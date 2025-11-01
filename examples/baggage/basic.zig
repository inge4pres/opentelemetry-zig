//! Basic Baggage usage example
//!
//! This example demonstrates how to:
//! - Create baggage with key-value pairs
//! - Add entries with and without metadata
//! - Retrieve values from baggage
//! - Use baggage with Context for propagation

const std = @import("std");
const sdk = @import("opentelemetry-sdk");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== OpenTelemetry Baggage Example ===\n\n", .{});

    // Create empty baggage
    var baggage = sdk.api.baggage.Baggage.init();
    defer baggage.deinit();

    // Add a user ID to baggage
    std.debug.print("Adding user_id to baggage...\n", .{});
    try baggage.setValue(allocator, "user_id", "alice", null);

    // Add an account ID with metadata
    std.debug.print("Adding account_id with metadata...\n", .{});
    try baggage.setValue(allocator, "account_id", "12345", "priority=high");

    // Add a feature flag
    std.debug.print("Adding feature flag...\n", .{});
    try baggage.setValue(allocator, "feature.new_ui", "enabled", null);

    std.debug.print("\n--- Baggage Contents ---\n", .{});

    // Retrieve and print all baggage entries
    var it = baggage.iterator();
    while (it.next()) |entry| {
        const metadata_str = if (entry.value_ptr.metadata) |meta| meta else "(no metadata)";
        std.debug.print("  {s} = {s} [{s}]\n", .{
            entry.key_ptr.*,
            entry.value_ptr.value,
            metadata_str,
        });
    }

    // Retrieve specific values
    std.debug.print("\n--- Retrieving Specific Values ---\n", .{});
    if (baggage.getValue("user_id")) |entry| {
        std.debug.print("User ID: {s}\n", .{entry.value});
    }

    if (baggage.getValue("account_id")) |entry| {
        std.debug.print("Account ID: {s}\n", .{entry.value});
        if (entry.metadata) |meta| {
            std.debug.print("  Metadata: {s}\n", .{meta});
        }
    }

    // Update an existing value (mutates in place)
    std.debug.print("\n--- Updating Values ---\n", .{});
    std.debug.print("Before update - user_id: {s}\n", .{baggage.getValue("user_id").?.value});

    try baggage.setValue(allocator, "user_id", "bob", null);

    std.debug.print("After update - user_id: {s}\n", .{baggage.getValue("user_id").?.value});

    // Use baggage with Context
    std.debug.print("\n--- Context Integration ---\n", .{});
    defer sdk.api.context.cleanup();

    var ctx = try sdk.api.baggage.insertBaggage(allocator, baggage);
    defer ctx.deinit();

    // Extract baggage from context
    if (sdk.api.baggage.extractBaggage(ctx)) |extracted| {
        std.debug.print("Extracted baggage from context:\n", .{});
        var extracted_it = extracted.iterator();
        while (extracted_it.next()) |entry| {
            std.debug.print("  {s} = {s}\n", .{
                entry.key_ptr.*,
                entry.value_ptr.value,
            });
        }
    }

    std.debug.print("\nExample completed successfully!\n", .{});
}
