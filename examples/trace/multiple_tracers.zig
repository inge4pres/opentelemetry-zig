const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const trace = sdk.trace;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaks detected");

    const allocator = gpa.allocator();

    // Create SDK components for realistic tracing

    // 1. Create an ID generator for trace and span IDs
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const id_generator = trace.IDGenerator{
        .Random = trace.RandomIDGenerator.init(prng.random()),
    };

    // 2. Create a tracer provider with the ID generator
    var tracer_provider = try trace.SDKTracerProvider.init(allocator, id_generator);
    defer tracer_provider.shutdown();

    // 3. Create a stdout exporter and simple processor for output
    var stdout_exporter = trace.StdOutExporter.init(std.io.getStdOut().writer());
    var simple_processor = trace.SimpleProcessor.init(allocator, stdout_exporter.asSpanExporter());

    // 4. Add the processor to the provider
    try tracer_provider.addSpanProcessor(simple_processor.asSpanProcessor());

    // Create multiple tracers for different services
    const user_tracer = try tracer_provider.getTracer(.{
        .name = "user-service",
        .version = "1.0.0",
    });

    const payment_tracer = try tracer_provider.getTracer(.{
        .name = "payment-service",
        .version = "2.1.0",
    });

    const database_tracer = try tracer_provider.getTracer(.{
        .name = "database-service",
        .version = "1.5.0",
    });

    // Verify that the same tracer is returned for the same name/version
    const user_tracer_2 = try tracer_provider.getTracer(.{
        .name = "user-service",
        .version = "1.0.0",
    });

    // Verify SDK returns the same tracer instance for identical name/version
    std.debug.assert(user_tracer == user_tracer_2);

    // Create spans with different tracers to simulate different services
    const user_attributes = try sdk.Attributes.from(allocator, .{
        "user_id",   @as([]const u8, "user123"),
        "operation", @as([]const u8, "login"),
    });
    defer allocator.free(user_attributes.?);

    var user_span = try user_tracer.startSpan(allocator, "user-login", .{
        .attributes = user_attributes,
    });
    defer user_span.deinit();

    const payment_attributes = try sdk.Attributes.from(allocator, .{
        "payment_id", @as([]const u8, "pay456"),
        "amount",     @as(f64, 99.99),
        "currency",   @as([]const u8, "USD"),
    });
    defer allocator.free(payment_attributes.?);

    var payment_span = try payment_tracer.startSpan(allocator, "payment-process", .{
        .attributes = payment_attributes,
    });
    defer payment_span.deinit();

    const db_attributes = try sdk.Attributes.from(allocator, .{
        "query", @as([]const u8, "SELECT * FROM users WHERE id = ?"),
        "table", @as([]const u8, "users"),
    });
    defer allocator.free(db_attributes.?);

    var db_span = try database_tracer.startSpan(allocator, "database-query", .{
        .attributes = db_attributes,
    });
    defer db_span.deinit();

    // Add events to spans
    const event_attributes = try sdk.Attributes.from(allocator, .{
        "event_type", @as([]const u8, "authentication"),
        "status",     @as([]const u8, "success"),
    });
    defer allocator.free(event_attributes.?);

    try user_span.addEvent("Authentication completed", null, event_attributes);

    try payment_span.addEvent("Payment authorized", null, null);
    try db_span.addEvent("Query executed successfully", null, null);

    // End spans using SDK tracer method for proper processing
    user_tracer.endSpan(&user_span);
    payment_tracer.endSpan(&payment_span);
    database_tracer.endSpan(&db_span);
}
