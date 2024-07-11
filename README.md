# OpenTelemetry Zig

This is an implementation of the OpenTelemetry specification for the [Zig](https://ziglang.org) programming language.

Type are generated from the official protobuf [definitions](https://github.com/open-telemetry/opentelemetry-proto/tree/main/opentelemetry/proto) using
the code generation provided by [Arwalk/zig-protobuf](https://github.com/Arwalk/zig-protobuf) (thanks @Arwalk).

Generated code is committed and can be updated by running:

```
zig build gen-proto
```


