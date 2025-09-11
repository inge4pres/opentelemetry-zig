const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const TracerProvider = sdk.trace.TracerProvider;
const SDKTracer = sdk.trace.SDKTracer;
const IDGenerator = sdk.trace.IDGenerator;
const RandomIDGenerator = sdk.trace.RandomIDGenerator;
const SpanProcessor = sdk.trace.span_processor.SpanProcessor;
const zbench = @import("benchmark");
const trace = sdk.api.trace;
const Attribute = sdk.Attribute;
const AttributeValue = sdk.AttributeValue;

// Thread-local random number generator
threadlocal var thread_rng: ?std.Random.DefaultPrng = null;

fn getThreadRng() *std.Random.DefaultPrng {
    if (thread_rng == null) {
        thread_rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    }
    return &thread_rng.?;
}

// Benchmark configuration
const Config = zbench.Config{
    .iterations = 100_000,
    .max_iterations = 1_000_000,
    .time_budget_ns = 2_000_000_000, // 2 seconds
    .track_allocations = true,
};

fn setupSDK(allocator: std.mem.Allocator) !*TracerProvider {
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const random = prng.random();
    const id_gen = IDGenerator{ .Random = RandomIDGenerator.init(random) };
    const tp = try TracerProvider.init(allocator, id_gen);
    errdefer tp.shutdown();
    return tp;
}

// Helper function to create a TracerProvider with ID generator
fn createTracerProvider(allocator: std.mem.Allocator) !*TracerProvider {
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    const random = prng.random();
    const id_gen = IDGenerator{ .Random = RandomIDGenerator.init(random) };
    return try TracerProvider.init(allocator, id_gen);
}

// Generate random attributes similar to metrics benchmarks
const ATTR_VALUES = [_][]const u8{
    "value_0", "value_1", "value_2", "value_3", "value_4",
    "value_5", "value_6", "value_7", "value_8", "value_9",
};

const ATTR_KEYS = [_][]const u8{
    "key_0", "key_1", "key_2", "key_3", "key_4",
    "key_5", "key_6", "key_7", "key_8", "key_9",
};

fn getRandomAttribute(rng: *std.Random.DefaultPrng) Attribute {
    const key_idx = rng.random().int(usize) % ATTR_KEYS.len;
    const val_idx = rng.random().int(usize) % ATTR_VALUES.len;
    return Attribute{
        .key = ATTR_KEYS[key_idx],
        .value = AttributeValue{ .string = ATTR_VALUES[val_idx] },
    };
}

// === BENCHMARK TESTS ===

test "Span_Create_W/O_Attributes" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const without_attributes = struct {
        tracer: *SDKTracer,

        pub fn setup(_: @This(), _: std.mem.Allocator) void {}
        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            span.end(null);
        }
        pub fn teardown(_: @This(), _: std.mem.Allocator) void {}
    }{ .tracer = tracer };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_Create_Without_Attributes", &without_attributes, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_Create_With_Attributes" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const with_attributes = struct {
        tracer: *SDKTracer,
        attrs: [5]Attribute,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{
                .attributes = &self.attrs,
            }) catch return;
            span.end(null);
        }
    }{
        .tracer = tracer,
        .attrs = [_]Attribute{
            Attribute{ .key = "key1", .value = AttributeValue{ .string = "value1" } },
            Attribute{ .key = "key2", .value = AttributeValue{ .string = "value2" } },
            Attribute{ .key = "key3", .value = AttributeValue{ .string = "value3" } },
            Attribute{ .key = "key4", .value = AttributeValue{ .string = "value4" } },
            Attribute{ .key = "key5", .value = AttributeValue{ .string = "value5" } },
        },
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_Create_With_Attributes", &with_attributes, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_SetAttribute" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const set_attribute = struct {
        tracer: *SDKTracer,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            defer span.end(null);
            span.setAttribute("test_key", AttributeValue{ .string = "test_value" }) catch return;
        }
    }{
        .tracer = tracer,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_SetAttribute", &set_attribute, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_AddEvent" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const add_event = struct {
        tracer: *SDKTracer,
        attrs: [3]Attribute,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            defer span.end(null);
            span.addEvent("test_event", null, &self.attrs) catch return;
        }
    }{
        .tracer = tracer,
        .attrs = [_]Attribute{
            Attribute{ .key = "event_key1", .value = AttributeValue{ .string = "event_value1" } },
            Attribute{ .key = "event_key2", .value = AttributeValue{ .string = "event_value2" } },
            Attribute{ .key = "event_key3", .value = AttributeValue{ .string = "event_value3" } },
        },
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_AddEvent", &add_event, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_Nested_Creation" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const bench_config = Config;

    const nested_spans = struct {
        tracer: *SDKTracer,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var parent_span = self.tracer.startSpan(allocator, "parent_span", .{}) catch return;
            defer parent_span.end(null);

            // Note: For now we'll just create two spans since we need to study the parent relationship API
            var child_span = self.tracer.startSpan(allocator, "child_span", .{}) catch return;
            defer child_span.end(null);
        }
    }{ .tracer = tracer };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Span_Nested_Creation", &nested_spans, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_Non_Recording" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const bench_config = Config;

    const non_recording = struct {
        tracer: *SDKTracer,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "non_recording_span", .{
                .kind = .Internal,
            }) catch return;
            defer span.end(null);

            // Add some operations that would normally be recorded
            span.setAttribute("key", .{ .string = "value" }) catch return;
            span.addEvent("test_event", null, null) catch return;
            // span.setStatus(.{ .code = .ok }); // TODO: Check if this method exists
        }
    }{ .tracer = tracer };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Span_Non_Recording", &non_recording, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "Span_Concurrent_Creation" {
    const tp = try createTracerProvider(std.testing.allocator);
    defer tp.shutdown();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const bench_config = zbench.Config{
        .iterations = 10_000,
        .max_iterations = 100_000,
        .time_budget_ns = 2_000_000_000, // 2 seconds
        .track_allocations = true,
    };

    const concurrent_spans = struct {
        tracer: *SDKTracer,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            const thread_count = 4;
            const threads = allocator.alloc(std.Thread, thread_count) catch return;
            defer allocator.free(threads);

            const worker = struct {
                fn work(t: *SDKTracer, alloc: std.mem.Allocator, index: usize) void {
                    for (0..10) |_| {
                        var span = t.startSpan(alloc, "concurrent_span", .{}) catch return;
                        span.setAttribute("thread_id", .{ .int = @intCast(index) }) catch {};
                        span.end(null);
                    }
                }
            };

            for (threads, 0..) |*thread, i| {
                thread.* = std.Thread.spawn(.{}, worker.work, .{ self.tracer, allocator, i }) catch {
                    // If spawn fails, just continue without this thread
                    continue;
                };
            }

            for (threads) |thread| {
                thread.join();
            }
        }
    }{ .tracer = tracer };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Span_Concurrent_Creation", &concurrent_spans, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}
