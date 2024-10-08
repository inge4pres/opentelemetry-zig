const std = @import("std");
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const reader = @import("reader.zig");
const MetricExporter = reader.MetricExporter;
const MetricReadError = reader.MetricReadError;

pub const ImMemoryExporter = struct {
    const Self = @This();

    var data: std.ArrayList(pbmetrics.ResourceMetrics) = std.ArrayList(pbmetrics.ResourceMetrics).init(std.heap.page_allocator);

    pub fn GetMetricExporter() MetricExporter {
        return MetricExporter{
            .exporter = Self.exportBatch,
        };
    }

    fn exportBatch(metrics: pbmetrics.MetricsData) MetricReadError!void {
        Self.data.clearRetainingCapacity();
        Self.data.appendSlice(metrics.resource_metrics.items) catch |e| {
            std.debug.print("Failed to export metrics in memory: {}\n", .{e});
            return MetricReadError.ExportFailed;
        };
    }

    pub fn Data() []pbmetrics.ResourceMetrics {
        return Self.data.items;
    }
};
