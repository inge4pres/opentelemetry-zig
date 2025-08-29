const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const MeterProvider = sdk.MeterProvider;
const view = sdk.View;
const Kind = sdk.Kind;

/// Histogram Example for OpenTelemetry Zig SDK
///
/// This example demonstrates how to use histogram instruments with different aggregation types:
/// 1. Explicit Bucket Histograms - Uses predefined bucket boundaries
/// 2. Exponential Bucket Histograms - Uses exponentially-sized buckets for wide value ranges
///
/// Histograms are ideal for measuring distributions of values like request durations,
/// response sizes, or any metric where you want to understand the distribution pattern.
pub fn main() !void {
    // Allocate memory for the metrics SDK
    const METRICS_BUFFER_SIZE = 4 * 1024 * 1024; // 4MB buffer for metrics collection
    const buf = try std.heap.page_allocator.alloc(u8, METRICS_BUFFER_SIZE);
    var fba = std.heap.FixedBufferAllocator.init(buf);

    // Create meter provider
    const mp = try MeterProvider.default();
    defer mp.shutdown();

    // Example 1: Histogram with Explicit Bucket Aggregation
    std.debug.print("=== Explicit Bucket Histogram Example ===\n", .{});
    try explicitBucketHistogramExample(fba.allocator(), mp);

    // Example 2: Histogram with Exponential Bucket Aggregation
    std.debug.print("\n=== Exponential Bucket Histogram Example ===\n", .{});
    std.debug.print("Note: Exponential bucket histogram has memory allocation issues in current implementation.\n", .{});
    std.debug.print("Showing the API usage for future reference:\n", .{});

    // Get a meter for the exponential example
    const meter = try mp.getMeter(.{
        .name = "histogram-example",
        .version = "1.0.0",
    });

    // Show the code structure without actually executing it to avoid memory errors
    exponentialBucketHistogramExample(fba.allocator(), mp, meter) catch |err| {
        std.debug.print("Expected error with exponential histogram aggregation: {}\n", .{err});
        std.debug.print("This demonstrates the API structure that will work when the memory issue is resolved.\n", .{});
    };
}

fn explicitBucketHistogramExample(allocator: std.mem.Allocator, mp: *MeterProvider) !void {
    // Create a view for histogram instruments with explicit bucket aggregation
    const histogram_view = view.View{
        .instrument_selector = .{ .kind = .Histogram },
        .aggregation = .{ .ExplicitBucketHistogram = .{
            .buckets = &.{ 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 2.5, 5.0, 10.0 },
        } },
        .temporality = .Cumulative,
    };

    // Register the view with the meter provider
    try mp.addView(histogram_view);

    // Get a meter for creating instruments
    const meter = try mp.getMeter(.{
        .name = "histogram.example.org",
        .version = "1.0.0",
    });

    // Create an in-memory exporter (no aggregation selector needed - views handle this)
    const me = try sdk.MetricExporter.InMemory(allocator, null, null);
    defer me.in_memory.deinit();

    const mr = try sdk.MetricReader.init(allocator, me.exporter);
    defer mr.shutdown();

    // Register the metric reader to the meter provider
    try mp.addReader(mr);

    // Create a histogram with custom explicit bucket boundaries for latency measurements
    const response_time_histogram = try meter.createHistogram(f64, .{
        .name = "http_request_duration_seconds",
        .description = "HTTP request duration in seconds",
        .unit = "s",
    });

    // Record some sample HTTP request durations
    std.debug.print("Recording HTTP request durations...\n", .{});

    // Fast requests
    try response_time_histogram.record(0.003, .{ "method", @as([]const u8, "GET"), "status", @as([]const u8, "200") });
    try response_time_histogram.record(0.025, .{ "method", @as([]const u8, "GET"), "status", @as([]const u8, "200") });

    // Slow request
    try response_time_histogram.record(1.2, .{ "method", @as([]const u8, "GET"), "status", @as([]const u8, "500") });

    // Collect the metrics
    try mr.collect();

    // Fetch and display the metrics
    const stored_metrics = try me.in_memory.fetch(allocator);
    defer allocator.free(stored_metrics);

    std.debug.print("Collected {} histogram measurements\n", .{stored_metrics.len});

    for (stored_metrics) |metric| {
        if (std.mem.eql(u8, metric.instrumentOptions.name, "http_request_duration_seconds")) {
            std.debug.print("Histogram: {s}\n", .{metric.instrumentOptions.name});
            std.debug.print("Description: {s}\n", .{metric.instrumentOptions.description.?});

            switch (metric.data) {
                .histogram => |histograms| {
                    for (histograms) |dp| {
                        std.debug.print("  Count: {}, Sum: {d:.3}, Min: {d:.3}, Max: {d:.3}\n", .{
                            dp.value.count,
                            dp.value.sum.?,
                            dp.value.min.?,
                            dp.value.max.?,
                        });

                        std.debug.print("  Bucket counts: ", .{});
                        for (dp.value.bucket_counts) |count| {
                            std.debug.print("{} ", .{count});
                        }
                        std.debug.print("\n", .{});

                        if (dp.attributes) |attrs| {
                            std.debug.print("  Attributes: ", .{});
                            for (attrs) |attr| {
                                switch (attr.value) {
                                    .string => |s| std.debug.print("{s}={s} ", .{ attr.key, s }),
                                    else => std.debug.print("{s}={any} ", .{ attr.key, attr.value }),
                                }
                            }
                            std.debug.print("\n", .{});
                        }
                        std.debug.print("\n", .{});
                    }
                },
                else => std.debug.print("  Unexpected data type for histogram\n", .{}),
            }
        }
    }
}

fn exponentialBucketHistogramExample(_: std.mem.Allocator, mp: *MeterProvider, meter: anytype) !void {
    // NOTE: Exponential bucket histogram aggregation is currently experiencing memory issues
    // in this SDK implementation due to allocator usage in ExponentialHistogramState.
    // This example demonstrates the API but does not actually collect data to avoid crashes.

    std.debug.print("=== API Usage Demonstration ===\n", .{});

    // Create a view for histogram instruments with exponential bucket aggregation
    const exponential_view = view.View{
        .instrument_selector = .{ .kind = .Histogram, .name = "memory_usage_bytes_exp" },
        .aggregation = .{ .ExponentialBucketHistogram = .{} },
        .temporality = .Cumulative,
    };

    // Register the view with the meter provider
    try mp.addView(exponential_view);

    // Create a histogram for memory usage measurements (exponential buckets work well for memory data)
    const memory_usage_histogram = try meter.createHistogram(u32, .{
        .name = "memory_usage_bytes_exp", // Different name to avoid conflicts
        .description = "Memory usage in bytes (exponential buckets)",
        .unit = "bytes",
    });

    // Record some sample memory usage values (in bytes)
    std.debug.print("API allows recording memory usage measurements like:\n", .{});
    std.debug.print("  memory_usage_histogram.record(1024, .{{ \"component\", \"cache\" }});\n", .{});
    std.debug.print("  memory_usage_histogram.record(65536, .{{ \"component\", \"database\" }});\n", .{});
    std.debug.print("  memory_usage_histogram.record(1048576, .{{ \"component\", \"cache\" }});\n", .{});

    // Actually record the values (this works fine)
    try memory_usage_histogram.record(1024, .{ "component", @as([]const u8, "cache") });
    try memory_usage_histogram.record(65536, .{ "component", @as([]const u8, "database") });
    try memory_usage_histogram.record(1048576, .{ "component", @as([]const u8, "cache") });

    std.debug.print("Values recorded successfully. Collection would produce exponential histogram data.\n", .{});
    std.debug.print("(Skipping actual collection due to current memory allocation issue)\n", .{});

    // Note: We don't register the reader with the meter provider or collect data
    // because that's where the memory error occurs. The API usage above is correct.
}
