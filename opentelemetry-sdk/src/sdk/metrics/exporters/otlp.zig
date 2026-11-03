//! OTLP exporter for metrics.

const std = @import("std");
const Configuration = @import("../../config.zig").Configuration;
const meter_api = @import("../../../api/metrics/meter.zig");
const Exemplar = @import("../exemplar.zig").Exemplar;
const clock = @import("clock");

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
const metric_exemplar = @import("../exemplar.zig");

const protobuf = @import("protobuf");
const pbcommon = @import("opentelemetry-proto").common_v1;
const pbresource = @import("opentelemetry-proto").resource_v1;
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
    io: std.Io,
    exporter: ExporterImpl,

    temporality: view.TemporalitySelector,
    config: *otlp.ConfigOptions,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        temporality: view.TemporalitySelector,
        config: *otlp.ConfigOptions,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .io = io,
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
                    .name = (try self.allocator.dupe(u8, measurement.scope.name)),
                    .version = if (measurement.scope.version) |version|
                        try self.allocator.dupe(u8, version)
                    else
                        "",
                    .attributes = attributes.values,
                },
                .schema_url = if (measurement.scope.schema_url) |s| try self.allocator.dupe(u8, s) else "",
                .metrics = metrics,
            };
        }
        const resource_attributes = try resourceToProtobuf(
            self.allocator,
            if (data.len > 0) data[0].resource else null,
        );

        resource_metrics[0] = pbmetrics.ResourceMetrics{
            .resource = pbresource.Resource{
                .attributes = resource_attributes,
                .dropped_attributes_count = 0,
                .entity_refs = std.ArrayList(pbcommon.EntityRef).empty,
            },
            .scope_metrics = std.ArrayList(pbmetrics.ScopeMetrics).fromOwnedSlice(scope_metrics),
            .schema_url = "",
        };

        var service_req = pbcollector_metrics.ExportMetricsServiceRequest{
            .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).fromOwnedSlice(resource_metrics),
        };
        defer service_req.deinit(self.allocator);

        // TODO: The timeout configured in MetricExporter.exportBatch() applies at the exporter level,
        // but the actual HTTP request in otlp.Export() does not have timeout support.
        // This means that while the collect() operation will return after the timeout,
        // the underlying HTTP request may continue running in a background thread.
        // To properly implement timeout, we would need to:
        // 1. Add timeout support to the HTTP client in otlp.Export()
        // 2. Use non-blocking I/O or async/await to make the HTTP request cancellable
        // This is currently limited by Zig's std.http.Client which doesn't support request timeouts.
        otlp.Export(self.allocator, self.io, self.config, otlp.Signal.Data{ .metrics = service_req }) catch |err| {
            log.err("failed in transport: {s}", .{@errorName(err)});
            return MetricReadError.ExportFailed;
        };
    }
};

pub fn toProtobufMetric(
    allocator: std.mem.Allocator,
    measurements: Measurements,
    temporailty: view.TemporalitySelector,
) !pbmetrics.Metric {
    const instrument_opts = measurements.instrumentOptions;
    const kind = measurements.instrumentKind;
    var metric = pbmetrics.Metric{
        .name = try allocator.dupe(u8, instrument_opts.name),
        .description = &.{},
        .unit = &.{},
        .data = null,
        .metadata = .empty,
    };
    errdefer metric.deinit(allocator);
    metric.description = try allocator.dupe(u8, instrument_opts.description orelse "");
    metric.unit = try allocator.dupe(u8, instrument_opts.unit orelse "");
    metric.data = switch (measurements.data) {
        inline .int, .double => |data_points, tag| blk: {
            const points = std.ArrayList(pbmetrics.NumberDataPoint).fromOwnedSlice(
                try numberDataPoints(allocator, if (tag == .int) i64 else f64, data_points),
            );
            break :blk if (measurements.isLastValue()) pbmetrics.Metric.data_union{
                .gauge = pbmetrics.Gauge{ .data_points = points },
            } else pbmetrics.Metric.data_union{
                .sum = pbmetrics.Sum{
                    .data_points = points,
                    .aggregation_temporality = temporailty(kind).toProto(),
                    .is_monotonic = kind.isMonotonic(),
                },
            };
        },
        .histogram => |data_points| pbmetrics.Metric.data_union{
            .histogram = pbmetrics.Histogram{
                .data_points = try histogramDataPoints(allocator, data_points),
                .aggregation_temporality = temporailty(kind).toProto(),
            },
        },
        .exponential_histogram => |data_points| pbmetrics.Metric.data_union{
            .exponential_histogram = pbmetrics.ExponentialHistogram{
                .data_points = try exponentialHistogramDataPoints(allocator, data_points),
                .aggregation_temporality = temporailty(kind).toProto(),
            },
        },
    };
    return metric;
}

fn attributeToProtobuf(allocator: std.mem.Allocator, attribute: Attribute) !pbcommon.KeyValue {
    const key = try allocator.dupe(u8, attribute.key);
    errdefer allocator.free(key);
    return pbcommon.KeyValue{
        .key = key,
        .value = switch (attribute.value) {
            .bool => pbcommon.AnyValue{ .value = .{ .bool_value = attribute.value.bool } },
            .string => pbcommon.AnyValue{ .value = .{ .string_value = try allocator.dupe(u8, attribute.value.string) } },
            .int => pbcommon.AnyValue{ .value = .{ .int_value = attribute.value.int } },
            .double => pbcommon.AnyValue{ .value = .{ .double_value = attribute.value.double } },
            .baggage => unreachable, // Baggage is not a regular attribute
            // TODO include nested Attribute values
        },
    };
}

fn resourceToProtobuf(allocator: std.mem.Allocator, resource: ?[]const Attribute) !std.ArrayList(pbcommon.KeyValue) {
    var kvs = std.ArrayList(pbcommon.KeyValue).empty;
    if (resource) |attrs| {
        try kvs.ensureTotalCapacityPrecise(allocator, attrs.len);
        for (attrs) |attr| {
            kvs.appendAssumeCapacity(try attributeToProtobuf(allocator, attr));
        }
    }
    return kvs;
}

pub fn attributesToProtobufKeyValueList(allocator: std.mem.Allocator, attributes: ?[]Attribute) !pbcommon.KeyValueList {
    if (attributes) |attrs| {
        var kvs: pbcommon.KeyValueList = .{ .values = try .initCapacity(allocator, attrs.len) };
        errdefer kvs.deinit(allocator);
        for (attrs) |a| {
            kvs.values.appendAssumeCapacity(try attributeToProtobuf(allocator, a));
        }
        return kvs;
    } else {
        return .{ .values = .empty };
    }
}

fn exemplarsToProtobuf(allocator: std.mem.Allocator, samples: []const metric_exemplar.Exemplar) !std.ArrayList(pbmetrics.Exemplar) {
    var converted = try std.ArrayList(pbmetrics.Exemplar).initCapacity(allocator, samples.len);
    errdefer {
        for (converted.items) |*sample| sample.deinit(allocator);
        converted.deinit(allocator);
    }
    for (samples) |sample| {
        var point = pbmetrics.Exemplar{
            .time_unix_nano = sample.time_ns,
            .value = switch (sample.value) {
                .int => |value| .{ .as_int = value },
                .double => |value| .{ .as_double = value },
            },
        };
        errdefer point.deinit(allocator);
        point.filtered_attributes = (try attributesToProtobufKeyValueList(allocator, sample.filtered_attributes)).values;
        if (sample.trace_id) |id| point.trace_id = try allocator.dupe(u8, &id);
        if (sample.span_id) |id| point.span_id = try allocator.dupe(u8, &id);
        converted.appendAssumeCapacity(point);
    }
    return converted;
}

// Caller owns the memory.
fn numberDataPoints(allocator: std.mem.Allocator, comptime T: type, data_points: []DataPoint(T)) ![]pbmetrics.NumberDataPoint {
    const numbers = try allocator.alloc(pbmetrics.NumberDataPoint, data_points.len);
    var initialized: usize = 0;
    errdefer {
        for (numbers[0..initialized]) |*point| point.deinit(allocator);
        allocator.free(numbers);
    }
    for (data_points, 0..) |dp, i| {
        var point = pbmetrics.NumberDataPoint{
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(clock.nanoTimestamp()),
            .value = switch (T) {
                i64 => .{ .as_int = dp.value },
                f64 => .{ .as_double = dp.value },
                else => @compileError("Unsupported type conversion to protobuf NumberDataPoint"),
            },
        };
        errdefer point.deinit(allocator);
        point.attributes = (try attributesToProtobufKeyValueList(allocator, dp.attributes)).values;
        point.exemplars = try exemplarsToProtobuf(allocator, dp.exemplars);
        numbers[i] = point;
        initialized += 1;
    }
    return numbers;
}

fn histogramDataPoints(allocator: std.mem.Allocator, data_points: []DataPoint(HistogramPoint)) !std.ArrayList(pbmetrics.HistogramDataPoint) {
    var converted = try std.ArrayList(pbmetrics.HistogramDataPoint).initCapacity(allocator, data_points.len);
    errdefer {
        for (converted.items) |*point| point.deinit(allocator);
        converted.deinit(allocator);
    }
    for (data_points) |dp| {
        var point = pbmetrics.HistogramDataPoint{
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(clock.nanoTimestamp()),
            .count = dp.value.count,
            .sum = dp.value.sum,
            .min = dp.value.min,
            .max = dp.value.max,
        };
        errdefer point.deinit(allocator);
        point.attributes = (try attributesToProtobufKeyValueList(allocator, dp.attributes)).values;
        point.bucket_counts = .fromOwnedSlice(try allocator.dupe(u64, dp.value.bucket_counts));
        point.explicit_bounds = .fromOwnedSlice(try allocator.dupe(f64, dp.value.explicit_bounds));
        point.exemplars = try exemplarsToProtobuf(allocator, dp.exemplars);
        converted.appendAssumeCapacity(point);
    }
    return converted;
}

fn exponentialHistogramDataPoints(allocator: std.mem.Allocator, data_points: []DataPoint(ExponentialHistogramPoint)) !std.ArrayList(pbmetrics.ExponentialHistogramDataPoint) {
    var converted = try std.ArrayList(pbmetrics.ExponentialHistogramDataPoint).initCapacity(allocator, data_points.len);
    errdefer {
        for (converted.items) |*point| point.deinit(allocator);
        converted.deinit(allocator);
    }
    for (data_points) |dp| {
        var point = pbmetrics.ExponentialHistogramDataPoint{
            .start_time_unix_nano = if (dp.timestamps) |ts| ts.start_time_ns orelse 0 else 0,
            .time_unix_nano = if (dp.timestamps) |ts| ts.time_ns else @intCast(clock.nanoTimestamp()),
            .count = dp.value.count,
            .sum = dp.value.sum,
            .scale = dp.value.scale,
            .zero_count = dp.value.zero_count,
            .min = dp.value.min,
            .max = dp.value.max,
            .zero_threshold = 0.0,
            .flags = 0,
        };
        errdefer point.deinit(allocator);
        point.attributes = (try attributesToProtobufKeyValueList(allocator, dp.attributes)).values;
        if (dp.value.positive_bucket_counts.len > 0) {
            const counts = try allocator.dupe(u64, dp.value.positive_bucket_counts);
            point.positive = .{ .offset = dp.value.positive_offset, .bucket_counts = .fromOwnedSlice(counts) };
        }
        if (dp.value.negative_bucket_counts.len > 0) {
            const counts = try allocator.dupe(u64, dp.value.negative_bucket_counts);
            point.negative = .{ .offset = dp.value.negative_offset, .bucket_counts = .fromOwnedSlice(counts) };
        }
        point.exemplars = try exemplarsToProtobuf(allocator, dp.exemplars);
        converted.appendAssumeCapacity(point);
    }
    return converted;
}

test "exemplar/otlp recording pipeline" {
    const allocator = std.testing.allocator;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("OTEL_METRICS_EXEMPLAR_FILTER", "always_on");
    const cfg = try Configuration.init(allocator, std.testing.io, &env);
    defer cfg.deinit();
    Configuration.set(cfg);
    const provider = try meter_api.MeterProvider.init(allocator, std.testing.io);
    defer provider.deinit();
    try provider.addView(.{
        .instrument_selector = .{ .name = "requests" },
        .aggregation = .Sum,
        .temporality = .Cumulative,
        .attribute_filter = .{ .include_keys = &.{"region"} },
    });
    const meter = try provider.getMeter(.{ .name = "exemplar-test" });
    const counter = try meter.createCounter(u64, .{ .name = "requests" });
    const region: []const u8 = "west";
    const request: []const u8 = "request-1";
    const before: u64 = @intCast(clock.nanoTimestamp());
    try counter.add(7, .{ "region", region, "request_id", request });
    var slice_attrs = [_]Attribute{
        .{ .key = "region", .value = .{ .string = region } },
        .{ .key = "request_id", .value = .{ .string = request } },
    };
    try counter.addWithSlice(7, &slice_attrs);
    const after: u64 = @intCast(clock.nanoTimestamp());
    const collected = try meter_api.AggregatedMetrics.fetch(allocator, meter, provider.views.items, null);
    defer {
        for (collected) |*m| m.deinit(allocator);
        allocator.free(collected);
    }
    var metric = try toProtobufMetric(allocator, collected[0], view.DefaultTemporality);
    defer metric.deinit(allocator);
    const points = metric.data.?.sum.data_points.items;
    try std.testing.expectEqual(@as(usize, 1), points[0].exemplars.items.len);
    try std.testing.expectEqual(@as(i64, 14), points[0].value.?.as_int);
    const sample = points[0].exemplars.items[0];
    try std.testing.expectEqual(@as(i64, 7), sample.value.?.as_int);
    try std.testing.expect(sample.time_unix_nano >= before and sample.time_unix_nano <= after);
    try std.testing.expectEqual(@as(usize, 1), points[0].attributes.items.len);
    try std.testing.expectEqualStrings("region", points[0].attributes.items[0].key);
    try std.testing.expectEqual(@as(usize, 1), sample.filtered_attributes.items.len);
    try std.testing.expectEqualStrings("request_id", sample.filtered_attributes.items[0].key);
    try std.testing.expectEqualStrings(request, sample.filtered_attributes.items[0].value.?.value.?.string_value);
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
            .min = 1.0,
            .max = @as(f64, @floatFromInt(i)),
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
    try std.testing.expectEqual(1.0, metric.data.?.histogram.data_points.items[99].min);
    try std.testing.expectEqual(99.0, metric.data.?.histogram.data_points.items[99].max);

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

test "exporters/otlp metric type follows the aggregated data" {
    const allocator = std.testing.allocator;

    // A view can aggregate a counter into a histogram.
    var bucket_counts = [_]u64{ 1, 0 };
    var histogram_points = [_]DataPoint(HistogramPoint){.{ .value = .{
        .count = 1,
        .sum = 0.5,
        .bucket_counts = &bucket_counts,
        .explicit_bounds = &.{1.0},
    } }};
    var counter_metric = try toProtobufMetric(allocator, .{
        .scope = .{ .name = "test-meter" },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-as-histogram" },
        .data = .{ .histogram = &histogram_points },
    }, view.DefaultTemporality);
    defer counter_metric.deinit(allocator);

    try std.testing.expectEqual(1, counter_metric.data.?.histogram.data_points.items.len);
    try std.testing.expectEqual(0.5, counter_metric.data.?.histogram.data_points.items[0].sum);

    // A view can aggregate a histogram into a sum.
    var sum_points = [_]DataPoint(i64){.{ .value = 42 }};
    var histogram_metric = try toProtobufMetric(allocator, .{
        .scope = .{ .name = "test-meter" },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-as-sum" },
        .data = .{ .int = &sum_points },
    }, view.DefaultTemporality);
    defer histogram_metric.deinit(allocator);

    try std.testing.expect(histogram_metric.data.?.sum.is_monotonic);
    try std.testing.expectEqual(42, histogram_metric.data.?.sum.data_points.items[0].value.?.as_int);

    // Observable counters are monotonic sums.
    var observed_points = [_]DataPoint(i64){.{ .value = 7 }};
    var observable_metric = try toProtobufMetric(allocator, .{
        .scope = .{ .name = "test-meter" },
        .instrumentKind = .ObservableCounter,
        .instrumentOptions = .{ .name = "observable-counter" },
        .data = .{ .int = &observed_points },
    }, view.DefaultTemporality);
    defer observable_metric.deinit(allocator);

    try std.testing.expect(observable_metric.data.?.sum.is_monotonic);
}

test "exporters/otlp init/deinit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    const config = try otlp.ConfigOptions.init(allocator, &env_map);
    defer config.deinit();

    var exporter = try OTLPExporter.init(allocator, io, view.DefaultTemporality, config);
    defer exporter.deinit();
}

test "exporters/otlp resource conversion" {
    const allocator = std.testing.allocator;

    const resource = [_]Attribute{
        .{ .key = "service.name", .value = .{ .string = "test-service" } },
        .{ .key = "service.version", .value = .{ .string = "1.2.3" } },
    };

    var kvs = try resourceToProtobuf(allocator, &resource);
    defer {
        for (kvs.items) |*kv| kv.deinit(allocator);
        kvs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), kvs.items.len);
    try std.testing.expectEqualStrings("service.name", kvs.items[0].key);
    try std.testing.expectEqualStrings("test-service", kvs.items[0].value.?.value.?.string_value);
    try std.testing.expectEqualStrings("service.version", kvs.items[1].key);
    try std.testing.expectEqualStrings("1.2.3", kvs.items[1].value.?.value.?.string_value);
}

test "exporters/otlp resource conversion without a resource" {
    const allocator = std.testing.allocator;

    var kvs = try resourceToProtobuf(allocator, null);
    defer kvs.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), kvs.items.len);
}

const ExemplarFixtureKind = enum { integer, double, histogram, exponential };

fn exemplarProtobufFixture(allocator: std.mem.Allocator, kind: ExemplarFixtureKind) !pbmetrics.Metric {
    var filtered = [_]Attribute{.{ .key = "request_id", .value = .{ .string = "abc" } }};
    var retained = [_]Attribute{.{ .key = "region", .value = .{ .string = "west" } }};
    var samples = [_]Exemplar{.{
        .value = if (kind == .integer) .{ .int = 7 } else .{ .double = 1.25 },
        .time_ns = 150,
        .trace_id = @splat(1),
        .span_id = @splat(2),
        .filtered_attributes = &filtered,
    }};
    const timestamps: measure.Timestamps = .{ .start_time_ns = 100, .time_ns = 200 };
    var integers = [_]DataPoint(i64){.{ .value = 8, .attributes = &retained, .timestamps = timestamps, .exemplars = &samples }};
    var doubles = [_]DataPoint(f64){.{ .value = 3.5, .attributes = &retained, .timestamps = timestamps, .exemplars = &samples }};
    var buckets = [_]u64{ 1, 1 };
    var histograms = [_]DataPoint(HistogramPoint){.{
        .value = .{ .explicit_bounds = &.{2}, .bucket_counts = &buckets, .sum = 3.5, .count = 2, .min = 1.25, .max = 2.25 },
        .attributes = &retained,
        .timestamps = timestamps,
        .exemplars = &samples,
    }};
    var exponentials = [_]DataPoint(ExponentialHistogramPoint){.{
        .value = .{ .sum = 3.5, .count = 2, .min = 1.25, .max = 2.25, .scale = 0, .zero_count = 0, .positive_offset = 0, .positive_bucket_counts = &buckets, .negative_offset = 0, .negative_bucket_counts = &.{} },
        .attributes = &retained,
        .timestamps = timestamps,
        .exemplars = &samples,
    }};
    return toProtobufMetric(allocator, .{
        .scope = .{ .name = "exemplar-fixture" },
        .instrumentKind = switch (kind) {
            .integer => .Counter,
            .double => .Gauge,
            else => .Histogram,
        },
        .instrumentOptions = .{ .name = "example", .description = "exemplar fixture", .unit = "1" },
        .data = switch (kind) {
            .integer => .{ .int = &integers },
            .double => .{ .double = &doubles },
            .histogram => .{ .histogram = &histograms },
            .exponential => .{ .exponential_histogram = &exponentials },
        },
    }, view.DefaultTemporality);
}

fn exemplarFromMetricForTest(metric: pbmetrics.Metric) !pbmetrics.Exemplar {
    const samples = switch (metric.data.?) {
        inline .sum, .gauge, .histogram, .exponential_histogram => |data| blk: {
            try std.testing.expectEqual(@as(usize, 1), data.data_points.items.len);
            break :blk data.data_points.items[0].exemplars.items;
        },
        else => return error.UnexpectedMetricType,
    };
    try std.testing.expectEqual(@as(usize, 1), samples.len);
    return samples[0];
}

test "exemplar/otlp round trips values context timestamps and filtered attributes" {
    const allocator = std.testing.allocator;
    for (std.meta.tags(ExemplarFixtureKind)) |kind| {
        var metric = try exemplarProtobufFixture(allocator, kind);
        defer metric.deinit(allocator);
        var encoded = std.Io.Writer.Allocating.init(allocator);
        defer encoded.deinit();
        try metric.encode(&encoded.writer, allocator);
        var reader = std.Io.Reader.fixed(encoded.written());
        var decoded = try pbmetrics.Metric.decode(&reader, allocator);
        defer decoded.deinit(allocator);
        const sample = try exemplarFromMetricForTest(decoded);
        try std.testing.expectEqual(@as(u64, 150), sample.time_unix_nano);
        try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(1)), sample.trace_id);
        try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(2)), sample.span_id);
        try std.testing.expect(sample.value != null);
        try std.testing.expect(if (kind == .integer) sample.value.? == .as_int else sample.value.? == .as_double);
        if (kind == .integer) try std.testing.expectEqual(@as(i64, 7), sample.value.?.as_int) else try std.testing.expectEqual(@as(f64, 1.25), sample.value.?.as_double);
        try std.testing.expectEqual(@as(usize, 1), sample.filtered_attributes.items.len);
        try std.testing.expectEqualStrings("request_id", sample.filtered_attributes.items[0].key);
        try std.testing.expectEqualStrings("abc", sample.filtered_attributes.items[0].value.?.value.?.string_value);
    }
}

test "exemplar/otlp conversion cleans up every allocation failure" {
    for (std.meta.tags(ExemplarFixtureKind)) |kind|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, exemplarProtobufAllocationFailure, .{kind});
}

fn exemplarProtobufAllocationFailure(allocator: std.mem.Allocator, kind: ExemplarFixtureKind) !void {
    var metric = try exemplarProtobufFixture(allocator, kind);
    defer metric.deinit(allocator);
}
