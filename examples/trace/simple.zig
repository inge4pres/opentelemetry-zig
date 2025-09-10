const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaks detected");
    const allocator = gpa.allocator();

    // Create SDK components for a realistic trace setup

    // 1. Create an ID generator for trace and span IDs
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const id_generator = sdk.trace.IDGenerator{
        .Random = sdk.trace.RandomIDGenerator.init(prng.random()),
    };

    // 2. Create a tracer provider with the ID generator
    var tracer_provider = try sdk.trace.TracerProvider.init(allocator, id_generator);
    defer tracer_provider.shutdown();

    // 3. Create a stdout exporter and simple processor
    var stdout_exporter = sdk.trace.StdoutExporter.init(std.io.getStdOut().writer());
    var simple_processor = sdk.trace.SimpleProcessor.init(allocator, stdout_exporter.asSpanExporter());

    // 4. Add the processor to the provider
    try tracer_provider.addSpanProcessor(simple_processor.asSpanProcessor());

    // 5. Get a tracer from the SDK provider
    const tracer = try tracer_provider.getTracer(.{ .name = "example-tracer", .version = "1.0.0" });

    // Create attributes for the span
    const span_attributes = try sdk.Attributes.from(allocator, .{
        "http.method",      @as([]const u8, "GET"),
        "http.status_code", @as(i64, 200),
    });
    defer allocator.free(span_attributes.?);

    // Create and start a span
    var span = try tracer.startSpan(allocator, "example-operation", .{
        .kind = .Server,
        .attributes = span_attributes,
    });
    defer span.deinit();

    // Create attributes for the event
    const event_attributes = try sdk.Attributes.from(allocator, .{
        "event.name", @as([]const u8, "processing"),
    });
    defer allocator.free(event_attributes.?);

    // Add an event
    try span.addEvent("Processing request", null, event_attributes);

    // Set span status
    span.setStatus(sdk.api.trace.Status.ok());

    // Set additional attributes using setAttribute (which takes AttributeValue)
    try span.setAttribute("user.id", .{ .string = "user123" });

    // Simulate some work
    std.time.sleep(100 * std.time.ns_per_ms);

    // End the span explicitly by calling the tracer's endSpan method
    tracer.endSpan(&span);

    std.debug.print("Span created and finished successfully using SDK!\n", .{});
    std.debug.print("Trace ID: {any}\n", .{span.span_context.trace_id.value});
    std.debug.print("Span ID: {any}\n", .{span.span_context.span_id.value});
}
