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
    .track_allocations = false,
};

// Static attribute values for testing - 10 possible values per attribute
const ATTR_VALUES = [_][]const u8{
    "value_0", "value_1", "value_2", "value_3", "value_4",
    "value_5", "value_6", "value_7", "value_8", "value_9",
};

test "Gauge_Add" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.gauge",
    });
    
    const gauge = try meter.createGauge(f64, .{
        .name = "cpu_usage",
        .description = "CPU usage percentage",
        .unit = "%",
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const gauge_bench = struct {
        gauge: *sdk.Gauge(f64),
        
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx3 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx4 = rng.random().intRangeAtMost(usize, 0, 9);
            
            // Record gauge value of 1 as in Rust benchmark
            self.gauge.record(1.0, .{
                "attr1", ATTR_VALUES[idx1],
                "attr2", ATTR_VALUES[idx2],
                "attr3", ATTR_VALUES[idx3],
                "attr4", ATTR_VALUES[idx4],
            }) catch @panic("gauge record failed");
        }
    }{ .gauge = gauge };
    
    try bench.addParam("Gauge_Add", &gauge_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

// Additional gauge benchmark with realistic CPU usage values
test "Gauge_Record_Realistic_Values" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.gauge.realistic",
    });
    
    const gauge = try meter.createGauge(f64, .{
        .name = "system_metrics",
        .description = "Various system metrics",
        .unit = "ratio",
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const realistic_bench = struct {
        gauge: *sdk.Gauge(f64),
        
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const rng = getThreadRng();
            const idx1 = rng.random().intRangeAtMost(usize, 0, 9);
            const idx2 = rng.random().intRangeAtMost(usize, 0, 9);
            
            // Generate realistic gauge value between 0 and 1
            const value = rng.random().float(f64);
            
            self.gauge.record(value, .{
                "host", ATTR_VALUES[idx1],
                "metric_type", ATTR_VALUES[idx2],
            }) catch @panic("gauge record failed");
        }
    }{ .gauge = gauge };
    
    try bench.addParam("Gauge_Record_Realistic_Values", &realistic_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

// Gauge benchmark with non-static values
test "Gauge_Record_Non_Static_Values" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    
    const meter = try mp.getMeter(.{
        .name = "benchmark.gauge.dynamic",
    });
    
    const gauge = try meter.createGauge(f64, .{
        .name = "dynamic_gauge",
        .description = "Gauge with dynamic attributes",
        .unit = "1",
    });
    
    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    
    const dynamic_bench = struct {
        gauge: *sdk.Gauge(f64),
        
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
            
            self.gauge.record(1.0, .{
                "attr1", val1,
                "attr2", val2,
                "attr3", val3,
                "attr4", val4,
            }) catch @panic("gauge record failed");
        }
    }{ .gauge = gauge };
    
    try bench.addParam("Gauge_Record_Non_Static_Values", &dynamic_bench, .{});
    
    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Gauge_Record_Varied_Values" {
    const mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/benchmark",
    });

    const gauge = try meter.createGauge(f64, .{
        .name = "benchmark_gauge_varied",
        .description = "Gauge for benchmarking varied values",
        .unit = "ratio",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const varied_bench = struct {
        gauge: *sdk.Gauge(f64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const sim_attr: []const u8 = "cpu_usage";
            // Simulate realistic gauge values (e.g., CPU usage)
            const values = [_]f64{ 0.15, 0.35, 0.78, 0.92, 0.65, 0.43, 0.21, 0.88 };
            for (values) |val| {
                self.gauge.record(val, .{ "simulation", sim_attr }) catch @panic("record failed");
            }
        }
    }{ .gauge = gauge };

    try bench.addParam("Gauge_Record_Varied_Values", &varied_bench, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}