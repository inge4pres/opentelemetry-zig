const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;
const benchmark = @import("benchmark");

// Benchmark configuration
const bench_config = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 2 * std.time.ns_per_s,
    .track_allocations = true,
};

test "ObservableCounter_Create" {
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("ObservableCounter_Create", ObservableCounterBench.run, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ObservableCounterBench = struct {
    pub fn run(allocator: std.mem.Allocator) void {
        const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
        defer provider.shutdown();

        const meter = provider.getMeter(.{
            .name = "observable-counter-benchmark",
        }) catch @panic("failed to get meter");

        // Create observable counter with a basic callback
        _ = meter.createObservableCounter(.{
            .name = "benchmark_observable_counter",
            .description = "Observable counter for benchmarking",
            .unit = "1",
        }, .{}, null) catch @panic("failed to create observable counter");
    }
};

test "ObservableUpDownCounter_Create" {
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("ObservableUpDownCounter_Create", ObservableUpDownBench.run, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ObservableUpDownBench = struct {
    pub fn run(allocator: std.mem.Allocator) void {
        const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
        defer provider.shutdown();

        const meter = provider.getMeter(.{
            .name = "observable-updown-benchmark",
        }) catch @panic("failed to get meter");

        _ = meter.createObservableUpDownCounter(.{
            .name = "benchmark_observable_updown",
            .description = "Observable updown counter for benchmarking",
            .unit = "1",
        }, .{}, null) catch @panic("failed to create observable updown counter");
    }
};

test "ObservableGauge_Create" {
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.add("ObservableGauge_Create", ObservableGaugeBench.run, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ObservableGaugeBench = struct {
    pub fn run(allocator: std.mem.Allocator) void {
        const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
        defer provider.shutdown();

        const meter = provider.getMeter(.{
            .name = "observable-gauge-benchmark",
        }) catch @panic("failed to get meter");

        _ = meter.createObservableGauge(.{
            .name = "benchmark_observable_gauge",
            .description = "Observable gauge for benchmarking",
            .unit = "ratio",
        }, .{}, null) catch @panic("failed to create observable gauge");
    }
};
