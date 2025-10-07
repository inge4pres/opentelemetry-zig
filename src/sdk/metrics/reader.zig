const std = @import("std");

const log = std.log.scoped(.reader);

const pbcommon = @import("opentelemetry-proto").common;
const pbresource = @import("opentelemetry-proto").resource;
const pbmetrics = @import("opentelemetry-proto").metrics;

const instrument = @import("../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;
const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const AggregatedMetrics = @import("../../api/metrics/meter.zig").AggregatedMetrics;

const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

const view = @import("view.zig");
const TemporalitySelector = view.TemporalitySelector;
const AggregationSelector = view.AggregationSelector;

const exporter = @import("exporter.zig");
const MetricExporter = exporter.MetricExporter;
const ExporterIface = exporter.ExporterImpl;
const ExportResult = exporter.ExportResult;
const Temporality = @import("temporality.zig");

const InMemoryExporter = @import("exporters/in_memory.zig").InMemoryExporter;

/// ExportError represents the failure to export data points
/// to a destination.
pub const MetricReadError = error{
    CollectFailedOnMissingMeterProvider,
    ExportFailed,
    ForceFlushTimedOut,
    ConcurrentCollectNotAllowed,
    OutOfMemory,
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

    // Data transform configuration
    temporality: TemporalitySelector = view.DefaultTemporality,
    aggregation: AggregationSelector = view.DefaultAggregation,
    // Composes the .Cumulative data points.
    temporal_aggregation: *Temporality = undefined,

    // Optional timeout for export operations (in milliseconds)
    exportTimeout: ?u64 = null,

    // Signal that shutdown has been called.
    hasShutDown: bool = false,
    mx: std.Thread.Mutex = std.Thread.Mutex{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, metric_exporter: *MetricExporter) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = metric_exporter,
            .temporality = metric_exporter.temporality orelse view.DefaultTemporality,
            .aggregation = metric_exporter.aggregation orelse view.DefaultAggregation,
            .temporal_aggregation = try Temporality.init(allocator),
        };

        return s;
    }

    pub fn collect(self: *Self) !void {
        if (@atomicLoad(bool, &self.hasShutDown, .acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        if (!self.mx.tryLock()) {
            return MetricReadError.ConcurrentCollectNotAllowed;
        }
        defer self.mx.unlock();
        var toBeExported = std.ArrayList(Measurements){};
        defer toBeExported.deinit(self.allocator);

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            // Measurements can be ported to protobuf structs during OTLP export.
            var meters = mp.meters.valueIterator();
            while (meters.next()) |meter| {
                const measurements = AggregatedMetrics.fetch(self.allocator, meter, mp.views.items, self.aggregation) catch |err| {
                    log.err("error aggregating data points from meter {s}: {}", .{ meter.scope.name, err });
                    continue;
                };
                defer self.allocator.free(measurements);

                for (measurements) |*m| {
                    try self.temporal_aggregation.process(m, self.temporality);
                }

                // The exporter takes ownership of the data points, which are deinitialized
                // by calling deinit() on the Measurements once done.
                // MetricExporter must be built with the same allocator as MetricReader
                // to ensure that the memory is managed correctly.
                try toBeExported.appendSlice(self.allocator, measurements);
            }

            const owned = try toBeExported.toOwnedSlice(self.allocator);
            switch (self.exporter.exportBatch(owned, self.exportTimeout)) {
                ExportResult.Success => return,
                ExportResult.Failure => return MetricReadError.ExportFailed,
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    pub fn shutdown(self: *Self) void {
        @atomicStore(bool, &self.hasShutDown, true, .release);
        self.collect() catch |e| {
            log.err("shutdown: error while collecting metrics: {}", .{e});
        };
        self.exporter.shutdown();
        self.temporal_aggregation.deinit();
        self.allocator.destroy(self);
    }
};

test "metric reader shutdown prevents collect() to execute" {
    var noop = exporter.ExporterImpl{ .exportFn = exporter.noopExporter };
    const metric_exporter = try MetricExporter.new(std.testing.allocator, &noop);
    var metric_reader = try MetricReader.init(std.testing.allocator, metric_exporter);
    const e = metric_reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    metric_reader.shutdown();
}

test "metric reader collects data from meter provider" {
    const allocator = std.testing.allocator;

    var mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, &inMem.exporter);

    var reader = try MetricReader.init(allocator, metric_exporter);
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

    const data = try inMem.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }
}

fn deltaTemporality(_: Kind) view.Temporality {
    return .Delta;
}

fn dropAll(_: Kind) view.Aggregation {
    return .Drop;
}

test "metric reader custom temporality and aggregation" {
    const allocator = std.testing.allocator;

    var mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator);
    defer inMem.deinit();

    var metric_exporter = try MetricExporter.new(allocator, &inMem.exporter);
    metric_exporter.temporality = deltaTemporality;
    metric_exporter.aggregation = dropAll;

    var reader = try MetricReader.init(allocator, metric_exporter);
    defer reader.shutdown();

    std.debug.assert(reader.temporality(.Counter) == .Delta);
    std.debug.assert(reader.aggregation(.Histogram) == .Drop);

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try reader.collect();

    const data = try inMem.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }
    // Since we are using the .Drop aggregation, no data should be collected.
    try std.testing.expectEqual(0, data.len);
}

test "metric reader correctness exporting cumulative temporality" {
    const allocator = std.testing.allocator;

    const mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, &inMem.exporter);

    var reader = try MetricReader.init(allocator, metric_exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    // Generate data
    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(2, .{});

    // first collection cycle: the value should be 3
    try reader.collect();
    const result = try inMem.fetch(allocator);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(3, result[0].data.int[0].value);

    try counter.add(1, .{});
    try counter.add(2, .{});

    // Second collection cycle: the value should be 6
    try reader.collect();
    const result2 = try inMem.fetch(allocator);
    defer {
        for (result2) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result2);
    }

    // Assert value is actually summed up with .Cumulative
    try std.testing.expectEqual(6, result2[0].data.int[0].value);
    // and that timestamp is preserved in a long-running series
    try std.testing.expectEqual(result[0].data.int[0].timestamps.?.time_ns, result2[0].data.int[0].timestamps.?.start_time_ns);
}
