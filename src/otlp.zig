///! Encapsulate the transport protocol for the OpenTelemetry Protocol (OTLP).
///! OTLP transport can be of 2 flavors: HTTP or gRPC.
const std = @import("std");
const http = std.http;
const Uri = std.Uri;

const UserAgent = "zig-o11y_opentelemetry-sdk/0.1.0";

/// The combination of underlying transport protocol and format used to send the data.
pub const Protocol = enum {
    // In order of precedence: SDK MUST support http/protobuf and SHOULD support grpc and http/json.
    http_protobuf,
    grpc,
    http_json,
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

/// Payload  compression algorithm.
pub const Compression = enum {
    none,
    gzip,

    fn encodingHeaderValue(self: Compression) ?[]const u8 {
        switch (self) {
            .none => return null,
            .gzip => return "gzip",
        }
    }
};

/// Configuration options for the OTLP transport.
pub const ConfigOpts = struct {
    /// The endpoint to send the data to.
    /// Must be in the form of "host:port/path".
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
    headers: ?[]const u8,

    tls_opts: ?TLSOptions = null,

    compression: Compression = .none,

    /// The maximum duration of batch exporting
    timeout_sec: u64 = 10,

    // Custom paths are used to override the default URL paths for the signals.
    // They should be populated by the user, but they can also be filled in
    // when parsing the config from environment variables.
    custom_paths: ?std.AutoHashMap(Signal, []const u8) = null,

    pub fn default() ConfigOpts {
        return .{};
    }

    fn validate(self: ConfigOpts) !void {
        // Validate the endpoint.
        if (self.endpoint.len == 0) {
            return ConfigError.InvalidEndpoint;
        }
        if (self.scheme == .https) {
            if (self.tls_opts == null) {
                return ConfigError.InvalidTLSOptions;
            }
        }
    }

    /// Retrieves the configuration from the environment variables.
    /// The environment variables are prefixed with "OTEL_EXPORTER_OTLP_"
    pub fn mergeFromEnv(self: *ConfigOpts) *ConfigOpts {
        //TODO implement this
        return self;
    }
};

/// Errors that can occur during the configuration of the OTLP transport.
pub const ConfigError = error{
    InvalidEndpoint,
    InvalidScheme,
    InvalidHeaders,
    InvalidTLSOptions,
    InvalidWireFormatForClient,
};

pub const Signal = enum {
    metrics,
    logs,
    trace,
    // TODO add other signals when implemented
    // profiles,

    fn defaulttHttpPath(self: Signal) []const u8 {
        switch (self) {
            .metrics => return "/v1/metrics",
            .logs => return "/v1/logs",
            .trace => return "/v1/traces",
        }
    }
};

// Creates the connection and handles the data transfer for an HTTP-based connection.
const HTTPClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ConfigOpts,

    pub fn init(allocator: std.mem.Allocator, config: ConfigOpts) !Self {
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

    fn requestOptions(config: ConfigOpts) http.Client.RequestOptions {
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
