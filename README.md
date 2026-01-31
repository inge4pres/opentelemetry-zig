<div class="title-block" style="text-align: center;" align="center">

# OpenTelemetry Zig

<p><img title="jj logo" src="docs/images/zero-otel.png" width="320"></p>

**[Zig docs] &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Installation](#installation) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Features](#features) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Examples](#examples) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Contributing](#contributing) &nbsp;&nbsp;&bull;&nbsp;&nbsp;****
**[Community](#join-the-community)**

[Zig docs]: https://zig-o11y.github.io/opentelemetry-sdk/

</div>

> [!CAUTION]
> This project is in **alpha** stage. While it is ready for usage and testing, it has not been battle-tested in production environments. Use with caution and expect breaking changes between releases.

This is an implementation of the [OpenTelemetry](https://opentelemetry.io) specification for the [Zig](https://ziglang.org) programming language.

The version of the OpenTelemetry specification targeted here is **1.48.0**.

## Goals

1. Provide a Zig library implementing the _stable_ features of an OpenTelemetry SDK
1. Provide a reference implementation of the OpenTelemetry API
1. Provide examples on how to use the library in real-world use cases

## Installation

Run the following command to add the package to your `build.zig.zon` dependencies, replacing `<ref>` with a release version:

```shall
zig fetch --save "git+https://github.com/zig-o11y/opentelemetry-sdk#<ref>"
```

Then in your `build.zig`:

```zig
const sdk = b.dependency("opentelemetry-sdk", .{
    .target = target,
    .optimize = optimize,
});
```

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

## Examples

Check out the [examples](./examples) folder for practical usage examples of traces, metrics, and logs.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to contribute to this project, including:

- Running tests locally
- Running benchmarks
- Test and benchmark options

## Origins

This project originated from a proposal in the OpenTelemetry community to create a native Zig implementation of the OpenTelemetry SDK.

You can read more about the original proposal and discussion at:

https://github.com/open-telemetry/community/issues/2514

For a more in-depth read of why OpenTelemetry needs a Zig SDK, see ["Zig is great for Observability"](https://inge.4pr.es/zig-is-great-for-observability/).

## Join the community

You can find the Zig OTel SDK developers in the [Zig-o11y Discord server](https://discord.gg/5TzezG2n).
