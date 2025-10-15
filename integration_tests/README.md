# Integration Tests

This directory contains integration tests for the OpenTelemetry SDK that run against a real OTLP collector.

## Prerequisites

- Docker must be installed and running
- The OpenTelemetry collector image (`otel/opentelemetry-collector:latest`) will be pulled automatically

## Running the Tests

To run all integration tests:

```bash
zig build integration
```

## What the Tests Do

The integration tests:

1. **Check Docker Availability**: Verify that Docker is installed and accessible
2. **Setup Data Directory**: Create a temporary directory (`/tmp/otel-integration-test-data`) for output files
3. **Start OTLP Collector**: Launch an OpenTelemetry collector container with the configuration from `otel-collector-config.yaml`
   - The data directory is mounted to `/tmp/otel-data` inside the container
4. **Test Metrics Export**:
   - Send test metrics data to the collector via OTLP HTTP
   - Validate metrics were received by reading and parsing the generated `metrics.json` file
   - Check for expected metric names and data points in the JSON output
5. **Test Traces Export**:
   - Send test trace spans to the collector via OTLP HTTP
   - Validate traces were received by reading and parsing the generated `traces.json` file
   - Check for expected span names and trace data in the JSON output
6. **Cleanup**: Stop and remove the collector container, then remove the temporary data directory and all files

### JSON File Validation

The tests validate that data was received by reading JSON files exported by the OTLP collector's file exporter. For metrics, the validation checks for:
- The presence of `resourceMetrics` or metric-related keywords
- The specific metric name (`test_counter`)

For traces, the validation checks for:
- The presence of `resourceSpans` or span-related keywords
- The expected span names (`test-span-0`, `test-span-1`, etc.)
- The tracer name (`integration-test`)

## Configuration

The collector configuration is defined in `otel-collector-config.yaml`:

- **HTTP Endpoint**: Port 4318 (used by the SDK)
- **gRPC Endpoint**: Port 4317
- **Exporters**:
  - File exporter for traces: `/tmp/otel-data/traces.json`
  - File exporter for metrics: `/tmp/otel-data/metrics.json`

## Adding New Integration Tests

To add new integration tests:

1. Create a new `.zig` file in the `integration_tests/` directory
2. Follow the same pattern as `otlp.zig`:
   - Start the collector container
   - Configure the SDK to use `localhost:4318`
   - Run your test scenarios
   - Clean up the container
3. The test will automatically be discovered and run by `zig build integration`

## Troubleshooting

### Connection Refused Errors

If you see `error.ConnectionRefused`, check that:
- Docker is running
- Port 4318 is not already in use
- The collector container started successfully

### Memory Leaks

The tests use a GPA (General Purpose Allocator) with leak detection. If leaks are reported, ensure all resources are properly cleaned up with `defer` statements.
