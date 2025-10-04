const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const trace = sdk.trace;
const trace_api = sdk.api.trace;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaks detected");
    const allocator = gpa.allocator();

    // Create SDK components for a realistic trace setup

    // 1. Create an ID generator for trace and span IDs
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const id_generator = trace.IDGenerator{
        .Random = trace.RandomIDGenerator.init(prng.random()),
    };

    // 2. Create a tracer provider with the ID generator
    var tracer_provider = try trace.TracerProvider.init(allocator, id_generator);
    defer tracer_provider.shutdown();

    // 3. Create a stdout exporter and simple processor
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_exporter = trace.StdOutExporter.init(std.fs.File.stdout().writer(&stdout_buffer));
    var simple_processor = trace.SimpleProcessor.init(allocator, stdout_exporter.asSpanExporter());

    // 4. Add the processor to the provider
    try tracer_provider.addSpanProcessor(simple_processor.asSpanProcessor());

    // 5. Get tracers from the SDK provider with different instrumentation scopes (via interface)
    const http_tracer = try tracer_provider.getTracer(.{
        .name = "http-client",
        .version = "1.2.3",
        .schema_url = "https://opentelemetry.io/schemas/1.21.0",
    });

    const db_tracer = try tracer_provider.getTracer(.{
        .name = "database-driver",
        .version = "2.1.0",
    });

    // Create attributes for HTTP span
    const http_span_attributes = try sdk.Attributes.from(allocator, .{
        "http.method",      @as([]const u8, "GET"),
        "http.url",         @as([]const u8, "/api/users"),
        "http.status_code", @as(i64, 200),
    });
    defer allocator.free(http_span_attributes.?);

    // Create and start an HTTP span
    var http_span = try http_tracer.startSpan(allocator, "GET /api/users", .{
        .kind = .Server,
        .attributes = http_span_attributes,
    });
    defer http_span.deinit();

    // Create attributes for DB span
    const db_span_attributes = try sdk.Attributes.from(allocator, .{
        "db.system",    @as([]const u8, "postgresql"),
        "db.operation", @as([]const u8, "select"),
        "db.table",     @as([]const u8, "users"),
    });
    defer allocator.free(db_span_attributes.?);

    // Create and start a DB span as a child of the HTTP span
    var db_span = try db_tracer.startSpan(allocator, "SELECT * FROM users", .{
        .kind = .Client,
        .attributes = db_span_attributes,
        // TODO: In a full implementation, we would set parent_context here
        // to make this span a child of the HTTP span
    });
    defer db_span.deinit();

    // Create attributes for the event
    const event_attributes = try sdk.Attributes.from(allocator, .{
        "event.name", @as([]const u8, "user_lookup"),
    });
    defer allocator.free(event_attributes.?);

    // Add an event to the HTTP span
    try http_span.addEvent("Looking up user data", null, event_attributes);

    // Set span statuses
    http_span.setStatus(trace_api.Status.ok());
    db_span.setStatus(trace_api.Status.ok());

    // Set additional attributes
    try http_span.setAttribute("user.id", .{ .string = "user123" });
    try db_span.setAttribute("db.rows_affected", .{ .int = 1 });

    // Simulate some work
    std.Thread.sleep(50 * std.time.ns_per_ms); // DB query time

    // End the DB span first (child spans should end before parent)
    db_span.end(null);

    std.Thread.sleep(50 * std.time.ns_per_ms); // HTTP processing time

    // End the HTTP span
    http_span.end(null);

    // Verify spans were created successfully with valid IDs (not all zeros)
    const zero_trace_id = [_]u8{0} ** 16;
    const zero_span_id = [_]u8{0} ** 8;
    std.debug.assert(!std.mem.eql(u8, &http_span.span_context.trace_id.value, &zero_trace_id));
    std.debug.assert(!std.mem.eql(u8, &http_span.span_context.span_id.value, &zero_span_id));
    std.debug.assert(!std.mem.eql(u8, &db_span.span_context.trace_id.value, &zero_trace_id));
    std.debug.assert(!std.mem.eql(u8, &db_span.span_context.span_id.value, &zero_span_id));
}
