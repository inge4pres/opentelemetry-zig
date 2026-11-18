//! Configuration shared by every gRPC transport implementation.

const std = @import("std");

/// gRPC message compression: applied per message by gRPC itself and announced
/// in the `grpc-encoding` header, not gzip applied to the protobuf bytes as is
/// done over HTTP.
pub const Compression = enum { none, gzip };

pub const Configuration = struct {
    /// The endpoint to send the data to.
    /// Must be in the form of "host:port", without scheme.
    endpoint: []const u8 = "localhost:4317",

    /// Selects the connection security credentials.
    ///   true:  insecure credentials (plaintext, no peer verification).
    ///   false: SSL credentials (TLS, using the cert/key fields below if set,
    ///          otherwise the system trust store).
    ///   null (default): infer from the other fields —
    ///     - if any of the cert/key filenames below is set, use SSL;
    ///     - otherwise use LOCAL_TCP, which is plaintext but rejected by
    ///       gRPC at handshake time when the peer is not on loopback.
    ///       This makes the default safe for a local collector while
    ///       refusing to silently send cleartext to a remote host.
    insecure: ?bool = null,

    /// The maximum duration of batch exporting.
    timeout_sec: u64 = 10,

    /// Sent as metadata with every call, e.g. an `authorization` header.
    /// gRPC requires lowercase keys, so backends lowercase the header names,
    /// which are case-insensitive.
    headers: []const std.http.Header = &.{},

    /// Compression of the messages sent.
    compression: Compression = .none,

    /// CA chain used to verify server certificate (PEM format).
    ///
    /// If unset, the libgrpc implementation will first try to dereference the
    /// file pointed by the GRPC_DEFAULT_SSL_ROOTS_FILE_PATH environment variable,
    /// and if that fails, try to get the roots set by grpc_override_ssl_default_roots.
    /// Eventually, if all these fail, it will try to get the roots from
    /// a well-known place on disk (in the grpc install directory).
    server_root_certificates_filename: ?[]const u8 = null,

    /// Client certificate used to authenticate the client (PEM format).
    client_certificate_filename: ?[]const u8 = null,

    /// Client private key used to authenticate the client (PEM format).
    client_private_key_filename: ?[]const u8 = null,
};

/// Kinds of gRPC channel credentials a backend may need to build.
/// See `Configuration.insecure` for the full truth table.
pub const CredentialChoice = enum { insecure, ssl, local_tcp, local_uds };

pub fn pickCredential(config: Configuration) CredentialChoice {
    if (config.insecure) |insecure| {
        return if (insecure) .insecure else .ssl;
    }
    if (config.server_root_certificates_filename != null or
        config.client_certificate_filename != null or
        config.client_private_key_filename != null) return .ssl;
    return .local_tcp;
}

test pickCredential {
    // Explicit insecure ignores any TLS files that happen to be set.
    try std.testing.expectEqual(CredentialChoice.insecure, pickCredential(.{ .insecure = true }));
    try std.testing.expectEqual(CredentialChoice.insecure, pickCredential(.{
        .insecure = true,
        .server_root_certificates_filename = "/some/ca.pem",
        .client_certificate_filename = "/some/cert.pem",
        .client_private_key_filename = "/some/key.pem",
    }));

    // Explicit secure forces SSL even when no TLS files are configured.
    try std.testing.expectEqual(CredentialChoice.ssl, pickCredential(.{ .insecure = false }));

    // When `insecure` is unset, the presence of any TLS file implies SSL.
    inline for (.{
        "server_root_certificates_filename",
        "client_certificate_filename",
        "client_private_key_filename",
    }) |field_name| {
        var cfg: Configuration = .{};
        @field(cfg, field_name) = "/some/path.pem";
        try std.testing.expectEqual(CredentialChoice.ssl, pickCredential(cfg));
    }

    // Nothing set: fall back to LOCAL_TCP (gRPC will reject non-loopback peers).
    try std.testing.expectEqual(CredentialChoice.local_tcp, pickCredential(.{}));
}
