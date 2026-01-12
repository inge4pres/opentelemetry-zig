/**
 * OpenTelemetry C API Test
 *
 * This is a test program that validates the C bindings for the OpenTelemetry SDK.
 * It exercises all the exported functions to ensure they work correctly from C.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

/* ============================================================================
 * Type declarations matching the Zig exports
 * ============================================================================ */

typedef enum {
    OTEL_STATUS_OK = 0,
    OTEL_STATUS_ERROR_OUT_OF_MEMORY = -1,
    OTEL_STATUS_ERROR_INVALID_ARGUMENT = -2,
    OTEL_STATUS_ERROR_INVALID_STATE = -3,
    OTEL_STATUS_ERROR_ALREADY_SHUTDOWN = -4,
    OTEL_STATUS_ERROR_EXPORT_FAILED = -5,
    OTEL_STATUS_ERROR_COLLECT_FAILED = -6,
    OTEL_STATUS_ERROR_UNKNOWN = -99
} otel_status_t;

typedef enum {
    OTEL_ATTRIBUTE_TYPE_BOOL = 0,
    OTEL_ATTRIBUTE_TYPE_INT = 1,
    OTEL_ATTRIBUTE_TYPE_DOUBLE = 2,
    OTEL_ATTRIBUTE_TYPE_STRING = 3
} otel_attribute_value_type_t;

typedef struct {
    const char* key;
    otel_attribute_value_type_t value_type;
    union {
        bool bool_value;
        int64_t int_value;
        double double_value;
        const char* string_value;
    } value;
} otel_attribute_t;

/* Opaque handle types */
typedef struct otel_meter_provider otel_meter_provider_t;
typedef struct otel_meter otel_meter_t;
typedef struct otel_counter_u64 otel_counter_u64_t;
typedef struct otel_updown_counter_i64 otel_updown_counter_i64_t;
typedef struct otel_histogram_f64 otel_histogram_f64_t;
typedef struct otel_gauge_f64 otel_gauge_f64_t;
typedef struct otel_metric_reader otel_metric_reader_t;
typedef struct otel_metric_exporter otel_metric_exporter_t;

/* ============================================================================
 * External function declarations (provided by the Zig library)
 * ============================================================================ */

/* MeterProvider API */
extern otel_meter_provider_t* otel_meter_provider_create(void);
extern otel_meter_provider_t* otel_meter_provider_init(void);
extern void otel_meter_provider_shutdown(otel_meter_provider_t* provider);
extern otel_meter_t* otel_meter_provider_get_meter(
    otel_meter_provider_t* provider,
    const char* name,
    const char* version,
    const char* schema_url);
extern otel_status_t otel_meter_provider_add_reader(
    otel_meter_provider_t* provider,
    otel_metric_reader_t* reader);

/* Counter API */
extern otel_counter_u64_t* otel_meter_create_counter_u64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);
extern otel_status_t otel_counter_add_u64(
    otel_counter_u64_t* counter,
    uint64_t value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* UpDownCounter API */
extern otel_updown_counter_i64_t* otel_meter_create_updown_counter_i64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);
extern otel_status_t otel_updown_counter_add_i64(
    otel_updown_counter_i64_t* counter,
    int64_t value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* Histogram API */
extern otel_histogram_f64_t* otel_meter_create_histogram_f64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);
extern otel_status_t otel_histogram_record_f64(
    otel_histogram_f64_t* histogram,
    double value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* Gauge API */
extern otel_gauge_f64_t* otel_meter_create_gauge_f64(
    otel_meter_t* meter,
    const char* name,
    const char* description,
    const char* unit);
extern otel_status_t otel_gauge_record_f64(
    otel_gauge_f64_t* gauge,
    double value,
    const otel_attribute_t* attributes,
    size_t attr_count);

/* MetricExporter API */
extern otel_metric_exporter_t* otel_metric_exporter_stdout_create(void);
extern otel_metric_exporter_t* otel_metric_exporter_inmemory_create(void);

/* MetricReader API */
extern otel_metric_reader_t* otel_metric_reader_create(otel_metric_exporter_t* exporter);
extern otel_status_t otel_metric_reader_collect(otel_metric_reader_t* reader);
extern void otel_metric_reader_shutdown(otel_metric_reader_t* reader);

/* ============================================================================
 * Test utilities
 * ============================================================================ */

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST_ASSERT(condition, message) do { \
    tests_run++; \
    if (condition) { \
        tests_passed++; \
        printf("  ✓ %s\n", message); \
    } else { \
        tests_failed++; \
        printf("  ✗ %s (FAILED)\n", message); \
    } \
} while(0)

#define TEST_ASSERT_NOT_NULL(ptr, message) TEST_ASSERT((ptr) != NULL, message)
#define TEST_ASSERT_NULL(ptr, message) TEST_ASSERT((ptr) == NULL, message)
#define TEST_ASSERT_EQ(a, b, message) TEST_ASSERT((a) == (b), message)

/* ============================================================================
 * Test cases
 * ============================================================================ */

void test_meter_provider_create(void) {
    printf("\n[TEST] MeterProvider creation\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    TEST_ASSERT_NOT_NULL(provider, "otel_meter_provider_create returns non-null");
    
    otel_meter_provider_shutdown(provider);
    printf("  ✓ otel_meter_provider_shutdown completed\n");
    tests_run++;
    tests_passed++;
}

void test_meter_provider_init(void) {
    printf("\n[TEST] MeterProvider init\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_init();
    TEST_ASSERT_NOT_NULL(provider, "otel_meter_provider_init returns non-null");
    
    otel_meter_provider_shutdown(provider);
}

void test_get_meter(void) {
    printf("\n[TEST] Get Meter\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    TEST_ASSERT_NOT_NULL(provider, "Provider created");
    
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", "1.0.0", NULL);
    TEST_ASSERT_NOT_NULL(meter, "otel_meter_provider_get_meter returns meter");
    
    /* Getting the same meter again should work */
    otel_meter_t* meter2 = otel_meter_provider_get_meter(
        provider, "test-meter", "1.0.0", NULL);
    TEST_ASSERT_NOT_NULL(meter2, "Getting same meter again works");
    
    /* Getting a different meter should work */
    otel_meter_t* meter3 = otel_meter_provider_get_meter(
        provider, "another-meter", NULL, NULL);
    TEST_ASSERT_NOT_NULL(meter3, "Getting different meter works");
    
    otel_meter_provider_shutdown(provider);
}

void test_counter_u64(void) {
    printf("\n[TEST] Counter u64\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", NULL, NULL);
    
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(
        meter, "test_counter", "A test counter", "1");
    TEST_ASSERT_NOT_NULL(counter, "otel_meter_create_counter_u64 returns counter");
    
    /* Add without attributes */
    otel_status_t status = otel_counter_add_u64(counter, 10, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_counter_add_u64 without attrs returns OK");
    
    /* Add with attributes */
    otel_attribute_t attrs[] = {
        { .key = "method", .value_type = OTEL_ATTRIBUTE_TYPE_STRING, 
          .value = { .string_value = "GET" } },
        { .key = "status", .value_type = OTEL_ATTRIBUTE_TYPE_INT, 
          .value = { .int_value = 200 } }
    };
    status = otel_counter_add_u64(counter, 5, attrs, 2);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_counter_add_u64 with attrs returns OK");
    
    otel_meter_provider_shutdown(provider);
}

void test_updown_counter_i64(void) {
    printf("\n[TEST] UpDownCounter i64\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", NULL, NULL);
    
    otel_updown_counter_i64_t* counter = otel_meter_create_updown_counter_i64(
        meter, "active_connections", "Number of active connections", "1");
    TEST_ASSERT_NOT_NULL(counter, "otel_meter_create_updown_counter_i64 returns counter");
    
    /* Add positive value */
    otel_status_t status = otel_updown_counter_add_i64(counter, 5, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_updown_counter_add_i64 positive returns OK");
    
    /* Add negative value */
    status = otel_updown_counter_add_i64(counter, -3, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_updown_counter_add_i64 negative returns OK");
    
    otel_meter_provider_shutdown(provider);
}

void test_histogram_f64(void) {
    printf("\n[TEST] Histogram f64\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", NULL, NULL);
    
    otel_histogram_f64_t* histogram = otel_meter_create_histogram_f64(
        meter, "request_duration", "Request duration in seconds", "s");
    TEST_ASSERT_NOT_NULL(histogram, "otel_meter_create_histogram_f64 returns histogram");
    
    /* Record values */
    otel_status_t status = otel_histogram_record_f64(histogram, 0.025, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_histogram_record_f64 returns OK");
    
    status = otel_histogram_record_f64(histogram, 0.150, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Recording second value OK");
    
    status = otel_histogram_record_f64(histogram, 1.234, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Recording third value OK");
    
    otel_meter_provider_shutdown(provider);
}

void test_gauge_f64(void) {
    printf("\n[TEST] Gauge f64\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", NULL, NULL);
    
    otel_gauge_f64_t* gauge = otel_meter_create_gauge_f64(
        meter, "cpu_usage", "Current CPU usage", "percent");
    TEST_ASSERT_NOT_NULL(gauge, "otel_meter_create_gauge_f64 returns gauge");
    
    /* Record value */
    otel_status_t status = otel_gauge_record_f64(gauge, 45.7, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "otel_gauge_record_f64 returns OK");
    
    /* Record another value */
    status = otel_gauge_record_f64(gauge, 78.2, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Recording second gauge value OK");
    
    otel_meter_provider_shutdown(provider);
}

void test_metric_exporter_stdout(void) {
    printf("\n[TEST] Stdout MetricExporter\n");
    
    otel_metric_exporter_t* exporter = otel_metric_exporter_stdout_create();
    TEST_ASSERT_NOT_NULL(exporter, "otel_metric_exporter_stdout_create returns exporter");
    
    /* We don't have a direct way to destroy the exporter, it's managed by the reader */
}

void test_metric_exporter_inmemory(void) {
    printf("\n[TEST] InMemory MetricExporter\n");
    
    otel_metric_exporter_t* exporter = otel_metric_exporter_inmemory_create();
    TEST_ASSERT_NOT_NULL(exporter, "otel_metric_exporter_inmemory_create returns exporter");
}

void test_metric_reader(void) {
    printf("\n[TEST] MetricReader\n");
    
    otel_metric_exporter_t* exporter = otel_metric_exporter_inmemory_create();
    TEST_ASSERT_NOT_NULL(exporter, "Exporter created");
    
    otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
    TEST_ASSERT_NOT_NULL(reader, "otel_metric_reader_create returns reader");
    
    /* Collect without a provider should fail with invalid state */
    otel_status_t status = otel_metric_reader_collect(reader);
    TEST_ASSERT_EQ(status, OTEL_STATUS_ERROR_INVALID_STATE, 
        "Collect without provider returns INVALID_STATE");
    
    otel_metric_reader_shutdown(reader);
    printf("  ✓ otel_metric_reader_shutdown completed\n");
    tests_run++;
    tests_passed++;
}

void test_full_pipeline(void) {
    printf("\n[TEST] Full metrics pipeline\n");
    
    /* Create provider */
    otel_meter_provider_t* provider = otel_meter_provider_create();
    TEST_ASSERT_NOT_NULL(provider, "Provider created");
    
    /* Create exporter and reader */
    otel_metric_exporter_t* exporter = otel_metric_exporter_inmemory_create();
    TEST_ASSERT_NOT_NULL(exporter, "Exporter created");
    
    otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
    TEST_ASSERT_NOT_NULL(reader, "Reader created");
    
    /* Add reader to provider */
    otel_status_t status = otel_meter_provider_add_reader(provider, reader);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Reader added to provider");
    
    /* Get meter and create instruments */
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "integration-test", "1.0.0", NULL);
    TEST_ASSERT_NOT_NULL(meter, "Meter created");
    
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(
        meter, "requests", "Total requests", "1");
    TEST_ASSERT_NOT_NULL(counter, "Counter created");
    
    otel_histogram_f64_t* histogram = otel_meter_create_histogram_f64(
        meter, "latency", "Request latency", "ms");
    TEST_ASSERT_NOT_NULL(histogram, "Histogram created");
    
    /* Record some data */
    otel_counter_add_u64(counter, 10, NULL, 0);
    otel_counter_add_u64(counter, 20, NULL, 0);
    otel_histogram_record_f64(histogram, 25.5, NULL, 0);
    otel_histogram_record_f64(histogram, 42.0, NULL, 0);
    
    /* Collect metrics */
    status = otel_metric_reader_collect(reader);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Metrics collected successfully");
    
    /* Shutdown */
    otel_meter_provider_shutdown(provider);
    printf("  ✓ Full pipeline shutdown completed\n");
    tests_run++;
    tests_passed++;
}

void test_attributes(void) {
    printf("\n[TEST] Attributes\n");
    
    otel_meter_provider_t* provider = otel_meter_provider_create();
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "test-meter", NULL, NULL);
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(
        meter, "test_counter", NULL, NULL);
    
    /* Test all attribute types */
    otel_attribute_t bool_attr = {
        .key = "bool_attr",
        .value_type = OTEL_ATTRIBUTE_TYPE_BOOL,
        .value = { .bool_value = true }
    };
    otel_status_t status = otel_counter_add_u64(counter, 1, &bool_attr, 1);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Bool attribute works");
    
    otel_attribute_t int_attr = {
        .key = "int_attr",
        .value_type = OTEL_ATTRIBUTE_TYPE_INT,
        .value = { .int_value = 42 }
    };
    status = otel_counter_add_u64(counter, 1, &int_attr, 1);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Int attribute works");
    
    otel_attribute_t double_attr = {
        .key = "double_attr",
        .value_type = OTEL_ATTRIBUTE_TYPE_DOUBLE,
        .value = { .double_value = 3.14159 }
    };
    status = otel_counter_add_u64(counter, 1, &double_attr, 1);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Double attribute works");
    
    otel_attribute_t string_attr = {
        .key = "string_attr",
        .value_type = OTEL_ATTRIBUTE_TYPE_STRING,
        .value = { .string_value = "hello" }
    };
    status = otel_counter_add_u64(counter, 1, &string_attr, 1);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "String attribute works");
    
    /* Test multiple attributes */
    otel_attribute_t multi_attrs[] = {
        { .key = "method", .value_type = OTEL_ATTRIBUTE_TYPE_STRING, 
          .value = { .string_value = "POST" } },
        { .key = "status", .value_type = OTEL_ATTRIBUTE_TYPE_INT, 
          .value = { .int_value = 201 } },
        { .key = "success", .value_type = OTEL_ATTRIBUTE_TYPE_BOOL, 
          .value = { .bool_value = true } },
        { .key = "duration", .value_type = OTEL_ATTRIBUTE_TYPE_DOUBLE, 
          .value = { .double_value = 0.123 } }
    };
    status = otel_counter_add_u64(counter, 1, multi_attrs, 4);
    TEST_ASSERT_EQ(status, OTEL_STATUS_OK, "Multiple attributes work");
    
    otel_meter_provider_shutdown(provider);
}

void test_null_handling(void) {
    printf("\n[TEST] Null handling\n");
    
    /* These should not crash, just return NULL or error */
    otel_meter_t* meter = otel_meter_provider_get_meter(NULL, "test", NULL, NULL);
    TEST_ASSERT_NULL(meter, "Get meter with null provider returns NULL");
    
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(NULL, "test", NULL, NULL);
    TEST_ASSERT_NULL(counter, "Create counter with null meter returns NULL");
    
    otel_status_t status = otel_counter_add_u64(NULL, 1, NULL, 0);
    TEST_ASSERT_EQ(status, OTEL_STATUS_ERROR_INVALID_ARGUMENT, 
        "Add to null counter returns INVALID_ARGUMENT");
    
    otel_metric_reader_t* reader = otel_metric_reader_create(NULL);
    TEST_ASSERT_NULL(reader, "Create reader with null exporter returns NULL");
    
    status = otel_metric_reader_collect(NULL);
    TEST_ASSERT_EQ(status, OTEL_STATUS_ERROR_INVALID_ARGUMENT, 
        "Collect on null reader returns INVALID_ARGUMENT");
    
    /* Shutdown with null should not crash */
    otel_meter_provider_shutdown(NULL);
    printf("  ✓ otel_meter_provider_shutdown(NULL) doesn't crash\n");
    tests_run++;
    tests_passed++;
    
    otel_metric_reader_shutdown(NULL);
    printf("  ✓ otel_metric_reader_shutdown(NULL) doesn't crash\n");
    tests_run++;
    tests_passed++;
}

/* ============================================================================
 * Main
 * ============================================================================ */

int main(void) {
    printf("========================================\n");
    printf("OpenTelemetry C Bindings Test Suite\n");
    printf("========================================\n");
    
    /* Run all tests */
    test_meter_provider_create();
    test_meter_provider_init();
    test_get_meter();
    test_counter_u64();
    test_updown_counter_i64();
    test_histogram_f64();
    test_gauge_f64();
    test_metric_exporter_stdout();
    test_metric_exporter_inmemory();
    test_metric_reader();
    test_full_pipeline();
    test_attributes();
    test_null_handling();
    
    /* Print summary */
    printf("\n========================================\n");
    printf("Test Summary\n");
    printf("========================================\n");
    printf("Total:  %d\n", tests_run);
    printf("Passed: %d\n", tests_passed);
    printf("Failed: %d\n", tests_failed);
    printf("========================================\n");
    
    if (tests_failed > 0) {
        printf("\n❌ SOME TESTS FAILED\n");
        return 1;
    } else {
        printf("\n✅ ALL TESTS PASSED\n");
        return 0;
    }
}
