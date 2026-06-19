# Contributing to OpenTelemetry Zig

The version of Zig used for development is declared in [`build.zig.zon`](./build.zig.zon) in the `.minimum_zig_version` field.

## Build Commands

### Building the library

Build the SDK library:

```
zig build
```

This compiles the OpenTelemetry SDK as a static library in `zig-out/lib/`.

### Running tests

Unit tests are executed as part of CI pipeline, you can run them locally while developing:

```
zig build test
```

#### Test options

The test build supports the following options:

- `-Dtest-verbose=true`: Show verbose test output with timing information (instead of dots)
- `-Dtest-fail-first=true`: Stop on first test failure
- `-Dtest-show-logs=true`: Show captured log output for tests with warnings/errors

To run only specific tests matching a pattern, use build args:

```
zig build test -- "counter"
```

Example usage:

```
# Run tests with verbose output (shows test names and timing)
zig build test -Dtest-verbose=true

# Run specific tests with verbose output and stop on first failure
zig build test -Dtest-verbose=true -Dtest-fail-first=true -- "counter"

# Show captured logs for tests with warnings/errors
zig build test -Dtest-show-logs=true
```

### Running integration tests

Integration tests verify the SDK behavior against real OpenTelemetry backends. These tests require Docker to be installed and running.

```
zig build integration
```

Integration tests are executed as part of CI on pull requests.

> [!IMPORTANT]
> Integration tests require Docker to be installed and the Docker daemon to be running.

### Running examples

Build and run all examples:

```
zig build examples
```

#### Examples options

Filter examples to build and run specific ones:

```
# Run only examples matching "otlp"
zig build examples -Dexamples-filter=otlp

# Run only histogram examples
zig build examples -Dexamples-filter=histogram
```

Examples are organized by signal type:
- `examples/metrics/` - Metrics API examples
- `examples/trace/` - Tracing API examples
- `examples/logs/` - Logging API examples

### Running benchmarks

Benchmarks are executed as part of the pipeline on Pull Requests if they contain a label `run::benchmarks`.

They can be executed locally with:

```
zig build benchmarks -Doptimize=ReleaseFast
```

#### Benchmark options

The benchmark build supports the following options:

- `-Dbenchmark-output=<path>`: Path to write benchmark results to a file
- `-Dbenchmark-debug=true`: Enable debug build mode for benchmarks (useful for profiling)

To run only specific benchmarks matching a pattern, use build args:

```
# Run only counter benchmarks
zig build benchmarks -Doptimize=ReleaseFast -- "counter"

# Run a specific benchmark and save results
zig build benchmarks -Doptimize=ReleaseFast -Dbenchmark-output="results.txt" -- "hist.record"

# Run benchmarks in debug mode for profiling
zig build benchmarks -Dbenchmark-debug=true -- "counter"
```

> [!NOTE]
> Currently there is no good way of comparing benchmark runs across various machines,
> as the results do not include CPU information.
> Benchmarks are still useful for detecting improvements or regressions during local development.

### Generating documentation

Generate API documentation:

```
zig build docs
```

Documentation will be generated in `zig-out/docs/` and can be viewed by opening `index.html` in a browser.

## Development Workflow

A typical development workflow:

1. Make your changes
2. Run unit tests: `zig build test`
3. Run integration tests: `zig build integration` (if applicable)
4. Run relevant examples: `zig build examples -Dexamples-filter=<signal>`
5. Run benchmarks: `zig build benchmarks -Doptimize=ReleaseFast` (if performance-critical)
6. Commit your changes



