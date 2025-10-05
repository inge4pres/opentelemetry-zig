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

// Helper function to create meter provider and meter
fn setupMeter(allocator: std.mem.Allocator) !*MeterProvider {
    const provider = try MeterProvider.init(allocator);
    return provider;
}

// Counter benchmarks with varying attribute counts
test "AddNoAttrs" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const no_attrs = struct {
        counter: *metrics.Counter(u64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.counter.add(1, .{}) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddNoAttrs", &no_attrs, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "AddOneAttr" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const one_attr = struct {
        counter: *metrics.Counter(u64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const val1: []const u8 = "value1";
            self.counter.add(1, .{
                "key1", val1,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddOneAttr", &one_attr, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "AddThreeAttr" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const three_attr = struct {
        counter: *metrics.Counter(u64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const val1: []const u8 = "value1";
            const val2: []const u8 = "value2";
            const val3: []const u8 = "value3";
            self.counter.add(1, .{
                "key1", val1,
                "key2", val2,
                "key3", val3,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddThreeAttr", &three_attr, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "AddFiveAttr" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const five_attr = struct {
        counter: *metrics.Counter(u64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const val1: []const u8 = "value1";
            const val2: []const u8 = "value2";
            const val3: []const u8 = "value3";
            const val4: []const u8 = "value4";
            const val5: []const u8 = "value5";
            self.counter.add(1, .{
                "key1", val1,
                "key2", val2,
                "key3", val3,
                "key4", val4,
                "key5", val5,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddFiveAttr", &five_attr, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "AddTenAttr" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const ten_attr = struct {
        counter: *metrics.Counter(u64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const val01: []const u8 = "value01";
            const val02: []const u8 = "value02";
            const val03: []const u8 = "value03";
            const val04: []const u8 = "value04";
            const val05: []const u8 = "value05";
            const val06: []const u8 = "value06";
            const val07: []const u8 = "value07";
            const val08: []const u8 = "value08";
            const val09: []const u8 = "value09";
            const val10: []const u8 = "value10";
            self.counter.add(1, .{
                "key01", val01,
                "key02", val02,
                "key03", val03,
                "key04", val04,
                "key05", val05,
                "key06", val06,
                "key07", val07,
                "key08", val08,
                "key09", val09,
                "key10", val10,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddTenAttr", &ten_attr, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

// Histogram benchmarks with varying bucket counts
test "RecordHistogram10Bounds" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();

    // Add a view with custom explicit buckets for the histogram
    try provider.addView(metrics.View.View{
        .instrument_selector = metrics.View.InstrumentSelector{
            .name = "test_histogram",
        },
        .aggregation = .{ .ExplicitBucketHistogram = .{
            .buckets = &[_]f64{ 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0 },
        } },
        .temporality = .Cumulative,
    });

    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const histogram = try meter.createHistogram(f64, .{
        .name = "test_histogram",
        .unit = "ms",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const hist_bench = struct {
        histogram: *metrics.Histogram(f64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const status: []const u8 = "ok";
            const method: []const u8 = "GET";
            self.histogram.record(25.0, .{
                "status", status,
                "method", method,
            }) catch @panic("histogram record failed");
        }
    }{ .histogram = histogram };

    try bench.addParam("RecordHistogram10Bounds", &hist_bench, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "RecordHistogram50Bounds" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();

    // Create 50 bucket boundaries
    var buckets: [50]f64 = undefined;
    for (&buckets, 0..) |*bucket, i| {
        bucket.* = @as(f64, @floatFromInt(i)) * 2.0;
    }

    // Add a view with 50 custom explicit buckets for the histogram
    try provider.addView(metrics.View.View{
        .instrument_selector = metrics.View.InstrumentSelector{
            .name = "test_histogram_50",
        },
        .aggregation = .{ .ExplicitBucketHistogram = .{
            .buckets = &buckets,
        } },
        .temporality = .Cumulative,
    });

    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const histogram = try meter.createHistogram(f64, .{
        .name = "test_histogram_50",
        .unit = "ms",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const hist_bench = struct {
        histogram: *metrics.Histogram(f64),
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const status: []const u8 = "ok";
            const method: []const u8 = "GET";
            self.histogram.record(25.0, .{
                "status", status,
                "method", method,
            }) catch @panic("histogram record failed");
        }
    }{ .histogram = histogram };

    try bench.addParam("RecordHistogram50Bounds", &hist_bench, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

// Benchmark for single-use attributes
test "AddSingleUseAttrs" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const counter = try meter.createCounter(u64, .{
        .name = "test_counter",
        .unit = "1",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const single_use = struct {
        counter: *metrics.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Use timestamp to create unique attribute value for each iteration
            const ts = std.time.timestamp();

            // Create unique attribute value for each iteration
            var buf: [32]u8 = undefined;
            const unique_value = std.fmt.bufPrint(&buf, "iteration_{}", .{ts}) catch @panic("fmt failed");

            self.counter.add(1, .{
                "unique_key", unique_value,
            }) catch @panic("counter add failed");
        }
    }{ .counter = counter };

    try bench.addParam("AddSingleUseAttrs", &single_use, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

// Gauge benchmark with varying values
test "GaugeRecordVaried" {
    const provider = try setupMeter(std.testing.allocator);
    defer provider.shutdown();
    const meter = try provider.getMeter(.{
        .name = "benchmark.general",
    });

    const gauge = try meter.createGauge(f64, .{
        .name = "test_gauge",
        .unit = "%",
    });

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    const gauge_varied = struct {
        gauge: *metrics.Gauge(f64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Simulate CPU usage between 0% and 100%
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
            const value = rng.random().float(f64) * 100.0;

            const cpu: []const u8 = "cpu0";
            const host: []const u8 = "localhost";
            self.gauge.record(value, .{
                "cpu",  cpu,
                "host", host,
            }) catch @panic("gauge record failed");
        }
    }{ .gauge = gauge };

    try bench.addParam("GaugeRecordVaried", &gauge_varied, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}
