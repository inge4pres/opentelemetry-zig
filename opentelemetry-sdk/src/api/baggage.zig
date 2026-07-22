//! OpenTelemetry Baggage API.
//!
//! Baggage is used to propagate contextual information across process boundaries.
//! It is a key-value store that can carry metadata like user IDs, account IDs,
//! feature flags, etc., making this data available throughout a distributed trace.
//!
//! SECURITY WARNING: Baggage is propagated in HTTP headers and environment variables.
//! Do not store sensitive information (passwords, tokens, PII) in baggage as it
//! may be exposed to unintended recipients.
//!
//! Example usage:
//! ```zig
//! const baggage = @import("opentelemetry").baggage;
//! const allocator = std.heap.page_allocator;
//!
//! // Create baggage with entries
//! var my_baggage = Baggage.init();
//! try my_baggage.setValue(allocator, "user_id", "alice", null);
//! try my_baggage.setValue(allocator, "account_id", "12345", "priority=high");
//! defer my_baggage.deinit();
//!
//! // Retrieve values
//! if (my_baggage.getValue("user_id")) |entry| {
//!     std.debug.print("User: {s}\n", .{entry.value});
//! }
//! ```
const std = @import("std");
const context = @import("context.zig");

/// A single baggage entry containing a value and optional metadata.
///
/// According to the OpenTelemetry specification:
/// - Values MUST be UTF-8 strings
/// - Metadata is an opaque string wrapper that may contain properties
pub const BaggageEntry = struct {
    /// The value associated with this baggage entry
    value: []const u8,
    /// Optional metadata for this entry (opaque string)
    metadata: ?[]const u8,

    /// Create a new baggage entry
    pub fn init(value: []const u8, metadata: ?[]const u8) BaggageEntry {
        return .{
            .value = value,
            .metadata = metadata,
        };
    }

    /// Clone this entry, allocating new memory for strings
    fn clone(self: BaggageEntry, allocator: std.mem.Allocator) !BaggageEntry {
        const value_copy = try allocator.dupe(u8, self.value);
        errdefer allocator.free(value_copy);

        const metadata_copy = if (self.metadata) |meta|
            try allocator.dupe(u8, meta)
        else
            null;

        return .{
            .value = value_copy,
            .metadata = metadata_copy,
        };
    }

    /// Free memory associated with this entry
    fn deinit(self: *BaggageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        if (self.metadata) |meta| {
            allocator.free(meta);
        }
    }
};

/// Internal hash map type for storing baggage entries efficiently.
const EntryMap = std.StringHashMapUnmanaged(BaggageEntry);

/// Baggage container for storing key-value pairs with optional metadata.
///
/// Baggage implements the OpenTelemetry Baggage API specification, providing
/// a data structure for propagating contextual information across process
/// boundaries. Modification operations (`setValue`, `removeValue`) mutate
/// the baggage in place, automatically managing the internal memory.
///
/// ## Memory Management
/// Baggage instances manage their own memory through the stored allocator.
/// Always call `deinit()` when done with a baggage to free its resources.
///
/// ## Example Usage
/// ```zig
/// var bag = Baggage.init();
/// try bag.setValue(allocator, "user_id", "alice", null);
/// try bag.setValue(allocator, "session", "xyz", "priority=high");
/// try bag.removeValue(allocator, "user_id");
/// defer bag.deinit();
/// ```
///
/// ## Thread Safety
/// Baggage instances are not thread-safe. Do not access a Baggage instance
/// from multiple threads without external synchronization.
pub const Baggage = struct {
    /// Internal storage for baggage entries. Null for empty baggage.
    entries: ?*EntryMap,
    /// Allocator used for memory management. Null for empty baggage.
    allocator: ?std.mem.Allocator,

    const Self = @This();

    /// Creates an empty baggage with no associated values.
    ///
    /// Empty baggage has minimal overhead and does not require explicit cleanup.
    ///
    /// ## Returns
    /// An empty Baggage instance ready for use.
    pub fn init() Self {
        return Self{ .entries = null, .allocator = null };
    }

    /// Retrieves a value associated with the given key.
    ///
    /// ## Parameters
    /// - `name`: The key to look up (case-sensitive)
    ///
    /// ## Returns
    /// The BaggageEntry associated with the key, or null if not found.
    pub fn getValue(self: Self, name: []const u8) ?BaggageEntry {
        const entries = self.entries orelse return null;
        return entries.get(name);
    }

    /// Returns an iterator over all baggage entries.
    ///
    /// ## Returns
    /// An iterator that yields all name-value pairs in the baggage.
    pub fn iterator(self: Self) EntryMap.Iterator {
        if (self.entries) |entries| {
            return entries.iterator();
        }
        // Return an empty iterator for empty baggage
        const empty_map = EntryMap{};
        return empty_map.iterator();
    }

    /// Sets a key-value pair in the baggage, mutating it in place.
    ///
    /// This operation creates a new internal map with all entries from the current
    /// baggage plus the new entry, then replaces the baggage's contents. The old
    /// baggage data is automatically cleaned up. If the key already exists, its
    /// value is replaced.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to the baggage to modify
    /// - `allocator`: Memory allocator for the new baggage data
    /// - `name`: The key to associate with the value (case-sensitive)
    /// - `value`: The string value to store
    /// - `metadata`: Optional metadata string for this entry
    ///
    /// ## Errors
    /// - `OutOfMemory`: If allocation fails during baggage creation
    ///
    /// ## Example
    /// ```zig
    /// var bag = Baggage.init();
    /// try bag.setValue(allocator, "user_id", "alice", null);
    /// try bag.setValue(allocator, "session", "xyz", "priority=high");
    /// defer bag.deinit();
    /// ```
    pub fn setValue(
        self: *Self,
        allocator: std.mem.Allocator,
        name: []const u8,
        value: []const u8,
        metadata: ?[]const u8,
    ) !void {
        // Create new map and clone existing entries if any
        const new_map_ptr = try allocator.create(EntryMap);
        errdefer allocator.destroy(new_map_ptr);

        if (self.entries) |existing| {
            // Deep clone all existing entries
            new_map_ptr.* = EntryMap{};
            try new_map_ptr.ensureTotalCapacity(allocator, existing.count() + 1);

            var it = existing.iterator();
            while (it.next()) |entry| {
                const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(name_copy);

                var entry_copy = try entry.value_ptr.clone(allocator);
                errdefer entry_copy.deinit(allocator);

                try new_map_ptr.putNoClobber(allocator, name_copy, entry_copy);
            }
        } else {
            new_map_ptr.* = EntryMap{};
        }

        // Error cleanup: free all cloned entries
        errdefer {
            var it = new_map_ptr.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                var val = entry.value_ptr.*;
                val.deinit(allocator);
            }
            new_map_ptr.deinit(allocator);
        }

        // Create the new entry
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        const metadata_copy = if (metadata) |meta|
            try allocator.dupe(u8, meta)
        else
            null;
        errdefer if (metadata_copy) |m| allocator.free(m);

        const new_entry = BaggageEntry{
            .value = value_copy,
            .metadata = metadata_copy,
        };

        // Use getOrPut to insert/replace the entry
        const gop = try new_map_ptr.getOrPut(allocator, name_copy);
        if (gop.found_existing) {
            // Key existed - free our duplicate key and the old value
            allocator.free(name_copy);
            var old_entry = gop.value_ptr.*;
            old_entry.deinit(allocator);
        }
        // Set the new value (works for both new and existing keys)
        gop.value_ptr.* = new_entry;

        // Clean up the old baggage and replace with new one
        self.deinit();
        self.* = Self{ .entries = new_map_ptr, .allocator = allocator };
    }

    /// Removes a key-value pair from the baggage, mutating it in place.
    ///
    /// This operation creates a new internal map with all entries except the one
    /// with the specified name, then replaces the baggage's contents. The old
    /// baggage data is automatically cleaned up. If the name does not exist,
    /// the baggage remains unchanged.
    ///
    /// ## Parameters
    /// - `self`: Mutable reference to the baggage to modify
    /// - `allocator`: Memory allocator for the new baggage data
    /// - `name`: The key to remove
    ///
    /// ## Errors
    /// - `OutOfMemory`: If allocation fails during baggage creation
    ///
    /// ## Example
    /// ```zig
    /// var bag = Baggage.init();
    /// try bag.setValue(allocator, "key1", "value1", null);
    /// try bag.setValue(allocator, "key2", "value2", null);
    /// try bag.removeValue(allocator, "key1");
    /// defer bag.deinit();
    /// ```
    pub fn removeValue(self: *Self, allocator: std.mem.Allocator, name: []const u8) !void {
        const entries = self.entries orelse return; // Nothing to remove

        // If the key doesn't exist, do nothing
        if (!entries.contains(name)) {
            return;
        }

        // Create new map without the specified entry
        const new_map_ptr = try allocator.create(EntryMap);
        errdefer allocator.destroy(new_map_ptr);

        new_map_ptr.* = EntryMap{};
        try new_map_ptr.ensureTotalCapacity(allocator, entries.count());

        var it = entries.iterator();
        while (it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, name)) {
                const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(name_copy);

                var entry_copy = try entry.value_ptr.clone(allocator);
                errdefer entry_copy.deinit(allocator);

                try new_map_ptr.putNoClobber(allocator, name_copy, entry_copy);
            }
        }

        // Clean up the old baggage
        self.deinit();

        // If we removed the last entry, leave baggage empty
        if (new_map_ptr.count() == 0) {
            new_map_ptr.deinit(allocator);
            allocator.destroy(new_map_ptr);
            self.* = Self.init();
        } else {
            self.* = Self{ .entries = new_map_ptr, .allocator = allocator };
        }
    }

    /// Creates a deep copy of this baggage.
    fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        const entries = self.entries orelse return Self.init();

        const new_map_ptr = try allocator.create(EntryMap);
        errdefer allocator.destroy(new_map_ptr);

        new_map_ptr.* = EntryMap{};
        try new_map_ptr.ensureTotalCapacity(allocator, entries.count());

        var it = entries.iterator();
        while (it.next()) |entry| {
            const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name_copy);

            var entry_copy = try entry.value_ptr.clone(allocator);
            errdefer entry_copy.deinit(allocator);

            try new_map_ptr.putNoClobber(allocator, name_copy, entry_copy);
        }

        return Self{ .entries = new_map_ptr, .allocator = allocator };
    }

    /// Returns the number of entries in this baggage.
    pub fn count(self: Self) usize {
        const entries = self.entries orelse return 0;
        return entries.count();
    }

    /// Releases all resources associated with this baggage.
    ///
    /// This must be called on all baggage instances created via setValue()
    /// or removeValue() to prevent memory leaks.
    pub fn deinit(self: *Self) void {
        if (self.entries) |entries| {
            if (self.allocator) |allocator| {
                var it = entries.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    var value = entry.value_ptr.*;
                    value.deinit(allocator);
                }
                entries.deinit(allocator);
                allocator.destroy(entries);
            }
        }
        self.* = init();
    }
};

// Context integration

/// Thread-local storage for the baggage key
threadlocal var baggage_key: ?context.ContextKey = null;

/// Get or create the Baggage context key
fn getBaggageKey() context.ContextKey {
    if (baggage_key) |key| {
        return key;
    }
    const key = context.createKey("opentelemetry.baggage");
    baggage_key = key;
    return key;
}

/// Extract Baggage from a Context instance.
///
/// Returns null if no Baggage is stored in the context.
///
/// ## Parameters
/// - `ctx`: The Context to extract from
///
/// ## Returns
/// The Baggage stored in the context, or null if not present.
pub fn extractBaggage(ctx: context.Context) ?Baggage {
    const value = ctx.getValue(getBaggageKey()) orelse return null;
    if (value != .baggage) return null;
    return value.baggage;
}

/// Insert Baggage into a new Context instance.
///
/// Creates a new Context containing the provided Baggage.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the new context
/// - `baggage`: The Baggage to store in the context
///
/// ## Returns
/// A new Context instance containing the Baggage.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during context creation
pub fn insertBaggage(allocator: std.mem.Allocator, baggage: Baggage) !context.Context {
    return try context.Context.init().setValue(
        allocator,
        getBaggageKey(),
        .{ .baggage = baggage },
    );
}

/// Get the currently active Baggage from the implicit context.
///
/// Returns an empty Baggage if no Baggage has been attached to the current context.
///
/// ## Returns
/// The current Baggage from the thread-local context stack.
pub fn getCurrentBaggage() Baggage {
    const current_context = context.getCurrentContext();
    return extractBaggage(current_context) orelse Baggage.init();
}

/// Set the currently active Baggage into a new context, and make that the implicit context.
///
/// ## Parameters
/// - `allocator`: Memory allocator for the new context
/// - `baggage`: The Baggage to set as current
///
/// ## Returns
/// A Token that must be used with `detachContext()` to remove this context.
///
/// ## Errors
/// - `OutOfMemory`: If allocation fails during context operations
pub fn setCurrentBaggage(allocator: std.mem.Allocator, baggage: Baggage) !context.Token {
    const new_context = try insertBaggage(allocator, baggage);
    return try context.attachContext(new_context);
}

// Re-export propagator
pub const propagator = @import("baggage/propagator.zig");

// Tests
test "baggage entry initialization" {
    const entry = BaggageEntry.init("value1", null);
    try std.testing.expectEqualStrings("value1", entry.value);
    try std.testing.expect(entry.metadata == null);

    const entry_with_meta = BaggageEntry.init("value2", "priority=high");
    try std.testing.expectEqualStrings("value2", entry_with_meta.value);
    try std.testing.expectEqualStrings("priority=high", entry_with_meta.metadata.?);
}

test "empty baggage" {
    const baggage = Baggage.init();
    try std.testing.expect(baggage.entries == null);
    try std.testing.expect(baggage.getValue("nonexistent") == null);
    try std.testing.expectEqual(@as(usize, 0), baggage.count());
}

test "baggage set and get" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key1", "value1", null);
    defer baggage.deinit();

    const entry = baggage.getValue("key1").?;
    try std.testing.expectEqualStrings("value1", entry.value);
    try std.testing.expectEqual(@as(usize, 1), baggage.count());
}

test "baggage with user_id" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    defer baggage.deinit();

    const entry = baggage.getValue("user_id").?;
    try std.testing.expectEqualStrings("alice", entry.value);
    try std.testing.expect(entry.metadata == null);
}

test "baggage with metadata" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "account_id", "12345", "priority=high");
    defer baggage.deinit();

    const entry = baggage.getValue("account_id").?;
    try std.testing.expectEqualStrings("12345", entry.value);
    try std.testing.expectEqualStrings("priority=high", entry.metadata.?);
}

test "baggage replace value" {
    const allocator = std.testing.allocator;

    var bag = Baggage.init();
    try bag.setValue(allocator, "key", "value1", null);
    defer bag.deinit();

    // Verify initial value
    try std.testing.expectEqualStrings("value1", bag.getValue("key").?.value);

    // Replace with new value
    try bag.setValue(allocator, "key", "value2", "meta");

    // Should have new value
    const entry = bag.getValue("key").?;
    try std.testing.expectEqualStrings("value2", entry.value);
    try std.testing.expectEqualStrings("meta", entry.metadata.?);
}

test "baggage remove value" {
    const allocator = std.testing.allocator;

    var bag = Baggage.init();
    try bag.setValue(allocator, "key1", "value1", null);
    try bag.setValue(allocator, "key2", "value2", null);
    defer bag.deinit();

    try std.testing.expectEqual(@as(usize, 2), bag.count());

    // Remove key1
    try bag.removeValue(allocator, "key1");

    // Should not have key1 anymore
    try std.testing.expect(bag.getValue("key1") == null);
    try std.testing.expect(bag.getValue("key2") != null);
    try std.testing.expectEqual(@as(usize, 1), bag.count());
}

test "baggage remove nonexistent value" {
    const allocator = std.testing.allocator;

    var bag = Baggage.init();
    try bag.setValue(allocator, "key1", "value1", null);
    defer bag.deinit();

    const count_before = bag.count();
    try bag.removeValue(allocator, "nonexistent");
    const count_after = bag.count();

    // Count should be unchanged
    try std.testing.expectEqual(count_before, count_after);
    try std.testing.expect(bag.getValue("key1") != null);
}

test "baggage iterator" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key1", "value1", null);
    try baggage.setValue(allocator, "key2", "value2", "meta");
    defer baggage.deinit();

    var count: usize = 0;
    var it = baggage.iterator();
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "baggage context integration" {
    const allocator = std.testing.allocator;
    defer context.cleanup();

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);

    var ctx = try insertBaggage(allocator, baggage);
    defer ctx.deinit();

    const extracted = extractBaggage(ctx).?;
    const entry = extracted.getValue("user_id").?;
    try std.testing.expectEqualStrings("alice", entry.value);

    // Note: We don't call baggage.deinit() here because the Context
    // stores the baggage value, but doesn't own the baggage memory.
    // The baggage is still owned by our local variable.
    baggage.deinit();
}

test "baggage current context" {
    const allocator = std.testing.allocator;
    defer context.cleanup();

    // Initially, current baggage should be empty
    const empty = getCurrentBaggage();
    try std.testing.expectEqual(@as(usize, 0), empty.count());

    // Create and set baggage
    var baggage = Baggage.init();
    try baggage.setValue(allocator, "key", "value", null);

    const token = try setCurrentBaggage(allocator, baggage);
    defer _ = context.detachContext(token) catch {};

    // Now current baggage should have our value
    const current = getCurrentBaggage();
    try std.testing.expect(current.getValue("key") != null);

    baggage.deinit();
}

test "baggage case sensitivity" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    try baggage.setValue(allocator, "Key", "value1", null);
    try baggage.setValue(allocator, "key", "value2", null);
    defer baggage.deinit();

    // Keys are case-sensitive
    try std.testing.expectEqualStrings("value1", baggage.getValue("Key").?.value);
    try std.testing.expectEqualStrings("value2", baggage.getValue("key").?.value);
    try std.testing.expectEqual(@as(usize, 2), baggage.count());
}

test "baggage case sensitivity - keys and values" {
    const allocator = std.testing.allocator;

    var baggage = Baggage.init();
    // Different case keys should be treated as different entries
    try baggage.setValue(allocator, "UserID", "alice", null);
    try baggage.setValue(allocator, "userId", "bob", null);
    try baggage.setValue(allocator, "USERID", "charlie", null);
    // Values should also preserve case
    try baggage.setValue(allocator, "email", "Alice@Example.COM", null);
    defer baggage.deinit();

    // Verify all three keys exist as separate entries
    try std.testing.expectEqual(@as(usize, 4), baggage.count());
    try std.testing.expectEqualStrings("alice", baggage.getValue("UserID").?.value);
    try std.testing.expectEqualStrings("bob", baggage.getValue("userId").?.value);
    try std.testing.expectEqualStrings("charlie", baggage.getValue("USERID").?.value);

    // Verify values preserve case
    try std.testing.expectEqualStrings("Alice@Example.COM", baggage.getValue("email").?.value);

    // Verify lookups are case-sensitive
    try std.testing.expect(baggage.getValue("userid") == null); // lowercase not found
    try std.testing.expect(baggage.getValue("Email") == null); // capitalized not found
}

test "baggage case sensitivity - propagation round-trip" {
    const allocator = std.testing.allocator;
    const prop = @import("baggage/propagator.zig");

    // Create baggage with case-sensitive keys and values
    var original = Baggage.init();
    try original.setValue(allocator, "UserID", "Alice", null);
    try original.setValue(allocator, "userId", "Bob", null);
    try original.setValue(allocator, "Email", "Test@Example.COM", null);
    defer original.deinit();

    // Inject into HTTP headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try prop.inject(allocator, original, &headers, prop.HttpSetter);

    // Extract from headers
    var extracted = try prop.extract(allocator, &headers, prop.HttpGetter);
    if (extracted) |*bag| {
        defer bag.deinit();

        // Verify case was preserved through the round-trip
        try std.testing.expectEqual(@as(usize, 3), bag.count());
        try std.testing.expectEqualStrings("Alice", bag.getValue("UserID").?.value);
        try std.testing.expectEqualStrings("Bob", bag.getValue("userId").?.value);
        try std.testing.expectEqualStrings("Test@Example.COM", bag.getValue("Email").?.value);

        // Verify wrong case doesn't match
        try std.testing.expect(bag.getValue("userid") == null);
        try std.testing.expect(bag.getValue("USERID") == null);
        try std.testing.expect(bag.getValue("email") == null);
    } else {
        try std.testing.expect(false); // Should have extracted baggage
    }
}

test "baggage setValue properly replaces existing key" {
    const allocator = std.testing.allocator;

    // Create baggage with initial value
    var bag = Baggage.init();
    try bag.setValue(allocator, "key", "value1", "meta1");
    defer bag.deinit();

    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqualStrings("value1", bag.getValue("key").?.value);
    try std.testing.expectEqualStrings("meta1", bag.getValue("key").?.metadata.?);

    // Replace with new value (mutates in place)
    try bag.setValue(allocator, "key", "value2", "meta2");

    // Should have the new value
    try std.testing.expectEqual(@as(usize, 1), bag.count());
    try std.testing.expectEqualStrings("value2", bag.getValue("key").?.value);
    try std.testing.expectEqualStrings("meta2", bag.getValue("key").?.metadata.?);
}

test "baggage setValue with multiple keys and replacement" {
    const allocator = std.testing.allocator;

    // Build up baggage with multiple keys
    var bag = Baggage.init();
    try bag.setValue(allocator, "k1", "v1", null);
    try bag.setValue(allocator, "k2", "v2", null);
    try bag.setValue(allocator, "k3", "v3", null);
    defer bag.deinit();

    // Verify all three keys exist
    try std.testing.expectEqual(@as(usize, 3), bag.count());
    try std.testing.expectEqualStrings("v1", bag.getValue("k1").?.value);
    try std.testing.expectEqualStrings("v2", bag.getValue("k2").?.value);
    try std.testing.expectEqualStrings("v3", bag.getValue("k3").?.value);

    // Replace k2
    try bag.setValue(allocator, "k2", "v2_new", "metadata");

    // Verify k2 was replaced, others unchanged
    try std.testing.expectEqual(@as(usize, 3), bag.count());
    try std.testing.expectEqualStrings("v1", bag.getValue("k1").?.value);
    try std.testing.expectEqualStrings("v2_new", bag.getValue("k2").?.value);
    try std.testing.expectEqualStrings("metadata", bag.getValue("k2").?.metadata.?);
    try std.testing.expectEqualStrings("v3", bag.getValue("k3").?.value);
}

test "baggage setValue memory safety with allocator" {
    // This test uses std.testing.allocator which detects leaks
    const allocator = std.testing.allocator;

    var bag = Baggage.init();
    try bag.setValue(allocator, "k1", "value1", null);
    try bag.setValue(allocator, "k2", "value2", "meta2");
    try bag.setValue(allocator, "k1", "value1_updated", "new_meta"); // Replace k1
    defer bag.deinit();

    // Verify final state
    try std.testing.expectEqual(@as(usize, 2), bag.count());
    try std.testing.expectEqualStrings("value1_updated", bag.getValue("k1").?.value);
    try std.testing.expectEqualStrings("new_meta", bag.getValue("k1").?.metadata.?);

    // If there are any leaks, std.testing.allocator will catch them when we deinit
}
