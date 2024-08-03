# OpenTelemetry Zig

> [!IMPORTANT]
> This project is a Work In Progress and not ready for production.
> In fact, it is not even ready for development as it is incomplete in its current form.

This is an implementation of the OpenTelemetry specification for the [Zig](https://ziglang.org) programming language.

The version of the spcification is 1.35.0.

## Goals

1. Provide a Zig library implementating the OpenTelemtry SDK:
    * Metrics
    * Traces
    * Logs
    * Events
1. Provide a reference implementation of the OpenTelemetry API
1. Provide examples on how to use the library in real-world use cases

## Data types

Types are generated from the official protobuf [definitions](https://github.com/open-telemetry/opentelemetry-proto/tree/main/opentelemetry/proto) using
the code generation provided by [Arwalk/zig-protobuf](https://github.com/Arwalk/zig-protobuf) (thanks @Arwalk).

Generated code is committed and can be updated by running:

```
zig build gen-proto
```


