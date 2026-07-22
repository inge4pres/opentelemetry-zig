/**
 * @file basic_logs.c
 * @brief Example demonstrating the OpenTelemetry Logs C API.
 *
 * This example shows how to:
 * - Create a LoggerProvider
 * - Configure a LogRecordProcessor with a stdout exporter
 * - Get a Logger
 * - Emit log records with different severities
 * - Use attributes with log records
 * - Properly shutdown the provider
 *
 * Build with:
 *   zig build c-examples
 *
 * Run with:
 *   ./zig-out/bin/basic_logs
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include "../include/opentelemetry.h"

/* Helper to check status and exit on error */
#define CHECK_STATUS(status, msg) \
    if ((status) != OTEL_STATUS_OK) { \
        fprintf(stderr, "Error: %s (status=%d)\n", msg, status); \
        exit(1); \
    }

/* Helper to check pointer and exit on NULL */
#define CHECK_PTR(ptr, msg) \
    if ((ptr) == NULL) { \
        fprintf(stderr, "Error: %s returned NULL\n", msg); \
        exit(1); \
    }

/**
 * @brief Demonstrates basic logging operations.
 */
void demo_basic_logging(otel_logger_t* logger) {
    printf("\n=== Basic Logging Demo ===\n");
    otel_status_t status;

    /* Emit a simple INFO log */
    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_INFO,
        "INFO",
        "Application started successfully",
        NULL,  /* no attributes */
        0
    );
    CHECK_STATUS(status, "otel_logger_emit INFO");
    printf("Emitted INFO log\n");

    /* Emit a DEBUG log */
    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_DEBUG,
        "DEBUG",
        "Loading configuration from file",
        NULL,
        0
    );
    CHECK_STATUS(status, "otel_logger_emit DEBUG");
    printf("Emitted DEBUG log\n");

    /* Emit a WARNING log */
    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_WARN,
        "WARN",
        "Configuration file not found, using defaults",
        NULL,
        0
    );
    CHECK_STATUS(status, "otel_logger_emit WARN");
    printf("Emitted WARN log\n");

    /* Emit an ERROR log */
    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_ERROR,
        "ERROR",
        "Failed to connect to database",
        NULL,
        0
    );
    CHECK_STATUS(status, "otel_logger_emit ERROR");
    printf("Emitted ERROR log\n");
}

/**
 * @brief Demonstrates logging with attributes.
 */
void demo_logging_with_attributes(otel_logger_t* logger) {
    printf("\n=== Logging with Attributes Demo ===\n");
    otel_status_t status;

    /* Create attributes for a request log */
    otel_attribute_t request_attrs[] = {
        {
            .key = "http.method",
            .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
            .value.string_value = "GET"
        },
        {
            .key = "http.url",
            .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
            .value.string_value = "/api/users"
        },
        {
            .key = "http.status_code",
            .value_type = OTEL_ATTRIBUTE_TYPE_INT,
            .value.int_value = 200
        },
        {
            .key = "http.response_time_ms",
            .value_type = OTEL_ATTRIBUTE_TYPE_DOUBLE,
            .value.double_value = 45.7
        }
    };

    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_INFO,
        "INFO",
        "HTTP request completed",
        request_attrs,
        4  /* number of attributes */
    );
    CHECK_STATUS(status, "otel_logger_emit with attributes");
    printf("Emitted log with HTTP request attributes\n");

    /* Create attributes for an error log */
    otel_attribute_t error_attrs[] = {
        {
            .key = "error.type",
            .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
            .value.string_value = "ConnectionError"
        },
        {
            .key = "error.message",
            .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
            .value.string_value = "Connection refused"
        },
        {
            .key = "retry.attempt",
            .value_type = OTEL_ATTRIBUTE_TYPE_INT,
            .value.int_value = 3
        },
        {
            .key = "retry.exhausted",
            .value_type = OTEL_ATTRIBUTE_TYPE_BOOL,
            .value.bool_value = true
        }
    };

    status = otel_logger_emit(
        logger,
        OTEL_SEVERITY_ERROR,
        "ERROR",
        "Failed to connect to service after retries",
        error_attrs,
        4  /* number of attributes */
    );
    CHECK_STATUS(status, "otel_logger_emit error with attributes");
    printf("Emitted error log with retry attributes\n");
}

/**
 * @brief Demonstrates different severity levels.
 */
void demo_severity_levels(otel_logger_t* logger) {
    printf("\n=== Severity Levels Demo ===\n");
    otel_status_t status;

    /* All TRACE levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_TRACE, "TRACE", "Trace level 1", NULL, 0);
    CHECK_STATUS(status, "TRACE");

    /* DEBUG levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_DEBUG, "DEBUG", "Debug level", NULL, 0);
    CHECK_STATUS(status, "DEBUG");
    status = otel_logger_emit(logger, OTEL_SEVERITY_DEBUG2, "DEBUG2", "Debug level 2", NULL, 0);
    CHECK_STATUS(status, "DEBUG2");

    /* INFO levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_INFO, "INFO", "Info level", NULL, 0);
    CHECK_STATUS(status, "INFO");

    /* WARN levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_WARN, "WARN", "Warning level", NULL, 0);
    CHECK_STATUS(status, "WARN");

    /* ERROR levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_ERROR, "ERROR", "Error level", NULL, 0);
    CHECK_STATUS(status, "ERROR");

    /* FATAL levels */
    status = otel_logger_emit(logger, OTEL_SEVERITY_FATAL, "FATAL", "Fatal level", NULL, 0);
    CHECK_STATUS(status, "FATAL");

    printf("Emitted logs at all severity levels\n");
}

/**
 * @brief Demonstrates checking if logging is enabled.
 */
void demo_enabled_check(otel_logger_t* logger) {
    printf("\n=== Enabled Check Demo ===\n");

    /* Check if different severity levels are enabled */
    bool trace_enabled = otel_logger_is_enabled(logger, OTEL_SEVERITY_TRACE);
    bool debug_enabled = otel_logger_is_enabled(logger, OTEL_SEVERITY_DEBUG);
    bool info_enabled = otel_logger_is_enabled(logger, OTEL_SEVERITY_INFO);
    bool error_enabled = otel_logger_is_enabled(logger, OTEL_SEVERITY_ERROR);

    printf("TRACE enabled: %s\n", trace_enabled ? "yes" : "no");
    printf("DEBUG enabled: %s\n", debug_enabled ? "yes" : "no");
    printf("INFO enabled: %s\n", info_enabled ? "yes" : "no");
    printf("ERROR enabled: %s\n", error_enabled ? "yes" : "no");
}

/**
 * @brief Demonstrates using multiple loggers.
 */
void demo_multiple_loggers(otel_logger_provider_t* provider) {
    printf("\n=== Multiple Loggers Demo ===\n");
    otel_status_t status;

    /* Get loggers for different components */
    otel_logger_t* db_logger = otel_logger_provider_get_logger(
        provider,
        "database-client",
        "2.0.0",
        NULL
    );
    CHECK_PTR(db_logger, "otel_logger_provider_get_logger (database)");

    otel_logger_t* http_logger = otel_logger_provider_get_logger(
        provider,
        "http-server",
        "1.5.0",
        "https://opentelemetry.io/schemas/1.21.0"
    );
    CHECK_PTR(http_logger, "otel_logger_provider_get_logger (http)");

    otel_logger_t* cache_logger = otel_logger_provider_get_logger(
        provider,
        "cache-service",
        NULL,  /* no version */
        NULL
    );
    CHECK_PTR(cache_logger, "otel_logger_provider_get_logger (cache)");

    /* Log from each component */
    status = otel_logger_emit(
        db_logger,
        OTEL_SEVERITY_INFO,
        "INFO",
        "Database connection pool initialized",
        NULL, 0
    );
    CHECK_STATUS(status, "db_logger emit");
    printf("Emitted log from database-client logger\n");

    status = otel_logger_emit(
        http_logger,
        OTEL_SEVERITY_INFO,
        "INFO",
        "HTTP server listening on port 8080",
        NULL, 0
    );
    CHECK_STATUS(status, "http_logger emit");
    printf("Emitted log from http-server logger\n");

    status = otel_logger_emit(
        cache_logger,
        OTEL_SEVERITY_DEBUG,
        "DEBUG",
        "Cache hit for key: user:123",
        NULL, 0
    );
    CHECK_STATUS(status, "cache_logger emit");
    printf("Emitted log from cache-service logger\n");
}

/**
 * @brief Main entry point.
 */
int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;

    printf("OpenTelemetry Logs C API Example\n");
    printf("================================\n");

    /* Step 1: Create a LoggerProvider */
    printf("\n--- Creating LoggerProvider ---\n");
    otel_logger_provider_t* provider = otel_logger_provider_create();
    CHECK_PTR(provider, "otel_logger_provider_create");
    printf("LoggerProvider created successfully\n");

    /* Step 2: Create a stdout exporter for debugging */
    printf("\n--- Creating stdout LogRecordExporter ---\n");
    otel_log_record_exporter_t* exporter = otel_log_record_exporter_stdout_create();
    CHECK_PTR(exporter, "otel_log_record_exporter_stdout_create");
    printf("Stdout LogRecordExporter created successfully\n");

    /* Step 3: Create a SimpleLogRecordProcessor */
    printf("\n--- Creating SimpleLogRecordProcessor ---\n");
    otel_log_record_processor_t* processor = otel_simple_log_record_processor_create(exporter);
    CHECK_PTR(processor, "otel_simple_log_record_processor_create");
    printf("SimpleLogRecordProcessor created successfully\n");

    /* Step 4: Add the processor to the provider */
    printf("\n--- Adding processor to provider ---\n");
    otel_status_t status = otel_logger_provider_add_log_record_processor(provider, processor);
    CHECK_STATUS(status, "otel_logger_provider_add_log_record_processor");
    printf("Processor added to provider successfully\n");

    /* Step 5: Get a Logger */
    printf("\n--- Getting Logger ---\n");
    otel_logger_t* logger = otel_logger_provider_get_logger(
        provider,
        "example-app",
        "1.0.0",
        NULL
    );
    CHECK_PTR(logger, "otel_logger_provider_get_logger");
    printf("Logger obtained successfully\n");

    /* Run demos */
    demo_basic_logging(logger);
    demo_logging_with_attributes(logger);
    demo_severity_levels(logger);
    demo_enabled_check(logger);
    demo_multiple_loggers(provider);

    /* Step 6: Force flush to ensure all logs are exported */
    printf("\n--- Flushing logs ---\n");
    status = otel_logger_provider_force_flush(provider);
    CHECK_STATUS(status, "otel_logger_provider_force_flush");
    printf("All logs flushed successfully\n");

    /* Step 7: Shutdown */
    printf("\n--- Shutting down ---\n");
    otel_logger_provider_shutdown(provider);
    printf("LoggerProvider shutdown successfully\n");

    printf("\n================================\n");
    printf("Example completed successfully!\n");

    return 0;
}
