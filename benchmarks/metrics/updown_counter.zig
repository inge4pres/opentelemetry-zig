const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics = sdk.metrics;
const MeterProvider = metrics.MeterProvider;
const benchmark = @import("benchmark");

// Benchmark configuration
const bench_config = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 2 * std.time.ns_per_s,
    .track_allocations = false,
};

fn setupSDK(allocator: std.mem.Allocator) !*MeterProvider {
    const mp = try MeterProvider.init(allocator);
    errdefer mp.shutdown();
    return mp;
}

test "UpDownCounter_Add_WithoutAttributes" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const updown = try meter.createUpDownCounter(i64, .{
        .name = "benchmark_updown_counter",
        .description = "UpDownCounter for benchmarking",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const bench_instance = struct {
        counter: *metrics.Counter(i64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.counter.add(1, .{}) catch @panic("add failed");
        }
    }{ .counter = updown };

    try bench.addParam("UpDownCounter_Add_WithoutAttributes", &bench_instance, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "UpDownCounter_Add_WithAttributes" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const updown = try meter.createUpDownCounter(i64, .{
        .name = "benchmark_updown_counter",
        .description = "UpDownCounter for benchmarking",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const bench_instance = struct {
        counter: *metrics.Counter(i64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const attr1: []const u8 = "updown_value1";
            const attr2: []const u8 = "updown_value2";
            const attr3: []const u8 = "up";
            self.counter.add(1, .{
                "direction", attr3,
                "attr1",     attr1,
                "attr2",     attr2,
            }) catch @panic("add failed");
        }
    }{ .counter = updown };

    try bench.addParam("UpDownCounter_Add_WithAttributes", &bench_instance, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "UpDownCounter_Concurrent" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const updown = try meter.createUpDownCounter(i64, .{
        .name = "benchmark_updown_counter",
        .description = "UpDownCounter for benchmarking",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const concurrent_bench = ConcurrentUpDownBench{ .counter = updown };
    try bench.addParam("UpDownCounter_Concurrent", &concurrent_bench, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

const ConcurrentUpDownBench = struct {
    counter: *metrics.Counter(i64),

    pub fn run(self: @This(), _: std.mem.Allocator) void {
        const t1 = std.Thread.spawn(.{}, addPositive, .{self.counter}) catch @panic("spawn failed");
        const t2 = std.Thread.spawn(.{}, addNegative, .{self.counter}) catch @panic("spawn failed");
        const t3 = std.Thread.spawn(.{}, addWithoutAttrs, .{self.counter}) catch @panic("spawn failed");

        t1.join();
        t2.join();
        t3.join();
    }

    fn addPositive(counter: *metrics.Counter(i64)) void {
        const t1_thread: []const u8 = "t1";
        const up_dir: []const u8 = "up";
        counter.add(1, .{
            "thread",    t1_thread,
            "direction", up_dir,
        }) catch @panic("add failed");
    }

    fn addNegative(counter: *metrics.Counter(i64)) void {
        const t2_thread: []const u8 = "t2";
        const down_dir: []const u8 = "down";
        counter.add(-1, .{
            "thread",    t2_thread,
            "direction", down_dir,
        }) catch @panic("add failed");
    }

    fn addWithoutAttrs(counter: *metrics.Counter(i64)) void {
        counter.add(1, .{}) catch @panic("add failed");
    }
};

test "UpDownCounter_MixedOperations" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const updown = try meter.createUpDownCounter(i64, .{
        .name = "benchmark_updown_counter",
        .description = "UpDownCounter for benchmarking",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const mixed_ops = struct {
        counter: *metrics.Counter(i64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const op1: []const u8 = "batch_up";
            const op2: []const u8 = "batch_down";
            const op3: []const u8 = "single_up";
            const op4: []const u8 = "correction";

            // Simulate mixed up/down operations
            self.counter.add(5, .{ "op", op1 }) catch @panic("add failed");
            self.counter.add(-3, .{ "op", op2 }) catch @panic("add failed");
            self.counter.add(1, .{ "op", op3 }) catch @panic("add failed");
            self.counter.add(-2, .{ "op", op4 }) catch @panic("add failed");
        }
    }{ .counter = updown };

    try bench.addParam("UpDownCounter_MixedOperations", &mixed_ops, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "UpDownCounterMixedOps" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "benchmark.general",
    });

    const updown = try meter.createUpDownCounter(i64, .{
        .name = "test_updown",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const mixed_ops = struct {
        counter: *metrics.Counter(i64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Use random to alternate between positive and negative values
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
            const is_positive = rng.random().boolean();
            const value: i64 = if (is_positive) 1 else -1;
            const op: []const u8 = if (value > 0) "increment" else "decrement";

            self.counter.add(value, .{
                "operation", op,
            }) catch @panic("counter add failed");
        }
    }{ .counter = updown };

    try bench.addParam("UpDownCounterMixedOps", &mixed_ops, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}
