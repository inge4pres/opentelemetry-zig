//! Baggage Propagation example
//!
//! This example demonstrates how to:
//! - Inject baggage into HTTP headers (W3C format)
//! - Extract baggage from HTTP headers
//! - Simulate cross-service propagation
//! - Use environment variable propagation

const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== OpenTelemetry Baggage Propagation Example ===\n\n", .{});

    // Create baggage with multiple entries
    var baggage = sdk.api.baggage.Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    try baggage.setValue(allocator, "session_id", "abc-123", "secure=true");
    try baggage.setValue(allocator, "region", "us-west", null);
    defer baggage.deinit();

    std.debug.print("--- Original Baggage ---\n", .{});
    var it = baggage.iterator();
    while (it.next()) |entry| {
        std.debug.print("  {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.value });
    }

    // Simulate HTTP propagation
    std.debug.print("\n--- HTTP Header Propagation ---\n", .{});

    // Create HTTP headers map
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    // Inject baggage into headers
    try sdk.api.baggage.propagator.inject(
        allocator,
        baggage,
        &headers,
        sdk.api.baggage.propagator.HttpSetter,
    );

    // Print the baggage header
    if (headers.get("baggage")) |baggage_header| {
        std.debug.print("Baggage HTTP header:\n  {s}\n", .{baggage_header});
    }

    // Simulate receiving the headers in another service
    std.debug.print("\n--- Extracting from HTTP Headers ---\n", .{});

    var extracted_baggage = try sdk.api.baggage.propagator.extract(
        allocator,
        &headers,
        sdk.api.baggage.propagator.HttpGetter,
    );

    if (extracted_baggage) |*extracted| {
        defer extracted.deinit();

        std.debug.print("Extracted baggage:\n", .{});
        var extracted_it = extracted.iterator();
        while (extracted_it.next()) |entry| {
            const metadata_str = if (entry.value_ptr.metadata) |meta| meta else "(none)";
            std.debug.print("  {s} = {s} [metadata: {s}]\n", .{
                entry.key_ptr.*,
                entry.value_ptr.value,
                metadata_str,
            });
        }

        // Verify all values were preserved
        std.debug.print("\nVerification:\n", .{});
        std.debug.print("  user_id matches: {}\n", .{
            std.mem.eql(u8, extracted.getValue("user_id").?.value, "alice"),
        });
        std.debug.print("  session_id matches: {}\n", .{
            std.mem.eql(u8, extracted.getValue("session_id").?.value, "abc-123"),
        });
        std.debug.print("  region matches: {}\n", .{
            std.mem.eql(u8, extracted.getValue("region").?.value, "us-west"),
        });
    }

    // Demonstrate special character handling
    std.debug.print("\n--- Special Characters in Baggage ---\n", .{});

    var special_baggage = sdk.api.baggage.Baggage.init();
    try special_baggage.setValue(allocator, "user email", "alice@example.com", null);
    defer special_baggage.deinit();

    var special_headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = special_headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        special_headers.deinit();
    }

    try sdk.api.baggage.propagator.inject(
        allocator,
        special_baggage,
        &special_headers,
        sdk.api.baggage.propagator.HttpSetter,
    );

    if (special_headers.get("baggage")) |header| {
        std.debug.print("Encoded header: {s}\n", .{header});
    }

    var extracted_special = try sdk.api.baggage.propagator.extract(
        allocator,
        &special_headers,
        sdk.api.baggage.propagator.HttpGetter,
    );

    if (extracted_special) |*extracted| {
        defer extracted.deinit();
        const value = extracted.getValue("user email").?.value;
        std.debug.print("Decoded value: {s}\n", .{value});
        std.debug.print("Characters preserved: {}\n", .{
            std.mem.eql(u8, value, "alice@example.com"),
        });
    }

    std.debug.print("\nPropagation example completed successfully!\n", .{});
}
