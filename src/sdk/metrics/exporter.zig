const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");
const spec = @import("../../api/metrics/spec.zig");

const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const MetricReadError = @import("reader.zig").MetricReadError;
const MetricReader = @import("reader.zig").MetricReader;

const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;

const Attributes = @import("../../attributes.zig").Attributes;

pub const ExportResult = enum {
    Success,
    Failure,
};

pub const MetricExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: *ExporterIface,
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    var exportCompleted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

    pub fn new(allocator: std.mem.Allocator, exporter: *ExporterIface) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = exporter,
        };
        return s;
    }

    /// ExportBatch exports a batch of metrics data by calling the exporter implementation.
    /// The passed metrics data will be owned by the exporter implementation.
    pub fn exportBatch(self: *Self, metrics: []Measurements) ExportResult {
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
        self.hasShutDown.store(true, .release);
        self.allocator.destroy(self);
    }
};

// test harness to build a noop exporter.
// marked as pub only for testing purposes.
pub fn noopExporter(_: *ExporterIface, _: []Measurements) MetricReadError!void {
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(_: *ExporterIface, metrics: []Measurements) MetricReadError!void {
    defer {
        for (metrics) |m| {
            var d = m;
            d.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(metrics);
    }
    if (metrics.len != 1) {
        std.debug.print("expectd just one metric, got {d}\n{any}\n", .{ metrics.len, metrics });
        return MetricReadError.ExportFailed;
    } // only one instrument from a single meter is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: *ExporterIface, _: []Measurements) MetricReadError!void {
    // Sleep for 1 second to simulate a slow exporter.
    std.time.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "metric exporter no-op" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const measurement: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = measurement },
    }};

    const result = me.exportBatch(&metrics);
    try std.testing.expectEqual(ExportResult.Success, result);
}

test "metric exporter is called by metric reader" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var mock = ExporterIface{ .exportFn = mockExporter };

    var rdr = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &mock),
    );
    defer rdr.shutdown();

    try mp.addReader(rdr);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    // only 1 metric should be in metrics data when we use the mock exporter
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try rdr.collect();
}

test "metric exporter force flush succeeds" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    const result = me.exportBatch(&metrics);
    try std.testing.expectEqual(ExportResult.Success, result);

    try me.forceFlush(1000);
}

fn backgroundRunner(me: *MetricExporter, metrics: []Measurements) !void {
    _ = me.exportBatch(metrics);
}

test "metric exporter force flush fails" {
    var wait = ExporterIface{ .exportFn = waiterExporter };
    var me = try MetricExporter.new(std.testing.allocator, &wait);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .meterName = "my-meter",
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    var bg = try std.Thread.spawn(
        .{},
        backgroundRunner,
        .{ me, &metrics },
    );
    bg.detach();

    std.time.sleep(10 * std.time.ns_per_ms); // sleep for 10 ms to ensure the background thread completed
    const e = me.forceFlush(0);
    try std.testing.expectError(MetricReadError.ForceFlushTimedOut, e);
}

/// ExporterIface is the interface for exporting metrics.
/// Implementations can be satisfied by any type by having a member field of type
/// ExporterIface and a member function exportBatch with the correct signature.
pub const ExporterIface = struct {
    exportFn: *const fn (*ExporterIface, []Measurements) MetricReadError!void,

    /// ExportBatch defines the behavior that metric exporters will implement.
    /// Each metric exporter owns the metrics data passed to it.
    pub fn exportBatch(self: *ExporterIface, data: []Measurements) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

/// InMemoryExporter stores in memory the metrics data to be exported.
/// The memory representation uses the types defined in the library.
pub const InMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayList(Measurements) = undefined,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = std.ArrayList(Measurements).init(allocator),
            .exporter = ExporterIface{
                .exportFn = exportBatch,
            },
        };
        return s;
    }
    pub fn deinit(self: *Self) void {
        for (self.data.items) |d| {
            var data = d;
            data.deinit(self.allocator);
        }
        self.data.deinit();
        self.allocator.destroy(self);
    }

    fn exportBatch(iface: *ExporterIface, metrics: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);

        for (self.data.items) |d| {
            var data = d;
            data.deinit(self.allocator);
        }
        self.data.clearRetainingCapacity();
        self.data = std.ArrayList(Measurements).fromOwnedSlice(self.allocator, metrics);
    }

    /// Read the metrics from the in memory exporter.
    //FIXME might need a mutex in the exporter as the field might be accessed
    // from a thread while it's being cleared in another (via exportBatch).
    pub fn fetch(self: *Self) ![]Measurements {
        return self.data.items;
    }
};

test "in memory exporter stores data" {
    const allocator = std.testing.allocator;

    var inMemExporter = try InMemoryExporter.init(allocator);
    defer inMemExporter.deinit();

    const exporter = try MetricExporter.new(allocator, &inMemExporter.exporter);
    defer exporter.shutdown();

    const howMany: usize = 2;

    const val = @as(u64, 42);
    const attrs = try Attributes.from(allocator, .{ "key", val });
    defer std.testing.allocator.free(attrs.?);

    var counterMeasure = try allocator.alloc(DataPoint(i64), 1);
    counterMeasure[0] = .{ .value = @as(i64, 1), .attributes = attrs };

    var histMeasure = try allocator.alloc(DataPoint(f64), 1);
    histMeasure[0] = .{ .value = @as(f64, 2.0), .attributes = attrs };

    var underTest = std.ArrayList(Measurements).init(allocator);

    try underTest.append(Measurements{
        .meterName = "first-meter",
        .meterAttributes = null,
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-abc" },
        .data = .{ .int = counterMeasure },
    });
    try underTest.append(Measurements{
        .meterName = "another-meter",
        .meterAttributes = null,
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-abc" },
        .data = .{ .double = histMeasure },
    });

    // MetricReader.collect() does a copy of the metrics data,
    // then calls the exportBatch implementation passing it in.
    const result = exporter.exportBatch(try underTest.toOwnedSlice());

    std.debug.assert(result == .Success);

    const data = try inMemExporter.fetch();

    std.debug.assert(data.len == howMany);

    try std.testing.expectEqualDeep(counterMeasure[0], data[0].data.int[0]);

    // try std.testing.expectEqual(pbmetrics.Sum, @TypeOf(entry.scope_metrics.items[0].metrics.items[0].data.?.sum));
    // const sum: pbmetrics.Sum = entry.scope_metrics.items[0].metrics.items[0].data.?.sum;

    // try std.testing.expectEqual(sum.data_points.items[0].value.?.as_int, 1);
}

/// A periodic exporting metric reader is a specialization of MetricReader
/// that periodically exports metrics data to a destination.
/// The exporter should be a push-based exporter.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#periodic-exporting-metricreader
pub const PeriodicExportingMetricReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exportIntervalMillis: u64,
    exportTimeoutMillis: u64,

    // Lock helper to signal shutdown is in progress
    shuttingDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // This reader will collect metrics data from the MeterProvider.
    reader: *MetricReader,

    // The intervals at which the reader should export metrics data
    // and wait for each operation to complete.
    // Default values are dicated by the OpenTelemetry specification.
    const defaultExportIntervalMillis: u64 = 60000;
    const defaultExportTimeoutMillis: u64 = 30000;

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *MetricReader,
        exportIntervalMs: ?u64,
        exportTimeoutMs: ?u64,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .reader = reader,
            .exportIntervalMillis = exportIntervalMs orelse defaultExportIntervalMillis,
            .exportTimeoutMillis = exportTimeoutMs orelse defaultExportTimeoutMillis,
        };
        const th = try std.Thread.spawn(
            .{},
            collectAndExport,
            .{ reader, s.shuttingDown, s.exportIntervalMillis, s.exportTimeoutMillis },
        );
        th.detach();
        return s;
    }

    pub fn shutdown(self: *Self) void {
        self.shuttingDown.store(true, .release);
        self.allocator.destroy(self);
    }
};

// Function that collects metrics from the reader and exports it to the destination.
// FIXME there is not a timeout for the collect operation.
fn collectAndExport(
    reader: *MetricReader,
    shuttingDown: std.atomic.Value(bool),
    exportIntervalMillis: u64,
    // TODO: add a timeout for the export operation
    _: u64,
) void {
    // The execution should continue until the reader is shutting down
    while (shuttingDown.load(.acquire) == false) {
        if (reader.meterProvider) |_| {
            // This will also call exporter.exportBatch() every interval.
            reader.collect() catch |e| {
                std.debug.print("PeriodicExportingReader: reader collect failed: {?}\n", .{e});
            };
        } else {
            std.debug.print("PeriodicExportingReader: no meter provider is registered with this MetricReader {any}\n", .{reader});
        }

        std.time.sleep(exportIntervalMillis * std.time.ns_per_ms);
    }
}

test "e2e periodic exporting metric reader" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const waiting: u64 = 100;

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    defer reader.shutdown();

    try mp.addReader(reader);

    var pemr = try PeriodicExportingMetricReader.init(
        std.testing.allocator,
        reader,
        waiting,
        null,
    );
    defer pemr.shutdown();

    var meter = try mp.getMeter(.{ .name = "test-reader" });
    var counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "a test counter",
    });
    try counter.add(10, .{});

    var histogram = try meter.createHistogram(f64, .{
        .name = "latency",
        .description = "a test histogram",
        .histogramOpts = .{ .explicitBuckets = &.{
            1.0,
            10.0,
            100.0,
        } },
    });
    try histogram.record(1.4, .{});
    try histogram.record(10.4, .{});

    std.time.sleep(waiting * 2 * std.time.ns_per_ms);

    const data = try inMem.fetch();

    try std.testing.expect(data.len == 2);
    //TODO add more assertions
}
