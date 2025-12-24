//! Basic Propagation Example
//!
//! This example demonstrates how to use the OpenTelemetry propagation system
//! to inject and extract context (baggage) across service boundaries.
//!
//! The propagation system is configured via the OTEL_PROPAGATORS environment variable.
//!
//! Usage:
//!   OTEL_PROPAGATORS=baggage zig build run-propagation-basic
//!   OTEL_PROPAGATORS=tracecontext,baggage zig build run-propagation-basic
//!   OTEL_PROPAGATORS=none zig build run-propagation-basic

const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== OpenTelemetry Propagation Example ===\n\n", .{});

    // Create a composite propagator from the global configuration
    // This reads OTEL_PROPAGATORS environment variable
    var propagator = try sdk.propagation.createGlobalPropagator(allocator);
    defer propagator.deinit();

    std.debug.print("Propagator initialized from configuration\n", .{});
    std.debug.print("Baggage propagation enabled: {}\n\n", .{propagator.registry.baggage_enabled});

    // Create some baggage to propagate
    var baggage = sdk.api.baggage.Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    try baggage.setValue(allocator, "session_id", "abc-123-def", null);
    try baggage.setValue(allocator, "environment", "production", "priority=high");
    defer baggage.deinit();

    std.debug.print("Created baggage with {} entries\n", .{baggage.count()});

    // Simulate HTTP headers carrier
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    // Inject baggage into headers (simulating outgoing HTTP request)
    try propagator.injectBaggage(baggage, &headers);

    std.debug.print("\n=== Injection (Outgoing Request) ===\n", .{});
    if (headers.get("baggage")) |header_value| {
        std.debug.print("Baggage header: {s}\n", .{header_value});
    } else {
        std.debug.print("No baggage header set (propagation disabled)\n", .{});
    }

    // Extract baggage from headers (simulating incoming HTTP request)
    std.debug.print("\n=== Extraction (Incoming Request) ===\n", .{});
    var extracted_baggage = try propagator.extractBaggage(&headers);

    if (extracted_baggage) |*extracted| {
        defer extracted.deinit();

        std.debug.print("Extracted {} baggage entries:\n", .{extracted.count()});

        if (extracted.getValue("user_id")) |entry| {
            std.debug.print("  user_id = {s}\n", .{entry.value});
        }
        if (extracted.getValue("session_id")) |entry| {
            std.debug.print("  session_id = {s}\n", .{entry.value});
        }
        if (extracted.getValue("environment")) |entry| {
            std.debug.print("  environment = {s}", .{entry.value});
            if (entry.metadata) |metadata| {
                std.debug.print(" (metadata: {s})\n", .{metadata});
            } else {
                std.debug.print("\n", .{});
            }
        }
    } else {
        std.debug.print("No baggage extracted (propagation disabled)\n", .{});
    }

    // List fields that will be read/written by the propagator
    std.debug.print("\n=== Propagator Fields ===\n", .{});
    const field_list = try propagator.fields();
    defer allocator.free(field_list);

    if (field_list.len > 0) {
        std.debug.print("This propagator reads/writes the following headers:\n", .{});
        for (field_list) |field| {
            std.debug.print("  - {s}\n", .{field});
        }
    } else {
        std.debug.print("No fields (all propagators disabled)\n", .{});
    }

    std.debug.print("\n=== Example Complete ===\n", .{});
}
