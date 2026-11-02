//! gRPC transport backed by Google's libgrpc (via the `cgrpc_wrapper`
//! Zig bindings). Selected by `-Dgrpc-provider=libgrpc`.

const std = @import("std");
const grpc = @import("cgrpc_wrapper");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.grpc_transport);

const configuration = @import("config.zig");
pub const Configuration = configuration.Configuration;

/// Send a pre-encoded protobuf payload to a gRPC endpoint.
///
/// `path` is the gRPC method path, e.g. "/package.Service/Method".
/// `data` is the raw protobuf-encoded request body.
/// `io` is used to read PEM files for SSL credentials (if configured); the
/// actual gRPC call goes through libgrpc's own thread pool.
pub fn send(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
    data: []const u8,
    config: Configuration,
) !void {
    // TODO: do it once globally
    grpc.init();
    defer grpc.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const endpoint: [:0]u8 = try arena.dupeSentinel(u8, config.endpoint, 0);

    var credentials: grpc.client.Credentials = try makeCredentials(arena, io, config);
    defer credentials.deinit();

    var channel: grpc.Channel = try grpc.Channel.init(endpoint, credentials);
    defer channel.deinit();

    var queue: grpc.PluckQueue = .init();
    defer queue.deinit();
    // TODO: drain the queue until its shutdown event before destroying it, as
    // gRPC requires. No event is left pending by then: `rawUnaryCall` waits for
    // its batch to complete, cancelling the call on timeout.
    defer queue.shutdown();

    const metadata = try arena.alloc(grpc.client.Metadata, config.headers.len);
    for (metadata, config.headers) |*m, header| m.* = .{
        .key = try std.ascii.allocLowerString(arena, header.name),
        .value = header.value,
    };

    const deadline: grpc.Deadline = if (config.timeout_sec == 0)
        .infinite
    else
        .{ .duration = .fromSeconds(@intCast(config.timeout_sec)) };
    switch (try grpc.client.rawUnaryCall(gpa, &channel, &queue, path, data, .{ .deadline = deadline, .metadata = metadata })) {
        // TODO: handle partial success.
        // See https://opentelemetry.io/docs/specs/otlp/#partial-success
        .success => |bytes| if (bytes) |b| gpa.free(b),
        .failure => |f| {
            defer gpa.free(f.details);
            log.err("gRPC error {}: {s}", .{ f.code, f.details });
            // Retryable codes per OTLP spec:
            // https://opentelemetry.io/docs/specs/otlp/#otlpgrpc-response
            // TODO: actually perform the retry (with exp. backoff) instead of
            // delegating it to the caller. Ideally the retry loop lives in a
            // transport-agnostic layer shared with the HTTP transport.
            return switch (f.toZigError()) {
                error.Cancelled,
                error.DeadlineExceeded,
                error.Aborted,
                error.OutOfRange,
                error.Unavailable,
                error.DataLoss,
                // RESOURCE_EXHAUSTED is retryable only when the server signals
                // it via RetryInfo; we don't parse trailers, so treat as nonretryable.
                // error.ResourceExhausted,
                => error.RetryableStatusCodeInResponse,
                else => error.NonRetryableStatusCodeInResponse,
            };
        },
        .operation_failed => {
            log.err("gRPC batch operation failed (no status available)", .{});
            return error.NonRetryableStatusCodeInResponse;
        },
        // Local deadline elapsed: transient by definition.
        .timeout => return error.RetryableStatusCodeInResponse,
    }
}

/// Builds the gRPC channel credentials for the given configuration.
/// The decision is made by `configuration.pickCredential`; this function only
/// constructs the credential object the decision points to.
///
/// TODO: support UDS endpoints (e.g. "unix:/var/run/otel.sock"). Over UDS,
/// libgrpc's LOCAL credentials provide PRIVACY_AND_INTEGRITY (the TCP variant
/// used here only checks the peer is loopback and provides no encryption).
fn makeCredentials(arena: Allocator, io: std.Io, config: Configuration) !grpc.client.Credentials {
    const choice = configuration.pickCredential(config);
    log.debug("Selecting {t} credentials", .{choice});
    return switch (choice) {
        .insecure => .insecure(),
        // local_tcp is plaintext, but gRPC rejects the connection at handshake
        // time when the peer is not on loopback — so a misconfigured remote
        // endpoint fails closed instead of silently exfiltrating cleartext.
        .local_tcp => .localTCP(),
        .local_uds => .localUDS(),
        .ssl => makeSSLCredentials(arena, io, config),
    };
}

fn readFile(allocator: Allocator, io: std.Io, filename: []const u8) ![:0]u8 {
    const max_size: usize = 1 << 20; // 1MiB

    return std.Io.Dir.cwd().readFileAllocOptions(
        io,
        filename,
        allocator,
        .limited(max_size),
        .of(u8),
        0,
    );
}

/// Builds SSL credentials from the configured PEM files.
///
/// Lifetime: gRPC copies `pem_root_certs` internally, but the client
/// `cert_chain` and `private_key` buffers passed via SSLKeyCertPair are
/// retained by reference (see grpc/src/core/credentials/transport/ssl/
/// ssl_credentials.cc::build_config). They must outlive the returned
/// credentials. The caller passes an arena freed only after
/// `credentials.deinit()` to satisfy this — `send()` arranges that ordering.
fn makeSSLCredentials(arena: Allocator, io: std.Io, config: Configuration) !grpc.client.Credentials {
    var root_certs: ?[:0]u8 = null;
    var client_key_cert: ?*grpc.SSLKeyCertPair = null;

    if (config.server_root_certificates_filename) |filename|
        root_certs = try readFile(arena, io, filename);
    if ((config.client_certificate_filename == null) != (config.client_private_key_filename == null))
        return error.IncompleteClientCertificateConfiguration;
    if (config.client_certificate_filename) |cert_filename| {
        if (config.client_private_key_filename) |key_filename| {
            client_key_cert = try arena.create(grpc.SSLKeyCertPair);
            client_key_cert.?.private_key = try readFile(arena, io, key_filename);
            client_key_cert.?.certificate_chain = try readFile(arena, io, cert_filename);
        }
    }
    log.debug("SSL: {s}, {s} a client key/certificate pair", .{
        if (root_certs != null) "using configured server root certificates" else "using server root certificates from GRPC_DEFAULT_SSL_ROOTS_FILE_PATH or system directories",
        if (client_key_cert != null) "with" else "without",
    });
    return .ssl(root_certs, client_key_cert);
}

test {
    // Pull config tests into this module's test suite so they run regardless
    // of which gRPC backend is selected at build time.
    _ = @import("config.zig");
}
