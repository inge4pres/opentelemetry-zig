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

// Benchmark configuration matching Rust (1s warmup, 2s measurement)
const bench_config = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 2 * std.time.ns_per_s,
    .track_allocations = true,
};

fn setupSDK(allocator: std.mem.Allocator) !*sdk.MeterProvider {
    const mp = try MeterProvider.init(allocator);
    errdefer mp.shutdown();
    return mp;
}

// Static attribute values for testing
const ATTR_VALUES = [_][]const u8{
    "value_0", "value_1", "value_2", "value_3", "value_4",
    "value_5", "value_6", "value_7", "value_8", "value_9",
};

test "Histogram_Record" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.histogram",
    });
    
    const histogram = try meter.createHistogram(f64, .{
        .name = "response_time",
        .description = "Response time in milliseconds",
        .unit = "ms",
        .histogramOpts = .{
            .explicitBuckets = &[_]f64{ 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0 },
        },
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const static_bench = struct {
        histogram: *sdk.Histogram(f64),
        
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx3 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx4 = rng.random().intRangeAtMost(usize, 0, 9);
            
            // Generate random value between 0 and 500
            const value = rng.random().float(f64) * 500.0;
            
            self.histogram.record(value, .{
                "attr1", ATTR_VALUES[idx1],
                "attr2", ATTR_VALUES[idx2],
                "attr3", ATTR_VALUES[idx3],
                "attr4", ATTR_VALUES[idx4],
            }) catch @panic("histogram record failed");
        }
    }{ .histogram = histogram };
    
    try bench.addParam("Histogram_Record", &static_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Histogram_Record_With_Non_Static_Values" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.histogram",
    });
    
    const histogram = try meter.createHistogram(f64, .{
        .name = "response_time",
        .description = "Response time in milliseconds",
        .unit = "ms",
        .histogramOpts = .{
            .explicitBuckets = &[_]f64{ 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0 },
        },
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const dynamic_bench = struct {
        histogram: *sdk.Histogram(f64),
        
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
            
            // Generate random value between 0 and 500
            const value = rng.random().float(f64) * 500.0;
            
            self.histogram.record(value, .{
                "attr1", val1,
                "attr2", val2,
                "attr3", val3,
                "attr4", val4,
            }) catch @panic("histogram record failed");
        }
    }{ .histogram = histogram };
    
    try bench.addParam("Histogram_Record_With_Non_Static_Values", &dynamic_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

// Additional histogram benchmarks with different bucket configurations
test "Histogram_Record_With_Many_Buckets" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.histogram.many_buckets",
    });
    
    // Create histogram with 50 buckets similar to Rust benchmarks
    var buckets: [50]f64 = undefined;
    for (&buckets, 0..) |*bucket, i| {
        bucket.* = @as(f64, @floatFromInt(i)) * 10.0;
    }
    
    const histogram = try meter.createHistogram(f64, .{
        .name = "response_time_many_buckets",
        .description = "Response time with many buckets",
        .unit = "ms",
        .histogramOpts = .{
            .explicitBuckets = &buckets,
        },
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const many_buckets_bench = struct {
        histogram: *sdk.Histogram(f64),
        
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            
            // Generate random value between 0 and 500
            const value = rng.random().float(f64) * 500.0;
            
            self.histogram.record(value, .{
                "service", ATTR_VALUES[idx1],
                "endpoint", ATTR_VALUES[idx2],
            }) catch @panic("histogram record failed");
        }
    }{ .histogram = histogram };
    
    try bench.addParam("Histogram_Record_With_50_Buckets", &many_buckets_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Histogram_Concurrent" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark-concurrent",
    });

    const histogram = try meter.createHistogram(f64, .{
        .name = "histogram_concurrent",
        .description = "A histogram for concurrent benchmarking",
        .unit = "ms",
        .histogramOpts = .{
            .explicitBuckets = &[_]f64{ 0.5, 1.0, 5.0, 10.0, 50.0, 100.0, 500.0, 1000.0 },
        },
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const concurrent_bench = ConcurrentHistogramBench{ .histogram = histogram };
    try bench.addParam("Histogram_Concurrent", &concurrent_bench, .{ .track_allocations = true });

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ConcurrentHistogramBench = struct {
    histogram: *sdk.Histogram(f64),

    pub fn run(self: @This(), _: std.mem.Allocator) void {
        const t1 = std.Thread.spawn(.{}, recordFast, .{self.histogram}) catch @panic("spawn failed");
        const t2 = std.Thread.spawn(.{}, recordMedium, .{self.histogram}) catch @panic("spawn failed");
        const t3 = std.Thread.spawn(.{}, recordSlow, .{self.histogram}) catch @panic("spawn failed");
        
        t1.join();
        t2.join();
        t3.join();
    }

    fn recordFast(histogram: *sdk.Histogram(f64)) void {
        const attr1: []const u8 = "fast";
        const attr2: []const u8 = "p50";
        histogram.record(2.5, .{
            "latency_type", attr1,
            "percentile", attr2,
        }) catch @panic("record failed");
    }

    fn recordMedium(histogram: *sdk.Histogram(f64)) void {
        const attr1: []const u8 = "medium";
        const attr2: []const u8 = "p90";
        histogram.record(45.0, .{
            "latency_type", attr1,
            "percentile", attr2,
        }) catch @panic("record failed");
    }

    fn recordSlow(histogram: *sdk.Histogram(f64)) void {
        const attr1: []const u8 = "slow";
        const attr2: []const u8 = "p99";
        histogram.record(250.0, .{
            "latency_type", attr1,
            "percentile", attr2,
        }) catch @panic("record failed");
    }
};

test "Histogram_Record_Varied_Values" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const histogram = try meter.createHistogram(f64, .{
        .name = "benchmark_histogram_varied",
        .description = "Histogram for benchmarking varied values",
        .unit = "ms",
        .histogramOpts = .{
            .explicitBuckets = &[_]f64{ 0.1, 0.5, 1.0, 5.0, 10.0, 50.0, 100.0, 500.0, 1000.0 },
        },
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const varied_bench = struct {
        histogram: *sdk.Histogram(f64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const test_attr: []const u8 = "varied";
            // Test with different values that hit different buckets
            const values = [_]f64{ 0.05, 0.3, 0.8, 3.2, 7.5, 25.0, 75.0, 250.0, 750.0 };
            for (values) |val| {
                self.histogram.record(val, .{ "test", test_attr }) catch @panic("record failed");
            }
        }
    }{ .histogram = histogram };

    try bench.addParam("Histogram_Record_Varied_Values", &varied_bench, .{ .track_allocations = true });

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}