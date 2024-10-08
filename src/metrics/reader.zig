const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbresource = @import("../opentelemetry/proto/resource/v1.pb.zig");
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../pbutils.zig");
const instr = @import("instrument.zig");
const Instrument = instr.Instrument;
const Kind = instr.Kind;
const MeterProvider = @import("meter.zig").MeterProvider;
const view = @import("view.zig");

/// ExportError represents the failure to export data points
/// to a destination.
pub const MetricReadError = error{
    CollectFailedOnMissingMeterProvider,
    ExportFailed,
    ForceFlushTimedOut,
};

/// MetricReader reads metrics' data from a MeterProvider.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#metricreader
pub const MetricReader = struct {
    allocator: std.mem.Allocator,
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    temporality: *const fn (Kind) view.Temporality = view.DefaultTemporalityFor,
    aggregation: *const fn (Kind) view.Aggregation = view.DefaultAggregationFor,
    // Signal that shutdown has been called.
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Exporter is the destination of the metrics data.
    // FIXME
    // the default metric exporter should be the PeriodicExporter
    exporter: MetricExporter = MetricExporter.new(noopExporter),

    const Self = @This();

    pub fn collect(self: Self) !void {
        if (self.hasShutDown.load(.acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        var metricsData = pbmetrics.MetricsData{ .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(self.allocator) };
        defer metricsData.deinit();

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            var mpIter = mp.meters.valueIterator();
            while (mpIter.next()) |meter| {
                // Create a resourceMetric for each Meter.
                var rm = pbmetrics.ResourceMetrics{
                    .resource = pbresource.Resource{ .attributes = if (meter.attributes) |a| a.values else std.ArrayList(pbcommon.KeyValue).init(self.allocator) },
                    .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).init(self.allocator),
                };
                // We only use a single ScopeMetric for each ResourceMetric.
                var sm = pbmetrics.ScopeMetrics{
                    .metrics = std.ArrayList(pbmetrics.Metric).init(self.allocator),
                };
                var instrIter = meter.instruments.valueIterator();
                while (instrIter.next()) |i| {
                    if (self.toMetric(i.*)) |metric| {
                        try sm.metrics.append(metric);
                    } else |err| {
                        std.debug.print("MetricReader collect: failed conversion to proto Metric: {?}\n", .{err});
                    }
                }
                try rm.scope_metrics.append(sm);
                try metricsData.resource_metrics.append(rm);
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }

        switch (self.exporter.exportBatch(metricsData)) {
            ExportResult.Success => return,
            ExportResult.Failure => return MetricReadError.ExportFailed,
        }
    }

    pub fn shutdown(self: *Self) void {
        self.collect() catch |e| {
            std.debug.print("MetricReader shutdown: error while collecting metrics: {?}\n", .{e});
        };
        self.hasShutDown.store(true, .release);
        self.exporter.shutdown();
    }

    fn toMetric(self: Self, i: *Instrument) !pbmetrics.Metric {
        return pbmetrics.Metric{
            .name = ManagedString.managed(i.opts.name),
            .description = if (i.opts.description) |d| ManagedString.managed(d) else .Empty,
            .unit = if (i.opts.unit) |u| ManagedString.managed(u) else .Empty,
            .data = switch (i.data) {
                .Counter_u16 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                    .data_points = try sumDataPoints(self.allocator, u16, i.data.Counter_u16),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                    .is_monotonic = true,
                } },
                .Counter_u32 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                    .data_points = try sumDataPoints(self.allocator, u32, i.data.Counter_u32),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                    .is_monotonic = true,
                } },

                .Counter_u64 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                    .data_points = try sumDataPoints(self.allocator, u64, i.data.Counter_u64),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                    .is_monotonic = true,
                } },
                .Histogram_u16 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(self.allocator, u16, i.data.Histogram_u16),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                } },

                .Histogram_u32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(self.allocator, u32, i.data.Histogram_u32),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                } },

                .Histogram_u64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(self.allocator, u64, i.data.Histogram_u64),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                } },

                .Histogram_f32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(self.allocator, f32, i.data.Histogram_f32),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                } },

                .Histogram_f64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(self.allocator, f64, i.data.Histogram_f64),
                    .aggregation_temporality = self.temporality(i.kind).toProto(),
                } },
                else => unreachable,
            },
            // Metadata used for internal translations and we can discard for now.
            // Consumers of SDK should not rely on this field.
            .metadata = std.ArrayList(pbcommon.KeyValue).init(self.allocator),
        };
    }
};

fn sumDataPoints(allocator: std.mem.Allocator, comptime T: type, c: *instr.Counter(T)) !std.ArrayList(pbmetrics.NumberDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.NumberDataPoint).init(allocator);
    var iter = c.cumulative.iterator();
    while (iter.next()) |measure| {
        var attrs = std.ArrayList(pbcommon.KeyValue).init(allocator);
        // Attributes are stored as key of the hasmap.
        if (measure.key_ptr.*) |kv| {
            try attrs.appendSlice(kv.values.items);
        }
        const dp = pbmetrics.NumberDataPoint{
            .attributes = attrs,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .value = .{ .as_int = @intCast(measure.value_ptr.*) },

            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        try dataPoints.append(dp);
    }
    return dataPoints;
}

fn histogramDataPoints(allocator: std.mem.Allocator, comptime T: type, h: *instr.Histogram(T)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.HistogramDataPoint).init(allocator);
    var iter = h.cumulative.iterator();
    while (iter.next()) |measure| {
        var attrs = std.ArrayList(pbcommon.KeyValue).init(allocator);
        // Attributes are stored as key of the hashmap.
        if (measure.key_ptr.*) |kv| {
            try attrs.appendSlice(kv.values.items);
        }
        var dp = pbmetrics.HistogramDataPoint{
            .attributes = attrs,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .count = h.counts.get(measure.key_ptr.*) orelse 0,
            .sum = switch (@TypeOf(h.*)) {
                instr.Histogram(u16), instr.Histogram(u32), instr.Histogram(u64) => @as(f64, @floatFromInt(measure.value_ptr.*)),
                instr.Histogram(f32), instr.Histogram(f64) => @as(f64, @floatCast(measure.value_ptr.*)),
                else => unreachable,
            },
            .bucket_counts = std.ArrayList(u64).init(allocator),
            .explicit_bounds = std.ArrayList(f64).init(allocator),
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        if (h.bucket_counts.get(measure.key_ptr.*)) |b| {
            try dp.bucket_counts.appendSlice(b);
        }
        try dp.explicit_bounds.appendSlice(h.buckets);

        try dataPoints.append(dp);
    }
    return dataPoints;
}

test "metric reader shutdown prevents collect() to execute" {
    var reader = MetricReader{ .allocator = std.testing.allocator };
    const e = reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    reader.shutdown();
    try reader.collect();
}

test "metric reader collects data from meter provider" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    var reader = MetricReader{
        .allocator = std.testing.allocator,
        .exporter = MetricExporter.new(noopExporter),
    };
    defer reader.shutdown();

    try mp.addReader(&reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, null);

    var hist = try m.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";
    const attrs = try pbutils.WithAttributes(
        std.testing.allocator,
        .{ "amazing", v },
    );
    try hist.record(10, attrs);

    const attrs2 = try pbutils.WithAttributes(
        std.testing.allocator,
        .{ "wonderful", v },
    );
    var histFloat = try m.createHistogram(f64, .{ .name = "my-histogram-float" });
    try histFloat.record(10.0, attrs2);

    try reader.collect();
}

fn deltaTemporality(_: Kind) view.Temporality {
    return view.Temporality.Delta;
}

const InMemoryExporter = @import("exporter.zig").ImMemoryExporter;

test "metric reader custom temporality" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    var reader = MetricReader{
        .allocator = std.testing.allocator,
        .exporter = InMemoryExporter.GetMetricExporter(),
        .temporality = deltaTemporality,
    };
    defer reader.shutdown();

    try mp.addReader(&reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, null);

    try reader.collect();

    const data = InMemoryExporter.Data();
    std.debug.assert(data.len == 1);
}

pub const ExportResult = enum {
    Success,
    Failure,
};

pub const ExportFn = fn (pbmetrics.MetricsData) MetricReadError!void;

pub const MetricExporter = struct {
    const Self = @This();
    exporter: *const ExportFn,
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    var exportCompleted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    pub fn new(exporter: *const ExportFn) Self {
        return Self{
            .exporter = exporter,
        };
    }

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
        self.exporter(metrics) catch |e| {
            std.debug.print("MetricExporter exportBatch failed: {?}\n", .{e});
            return ExportResult.Failure;
        };
        return ExportResult.Success;
    }
    // Ensure that all the data is flushed to the destination.
    pub fn forceFlush(_: Self, timeout_ms: u64) !void {
        const start = std.time.milliTimestamp(); // Miliseconds
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
fn noopExporter(_: pbmetrics.MetricsData) MetricReadError!void {
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(metrics: pbmetrics.MetricsData) MetricReadError!void {
    if (metrics.resource_metrics.items.len != 1) {
        return MetricReadError.ExportFailed;
    } // only one resource metrics is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: pbmetrics.MetricsData) MetricReadError!void {
    // Sleep for 1 second to simulate a slow exporter.
    std.time.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "build no-op metric exporter" {
    const exporter: *const ExportFn = noopExporter;
    var me = MetricExporter.new(exporter);

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
    const me = MetricExporter.new(mockExporter);

    var reader = MetricReader{ .allocator = std.testing.allocator, .exporter = me };
    defer reader.shutdown();

    try mp.addReader(&reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    // only 1 metric should be in metrics data when we use the mock exporter
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, null);

    try reader.collect();
}

test "metric exporter force flush succeeds" {
    var me = MetricExporter.new(noopExporter);

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
    var me = MetricExporter.new(waiterExporter);

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
