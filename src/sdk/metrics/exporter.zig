const std = @import("std");

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const pbcommon = @import("../../opentelemetry/proto/common/v1.pb.zig");

const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const MetricReadError = @import("reader.zig").MetricReadError;
const MetricReader = @import("reader.zig").MetricReader;

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
    pub fn exportBatch(self: *Self, metrics: pbmetrics.MetricsData) ExportResult {
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
        self.allocator.destroy(self);
    }
};

// test harness to build a noop exporter.
// marked as pub only for testing purposes.
pub fn noopExporter(_: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
    defer metrics.deinit();
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(_: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
    defer metrics.deinit();
    if (metrics.resource_metrics.items.len != 1) {
        return MetricReadError.ExportFailed;
    } // only one resource metrics is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: *ExporterIface, metrics: pbmetrics.MetricsData) MetricReadError!void {
    defer metrics.deinit();
    // Sleep for 1 second to simulate a slow exporter.
    std.time.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "metric exporter no-op" {
    var noop = ExporterIface{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    const metrics = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metrics.deinit();
    const result = me.exportBatch(metrics);
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
    metrics.deinit();
}

test "metric exporter force flush fails" {
    var wait = ExporterIface{ .exportFn = waiterExporter };
    var me = try MetricExporter.new(std.testing.allocator, &wait);
    defer me.shutdown();

    const metrics = pbmetrics.MetricsData{
        .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(std.testing.allocator),
    };
    defer metrics.deinit();

    var bg = try std.Thread.spawn(
        .{},
        backgroundRunner,
        .{ me, metrics },
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
    exportFn: *const fn (*ExporterIface, pbmetrics.MetricsData) MetricReadError!void,

    /// ExportBatch defines the behavior that metric exporters will implement.
    /// Each metric exporter owns the metrics data passed to it.
    pub fn exportBatch(self: *ExporterIface, data: pbmetrics.MetricsData) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

/// InMemoryExporter stores in memory the metrics data to be exported.
/// The memory representation uses the types defined in the library.
pub const InMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: pbmetrics.MetricsData,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = pbmetrics.MetricsData{ .resource_metrics = std.ArrayList(pbmetrics.ResourceMetrics).init(allocator) },
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

        self.data.deinit();
        self.data = metrics;
    }

    /// Copy the metrics from the in memory exporter.
    /// Caller owns the memory and must call deinit() once done.
    pub fn fetch(self: *Self) !pbmetrics.MetricsData {
        return self.data.dupe(self.allocator);
    }
};

test "in memory exporter stores data" {
    var inMemExporter = try InMemoryExporter.init(std.testing.allocator);
    defer inMemExporter.deinit();

    const exporter = try MetricExporter.new(std.testing.allocator, &inMemExporter.exporter);
    defer exporter.shutdown();

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

    // MetricReader.collect() does a copy of the metrics data,
    // then calls the exportBatch implementation passing it in.
    const ownedData = try metricsData.dupe(std.testing.allocator);
    defer metricsData.deinit();
    const result = exporter.exportBatch(ownedData);

    std.debug.assert(result == .Success);

    const data = try inMemExporter.fetch();
    defer data.deinit();

    std.debug.assert(data.resource_metrics.items.len == 1);
    const entry = data.resource_metrics.items[0];

    std.debug.assert(entry.scope_metrics.items.len == 1);
    std.debug.assert(entry.scope_metrics.items[0].metrics.items[0].data.?.sum.data_points.items.len == 2);

    try std.testing.expectEqual(pbmetrics.Sum, @TypeOf(entry.scope_metrics.items[0].metrics.items[0].data.?.sum));
    const sum: pbmetrics.Sum = entry.scope_metrics.items[0].metrics.items[0].data.?.sum;

    try std.testing.expectEqual(sum.data_points.items[0].value.?.as_int, 1);
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
        try s.start();
        return s;
    }

    fn start(self: *Self) !void {
        const th = try std.Thread.spawn(
            .{},
            collectAndExport,
            .{self},
        );
        th.detach();
        return;
    }

    pub fn shutdown(self: *Self) void {
        self.shuttingDown.store(true, .release);
        self.allocator.destroy(self);
    }
};

// Function that collects metrics from the reader and exports it to the destination.
// FIXME there is not a timeout for the collect operation.
fn collectAndExport(periodicExp: *PeriodicExportingMetricReader) void {
    // The execution should continue until the reader is shutting down
    while (periodicExp.shuttingDown.load(.acquire) == false) {
        if (periodicExp.reader.meterProvider) |_| {
            // This will also call exporter.exportBatch() every interval.
            periodicExp.reader.collect() catch |e| {
                std.debug.print("PeriodicExportingReader: reader collect failed: {?}\n", .{e});
            };
        } else {
            std.debug.print("PeriodicExportingReader: no meter provider is registered with this MetricReader {any}\n", .{periodicExp.reader});
        }

        std.time.sleep(periodicExp.exportIntervalMillis * std.time.ns_per_ms);
    }
}

test "e2e periodic exporting metric reader" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const waiting: u64 = 10;

    var inMem = try InMemoryExporter.init(std.testing.allocator);
    defer inMem.deinit();

    var reader = try MetricReader.init(
        std.testing.allocator,
        try MetricExporter.new(std.testing.allocator, &inMem.exporter),
    );
    defer reader.shutdown();

    var pemr = try PeriodicExportingMetricReader.init(
        std.testing.allocator,
        reader,
        waiting,
        null,
    );
    defer pemr.shutdown();

    try mp.addReader(pemr.reader);

    var meter = try mp.getMeter(.{ .name = "test-reader" });
    var counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "a test counter",
    });
    try counter.add(10, .{});

    var histogram = try meter.createHistogram(u64, .{
        .name = "latency",
        .description = "a test histogram",
        .histogramOpts = .{ .explicitBuckets = &.{
            1.0,
            10.0,
            100.0,
        } },
    });
    try histogram.record(10, .{});

    std.time.sleep(waiting * 2 * std.time.ns_per_ms);

    const data = try inMem.fetch();
    defer data.deinit();

    std.debug.assert(data.resource_metrics.items.len == 1);
    std.debug.assert(data.resource_metrics.items[0].scope_metrics.items[0].metrics.items.len == 2);
}
