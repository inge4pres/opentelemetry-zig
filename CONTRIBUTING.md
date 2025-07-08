# Contributing to OpenTelemetry Zig

The version of Zig used for development is declared in [`build.zig.zon`](./build.zig.zon) in the `.minimum_zig_version` field.

## Running tests

Unit tests are executed as part of CI pipeline, you can run them locally while developing:

```
zig build test
```

## Running benchmarks

Benchmarks are executed as part of the pipeline on Pull Requests if the contain a label `run::benchmarks`.

They can be executed locally with:

```
zig build benchmarks -Doptimize=ReleaseFast
```

### Benchmark options

The benchmark build supports the following options:

- `-Dbenchmark-filter=<pattern>`: Filter benchmarks to run only those matching the specified pattern
- `-Dbenchmark-output=<path>`: Path to write benchmark results to a file

Example usage:

```
# Run only counter benchmarks
zig build benchmarks -Doptimize=ReleaseFast -Dbenchmark-filter="counter"

# Run a specific benchmark and save results
zig build benchmarks -Doptimize=ReleaseFast -Dbenchmark-filter="hist.record" -Dbenchmark-output="results.txt"
```

> [!NOTE]
> Currently there is no good way of comparing benchmark runs across various machines,
> as the results do not include CPU information.
> Benchmarks are still useful for detecting improvements or regressions during local development.

## Generating OTLP protobuf code

Types for OTLP are generated from the official protobuf [definitions](https://github.com/open-telemetry/opentelemetry-proto/tree/main/opentelemetry/proto) using
the code generation provided by [Arwalk/zig-protobuf](https://github.com/Arwalk/zig-protobuf) (thanks @Arwalk).

Generated code must be committed and can be updated by running:

```
zig build gen-proto
```


