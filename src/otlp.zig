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
    InvalidHeaders,
    InvalidTLSOptions,
    InvalidWireFormatForClient,
    InvalidCompression,
    InvalidProtocol,
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

    fn defaulttHttpPath(self: Signal) []const u8 {
        switch (self) {
            .metrics => return "/v1/metrics",
            .logs => return "/v1/logs",
            .traces => return "/v1/traces",
        }
    }
};

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

    pub fn init(allocator: std.mem.Allocator, config: ConfigOptions) !Self {
        try config.validate();
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .config = config,
        };
        return s;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    fn requestOptions(config: ConfigOptions) http.Client.RequestOptions {
        const headers: http.Client.Request.Headers = .{
            .accept_encoding = if (config.compression.encodingHeaderValue()) |v| v else .default,
            .content_type = switch (config.protocol) {
                .http_protobuf => "application/x-protobuf",
                .http_json => "application/json",
                else => ConfigError.InvalidWireFormatForClient,
            },
            .user_agent = .{ .override = UserAgent },
        };
        var request_options: http.Client.RequestOptions = .{
            .headers = headers,
        };
        if (config.headers) |h| {
            request_options.extra_headers = try parseHeaders(h);
        }

        return request_options;
    }

    fn send(self: Self, url: []const u8, body: []u8) !void {
        const client = http.Client{};

        var resp_body = std.ArrayList(u8).init(self.allocator);
        defer resp_body.deinit();

        const req_opts = self.requestOptions(self.config);
        const response = try client.fetch(http.Client.FetchOptions{
            .location = .{ .url = url },
            // We always send a POST request to write OTLP data.
            .method = .POST,
            .headers = req_opts.headers,
            .extra_headers = req_opts.extra_headers,
            .payload = body,
        });

        // Check the response status code; ptionally retry on some errors.
        switch (response.status.code) {
            // We must handle retries for a subset of status codes.
            // See https://opentelemetry.io/docs/specs/otlp/#otlphttp-response
            .ok, .accepted => return,
            .too_many_requests, .bad_gateway, .service_unavailable, .gateway_timeout => {
                // Retry the request.
                // TODO implement retry logic
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
        var kv = std.mem.splitScalar(u8, item, '=');
        const key: []const u8 = if (kv.next()) |t| std.mem.trim(u8, t, " ") else return ConfigError.InvalidHeaders;
        if (key.len == 0) {
            return ConfigError.InvalidHeaders;
        }
        const value: []const u8 = if (kv.next()) |t| std.mem.trim(u8, t, " ") else return ConfigError.InvalidHeaders;
        if (value.len == 0) {
            return ConfigError.InvalidHeaders;
        }
        if (kv.next()) |_| {
            return ConfigError.InvalidHeaders;
        }
        headers[idx] = std.http.Header{ .name = key, .value = value };
        idx += 1;
        // Fail when the sum of all bytes for the headers overflows.
        cum_bytes = std.math.add(u13, cum_bytes, @intCast(key.len + value.len + 1)) catch return ConfigError.InvalidHeaders;
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
        try std.testing.expectError(ConfigError.InvalidHeaders, parseHeaders(header));
    }
}
