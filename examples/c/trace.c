/**
 * OpenTelemetry C API Example - Basic Tracing
 *
 * This example demonstrates how to use the OpenTelemetry C API
 * to create and manage distributed traces.
 *
 * To compile:
 *   zig build
 *   # Then compile this C file and link with the generated library:
 *   cc -I include examples/c/basic_trace.c -L zig-out/lib -lopentelemetry-sdk -o basic_trace
 *
 * To run:
 *   ./basic_trace
 */

#include "opentelemetry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Simulate some work */
void simulate_work(const char* description) {
    printf("  Working on: %s\n", description);
    /* In a real application, this would do actual work */
}

/* Simulate a database query */
void simulate_db_query(otel_tracer_t* tracer, const char* query) {
    /* Create a client span for the database call */
    otel_span_start_options_t opts = {
        .kind = OTEL_SPAN_KIND_CLIENT,
        .attributes = NULL,
        .attr_count = 0,
        .start_timestamp_ns = 0
    };

    otel_span_t* span = otel_tracer_start_span(tracer, "db.query", &opts);
    if (!span) {
        fprintf(stderr, "Failed to create database span\n");
        return;
    }

    /* Set database-related attributes */
    otel_span_set_attribute_string(span, "db.system", "postgresql");
    otel_span_set_attribute_string(span, "db.statement", query);
    otel_span_set_attribute_string(span, "db.name", "users_db");

    /* Simulate the query execution */
    simulate_work("executing database query");

    /* Add an event for query completion */
    otel_span_add_event(span, "query.executed", NULL, 0);

    /* Set success status */
    otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);

    /* End the span */
    otel_span_end(span);
}

/* Simulate an HTTP request handler */
void handle_request(otel_tracer_t* tracer, const char* method, const char* path) {
    /* Create a server span for the incoming request */
    otel_span_start_options_t opts = {
        .kind = OTEL_SPAN_KIND_SERVER,
        .attributes = NULL,
        .attr_count = 0,
        .start_timestamp_ns = 0
    };

    otel_span_t* span = otel_tracer_start_span(tracer, "http.request", &opts);
    if (!span) {
        fprintf(stderr, "Failed to create request span\n");
        return;
    }

    /* Set HTTP-related attributes */
    otel_span_set_attribute_string(span, "http.method", method);
    otel_span_set_attribute_string(span, "http.target", path);
    otel_span_set_attribute_string(span, "http.scheme", "https");
    otel_span_set_attribute_int(span, "http.status_code", 200);

    /* Get and print trace context */
    char trace_id[33];
    char span_id[17];
    if (otel_span_get_trace_id_hex(span, trace_id, sizeof(trace_id)) == OTEL_STATUS_OK) {
        printf("  Trace ID: %s\n", trace_id);
    }
    if (otel_span_get_span_id_hex(span, span_id, sizeof(span_id)) == OTEL_STATUS_OK) {
        printf("  Span ID:  %s\n", span_id);
    }

    /* Add an event for request received */
    otel_span_add_event(span, "request.received", NULL, 0);

    /* Simulate request processing */
    simulate_work("parsing request");

    /* Make a nested database call */
    simulate_db_query(tracer, "SELECT * FROM users WHERE id = 42");

    /* Simulate more work */
    simulate_work("formatting response");

    /* Add an event for response sent */
    otel_span_add_event(span, "response.sent", NULL, 0);

    /* Set success status */
    otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);

    /* End the span */
    otel_span_end(span);
}

/* Simulate an operation that fails */
void failing_operation(otel_tracer_t* tracer) {
    otel_span_t* span = otel_tracer_start_span(tracer, "failing.operation", NULL);
    if (!span) {
        fprintf(stderr, "Failed to create span\n");
        return;
    }

    /* Simulate some work */
    simulate_work("attempting risky operation");

    /* Record an exception */
    otel_span_record_exception(
        span,
        "RuntimeError",
        "Something went wrong!",
        "at failing_operation (basic_trace.c:110)\nat main (basic_trace.c:180)"
    );

    /* Set error status */
    otel_span_set_status(span, OTEL_SPAN_STATUS_ERROR, "Operation failed due to RuntimeError");

    /* End the span */
    otel_span_end(span);
}

int main(void) {
    printf("OpenTelemetry C API Tracing Example\n");
    printf("====================================\n\n");

    /* Create a tracer provider */
    otel_tracer_provider_t* provider = otel_tracer_provider_create();
    if (!provider) {
        fprintf(stderr, "Failed to create tracer provider\n");
        return 1;
    }
    printf("✓ Created TracerProvider\n");

    /* Create a stdout exporter for debugging */
    otel_span_exporter_t* exporter = otel_span_exporter_stdout_create();
    if (!exporter) {
        fprintf(stderr, "Failed to create exporter\n");
        otel_tracer_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created stdout SpanExporter\n");

    /* Create a simple span processor */
    otel_span_processor_t* processor = otel_simple_span_processor_create(exporter);
    if (!processor) {
        fprintf(stderr, "Failed to create processor\n");
        otel_tracer_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Created SimpleSpanProcessor\n");

    /* Add the processor to the provider */
    otel_status_t status = otel_tracer_provider_add_span_processor(provider, processor);
    if (status != OTEL_STATUS_OK) {
        fprintf(stderr, "Failed to add processor: %d\n", status);
        otel_tracer_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Added processor to provider\n");

    /* Get a tracer */
    otel_tracer_t* tracer = otel_tracer_provider_get_tracer(
        provider,
        "example-service",
        "1.0.0",
        NULL
    );
    if (!tracer) {
        fprintf(stderr, "Failed to get tracer\n");
        otel_tracer_provider_shutdown(provider);
        return 1;
    }
    printf("✓ Got Tracer 'example-service'\n");

    /* Check if tracer is enabled */
    if (otel_tracer_is_enabled(tracer)) {
        printf("✓ Tracer is enabled\n");
    }

    printf("\n--- Creating traces ---\n\n");

    /* Example 1: Simple span */
    printf("Example 1: Simple span\n");
    {
        otel_span_t* span = otel_tracer_start_span(tracer, "simple-operation", NULL);
        if (span) {
            otel_span_set_attribute_string(span, "operation.type", "simple");
            otel_span_set_attribute_int(span, "operation.count", 1);
            simulate_work("simple task");
            otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);
            otel_span_end(span);
            printf("  ✓ Simple span completed\n");
        }
    }

    printf("\nExample 2: HTTP request with nested database call\n");
    handle_request(tracer, "GET", "/api/users/42");
    printf("  ✓ HTTP request span completed\n");

    printf("\nExample 3: Span with custom kind\n");
    {
        otel_span_start_options_t opts = {
            .kind = OTEL_SPAN_KIND_PRODUCER,
            .attributes = NULL,
            .attr_count = 0,
            .start_timestamp_ns = 0
        };
        otel_span_t* span = otel_tracer_start_span(tracer, "message.publish", &opts);
        if (span) {
            otel_span_set_attribute_string(span, "messaging.system", "kafka");
            otel_span_set_attribute_string(span, "messaging.destination", "orders");
            simulate_work("publishing message");
            otel_span_add_event(span, "message.sent", NULL, 0);
            otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);
            otel_span_end(span);
            printf("  ✓ Producer span completed\n");
        }
    }

    printf("\nExample 4: Span with event attributes\n");
    {
        otel_span_t* span = otel_tracer_start_span(tracer, "process-order", NULL);
        if (span) {
            otel_span_set_attribute_string(span, "order.id", "ORD-12345");

            /* Add event with attributes */
            otel_attribute_t event_attrs[] = {
                {
                    .key = "item.count",
                    .value_type = OTEL_ATTRIBUTE_TYPE_INT,
                    .value = { .int_value = 3 }
                },
                {
                    .key = "total.amount",
                    .value_type = OTEL_ATTRIBUTE_TYPE_DOUBLE,
                    .value = { .double_value = 99.99 }
                }
            };
            otel_span_add_event(span, "order.validated", event_attrs, 2);

            simulate_work("processing order");
            otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);
            otel_span_end(span);
            printf("  ✓ Order processing span completed\n");
        }
    }

    printf("\nExample 5: Failing operation with exception\n");
    failing_operation(tracer);
    printf("  ✓ Failing operation span completed (with error)\n");

    printf("\nExample 6: Updating span name\n");
    {
        otel_span_t* span = otel_tracer_start_span(tracer, "generic-operation", NULL);
        if (span) {
            /* Update name based on what we learn during execution */
            otel_span_update_name(span, "specific-user-lookup");
            otel_span_set_attribute_int(span, "user.id", 12345);
            simulate_work("looking up user");
            otel_span_set_status(span, OTEL_SPAN_STATUS_OK, NULL);
            otel_span_end(span);
            printf("  ✓ Span with updated name completed\n");
        }
    }

    /* Force flush to ensure all spans are exported */
    printf("\n--- Flushing spans ---\n\n");
    status = otel_tracer_provider_force_flush(provider);
    if (status == OTEL_STATUS_OK) {
        printf("✓ Force flush completed\n");
    } else {
        printf("⚠ Force flush failed: %d\n", status);
    }

    /* Cleanup */
    printf("\n--- Shutdown ---\n\n");
    otel_tracer_provider_shutdown(provider);
    printf("✓ TracerProvider shutdown complete\n");

    printf("\nDone!\n");
    return 0;
}
