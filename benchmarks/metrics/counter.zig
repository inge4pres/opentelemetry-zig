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

// Helper struct for pre-generated random indices
const RandomIndicesPool = struct {
    indices: [][4]u8,
    counter: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pool_size: usize) !RandomIndicesPool {
        const indices = try allocator.alloc([4]u8, pool_size);
        errdefer allocator.free(indices);

        // Fill the pool with random indices
        const rng = getThreadRng();
        for (indices) |*idx_set| {
            idx_set[0] = rng.random().intRangeAtMost(u8, 0, 9);
            idx_set[1] = rng.random().intRangeAtMost(u8, 0, 9);
            idx_set[2] = rng.random().intRangeAtMost(u8, 0, 9);
            idx_set[3] = rng.random().intRangeAtMost(u8, 0, 9);
        }

        return RandomIndicesPool{
            .indices = indices,
            .counter = std.atomic.Value(u32).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RandomIndicesPool) void {
        self.allocator.free(self.indices);
    }

    pub fn getNext(self: *RandomIndicesPool) [4]u8 {
        const idx = self.counter.fetchAdd(1, .monotonic) % self.indices.len;
        return self.indices[idx];
    }
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

    // Pre-generate random indices to avoid RNG overhead during benchmark
    var random_pool = try RandomIndicesPool.init(std.testing.allocator, 10000);
    defer random_pool.deinit();

    const sorted_bench = struct {
        counter: *sdk.Counter(u64),
        random_pool: *RandomIndicesPool,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const indices = self.random_pool.getNext();

            // Note: In Zig, attributes are already sorted by the SDK
            self.counter.add(1, .{
                "attr1", ATTR_VALUES[indices[0]],
                "attr2", ATTR_VALUES[indices[1]],
                "attr3", ATTR_VALUES[indices[2]],
                "attr4", ATTR_VALUES[indices[3]],
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter, .random_pool = &random_pool };

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

    // Pre-generate random indices to avoid RNG overhead during benchmark
    var random_pool = try RandomIndicesPool.init(std.testing.allocator, 10000);
    defer random_pool.deinit();

    const unsorted_bench = struct {
        counter: *sdk.Counter(u64),
        random_pool: *RandomIndicesPool,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const indices = self.random_pool.getNext();

            // Intentionally unsorted attribute order
            self.counter.add(1, .{
                "attr4", ATTR_VALUES[indices[3]],
                "attr2", ATTR_VALUES[indices[1]],
                "attr3", ATTR_VALUES[indices[2]],
                "attr1", ATTR_VALUES[indices[0]],
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter, .random_pool = &random_pool };

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

    // Pre-generate random indices to avoid RNG overhead during benchmark
    var random_pool = try RandomIndicesPool.init(std.testing.allocator, 10000);
    defer random_pool.deinit();

    const dynamic_bench = struct {
        counter: *sdk.Counter(u64),
        allocator: std.mem.Allocator,
        random_pool: *RandomIndicesPool,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const indices = self.random_pool.getNext();

            // Create dynamic strings
            var buf1: [20]u8 = undefined;
            var buf2: [20]u8 = undefined;
            var buf3: [20]u8 = undefined;
            var buf4: [20]u8 = undefined;

            const val1 = std.fmt.bufPrint(&buf1, "value_{}", .{indices[0]}) catch @panic("fmt failed");
            const val2 = std.fmt.bufPrint(&buf2, "value_{}", .{indices[1]}) catch @panic("fmt failed");
            const val3 = std.fmt.bufPrint(&buf3, "value_{}", .{indices[2]}) catch @panic("fmt failed");
            const val4 = std.fmt.bufPrint(&buf4, "value_{}", .{indices[3]}) catch @panic("fmt failed");

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
        .random_pool = &random_pool,
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

    // Initialize atomic counter for iteration tracking
    var iteration_counter = std.atomic.Value(u32).init(0);

    const overflow_bench = struct {
        counter: *sdk.Counter(u64),
        iteration_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Use atomic fetchAdd to get unique iteration number for each call
            const iteration = self.iteration_counter.fetchAdd(1, .monotonic);

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
    }{ .counter = counter, .iteration_counter = &iteration_counter };

    try bench.addParam("Counter_Overflow", &overflow_bench, .{});

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
