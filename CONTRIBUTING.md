# Contributing to OpenTelemetry Zig

The version of Zig used for development is declared in [`build.zig.zon`](./build.zig.zon) in the `.minimum_zig_version` field.

## Running tests

Unit tests are executed as part of CI pipeline, you can run them locally while developing:

```
zig build test
```

## Generating OTLP protobuf code

Types for OTLP are generated from the official protobuf [definitions](https://github.com/open-telemetry/opentelemetry-proto/tree/main/opentelemetry/proto) using
the code generation provided by [Arwalk/zig-protobuf](https://github.com/Arwalk/zig-protobuf) (thanks @Arwalk).

Generated code must be committed and can be updated by running:

```
zig build gen-proto
```


