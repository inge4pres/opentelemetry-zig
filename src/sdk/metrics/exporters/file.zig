//! OTLP File exporter for metrics.
//!
//! This exporter uses the generic OTLP file exporter to write metrics data
//! to a file in JSON Lines format.

const std = @import("std");

const log = std.log.scoped(.file_exporter);

const Measurements = @import("../../../api/metrics/measurement.zig").Measurements;

const view = @import("../view.zig");

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterImpl = @import("../exporter.zig").ExporterImpl;

const MetricReadError = @import("../reader.zig").MetricReadError;

const otlp = @import("../../../otlp.zig");
const pbmetrics = @import("opentelemetry-proto").metrics_v1;
const pbcollector_metrics = @import("opentelemetry-proto").collector_metrics_v1;

// Import the conversion functions from the OTLP exporter
const otlp_exporter = @import("otlp.zig");
const toProtobufMetric = otlp_exporter.toProtobufMetric;
const attributesToProtobufKeyValueList = otlp_exporter.attributesToProtobufKeyValueList;

/// File exporter for metrics using OTLP JSON Lines format.
pub const FileExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: ExporterImpl,
    temporality: view.TemporalitySelector,
    file: std.fs.File,
    owns_file: bool,

    pub const Options = struct {
        /// Path to the output file. If null, writes to stdout.
        file_path: ?[]const u8 = null,
        /// If true and file exists, append to it. Otherwise truncate.
        append: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, temporality: view.TemporalitySelector, options: Options) !*Self {
        const file = if (options.file_path) |path| blk: {
            const flags: std.fs.File.CreateFlags = if (options.append)
                .{ .read = true, .truncate = false }
            else
                .{ .read = true, .truncate = true };
            break :blk try std.fs.cwd().createFile(path, flags);
        } else std.fs.File.stdout();

        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .exporter = ExporterImpl{
                .exportFn = exportBatch,
            },
            .temporality = temporality,
            .file = file,
            .owns_file = options.file_path != null,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_file) {
            self.file.close();
        }
        self.allocator.destroy(self);
    }

    pub fn exportBatch(iface: *ExporterImpl, data: []Measurements) MetricReadError!void {
        const self: *Self = @fieldParentPtr("exporter", iface);

        // Cleanup the data after use, it is mandatory for all exporters as they own the data argument.
        defer {
            for (data) |*m| {
                m.deinit(self.allocator);
            }
            self.allocator.free(data);
        }

        // Convert measurements to OTLP protobuf format
        var resource_metrics = self.allocator.alloc(pbmetrics.ResourceMetrics, 1) catch |err| {
            log.err("failed to allocate memory for resource metrics: {s}", .{@errorName(err)});
            return MetricReadError.OutOfMemory;
        };

        var scope_metrics = try self.allocator.alloc(pbmetrics.ScopeMetrics, data.len);
        for (data, 0..) |measurement, i| {
            var metrics = std.ArrayList(pbmetrics.Metric).initCapacity(self.allocator, 1) catch |err| {
                log.err("failed to allocate memory for metrics: {s}", .{@errorName(err)});
                return MetricReadError.OutOfMemory;
            };
            metrics.appendAssumeCapacity(try toProtobufMetric(self.allocator, measurement, self.temporality));

            const attributes = try attributesToProtobufKeyValueList(self.allocator, measurement.scope.attributes);
            scope_metrics[i] = pbmetrics.ScopeMetrics{
                .scope = @import("opentelemetry-proto").common_v1.InstrumentationScope{
                    .name = (try self.allocator.dupe(u8, measurement.scope.name)),
                    .version = if (measurement.scope.version) |version|
                        try self.allocator.dupe(u8, version)
                    else
                        "",
                    .attributes = attributes.values,
                },
                .schema_url = if (measurement.scope.schema_url) |s| try self.allocator.dupe(u8, s) else "",
                .metrics = metrics,
            };
        }

        // Build metrics data structure
        resource_metrics[0] = pbmetrics.ResourceMetrics{
            .resource = .{},
            .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).fromOwnedSlice(scope_metrics),
            .schema_url = "",
        };

        var service_req = pbcollector_metrics.ExportMetricsServiceRequest{
            .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(resource_metrics),
        };
        defer service_req.deinit(self.allocator);

        // Wrap in OTLP Signal.Data
        const signal_data = otlp.Signal.Data{
            .metrics = service_req,
        };

        // Write using the OTLP ExportFile function
        otlp.ExportFile(self.allocator, signal_data, &self.file) catch |err| {
            log.err("failed to write metrics to file: {s}", .{@errorName(err)});
            return MetricReadError.ExportFailed;
        };
    }
};

test "FileExporter init and deinit" {
    const allocator = std.testing.allocator;

    const file_exporter = try FileExporter.init(allocator, view.DefaultTemporality, .{});
    defer file_exporter.deinit();
}

test "FileExporter export to file" {
    const allocator = std.testing.allocator;
    const test_file = "test_metrics_file.jsonl";

    // Clean up any existing test file
    std.fs.cwd().deleteFile(test_file) catch {};
    defer std.fs.cwd().deleteFile(test_file) catch {};

    const file_exporter = try FileExporter.init(allocator, view.DefaultTemporality, .{
        .file_path = test_file,
        .append = false,
    });
    defer file_exporter.deinit();

    // Create test measurement with properly allocated data
    // Note: Scope and instrument strings are borrowed, not owned, so we use literals
    const DataPoint = @import("../../../api/metrics/measurement.zig").DataPoint;
    var measurement = try allocator.alloc(DataPoint(i64), 1);
    measurement[0] = .{ .value = 42 };

    var metrics = try allocator.alloc(Measurements, 1);
    metrics[0] = .{
        .scope = .{
            .name = "test-meter",
            .version = "1.0",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{
            .name = "test-counter",
        },
        .data = .{ .int = measurement },
    };

    // Export the metrics
    try file_exporter.exporter.exportFn(&file_exporter.exporter, metrics);

    // Verify the file was created and contains data
    const file = try std.fs.cwd().openFile(test_file, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // Should contain expected JSON fields
    try std.testing.expect(std.mem.indexOf(u8, content, "resourceMetrics") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "test-counter") != null);
}
