const std = @import("std");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const pbresource = @import("../../opentelemetry/proto/resource/v1.pb.zig");
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbutils = @import("../../pbutils.zig");
const instrument = @import("../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;
const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const AggregatedMetrics = @import("../../api/metrics/meter.zig").AggregatedMetrics;

const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
// =======
// const MeterProvider = @import("meter.zig").MeterProvider;
// const AggregatedMetrics = @import("meter.zig").AggregatedMetrics;
// const Attribute = @import("attributes.zig").Attribute;
// const Attributes = @import("attributes.zig").Attributes;
// const DataPoint = @import("measurement.zig").DataPoint;
// const MeasurementsData = @import("measurement.zig").MeasurementsData;
// const Measurements = @import("measurement.zig").Measurements;
// >>>>>>> 92c97a2 (refactor: use internal measurements lists, isolate protobuf structs):src/metrics/reader.zig

const view = @import("view.zig");
const TemporalitySelector = view.TemporalitySelector;
const AggregationSelector = view.AggregationSelector;

const exporter = @import("exporter.zig");
const MetricExporter = exporter.MetricExporter;
const Exporter = exporter.ExporterIface;
const ExportResult = exporter.ExportResult;
const InMemoryExporter = exporter.InMemoryExporter;

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
    // Exporter is the destination of the metrics data.
    // It takes ownership of the collected metrics.
    exporter: *MetricExporter = undefined,
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    temporality: TemporalitySelector = view.DefaultTemporalityFor,
    aggregation: AggregationSelector = view.DefaultAggregationFor,
    // Signal that shutdown has been called.
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, metricExporter: *MetricExporter) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = metricExporter,
        };
        return s;
    }

    pub fn withTemporality(self: *Self, temporality: *const fn (Kind) view.Temporality) *Self {
        self.temporality = temporality;
        return self;
    }

    pub fn withAggregation(self: *Self, aggregation: *const fn (Kind) view.Aggregation) *Self {
        self.aggregation = aggregation;
        return self;
    }

    pub fn collect(self: *Self) !void {
        if (self.hasShutDown.load(.acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        var toBeExported = std.ArrayList(Measurements).init(self.allocator);
        defer toBeExported.deinit();

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            // TODO: extract MeasurmentsData from all meters and accumulate them with Meter attributes.
            //  MeasurementsData can be ported much more easilty to protobuf structs during export.
            var meters = mp.meters.valueIterator();
            while (meters.next()) |meter| {
                const measurements = try AggregatedMetrics.fetch(self.allocator, meter, self.aggregation);
                try toBeExported.appendSlice(measurements);
            }

            //TODO: apply the readers' temporality before exporting, optionally keeping the state in the reader.
            // When .Delta temporality is used, it will report the difference between the value
            // previsouly collected and the currently collected value.

            // Export the metrics data through the exporter.
            // The exporter will own the metrics and should free it
            // by calling deinit() on the MeterMeasurements once done.
            //FIXME: the exporter doen not know which allocator was used to allocate the MeterMeasurements.
            const owned = try toBeExported.toOwnedSlice();
            switch (self.exporter.exportBatch(owned)) {
                ExportResult.Success => return,
                ExportResult.Failure => return MetricReadError.ExportFailed,
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    pub fn shutdown(self: *Self) void {
        self.collect() catch |e| {
            std.debug.print("MetricReader shutdown: error while collecting metrics: {?}\n", .{e});
        };
        self.hasShutDown.store(true, .release);
        self.exporter.shutdown();
        self.allocator.destroy(self);
    }
};

fn toProtobufMetric(
    allocator: std.mem.Allocator,
    temporality: *const fn (Kind) view.Temporality,
    i: *Instrument,
) !pbmetrics.Metric {
    return pbmetrics.Metric{
        .name = ManagedString.managed(i.opts.name),
        .description = if (i.opts.description) |d| ManagedString.managed(d) else .Empty,
        .unit = if (i.opts.unit) |u| ManagedString.managed(u) else .Empty,
        .data = switch (i.data) {
            .Counter_u16 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u16, i.data.Counter_u16),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },
            .Counter_u32 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u32, i.data.Counter_u32),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },

            .Counter_u64 => pbmetrics.Metric.data_union{ .sum = pbmetrics.Sum{
                .data_points = try sumDataPoints(allocator, u64, i.data.Counter_u64),
                .aggregation_temporality = temporality(i.kind).toProto(),
                .is_monotonic = true,
            } },
            .Histogram_u16 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u16, i.data.Histogram_u16),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_u32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u32, i.data.Histogram_u32),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_u64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, u64, i.data.Histogram_u64),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },

            .Histogram_f32 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, f32, i.data.Histogram_f32),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },
            .Histogram_f64 => pbmetrics.Metric.data_union{ .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, f64, i.data.Histogram_f64),
                .aggregation_temporality = temporality(i.kind).toProto(),
            } },
            // TODO: add other metrics types.
            else => unreachable,
        },
        // Metadata used for internal translations and we can discard for now.
        // Consumers of SDK should not rely on this field.
        .metadata = std.ArrayList(pbcommon.KeyValue).init(allocator),
    };
}

fn attributeToProtobuf(attribute: Attribute) pbcommon.KeyValue {
    return pbcommon.KeyValue{
        .key = ManagedString.managed(attribute.key),
        .value = switch (attribute.value) {
            .bool => pbcommon.AnyValue{ .value = .{ .bool_value = attribute.value.bool } },
            .string => pbcommon.AnyValue{ .value = .{ .string_value = ManagedString.managed(attribute.value.string) } },
            .int => pbcommon.AnyValue{ .value = .{ .int_value = attribute.value.int } },
            .double => pbcommon.AnyValue{ .value = .{ .double_value = attribute.value.double } },
            // TODO include nested Attribute values
        },
    };
}

fn attributesToProtobufKeyValueList(allocator: std.mem.Allocator, attributes: ?[]Attribute) !pbcommon.KeyValueList {
    if (attributes) |attrs| {
        var kvs = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(allocator) };
        for (attrs) |a| {
            try kvs.values.append(attributeToProtobuf(a));
        }
        return kvs;
    } else {
        return pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue).init(allocator) };
    }
}

fn sumDataPoints(allocator: std.mem.Allocator, comptime T: type, c: *instrument.Counter(T)) !std.ArrayList(pbmetrics.NumberDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.NumberDataPoint).init(allocator);
    for (c.measurements.items) |measure| {
        const attrs = try attributesToProtobufKeyValueList(allocator, measure.attributes);
        const dp = pbmetrics.NumberDataPoint{
            .attributes = attrs.values,
            // FIXME add a timestamp to Measurement in order to get it here.
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .value = .{ .as_int = @intCast(measure.value) },

            // TODO: support exemplars.
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        try dataPoints.append(dp);
    }
    return dataPoints;
}

fn histogramDataPoints(allocator: std.mem.Allocator, comptime T: type, h: *instrument.Histogram(T)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var dataPoints = std.ArrayList(pbmetrics.HistogramDataPoint).init(allocator);
    for (h.measurements.items) |measure| {
        const attrs = try attributesToProtobufKeyValueList(allocator, measure.attributes);
        var dp = pbmetrics.HistogramDataPoint{
            .attributes = attrs.values,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .count = h.counts.get(measure.attributes) orelse 0,
            .sum = switch (@TypeOf(h.*)) {
                instrument.Histogram(u16), instrument.Histogram(u32), instrument.Histogram(u64) => @as(f64, @floatFromInt(measure.value)),
                instrument.Histogram(f32), instrument.Histogram(f64) => @as(f64, @floatCast(measure.value)),
                else => unreachable,
            },
            .bucket_counts = std.ArrayList(u64).init(allocator),
            .explicit_bounds = std.ArrayList(f64).init(allocator),
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        if (h.bucket_counts.get(measure.attributes)) |b| {
            try dp.bucket_counts.appendSlice(b);
        }
        try dp.explicit_bounds.appendSlice(h.buckets);

        try dataPoints.append(dp);
    }
    return dataPoints;
}

test "metric reader shutdown prevents collect() to execute" {
    var noop = exporter.ExporterIface{ .exportFn = exporter.noopExporter };
    const me = try MetricExporter.new(std.testing.allocator, &noop);
    var reader = try MetricReader.init(std.testing.allocator, me);
    const e = reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    reader.shutdown();
}

test "metric reader collects data from meter provider" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    var hist = try m.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";

    try hist.record(10, .{ "amazing", v });

    var histFloat = try m.createHistogram(f64, .{ .name = "my-histogram-float" });
    try histFloat.record(10.0, .{ "wonderful", v });

    try reader.collect();
}

fn deltaTemporality(_: Kind) view.Temporality {
    return view.Temporality.Delta;
}

test "metric reader custom temporality" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    reader = reader.withTemporality(deltaTemporality);

    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try reader.collect();

    const data = try inMem.fetch();
    defer {
        for (data) |d| {
            var me = d;
            me.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(data);
    }

    std.debug.assert(data.len == 1);
}
