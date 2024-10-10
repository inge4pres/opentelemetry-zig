const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");

const reader = @import("reader.zig");
const MetricExporter = reader.MetricExporter;
const MetricReadError = reader.MetricReadError;
const ExportFn = reader.ExportFn;

pub fn ImMemoryExporter(allocator: std.mem.Allocator) type {
    return struct {
        const Self = @This();

        var global: std.ArrayList(pbmetrics.ResourceMetrics) = std.ArrayList(pbmetrics.ResourceMetrics).init(allocator);

        pub fn exporter() *const ExportFn {
            return Self.exportBatch;
        }

        fn exportBatch(metrics: pbmetrics.MetricsData) MetricReadError!void {
            Self.global.clearRetainingCapacity();
            Self.global.appendSlice(metrics.resource_metrics.items) catch |e| {
                std.debug.print("error exporting to memory, allocation error: {?}", .{e});
                return MetricReadError.ExportFailed;
            };
            return;
        }

        pub fn fetch() []pbmetrics.ResourceMetrics {
            return Self.global.items;
        }

        pub fn deinit() void {
            Self.global.deinit();
        }
    };
}

test "in memory exporter stores data" {
    const inMemExporter = ImMemoryExporter(std.testing.allocator);
    defer inMemExporter.deinit();

    const exporter = MetricExporter.new(inMemExporter.exporter());

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

    try exporter.exporter(metricsData);
    const data = inMemExporter.fetch();

    std.debug.assert(data.len == 1);
    std.debug.assert(data[0].scope_metrics.items.len == 1);
}
