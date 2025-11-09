//! Encapsulate the transport protocol for the OpenTelemetry Protocol (OTLP).
//! This module provides facilities to export signals via the OpenTelemetry Protocol (OTLP).
//! OTLP is a protocol used for transmitting telemetry data across networks, encoding them with protobuf or JSON.
//! See https://opentelemetry.io/docs/specs/otlp/
//!
//! OTLP transport can be have 2 types of transport: HTTP or gRPC.
//! Currently, only HTTP transport is implemented, because gRPC is not yet supported in Zig's ecosystem.

const std = @import("std");
const http = std.http;
const Uri = std.Uri;
const zlib = @cImport({
    @cInclude("zlib.h");
});

const log = std.log.scoped(.otlp);

const proto = @import("opentelemetry-proto");

const pbmetrics = proto.metrics_v1;
const pblogs = proto.logs_v1;
const pbtrace = proto.trace_v1;
const pbcommon = proto.common_v1;

const pbcollector_metrics = proto.collector_metrics_v1;
const pbcollector_trace = proto.collector_trace_v1;
const pbcollector_logs = proto.collector_logs_v1;

// Fixed user-agent string for the OTLP transport.
// TODO: find a way to make the version dynamic.
const UserAgent = "zig-o11y_opentelemetry-sdk/0.1.0";

/// Errors that can occur during the configuration of the OTLP transport.
pub const ConfigError = error{
    ConflictingOptions,
    InvalidEndpoint,
    InvalidScheme,
    InvalidHeadersSyntax,
    InvalidHeadersTooManyBytes,
    InvalidHeadersTooManyItems,
    InvalidTLSOptions,
    InvalidWireFormatForClient,
    InvalidCompression,
    InvalidProtocol,
};

/// Error set for the OTLP Export operation.
pub const ExportError = error{
    RequestEnqueuedForRetry,
    UnimplementedTransportProtocol,
    NonRetryableStatusCodeInResponse,
};

/// The combination of underlying transport protocol and format used to send the data.
pub const Protocol = enum {
    // In order of precedence: SDK MUST support http/protobuf and SHOULD support grpc and http/json.
    http_protobuf,
    grpc,
    http_json,

    fn fromString(in: []const u8) !Protocol {
        if (std.mem.eql(u8, in, "grpc")) return Protocol.grpc;
        if (std.mem.eql(u8, in, "http/protobuf")) return Protocol.http_protobuf;
        if (std.mem.eql(u8, in, "http/json")) return Protocol.http_json;

        return ConfigError.InvalidProtocol;
    }
};

/// Configure the TLS connection properties.
pub const TLSOptions = struct {
    /// CA chain used to verify server certificate (PEM format).
    certificate_file: ?[]const u8 = null,
    /// Client certificate used to authenticate the client (PEM format).
    client_certificate_file: ?[]const u8 = null,
    /// Client private key used to authenticate the client (PEM format).
    client_private_key_file: ?[]const u8 = null,
};

/// Payload compression algorithm.
/// When set to empty string, no compression is used.
pub const Compression = enum {
    none,
    gzip,

    fn encodingHeaderValue(self: Compression) ?[]const u8 {
        switch (self) {
            .none => return null,
            .gzip => return "gzip",
        }
    }

    fn fromString(in: []const u8) !Compression {
        if (std.mem.eql(u8, in, "gzip")) return .gzip;
        if (std.mem.eql(u8, in, "")) return .none;

        return ConfigError.InvalidCompression;
    }
};

/// The type of data being sent to the OTLP endpoint.
pub const Signal = enum {
    metrics,
    logs,
    traces,
    // TODO add other signals when implemented
    // profiles,

    const Self = @This();

    fn defaulttHttpPath(self: Self) []const u8 {
        switch (self) {
            .metrics => return "/v1/metrics",
            .logs => return "/v1/logs",
            .traces => return "/v1/traces",
        }
    }

    /// Actual signal data as protobuf messages.
    pub const Data = union(Self) {
        metrics: pbcollector_metrics.ExportMetricsServiceRequest,
        logs: pbcollector_logs.ExportLogsServiceRequest,
        traces: pbcollector_trace.ExportTraceServiceRequest,
        // TODO add other signals when implemented
        // profiles: profiles.ExportProfilesServiceRequest,

        fn toOwnedSlice(self: Data, allocator: std.mem.Allocator, protocol: Protocol) ![]const u8 {
            return switch (protocol) {
                .http_json => {
                    switch (self) {
                        inline else => |data| {
                            var list: std.ArrayList(u8) = .empty;
                            try list.ensureTotalCapacity(allocator, 4096);
                            try list.writer(allocator).print("{f}", .{std.json.fmt(data, .{})});
                            return try list.toOwnedSlice(allocator);
                        },
                    }
                },
                .http_protobuf, .grpc => {
                    switch (self) {
                        // All protobuf-generated structs have a encode method.
                        inline else => |data| {
                            var writer_ctx = std.Io.Writer.Allocating.init(allocator);
                            errdefer writer_ctx.deinit();
                            try data.encode(&writer_ctx.writer, allocator);
                            try writer_ctx.writer.flush();
                            // Note: toOwnedSlice() empties the buffer, so deinit() should be safe,
                            // but we skip it to avoid any potential double-free issues
                            return try writer_ctx.toOwnedSlice();
                        },
                    }
                },
            };
        }

        fn signal(self: Data) Signal {
            return std.meta.activeTag(self);
        }
    };
};

test "otlp Signal.Data get payload bytes" {
    const allocator = std.testing.allocator;
    var data = Signal.Data{
        .metrics = pbcollector_metrics.ExportMetricsServiceRequest{
            .resource_metrics = .empty,
        },
    };
    const payload = try data.toOwnedSlice(allocator, Protocol.http_protobuf);
    defer allocator.free(payload);

    try std.testing.expectEqual(payload.len, 0);
}

/// Configuration options for the OTLP transport.
pub const ConfigOptions = struct {
    allocator: std.mem.Allocator,

    /// The endpoint to send the data to.
    /// Must be in the form of "host:port", withouth scheme.
    endpoint: []const u8 = "localhost:4317",

    /// Only applicable to HTTP based transports.
    scheme: enum { http, https } = .http,

    /// Only applicabl to gRPC based trasnport.
    /// Defines if the gRPC client can use plaintext connection.
    insecure: ?bool = null,

    /// The protocol to use for sending the data.
    protocol: Protocol = .http_protobuf,

    /// Comma-separated list of key=value pairs to include in the request as headers.
    /// Format "key1=value1,key2=value2,...".
    /// They wll be parsed into HTTP headers and all the values will be treated as strings.
    headers: ?[]const u8 = null,

    tls_opts: ?TLSOptions = null,

    compression: Compression = .none,

    /// The maximum duration of batch exporting
    timeout_sec: u64 = 10,

    // Custom signal URLS are used to override the default endpoint + path concat logic for each signals.
    // They should be populated by the user, but they can also be filled in
    // when parsing the config from environment variables.
    custom_signal_urls: std.AutoHashMap(Signal, []const u8),

    retryConfig: ExpBackoffconfig = .{},

    pub fn init(allocator: std.mem.Allocator) !*ConfigOptions {
        const s = try allocator.create(ConfigOptions);
        s.* = ConfigOptions{
            .allocator = allocator,
            .custom_signal_urls = std.AutoHashMap(Signal, []const u8).init(allocator),
        };
        return s;
    }

    pub fn default() !*ConfigOptions {
        return init(std.heap.page_allocator);
    }

    pub fn deinit(self: *ConfigOptions) void {
        self.custom_signal_urls.deinit();
        self.allocator.destroy(self);
    }

    fn validate(self: ConfigOptions) !void {
        // Validate the endpoint.
        if (self.endpoint.len == 0) {
            return ConfigError.InvalidEndpoint;
        }
        if (self.scheme == .https) {
            if (self.insecure) |ins| {
                if (ins) return ConfigError.ConflictingOptions;
            }
        }
    }

    const env_var_prefix = "OTEL_EXPORTER_OTLP_";
    /// Retrieves the configuration from the environment variables.
    /// The environment variables are prefixed with "OTEL_EXPORTER_OTLP_",
    /// and they take precedence over the values set in the config.
    /// Pass the "environ" argument with std.process.getEnvMap().
    pub fn mergeFromEnvMap(self: *ConfigOptions, environ: *const std.process.EnvMap) !void {
        // customize endpoint and URLs
        if (entryFromEnvMap(environ, "ENDPOINT")) |endpoint| {
            self.endpoint = endpoint;
        }
        if (entryFromEnvMap(environ, "TRACES_ENDPOINT")) |traces| {
            try self.custom_signal_urls.put(Signal.traces, traces);
        }
        if (entryFromEnvMap(environ, "METRICS_ENDPOINT")) |metrics| {
            try self.custom_signal_urls.put(Signal.metrics, metrics);
        }
        if (entryFromEnvMap(environ, "LOGS_ENDPOINT")) |logs| {
            try self.custom_signal_urls.put(Signal.logs, logs);
        }
        // connection configs
        if (entryFromEnvMap(environ, "COMPRESSION")) |compression| {
            self.compression = try Compression.fromString(compression);
        }
        if (entryFromEnvMap(environ, "PROTOCOL")) |protocol| {
            self.protocol = try Protocol.fromString(protocol);
        }
        // TODO implement the rest of the environment variables.
    }

    fn entryFromEnvMap(environ: *const std.process.EnvMap, varSuffix: []const u8) ?[]const u8 {
        var env_var_name: [128]u8 = [_]u8{0} ** 128;
        for (env_var_prefix, 0..) |c, i| {
            env_var_name[i] = c;
        }
        for (varSuffix, 0..) |c, i| {
            env_var_name[env_var_prefix.len + i] = c;
        }
        return environ.get(env_var_name[0 .. env_var_prefix.len + varSuffix.len]);
    }

    // Builds the full HTTP URL for each signal.
    // Allocated memory is owned by the caller.
    fn httpUrlForSignal(self: ConfigOptions, signal: Signal, allocator: std.mem.Allocator) ![]const u8 {
        // When a custom path is specified, use it for the signal.
        // Otherwise, use the default.
        if (self.custom_signal_urls.get(signal)) |path| {
            return allocator.dupe(u8, path);
        }
        // When custom URLs are not specified, use the default logic to build the URL.
        var url = std.ArrayList(u8){};
        try url.appendSlice(allocator, @tagName(self.scheme));
        try url.appendSlice(allocator, "://");
        try url.appendSlice(allocator, self.endpoint);
        try url.appendSlice(allocator, signal.defaulttHttpPath());

        return url.toOwnedSlice(allocator);
    }
};

test "otlp config from env" {
    const allocator = std.testing.allocator;
    var map = std.process.EnvMap.init(allocator);
    defer map.deinit();
    // Set the environment variable to test.
    const new_endpoint: []const u8 = "something:1234";
    try map.put("OTEL_EXPORTER_OTLP_ENDPOINT", new_endpoint);
    try map.put("OTEL_EXPORTER_OTLP_COMPRESSION", "gzip");
    try map.put("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc");

    var config = try ConfigOptions.default();
    defer config.deinit();

    try config.mergeFromEnvMap(&map);
    try std.testing.expectEqualStrings(new_endpoint, config.endpoint);
    try std.testing.expectEqual(Compression.gzip, config.compression);
    try std.testing.expectEqual(Protocol.grpc, config.protocol);
}

test "otlp config custom endpoint for singals" {
    const allocator = std.testing.allocator;
    // Sanity check
    const cfg = try ConfigOptions.init(allocator);
    defer cfg.deinit();

    const traces = try cfg.httpUrlForSignal(Signal.traces, allocator);
    defer allocator.free(traces);

    try std.testing.expectEqualStrings("http://localhost:4317/v1/traces", traces);
    // Assert that some signals' HTTP path can be overridden from env.

    var map = std.process.EnvMap.init(allocator);
    defer map.deinit();
    try map.put("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "https://another.com:1234/traces");
    try map.put("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://metrics-new:1234");
    // logs are left untouched

    var config = try ConfigOptions.init(allocator);
    defer config.deinit();

    try config.mergeFromEnvMap(&map);

    const customTraces = try config.httpUrlForSignal(Signal.traces, allocator);
    const customMetrics = try config.httpUrlForSignal(Signal.metrics, allocator);
    const standardLogs = try config.httpUrlForSignal(Signal.logs, allocator);
    defer allocator.free(customTraces);
    defer allocator.free(customMetrics);
    defer allocator.free(standardLogs);
    try std.testing.expectEqualStrings("https://another.com:1234/traces", customTraces);
    try std.testing.expectEqualStrings("http://metrics-new:1234", customMetrics);
    try std.testing.expectEqualStrings("http://localhost:4317/v1/logs", standardLogs);
}

test "otlp config validation" {
    const allocator = std.testing.allocator;
    // Test invalid endpoint
    var cfg = try ConfigOptions.init(allocator);
    cfg.endpoint = "";
    try std.testing.expectError(ConfigError.InvalidEndpoint, cfg.validate());
    cfg.deinit();

    // Test conflicting options
    var cfg2 = try ConfigOptions.init(allocator);
    cfg2.scheme = .https;
    cfg2.insecure = true;
    try std.testing.expectError(ConfigError.ConflictingOptions, cfg2.validate());
    cfg2.deinit();

    // Test valid configuration
    var cfg3 = try ConfigOptions.init(allocator);
    cfg3.endpoint = "anything:1234";
    cfg3.scheme = .http;
    cfg3.insecure = null;
    try cfg3.validate();
    cfg3.deinit();
}

// Configures the behavior of the Exponential Backoff Retry strategy.
// The default values are not dictated by the OTLP spec.
pub const ExpBackoffconfig = struct {
    max_retries: u32 = 20,
    base_delay_ms: u64 = 100,
    max_delay_ms: u64 = 60000,
};

/// Compress data using gzip format via zlib C library.
/// Returns allocated slice owned by the caller.
/// compression_level should be between 0-9, or zlib.Z_DEFAULT_COMPRESSION.
fn compressGzip(allocator: std.mem.Allocator, input: []const u8, compression_level: c_int) ![]u8 {
    // Initialize zlib stream
    var stream: zlib.z_stream = undefined;
    stream.zalloc = null;
    stream.zfree = null;
    stream.@"opaque" = null;

    // Use deflateInit2 to specify gzip format
    // windowBits = 15 + 16 for gzip format (15 is the default, +16 adds gzip wrapper)
    const init_result = zlib.deflateInit2_(
        &stream,
        compression_level,
        zlib.Z_DEFLATED,
        15 + 16, // gzip format
        8, // default memory level
        zlib.Z_DEFAULT_STRATEGY,
        zlib.ZLIB_VERSION,
        @sizeOf(zlib.z_stream),
    );
    if (init_result != zlib.Z_OK) {
        return error.CompressionInitFailed;
    }
    defer _ = zlib.deflateEnd(&stream);

    // Allocate output buffer
    // Worst case: slightly larger than input due to headers
    const max_compressed_size = zlib.deflateBound(&stream, @intCast(input.len));
    const output = try allocator.alloc(u8, @intCast(max_compressed_size));
    errdefer allocator.free(output);

    // Set up input and output
    stream.avail_in = @intCast(input.len);
    stream.next_in = @constCast(input.ptr);
    stream.avail_out = @intCast(max_compressed_size);
    stream.next_out = output.ptr;

    // Compress
    const deflate_result = zlib.deflate(&stream, zlib.Z_FINISH);
    if (deflate_result != zlib.Z_STREAM_END) {
        allocator.free(output);
        return error.CompressionFailed;
    }

    // Resize to actual compressed size
    const compressed_size: usize = @intCast(stream.total_out);
    const result = try allocator.realloc(output, compressed_size);
    return result;
}

/// Handles the data transfer for HTTP-based OTLP.
const HTTPClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: *ConfigOptions,
    // Default HTTP Client
    client: http.Client,

    pub fn init(allocator: std.mem.Allocator, config: *ConfigOptions) !*Self {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        // Merge the environment variables into the config.
        try config.mergeFromEnvMap(&env);
        try config.validate();

        const s = try allocator.create(Self);

        s.* = Self{
            .allocator = allocator,
            .config = config,
            .client = http.Client{ .allocator = allocator },
        };

        return s;
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.allocator.destroy(self);
    }

    fn extraHeaders(allocator: std.mem.Allocator, config: *ConfigOptions) ![]http.Header {
        var extra_headers = std.ArrayList(http.Header){};
        if (config.headers) |h| {
            const parsed_headers = try parseHeaders(allocator, h);
            defer allocator.free(parsed_headers);
            try extra_headers.appendSlice(allocator, parsed_headers);
        }
        if (config.compression.encodingHeaderValue()) |comp| {
            const ce: http.Header = .{ .name = "content-encoding", .value = comp };
            try extra_headers.append(allocator, ce);
        }
        return extra_headers.toOwnedSlice(allocator);
    }

    fn requestOptions(allocator: std.mem.Allocator, config: *ConfigOptions) !http.Client.RequestOptions {
        const headers: http.Client.Request.Headers = .{
            .accept_encoding = if (config.compression.encodingHeaderValue()) |v| .{ .override = v } else .default,
            .content_type = .{ .override = switch (config.protocol) {
                .http_protobuf => "application/x-protobuf",
                .http_json => "application/json",
                else => return ConfigError.InvalidWireFormatForClient,
            } },
            .user_agent = .{ .override = UserAgent },
        };
        const request_options: http.Client.RequestOptions = .{
            .headers = headers,
            .extra_headers = try extraHeaders(allocator, config),
        };

        return request_options;
    }

    // Send the OTLP data to the url using the client's configuration.
    // Data passed as argument should either be protobuf or JSON encoded, as specified in the config.
    // Data will be compressed here.
    fn send(self: *Self, url: []const u8, input_data: []const u8) !void {
        const req_body = req: {
            switch (self.config.compression) {
                .none => break :req try self.allocator.dupe(u8, input_data),
                .gzip => {
                    // Compress the data using gzip via zlib C library.
                    // Maximum compression level (9), favor minimum network transfer over CPU usage.
                    break :req try compressGzip(self.allocator, input_data, zlib.Z_BEST_COMPRESSION);
                },
            }
        };
        defer self.allocator.free(req_body);

        const req_opts = try requestOptions(self.allocator, self.config);
        defer {
            if (req_opts.extra_headers.len > 0) self.allocator.free(req_opts.extra_headers);
        }

        const fetch_request = http.Client.FetchOptions{
            .location = .{ .url = url },
            // We always send a POST request to write OTLP data.
            .method = .POST,
            .headers = req_opts.headers,
            .extra_headers = if (req_opts.extra_headers.len > 0) req_opts.extra_headers else &.{},
            .payload = req_body,
        };

        const response = self.client.fetch(fetch_request) catch |err| {
            // Handle connection errors that occur before getting a response
            switch (err) {
                error.HttpConnectionClosing, error.ReadFailed, error.ConnectionResetByPeer => {
                    // These are connection-level errors that should be treated as non-retryable
                    return ExportError.NonRetryableStatusCodeInResponse;
                },
                else => return err,
            }
        };

        switch (response.status) {
            // TODO: handle partial success.
            // See https://opentelemetry.io/docs/specs/otlp/#partial-success-1
            .ok, .accepted => return,
            // We must handle retries for a subset of status codes.
            // See https://opentelemetry.io/docs/specs/otlp/#otlphttp-response
            .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => {
                // Use page_allocator for retry thread to avoid lifetime issues with the caller's allocator
                // The retry thread is detached and may outlive the caller's scope
                const retry_allocator = std.heap.page_allocator;
                const cloned_req = try cloneFetchOptions(retry_allocator, fetch_request);
                const t = try std.Thread.spawn(.{}, retryRequest, .{
                    retry_allocator,
                    self.config.retryConfig,
                    cloned_req,
                });
                t.detach();

                return ExportError.RequestEnqueuedForRetry;
            },
            else => {
                // Do not retry and report the status code and the message.
                // TODO implement error handling, parsing Status message.
                log.err("Non-retryable status code: {} for URL: {s}", .{ response.status, url });
                return ExportError.NonRetryableStatusCodeInResponse;
            },
        }
    }

    fn retryRequest(allocator: std.mem.Allocator, retry_config: ExpBackoffconfig, req_opts: http.Client.FetchOptions) void {
        defer freeFetchOptions(allocator, req_opts);

        var retry_count: u32 = 0;
        while (retry_count < retry_config.max_retries) {
            defer retry_count += 1;

            var client = http.Client{ .allocator = allocator };
            const response = client.fetch(req_opts) catch |err| {
                client.deinit();
                log.err("transport (retry): error connecting to server: {}", .{err});
                continue;
            };
            client.deinit();

            switch (response.status) {
                .ok, .accepted => {
                    return;
                },
                .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => {
                    std.Thread.sleep(std.time.ns_per_ms * calculateDelayMillisec(
                        retry_config.base_delay_ms,
                        retry_config.max_delay_ms,
                        retry_count,
                    ));
                    continue;
                },
                else => |status| {
                    log.err("transport (retry): request failed with status code: {}", .{status});
                    return;
                },
            }
        }
    }

    fn cloneFetchOptions(allocator: std.mem.Allocator, opts: http.Client.FetchOptions) !http.Client.FetchOptions {
        var cloned = opts;
        cloned.location = .{ .url = try allocator.dupe(u8, opts.location.url) };
        if (opts.payload) |payload| {
            cloned.payload = try allocator.dupe(u8, payload);
        }
        cloned.extra_headers = try allocator.dupe(http.Header, opts.extra_headers);

        return cloned;
    }

    fn freeFetchOptions(allocator: std.mem.Allocator, req: http.Client.FetchOptions) void {
        allocator.free(req.location.url);
        if (req.payload) |payload| {
            allocator.free(payload);
        }
        allocator.free(req.extra_headers);
    }
};

fn calculateDelayMillisec(base_delay_ms: u64, max_delay_ms: u64, attempt: u32) u64 {
    // Exponential backoff with jitter: delay = min(max_delay, base * 2^attempt) + random(0, 10%)
    const delay: u64 = @min(
        max_delay_ms,
        base_delay_ms * std.math.pow(u64, 2, attempt),
    );
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const jitter = prng.random().intRangeAtMost(u64, 0, @intCast(@divTrunc(delay, 10)));
    return delay + jitter;
}

// Parses the key-value, comma separated list of headers from the config.
// Caller owns the memory and must free it.
fn parseHeaders(allocator: std.mem.Allocator, key_values: []const u8) ![]std.http.Header {
    // Maximum 64 items are allowd in the W3C baggage
    var headers = try allocator.alloc(std.http.Header, 64);
    defer allocator.free(headers);

    var comma_split = std.mem.splitScalar(u8, key_values, ',');

    var idx: usize = 0;
    // The sum of all characters in the key and value must be less than 8192 bytes (2^13).
    var cum_bytes: u13 = 0;
    while (comma_split.next()) |item| {
        // Fail if there are more than 64 headers.
        if (idx == headers.len) {
            return ConfigError.InvalidHeadersTooManyItems;
        }
        var kv = std.mem.splitScalar(u8, item, '=');
        const key: []const u8 = if (kv.next()) |t| std.mem.trim(u8, t, " ") else return ConfigError.InvalidHeadersSyntax;
        if (key.len == 0) {
            return ConfigError.InvalidHeadersSyntax;
        }
        const value: []const u8 = if (kv.next()) |t| std.mem.trim(u8, t, " ") else return ConfigError.InvalidHeadersSyntax;
        if (value.len == 0) {
            return ConfigError.InvalidHeadersSyntax;
        }
        if (kv.next()) |_| {
            return ConfigError.InvalidHeadersSyntax;
        }
        // Fail when the sum of all bytes for the headers overflows.
        // Each header is accompanied by 3 more bytes: a colon, a space and a newline.
        cum_bytes = std.math.add(u13, cum_bytes, @intCast(key.len + value.len + 3)) catch return ConfigError.InvalidHeadersTooManyBytes;

        headers[idx] = std.http.Header{ .name = key, .value = value };
        idx += 1;
    }
    const ret = try allocator.alloc(std.http.Header, idx);
    std.mem.copyForwards(std.http.Header, ret, headers[0..idx]);
    return ret;
}

test "otlp config parse headers" {
    const allocator = std.testing.allocator;

    const single_header = "test-header=test-value";
    const single_parsed = try parseHeaders(allocator, single_header);
    defer allocator.free(single_parsed);

    try std.testing.expectEqual(1, single_parsed.len);
    try std.testing.expectEqualSlices(u8, "test-header", single_parsed[0].name);
    try std.testing.expectEqualSlices(u8, "test-value", single_parsed[0].value);

    const valid_headers = "a=b,123=456,key1=value1  ,  key2=value2";
    const parsed = try parseHeaders(allocator, valid_headers);
    defer allocator.free(parsed);

    try std.testing.expectEqual(parsed.len, 4);
    try std.testing.expectEqualSlices(u8, "a", parsed[0].name);
    try std.testing.expectEqualSlices(u8, "b", parsed[0].value);
    try std.testing.expectEqualSlices(u8, "123", parsed[1].name);
    try std.testing.expectEqualSlices(u8, "456", parsed[1].value);
    try std.testing.expectEqualSlices(u8, "key1", parsed[2].name);
    try std.testing.expectEqualSlices(u8, "value1", parsed[2].value);
    try std.testing.expectEqualSlices(u8, "key2", parsed[3].name);
    try std.testing.expectEqualSlices(u8, "value2", parsed[3].value);

    const invalid_headers: [4][]const u8 = .{ "a=,", "=b", "a=b=c", "a=b,=c=d" };
    for (invalid_headers) |header| {
        try std.testing.expectError(ConfigError.InvalidHeadersSyntax, parseHeaders(allocator, header));
    }

    // 150 bytes * 60 == 9000 bytes
    const invalid_too_many_bytes: []const u8 = "key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA," ** 60;
    try std.testing.expectError(ConfigError.InvalidHeadersTooManyBytes, parseHeaders(allocator, invalid_too_many_bytes));

    const invalid_too_many_items: []const u8 = "key=val," ** 65;
    try std.testing.expectError(ConfigError.InvalidHeadersTooManyItems, parseHeaders(allocator, invalid_too_many_items));
}

test "otlp HTTPClient extra headers" {
    const allocator = std.testing.allocator;
    var config = try ConfigOptions.init(allocator);
    defer config.deinit();

    config.headers = "key1=value1,key2=value2";
    const headers = try HTTPClient.extraHeaders(allocator, config);
    defer allocator.free(headers);

    try std.testing.expectEqual(2, headers.len);
    try std.testing.expectEqualSlices(u8, "key1", headers[0].name);
    try std.testing.expectEqualSlices(u8, "value1", headers[0].value);
    try std.testing.expectEqualSlices(u8, "key2", headers[1].name);
    try std.testing.expectEqualSlices(u8, "value2", headers[1].value);
}

test "otlp exp backoff delay calculation" {
    const config = ExpBackoffconfig{
        .max_retries = 10,
        .base_delay_ms = 5,
        .max_delay_ms = 30000,
    };

    const first_backoff = calculateDelayMillisec(config.base_delay_ms, config.max_delay_ms, 1);
    const second_backoff = calculateDelayMillisec(config.base_delay_ms, config.max_delay_ms, 2);

    try std.testing.expect(first_backoff >= 10 and first_backoff <= 12);
    try std.testing.expect(second_backoff >= 20 and second_backoff <= 23);

    try std.testing.expect(second_backoff > first_backoff);
    try std.testing.expect(second_backoff < config.max_delay_ms);
}

// This test is here to allow compiling all the code paths of ExpBackoffRetry struct.
// In itself, it does not provide much value other than ensuring that the code compiles,
// and there is no memory leak.
test "otlp HTTPClient send fails for missing server" {
    const allocator = std.testing.allocator;
    var config = try ConfigOptions.init(allocator);
    defer config.deinit();

    const client = try HTTPClient.init(allocator, config);
    defer client.deinit();

    const url = try config.httpUrlForSignal(.metrics, allocator);
    defer allocator.free(url);

    var payload = [_]u8{0} ** 1024;
    const result = client.send(url, &payload);
    try std.testing.expectError(std.posix.ConnectError.ConnectionRefused, result);
}

/// Export the data to the OTLP endpoint using the options configured with ConfigOptions.
pub fn Export(
    allocator: std.mem.Allocator,
    config: *ConfigOptions,
    otlp_payload: Signal.Data,
) !void {
    // FIXME better polymorphism here.
    // Determine the type of client to be used, currently only HTTP is supported.
    const client = switch (config.protocol) {
        .http_json, .http_protobuf => try HTTPClient.init(allocator, config),
        .grpc => return ExportError.UnimplementedTransportProtocol,
    };
    // the `deinit()` method MUST be implemented by all clients.
    defer client.deinit();

    const payload = otlp_payload.toOwnedSlice(allocator, config.protocol) catch |err| {
        log.err("failed to encode payload via {t}: {}", .{ config.protocol, err });
        return err;
    };
    defer allocator.free(payload);

    const url = try config.httpUrlForSignal(otlp_payload.signal(), allocator);
    defer allocator.free(url);

    client.send(url, payload) catch |err| {
        switch (err) {
            ExportError.RequestEnqueuedForRetry => return err,
            else => {
                log.err("failed to send payload: {}", .{err});
                return err;
            },
        }
    };
}

pub fn ExportFile(
    allocator: std.mem.Allocator,
    otlp_payload: Signal.Data,
    file: *std.fs.File,
) !void {
    // We always want the JSON format for file export.
    // Single-line output for each entry is concatenated with newline before flushing.
    const payload = otlp_payload.toOwnedSlice(allocator, .http_json) catch |err| {
        log.err("failed to encode payload to JSON: {}", .{err});
        return err;
    };
    defer allocator.free(payload);

    // Position the file cursor at the end before writing
    try file.seekFromEnd(0);

    // Write payload and newline directly to file
    try file.writeAll(payload);
    try file.writeAll("\n");

    try file.sync();
}

// NOTE: The following code **not used** in the current implementation, but it is here to show how it could be done.

// This is an attempt to implement a priority queue for the retryable requests.
// The retryable requests are stored in a priority queue, sorted by the next attempt time.
// A single thread, or a thread pool, can be used to process the requests.
fn ExpBackoffQueue(comptime Retry: type) type {
    return struct {
        const Self = @This();

        const DelayedRetry = struct {
            value: Retry,
            next_attempt_time_ms: u64,
            attempts_counter: u32,
        };

        allocator: std.mem.Allocator,
        queue: std.PriorityQueue(DelayedRetry, void, compareRetriable),
        mutex: std.Thread.Mutex,
        condition: *std.Thread.Condition,
        config: ExpBackoffconfig,

        fn init(allocator: std.mem.Allocator, config: ExpBackoffconfig, signal: *std.Thread.Condition) !*Self {
            const s = try allocator.create(Self);
            s.* = Self{
                .allocator = allocator,
                .queue = std.PriorityQueue(DelayedRetry, void, compareRetriable).init(allocator, {}),
                .mutex = std.Thread.Mutex{},
                .condition = signal,
                .config = config,
            };
            return s;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            while (self.queue.removeOrNull()) |_| {}
            self.queue.deinit();
            self.mutex.unlock();

            self.allocator.destroy(self);
        }

        fn compareRetriable(_: void, a: DelayedRetry, b: DelayedRetry) std.math.Order {
            return std.math.order(a.next_attempt_time_ms, b.next_attempt_time_ms);
        }

        fn enqueue(self: *Self, value: Retry, attempt: u32) !void {
            const next_attempt_ms = @as(u64, @intCast(std.time.milliTimestamp())) +
                calculateDelayMillisec(self.config.base_delay_ms, self.config.max_delay_ms, attempt);

            const req = DelayedRetry{
                .value = value,
                .attempts_counter = attempt,
                .next_attempt_time_ms = next_attempt_ms,
            };

            self.mutex.lock();
            try self.queue.add(req);
            self.mutex.unlock();

            self.condition.signal();
        }

        fn poll(self: *Self) ?Retry {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.queue.removeOrNull()) |item| {
                const now_ms = std.time.milliTimestamp();
                if (item.next_attempt_time_ms < now_ms) {
                    self.condition.timedWait(
                        &self.mutex,
                        (@as(u64, @intCast(now_ms)) - item.next_attempt_time_ms) * std.time.ns_per_ms,
                    ) catch {
                        return item.value;
                    };
                }
                return item.value;
            }
            return null;
        }
    };
}

test "otlp ExpBackOffqueue for request FetchOptions" {
    var cond = std.Thread.Condition{};

    const cfg = ExpBackoffconfig{
        .max_retries = 10,
        .base_delay_ms = 1,
        .max_delay_ms = 1,
    };
    const queue = ExpBackoffQueue(*http.Client.FetchOptions);

    const q = try queue.init(std.testing.allocator, cfg, &cond);
    defer q.deinit();

    var req = http.Client.FetchOptions{
        .location = .{ .url = "http://localhost:4317/v1/metrics" },
        .method = .POST,
    };
    try std.testing.expect(q.poll() == null);

    try q.enqueue(&req, 0);
    try std.testing.expectEqual(req, q.poll().?.*);
}

// Integration tests
test {
    _ = @import("otlp_test.zig");
}
