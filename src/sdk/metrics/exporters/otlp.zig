const std = @import("std");

const Attribute = @import("../../../attributes.zig").Attribute;

const instrument = @import("../../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;

const measure = @import("../../../api/metrics/measurement.zig");
const Measurements = measure.Measurements;
const DataPoint = measure.DataPoint;
const HistogramPoint = measure.HistogramDataPoint;

const view = @import("../view.zig");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbcommon = @import("../../../opentelemetry/proto/common/v1.pb.zig");
const pbmetrics = @import("../../../opentelemetry/proto/metrics/v1.pb.zig");

pub fn toProtobufMetric(
    allocator: std.mem.Allocator,
    measurements: Measurements,
    temporailty: view.TemporalitySelector,
) !pbmetrics.Metric {
    const instrument_opts = measurements.instrumentOptions;
    const kind = measurements.instrumentKind;
    return pbmetrics.Metric{
        .name = ManagedString.managed(instrument_opts.name),
        .description = if (instrument_opts.description) |d| ManagedString.managed(d) else .Empty,
        .unit = if (instrument_opts.unit) |u| ManagedString.managed(u) else .Empty,
        .data = switch (kind) {
            .Counter, .UpDownCounter => pbmetrics.Metric.data_union{
                .sum = pbmetrics.Sum{
                    .data_points = try sumDataPoints(allocator, i64, measurements.data.int),
                    .aggregation_temporality = temporailty(kind).toProto(),
                    .is_monotonic = true,
                },
            },

            .Histogram => pbmetrics.Metric.data_union{
                .histogram = pbmetrics.Histogram{
                    .data_points = try histogramDataPoints(allocator, measurements.data.histogram),
                    .aggregation_temporality = temporailty(kind).toProto(),
                },
            },

            .Gauge => pbmetrics.Metric.data_union{
                .gauge = pbmetrics.Gauge{
                    .data_points = .empty, //FIXME
                    .aggregation_temporality = temporailty(kind).toProto(),
                },
            },
            // TODO: add other instruments.
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

fn sumDataPoints(allocator: std.mem.Allocator, comptime T: type, data_points: []DataPoint(T)) !std.ArrayList(pbmetrics.NumberDataPoint) {
    var a = std.ArrayList(pbmetrics.NumberDataPoint).init(allocator);
    for (data_points) |dp| {
        const attrs = try attributesToProtobufKeyValueList(allocator, dp.attributes);
        const number_dp = pbmetrics.NumberDataPoint{
            .attributes = attrs.values,
            // FIXME add a timestamp to DatatPoint in order to get it here.
            .time_unix_nano = @intCast(std.time.nanoTimestamp()),
            // FIXME reader's temporailty is not applied here.
            .value = .{ .as_int = dp.value },

            // TODO: support exemplars.
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        };
        try a.append(number_dp);
    }
    return a;
}

fn histogramDataPoints(allocator: std.mem.Allocator, data_points: []DataPoint(HistogramPoint)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var a = std.ArrayList(pbmetrics.HistogramDataPoint).init(allocator);
    for (data_points) |dp| {
        const attrs = try attributesToProtobufKeyValueList(allocator, dp.attributes);
        try a.append(pbmetrics.HistogramDataPoint{
            .attributes = attrs.values,
            .time_unix_nano = @intCast(std.time.nanoTimestamp()), //TODO fetch from DataPoint
            .count = dp.value.count,
            .sum = dp.value.sum,
            .bucket_counts = std.ArrayList(u64).fromOwnedSlice(allocator, dp.value.bucket_counts),
            .explicit_bounds = std.ArrayList(f64).init(allocator),
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar).init(allocator),
        });
    }
    return a;
}
