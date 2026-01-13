/**
 * @file opentelemetry.h
 * @brief OpenTelemetry C API Header
 *
 * This header provides C-compatible bindings for the OpenTelemetry Zig SDK.
 * It allows C programs to instrument their applications with OpenTelemetry
 * metrics, traces, and logs.
 *
 * ## Quick Start
 *
 * ```c
 * #include "opentelemetry.h"
 *
 * int main() {
 *     // Create a meter provider
 *     otel_meter_provider_t* provider = otel_meter_provider_create();
 *     if (!provider) return 1;
 *
 *     // Create an exporter and reader
 *     otel_metric_exporter_t* exporter = otel_metric_exporter_stdout_create();
 *     otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
 *     otel_meter_provider_add_reader(provider, reader);
 *
 *     // Get a meter
 *     otel_meter_t* meter = otel_meter_provider_get_meter(
 *         provider, "my-service", "1.0.0", NULL);
 *
 *     // Create and use a counter
 *     otel_counter_u64_t* counter = otel_meter_create_counter_u64(
 *         meter, "requests", "Total requests", "1");
 *     otel_counter_add_u64(counter, 1, NULL, 0);
 *
 *     // Collect and export metrics
 *     otel_metric_reader_collect(reader);
 *
 *     // Cleanup
 *     otel_meter_provider_shutdown(provider);
 *     return 0;
 * }
 * ```
 *
 * @note Link with the compiled OpenTelemetry Zig library.
 */

#ifndef OPENTELEMETRY_H
#define OPENTELEMETRY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Status Codes
 * ============================================================================ */

/**
 * @brief Status codes returned by OpenTelemetry C API functions.
 */
typedef enum {
    OTEL_STATUS_OK = 0,                  /**< Operation succeeded */
    OTEL_STATUS_ERROR_OUT_OF_MEMORY = -1, /**< Memory allocation failed */
    OTEL_STATUS_ERROR_INVALID_ARGUMENT = -2, /**< Invalid argument provided */
    OTEL_STATUS_ERROR_INVALID_STATE = -3,    /**< Invalid state for operation */
    OTEL_STATUS_ERROR_ALREADY_SHUTDOWN = -4, /**< Component already shut down */
    OTEL_STATUS_ERROR_EXPORT_FAILED = -5,    /**< Export operation failed */
    OTEL_STATUS_ERROR_COLLECT_FAILED = -6,   /**< Collection operation failed */
    OTEL_STATUS_ERROR_UNKNOWN = -99          /**< Unknown error */
} otel_status_t;

/* ============================================================================
 * Opaque Handle Types
 * ============================================================================ */

/**
 * @brief Opaque handle to a MeterProvider.
 *
 * MeterProvider is the entry point for the Metrics API. It provides access
 * to Meters which are used to create instruments.
 */
typedef struct otel_meter_provider otel_meter_provider_t;

/**
 * @brief Opaque handle to a Meter.
 *
 * A Meter is used to create instruments (Counter, Histogram, Gauge, etc.)
 * for recording measurements.
 */
typedef struct otel_meter otel_meter_t;

/**
 * @brief Opaque handle to a Counter instrument with u64 values.
 *
 * A Counter is a monotonically increasing value. Use add() to increment.
 * Counter uses unsigned integers since it can only increase.
 */
typedef struct otel_counter_u64 otel_counter_u64_t;

/**
 * @brief Opaque handle to an UpDownCounter instrument with i64 values.
 *
 * An UpDownCounter can increase or decrease. Use add() with positive
 * or negative values.
 */
typedef struct otel_updown_counter_i64 otel_updown_counter_i64_t;

/**
 * @brief Opaque handle to a Histogram instrument with f64 values.
 *
 * A Histogram records a distribution of values. Use record() to add
 * measurements.
 */
typedef struct otel_histogram_f64 otel_histogram_f64_t;

/**
 * @brief Opaque handle to a Gauge instrument with f64 values.
 *
 * A Gauge records point-in-time values. Use record() to set the current
 * value.
 */
typedef struct otel_gauge_f64 otel_gauge_f64_t;

/**
 * @brief Opaque handle to a MetricReader.
 *
 * A MetricReader collects metrics from a MeterProvider and exports them
 * using a MetricExporter.
 */
typedef struct otel_metric_reader otel_metric_reader_t;

/**
 * @brief Opaque handle to a MetricExporter.
 *
 * A MetricExporter exports metrics to a destination (stdout, OTLP, etc.).
 */
typedef struct otel_metric_exporter otel_metric_exporter_t;

/* ============================================================================
 * Attribute Types
 * ============================================================================ */

/**
 * @brief Attribute value types.
 */
typedef enum {
    OTEL_ATTRIBUTE_TYPE_BOOL = 0,   /**< Boolean value */
    OTEL_ATTRIBUTE_TYPE_INT = 1,    /**< 64-bit signed integer */
    OTEL_ATTRIBUTE_TYPE_DOUBLE = 2, /**< 64-bit floating point */
    OTEL_ATTRIBUTE_TYPE_STRING = 3  /**< Null-terminated string */
} otel_attribute_value_type_t;

/**
 * @brief A key-value attribute for adding metadata to measurements.
 *
 * Attributes provide additional context to measurements. They are
 * key-value pairs where the value can be a bool, int, double, or string.
 *
 * Example:
 * ```c
 * otel_attribute_t attrs[] = {
 *     {.key = "method", .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
 *      .value = {.string_value = "GET"}},
 *     {.key = "status", .value_type = OTEL_ATTRIBUTE_TYPE_INT,
 *      .value = {.int_value = 200}}
 * };
 * otel_counter_add_i64(counter, 1, attrs, 2);
 * ```
 */
typedef struct {
    const char* key;                /**< Attribute key (null-terminated) */
    otel_attribute_value_type_t value_type; /**< Type of the value */
    union {
        bool bool_value;            /**< Boolean value */
        int64_t int_value;          /**< Integer value */
        double double_value;        /**< Double value */
        const char* string_value;   /**< String value (null-terminated) */
    } value;
} otel_attribute_t;

/* ============================================================================
 * MeterProvider API
 * ============================================================================ */

/**
 * @brief Create a new MeterProvider using the default allocator.
 *
 * Creates a MeterProvider that manages Meters and their instruments.
 * The provider must be shut down with otel_meter_provider_shutdown()
 * when no longer needed.
 *
 * @return Pointer to the MeterProvider, or NULL on error.
 *
 * Example:
 * ```c
 * otel_meter_provider_t* provider = otel_meter_provider_create();
 * if (provider) {
 *     // Use the provider...
 *     otel_meter_provider_shutdown(provider);
 * }
 * ```
 */
otel_meter_provider_t* otel_meter_provider_create(void);

/**
 * @brief Create a new MeterProvider with explicit initialization.
 *
 * Similar to otel_meter_provider_create() but uses a different
 * internal allocator. For most use cases, prefer otel_meter_provider_create().
 *
 * @return Pointer to the MeterProvider, or NULL on error.
 */
otel_meter_provider_t* otel_meter_provider_init(void);

/**
 * @brief Shutdown the MeterProvider and release all resources.
 *
 * This function flushes all pending metrics, shuts down all associated
 * readers and exporters, and frees all memory. After calling this function,
 * the provider handle becomes invalid and must not be used.
 *
 * @param provider The MeterProvider to shutdown. Can be NULL (no-op).
 */
void otel_meter_provider_shutdown(otel_meter_provider_t* provider);

/**
 * @brief Get a Meter from the MeterProvider.
 *
 * Returns a Meter for the given instrumentation scope. If a Meter with
 * the same scope already exists, it is returned. Otherwise, a new Meter
 * is created.
 *
 * @param provider The MeterProvider handle.
 * @param name The name of the instrumentation scope (required, null-terminated).
 * @param version Optional version string (null-terminated, can be NULL).
 * @param schema_url Optional schema URL (null-terminated, can be NULL).
 * @return Pointer to the Meter, or NULL on error.
 *
 * Example:
 * ```c
 * otel_meter_t* meter = otel_meter_provider_get_meter(
 *     provider, "my-library", "1.0.0", NULL);
 * ```
 */
otel_meter_t* otel_meter_provider_get_meter(
    otel_meter_provider_t* provider,
    const char* name,
    const char* version,
    const char* schema_url);

/**
 * @brief Add a MetricReader to the MeterProvider.
 *
 * Registers a MetricReader with the provider. The reader will collect
 * metrics from all Meters managed by this provider.
 *
 * @param provider The MeterProvider handle.
 * @param reader The MetricReader to add.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_meter_provider_add_reader(
    otel_meter_provider_t* provider,
    otel_metric_reader_t* reader);

/* ============================================================================
 * Counter API (u64)
 * ============================================================================ */

/**
 * @brief Create a new Counter instrument with u64 values.
 *
 * A Counter is a monotonically increasing value. It uses unsigned integers
 * since counters can only be incremented (never negative).
 *
 * @param meter The Meter handle.
 * @param name Instrument name (required, null-terminated).
 * @param description Optional description (null-terminated, can be NULL).
 * @param unit Optional unit (null-terminated, can be NULL). Example: "1", "ms", "bytes".
 * @return Pointer to the Counter, or NULL on error.
 *
 * Example:
 * ```c
 * otel_counter_u64_t* counter = otel_meter_create_counter_u64(
 *     meter, "http.requests", "Total HTTP requests", "1");
 * ```
 */
otel_counter_u64_t* otel_meter_create_counter_u64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);

/**
 * @brief Add a value to the Counter.
 *
 * Increments the counter by the given value.
 *
 * @param counter The Counter handle.
 * @param value The value to add (unsigned).
 * @param attributes Array of attributes (can be NULL if attr_count is 0).
 * @param attr_count Number of attributes in the array.
 * @return Status code indicating success or failure.
 *
 * Example:
 * ```c
 * // Simple increment
 * otel_counter_add_u64(counter, 1, NULL, 0);
 *
 * // With attributes
 * otel_attribute_t attrs[] = {
 *     {.key = "method", .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
 *      .value = {.string_value = "GET"}}
 * };
 * otel_counter_add_u64(counter, 1, attrs, 1);
 * ```
 */
otel_status_t otel_counter_add_u64(
    otel_counter_u64_t* counter,
    uint64_t value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* ============================================================================
 * UpDownCounter API (i64)
 * ============================================================================ */

/**
 * @brief Create a new UpDownCounter instrument with i64 values.
 *
 * An UpDownCounter can both increase and decrease. It's useful for
 * values that can go up or down, like active connections or queue size.
 *
 * @param meter The Meter handle.
 * @param name Instrument name (required, null-terminated).
 * @param description Optional description (null-terminated, can be NULL).
 * @param unit Optional unit (null-terminated, can be NULL).
 * @return Pointer to the UpDownCounter, or NULL on error.
 */
otel_updown_counter_i64_t* otel_meter_create_updown_counter_i64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);

/**
 * @brief Add a value to the UpDownCounter.
 *
 * Adds the given value to the counter. The value can be positive
 * (increment) or negative (decrement).
 *
 * @param counter The UpDownCounter handle.
 * @param value The value to add (can be positive or negative).
 * @param attributes Array of attributes (can be NULL if attr_count is 0).
 * @param attr_count Number of attributes in the array.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_updown_counter_add_i64(
    otel_updown_counter_i64_t* counter,
    int64_t value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* ============================================================================
 * Histogram API (f64)
 * ============================================================================ */

/**
 * @brief Create a new Histogram instrument with f64 values.
 *
 * A Histogram samples observations and counts them in buckets. It's
 * useful for measuring durations, sizes, and other distributions.
 *
 * @param meter The Meter handle.
 * @param name Instrument name (required, null-terminated).
 * @param description Optional description (null-terminated, can be NULL).
 * @param unit Optional unit (null-terminated, can be NULL). Example: "ms", "bytes".
 * @return Pointer to the Histogram, or NULL on error.
 */
otel_histogram_f64_t* otel_meter_create_histogram_f64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);

/**
 * @brief Record a value in the Histogram.
 *
 * Records an observation in the histogram. The value will be counted
 * in the appropriate bucket.
 *
 * @param histogram The Histogram handle.
 * @param value The value to record.
 * @param attributes Array of attributes (can be NULL if attr_count is 0).
 * @param attr_count Number of attributes in the array.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_histogram_record_f64(
    otel_histogram_f64_t* histogram,
    double value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* ============================================================================
 * Gauge API (f64)
 * ============================================================================ */

/**
 * @brief Create a new Gauge instrument with f64 values.
 *
 * A Gauge records point-in-time values. It's useful for values that
 * fluctuate, like temperature, CPU usage, or memory usage.
 *
 * @param meter The Meter handle.
 * @param name Instrument name (required, null-terminated).
 * @param description Optional description (null-terminated, can be NULL).
 * @param unit Optional unit (null-terminated, can be NULL).
 * @return Pointer to the Gauge, or NULL on error.
 */
otel_gauge_f64_t* otel_meter_create_gauge_f64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);

/**
 * @brief Record a value in the Gauge.
 *
 * Records the current value of the gauge.
 *
 * @param gauge The Gauge handle.
 * @param value The value to record.
 * @param attributes Array of attributes (can be NULL if attr_count is 0).
 * @param attr_count Number of attributes in the array.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_gauge_record_f64(
    otel_gauge_f64_t* gauge,
    double value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* ============================================================================
 * MetricExporter API
 * ============================================================================ */

/**
 * @brief Create a stdout MetricExporter for debugging.
 *
 * Creates an exporter that writes metrics to standard output in a
 * human-readable format. Useful for debugging and development.
 *
 * @return Pointer to the MetricExporter, or NULL on error.
 */
otel_metric_exporter_t* otel_metric_exporter_stdout_create(void);

/**
 * @brief Create an in-memory MetricExporter.
 *
 * Creates an exporter that stores metrics in memory. Useful for testing
 * and scenarios where metrics need to be accessed programmatically.
 *
 * @return Pointer to the MetricExporter, or NULL on error.
 */
otel_metric_exporter_t* otel_metric_exporter_inmemory_create(void);

/* ============================================================================
 * MetricReader API
 * ============================================================================ */

/**
 * @brief Create a MetricReader with the given exporter.
 *
 * A MetricReader collects metrics from a MeterProvider and exports them
 * using the provided exporter.
 *
 * @param exporter The MetricExporter to use.
 * @return Pointer to the MetricReader, or NULL on error.
 */
otel_metric_reader_t* otel_metric_reader_create(otel_metric_exporter_t* exporter);

/**
 * @brief Trigger a collection cycle on the MetricReader.
 *
 * Collects all metrics from the associated MeterProvider and exports
 * them using the configured exporter.
 *
 * @param reader The MetricReader handle.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_metric_reader_collect(otel_metric_reader_t* reader);

/**
 * @brief Shutdown the MetricReader and release resources.
 *
 * Performs a final collection, shuts down the exporter, and frees
 * all memory. After calling this function, the reader handle becomes
 * invalid and must not be used.
 *
 * @param reader The MetricReader to shutdown. Can be NULL (no-op).
 */
void otel_metric_reader_shutdown(otel_metric_reader_t* reader);

/* ============================================================================
 * Tracing API - Opaque Handle Types
 * ============================================================================ */

/**
 * @brief Opaque handle to a TracerProvider.
 *
 * TracerProvider is the entry point for the Tracing API. It provides access
 * to Tracers which are used to create Spans.
 */
typedef struct otel_tracer_provider otel_tracer_provider_t;

/**
 * @brief Opaque handle to a Tracer.
 *
 * A Tracer is used to create Spans for recording distributed traces.
 */
typedef struct otel_tracer otel_tracer_t;

/**
 * @brief Opaque handle to a Span.
 *
 * A Span represents a single operation within a trace. Spans can be
 * nested to form a trace tree.
 */
typedef struct otel_span otel_span_t;

/**
 * @brief Opaque handle to a SpanProcessor.
 *
 * A SpanProcessor processes spans as they are started and ended.
 */
typedef struct otel_span_processor otel_span_processor_t;

/**
 * @brief Opaque handle to a SpanExporter.
 *
 * A SpanExporter exports spans to a destination (stdout, OTLP, etc.).
 */
typedef struct otel_span_exporter otel_span_exporter_t;

/* ============================================================================
 * Tracing API - Enums
 * ============================================================================ */

/**
 * @brief Span kind values.
 *
 * SpanKind describes the relationship between the Span, its parents,
 * and its children in a Trace.
 */
typedef enum {
    OTEL_SPAN_KIND_INTERNAL = 0, /**< Default. Internal operation */
    OTEL_SPAN_KIND_SERVER = 1,   /**< Server-side handling of a request */
    OTEL_SPAN_KIND_CLIENT = 2,   /**< Client-side request to a remote service */
    OTEL_SPAN_KIND_PRODUCER = 3, /**< Initiation of an async operation */
    OTEL_SPAN_KIND_CONSUMER = 4  /**< Processing of an async operation */
} otel_span_kind_t;

/**
 * @brief Span status codes.
 */
typedef enum {
    OTEL_SPAN_STATUS_UNSET = 0, /**< Default status */
    OTEL_SPAN_STATUS_OK = 1,    /**< Operation completed successfully */
    OTEL_SPAN_STATUS_ERROR = 2  /**< Operation failed */
} otel_span_status_code_t;

/**
 * @brief Options for starting a span.
 */
typedef struct {
    otel_span_kind_t kind;           /**< Span kind (default: INTERNAL) */
    const otel_attribute_t* attributes; /**< Initial attributes (can be NULL) */
    size_t attr_count;               /**< Number of attributes */
    uint64_t start_timestamp_ns;     /**< Start time in nanoseconds (0 = now) */
} otel_span_start_options_t;

/* ============================================================================
 * TracerProvider API
 * ============================================================================ */

/**
 * @brief Create a new TracerProvider.
 *
 * Creates a TracerProvider that manages Tracers and their Spans.
 * The provider must be shut down with otel_tracer_provider_shutdown()
 * when no longer needed.
 *
 * @return Pointer to the TracerProvider, or NULL on error.
 *
 * Example:
 * ```c
 * otel_tracer_provider_t* provider = otel_tracer_provider_create();
 * if (provider) {
 *     // Use the provider...
 *     otel_tracer_provider_shutdown(provider);
 * }
 * ```
 */
otel_tracer_provider_t* otel_tracer_provider_create(void);

/**
 * @brief Shutdown the TracerProvider and release all resources.
 *
 * This function flushes all pending spans, shuts down all associated
 * processors and exporters, and frees all memory. After calling this
 * function, the provider handle becomes invalid and must not be used.
 *
 * @param provider The TracerProvider to shutdown. Can be NULL (no-op).
 */
void otel_tracer_provider_shutdown(otel_tracer_provider_t* provider);

/**
 * @brief Get a Tracer from the TracerProvider.
 *
 * Returns a Tracer for the given instrumentation scope. If a Tracer with
 * the same scope already exists, it is returned. Otherwise, a new Tracer
 * is created.
 *
 * @param provider The TracerProvider handle.
 * @param name The name of the instrumentation scope (required, null-terminated).
 * @param version Optional version string (null-terminated, can be NULL).
 * @param schema_url Optional schema URL (null-terminated, can be NULL).
 * @return Pointer to the Tracer, or NULL on error.
 *
 * Example:
 * ```c
 * otel_tracer_t* tracer = otel_tracer_provider_get_tracer(
 *     provider, "my-library", "1.0.0", NULL);
 * ```
 */
otel_tracer_t* otel_tracer_provider_get_tracer(
    otel_tracer_provider_t* provider,
    const char* name,
    const char* version,
    const char* schema_url);

/**
 * @brief Add a SpanProcessor to the TracerProvider.
 *
 * Registers a SpanProcessor with the provider. The processor will be
 * called for all spans created by tracers from this provider.
 *
 * @param provider The TracerProvider handle.
 * @param processor The SpanProcessor to add.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_tracer_provider_add_span_processor(
    otel_tracer_provider_t* provider,
    otel_span_processor_t* processor);

/**
 * @brief Force flush all span processors.
 *
 * @param provider The TracerProvider handle.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_tracer_provider_force_flush(otel_tracer_provider_t* provider);

/* ============================================================================
 * Tracer API
 * ============================================================================ */

/**
 * @brief Start a new Span.
 *
 * Creates a new span with the given name. The span must be ended with
 * otel_span_end() when the operation completes.
 *
 * @param tracer The Tracer handle.
 * @param name The span name (required, null-terminated).
 * @param options Optional span start options (can be NULL for defaults).
 * @return Pointer to the Span, or NULL on error.
 *
 * Example:
 * ```c
 * otel_span_t* span = otel_tracer_start_span(tracer, "my-operation", NULL);
 * // ... do work ...
 * otel_span_end(span);
 * ```
 */
otel_span_t* otel_tracer_start_span(
    otel_tracer_t* tracer,
    const char* name,
    const otel_span_start_options_t* options);

/**
 * @brief Check if the tracer is enabled.
 *
 * @param tracer The Tracer handle.
 * @return true if the tracer is enabled, false otherwise.
 */
bool otel_tracer_is_enabled(otel_tracer_t* tracer);

/* ============================================================================
 * Span API
 * ============================================================================ */

/**
 * @brief End a Span.
 *
 * Ends the span and exports it via the configured processors.
 * After calling this function, the span handle becomes invalid.
 *
 * @param span The Span to end. Can be NULL (no-op).
 */
void otel_span_end(otel_span_t* span);

/**
 * @brief End a Span with a specific timestamp.
 *
 * @param span The Span to end.
 * @param timestamp_ns End timestamp in nanoseconds since epoch.
 */
void otel_span_end_with_timestamp(otel_span_t* span, uint64_t timestamp_ns);

/**
 * @brief Set a string attribute on the Span.
 *
 * @param span The Span handle.
 * @param key Attribute key (null-terminated).
 * @param value Attribute value (null-terminated).
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_set_attribute_string(
    otel_span_t* span,
    const char* key,
    const char* value);

/**
 * @brief Set an integer attribute on the Span.
 *
 * @param span The Span handle.
 * @param key Attribute key (null-terminated).
 * @param value Attribute value.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_set_attribute_int(
    otel_span_t* span,
    const char* key,
    int64_t value);

/**
 * @brief Set a double attribute on the Span.
 *
 * @param span The Span handle.
 * @param key Attribute key (null-terminated).
 * @param value Attribute value.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_set_attribute_double(
    otel_span_t* span,
    const char* key,
    double value);

/**
 * @brief Set a boolean attribute on the Span.
 *
 * @param span The Span handle.
 * @param key Attribute key (null-terminated).
 * @param value Attribute value.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_set_attribute_bool(
    otel_span_t* span,
    const char* key,
    bool value);

/**
 * @brief Add an event to the Span.
 *
 * Events represent something that happened during a Span's lifetime.
 *
 * @param span The Span handle.
 * @param name Event name (null-terminated).
 * @param attributes Array of attributes (can be NULL).
 * @param attr_count Number of attributes.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_add_event(
    otel_span_t* span,
    const char* name,
    const otel_attribute_t* attributes,
    size_t attr_count);

/**
 * @brief Add an event with a specific timestamp.
 *
 * @param span The Span handle.
 * @param name Event name (null-terminated).
 * @param timestamp_ns Event timestamp in nanoseconds since epoch.
 * @param attributes Array of attributes (can be NULL).
 * @param attr_count Number of attributes.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_add_event_with_timestamp(
    otel_span_t* span,
    const char* name,
    uint64_t timestamp_ns,
    const otel_attribute_t* attributes,
    size_t attr_count);

/**
 * @brief Set the status of the Span.
 *
 * @param span The Span handle.
 * @param code Status code.
 * @param description Optional description (null-terminated, can be NULL).
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_set_status(
    otel_span_t* span,
    otel_span_status_code_t code,
    const char* description);

/**
 * @brief Update the name of the Span.
 *
 * @param span The Span handle.
 * @param name New span name (null-terminated).
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_update_name(otel_span_t* span, const char* name);

/**
 * @brief Record an exception on the Span.
 *
 * Records an exception as an event with standard exception attributes.
 *
 * @param span The Span handle.
 * @param exception_type Exception type (null-terminated).
 * @param message Exception message (null-terminated).
 * @param stacktrace Optional stack trace (null-terminated, can be NULL).
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_record_exception(
    otel_span_t* span,
    const char* exception_type,
    const char* message,
    const char* stacktrace);

/**
 * @brief Check if the Span is recording.
 *
 * @param span The Span handle.
 * @return true if the span is recording, false otherwise.
 */
bool otel_span_is_recording(otel_span_t* span);

/**
 * @brief Get the trace ID as a hex string.
 *
 * @param span The Span handle.
 * @param buffer Buffer to write the hex string (must be at least 33 bytes).
 * @param buffer_size Size of the buffer.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_get_trace_id_hex(
    otel_span_t* span,
    char* buffer,
    size_t buffer_size);

/**
 * @brief Get the span ID as a hex string.
 *
 * @param span The Span handle.
 * @param buffer Buffer to write the hex string (must be at least 17 bytes).
 * @param buffer_size Size of the buffer.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_span_get_span_id_hex(
    otel_span_t* span,
    char* buffer,
    size_t buffer_size);

/* ============================================================================
 * SpanExporter API
 * ============================================================================ */

/**
 * @brief Create a stdout SpanExporter for debugging.
 *
 * Creates an exporter that writes spans to standard output in a
 * human-readable JSON format. Useful for debugging and development.
 *
 * @return Pointer to the SpanExporter, or NULL on error.
 */
otel_span_exporter_t* otel_span_exporter_stdout_create(void);

/* ============================================================================
 * SpanProcessor API
 * ============================================================================ */

/**
 * @brief Create a SimpleSpanProcessor.
 *
 * A SimpleSpanProcessor exports spans immediately when they end.
 * This is useful for debugging but may not be suitable for production
 * due to the synchronous export on the critical path.
 *
 * @param exporter The SpanExporter to use.
 * @return Pointer to the SpanProcessor, or NULL on error.
 */
otel_span_processor_t* otel_simple_span_processor_create(
    otel_span_exporter_t* exporter);

/* ============================================================================
 * LOGS API
 * ============================================================================ */

/* ============================================================================
 * Logs Opaque Handle Types
 * ============================================================================ */

/**
 * @brief Opaque handle to a LoggerProvider.
 *
 * A LoggerProvider is the entry point for the Logs SDK. It provides
 * Loggers and manages log record processors.
 */
typedef struct otel_logger_provider_t otel_logger_provider_t;

/**
 * @brief Opaque handle to a Logger.
 *
 * A Logger emits log records to the configured log record processors.
 */
typedef struct otel_logger_t otel_logger_t;

/**
 * @brief Opaque handle to a LogRecordProcessor.
 *
 * A LogRecordProcessor receives log records from Loggers and forwards
 * them to LogRecordExporters.
 */
typedef struct otel_log_record_processor_t otel_log_record_processor_t;

/**
 * @brief Opaque handle to a LogRecordExporter.
 *
 * A LogRecordExporter exports log records to a backend.
 */
typedef struct otel_log_record_exporter_t otel_log_record_exporter_t;

/* ============================================================================
 * Severity Levels
 * ============================================================================ */

/**
 * @brief Severity number values for logs (OpenTelemetry specification).
 */
typedef enum {
    OTEL_SEVERITY_UNSPECIFIED = 0,
    OTEL_SEVERITY_TRACE = 1,
    OTEL_SEVERITY_TRACE2 = 2,
    OTEL_SEVERITY_TRACE3 = 3,
    OTEL_SEVERITY_TRACE4 = 4,
    OTEL_SEVERITY_DEBUG = 5,
    OTEL_SEVERITY_DEBUG2 = 6,
    OTEL_SEVERITY_DEBUG3 = 7,
    OTEL_SEVERITY_DEBUG4 = 8,
    OTEL_SEVERITY_INFO = 9,
    OTEL_SEVERITY_INFO2 = 10,
    OTEL_SEVERITY_INFO3 = 11,
    OTEL_SEVERITY_INFO4 = 12,
    OTEL_SEVERITY_WARN = 13,
    OTEL_SEVERITY_WARN2 = 14,
    OTEL_SEVERITY_WARN3 = 15,
    OTEL_SEVERITY_WARN4 = 16,
    OTEL_SEVERITY_ERROR = 17,
    OTEL_SEVERITY_ERROR2 = 18,
    OTEL_SEVERITY_ERROR3 = 19,
    OTEL_SEVERITY_ERROR4 = 20,
    OTEL_SEVERITY_FATAL = 21,
    OTEL_SEVERITY_FATAL2 = 22,
    OTEL_SEVERITY_FATAL3 = 23,
    OTEL_SEVERITY_FATAL4 = 24
} otel_severity_number_t;

/* ============================================================================
 * LoggerProvider API
 * ============================================================================ */

/**
 * @brief Create a new LoggerProvider.
 *
 * Creates a new LoggerProvider with default configuration.
 *
 * @return Pointer to the LoggerProvider, or NULL on error.
 */
otel_logger_provider_t* otel_logger_provider_create(void);

/**
 * @brief Shutdown the LoggerProvider and release all resources.
 *
 * Flushes any pending log records and releases all associated resources.
 * After calling this function, the provider handle becomes invalid.
 *
 * @param provider The LoggerProvider to shutdown. Can be NULL (no-op).
 */
void otel_logger_provider_shutdown(otel_logger_provider_t* provider);

/**
 * @brief Get a Logger from the LoggerProvider.
 *
 * @param provider The LoggerProvider handle.
 * @param name The name of the logger (null-terminated).
 * @param version Optional version string (null-terminated, can be NULL).
 * @param schema_url Optional schema URL (null-terminated, can be NULL).
 * @return Pointer to the Logger, or NULL on error.
 */
otel_logger_t* otel_logger_provider_get_logger(
    otel_logger_provider_t* provider,
    const char* name,
    const char* version,
    const char* schema_url);

/**
 * @brief Add a LogRecordProcessor to the LoggerProvider.
 *
 * @param provider The LoggerProvider handle.
 * @param processor The LogRecordProcessor to add.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_logger_provider_add_log_record_processor(
    otel_logger_provider_t* provider,
    otel_log_record_processor_t* processor);

/**
 * @brief Force flush all log record processors.
 *
 * Forces immediate export of all log records that have not yet been exported.
 *
 * @param provider The LoggerProvider handle.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_logger_provider_force_flush(otel_logger_provider_t* provider);

/* ============================================================================
 * Logger API
 * ============================================================================ */

/**
 * @brief Emit a log record.
 *
 * @param logger The Logger handle.
 * @param severity_number Severity level (use otel_severity_number_t values).
 * @param severity_text Severity text (e.g., "INFO", "ERROR", null-terminated, can be NULL).
 * @param body Log message body (null-terminated, can be NULL).
 * @param attributes Array of attributes (can be NULL).
 * @param attr_count Number of attributes.
 * @return Status code indicating success or failure.
 */
otel_status_t otel_logger_emit(
    otel_logger_t* logger,
    int severity_number,
    const char* severity_text,
    const char* body,
    const otel_attribute_t* attributes,
    size_t attr_count);

/**
 * @brief Check if logging is enabled for the given severity.
 *
 * This method is useful for avoiding expensive operations when logging is disabled.
 *
 * @param logger The Logger handle.
 * @param severity_number Severity level to check.
 * @return true if logging is enabled, false otherwise.
 */
bool otel_logger_is_enabled(otel_logger_t* logger, int severity_number);

/* ============================================================================
 * LogRecordExporter API
 * ============================================================================ */

/**
 * @brief Create a stdout LogRecordExporter for debugging.
 *
 * Creates an exporter that writes log records to standard output.
 * Useful for debugging and development.
 *
 * @return Pointer to the LogRecordExporter, or NULL on error.
 */
otel_log_record_exporter_t* otel_log_record_exporter_stdout_create(void);

/* ============================================================================
 * LogRecordProcessor API
 * ============================================================================ */

/**
 * @brief Create a SimpleLogRecordProcessor.
 *
 * A SimpleLogRecordProcessor exports log records immediately when they are emitted.
 * This is useful for debugging but may not be suitable for production
 * due to the synchronous export on the critical path.
 *
 * @param exporter The LogRecordExporter to use.
 * @return Pointer to the LogRecordProcessor, or NULL on error.
 */
otel_log_record_processor_t* otel_simple_log_record_processor_create(
    otel_log_record_exporter_t* exporter);

#ifdef __cplusplus
}
#endif

#endif /* OPENTELEMETRY_H */
