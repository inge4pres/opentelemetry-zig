const std = @import("std");
const benchmark = @import("benchmark");

const metrics = @import("opentelemetry-sdk").metrics;

const MetricReader = metrics.MetricReader;
const MeterProvider = metrics.MeterProvider;
const InMemory = metrics.InMemoryExporter;
const MetricExporter = metrics.MetricExporter;

const ReaderBench = struct {
    reader: *MetricReader,

    fn generateMetrics(provider: *MeterProvider, how_many: u64) !void {
        const meter = try provider.getMeter(.{
            .name = "benchmark.reader",
        });

        const counter = try meter.createCounter(u64, .{
            .name = "reader_counter",
            .description = "Counter for reader benchmark",
        });

        // Record some values
        for (0..how_many) |i| {
            try counter.add(i, .{ "index", i });
        }
    }

    fn init(reader: *MetricReader, provider: *MeterProvider, how_many: usize) !@This() {
        generateMetrics(provider, how_many) catch @panic("generate metrics failed");
        return ReaderBench{ .reader = reader };
    }

    pub fn run(self: @This(), _: std.mem.Allocator) void {
        self.reader.collect() catch |err| {
            std.debug.print("error during collect: {}", .{err});
            @panic("MetricReader collect failed");
        };
    }
};

test "MetricReader_collect" {
    var mp = try MeterProvider.init(std.testing.allocator);
    defer mp.shutdown();

    var me = try MetricExporter.InMemory(std.testing.allocator, null, null);
    defer me.in_memory.deinit();

    const n10k = 10000;

    var reader = try MetricReader.init(std.testing.allocator, me.exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    const under_test = ReaderBench.init(reader, mp, n10k) catch |err| {
        std.debug.print("Failed to initialize ReaderBench: {}\n", .{err});
        return;
    };

    var bench = benchmark.Benchmark.init(std.testing.allocator, .{
        .max_iterations = 10000,
        .time_budget_ns = 5 * std.time.ns_per_s,
        .track_allocations = true,
    });
    defer bench.deinit();

    try bench.addParam("MetricReader_collect_100k_datapoints", &under_test, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();

    const data = try me.in_memory.fetch(std.testing.allocator);
    defer std.testing.allocator.free(data);
    for (data) |*record| {
        record.deinit(std.testing.allocator);
    }

    try std.testing.expect(data.len == 1);
    try std.testing.expect(data[0].data.int.len == n10k);
}
