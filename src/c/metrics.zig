//! OpenTelemetry Metrics SDK C bindings.
//!
//! This module provides C-compatible wrappers for the Zig Metrics SDK,
//! allowing C programs to use OpenTelemetry metrics instrumentation.
//!
//! ## Usage from C
//!
//! ```c
//! #include "opentelemetry.h"
//!
//! // Create a meter provider
//! otel_meter_provider_t* provider = otel_meter_provider_create();
//!
//! // Get a meter
//! otel_meter_t* meter = otel_meter_provider_get_meter(provider, "my-library", "1.0.0", NULL);
//!
//! // Create a counter
//! otel_counter_t* counter = otel_meter_create_counter_i64(meter, "my_counter", "A sample counter", "1");
//!
//! // Record a value
//! otel_counter_add_i64(counter, 1, NULL, 0);
//!
//! // Cleanup
//! otel_meter_provider_shutdown(provider);
//! ```

const std = @import("std");
const MeterProvider = @import("../api/metrics/meter.zig").MeterProvider;
const Meter = @import("../api/metrics/meter.zig").Meter;
const InstrumentOptions = @import("../api/metrics/instrument.zig").InstrumentOptions;
const Counter = @import("../api/metrics/instrument.zig").Counter;
const Histogram = @import("../api/metrics/instrument.zig").Histogram;
const Gauge = @import("../api/metrics/instrument.zig").Gauge;
const Attribute = @import("../attributes.zig").Attribute;
const MetricReader = @import("../sdk/metrics/reader.zig").MetricReader;
const MetricExporter = @import("../sdk/metrics/exporter.zig").MetricExporter;
const InMemoryExporter = @import("../sdk/metrics/exporters/in_memory.zig").InMemoryExporter;
const StdoutExporter = @import("../sdk/metrics/exporters/stdout.zig").StdoutExporter;

// ============================================================================
// Error Codes
// ============================================================================

/// Error codes returned by C API functions.
pub const OtelStatus = enum(c_int) {
    ok = 0,
    error_out_of_memory = -1,
    error_invalid_argument = -2,
    error_invalid_state = -3,
    error_already_shutdown = -4,
    error_export_failed = -5,
    error_collect_failed = -6,
    error_unknown = -99,
};

// ============================================================================
// Opaque Handle Types
// ============================================================================

/// Opaque handle to a MeterProvider.
pub const OtelMeterProvider = opaque {};

/// Opaque handle to a Meter.
pub const OtelMeter = opaque {};

/// Opaque handle to a Counter instrument (u64 values).
/// Monotonic counters only support unsigned types.
pub const OtelCounterU64 = opaque {};

/// Opaque handle to an UpDownCounter instrument (i64 values).
pub const OtelUpDownCounterI64 = opaque {};

/// Opaque handle to a Histogram instrument (f64 values).
pub const OtelHistogramF64 = opaque {};

/// Opaque handle to a Gauge instrument (f64 values).
pub const OtelGaugeF64 = opaque {};

/// Opaque handle to a MetricReader.
pub const OtelMetricReader = opaque {};

/// Opaque handle to a MetricExporter.
pub const OtelMetricExporter = opaque {};

// ============================================================================
// Attribute Types
// ============================================================================

/// Attribute value types for C API.
pub const OtelAttributeValueType = enum(c_int) {
    bool = 0,
    int = 1,
    double = 2,
    string = 3,
};

/// A key-value attribute pair for C API.
pub const OtelAttribute = extern struct {
    key: [*:0]const u8,
    value_type: OtelAttributeValueType,
    value: extern union {
        bool_value: bool,
        int_value: i64,
        double_value: f64,
        string_value: [*:0]const u8,
    },
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get the global allocator used for C bindings.
fn getCAllocator() std.mem.Allocator {
    // Use page allocator for C bindings - it's simple and doesn't require cleanup
    return std.heap.c_allocator;
}

/// Convert C attribute array to Zig attribute slice for instrument recording.
fn convertAttributes(
    allocator: std.mem.Allocator,
    c_attrs: [*c]const OtelAttribute,
    count: usize,
) !?[]Attribute {
    if (count == 0 or c_attrs == null) return null;

    var attrs = try allocator.alloc(Attribute, count);
    errdefer allocator.free(attrs);

    for (0..count) |i| {
        const c_attr = c_attrs[i];
        const key = std.mem.span(c_attr.key);

        attrs[i] = .{
            .key = key,
            .value = switch (c_attr.value_type) {
                .bool => .{ .bool = c_attr.value.bool_value },
                .int => .{ .int = c_attr.value.int_value },
                .double => .{ .double = c_attr.value.double_value },
                .string => .{ .string = std.mem.span(c_attr.value.string_value) },
            },
        };
    }

    return attrs;
}

// ============================================================================
// MeterProvider API
// ============================================================================

/// Create a new MeterProvider using the default allocator.
///
/// Returns: Pointer to the MeterProvider, or null on error.
pub fn meterProviderCreate() callconv(.c) ?*OtelMeterProvider {
    const provider = MeterProvider.default() catch return null;
    return @ptrCast(provider);
}

/// Create a new MeterProvider with a custom allocator (for advanced use).
///
/// Returns: Pointer to the MeterProvider, or null on error.
pub fn meterProviderInit() callconv(.c) ?*OtelMeterProvider {
    const allocator = getCAllocator();
    const provider = MeterProvider.init(allocator) catch return null;
    return @ptrCast(provider);
}

/// Shutdown the MeterProvider and release all resources.
///
/// After calling this function, the provider handle becomes invalid.
pub fn meterProviderShutdown(provider: ?*OtelMeterProvider) callconv(.c) void {
    if (provider) |p| {
        const mp: *MeterProvider = @ptrCast(@alignCast(p));
        mp.shutdown();
    }
}

/// Get a Meter from the MeterProvider.
///
/// Parameters:
/// - provider: The MeterProvider handle
/// - name: The name of the meter (null-terminated string)
/// - version: Optional version string (null-terminated, can be null)
/// - schema_url: Optional schema URL (null-terminated, can be null)
///
/// Returns: Pointer to the Meter, or null on error.
pub fn meterProviderGetMeter(
    provider: ?*OtelMeterProvider,
    name: [*:0]const u8,
    version: ?[*:0]const u8,
    schema_url: ?[*:0]const u8,
) callconv(.c) ?*OtelMeter {
    const p = provider orelse return null;
    const mp: *MeterProvider = @ptrCast(@alignCast(p));

    const scope = @import("../scope.zig").InstrumentationScope{
        .name = std.mem.span(name),
        .version = if (version) |v| std.mem.span(v) else null,
        .schema_url = if (schema_url) |s| std.mem.span(s) else null,
    };

    const meter = mp.getMeter(scope) catch return null;
    return @ptrCast(meter);
}

/// Add a MetricReader to the MeterProvider.
///
/// Returns: Status code indicating success or failure.
pub fn meterProviderAddReader(
    provider: ?*OtelMeterProvider,
    reader: ?*OtelMetricReader,
) callconv(.c) OtelStatus {
    const p = provider orelse return .error_invalid_argument;
    const r = reader orelse return .error_invalid_argument;

    const mp: *MeterProvider = @ptrCast(@alignCast(p));
    const mr: *MetricReader = @ptrCast(@alignCast(r));

    mp.addReader(mr) catch |err| {
        return switch (err) {
            error.OutOfMemory => .error_out_of_memory,
            else => .error_invalid_state,
        };
    };

    return .ok;
}

// ============================================================================
// Counter API (u64) - Monotonic counters use unsigned types
// ============================================================================

/// Create a new Counter instrument with u64 values.
/// Monotonic counters can only be incremented by non-negative values.
///
/// Parameters:
/// - meter: The Meter handle
/// - name: Instrument name (null-terminated)
/// - description: Optional description (null-terminated, can be null)
/// - unit: Optional unit (null-terminated, can be null)
///
/// Returns: Pointer to the Counter, or null on error.
pub fn meterCreateCounterU64(
    meter: ?*OtelMeter,
    name: [*:0]const u8,
    description: ?[*:0]const u8,
    unit: ?[*:0]const u8,
) callconv(.c) ?*OtelCounterU64 {
    const m = meter orelse return null;
    const zigMeter: *Meter = @ptrCast(@alignCast(m));

    const opts = InstrumentOptions{
        .name = std.mem.span(name),
        .description = if (description) |d| std.mem.span(d) else null,
        .unit = if (unit) |u| std.mem.span(u) else null,
    };

    const counter = zigMeter.createCounter(u64, opts) catch return null;
    return @ptrCast(counter);
}

/// Add a value to the Counter.
///
/// Parameters:
/// - counter: The Counter handle
/// - value: The value to add (must be non-negative)
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
///
/// Returns: Status code indicating success or failure.
pub fn counterAddU64(
    counter: ?*OtelCounterU64,
    value: u64,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const c = counter orelse return .error_invalid_argument;
    const zigCounter: *Counter(u64) = @ptrCast(@alignCast(c));

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    zigCounter.addWithSlice(value, attrs) catch return .error_out_of_memory;
    return .ok;
}

// ============================================================================
// UpDownCounter API (i64)
// ============================================================================

/// Create a new UpDownCounter instrument with i64 values.
///
/// Parameters:
/// - meter: The Meter handle
/// - name: Instrument name (null-terminated)
/// - description: Optional description (null-terminated, can be null)
/// - unit: Optional unit (null-terminated, can be null)
///
/// Returns: Pointer to the UpDownCounter, or null on error.
pub fn meterCreateUpDownCounterI64(
    meter: ?*OtelMeter,
    name: [*:0]const u8,
    description: ?[*:0]const u8,
    unit: ?[*:0]const u8,
) callconv(.c) ?*OtelUpDownCounterI64 {
    const m = meter orelse return null;
    const zigMeter: *Meter = @ptrCast(@alignCast(m));

    const opts = InstrumentOptions{
        .name = std.mem.span(name),
        .description = if (description) |d| std.mem.span(d) else null,
        .unit = if (unit) |u| std.mem.span(u) else null,
    };

    const counter = zigMeter.createUpDownCounter(i64, opts) catch return null;
    return @ptrCast(counter);
}

/// Add a value to the UpDownCounter (can be negative).
///
/// Parameters:
/// - counter: The UpDownCounter handle
/// - value: The value to add (can be positive or negative)
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
///
/// Returns: Status code indicating success or failure.
pub fn upDownCounterAddI64(
    counter: ?*OtelUpDownCounterI64,
    value: i64,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const c = counter orelse return .error_invalid_argument;
    const zigCounter: *Counter(i64) = @ptrCast(@alignCast(c));

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    zigCounter.addWithSlice(value, attrs) catch return .error_out_of_memory;
    return .ok;
}

// ============================================================================
// Histogram API (f64)
// ============================================================================

/// Create a new Histogram instrument with f64 values.
///
/// Parameters:
/// - meter: The Meter handle
/// - name: Instrument name (null-terminated)
/// - description: Optional description (null-terminated, can be null)
/// - unit: Optional unit (null-terminated, can be null)
///
/// Returns: Pointer to the Histogram, or null on error.
pub fn meterCreateHistogramF64(
    meter: ?*OtelMeter,
    name: [*:0]const u8,
    description: ?[*:0]const u8,
    unit: ?[*:0]const u8,
) callconv(.c) ?*OtelHistogramF64 {
    const m = meter orelse return null;
    const zigMeter: *Meter = @ptrCast(@alignCast(m));

    const opts = InstrumentOptions{
        .name = std.mem.span(name),
        .description = if (description) |d| std.mem.span(d) else null,
        .unit = if (unit) |u| std.mem.span(u) else null,
    };

    const histogram = zigMeter.createHistogram(f64, opts) catch return null;
    return @ptrCast(histogram);
}

/// Record a value in the Histogram.
///
/// Parameters:
/// - histogram: The Histogram handle
/// - value: The value to record
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
///
/// Returns: Status code indicating success or failure.
pub fn histogramRecordF64(
    histogram: ?*OtelHistogramF64,
    value: f64,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const h = histogram orelse return .error_invalid_argument;
    const zigHistogram: *Histogram(f64) = @ptrCast(@alignCast(h));

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    zigHistogram.recordWithSlice(value, attrs) catch return .error_out_of_memory;
    return .ok;
}

// ============================================================================
// Gauge API (f64)
// ============================================================================

/// Create a new Gauge instrument with f64 values.
///
/// Parameters:
/// - meter: The Meter handle
/// - name: Instrument name (null-terminated)
/// - description: Optional description (null-terminated, can be null)
/// - unit: Optional unit (null-terminated, can be null)
///
/// Returns: Pointer to the Gauge, or null on error.
pub fn meterCreateGaugeF64(
    meter: ?*OtelMeter,
    name: [*:0]const u8,
    description: ?[*:0]const u8,
    unit: ?[*:0]const u8,
) callconv(.c) ?*OtelGaugeF64 {
    const m = meter orelse return null;
    const zigMeter: *Meter = @ptrCast(@alignCast(m));

    const opts = InstrumentOptions{
        .name = std.mem.span(name),
        .description = if (description) |d| std.mem.span(d) else null,
        .unit = if (unit) |u| std.mem.span(u) else null,
    };

    const gauge = zigMeter.createGauge(f64, opts) catch return null;
    return @ptrCast(gauge);
}

/// Record a value in the Gauge.
///
/// Parameters:
/// - gauge: The Gauge handle
/// - value: The value to record
/// - attributes: Array of attributes (can be null)
/// - attr_count: Number of attributes
///
/// Returns: Status code indicating success or failure.
pub fn gaugeRecordF64(
    gauge: ?*OtelGaugeF64,
    value: f64,
    attributes: [*c]const OtelAttribute,
    attr_count: usize,
) callconv(.c) OtelStatus {
    const g = gauge orelse return .error_invalid_argument;
    const zigGauge: *Gauge(f64) = @ptrCast(@alignCast(g));

    const allocator = getCAllocator();
    const attrs = convertAttributes(allocator, attributes, attr_count) catch return .error_out_of_memory;
    defer if (attrs) |a| allocator.free(a);

    zigGauge.recordWithSlice(value, attrs) catch return .error_out_of_memory;
    return .ok;
}

// ============================================================================
// MetricExporter API
// ============================================================================

/// Create a new stdout MetricExporter for debugging.
///
/// Returns: Pointer to the MetricExporter, or null on error.
pub fn metricExporterStdoutCreate() callconv(.c) ?*OtelMetricExporter {
    const allocator = getCAllocator();
    const result = MetricExporter.Stdout(allocator, null, null) catch return null;
    return @ptrCast(result.exporter);
}

/// Create a new in-memory MetricExporter.
///
/// Returns: Pointer to the MetricExporter, or null on error.
pub fn metricExporterInMemoryCreate() callconv(.c) ?*OtelMetricExporter {
    const allocator = getCAllocator();
    const result = MetricExporter.InMemory(allocator, null, null) catch return null;
    return @ptrCast(result.exporter);
}

// ============================================================================
// MetricReader API
// ============================================================================

/// Create a new MetricReader with the given exporter.
///
/// Parameters:
/// - exporter: The MetricExporter handle
///
/// Returns: Pointer to the MetricReader, or null on error.
pub fn metricReaderCreate(exporter: ?*OtelMetricExporter) callconv(.c) ?*OtelMetricReader {
    const e = exporter orelse return null;
    const allocator = getCAllocator();
    const me: *MetricExporter = @ptrCast(@alignCast(e));

    const reader = MetricReader.init(allocator, me) catch return null;
    return @ptrCast(reader);
}

/// Trigger a collection cycle on the MetricReader.
///
/// Returns: Status code indicating success or failure.
pub fn metricReaderCollect(reader: ?*OtelMetricReader) callconv(.c) OtelStatus {
    const r = reader orelse return .error_invalid_argument;
    const mr: *MetricReader = @ptrCast(@alignCast(r));

    mr.collect() catch |err| {
        return switch (err) {
            error.CollectFailedOnMissingMeterProvider => .error_invalid_state,
            error.ExportFailed => .error_export_failed,
            error.OutOfMemory => .error_out_of_memory,
            else => .error_collect_failed,
        };
    };

    return .ok;
}

/// Shutdown the MetricReader and release resources.
///
/// After calling this function, the reader handle becomes invalid.
pub fn metricReaderShutdown(reader: ?*OtelMetricReader) callconv(.c) void {
    if (reader) |r| {
        const mr: *MetricReader = @ptrCast(@alignCast(r));
        mr.shutdown();
    }
}

// ============================================================================
// C Export Declarations
// ============================================================================

comptime {
    // MeterProvider exports
    @export(&meterProviderCreate, .{ .name = "otel_meter_provider_create" });
    @export(&meterProviderInit, .{ .name = "otel_meter_provider_init" });
    @export(&meterProviderShutdown, .{ .name = "otel_meter_provider_shutdown" });
    @export(&meterProviderGetMeter, .{ .name = "otel_meter_provider_get_meter" });
    @export(&meterProviderAddReader, .{ .name = "otel_meter_provider_add_reader" });

    // Counter exports (u64 - monotonic counters use unsigned types)
    @export(&meterCreateCounterU64, .{ .name = "otel_meter_create_counter_u64" });
    @export(&counterAddU64, .{ .name = "otel_counter_add_u64" });

    // UpDownCounter exports (i64 - can go up or down)
    @export(&meterCreateUpDownCounterI64, .{ .name = "otel_meter_create_updown_counter_i64" });
    @export(&upDownCounterAddI64, .{ .name = "otel_updown_counter_add_i64" });

    // Histogram exports
    @export(&meterCreateHistogramF64, .{ .name = "otel_meter_create_histogram_f64" });
    @export(&histogramRecordF64, .{ .name = "otel_histogram_record_f64" });

    // Gauge exports
    @export(&meterCreateGaugeF64, .{ .name = "otel_meter_create_gauge_f64" });
    @export(&gaugeRecordF64, .{ .name = "otel_gauge_record_f64" });

    // MetricExporter exports
    @export(&metricExporterStdoutCreate, .{ .name = "otel_metric_exporter_stdout_create" });
    @export(&metricExporterInMemoryCreate, .{ .name = "otel_metric_exporter_inmemory_create" });

    // MetricReader exports
    @export(&metricReaderCreate, .{ .name = "otel_metric_reader_create" });
    @export(&metricReaderCollect, .{ .name = "otel_metric_reader_collect" });
    @export(&metricReaderShutdown, .{ .name = "otel_metric_reader_shutdown" });
}

// ============================================================================
// Tests
// ============================================================================

test "metrics C API - create and use counter" {
    const provider = meterProviderCreate();
    try std.testing.expect(provider != null);
    defer meterProviderShutdown(provider);

    const meter = meterProviderGetMeter(provider, "test-meter", "1.0.0", null);
    try std.testing.expect(meter != null);

    const counter = meterCreateCounterU64(meter, "test_counter", "A test counter", "1");
    try std.testing.expect(counter != null);

    const status = counterAddU64(counter, 42, null, 0);
    try std.testing.expectEqual(OtelStatus.ok, status);
}

test "metrics C API - create histogram and record" {
    const provider = meterProviderCreate();
    try std.testing.expect(provider != null);
    defer meterProviderShutdown(provider);

    const meter = meterProviderGetMeter(provider, "test-meter", null, null);
    try std.testing.expect(meter != null);

    const histogram = meterCreateHistogramF64(meter, "request_duration", "Duration of requests", "ms");
    try std.testing.expect(histogram != null);

    const status = histogramRecordF64(histogram, 123.45, null, 0);
    try std.testing.expectEqual(OtelStatus.ok, status);
}

test "metrics C API - full pipeline with reader" {
    const provider = meterProviderCreate();
    try std.testing.expect(provider != null);
    defer meterProviderShutdown(provider);

    const exporter = metricExporterInMemoryCreate();
    try std.testing.expect(exporter != null);

    const reader = metricReaderCreate(exporter);
    try std.testing.expect(reader != null);

    const add_status = meterProviderAddReader(provider, reader);
    try std.testing.expectEqual(OtelStatus.ok, add_status);

    const meter = meterProviderGetMeter(provider, "test-meter", null, null);
    try std.testing.expect(meter != null);

    const counter = meterCreateCounterU64(meter, "requests", null, null);
    try std.testing.expect(counter != null);

    _ = counterAddU64(counter, 10, null, 0);
    _ = counterAddU64(counter, 20, null, 0);

    const collect_status = metricReaderCollect(reader);
    try std.testing.expectEqual(OtelStatus.ok, collect_status);
}
