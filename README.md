<div class="title-block" style="text-align: center;" align="center">

# OpenTelemetry Zig

<p><img title="jj logo" src="docs/images/zero-otel.png" width="320"></p>

**[Zig docs] &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Installation](#installation) &nbsp;&nbsp;&bull;&nbsp;&nbsp;**
**[Contributing](#contributing)**

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
