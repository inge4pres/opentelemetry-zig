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
| gRPC | ✅ opt-in, see [OTLP over gRPC](#otlp-over-grpc) |
| Compression (gzip) | ✅ |


## Features

### Metric exemplars

Exemplars retain a measurement's value, time and trace context alongside an
aggregated data point. By default, measurements from sampled spans are eligible.
Initialize `sdk.config.Configuration` to read `OTEL_METRICS_EXEMPLAR_FILTER`;
its values are `trace_based`, `always_on` and `always_off`.

Collected points expose `exemplars`, including attributes removed by a View.
OTLP exports them in protobuf and JSON. Views can supply a custom
`exemplar_reservoir` factory; the SDK creates one reservoir per time series.

The [exemplar example](examples/metrics/exemplars.zig) records within a span and
collects after it ends. Run it without a collector:

```bash
zig build sdk-run-examples -Dexamples-filter=exemplars
```

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

### OTLP over gRPC

Exporting over gRPC requires linking a gRPC implementation, which the SDK does not
pull in unless asked: the default build has no gRPC backend, and selecting the gRPC
protocol then fails every export with `error.UnimplementedTransportProtocol`. The
HTTP protocols are unaffected.

Pick an implementation with the `grpc-provider` option. `libgrpc` is currently the
only one, binding [gRPC Core](https://github.com/grpc/grpc) through
[cgrpc_wrapper](https://github.com/agagniere/cgrpc_wrapper):

```zig
const otel = b.dependency("opentelemetry", .{
    .target = target,
    .@"grpc-provider" = "libgrpc",
});
exe.root_module.addImport("opentelemetry-sdk", otel.module("sdk"));
```

Then select the protocol at runtime, along with the collector's gRPC port (4317,
where the HTTP protocols use 4318):

```zig
var config = try sdk.otlp.ConfigOptions.init(allocator, env_map);
defer config.deinit();

config.protocol = .grpc;
// Unless set from OTEL_EXPORTER_OTLP_ENDPOINT, the endpoint is not allocated and can be replaced
if (env_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") == null) config.endpoint = "localhost:4317";
```

`OTEL_EXPORTER_OTLP_PROTOCOL=grpc` and `OTEL_EXPORTER_OTLP_ENDPOINT=<host:port>`
select the same thing from the environment. See
[examples/grpc/all_signals.zig](./examples/grpc/all_signals.zig) for a complete
program exporting all three signals over gRPC.

#### Building against libgrpc

gRPC Core is built from source by default. It is a large C++ project, so expect a
slow first build. It is linked statically, producing self-contained executables,
at the cost of slower links and much larger binaries. Two alternatives:

- **Linking it dynamically.** `.@"grpc-link-mode" = .dynamic` builds a shared
  library that the executable loads at runtime, making links much faster: in Debug
  on macOS, `all_signals` drops from 314 MB to under 8 MB, and linking it from about
  2.7 GB of RAM to 0.7 GB. The executable looks for libgrpc in `../lib` relative to
  itself, matching the default install layout, so install the shared library along
  with it:

  ```zig
  if (!b.systemIntegrationOption("grpc", .{})) {
      const libgrpc = otel.artifact("grpc");
      if (libgrpc.isDynamicLibrary())
          b.installArtifact(libgrpc);
  }
  ```

  Without it, libgrpc is only found through an rpath into the build cache: enough
  for `zig build run`, but an installed binary run from another directory aborts
  with `Library not loaded: @rpath/libgrpc.dylib`. Binaries installed outside
  `bin/` need an rpath of their own, as this repository's examples get in
  [build/helpers.zig](../build/helpers.zig).
- **Using the system libgrpc instead.** `-fsys=grpc` links the libgrpc already
  installed on the machine and skips the source build altogether. The system library
  carries an absolute install name, so the rpath caveat above does not apply. On
  macOS, Zig only searches Homebrew's directories when `HOMEBREW_PREFIX` is set
  (as `brew shellenv` does):

  ```bash
  HOMEBREW_PREFIX="$(brew --prefix)" zig build sdk-examples -Dgrpc-provider=libgrpc -fsys=grpc
  ```

  A recent libgrpc is recommended, and at least 1.76, the oldest version tested:
  some Linux distributions still ship much older ones.

Inside this repository `-Dgrpc-provider` applies to every SDK step. The
integration tests start their own collector container:

```bash
zig build sdk-run-integration -Dgrpc-provider=libgrpc -Dintegration-filter=logs_grpc
```

The examples instead export to a collector started separately:

```bash
docker run --rm -p 4317:4317 otel/opentelemetry-collector
zig build sdk-run-examples -Dgrpc-provider=libgrpc -Dexamples-filter=all_signals
```

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
