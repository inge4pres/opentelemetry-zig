const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");

const MeterProvider = @import("meter.zig").MeterProvider;
const reader = @import("reader.zig");
const MetricReadError = reader.MetricReadError;

pub const ExportResult = enum {
    Success,
    Failure,
};

pub const MetricExporter = struct {
    const Self = @This();
    exporter: *ExporterIface,
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    var exportCompleted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    pub fn new(exporter: *ExporterIface) Self {
        return Self{
            .exporter = exporter,
        };
    }

    /// ExportBatch exports a batch of metrics data.
    /// The passed metrics data is cleaned up by the caller, so it must be copied.
    pub fn exportBatch(self: Self, metrics: pbmetrics.MetricsData) ExportResult {
        if (self.hasShutDown.load(.acquire)) {
            // When shutdown has already been called, calling export should be a failure.
            // https://opentelemetry.io/docs/specs/otel/metrics/sdk/#shutdown-2
            return ExportResult.Failure;
        }
        // Acquire the lock to ensure that forceFlush is waiting for export to complete.
        _ = exportCompleted.load(.acquire);
        defer exportCompleted.store(true, .release);

        // Call the exporter function to process metrics data.
        self.exporter.exportBatch(metrics) catch |e| {
            std.debug.print("MetricExporter exportBatch failed: {?}\n", .{e});
            return ExportResult.Failure;
        };
        return ExportResult.Success;
    }
    // Ensure that all the data is flushed to the destination.
    pub fn forceFlush(_: Self, timeout_ms: u64) !void {
        const start = std.time.milliTimestamp(); // Milliseconds
        const timeout: i64 = @intCast(timeout_ms);
        while (std.time.milliTimestamp() < start + timeout) {
            if (exportCompleted.load(.acquire)) {
                return;
            } else std.time.sleep(std.time.ns_per_ms);
        }
        return MetricReadError.ForceFlushTimedOut;
    }

    pub fn shutdown(self: *Self) void {
        self.hasShutDown.store(true, .monotonic);
    }
};

// test harness to build a noop exporter.
fn noopExporter(_: *ExporterIface, _: pbmetrics.MetricsData) MetricReadError!void {
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(_: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
    if (metrics.resource_metrics.items.len != 1) {
        return MetricReadError.ExportFailed;
    } // only one resource metrics is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: *ExporterIface, _: pbmetrics.MetricsData) MetricReadError!void {
    // Sleep for 1 second to simulate a slow exporter.
    std.time.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "build no-op metric exporter" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = MetricExporter.new(&noop);

    const metrics = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metrics.deinit();
    const result = me.exportBatch(metrics);
    try std.testing.expectEqual(ExportResult.Success, result);
}

test "exported metrics by calling metric reader" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var mock = ExporterIface{ .exportFn = mockExporter };
    const me = MetricExporter.new(&mock);

    var rdr = reader.MetricReader{ .allocator = std.testing.allocator, .exporter = me };
    defer rdr.shutdown();

    try mp.addReader(&rdr);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    // only 1 metric should be in metrics data when we use the mock exporter
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, null);

    try rdr.collect();
}

test "metric exporter force flush succeeds" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = MetricExporter.new(&noop);

    const metrics = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metrics.deinit();
    const result = me.exportBatch(metrics);
    try std.testing.expectEqual(ExportResult.Success, result);

    try me.forceFlush(1000);
}

fn backgroundRunner(me: *MetricExporter, metrics: pbmetrics.MetricsData) !void {
    _ = me.exportBatch(metrics);
}

test "metric exporter force flush fails" {
    var wait = ExporterIface{ .exportFn = waiterExporter };
    var me = MetricExporter.new(&wait);

    const metrics = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metrics.deinit();
    var bg = try std.Thread.spawn(
        .{},
        backgroundRunner,
        .{ &me, metrics },
    );
    bg.detach();

    const e = me.forceFlush(0);
    try std.testing.expectError(MetricReadError.ForceFlushTimedOut, e);
}

/// ExporterIface is the interface for exporting metrics.
/// Implementations can be satisfied by any type by having a member field of type
/// ExporterIface and a member function exportBatch with the correct signature.
pub const ExporterIface = struct {
    exportFn: *const fn (*ExporterIface, pbmetrics.MetricsData) MetricReadError!void,

    pub fn exportBatch(self: *ExporterIface, data: pbmetrics.MetricsData) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

/// ImMemoryExporter stores in memory the metrics data that is exported to it.
/// The memory representation uses the protobuf structures as defined by OTLP.
pub const ImMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayList(pbmetrics.ResourceMetrics),
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = std.ArrayList(pbmetrics.ResourceMetrics).init(allocator),
            .exporter = ExporterIface{
                .exportFn = exportBatch,
            },
        };
        return s;
    }
    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.allocator.destroy(self);
    }

    fn exportBatch(iface: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);

        self.data.clearRetainingCapacity();
        // var rm = metrics.resource_metrics;
        // const owned = rm.toOwnedSlice() catch |e|{
        //     std.debug.print("error cloning to memory, allocation error: {?}", .{e});
        //     return MetricReadError.ExportFailed;
        // };
        // self.data.appendSlice(owned) catch |e| {
        //     std.debug.print("error exporting to memory, allocation error: {?}", .{e});
        //     return MetricReadError.ExportFailed;
        // };
        
        const rm = self.allocator.dupe(pbmetrics.ResourceMetrics, metrics.resource_metrics.items) catch |e| {
                std.debug.print("error cloning to memory, allocation error: {?}", .{e});
                return MetricReadError.ExportFailed;
        };
        defer self.allocator.free(rm);
        // for(rm) |i| {
        //     self.data.append(i) catch |e| {
        //         std.debug.print("error exporting to memory, allocation error: {?}", .{e});
        //         return MetricReadError.ExportFailed;
        //     };
        // }
        self.data.items = rm[0..];
        return;
    }

    pub fn fetch(self: *Self) []pbmetrics.ResourceMetrics {
        std.debug.print("when fetching, we have self.data with {any}!\n", .{self.data.items[0].scope_metrics});

        return self.data.items;
    }
};

test "in memory exporter stores data" {
    var inMemExporter = try ImMemoryExporter.init(std.testing.allocator);
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
    try metricsData.resource_metrics.append(resource);

    const result = exporter.exportBatch(metricsData);
    // Calling immediately deinit because that's what MetricReader.collect() does
    // after calling the exportBatch implementation.
    metricsData.deinit();

    std.debug.assert(result == .Success);
    std.debug.print("exportBatch was successful!\n", .{});

    std.debug.print("fetching from InMem exporter!\n", .{});
    const data = inMemExporter.fetch();

    std.debug.assert(data.len == 1);
    const entry = data[0];

    std.debug.assert(entry.scope_metrics.items.len == 1);
    std.debug.assert(entry.scope_metrics.items[0].metrics.items[0].data.?.sum.data_points.items.len == 2);

    try std.testing.expectEqual(pbmetrics.Sum, @TypeOf(entry.scope_metrics.items[0].metrics.items[0].data.?.sum));
    const sum: pbmetrics.Sum = entry.scope_metrics.items[0].metrics.items[0].data.?.sum;

    try std.testing.expectEqual(sum.data_points.items[0].value.?.as_int, 1);
}
