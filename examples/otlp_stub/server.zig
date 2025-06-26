const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const otlp = @import("opentelemetry-sdk").otlp;
const protobuf = @import("protobuf");
const pb = @import("opentelemetry-proto");

pub fn OtlpStubServer(comptime RequestType: type, signal: otlp.Signal) type {
    return struct {
        allocator: Allocator,
        port: u16,
        on_export: *const fn (req: *RequestType) void,
        listener: ?net.Server = null,

        const Self = @This();

        pub fn init(
            allocator: Allocator,
            port: u16,
            on_export: *const fn (req: *RequestType) void,
        ) !*Self {
            const self = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .port = port,
                .on_export = on_export,
            };
            var address = try net.Address.resolveIp("127.0.0.1", self.port);
            self.listener = try address.listen(.{ .reuse_address = true });

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.listener) |*l| l.deinit();
            self.allocator.destroy(self);
        }

        pub fn start(self: *@This(), stop: *std.atomic.Value(bool)) !void {
            while (!stop.load(.acquire)) {
                defer stop.store(false, .release);

                var conn = try self.listener.?.accept();
                defer conn.stream.close();
                // Read HTTP request (very basic, just enough for OTLP exporter)
                var buf: [4096]u8 = undefined;

                var server = std.http.Server.init(conn, &buf);
                var request = try server.receiveHead();

                try request.respond(okResponeBody(self.allocator, signal), .{ .status = .ok });
            }
        }

        fn okResponeBody(allocator: Allocator, input: otlp.Signal) []const u8 {
            switch (input) {
                .metrics => {
                    const p = pb.collector_metrics.ExportMetricsServiceResponse{};
                    return p.encode(allocator) catch unreachable;
                },
                .traces => {
                    const p = pb.collector_trace.ExportTraceServiceResponse{};
                    return p.encode(allocator) catch unreachable;
                },
                .logs => {
                    const p = pb.collector_logs.ExportLogsServiceResponse{};
                    return p.encode(allocator) catch unreachable;
                },
            }
        }
    };
}

// Type aliases for convenience
pub const MetricsStubServer = OtlpStubServer(pb.collector_metrics.ExportMetricsServiceRequest, .metrics);
// For traces/logs, add similar aliases with appropriate protobuf types.
