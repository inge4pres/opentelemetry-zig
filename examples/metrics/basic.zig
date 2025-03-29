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

    const metric_exporter = try sdk.MetricExporter.new(fba.allocator(), &in_mem.exporter);

    // Create an exporter and a a metric reader to aggregate the metrics
    const mr = try sdk.MetricReader.init(fba.allocator(), metric_exporter);
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
    const stored_metrics = try in_mem.fetch(fba.allocator());
    defer fba.allocator().free(stored_metrics);

    std.debug.assert(stored_metrics.len == 1);
    const metric = stored_metrics[0];
    std.debug.assert(metric.data.int[0].attributes == null);
}
