const std = @import("std");

const log = std.log.scoped(.exporter);

const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const MetricReadError = @import("reader.zig").MetricReadError;
const MetricReader = @import("reader.zig").MetricReader;

const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;

const Attributes = @import("../../attributes.zig").Attributes;

const InMemoryExporter = @import("exporters/in_memory.zig").InMemoryExporter;
const StdoutExporter = @import("exporters/stdout.zig").StdoutExporter;
const OTLPExporter = @import("exporters/otlp.zig").OTLPExporter;
const PrometheusExporter = @import("exporters/prometheus.zig").PrometheusExporter;
const PrometheusExporterConfig = @import("exporters/prometheus.zig").ExporterConfig;

const otlp = @import("../../otlp.zig");

const view = @import("view.zig");

pub const ExportResult = enum {
    Success,
    Failure,
    // TODO: add a timeout error
};

/// MetricExporter is the container that is resposible for moving metrics out
/// of MetricReader.
/// Configuration for the metrics view is passed to the MetricReader.
/// It has pluggable exporters that can be implemented by the users,
/// and pre-defined ones that are provided by the library.
pub const MetricExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: *ExporterImpl,

    // Configuration will be passed to the MetricReader.
    // This is needed because exporters MUST provide aggregation and temporality
    // when hooked to a MetricReader.
    temporality: ?view.TemporalitySelector = null,
    aggregation: ?view.AggregationSelector = null,

    // Lock helper to signal shutdown and/or export is in progress
    hasShutDown: bool = false,
    exportCompleted: std.Thread.Mutex = std.Thread.Mutex{},

    /// Creates a new MetricExporter, providing an allocator and an exporter implementation.
    /// Use this function to plug a custom exporter implementation.
    /// Prefer the accessory functions to create pre-defined exporters.
    //TODO we should have the option to configure the exporter with aggregation and temporality.
    // In a design where MetricExporter is the one dispatching various implementations through
    // associated tyoes, we could have a method to set the configuration.
    pub fn new(allocator: std.mem.Allocator, exporter: *ExporterImpl) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = exporter,
        };
        return s;
    }

    /// Creates an in-memory exporter as described in the OpenTelemetry specification.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/in-memory/.
    pub fn InMemory(
        allocator: std.mem.Allocator,
        temporality: ?view.TemporalitySelector,
        aggregation: ?view.AggregationSelector,
    ) !struct { exporter: *MetricExporter, in_memory: *InMemoryExporter } {
        const in_mem = try InMemoryExporter.init(allocator);
        const exporter = try MetricExporter.new(allocator, &in_mem.exporter);
        // Default configuration
        exporter.temporality = temporality orelse view.TemporalityCumulative;
        exporter.aggregation = aggregation orelse view.DefaultAggregation;

        return .{ .exporter = exporter, .in_memory = in_mem };
    }

    /// Creates an exporter that writes metrics data to standard output.
    /// This is useful for debugging purposes.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/stdout/.
    pub fn Stdout(
        allocator: std.mem.Allocator,
        temporality: ?view.TemporalitySelector,
        aggregation: ?view.AggregationSelector,
    ) !struct { exporter: *MetricExporter, stdout: *StdoutExporter } {
        const stdout = try StdoutExporter.init(allocator);
        const exporter = try MetricExporter.new(allocator, &stdout.exporter);
        // Default configuration
        exporter.temporality = temporality orelse view.TemporalityCumulative;
        exporter.aggregation = aggregation orelse view.DefaultAggregation;

        return .{ .exporter = exporter, .stdout = stdout };
    }

    pub fn OTLP(
        allocator: std.mem.Allocator,
        temporality: ?view.TemporalitySelector,
        aggregation: ?view.AggregationSelector,
        options: *otlp.ConfigOptions,
    ) !struct { exporter: *MetricExporter, otlp: *OTLPExporter } {
        const temporality_ = temporality orelse view.DefaultTemporality;

        const otlp_exporter = try OTLPExporter.init(allocator, options, temporality_);
        const exporter = try MetricExporter.new(allocator, &otlp_exporter.exporter);
        // Default configuration
        exporter.temporality = temporality_;
        exporter.aggregation = aggregation orelse view.DefaultAggregation;

        return .{ .exporter = exporter, .otlp = otlp_exporter };
    }

    /// Creates a Prometheus exporter that exposes metrics via an HTTP server.
    /// This is a pull-based exporter where Prometheus scrapes metrics from the HTTP endpoint.
    /// The exporter implements ExporterImpl and caches metrics when exportBatch is called.
    ///
    /// Per OpenTelemetry specification, Prometheus exporters MUST use Cumulative temporality.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/prometheus/
    ///
    /// The HTTP server must be started by calling prometheus.start() and stopped with prometheus.stop().
    pub fn Prometheus(
        allocator: std.mem.Allocator,
        config: PrometheusExporterConfig,
    ) !struct { exporter: *MetricExporter, prometheus: *PrometheusExporter } {
        const prometheus = try PrometheusExporter.init(allocator, config);
        const exporter = try MetricExporter.new(allocator, &prometheus.exporter);

        // Prometheus MUST use Cumulative temporality per OpenTelemetry spec
        exporter.temporality = view.TemporalityCumulative;
        exporter.aggregation = view.DefaultAggregation;

        return .{ .exporter = exporter, .prometheus = prometheus };
    }

    /// Exports a batch of metrics data by calling the exporter implementation.
    /// The passed metrics data will be owned by the exporter implementation.
    /// If timeout_ms is provided, the export operation will be cancelled if it exceeds the timeout.
    pub fn exportBatch(self: *Self, metrics: []Measurements, timeout_ms: ?u64) ExportResult {
        if (@atomicLoad(bool, &self.hasShutDown, .acquire)) {
            // When shutdown has already been called, calling export should be a failure.
            // https://opentelemetry.io/docs/specs/otel/metrics/sdk/#shutdown-2
            return ExportResult.Failure;
        }
        // Acquire the lock to signal to forceFlush to wait for export to complete.
        // Also, guarantee that only one export operation is in progress at any time.
        self.exportCompleted.lock();
        defer self.exportCompleted.unlock();

        // Little trick to timeout the export operation if needed.
        if (timeout_ms) |timeout| {
            return self.exportBatchWithTimeout(metrics, timeout);
        } else {
            return self.exportBatchInternal(metrics);
        }
    }

    // Function used to perform the actual export operation.
    fn exportBatchInternal(self: *Self, metrics: []Measurements) ExportResult {
        // Call the exporter function to process metrics data.
        self.exporter.exportBatch(metrics) catch |e| {
            log.err("exportBatch failed: {}", .{e});
            return ExportResult.Failure;
        };
        return ExportResult.Success;
    }

    const ExportState = struct {
        result: ?ExportResult = null,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
    };

    fn exportWorker(self: *Self, metrics: []Measurements, state: *ExportState) void {
        const result = self.exportBatchInternal(metrics);
        state.mutex.lock();
        defer state.mutex.unlock();
        state.result = result;
        state.cond.signal();
    }

    fn exportBatchWithTimeout(self: *Self, metrics: []Measurements, timeout_ms: u64) ExportResult {
        var state = ExportState{};

        const thread = std.Thread.spawn(
            .{},
            exportWorker,
            .{ self, metrics, &state },
        ) catch |err| {
            log.err("failed to spawn export worker thread: {}", .{err});
            return self.exportBatchInternal(metrics);
        };

        state.mutex.lock();
        const timeout_ns = timeout_ms * std.time.ns_per_ms;
        const timed_out = if (state.cond.timedWait(&state.mutex, timeout_ns)) |_| false else |_| true;
        state.mutex.unlock();

        if (timed_out) {
            // Timeout occurred - we still need to wait for the thread to finish
            // to avoid memory leaks, but we return failure
            log.warn("export operation timed out after {} ms", .{timeout_ms});
            thread.join();
            return ExportResult.Failure;
        }

        thread.join();

        if (state.result) |result| {
            return result;
        } else {
            // This should not happen, but handle it gracefully
            return ExportResult.Failure;
        }
    }

    // Ensure that all the data is flushed to the destination.
    pub fn forceFlush(self: *Self, timeout_ms: u64) !void {
        const start = std.time.milliTimestamp(); // Milliseconds
        const timeout: i64 = @intCast(timeout_ms);
        while (std.time.milliTimestamp() < start + timeout) {
            if (self.exportCompleted.tryLock()) {
                self.exportCompleted.unlock();
                return;
            } else {
                std.Thread.sleep(std.time.ns_per_ms);
            }
        }
        return MetricReadError.ForceFlushTimedOut;
    }

    pub fn shutdown(self: *Self) void {
        if (@atomicRmw(bool, &self.hasShutDown, .Xchg, true, .acq_rel)) {
            return;
        }
        self.allocator.destroy(self);
    }
};

// test harness to build a noop exporter.
// marked as pub only for testing purposes.
pub fn noopExporter(_: *ExporterImpl, _: []Measurements) MetricReadError!void {
    return;
}
// mocked metric exporter to assert metrics data are read once exported.
fn mockExporter(_: *ExporterImpl, metrics: []Measurements) MetricReadError!void {
    defer {
        for (metrics) |m| {
            var d = m;
            d.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(metrics);
    }
    if (metrics.len != 1) {
        log.err("expected just one metric, got {d}\n{any}", .{ metrics.len, metrics });
        return MetricReadError.ExportFailed;
    } // only one instrument from a single meter is expected in this mock
}

// test harness to build an exporter that times out.
fn waiterExporter(_: *ExporterImpl, _: []Measurements) MetricReadError!void {
    // Sleep for 1 second to simulate a slow exporter.
    std.Thread.sleep(std.time.ns_per_ms * 1000);
    return;
}

test "metric exporter no-op" {
    var noop = ExporterImpl{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const measurement: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{.{
        .scope = .{
            .name = "my-meter",
            .version = "1.0",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = measurement },
    }};

    const result = me.exportBatch(&metrics, null);
    try std.testing.expectEqual(ExportResult.Success, result);
}

test "metric exporter is called by metric reader" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var mock = ExporterImpl{ .exportFn = mockExporter };

    const metric_exporter = try MetricExporter.new(std.testing.allocator, &mock);

    var rdr = try MetricReader.init(std.testing.allocator, metric_exporter);
    defer rdr.shutdown();

    try mp.addReader(rdr);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    // only 1 metric should be in metrics data when we use the mock exporter
    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try rdr.collect();
}

test "metric exporter force flush succeeds" {
    var noop = ExporterImpl{ .exportFn = noopExporter };
    var me = try MetricExporter.new(std.testing.allocator, &noop);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .scope = .{
            .name = "my-meter",
            .version = "1.0",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    const result = me.exportBatch(&metrics, null);
    try std.testing.expectEqual(ExportResult.Success, result);

    try me.forceFlush(1000);
}

fn backgroundRunner(me: *MetricExporter, metrics: []Measurements) !void {
    _ = me.exportBatch(metrics, null);
}

test "metric exporter force flush fails" {
    var wait = ExporterImpl{ .exportFn = waiterExporter };
    var me = try MetricExporter.new(std.testing.allocator, &wait);
    defer me.shutdown();

    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    var metrics = [1]Measurements{Measurements{
        .scope = .{
            .name = "my-meter",
            .version = "1.0",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    }};

    var bg = try std.Thread.spawn(
        .{},
        backgroundRunner,
        .{ me, &metrics },
    );
    bg.join();

    const e = me.forceFlush(0);
    try std.testing.expectError(MetricReadError.ForceFlushTimedOut, e);
}

test "metric exporter exportBatch with timeout" {
    const allocator = std.testing.allocator;

    // Create a slow exporter that will exceed the timeout
    const SlowExporter = struct {
        fn exportFn(_: *ExporterImpl, metrics: []Measurements) MetricReadError!void {
            // Sleep for 100ms to simulate slow export
            std.Thread.sleep(100 * std.time.ns_per_ms);
            // Just free the metrics array, not the contents (they're stack-allocated in test)
            allocator.free(metrics);
        }
    };

    var slow_exporter = ExporterImpl{ .exportFn = SlowExporter.exportFn };
    const metric_exporter = try MetricExporter.new(allocator, &slow_exporter);
    defer metric_exporter.shutdown();

    // Allocate metrics array on the heap
    var measure = [1]DataPoint(i64){.{ .value = 42 }};
    const dataPoints: []DataPoint(i64) = measure[0..];
    const metrics = try allocator.alloc(Measurements, 1);
    metrics[0] = Measurements{
        .scope = .{
            .name = "my-meter",
            .version = "1.0",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "my-counter" },
        .data = .{ .int = dataPoints },
    };

    // Export with a very short timeout (10ms) - should timeout and return Failure
    const result = metric_exporter.exportBatch(metrics, 10);
    try std.testing.expectEqual(ExportResult.Failure, result);
}

test "metric exporter builder in memory" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const metric_exporter = try MetricExporter.InMemory(
        std.testing.allocator,
        null,
        null,
    );

    defer {
        metric_exporter.in_memory.deinit();
        metric_exporter.exporter.shutdown();
    }
    const metric_reader = try MetricReader.init(std.testing.allocator, metric_exporter.exporter);
    defer metric_reader.shutdown();

    try mp.addReader(metric_reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });
    var g = try m.createGauge(i64, .{
        .name = "my-gauge",
        .description = "a test gauge",
    });

    try g.record(42, .{});

    try metric_reader.collect();
    const data = try metric_exporter.in_memory.fetch(std.testing.allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(data);
    }

    try std.testing.expectEqual(42, data[0].data.int[0].value);
}

test "metric exporter builder stdout" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const metric_exporter = try MetricExporter.Stdout(
        std.testing.allocator,
        null,
        null,
    );
    defer {
        metric_exporter.stdout.deinit();
        // Note: Don't call shutdown here - the MetricReader will handle it
    }

    const metric_reader = try MetricReader.init(std.testing.allocator, metric_exporter.exporter);
    defer metric_reader.shutdown();

    try mp.addReader(metric_reader);
    // We can't colect any metrics because usage of stdout is blocked by zig build.
    // This test is only demonstrative.
    try metric_reader.collect();
}

/// ExporterImpl is the interface for exporting metrics.
/// Implementations can be satisfied by any type by having a member field of type
/// ExporterImpl and a member function exportBatch with the correct signature.
pub const ExporterImpl = struct {
    exportFn: *const fn (*ExporterImpl, []Measurements) MetricReadError!void,

    /// ExportBatch defines the behavior that metric exporters will implement.
    /// Each metric exporter owns the metrics data passed to it.
    pub fn exportBatch(self: *ExporterImpl, data: []Measurements) MetricReadError!void {
        return self.exportFn(self, data);
    }
};

// This is a helper struct to synchronize the background collector thread
// with the shutdown of the PeriodicExportingReader.
const ReaderShared = struct {
    shuttingDown: bool = false,
    cond: std.Thread.Condition = .{},
    lock: std.Thread.Mutex = .{},
};

/// A periodic exporting reader is a specialization of MetricReader
/// that periodically exports metrics data to a destination.
/// The exporter configured in init() should be a push-based exporter.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#periodic-exporting-metricreader
pub const PeriodicExportingReader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exportIntervalMillis: u64,
    exportTimeoutMillis: u64,

    shared: ReaderShared = .{},
    collectThread: std.Thread = undefined,

    // This reader will collect metrics data from the MeterProvider.
    reader: *MetricReader,

    // The intervals at which the reader should export metrics data
    // and wait for each operation to complete.
    // Default values are dicated by the OpenTelemetry specification.
    const defaultExportIntervalMillis: u64 = 60000;
    const defaultExportTimeoutMillis: u64 = 30000;

    pub fn init(
        allocator: std.mem.Allocator,
        mp: *MeterProvider,
        exporter: *MetricExporter,
        exportIntervalMs: ?u64,
        exportTimeoutMs: ?u64,
    ) !*Self {
        const s = try allocator.create(Self);
        const timeout = exportTimeoutMs orelse defaultExportTimeoutMillis;

        const reader = try MetricReader.init(
            allocator,
            exporter,
        );
        // Set the export timeout on the reader so it can pass it to exportBatch
        reader.exportTimeout = timeout;

        s.* = Self{
            .allocator = allocator,
            .reader = reader,
            .exportIntervalMillis = exportIntervalMs orelse defaultExportIntervalMillis,
            .exportTimeoutMillis = timeout,
        };
        try mp.addReader(s.reader);

        s.collectThread = try std.Thread.spawn(
            .{},
            collectAndExport,
            .{ s.reader, &s.shared, s.exportIntervalMillis, s.exportTimeoutMillis },
        );
        return s;
    }

    pub fn shutdown(self: *Self) void {
        self.shared.lock.lock();
        self.shared.shuttingDown = true;
        self.shared.lock.unlock();
        self.shared.cond.signal();
        self.collectThread.join();

        self.reader.shutdown();

        // Only when the background collector has stopped we can destroy.
        self.allocator.destroy(self);
    }
};

// Function that collects metrics from the reader and exports it to the destination.
// The reader's exportTimeout (configured in PeriodicExportingReader.init) will be
// used to timeout the export operation.
fn collectAndExport(
    reader: *MetricReader,
    shared: *ReaderShared,
    exportIntervalMillis: u64,
    _: u64, // exportTimeoutMillis - no longer used here, configured on the reader
) void {
    shared.lock.lock();
    defer shared.lock.unlock();
    // The execution should continue until the reader is shutting down
    while (!shared.shuttingDown) {
        if (reader.meterProvider) |_| {
            // This will call exporter.exportBatch() with the configured timeout.
            reader.collect() catch |e| {
                log.err("PeriodicExportingReader: collecting failed on reader: {}", .{e});
            };
        } else {
            log.warn("PeriodicExportingReader: no meter provider is registered with this MetricReader {any}", .{reader});
        }
        // timedWait returns an error when the timeout is reached waiting for a signal, so we catch it and continue.
        // This is a way of keeping the timer running, becaus no other wake up signal is sent other than
        // during shutdown.
        // When the signal is actually received, the while loop exits because shared.shuttingDown has been set to true.
        shared.cond.timedWait(&shared.lock, exportIntervalMillis * std.time.ns_per_ms) catch continue;
    }
}

test "e2e periodic exporting metric reader" {
    const allocator = std.testing.allocator;

    const mp = try MeterProvider.init(allocator);
    defer mp.shutdown();

    const waiting_ms: u64 = 100;

    var inMem = try InMemoryExporter.init(allocator);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, &inMem.exporter);

    var per = try PeriodicExportingReader.init(
        allocator,
        mp,
        metric_exporter,
        waiting_ms,
        null,
    );
    defer per.shutdown();

    var meter = try mp.getMeter(.{ .name = "test-reader", .attributes = try Attributes.from(
        allocator,
        .{ "wonderful", true },
    ) });
    var counter = try meter.createCounter(u64, .{
        .name = "requests",
        .description = "a test counter",
    });
    try counter.add(10, .{});
    const val: []const u8 = "value";
    try counter.add(20, .{ "key", val });

    var histogram = try meter.createHistogram(f64, .{
        .name = "latency",
        .description = "a test histogram",
    });
    try histogram.record(1.4, .{});
    try histogram.record(10.4, .{});

    // Need to wait for the PeriodicExportingReader to collect and export the metrics.
    // Wait for more than 1 collection cycle to ensure that no duplication of data points occurs.
    std.Thread.sleep(waiting_ms * 4 * std.time.ns_per_ms);

    const data = try inMem.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }

    // There are 2 measurements: a counter and a histogram.
    try std.testing.expectEqual(2, data.len);
    // Meter attributes are added.
    try std.testing.expectEqual("test-reader", data[0].scope.name);
    try std.testing.expectEqual(1, data[0].scope.attributes.?.len);
    try std.testing.expectEqual("wonderful", data[0].scope.attributes.?[0].key);
    // Counter has 2 data points.
    try std.testing.expectEqual(2, data[0].data.int.len);
}

// Include testing for the exporters
test {
    _ = @import("exporters/in_memory.zig");
    _ = @import("exporters/otlp.zig");
    _ = @import("exporters/stdout.zig");
    _ = @import("exporters/file.zig");
    _ = @import("exporters/prometheus.zig");
}
