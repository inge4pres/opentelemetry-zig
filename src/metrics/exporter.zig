const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");

const reader = @import("reader.zig");
const MetricExporter = reader.MetricExporter;
const MetricReadError = reader.MetricReadError;

/// ExporterIface is the type representing the interface for exporting metrics.
/// Implementations can be achieved by any type by having a member field of type
/// ExporterIface and a member function exporttBatch with the same signature.
pub const ExporterIface = struct {
    exportFn: *const fn (*ExporterIface, pbmetrics.MetricsData) MetricReadError!void,

    pub fn exportBatch(self: *ExporterIface, data: pbmetrics.MetricsData) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

pub const ImMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayList(pbmetrics.ResourceMetrics) = undefined,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .data = std.ArrayList(pbmetrics.ResourceMetrics).init(allocator),
            .exporter = ExporterIface{
                .exportFn = exportBatch,
            },
        };
    }
    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }

    fn exportBatch(iface: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
        const self: *Self = @fieldParentPtr("exporter", iface);

        self.data.clearRetainingCapacity();
        self.data.appendSlice(metrics.resource_metrics.items) catch |e| {
            std.debug.print("error exporting to memory, allocation error: {?}", .{e});
            return MetricReadError.ExportFailed;
        };
        return;
    }

    pub fn fetch(self: Self) []pbmetrics.ResourceMetrics {
        return self.data.items;
    }
};

test "in memory exporter stores data" {
    var inMemExporter = ImMemoryExporter.init(std.testing.allocator);
    defer inMemExporter.deinit();

    const exporter = MetricExporter.new(&inMemExporter.exporter);

    const howMany: usize = 2;
    const dp = try std.testing.allocator.alloc(pbmetrics.NumberDataPoint, howMany);
    dp[0] = pbmetrics.NumberDataPoint{
        .attributes = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator),
        .exemplars = std.ArrayList(pbmetrics.Exemplar).init(std.testing.allocator),
        .value = .{ .as_int = @as(i64, 1) },
    };
    dp[1] = pbmetrics.NumberDataPoint{
        .attributes = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator),
        .exemplars = std.ArrayList(pbmetrics.Exemplar).init(std.testing.allocator),
        .value = .{ .as_int = @as(i64, 2) },
    };

    const metric = pbmetrics.Metric{
        .metadata = std.ArrayList(pbcommon.KeyValue).init(std.testing.allocator),
        .name = ManagedString.managed("test_metric"),
        .unit = ManagedString.managed("count"),
        .data = .{ .sum = pbmetrics.Sum{
            .data_points = std.ArrayList(pbmetrics.NumberDataPoint).fromOwnedSlice(std.testing.allocator, dp),
            .aggregation_temporality = .AGGREGATION_TEMPORALITY_CUMULATIVE,
        } },
    };

    var sm = pbmetrics.ScopeMetrics{
        .metrics = std.ArrayList(pbmetrics.Metric).init(std.testing.allocator),
    };
    try sm.metrics.append(metric);

    var resource = pbmetrics.ResourceMetrics{
        .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).init(std.testing.allocator),
    };
    try resource.scope_metrics.append(sm);

    var metricsData = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metricsData.deinit();
    try metricsData.resource_metrics.append(resource);

    const result = exporter.exportBatch(metricsData);
    std.debug.assert(result == .Success);
    const data = inMemExporter.fetch();

    std.debug.assert(data.len == 1);
    std.debug.assert(data[0].scope_metrics.items.len == 1);
}
