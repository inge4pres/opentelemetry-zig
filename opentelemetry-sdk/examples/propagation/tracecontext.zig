//! W3C Trace Context Propagation Example
//!
//! This example shows how a service joins a distributed trace:
//! 1. Extract the caller's `traceparent` from the incoming request headers
//! 2. Start a server span as a child of the remote span
//! 3. Inject the server span into the headers of an outgoing request
//!
//! The propagation system is configured via the OTEL_PROPAGATORS environment variable.
//!
//! Usage:
//!   OTEL_PROPAGATORS=tracecontext zig build sdk-run-examples
//!   OTEL_PROPAGATORS=none zig build sdk-run-examples

const std = @import("std");
const clock = @import("clock");

const sdk = @import("opentelemetry-sdk");
const trace = sdk.trace;
const trace_api = sdk.api.trace;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("=== OpenTelemetry W3C Trace Context Example ===\n\n", .{});

    var propagator = try sdk.propagation.createGlobalPropagator(allocator, init.io, init.environ_map);
    defer propagator.deinit();
    // Release the global configuration at exit.
    defer sdk.config.deinitGlobal();

    std.debug.print("Trace context propagation enabled: {}\n\n", .{propagator.registry.tracecontext_enabled});

    var prng = std.Random.DefaultPrng.init(@intCast(clock.milliTimestamp()));
    var tracer_provider = try trace.TracerProvider.init(allocator, init.io, .{
        .Random = trace.RandomIDGenerator.init(prng.random()),
    });
    defer tracer_provider.deinit();

    const tracer = try tracer_provider.getTracer(.{ .name = "tracecontext-example", .version = "1.0.0" });

    // Simulate the headers of a request sent by an upstream service
    var incoming = std.StringHashMap([]const u8).init(allocator);
    defer incoming.deinit();
    try incoming.put("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try incoming.put("tracestate", "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE");

    std.debug.print("=== Extraction (Incoming Request) ===\n", .{});
    std.debug.print("traceparent: {s}\n", .{incoming.get("traceparent").?});
    std.debug.print("tracestate:  {s}\n", .{incoming.get("tracestate").?});

    // The remote SpanContext becomes the parent of the server span. Without a
    // valid traceparent the server span starts a new trace instead.
    var parent_context: ?sdk.api.context.Context = null;
    defer if (parent_context) |ctx| {
        var owned = ctx;
        trace_api.freeSerializedSpanContext(allocator, owned);
        owned.deinit();
    };

    if (try propagator.extractTraceContext(&incoming)) |remote| {
        var trace_state = remote.trace_state;
        defer trace_state.deinit();

        // The server span keeps its own copy of the TraceState, so the parent
        // context only needs to live until startSpan returns
        parent_context = try trace_api.insertSpanContext(allocator, remote);
        std.debug.print("Extracted remote parent span (is_remote={})\n", .{remote.isRemote()});
    } else {
        std.debug.print("No trace context extracted, starting a new trace\n", .{});
    }

    var server_span = try tracer.startSpan(allocator, "GET /api/users", .{
        .kind = .Server,
        .parent_context = parent_context,
    });
    defer server_span.deinit();

    var trace_id_buf: [32]u8 = undefined;
    var span_id_buf: [16]u8 = undefined;
    std.debug.print("\n=== Server Span ===\n", .{});
    std.debug.print("trace_id: {s}\n", .{server_span.span_context.trace_id.toHex(&trace_id_buf)});
    std.debug.print("span_id:  {s}\n", .{server_span.span_context.span_id.toHex(&span_id_buf)});
    if (server_span.parent_span_id) |parent_span_id| {
        std.debug.print("parent:   {s}\n", .{parent_span_id.toHex(&span_id_buf)});
    }

    // Headers of a request sent to a downstream service
    var outgoing = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = outgoing.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        outgoing.deinit();
    }

    try propagator.injectTraceContext(server_span.getContext(), &outgoing);

    std.debug.print("\n=== Injection (Outgoing Request) ===\n", .{});
    if (outgoing.get("traceparent")) |traceparent| {
        std.debug.print("traceparent: {s}\n", .{traceparent});
        if (outgoing.get("tracestate")) |tracestate| {
            std.debug.print("tracestate:  {s}\n", .{tracestate});
        }
    } else {
        std.debug.print("No traceparent set (propagation disabled)\n", .{});
    }

    server_span.end(null);

    std.debug.print("\n=== Example Complete ===\n", .{});
}
