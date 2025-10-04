const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.net;
const otlp = @import("opentelemetry-sdk").otlp;
const protobuf = @import("protobuf");
const pb = @import("opentelemetry-proto");

pub fn OTLPStubServer(comptime RequestType: type, signal: otlp.Signal) type {
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
            var address = try net.Address.resolveIp("127.0.0.1", port);
            const self = try allocator.create(@This());
            self.* = .{
                .allocator = allocator,
                .port = port,
                .on_export = on_export,
                .listener = try address.listen(.{ .reuse_address = true }),
            };

            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.listener) |*l| l.deinit();
            self.allocator.destroy(self);
        }

        // Processes only 1 export request
        pub fn start(self: *@This()) !void {
            var conn = try self.listener.?.accept();
            defer conn.stream.close();
            // Read HTTP request (very basic, just enough for OTLP exporter)
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [4096]u8 = undefined;
            var conn_reader = conn.stream.reader(&read_buffer);
            var conn_writer = conn.stream.writer(&write_buffer);

            var server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);
            var request = try server.receiveHead();

            var body_buffer: [8192]u8 = undefined;
            const reader = request.readerExpectNone(&body_buffer);
            const body = try reader.allocRemaining(self.allocator, .unlimited);
            defer self.allocator.free(body);

            var body_reader = std.Io.Reader.fixed(body);
            var body_msg: RequestType = try protobuf.decode(RequestType, &body_reader, self.allocator);
            defer body_msg.deinit(self.allocator);

            self.on_export(&body_msg);

            try request.respond(
                try okResponeBody(self.allocator, signal),
                .{ .status = .ok },
            );
        }

        fn okResponeBody(allocator: Allocator, input: otlp.Signal) ![]const u8 {
            var writer_ctx = std.Io.Writer.Allocating.init(allocator);
            defer writer_ctx.deinit();
            switch (input) {
                .metrics => {
                    const p = pb.collector_metrics_v1.ExportMetricsServiceResponse{};
                    try p.encode(&writer_ctx.writer, allocator);
                },
                .traces => {
                    const p = pb.collector_trace_v1.ExportTraceServiceResponse{};
                    try p.encode(&writer_ctx.writer, allocator);
                },
                .logs => {
                    const p = pb.collector_logs_v1.ExportLogsServiceResponse{};
                    try p.encode(&writer_ctx.writer, allocator);
                },
            }
            try writer_ctx.writer.flush();
            return try writer_ctx.toOwnedSlice();
        }
    };
}

// Type aliases for convenience
pub const MetricsStubServer = OTLPStubServer(pb.collector_metrics_v1.ExportMetricsServiceRequest, .metrics);
// For traces/logs, add similar aliases with appropriate protobuf types.
