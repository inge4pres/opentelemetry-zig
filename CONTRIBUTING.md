# Contributing to OpenTelemetry Zig

The version of Zig used for development is declared in [`build.zig.zon`](./build.zig.zon) in the `.minimum_zig_version` field.

## Running tests

Unit tests are executed as part of CI pipeline, you can run them locally while developing:

```
zig build test
```

### Test options

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

## Running benchmarks

Benchmarks are executed as part of the pipeline on Pull Requests if the contain a label `run::benchmarks`.

They can be executed locally with:

```
zig build benchmarks -Doptimize=ReleaseFast
```

### Benchmark options

The benchmark build supports the following options:

- `-Dbenchmark-output=<path>`: Path to write benchmark results to a file

To run only specific benchmarks matching a pattern, use build args:

```
# Run only counter benchmarks
zig build benchmarks -Doptimize=ReleaseFast -- "counter"

# Run a specific benchmark and save results
zig build benchmarks -Doptimize=ReleaseFast -Dbenchmark-output="results.txt" -- "hist.record"
```

> [!NOTE]
> Currently there is no good way of comparing benchmark runs across various machines,
> as the results do not include CPU information.
> Benchmarks are still useful for detecting improvements or regressions during local development.



