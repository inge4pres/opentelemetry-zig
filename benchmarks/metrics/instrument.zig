const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;

const benchmark = @import("benchmark");

// We need to use stderr instead of stdout because stdout is used by the build.
const bench_output = std.io.getStdErr().writer();

const std_bench_opts = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 5 * std.time.ns_per_s,
    .track_allocations = true,
};

fn setupSDK(allocator: std.mem.Allocator) !*sdk.MeterProvider {
    const mp = try MeterProvider.init(allocator);
    errdefer mp.shutdown();

    return mp;
}

test "benchmark metrics instruments" {
    const mp = try setupSDK(std.testing.allocator);
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/sample",
    });

    var counter = try meter.createCounter(u64, .{
        .name = "sample_counter",
    });
    _ = &counter;

    var bench = benchmark.Benchmark.init(std.testing.allocator, std_bench_opts);
    defer bench.deinit();

    // Counter
    const cb = CounterBenchmarks{ .counter = counter };
    try bench.addParam("counter.add w/o attrs", &cb.withoutAttributes(), .{ .track_allocations = false });
    try bench.addParam("counter.add with attrs", &cb.withAttributes(), .{ .track_allocations = false });
    try bench.addParam("counter.add concurrent", &cb.concurrent(), .{ .track_allocations = false });

    // Histogram (we want to track allocations)
    try bench.add("hist.record w/o attrs", HistogramBenchmarks.WithoutAttributes.run, .{ .track_allocations = true });
    try bench.add("hist.record with attrs", HistogramBenchmarks.WithAttributes.run, .{ .track_allocations = true });
    try bench.add("hist.record concurrent", HistogramBenchmarks.ConcurrentRecord.run, .{ .track_allocations = true });

    try bench.run(bench_output);
}

const CounterBenchmarks = struct {
    counter: *sdk.Counter(u64),

    fn withAttributes(self: @This()) WithAttributes {
        return WithAttributes{ .counter = self.counter };
    }

    const WithAttributes = struct {
        counter: *sdk.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const attr1: []const u8 = "some-val";
            const attr2: []const u8 = "some-other-val";
            self.counter.add(1, .{
                "attribute_one",
                attr1,
                "attribute_two",
                attr2,
            }) catch @panic("benchmark failed");
        }
    };

    fn withoutAttributes(self: @This()) WithoutAttributes {
        return WithoutAttributes{ .counter = self.counter };
    }

    const WithoutAttributes = struct {
        counter: *sdk.Counter(u64),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.counter.add(1, .{}) catch @panic("benchmark failed");
        }
    };

    fn concurrent(self: @This()) ConcurrentAdd {
        return ConcurrentAdd{ .counter = self.counter };
    }

    const ConcurrentAdd = struct {
        counter: *sdk.Counter(u64),
        const attr1: []const u8 = "some-val";
        const attr2: []const u8 = "some-other-val";

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const t1 = std.Thread.spawn(.{}, add, .{ self.counter, .{
                "attribute_one",
                attr1,
                "attribute_two",
                attr2,
            } }) catch @panic("spawn failed");
            const t2 = std.Thread.spawn(.{}, add, .{ self.counter, .{} }) catch @panic("spawn failed");
            t1.join();
            t2.join();
        }

        fn add(counter: *sdk.Counter(u64), attributes: anytype) void {
            counter.add(1, attributes) catch @panic("add failed");
        }
    };
};

const HistogramBenchmarks = struct {
    const WithAttributes = struct {
        const attr1: []const u8 = "some-val";
        const attr2: []const u8 = "some-other-val";
        pub fn run(allocator: std.mem.Allocator) void {
            const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
            const meter = provider.getMeter(.{
                .name = "histogram-with-attrs",
            }) catch @panic("failed to get meter");
            const histogram = meter.createHistogram(u64, .{
                .name = "sample_histogram",
            }) catch @panic("failed to create histogram");

            histogram.record(1, .{
                "attribute_one",
                attr1,
                "attribute_two",
                attr2,
            }) catch @panic("benchmark failed");
        }
    };

    const WithoutAttributes = struct {
        pub fn run(allocator: std.mem.Allocator) void {
            const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
            const meter = provider.getMeter(.{
                .name = "test.company.org/sample",
            }) catch @panic("failed to get meter");
            const histogram = meter.createHistogram(u64, .{
                .name = "sample_histogram",
            }) catch @panic("failed to create histogram");

            histogram.record(1, .{}) catch @panic("benchmark failed");
        }
    };

    const ConcurrentRecord = struct {
        const attr1: []const u8 = "some-val";
        const attr2: []const u8 = "some-other-val";

        pub fn run(allocator: std.mem.Allocator) void {
            const provider = sdk.MeterProvider.init(allocator) catch @panic("failed to create meter provider");
            const meter = provider.getMeter(.{
                .name = "test.company.org/sample",
            }) catch @panic("failed to get meter");
            const histogram = meter.createHistogram(u64, .{
                .name = "sample_histogram",
            }) catch @panic("failed to create histogram");

            const t1 = std.Thread.spawn(.{}, record, .{ histogram, .{
                "attribute_one",
                attr1,
                "attribute_two",
                attr2,
            } }) catch @panic("spawn failed");
            const t2 = std.Thread.spawn(.{}, record, .{ histogram, .{} }) catch @panic("spawn failed");
            t1.join();
            t2.join();
        }

        fn record(histogram: *sdk.Histogram(u64), attributes: anytype) void {
            histogram.record(1, attributes) catch @panic("add failed");
        }
    };
};
