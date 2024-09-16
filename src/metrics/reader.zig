const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../opentelemetry/proto/common/v1.pb.zig");
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
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
    // TODO add exporter
    // exporter: MetricExporter,

    const Self = @This();

    pub fn collect(self: Self) !void {
        if (self.hasShutDown.load(.acquire)) {
            // Shutdown has already been called so this is a no-op.
            return;
        }
        if (self.meterProvider) |mp| {
            // Collect the data from the meter provider.
            var mpIter = mp.meters.valueIterator();
            while (mpIter.next()) |meter| {
                var instrIter = meter.instruments.valueIterator();
                while (instrIter.next()) |i| {
                    const metric = try toMetric(self.allocator, i);
                    defer metric.metadata.deinit();
                }
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    pub fn shutdown(self: *Self) void {
        self.hasShutDown.store(true, .release);
    }

    fn toMetric(allocator: std.mem.Allocator, i: *Instrument) !pbmetrics.Metric {
        return pbmetrics.Metric{
            .name = ManagedString.managed(i.opts.name),
            .description = if (i.opts.description) |d| ManagedString.managed(d) else .Empty,
            .unit = if (i.opts.unit) |u| ManagedString.managed(u) else .Empty,
            .data = null,
            // .data = switch (i.data) {
            //     .Counter_u32 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
            //         .data_points = try sumDataPoints(allocator, u32, i.data.Counter_u32),
            //     } },
            //     else => unreachable,
            // },
            // Metadata used for internal translations and we can discard for now.
            // Consumers of SDK should not rely on this field.
            .metadata = std.ArrayList(pbcommon.KeyValue).init(allocator),
        };
    }
};

fn sumDataPoints(allocator: std.mem.Allocator, comptime T: type, c: instr.Counter(T)) !std.ArrayList(pbmetrics.NumberDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.NumberDataPoint).init(allocator);
    var iter = c.cumulative.iterator();
    while (iter.next()) |measure| {
        const dp = pbmetrics.NumberDataPoint{
            // Attributes are stored as key of the hasmap.
            .attributes = if (measure.key_ptr.*) |m| m.values else std.ArrayList(pbcommon.KeyValue).init(allocator),
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            .value = .{ .as_int = @intCast(measure.value_ptr.*) },

            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
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
    var reader = MetricReader{ .allocator = std.testing.allocator };
    defer reader.shutdown();

    try mp.addReader(&reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, null);

    try reader.collect();
}

pub const MetricExporter = struct {
    exporter: *const fn (pbmetrics.ExportMetricsServiceRequest) MetricReadError!void,
};
