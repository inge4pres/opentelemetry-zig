const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;

pub fn main() !void {
    // Use the builtin meter provider
    const mp = try MeterProvider.default();
    defer mp.shutdown();
    const meter = try mp.getMeter(.{
        .name = "test.company.org/sample",
    });

    // Allocate a maximum of 4MiB of memory for the metrics sdk
    const buf = try std.heap.page_allocator.alloc(u8, 4 << 20);
    var fba = std.heap.FixedBufferAllocator.init(buf);

    // Declare an in-memory exporter
    var in_mem = try sdk.InMemoryExporter.init(fba.allocator());

    // Create an exporter and a a metric reader to aggregate the metrics
    const exporter = try sdk.MetricExporter.new(fba.allocator(), &in_mem.exporter);
    const mr = try sdk.MetricReader.init(fba.allocator(), exporter);
    defer mr.shutdown();

    // Register the metric reader to the meter provider
    try mp.addReader(mr);

    const sample_counter = try meter.createCounter(u16, .{
        .name = "cumulative_sum",
        .description = "sum of integers",
    });
    for (1..5) |d| {
        try sample_counter.add(@intCast(d), .{});
    }

    // Collect the metrics from the reader.
    // This is just an exmple, normally collection would happen in the background,
    // by using more sophisticated readers.
    try mr.collect();

    // Print the metrics
    const stored_metrics = try in_mem.fetch();
    defer stored_metrics.deinit();

    std.debug.print("metric: {any}\n", .{stored_metrics});
}
