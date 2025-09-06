const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaks detected");

    const allocator = gpa.allocator();

    // Initialize tracer provider with proper resource management
    var tracer_provider = try sdk.api.trace.TracerProvider.default();
    defer tracer_provider.shutdown();

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

    std.debug.print("Tracer instances - Same instance returned: {}\n", .{user_tracer == user_tracer_2});

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

    std.debug.print("Multiple tracers example completed successfully!\n", .{});
    std.debug.print("- User service tracer: {} (version 1.0.0)\n", .{user_tracer});
    std.debug.print("- Payment service tracer: {} (version 2.1.0)\n", .{payment_tracer});
    std.debug.print("- Database service tracer: {} (version 1.5.0)\n", .{database_tracer});
}
