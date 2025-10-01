//! OpenTelemetry Context API.
//!
//! This module provides a thread-safe, immutable context implementation that conforms
//! to the OpenTelemetry Context API specification. Context is used to store and
//! propagate request-scoped data such as trace spans, baggage, and other cross-cutting
//! concerns throughout the application call stack.
//!
//! Example usage:
//! ```zig
//! const TraceIdKey = context.Key("trace_id");
//! const current_ctx = context.getCurrentContext();
//! const new_ctx = try current_ctx.setValue(allocator, TraceIdKey, .{ .string = "abc123" });
//! const token = try context.attachContext(new_ctx);
//! defer _ = context.detachContext(token) catch {};
//! ```
const std = @import("std");

const attributes = @import("../../attributes.zig");
const AttributeValue = attributes.AttributeValue;

/// Compile-time key ID generator for creating unique IDs during compilation.
///
/// This structure encapsulates the compile-time counter state to prevent
/// type resolution cascades that can occur with bare global variables.
/// Each call to `next()` returns a unique ID starting from 0.
///
/// Note: This is NOT thread-safe at runtime. It only works at compile-time
/// where there is no concurrency. This generator is only called from the
/// `Key()` function which executes at compile-time.
const ComptimeKeyGenerator = struct {
    var next_id: usize = 0;

    fn next() usize {
        const id = next_id;
        next_id += 1;
        return id;
    }
};

/// Atomic counter for generating unique runtime key IDs.
var next_runtime_key_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(1 << 32);

/// Opaque, type-safe key for storing and retrieving values from Context.
///
/// ContextKey provides identity-based equality and hashing, ensuring that
/// only the holder of a specific key instance can access its associated value.
/// This prevents accidental cross-contamination between different context values.
///
/// Keys can be created at compile-time using `Key()` or at runtime using `createKey()`.
/// Compile-time keys offer better performance and are preferred when the key name
/// is known statically.
pub const ContextKey = struct {
    /// Unique identifier for this key instance
    id: usize,
    /// Human-readable name for debugging and introspection
    name: []const u8,

    /// Hash context implementation for using ContextKey in hash maps.
    /// Uses the key's unique ID for fast, collision-resistant hashing.
    pub const HashContext = struct {
        pub fn hash(_: HashContext, key: ContextKey) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key.id));
        }
        pub fn eql(_: HashContext, a: ContextKey, b: ContextKey) bool {
            return a.id == b.id;
        }
    };
};

/// Creates a unique context key at runtime.
///
/// Runtime key creation is useful when key names are determined dynamically
/// or when keys need to be created in library initialization code.
///
/// ## Parameters
/// - `name`: Human-readable name for debugging. Does not affect key identity.
///
/// ## Returns
/// A unique ContextKey that can be used to store and retrieve context values.
///
/// ## Thread Safety
/// This function is thread-safe and can be called concurrently from multiple threads.
///
/// ## Example
/// ```zig
/// const request_id_key = context.createKey("http.request_id");
/// ```
pub fn createKey(name: []const u8) ContextKey {
    const id = next_runtime_key_id.fetchAdd(1, .seq_cst);
    return ContextKey{ .id = id, .name = name };
}

/// Creates a unique context key at compile-time.
///
/// Compile-time key creation offers better performance as key IDs are resolved
/// during compilation. This is the preferred method when key names are known
/// statically. Each call with the same name creates a different key.
///
/// ## Parameters
/// - `name`: Compile-time string literal for the key name
///
/// ## Returns
/// A unique ContextKey with a compile-time determined ID.
///
/// ## Example
/// ```zig
/// const TraceIdKey = context.Key("trace.trace_id");
/// const SpanIdKey = context.Key("trace.span_id");
/// ```
pub fn Key(comptime name: []const u8) ContextKey {
    return .{
        .id = ComptimeKeyGenerator.next(),
        .name = name,
    };
}

/// Internal hash map type for storing context entries efficiently.
const EntryMap = std.HashMapUnmanaged(ContextKey, AttributeValue, ContextKey.HashContext, std.hash_map.default_max_load_percentage);

/// Immutable context container that stores key-value pairs.
///
/// Context implements the OpenTelemetry Context API specification, providing
/// an immutable data structure for propagating request-scoped information.
/// All modification operations return a new Context instance, preserving
/// the original context's immutability guarantees.
///
/// ## Memory Management
/// Context instances manage their own memory through the stored allocator.
/// Always call `deinit()` on contexts created via `setValue()` to prevent
/// memory leaks.
///
/// ## Thread Safety
/// Individual Context instances are immutable and thus thread-safe for reads.
/// However, the `deinit()` operation is not thread-safe and should only be
/// called once by the owning thread.
pub const Context = struct {
    /// Internal storage for context entries. Null for empty contexts.
    entries: ?*EntryMap,
    /// Allocator used for memory management. Null for empty contexts.
    allocator: ?std.mem.Allocator,

    const Self = @This();

    /// Creates an empty context with no associated values.
    ///
    /// Empty contexts have minimal overhead and do not require explicit cleanup.
    ///
    /// ## Returns
    /// An empty Context instance ready for use.
    pub fn init() Self {
        return Self{ .entries = null, .allocator = null };
    }

    /// Retrieves a value associated with the given key.
    ///
    /// ## Parameters
    /// - `key`: The ContextKey to look up
    ///
    /// ## Returns
    /// The AttributeValue associated with the key, or null if not found.
    pub fn getValue(self: Self, key: ContextKey) ?AttributeValue {
        const entries = self.entries orelse return null;
        return entries.get(key);
    }

    /// Creates a new context with an additional key-value pair.
    ///
    /// This operation preserves immutability by creating a new context instance
    /// that contains all entries from the current context plus the new entry.
    /// If the key already exists, its value is replaced in the new context.
    ///
    /// ## Parameters
    /// - `allocator`: Memory allocator for the new context
    /// - `key`: The ContextKey to associate with the value
    /// - `value`: The AttributeValue to store
    ///
    /// ## Returns
    /// A new Context instance containing the additional entry.
    ///
    /// ## Errors
    /// - `OutOfMemory`: If allocation fails during context creation
    ///
    /// ## Memory Management
    /// The returned context must be cleaned up with `deinit()` to prevent leaks.
    pub fn setValue(self: Self, allocator: std.mem.Allocator, key: ContextKey, value: AttributeValue) !Self {
        const new_map_ptr = try allocator.create(EntryMap);
        if (self.entries) |existing| {
            new_map_ptr.* = try existing.clone(allocator);
        } else {
            new_map_ptr.* = EntryMap{};
        }
        errdefer allocator.destroy(new_map_ptr);
        try new_map_ptr.put(allocator, key, value);
        return Self{ .entries = new_map_ptr, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.entries) |entries| {
            if (self.allocator) |allocator| {
                entries.deinit(allocator);
                allocator.destroy(entries);
            }
        }
        self.* = init();
    }
};

/// Token representing a position in the context stack.
///
/// Tokens are returned by `attachContext()` and must be used with `detachContext()`
/// to maintain proper stack ordering. Tokens implement the LIFO (last-in, first-out)
/// semantics required by the OpenTelemetry specification.
pub const Token = struct {
    position: u32,
};

/// Thread-local context stack for implicit context propagation.
///
/// The context stack enables automatic context propagation without explicit
/// parameter passing. This follows the OpenTelemetry pattern where the "current"
/// context is implicitly available throughout the call stack.
const ContextStack = struct {
    /// Stack of attached contexts
    contexts: std.ArrayList(Context),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initializes a new context stack.
    fn init(allocator: std.mem.Allocator) Self {
        return Self{ .contexts = std.ArrayList(Context){}, .allocator = allocator };
    }

    /// Releases all resources and contexts in the stack.
    fn deinit(self: *Self) void {
        for (self.contexts.items) |*ctx| {
            ctx.deinit();
        }
        self.contexts.deinit(self.allocator);
    }

    /// Returns the current (top-most) context from the stack.
    fn current(self: *const Self) Context {
        return if (self.contexts.items.len > 0) self.contexts.items[self.contexts.items.len - 1] else Context.init();
    }

    /// Pushes a context onto the stack and returns a detachment token.
    fn attach(self: *Self, context: Context) !Token {
        const position = @as(u32, @intCast(self.contexts.items.len));
        try self.contexts.append(self.allocator, context);
        return Token{ .position = position };
    }

    /// Removes the top context from the stack if it matches the token position.
    fn detach(self: *Self, token: Token) !bool {
        const expected_len = token.position + 1;
        if (expected_len != self.contexts.items.len) {
            return error.DetachOrderError;
        }
        var popped = self.contexts.pop().?;
        (&popped).deinit();
        return true;
    }
};

/// Thread-local storage for the context stack.
/// Each thread maintains its own independent context stack.
threadlocal var context_stack: ?*ContextStack = null;

/// Retrieves or creates the thread-local context stack.
fn getContextStack(allocator: std.mem.Allocator) !*ContextStack {
    if (context_stack) |stack| {
        return stack;
    }
    const new_stack = try allocator.create(ContextStack);
    new_stack.* = ContextStack.init(allocator);
    context_stack = new_stack;
    return new_stack;
}

/// Returns the current context from the thread-local context stack.
///
/// This function provides access to the currently active context without
/// requiring explicit context passing. If no context has been attached,
/// returns an empty context.
///
/// ## Returns
/// The current Context from the top of the stack, or an empty context.
pub fn getCurrentContext() Context {
    const stack = (getContextStack(std.heap.page_allocator) catch return Context.init());
    return stack.current();
}

/// Attaches a context to the current thread's context stack.
///
/// The attached context becomes the new "current" context for subsequent
/// operations. This follows LIFO semantics - the most recently attached
/// context is always current.
///
/// ## Parameters
/// - `context`: The Context to attach to the stack
///
/// ## Returns
/// A Token that must be used with `detachContext()` to remove this context.
///
/// ## Errors
/// - `OutOfMemory`: If the context stack cannot be allocated or expanded
///
/// ## Example
/// ```zig
/// const token = try context.attachContext(my_context);
/// defer _ = context.detachContext(token) catch {};
/// // my_context is now the current context
/// ```
pub fn attachContext(context: Context) !Token {
    const stack = try getContextStack(std.heap.page_allocator);
    return stack.attach(context);
}

/// Errors that can occur during context detachment.
pub const DetachError = error{
    /// The context stack has not been initialized for this thread
    ContextStackNotInitialized,
    /// Attempted to detach contexts out of LIFO order
    DetachOrderError,
};

/// Detaches a context from the thread-local context stack.
///
/// Contexts must be detached in LIFO (last-in, first-out) order. Attempting
/// to detach contexts out of order will result in a `DetachOrderError`.
///
/// ## Parameters
/// - `token`: Token returned by `attachContext()` for the context to detach
///
/// ## Returns
/// `true` if the context was successfully detached.
pub fn detachContext(token: Token) DetachError!bool {
    const stack = context_stack orelse return error.ContextStackNotInitialized;
    return stack.detach(token);
}

/// Cleans up all thread-local context resources.
///
/// This function should be called before thread termination to prevent
/// memory leaks. It releases the context stack and all attached contexts
/// for the current thread.
///
/// ## Thread Safety
/// This function only affects the calling thread's context stack.
///
/// ## Usage
/// ```zig
/// defer context.cleanup(); // At thread/program exit
/// ```
pub fn cleanup() void {
    if (context_stack) |stack| {
        const allocator = stack.allocator;
        stack.deinit();
        allocator.destroy(stack);
        context_stack = null;
    }
}

// --- Tests ---
test "key creation uniqueness" {
    const key1 = createKey("test");
    const key2 = createKey("test");
    try std.testing.expect(key1.id != key2.id);
}

test "context immutability" {
    const allocator = std.testing.allocator;
    const ctx1 = Context.init();
    const key = createKey("test_key");
    var ctx2 = try ctx1.setValue(allocator, key, .{ .string = "value1" });
    defer ctx2.deinit();
    try std.testing.expect(ctx1.getValue(key) == null);
    const value = ctx2.getValue(key).?;
    try std.testing.expectEqualStrings("value1", value.string);
}

test "context operations" {
    const allocator = std.testing.allocator;
    defer cleanup();

    try std.testing.expect(getCurrentContext().entries == null);

    const key = createKey("test");
    const ctx = try Context.init().setValue(allocator, key, .{ .int = 42 });
    const token = try attachContext(ctx);
    const value = getCurrentContext().getValue(key).?;

    try std.testing.expectEqual(@as(i64, 42), value.int);
    try std.testing.expect(try detachContext(token));
    try std.testing.expect(getCurrentContext().getValue(key) == null);
}

test "detach error handling" {
    const allocator = std.testing.allocator;
    defer cleanup();

    const ctx1 = try Context.init().setValue(allocator, createKey("k1"), .{ .int = 1 });
    const ctx2 = try Context.init().setValue(allocator, createKey("k2"), .{ .int = 2 });

    const token1 = try attachContext(ctx1);
    const token2 = try attachContext(ctx2);

    try std.testing.expectError(error.DetachOrderError, detachContext(token1));

    try std.testing.expect(try detachContext(token2));
    try std.testing.expect(try detachContext(token1));
}

test "key creation" {
    const MyKey = Key("my_service.request_id");
    const OtherKey = Key("my_service.request_id");
    try std.testing.expect(MyKey.id != OtherKey.id);
    try std.testing.expectEqual(@as(usize, 0), MyKey.id);
    try std.testing.expectEqual(@as(usize, 1), OtherKey.id);
}

test "context chaining" {
    const allocator = std.testing.allocator;
    const key1 = createKey("key1");
    const key2 = createKey("key2");
    var ctx1 = try Context.init().setValue(allocator, key1, .{ .string = "value1" });
    defer ctx1.deinit();
    var ctx2 = try ctx1.setValue(allocator, key2, .{ .string = "value2" });
    defer ctx2.deinit();
    try std.testing.expectEqualStrings("value1", ctx2.getValue(key1).?.string);
    try std.testing.expectEqualStrings("value2", ctx2.getValue(key2).?.string);
    try std.testing.expectEqualStrings("value1", ctx1.getValue(key1).?.string);
    try std.testing.expect(ctx1.getValue(key2) == null);
}

test "context thread isolation" {
    // Verify that each thread has its own independent context stack
    var thread_count = std.atomic.Value(u32).init(0);

    const threadWorker = struct {
        fn run(counter: *std.atomic.Value(u32)) void {
            defer cleanup();

            // Each thread should start with an uninitialized context stack
            if (context_stack == null) {
                _ = counter.fetchAdd(1, .seq_cst);
            }
        }
    }.run;

    // Spawn multiple threads to verify isolation
    const t1 = try std.Thread.spawn(.{}, threadWorker, .{&thread_count});
    const t2 = try std.Thread.spawn(.{}, threadWorker, .{&thread_count});
    const t3 = try std.Thread.spawn(.{}, threadWorker, .{&thread_count});

    t1.join();
    t2.join();
    t3.join();

    // All threads should have seen null context_stack initially
    try std.testing.expectEqual(@as(u32, 3), thread_count.load(.seq_cst));
}

test "context thread-local storage verification" {
    // Verify that thread-local storage works correctly for context stacks
    var success = std.atomic.Value(bool).init(false);

    const verifyThreadLocal = struct {
        fn run(result: *std.atomic.Value(bool)) void {
            // Verify this thread has its own context_stack variable
            if (context_stack == null) {
                result.store(true, .seq_cst);
            }
        }
    }.run;

    const thread = try std.Thread.spawn(.{}, verifyThreadLocal, .{&success});
    thread.join();

    try std.testing.expect(success.load(.seq_cst));
}

test "runtime key creation thread safety" {
    // This test verifies that createKey() is thread-safe by having multiple
    // threads create keys simultaneously and checking for uniqueness

    const num_threads = 4;
    const keys_per_thread = 100;

    // Shared state for collecting results
    const SharedData = struct {
        keys: std.ArrayList(ContextKey),
        mutex: std.Thread.Mutex = .{},
        barrier: std.Thread.ResetEvent = .{},
    };

    var shared = SharedData{
        .keys = std.ArrayList(ContextKey){},
    };
    defer shared.keys.deinit(std.testing.allocator);

    const keyGenWorker = struct {
        fn run(data: *SharedData, thread_id: u32) void {
            // Wait for all threads to start
            data.barrier.wait();

            // Generate keys rapidly to stress test atomicity
            var local_keys: [keys_per_thread]ContextKey = undefined;
            for (0..keys_per_thread) |i| {
                var name_buf: [64]u8 = undefined;
                const name = std.fmt.bufPrint(
                    &name_buf,
                    "thread_{}_key_{}",
                    .{ thread_id, i },
                ) catch unreachable;
                local_keys[i] = createKey(name);
            }

            // Add to shared collection
            data.mutex.lock();
            defer data.mutex.unlock();
            data.keys.appendSlice(std.testing.allocator, &local_keys) catch unreachable;
        }
    }.run;

    // Spawn threads
    var threads: [num_threads]std.Thread = undefined;
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(
            .{},
            keyGenWorker,
            .{ &shared, @as(u32, @intCast(i)) },
        );
    }

    // Start all threads simultaneously
    shared.barrier.set();

    // Wait for completion
    for (threads) |thread| {
        thread.join();
    }

    // Verify we have the expected number of keys
    try std.testing.expectEqual(
        @as(usize, num_threads * keys_per_thread),
        shared.keys.items.len,
    );

    // Verify all key IDs are unique
    var seen = std.AutoHashMap(usize, void).init(std.testing.allocator);
    defer seen.deinit();

    for (shared.keys.items) |key| {
        const result = try seen.getOrPut(key.id);
        try std.testing.expect(!result.found_existing);
    }
}
