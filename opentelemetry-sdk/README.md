## OpenTelemetry SDK for Zig

The `opentelemetry-sdk` module: Zig implementations of the OpenTelemetry API and
SDK for traces, metrics, and logs, with OTLP and stdout exporters and C bindings.

It is wired into the repo build by `build/sdk/build.zig` and exposed as the `sdk`
module of the `opentelemetry-zig` package.

## Installation

Run the following command to add the package to your `build.zig.zon` dependencies, replacing `<ref>` with a release version or branch name:

```bash
zig fetch --save "git+https://github.com/open-telemetry/opentelemetry-zig#<ref>"
```

This adds an `opentelemetry` entry to your `build.zig.zon`. Then in your `build.zig`, import the `sdk` module:

```zig
const otel = b.dependency("opentelemetry", .{});
exe.root_module.addImport("opentelemetry-sdk", otel.module("sdk"));
```

And use it in your code:

```zig
const sdk = @import("opentelemetry-sdk");
```

## Specification Support State

### Signals

| Signal | Status |
|--------|--------|
| Traces | ✅ |
| Metrics | ✅ |
| Logs | ✅ |
| Profiles | ❌ |

### OTLP Protocol

| Feature | Status |
|---------|--------|
| HTTP/Protobuf | ✅ |
| HTTP/JSON | ✅ |
| gRPC | ❌ |
| Compression (gzip) | ✅ |


## Features

### `std.log` Bridge for Seamless Migration

The SDK includes a bridge that allows you to route Zig's standard `std.log` calls to OpenTelemetry without refactoring your entire codebase. This is perfect for gradual adoption of observability.

**Quick Start:**

```zig
const std = @import("std");
const sdk = @import("opentelemetry-sdk");

// Override std.log to use OpenTelemetry
pub const std_options: std.Options = .{
    .logFn = sdk.logs.std_log_bridge.logFn,
};

pub fn main() !void {
    var provider = try sdk.logs.LoggerProvider.init(allocator, null);
    defer provider.deinit();

    // Configure the bridge
    try sdk.logs.std_log_bridge.configure(.{
        .provider = provider,
        .also_log_to_stderr = true, // Dual mode: OTel + stderr
    });
    defer sdk.logs.std_log_bridge.shutdown();

    // Now std.log calls automatically go to OpenTelemetry!
    std.log.info("Application started", .{});
}
```

**Key Features:**
- **Dual-mode logging**: Send logs to both OpenTelemetry and stderr during migration
- **Thread-safe**: Safe for concurrent use across multiple threads
- **Scope strategies**: Single scope for all logs, or separate scopes per Zig module
- **Automatic severity mapping**: Zig log levels map to OpenTelemetry severity numbers
- **Source location tracking**: Optional file/line information as attributes

See [examples/logs/std_log_basic.zig](./examples/logs/std_log_basic.zig) and [examples/logs/std_log_migration.zig](./examples/logs/std_log_migration.zig) for complete examples.

## C Language Bindings

The SDK provides C-compatible bindings, allowing C programs to use OpenTelemetry instrumentation. The C API covers all three signals: Traces, Metrics, and Logs.

### Using from C

1. **Link with the compiled library**: Build the Zig library and link it with your C project.

2. **Include the header**: Add `include/opentelemetry.h` to your project.

3. **Basic usage example**:

```c
#include "opentelemetry.h"

int main() {
    // Create a meter provider
    otel_meter_provider_t* provider = otel_meter_provider_create();

    // Create an exporter and reader
    otel_metric_exporter_t* exporter = otel_metric_exporter_stdout_create();
    otel_metric_reader_t* reader = otel_metric_reader_create(exporter);
    otel_meter_provider_add_reader(provider, reader);

    // Get a meter
    otel_meter_t* meter = otel_meter_provider_get_meter(
        provider, "my-service", "1.0.0", NULL);

    // Create and use a counter
    otel_counter_u64_t* counter = otel_meter_create_counter_u64(
        meter, "requests", "Total requests", "1");
    otel_counter_add_u64(counter, 1, NULL, 0);

    // Collect and export metrics
    otel_metric_reader_collect(reader);

    // Cleanup
    otel_meter_provider_shutdown(provider);
    return 0;
}
```

### C API Features

- **Opaque handles**: All SDK objects are exposed as opaque handles for type safety
- **Memory management**: The C API manages memory internally using page allocators
- **Error handling**: Functions return status codes (0 for success, negative for errors)
- **Examples**: See `examples/c/` for complete examples of traces, metrics, and logs

For detailed API documentation, refer to `include/opentelemetry.h`.

## Examples

Check out the [examples](./examples) folder for practical usage examples:
- `examples/` - Zig examples for traces, metrics, and logs
- `examples/c/` - C language examples demonstrating the C API bindings

## Layout

- `src/` - API and SDK implementations (traces, metrics, logs, OTLP, C bindings)
- `include/opentelemetry.h` - C API header
- `examples/` - Zig and C usage examples
- `benchmarks/` - benchmarks
- `integration_tests/` - Docker-based integration tests
- `docs/` - design docs (e.g. `logs-emit-flow.md`)

The SDK build steps (`sdk-test`, `sdk-examples`, `sdk-benchmarks`, `sdk-integration`, `sdk-docs`) are documented in [CONTRIBUTING.md](../CONTRIBUTING.md).
