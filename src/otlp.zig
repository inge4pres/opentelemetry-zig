///! Encapsulate the transport protocol for the OpenTelemetry Protocol (OTLP).
///! OTLP transport can be of 2 flavors: HTTP or gRPC.
const std = @import("std");
const http = std.http;
const Uri = std.Uri;

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
    UnimplementedTransportProtocol,
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
        metrics: pbmetrics.MetricsData,
        logs: pblogs.LogsData,
        traces: pbtrace.TracesData,
        // TODO add other signals when implemented
        // profiles: profiles.ProfilesData,

        fn toOwnedSlice(self: Data, allocator: std.mem.Allocator, protocol: Protocol) ![]const u8 {
            return switch (protocol) {
                .http_json => {
                    switch (self) {
                        // All protobuf-generated structs have a json_encode method.
                        inline else => |data| return data.json_encode(.{}, allocator),
                    }
                },
                .http_protobuf, .grpc => {
                    switch (self) {
                        // All protobuf-generated structs have a encode method.
                        inline else => |data| return data.encode(allocator),
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
        .metrics = pbmetrics.MetricsData{
            .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(allocator),
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
    /// Must be in the form of "host:port".
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
        var url = std.ArrayList(u8).init(allocator);
        try url.appendSlice(@tagName(self.scheme));
        try url.appendSlice("://");
        try url.appendSlice(self.endpoint);
        try url.appendSlice(signal.defaulttHttpPath());

        return url.toOwnedSlice();
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

// Creates the connection and handles the data transfer for an HTTP-based connection.
const HTTPClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ConfigOptions,
    // Default HTTP Client
    client: http.Client,
    // Retries are processed using a separate thread.
    // A priority queue is maintained in the ExpBackoffRetry struct.
    retry: *ExpBackoffRetry,

    pub fn init(allocator: std.mem.Allocator, config: ConfigOptions) !*Self {
        try config.validate();

        const s = try allocator.create(Self);

        s.* = Self{
            .allocator = allocator,
            .config = config,
            .client = http.Client{ .allocator = allocator },
            .retry = undefined,
        };

        const retry = try ExpBackoffRetry.init(allocator, &s.client, .{});
        s.retry = retry;

        return s;
    }

    pub fn deinit(self: *Self) void {
        self.retry.deinit();
        self.allocator.destroy(self);
    }

    fn requestOptions(config: ConfigOptions) !http.Client.RequestOptions {
        const headers: http.Client.Request.Headers = .{
            .accept_encoding = if (config.compression.encodingHeaderValue()) |v| .{ .override = v } else .default,
            .content_type = .{ .override = switch (config.protocol) {
                .http_protobuf => "application/x-protobuf",
                .http_json => "application/json",
                else => return ConfigError.InvalidWireFormatForClient,
            } },
            .user_agent = .{ .override = UserAgent },
        };
        var request_options: http.Client.RequestOptions = .{
            .headers = headers,
            .server_header_buffer = undefined,
        };
        if (config.headers) |h| {
            request_options.extra_headers = try parseHeaders(h);
        }

        return request_options;
    }

    // Send the OTLP data to the url using the client's configuration.
    // Data passed as argument should either be protobuf or JSON encoded, as specified in the config.
    // Data will be compressed here.
    fn send(self: *Self, url: []const u8, data: []u8) !void {
        var resp_body = std.ArrayList(u8).init(self.allocator);
        defer resp_body.deinit();

        const req_body = req: {
            switch (self.config.compression) {
                .none => break :req try self.allocator.dupe(u8, data),
                .gzip => {
                    // Compress the data using gzip.
                    // Maximum compression level, favor minimum network transfer over CPU usage.
                    var uncompressed = std.io.fixedBufferStream(data);
                    defer uncompressed.reset();

                    var compressed = std.ArrayList(u8).init(self.allocator);

                    try std.compress.gzip.compress(uncompressed.reader(), compressed.writer(), .{ .level = .level_9 });
                    break :req try compressed.toOwnedSlice();
                },
            }
        };
        defer self.allocator.free(req_body);

        const req_opts = try requestOptions(self.config);

        const fetch_request = http.Client.FetchOptions{
            .location = .{ .url = url },
            // We always send a POST request to write OTLP data.
            .method = .POST,
            .headers = req_opts.headers,
            .extra_headers = req_opts.extra_headers,
            .payload = req_body,
        };
        const response = try self.client.fetch(fetch_request);

        switch (response.status) {
            .ok, .accepted => return,
            // We must handle retries for a subset of status codes.
            // See https://opentelemetry.io/docs/specs/otlp/#otlphttp-response
            .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => {
                try self.retry.enqueue(fetch_request, 0);
            },
            else => {
                // Do not retry and report the status code and the message.
                // TODO implement error handling
            },
        }
    }
};

fn parseHeaders(key_values: []const u8) ConfigError![]std.http.Header {
    // Maximum 64 items are allowd in the W3C baggage
    var headers = [_]std.http.Header{.{ .name = "", .value = "" }} ** 64;
    var split = std.mem.splitScalar(u8, key_values, ',');

    var idx: usize = 0;
    // The sum of all characters in the key and value must be less than 8192 bytes (2^13).
    var cum_bytes: u13 = 0;
    while (split.next()) |item| {
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
        headers[idx] = std.http.Header{ .name = key, .value = value };
        idx += 1;
        // Fail when the sum of all bytes for the headers overflows.
        // Each header is accompanied by 3 more bytes: a colon, a space and a newline.
        cum_bytes = std.math.add(u13, cum_bytes, @intCast(key.len + value.len + 3)) catch return ConfigError.InvalidHeadersTooManyBytes;
    }
    return headers[0..idx];
}

test "otlp config parse headers" {
    const valid_headers = "a=b,123=456,key1=value1  ,  key2=value2";
    const parsed = try parseHeaders(valid_headers);

    try std.testing.expectEqual(parsed.len, 4);
    try std.testing.expectEqualSlices(u8, parsed[0].name, "a");
    try std.testing.expectEqualSlices(u8, parsed[0].value, "b");
    try std.testing.expectEqualSlices(u8, parsed[1].name, "123");
    try std.testing.expectEqualSlices(u8, parsed[1].value, "456");
    try std.testing.expectEqualSlices(u8, parsed[2].name, "key1");
    try std.testing.expectEqualSlices(u8, parsed[2].value, "value1");
    try std.testing.expectEqualSlices(u8, parsed[3].name, "key2");
    try std.testing.expectEqualSlices(u8, parsed[3].value, "value2");

    const invalid_headers: [4][]const u8 = .{ "a=,", "=b", "a=b=c", "a=b,=c=d" };
    for (invalid_headers) |header| {
        try std.testing.expectError(ConfigError.InvalidHeadersSyntax, parseHeaders(header));
    }

    // 150 bytes * 60 == 9000 bytes
    const invalid_too_many_bytes: []const u8 = "key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA," ** 60;
    try std.testing.expectError(ConfigError.InvalidHeadersTooManyBytes, parseHeaders(invalid_too_many_bytes));

    const invalid_too_many_items: []const u8 = "key=val," ** 65;
    try std.testing.expectError(ConfigError.InvalidHeadersTooManyItems, parseHeaders(invalid_too_many_items));
}

// Implements the Exponential Backoff Retry strategy for HTTP requests.
// The default configuration values are not dictated by the OTLP spec.
// We choose toset a maxumum number of retries, even if not specified in the spec,
// to avoid infinite loops in case of a un-responsive server.
const ExpBackoffRetry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    client: *http.Client,

    max_retries: u32,
    base_delay_ms: u64,
    max_delay_ms: u64,

    queue: std.PriorityQueue(FetchRequest, void, compareFetchRequest),
    thread: ?std.Thread,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    running: std.atomic.Value(bool),

    // Wrapper for FetchOptions with retry metadata
    const FetchRequest = struct {
        options: http.Client.FetchOptions,
        attempts_counter: u32,
        next_attempt_time_ms: i64, // Timestamp (ms) for next retry
    };

    // Compare function for PriorityQueue (earlier next_attempt first)
    fn compareFetchRequest(_: void, a: FetchRequest, b: FetchRequest) std.math.Order {
        return std.math.order(a.next_attempt_time_ms, b.next_attempt_time_ms);
    }

    fn init(allocator: std.mem.Allocator, client: *http.Client, config: struct {
        max_retries: u32 = 50,
        base_delay_ms: u64 = 100,
        max_delay_ms: u64 = 60000,
    }) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .client = client,
            .max_retries = config.max_retries,
            .base_delay_ms = config.base_delay_ms,
            .max_delay_ms = config.max_delay_ms,
            .queue = std.PriorityQueue(FetchRequest, void, compareFetchRequest).init(allocator, {}),
            .mutex = std.Thread.Mutex{},
            .thread = null,
            .condition = std.Thread.Condition{},
            .running = std.atomic.Value(bool).init(true),
        };

        // Start the background thread
        s.thread = try std.Thread.spawn(.{}, retryLoop, .{s});
        return s;
    }

    fn deinit(self: *Self) void {
        // Signal the thread to stop
        self.running.store(false, .release);
        // Wake the thread if it's waiting
        self.condition.signal();

        // Wait for the thread to finish
        if (self.thread) |t| {
            t.join();
        }

        // Clean up queue
        self.mutex.lock();
        while (self.queue.removeOrNull()) |req| {
            self.freeFetchRequest(&req);
        }
        self.queue.deinit();
        self.mutex.unlock();

        self.allocator.destroy(self);
    }

    fn enqueue(self: *Self, options: http.Client.FetchOptions, attempt: u32) !void {
        const req = FetchRequest{
            .options = try self.cloneFetchOptions(options),
            .attempts_counter = attempt,
            .next_attempt_time_ms = std.time.milliTimestamp() + calculateDelay(self.base_delay_ms, self.max_delay_ms, attempt),
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.add(req);
        self.condition.signal();
    }

    fn retryLoop(self: *Self) void {
        while (self.running.load(.acquire)) {
            var req: FetchRequest = undefined;
            // We use this boolean to avoid a data race.
            var has_request: bool = false;

            {
                // Block that acquires the lock and waits for the first request in the queue to be ready.
                self.mutex.lock();
                // We release the lock at the end of the block.
                defer self.mutex.unlock();

                if (self.queue.peek()) |peeked_req| {
                    const now = std.time.milliTimestamp();
                    if (now < peeked_req.next_attempt_time_ms) {
                        // Wait until the next attempt time or a new item
                        const wait_ns: u64 = @intCast((peeked_req.next_attempt_time_ms - now) * std.time.ns_per_ms);
                        self.condition.timedWait(&self.mutex, wait_ns) catch continue;
                    } else {
                        // Copy the request and remove it from the queue, avoiding the data race that would be caused by
                        // modifying the queue while the thread is running.
                        req = peeked_req;
                        _ = self.queue.remove();
                        has_request = true;
                    }
                } else {
                    // Queue is empty, wait for a signal
                    self.condition.wait(&self.mutex);
                    continue;
                }
            }

            if (!has_request) continue;
            defer self.freeFetchRequest(&req);

            // Attempt the request
            const response = self.client.fetch(req.options) catch |err| {
                std.debug.print("OTLP transport: error connecting to server: {}\n", .{err});
                if (req.attempts_counter < self.max_retries) {
                    self.enqueue(req.options, req.attempts_counter + 1) catch |e| {
                        std.debug.print("OTLP transport: failed to re-queue: {}\n", .{e});
                    };
                }
                continue;
            };

            // Check response status
            switch (response.status) {
                .ok, .accepted => {
                    // Success, go on (the request is cleaned up in the loop)
                },
                .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => {
                    // Retry if we have attempts left
                    if (req.attempts_counter < self.max_retries) {
                        self.enqueue(req.options, req.attempts_counter + 1) catch |e| {
                            std.debug.print("OTLP transport: failed to re-queue: {}\n", .{e});
                        };
                    }
                },
                else => |s| {
                    // Non-retryable error should be logged
                    std.debug.print("OTLP transport: exp backoff response has a non-retryable status: {s}\n", .{@tagName(s)});
                },
            }
        }
    }

    fn calculateDelay(base_delay_ms: u64, max_delay_ms: u64, attempt: u32) i64 {
        // Exponential backoff with jitter: delay = min(max_delay, base * 2^attempt) + random(0, 10%)
        const delay: i64 = @intCast(@min(
            max_delay_ms,
            base_delay_ms * std.math.pow(u64, 2, attempt),
        ));
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        const jitter = prng.random().intRangeAtMost(i64, 0, @intCast(@divTrunc(delay, 10)));
        return delay + jitter;
    }

    fn cloneFetchOptions(self: *Self, opts: http.Client.FetchOptions) !http.Client.FetchOptions {
        var cloned = opts;
        cloned.location = .{ .url = try self.allocator.dupe(u8, opts.location.url) };
        if (opts.payload) |payload| {
            cloned.payload = try self.allocator.dupe(u8, payload);
        }
        cloned.extra_headers = try self.allocator.dupe(http.Header, opts.extra_headers);

        return cloned;
    }

    fn freeFetchRequest(self: *Self, req: *const FetchRequest) void {
        self.allocator.free(req.options.location.url);
        if (req.options.payload) |payload| {
            self.allocator.free(payload);
        }
        self.allocator.free(req.options.extra_headers);
    }
};

// This test is here to allow compiling all the code paths of ExpBackoffRetry struct.
// In itself, it does not provide much value other than ensuring that the code compiles,
// and there is no memory leak.
test "otlp HTTPClient send fails for missing server" {
    const allocator = std.testing.allocator;
    var config = try ConfigOptions.init(allocator);
    defer config.deinit();

    const client = try HTTPClient.init(allocator, config.*);
    defer client.deinit();

    const url = try config.httpUrlForSignal(.metrics, allocator);
    defer allocator.free(url);

    var payload = [_]u8{0} ** 1024;
    const result = client.send(url, &payload);
    try std.testing.expectError(std.posix.ConnectError.ConnectionRefused, result);
}

const pbmetrics = @import("opentelemetry/proto/metrics/v1.pb.zig");
const pblogs = @import("opentelemetry/proto/logs/v1.pb.zig");
const pbtrace = @import("opentelemetry/proto/trace/v1.pb.zig");

/// Export the data to the OTLP endpoint using the options configured with ConfigOptions.
pub fn Export(
    allocator: std.mem.Allocator,
    config: ConfigOptions,
    otlp_payload: Signal.Data,
) !void {
    // Determine the type of client to be used, currently only HTTP is supported.
    const client = switch (config.protocol) {
        .http_json, .http_protobuf => try HTTPClient.init(allocator, config),
        .grpc => return ExportError.UnimplementedTransportProtocol,
    };

    const payload = otlp_payload.toOwnedSlice(allocator, config.protocol) catch |err| {
        std.debug.print("OTLP transport: failed to encode payload via {s}: {?}\n", .{ @tagName(config.protocol), err });
        return err;
    };
    defer allocator.free(payload);

    const url = try config.httpUrlForSignal(otlp_payload.signal(), allocator);
    defer allocator.free(url);

    client.send(url, payload) catch |err| {
        std.debug.print("OTLP transport: failed to send payload: {?}\n", .{err});
        return err;
    };
}
