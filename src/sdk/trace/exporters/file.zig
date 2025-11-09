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
    resource: Resource,
    file: std.fs.File,
    owns_file: bool,

    pub const Options = struct {
        /// Path to the output file. If null, writes to stdout.
        file_path: ?[]const u8 = null,
        /// If true and file exists, append to it. Otherwise truncate.
        append: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, resource: Resource, options: Options) !Self {
        const file = if (options.file_path) |path| blk: {
            const flags: std.fs.File.CreateFlags = if (options.append)
                .{ .read = true, .truncate = false }
            else
                .{ .read = true, .truncate = true };
            break :blk try std.fs.cwd().createFile(path, flags);
        } else std.io.getStdOut();

        return Self{
            .allocator = allocator,
            .resource = resource,
            .file = file,
            .owns_file = options.file_path != null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_file) {
            self.file.close();
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
        var pb_spans = std.ArrayList(pbtrace.Span).init(self.allocator);
        defer pb_spans.deinit();

        for (spans) |span| {
            const pb_span = try toProtobufSpan(self.allocator, span);
            try pb_spans.append(pb_span);
        }

        // Build scope spans
        var scope_spans = std.ArrayList(pbtrace.ScopeSpans).init(self.allocator);
        defer scope_spans.deinit();

        try scope_spans.append(pbtrace.ScopeSpans{
            .scope = .{
                .name = "",
                .version = "",
            },
            .spans = pb_spans,
            .schema_url = "",
        });

        // Build resource spans
        const pb_resource = try toProtobufResource(self.allocator, self.resource);

        var resource_spans = std.ArrayList(pbtrace.ResourceSpans).init(self.allocator);
        defer resource_spans.deinit();

        try resource_spans.append(pbtrace.ResourceSpans{
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
        try otlp.ExportFile(self.allocator, signal_data, &self.file);
    }

    pub fn shutdown(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.owns_file) {
            self.file.close();
        }
    }
};

test "FileExporter init and deinit" {
    const allocator = std.testing.allocator;

    var file_exporter = try FileExporter.init(allocator, Resource.empty(), .{});
    defer file_exporter.deinit();
}
