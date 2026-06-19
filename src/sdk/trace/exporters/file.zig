//! OTLP File exporter for traces.
//!
//! This exporter uses the generic OTLP file exporter to write trace data
//! to a file in JSON Lines format.

const std = @import("std");

const log = std.log.scoped(.file_exporter);

const trace = @import("../../../api/trace.zig");
const Resource = @import("../../../resource.zig").Resource;

const SpanExporter = @import("../span_exporter.zig").SpanExporter;

const otlp = @import("../../../otlp.zig");
const pbtrace = @import("opentelemetry-proto").trace_v1;
const pbcollector_trace = @import("opentelemetry-proto").collector_trace_v1;

// Import the conversion functions from the OTLP exporter
const otlp_exporter = @import("otlp.zig");
const toProtobufSpan = otlp_exporter.toProtobufSpan;
const toProtobufResource = otlp_exporter.toProtobufResource;

/// File exporter for traces using OTLP JSON Lines format.
pub const FileExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    resource: Resource,
    file: std.Io.File,
    owns_file: bool,

    pub const Options = struct {
        /// Path to the output file. If null, writes to stdout.
        file_path: ?[]const u8 = null,
        /// If true and file exists, append to it. Otherwise truncate.
        append: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, resource: Resource, options: Options) !Self {
        const file = if (options.file_path) |path| blk: {
            const flags: std.Io.Dir.CreateFileOptions = if (options.append)
                .{ .read = true, .truncate = false, .lock = .exclusive }
            else
                .{ .read = true, .truncate = true };
            break :blk try std.Io.Dir.cwd().createFile(io, path, flags);
        } else std.Io.File.stdout();

        return Self{
            .allocator = allocator,
            .io = io,
            .resource = resource,
            .file = file,
            .owns_file = options.file_path != null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_file) {
            self.file.close(self.io);
        }
    }

    pub fn spanExporter(self: *Self) SpanExporter {
        return SpanExporter{
            .ptr = self,
            .vtable = &.{
                .exportSpansFn = exportSpans,
                .shutdownFn = shutdown,
            },
        };
    }

    pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Convert spans to OTLP protobuf format
        var pb_spans: std.ArrayList(pbtrace.Span) = .empty;
        defer pb_spans.deinit(self.allocator);

        for (spans) |span| {
            const pb_span = try toProtobufSpan(self.allocator, span);
            try pb_spans.append(self.allocator, pb_span);
        }

        // Build scope spans
        var scope_spans: std.ArrayList(pbtrace.ScopeSpans) = .empty;
        defer scope_spans.deinit(self.allocator);

        try scope_spans.append(self.allocator, pbtrace.ScopeSpans{
            .scope = .{
                .name = "",
                .version = "",
            },
            .spans = pb_spans,
            .schema_url = "",
        });

        // Build resource spans
        const pb_resource = try toProtobufResource(self.allocator, self.resource);

        var resource_spans: std.ArrayList(pbtrace.ResourceSpans) = .empty;
        defer resource_spans.deinit(self.allocator);

        try resource_spans.append(self.allocator, pbtrace.ResourceSpans{
            .resource = pb_resource,
            .scope_spans = scope_spans,
            .schema_url = "",
        });

        var service_req = pbcollector_trace.ExportTraceServiceRequest{
            .resource_spans = resource_spans,
        };
        defer service_req.deinit(self.allocator);

        // Wrap in OTLP Signal.Data
        const signal_data = otlp.Signal.Data{
            .traces = service_req,
        };

        // Write using the OTLP ExportFile function
        try otlp.ExportFile(self.allocator, self.io, signal_data, &self.file);
    }

    pub fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.owns_file) {
            self.file.close(self.io);
            self.owns_file = false;
        }
    }
};

test "FileExporter init and deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var file_exporter = try FileExporter.init(allocator, io, Resource.empty(), .{});
    defer file_exporter.deinit();
}
