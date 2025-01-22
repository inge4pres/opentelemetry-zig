const std = @import("std");
const Kind = @import("../instrument.zig").Kind;
const Attribute = @import("../attributes.zig").Attribute;
const instrument = @import("../instrument.zig");
const Instrument = instrument.Instrument;
const view = @import("../view.zig");
const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");

pub fn toProtobufMetric(
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
    for (h.dataPoints.items) |measure| {
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
