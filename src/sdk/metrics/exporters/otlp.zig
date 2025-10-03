//! OTLP exporter for metrics.

const std = @import("std");

const log = std.log.scoped(.otlp_exporter);

const Attribute = @import("../../../attributes.zig").Attribute;
const Attributes = @import("../../../attributes.zig").Attributes;

const instrument = @import("../../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;

const measure = @import("../../../api/metrics/measurement.zig");
const Measurements = measure.Measurements;
const DataPoint = measure.DataPoint;
const HistogramPoint = measure.HistogramDataPoint;

const aggregation = @import("../aggregation.zig");
const ExponentialHistogramPoint = aggregation.ExponentialHistogramDataPoint;

const view = @import("../view.zig");

const protobuf = @import("protobuf");
const pbcommon = @import("opentelemetry-proto").common_v1;
const pbmetrics = @import("opentelemetry-proto").metrics_v1;
const pbcollector_metrics = @import("opentelemetry-proto").collector_metrics_v1;

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterImpl = @import("../exporter.zig").ExporterImpl;

const MetricReadError = @import("../reader.zig").MetricReadError;

const otlp = @import("../../../otlp.zig");

/// Exports metrics via the OpenTelemetry Protocol (OTLP).
/// OTLP is a binary protocol used for transmitting telemetry data, encoding them with protobuf or JSON.
/// See https://opentelemetry.io/docs/specs/otlp/
pub const OTLPExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: ExporterImpl,

    temporality: view.TemporalitySelector,
    config: *otlp.ConfigOptions,

    pub fn init(allocator: std.mem.Allocator, config: *otlp.ConfigOptions, temporality: view.TemporalitySelector) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = ExporterImpl{
                .exportFn = exportBatch,
            },
            .temporality = temporality,
            .config = config,
        };
        return s;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn exportBatch(iface: *ExporterImpl, data: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);
        // Cleanup the data after use, it is mandatory for all exporters as they own the data argument.
        defer {
            for (data) |*m| {
                m.deinit(self.allocator);
            }
            self.allocator.free(data);
        }
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
                .scope = pbcommon.InstrumentationScope{
                    .name = (measurement.scope.name),
                    .version = if (measurement.scope.version) |version| (version) else "",
                    .attributes = attributes.values,
                },
                .schema_url = if (measurement.scope.schema_url) |s| (s) else "",
                .metrics = metrics,
            };
        }
        resource_metrics[0] = pbmetrics.ResourceMetrics{
            .resource = null, //FIXME support resource attributes
            .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).fromOwnedSlice(scope_metrics),
            .schema_url = "",
        };

        var service_req = pbcollector_metrics.ExportMetricsServiceRequest{
            .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(resource_metrics),
        };
        defer service_req.deinit(self.allocator);

        otlp.Export(self.allocator, self.config, otlp.Signal.Data{ .metrics = service_req }) catch |err| {
            log.err("failed in transport: {s}", .{@errorName(err)});
            return MetricReadError.ExportFailed;
        };
    }
};

fn toProtobufMetric(
    allocator: std.mem.Allocator,
    measurements: Measurements,
    temporailty: view.TemporalitySelector,
) !pbmetrics.Metric {
    const instrument_opts = measurements.instrumentOptions;
    const kind = measurements.instrumentKind;
    return pbmetrics.Metric{
        .name = try allocator.dupe(u8, instrument_opts.name),
        .description = if (instrument_opts.description) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, ""),
        .unit = if (instrument_opts.unit) |u| try allocator.dupe(u8, u) else try allocator.dupe(u8, ""),
        .data = switch (kind) {
            .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => |k| pbmetrics.Metric.data_union{
                .sum = pbmetrics.Sum{
                    .data_points = .fromOwnedSlice(try numberDataPoints(allocator, i64, measurements.data.int)),
                    .aggregation_temporality = temporailty(kind).toProto(),
                    // Only .Counter is guaranteed to be monotonic.
                    .is_monotonic = k == .Counter,
                },
            },

            .Histogram => switch (measurements.data) {
                .histogram => pbmetrics.Metric.data_union{
                    .histogram = pbmetrics.Histogram{
                        .data_points = try histogramDataPoints(allocator, measurements.data.histogram),
                        .aggregation_temporality = temporailty(kind).toProto(),
                    },
                },
                .exponential_histogram => pbmetrics.Metric.data_union{
                    .exponential_histogram = pbmetrics.ExponentialHistogram{
                        .data_points = try exponentialHistogramDataPoints(allocator, measurements.data.exponential_histogram),
                        .aggregation_temporality = temporailty(kind).toProto(),
                    },
                },
                .int, .double => unreachable, // Histogram instruments should not produce int/double data at export time
            },

            .Gauge, .ObservableGauge => pbmetrics.Metric.data_union{
                .gauge = pbmetrics.Gauge{
                    .data_points = switch (measurements.data) {
                        .int => blk: {
                            var a = try std.ArrayList(pbmetrics.NumberDataPoint).initCapacity(allocator, measurements.data.int.len);
                            a.appendSliceAssumeCapacity(try numberDataPoints(allocator, i64, measurements.data.int));
                            break :blk a;
                        },
                        .double => blk: {
                            var a = try std.ArrayList(pbmetrics.NumberDataPoint).initCapacity(allocator, measurements.data.double.len);
                            a.appendSliceAssumeCapacity(try numberDataPoints(allocator, f64, measurements.data.double));
                            break :blk a;
                        },
                        // No support to export histogram data points as gauge.
                        // TODO we should probably return an error?
                        .histogram, .exponential_histogram => std.ArrayList(pbmetrics.NumberDataPoint){},
                    },
                },
            },
            // TODO: add other instruments here.
            // When they are first added to Kind, a compiler error will be thrown here.
        },
        // Metadata used for internal translations, we can discard for now.
        // Consumers of SDK should not rely on this field.
        .metadata = std.ArrayList(pbcommon.KeyValue){},
    };
}

fn attributeToProtobuf(allocator: std.mem.Allocator, attribute: Attribute) !pbcommon.KeyValue {
    return pbcommon.KeyValue{
        .key = try allocator.dupe(u8, attribute.key),
        .value = switch (attribute.value) {
            .bool => pbcommon.AnyValue{ .value = .{ .bool_value = attribute.value.bool } },
            .string => pbcommon.AnyValue{ .value = .{ .string_value = try allocator.dupe(u8, attribute.value.string) } },
            .int => pbcommon.AnyValue{ .value = .{ .int_value = attribute.value.int } },
            .double => pbcommon.AnyValue{ .value = .{ .double_value = attribute.value.double } },
            // TODO include nested Attribute values
        },
    };
}

fn attributesToProtobufKeyValueList(allocator: std.mem.Allocator, attributes: ?[]Attribute) !pbcommon.KeyValueList {
    if (attributes) |attrs| {
        var kvs = pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue){} };
        for (attrs) |a| {
            try kvs.values.append(allocator, try attributeToProtobuf(allocator, a));
        }
        return kvs;
    } else {
        return pbcommon.KeyValueList{ .values = std.ArrayList(pbcommon.KeyValue){} };
    }
}

// Caller owns the memory
fn numberDataPoints(allocator: std.mem.Allocator, comptime T: type, data_points: []DataPoint(T)) ![]pbmetrics.NumberDataPoint {
    const numbers = try allocator.alloc(pbmetrics.NumberDataPoint, data_points.len);
    for (data_points, 0..) |dp, i| {
        const attrs = try attributesToProtobufKeyValueList(allocator, dp.attributes);
        numbers[i] = pbmetrics.NumberDataPoint{
            .attributes = attrs.values,
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(std.time.nanoTimestamp()),
            .value = switch (T) {
                i64 => .{ .as_int = dp.value },
                f64 => .{ .as_double = dp.value },
                else => @compileError("Unsupported type conversion to protobuf NumberDataPoint"),
            },
            // TODO: support exemplars.
            .exemplars = std.ArrayList(pbmetrics.Exemplar){},
        };
    }

    return numbers;
}

fn histogramDataPoints(allocator: std.mem.Allocator, data_points: []DataPoint(HistogramPoint)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var a = try std.ArrayList(pbmetrics.HistogramDataPoint).initCapacity(allocator, data_points.len);
    for (data_points) |dp| {
        const bounds = try allocator.alloc(f64, dp.value.explicit_bounds.len);
        for (dp.value.explicit_bounds, 0..) |b, bi| {
            bounds[bi] = b;
        }
        const attrs = try attributesToProtobufKeyValueList(allocator, dp.attributes);
        a.appendAssumeCapacity(pbmetrics.HistogramDataPoint{
            .attributes = attrs.values,
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(std.time.nanoTimestamp()),
            .count = dp.value.count,
            .sum = dp.value.sum,
            .bucket_counts = std.ArrayList(u64).fromOwnedSlice(try allocator.dupe(u64, dp.value.bucket_counts)),
            .explicit_bounds = std.ArrayList(f64).fromOwnedSlice(bounds),
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar){},
        });
    }
    return a;
}

fn exponentialHistogramDataPoints(allocator: std.mem.Allocator, data_points: []DataPoint(ExponentialHistogramPoint)) !std.ArrayList(pbmetrics.ExponentialHistogramDataPoint) {
    var a = try std.ArrayList(pbmetrics.ExponentialHistogramDataPoint).initCapacity(allocator, data_points.len);
    for (data_points) |dp| {
        const attrs = try attributesToProtobufKeyValueList(allocator, dp.attributes);

        // Convert positive buckets
        var positive_buckets: ?pbmetrics.ExponentialHistogramDataPoint.Buckets = null;
        if (dp.value.positive_bucket_counts.len > 0) {
            positive_buckets = pbmetrics.ExponentialHistogramDataPoint.Buckets{
                .offset = dp.value.positive_offset,
                .bucket_counts = std.ArrayList(u64).fromOwnedSlice(try allocator.dupe(u64, dp.value.positive_bucket_counts)),
            };
        }

        // Convert negative buckets
        var negative_buckets: ?pbmetrics.ExponentialHistogramDataPoint.Buckets = null;
        if (dp.value.negative_bucket_counts.len > 0) {
            negative_buckets = pbmetrics.ExponentialHistogramDataPoint.Buckets{
                .offset = dp.value.negative_offset,
                .bucket_counts = std.ArrayList(u64).fromOwnedSlice(try allocator.dupe(u64, dp.value.negative_bucket_counts)),
            };
        }

        a.appendAssumeCapacity(pbmetrics.ExponentialHistogramDataPoint{
            .attributes = attrs.values,
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(std.time.nanoTimestamp()),
            .count = dp.value.count,
            .sum = dp.value.sum,
            .scale = dp.value.scale,
            .zero_count = dp.value.zero_count,
            .positive = positive_buckets,
            .negative = negative_buckets,
            .min = dp.value.min,
            .max = dp.value.max,
            .zero_threshold = 0.0, // Default zero threshold
            // TODO support exemplars
            .exemplars = std.ArrayList(pbmetrics.Exemplar){},
            .flags = 0,
        });
    }
    return a;
}

test "exporters/otlp conversion for NumberDataPoint" {
    const allocator = std.testing.allocator;
    const num: usize = 100;
    var data_points = try allocator.alloc(DataPoint(i64), num);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    const anyval: []const u8 = "::anyval::";
    for (0..num) |i| {
        data_points[i] = try DataPoint(i64).new(allocator, @intCast(i), .{ "key", anyval });
    }

    var metric = try toProtobufMetric(allocator, Measurements{
        .scope = .{
            .name = "test-meter",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-abc" },
        .data = .{ .int = data_points },
    }, view.DefaultTemporality);

    defer metric.deinit(allocator);

    try std.testing.expectEqual(num, metric.data.?.sum.data_points.items.len);
    try std.testing.expectEqualStrings("counter-abc", metric.name);

    const attrs = Attributes.with(data_points[0].attributes);

    try std.testing.expectEqualStrings(
        attrs.attributes.?[0].key,
        metric.data.?.sum.data_points.items[0].attributes.items[0].key,
    );
    try std.testing.expectEqualStrings(
        anyval,
        metric.data.?.sum.data_points.items[0].attributes.items[0].value.?.value.?.string_value,
    );
}

test "exporters/otlp conversion for HistogramDataPoint" {
    const allocator = std.testing.allocator;
    const num: usize = 100;
    var data_points = try allocator.alloc(DataPoint(HistogramPoint), num);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    const anyval: []const u8 = "::anyval::";
    var bucket_counts = [_]u64{ 1, 2, 3 };
    var explicit_bounds = [_]f64{ 1.0, 2.0, 3.0 };
    for (0..num) |i| {
        data_points[i] = try DataPoint(HistogramPoint).new(allocator, HistogramPoint{
            .count = i,
            .sum = @as(f64, @floatFromInt(i * 2)),
            // The bucket counts are cloned as they are set independently for each data point,
            .bucket_counts = try allocator.dupe(u64, &bucket_counts),
            // while the explicit bounds are referenced from the instrument, as they are constant.
            .explicit_bounds = &explicit_bounds,
        }, .{ "key", anyval });
    }

    var metric = try toProtobufMetric(allocator, Measurements{
        .scope = .{
            .name = "test-meter",
        },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-abc" },
        .data = .{ .histogram = data_points },
    }, view.DefaultTemporality);
    defer metric.deinit(allocator);

    try std.testing.expectEqual(num, metric.data.?.histogram.data_points.items.len);
    try std.testing.expectEqualStrings("histogram-abc", metric.name);
    try std.testing.expectEqual(3, metric.data.?.histogram.data_points.items[0].bucket_counts.items.len);
    try std.testing.expectEqual(3, metric.data.?.histogram.data_points.items[0].explicit_bounds.items.len);
    try std.testing.expectEqual(1, metric.data.?.histogram.data_points.items[0].bucket_counts.items[0]);
    try std.testing.expectEqual(1.0, metric.data.?.histogram.data_points.items[0].explicit_bounds.items[0]);

    try std.testing.expectEqual(99, metric.data.?.histogram.data_points.items[99].count);
    try std.testing.expectEqual(198, metric.data.?.histogram.data_points.items[99].sum);

    const attrs = Attributes.with(data_points[0].attributes);

    try std.testing.expectEqualStrings(
        attrs.attributes.?[0].key,
        metric.data.?.histogram.data_points.items[0].attributes.items[0].key,
    );
    try std.testing.expectEqualStrings(
        anyval,
        metric.data.?.histogram.data_points.items[0].attributes.items[0].value.?.value.?.string_value,
    );
}

test "exporters/otlp conversion for ExponentialHistogramDataPoint" {
    const allocator = std.testing.allocator;
    const num: usize = 2;
    var data_points = try allocator.alloc(DataPoint(ExponentialHistogramPoint), num);
    defer {
        for (data_points) |*dp| dp.deinit(allocator);
        allocator.free(data_points);
    }

    const anyval: []const u8 = "::anyval::";
    var positive_bucket_counts = [_]u64{ 1, 2, 3 };
    var negative_bucket_counts = [_]u64{ 0, 1, 0 };
    for (0..num) |i| {
        data_points[i] = try DataPoint(ExponentialHistogramPoint).new(allocator, ExponentialHistogramPoint{
            .count = i + 1,
            .sum = @as(f64, @floatFromInt((i + 1) * 10)),
            .min = 1.0,
            .max = 100.0,
            .scale = 20,
            .zero_count = 0,
            .positive_offset = 0,
            .positive_bucket_counts = try allocator.dupe(u64, &positive_bucket_counts),
            .negative_offset = -1,
            .negative_bucket_counts = try allocator.dupe(u64, &negative_bucket_counts),
        }, .{ "key", anyval });
    }

    var metric = try toProtobufMetric(allocator, Measurements{
        .scope = .{
            .name = "test-meter",
        },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "exponential-histogram-abc" },
        .data = .{ .exponential_histogram = data_points },
    }, view.DefaultTemporality);

    defer metric.deinit(allocator);

    try std.testing.expectEqual(num, metric.data.?.exponential_histogram.data_points.items.len);
    try std.testing.expectEqualStrings("exponential-histogram-abc", metric.name);

    const first_dp = metric.data.?.exponential_histogram.data_points.items[0];
    try std.testing.expectEqual(@as(u64, 1), first_dp.count);
    try std.testing.expectEqual(@as(f64, 10.0), first_dp.sum.?);
    try std.testing.expectEqual(@as(i32, 20), first_dp.scale);
    try std.testing.expectEqual(@as(u64, 0), first_dp.zero_count);
    try std.testing.expectEqual(@as(f64, 1.0), first_dp.min.?);
    try std.testing.expectEqual(@as(f64, 100.0), first_dp.max.?);

    // Check positive buckets
    try std.testing.expect(first_dp.positive != null);
    try std.testing.expectEqual(@as(i32, 0), first_dp.positive.?.offset);
    try std.testing.expectEqual(@as(usize, 3), first_dp.positive.?.bucket_counts.items.len);
    try std.testing.expectEqual(@as(u64, 1), first_dp.positive.?.bucket_counts.items[0]);
    try std.testing.expectEqual(@as(u64, 2), first_dp.positive.?.bucket_counts.items[1]);
    try std.testing.expectEqual(@as(u64, 3), first_dp.positive.?.bucket_counts.items[2]);

    // Check negative buckets
    try std.testing.expect(first_dp.negative != null);
    try std.testing.expectEqual(@as(i32, -1), first_dp.negative.?.offset);
    try std.testing.expectEqual(@as(usize, 3), first_dp.negative.?.bucket_counts.items.len);

    const attrs = Attributes.with(data_points[0].attributes);
    try std.testing.expectEqualStrings(
        attrs.attributes.?[0].key,
        first_dp.attributes.items[0].key,
    );
    try std.testing.expectEqualStrings(
        anyval,
        first_dp.attributes.items[0].value.?.value.?.string_value,
    );
}

test "exporters/otlp init/deinit" {
    const allocator = std.testing.allocator;
    const config = try otlp.ConfigOptions.init(allocator);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, config, view.DefaultTemporality);
    defer exporter.deinit();
}
