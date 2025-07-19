const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;
const benchmark = @import("benchmark");

// Thread-local random number generator
threadlocal var thread_rng: ?std.Random.DefaultPrng = null;

fn getThreadRng() *std.Random.DefaultPrng {
    if (thread_rng == null) {
        thread_rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    }
    return &thread_rng.?;
}

// Benchmark configuration
const bench_config = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 2 * std.time.ns_per_s,
    .track_allocations = false,
};

fn setupSDK(allocator: std.mem.Allocator) !*sdk.MeterProvider {
    const mp = try MeterProvider.init(allocator);
    errdefer mp.shutdown();
    return mp;
}

// Generate random attributes similar to Rust benchmarks
const ATTR_VALUES = [_][]const u8{
    "value_0", "value_1", "value_2", "value_3", "value_4",
    "value_5", "value_6", "value_7", "value_8", "value_9",
};

test "Counter_Add_Sorted" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{
        .name = "benchmark.counter",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "requests_total",
        .description = "Total number of requests",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const sorted_bench = struct {
        counter: *sdk.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx3 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx4 = rng.random().intRangeAtMost(usize, 0, 9);

            // Note: In Zig, attributes are already sorted by the SDK
            self.counter.add(1, .{
                "attr1", ATTR_VALUES[idx1],
                "attr2", ATTR_VALUES[idx2],
                "attr3", ATTR_VALUES[idx3],
                "attr4", ATTR_VALUES[idx4],
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("Counter_Add_Sorted", &sorted_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Counter_Add_Unsorted" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{
        .name = "benchmark.counter",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "requests_total",
        .description = "Total number of requests",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const unsorted_bench = struct {
        counter: *sdk.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx3 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx4 = rng.random().intRangeAtMost(usize, 0, 9);

            // Intentionally unsorted attribute order
            self.counter.add(1, .{
                "attr4", ATTR_VALUES[idx4],
                "attr2", ATTR_VALUES[idx2],
                "attr3", ATTR_VALUES[idx3],
                "attr1", ATTR_VALUES[idx1],
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("Counter_Add_Unsorted", &unsorted_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Counter_Add_Non_Static_Values" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{
        .name = "benchmark.counter",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "requests_total",
        .description = "Total number of requests",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const dynamic_bench = struct {
        counter: *sdk.Counter(u64),
        allocator: std.mem.Allocator,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(u8, 0, 9);
            const idx2 = rng.random().intRangeAtMost(u8, 0, 9);
            const idx3 = rng.random().intRangeAtMost(u8, 0, 9);
            const idx4 = rng.random().intRangeAtMost(u8, 0, 9);

            // Create dynamic strings
            var buf1: [20]u8 = undefined;
            var buf2: [20]u8 = undefined;
            var buf3: [20]u8 = undefined;
            var buf4: [20]u8 = undefined;

            const val1 = std.fmt.bufPrint(&buf1, "value_{}", .{idx1}) catch @panic("fmt failed");
            const val2 = std.fmt.bufPrint(&buf2, "value_{}", .{idx2}) catch @panic("fmt failed");
            const val3 = std.fmt.bufPrint(&buf3, "value_{}", .{idx3}) catch @panic("fmt failed");
            const val4 = std.fmt.bufPrint(&buf4, "value_{}", .{idx4}) catch @panic("fmt failed");

            self.counter.add(1, .{
                "attr1", val1,
                "attr2", val2,
                "attr3", val3,
                "attr4", val4,
            }) catch @panic("counter add failed");
        }
    }{
        .counter = counter,
        .allocator = std.testing.allocator,
    };

    try bench.addParam("Counter_Add_Non_Static_Values", &dynamic_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Counter_Overflow" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    const meter = try mp.getMeter(.{
        .name = "benchmark.counter.overflow",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "overflow_test",
        .description = "Testing counter with many unique time series",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const overflow_bench = struct {
        counter: *sdk.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Use random values to create unique attributes for each iteration
            const rng = getThreadRng();
            const iteration = rng.random().int(u32);

            // Create unique attributes for each iteration to force new time series
            var buf1: [20]u8 = undefined;
            var buf2: [20]u8 = undefined;
            const key1 = std.fmt.bufPrint(&buf1, "iter_{}", .{iteration}) catch @panic("fmt failed");
            const key2 = std.fmt.bufPrint(&buf2, "batch_{}", .{iteration / 100}) catch @panic("fmt failed");

            self.counter.add(1, .{
                "iteration", key1,
                "batch",     key2,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("Counter_Overflow", &overflow_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "ThreadLocal_Random_Generator" {
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const rng_bench = struct {
        pub fn run(_: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            // Generate 5 random numbers similar to Rust benchmark
            _ = rng.random().intRangeAtMost(usize, 0, 9);
            _ = rng.random().intRangeAtMost(usize, 0, 9);
            _ = rng.random().intRangeAtMost(usize, 0, 9);
            _ = rng.random().intRangeAtMost(usize, 0, 9);
            _ = rng.random().intRangeAtMost(usize, 0, 9);
        }
    }{};

    try bench.addParam("ThreadLocal_Random_Generator_5", &rng_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Counter_Concurrent" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark-concurrent",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "counter_concurrent",
        .description = "A counter for concurrent benchmarking",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const concurrent_bench = ConcurrentCounterBench{ .counter = counter };
    try bench.addParam("Counter_Concurrent", &concurrent_bench, .{ .track_allocations = false });

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ConcurrentCounterBench = struct {
    counter: *sdk.Counter(u64),

    pub fn run(self: @This(), _: std.mem.Allocator) void {
        const t1 = std.Thread.spawn(.{}, addWithAttrs, .{self.counter}) catch @panic("spawn failed");
        const t2 = std.Thread.spawn(.{}, addWithoutAttrs, .{self.counter}) catch @panic("spawn failed");
        const t3 = std.Thread.spawn(.{}, addWithDifferentAttrs, .{self.counter}) catch @panic("spawn failed");

        t1.join();
        t2.join();
        t3.join();
    }

    fn addWithAttrs(counter: *sdk.Counter(u64)) void {
        const attr1: []const u8 = "thread1";
        const attr2: []const u8 = "concurrent";
        counter.add(1, .{
            "thread_id", attr1,
            "operation", attr2,
        }) catch @panic("add failed");
    }

    fn addWithoutAttrs(counter: *sdk.Counter(u64)) void {
        counter.add(1, .{}) catch @panic("add failed");
    }

    fn addWithDifferentAttrs(counter: *sdk.Counter(u64)) void {
        const attr1: []const u8 = "thread3";
        const attr2: []const u8 = "concurrent";
        const attr3: []const u8 = "test";
        counter.add(1, .{
            "thread_id", attr1,
            "operation", attr2,
            "type",      attr3,
        }) catch @panic("add failed");
    }
};
