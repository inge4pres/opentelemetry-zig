# Integration Tests

This directory contains integration tests for the OpenTelemetry SDK that run against a real OTLP collector.

## Structure

The integration tests are split into separate test executables that can run in parallel:

- `common.zig` - Shared utilities for Docker container management, file operations, and test setup
- `metrics.zig` - Metrics export tests (uncompressed and gzip-compressed)
- `traces.zig` - Traces export tests (uncompressed and gzip-compressed)
- `logs.zig` - Logs export tests (uncompressed and gzip-compressed)

Each test executable runs independently with its own:
- Unique Docker container (named `otel-test-{signal}-{timestamp}-{random}`)
- Temporary directory for output files
- OTLP collector instance

## Prerequisites

- Docker must be installed and running
- The OpenTelemetry collector image (`otel/opentelemetry-collector:latest`) will be pulled automatically

## Running the Tests

To run all integration tests:

```bash
zig build integration
```

The tests will run with separate collector containers, allowing for parallel execution.

## What the Tests Do

Each integration test:

1. **Check Docker Availability**: Verify that Docker is installed and accessible
2. **Setup Data Directory**: Create a unique temporary directory for output files
3. **Start OTLP Collector**: Launch an OpenTelemetry collector container with a unique name
   - The data directory is mounted to `/tmp/otel-data` inside the container
   - Configuration is loaded from `otel-collector-config.yaml`
4. **Test Signal Export** (for each signal type - metrics, traces, logs):
   - Send test data to the collector via OTLP HTTP
   - Validate data was received by reading and parsing the generated JSON file
   - Check for expected content in the JSON output
5. **Test Compression**: Run the same tests with gzip compression enabled
6. **Cleanup**: Stop and remove the collector container

### JSON File Validation

The tests validate that data was received by reading JSON files exported by the OTLP collector's file exporter. For metrics, the validation checks for:
- The presence of `resourceMetrics` or metric-related keywords
- The specific metric name (`test_counter`)

For traces, the validation checks for:
- The presence of `resourceSpans` or span-related keywords
- The expected span names (`test-span-0`, `test-span-1`, etc.)
- The tracer name (`integration-test`)

For logs, the validation checks for:
- The presence of `resourceLogs` or log-related keywords
- The expected log messages containing "Test"
- The logger scope name (`integration-test`)

## Configuration

The collector configuration is defined in `otel-collector-config.yaml`:

- **HTTP Endpoint**: Port 4318 (used by the SDK)
- **gRPC Endpoint**: Port 4317
- **Exporters**:
  - File exporter for traces: `/tmp/otel-data/traces.json`
  - File exporter for metrics: `/tmp/otel-data/metrics.json`
  - File exporter for logs: `/tmp/otel-data/logs.json`

## Adding New Integration Tests

To add new integration tests:

1. Create a new `.zig` file in the `integration_tests/` directory
2. Import the `common` module and follow the pattern used in existing tests:
   ```zig
   const common = @import("common.zig");

   pub fn main() !void {
       const allocator = std.heap.page_allocator;
       var ctx = try common.setupTestContext(allocator, "my-test");
       defer common.cleanupTestContext(&ctx);

       // Run your tests using ctx.tmp_dir
   }
   ```
3. Use utilities from `common.zig` for:
   - `setupTestContext()` - Sets up container and temporary directory
   - `cleanupTestContext()` - Cleans up container and resources
   - `waitForFile()` - Wait for collector to write output files
   - `waitForFileContent()` - Wait for specific content in output files
   - `readJsonFile()` - Read JSON output files
4. The test will automatically be discovered and run by `zig build integration`

## Troubleshooting

### Connection Refused Errors

If you see `error.ConnectionRefused`, check that:
- Docker is running
- Port 4318 is not already in use
- The collector container started successfully

### Memory Leaks

The tests use a GPA (General Purpose Allocator) with leak detection. If leaks are reported, ensure all resources are properly cleaned up with `defer` statements.
