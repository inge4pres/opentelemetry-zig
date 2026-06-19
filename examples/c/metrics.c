/**
 * OpenTelemetry C API Example - Basic Metrics
 *
 * This example demonstrates how to use the OpenTelemetry C API
 * to create and record metrics.
 *
 * To compile:
 *   zig build
 *   # Then compile this C file and link with the generated library:
 *   cc -I include examples/c/basic_metrics.c -L zig-out/lib -lopentelemetry-sdk -o basic_metrics
 *
 * To run:
 *   ./basic_metrics
 */

#include "opentelemetry.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    printf("OpenTelemetry C API Example\n");
    printf("===========================\n\n");

    // Create a meter provider
    otel_meter_provider_t* provider = otel_meter_provider_create();
    if (!provider) {
        fprintf(stderr, "Failed to create meter provider\n");
        return 1;
    }
    printf("✓ Created MeterProvider\n");

    // Create a stdout exporter for debugging
    otel_metric_exporter_t* exporter = otel_metric_exporter_stdout_create();
    if (!exporter) {
        fprintf(stderr, "Failed to create exporter\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created stdout MetricExporter\n");

    // Create a metric reader
    otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
    if (!reader) {
        fprintf(stderr, "Failed to create metric reader\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created MetricReader\n");

    // Add the reader to the provider
    otel_status_t status = otel_meter_provider_add_reader(provider, reader);
    if (status != OTEL_STATUS_OK) {
        fprintf(stderr, "Failed to add reader to provider: %d\n", status);
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Added reader to provider\n");

    // Get a meter
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider,
        "example-service",
        "1.0.0",
        NULL
    );
    if (!meter) {
        fprintf(stderr, "Failed to get meter\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Got Meter 'example-service'\n");

    // Create a counter
    otel_counter_u64_t* request_counter = otel_meter_create_counter_u64(
        meter,
        "http_requests_total",
        "Total number of HTTP requests",
        "1"
    );
    if (!request_counter) {
        fprintf(stderr, "Failed to create counter\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created Counter 'http_requests_total'\n");

    // Create a histogram
    otel_histogram_f64_t* latency_histogram = otel_meter_create_histogram_f64(
        meter,
        "http_request_duration_seconds",
        "HTTP request latency in seconds",
        "s"
    );
    if (!latency_histogram) {
        fprintf(stderr, "Failed to create histogram\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created Histogram 'http_request_duration_seconds'\n");

    // Create a gauge
    otel_gauge_f64_t* cpu_gauge = otel_meter_create_gauge_f64(
        meter,
        "system_cpu_usage",
        "Current CPU usage",
        "percent"
    );
    if (!cpu_gauge) {
        fprintf(stderr, "Failed to create gauge\n");
        otel_meter_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created Gauge 'system_cpu_usage'\n");

    printf("\n--- Recording metrics ---\n\n");

    // Record some counter values without attributes
    printf("Recording counter increments...\n");
    otel_counter_add_u64(request_counter, 1, NULL, 0);
    otel_counter_add_u64(request_counter, 5, NULL, 0);
    otel_counter_add_u64(request_counter, 3, NULL, 0);

    // Record counter with attributes
    otel_attribute_t attrs[] = {
        {
            .key = "method",
            .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
            .value = { .string_value = "GET" }
        },
        {
            .key = "status_code",
            .value_type = OTEL_ATTRIBUTE_TYPE_INT,
            .value = { .int_value = 200 }
        }
    };
    otel_counter_add_u64(request_counter, 10, attrs, 2);
    printf("  ✓ Recorded counter with attributes\n");

    // Record histogram values
    printf("Recording histogram values...\n");
    otel_histogram_record_f64(latency_histogram, 0.025, NULL, 0);
    otel_histogram_record_f64(latency_histogram, 0.150, NULL, 0);
    otel_histogram_record_f64(latency_histogram, 0.042, NULL, 0);
    otel_histogram_record_f64(latency_histogram, 1.234, NULL, 0);
    printf("  ✓ Recorded 4 latency samples\n");

    // Record gauge value
    printf("Recording gauge value...\n");
    otel_gauge_record_f64(cpu_gauge, 45.7, NULL, 0);
    printf("  ✓ Recorded CPU usage: 45.7%%\n");

    // Collect and export metrics
    printf("\n--- Collecting metrics ---\n\n");
    status = otel_metric_reader_collect(reader);
    if (status == OTEL_STATUS_OK) {
        printf("✓ Metrics collected and exported successfully\n");
    } else {
        printf("⚠ Failed to collect metrics: %d\n", status);
    }

    // Cleanup
    printf("\n--- Shutdown ---\n\n");
    otel_meter_provider_shutdown(provider);
    printf("✓ MeterProvider shutdown complete\n");

    printf("\nDone!\n");
    return 0;
}
