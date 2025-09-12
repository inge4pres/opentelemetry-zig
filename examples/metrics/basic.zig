const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const metrics_sdk = sdk.metrics;
const MeterProvider = metrics_sdk.MeterProvider;

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
    const me = try metrics_sdk.MetricExporter.InMemory(fba.allocator(), null, null);
    defer me.in_memory.deinit();

    // Create an exporter and a a metric reader to aggregate the metrics
    const mr = try metrics_sdk.MetricReader.init(fba.allocator(), me.exporter);
    defer mr.shutdown();

    // Register the metric reader to the meter provider
    try mp.addReader(mr);

    const sample_counter = try meter.createCounter(u16, .{
        .name = "cumulative_sum",
        .description = "sum of integers",
    });
    for (1..5) |d| {
        try sample_counter.add(@intCast(d), .{ "value", @as(u64, d) });
    }

    // Collect the metrics from the reader.
    // This is just an exmple, normally collection would happen in the background,
    // by using more sophisticated readers.
    try mr.collect();

    // Print the metrics
    const stored_metrics = try me.in_memory.fetch(fba.allocator());
    defer fba.allocator().free(stored_metrics);

    // Only 1 instrument collected measurments
    try std.testing.expectEqual(1, stored_metrics.len);
    const metric = stored_metrics[0];
    // Each metric is stored independently because the attribute is different,
    // beware of cardinality!
    try std.testing.expectEqual(4, metric.data.int.len);
    std.debug.assert(metric.data.int[0].attributes != null);
    std.debug.assert(metric.data.int[0].attributes.?.len == 1);
}
