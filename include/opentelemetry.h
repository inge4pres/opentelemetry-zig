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

#ifdef __cplusplus
}
#endif

#endif /* OPENTELEMETRY_H */
