//! OpenTelemetry SDK C bindings.
//!
//! This module provides C-compatible wrappers for the Zig OpenTelemetry SDK,
//! allowing C programs to use OpenTelemetry instrumentation.
//!
//! ## Overview
//!
//! The C API exposes opaque handles for SDK objects and provides functions
//! to create, manipulate, and destroy them. All functions follow a consistent
//! naming convention:
//!
//! - `otel_<component>_create` - Create a new instance
//! - `otel_<component>_<action>` - Perform an action
//! - `otel_<component>_shutdown` - Cleanup and destroy
//!
//! ## Signals
//!
//! Currently supported signals:
//! - Metrics (see `c/metrics.zig`)
//!
//! ## Memory Management
//!
//! The C API manages memory internally using page allocators. Users must
//! call the appropriate shutdown/destroy functions to release resources.
//!
//! ## Thread Safety
//!
//! The underlying Zig SDK is thread-safe where specified. The C bindings
//! preserve these guarantees.

// ============================================================================
// Signal Modules
// ============================================================================

/// Metrics signal C bindings.
/// Provides MeterProvider, Meter, Counter, Histogram, Gauge, and related types.
pub const metrics = @import("c/metrics.zig");

// Force the metrics module to be analyzed at comptime so exports are registered
comptime {
    _ = metrics;
}

// ============================================================================
// API Bindings
// ============================================================================

// Baggage - TODO: Create proper C wrappers for baggage types
// The baggage API returns Zig types that need C-compatible wrappers
// const baggage = @import("api/baggage.zig");
// comptime {
//     @export(&baggage.getCurrentBaggage, .{ .name = "otel_baggage_get_current" });
// }

// ============================================================================
// Re-export types for convenience
// ============================================================================

// Re-export common types that C users might need
pub const OtelStatus = metrics.OtelStatus;
pub const OtelAttribute = metrics.OtelAttribute;
pub const OtelAttributeValueType = metrics.OtelAttributeValueType;

// Opaque handle types
pub const OtelMeterProvider = metrics.OtelMeterProvider;
pub const OtelMeter = metrics.OtelMeter;
pub const OtelCounterU64 = metrics.OtelCounterU64;
pub const OtelUpDownCounterI64 = metrics.OtelUpDownCounterI64;
pub const OtelHistogramF64 = metrics.OtelHistogramF64;
pub const OtelGaugeF64 = metrics.OtelGaugeF64;
pub const OtelMetricReader = metrics.OtelMetricReader;
pub const OtelMetricExporter = metrics.OtelMetricExporter;

// ============================================================================
// Tests
// ============================================================================

test {
    _ = metrics;
}
