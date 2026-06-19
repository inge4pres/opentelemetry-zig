const std = @import("std");
const zbench = @import("benchmark");

const sdk = @import("opentelemetry-sdk");
const TracerProvider = sdk.trace.TracerProvider;
const Tracer = sdk.trace.Tracer;

const TracerAPI = sdk.api.trace.Tracer;
const IDGenerator = sdk.trace.IDGenerator;

const Attribute = sdk.Attribute;
const AttributeValue = sdk.AttributeValue;

// Benchmark configuration
const Config = zbench.Config{
    .iterations = 100_000,
    .max_iterations = 1_000_000,
    .time_budget_ns = 2_000_000_000, // 2 seconds
    .track_allocations = true,
};

fn createTracerProvider(allocator: std.mem.Allocator, io: std.Io) !*TracerProvider {
    const id_gen = IDGenerator{ .TimeBased = .{} };
    return try TracerProvider.init(allocator, io, id_gen);
}

// === BENCHMARK TESTS ===

test "Span_Create_W/O_Attributes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const without_attributes = struct {
        tracer: *TracerAPI,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            defer span.deinit();
            span.end(null);
        }
    }{
        .tracer = tracer,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_Create_Without_Attributes", &without_attributes, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_Create_With_Attributes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const with_attributes = struct {
        tracer: *TracerAPI,
        attrs: [5]Attribute,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{
                .attributes = &self.attrs,
            }) catch return;
            defer span.deinit();
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

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_SetAttribute" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const set_attribute = struct {
        tracer: *TracerAPI,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            defer span.deinit();
            defer span.end(null);
            span.setAttribute("test_key", AttributeValue{ .string = "test_value" }) catch return;
        }
    }{
        .tracer = tracer,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_SetAttribute", &set_attribute, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_AddEvent" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const add_event = struct {
        tracer: *TracerAPI,
        attrs: [3]Attribute,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "test_span", .{}) catch return;
            defer span.deinit();
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

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_Nested_Creation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const nested_spans = struct {
        tracer: *TracerAPI,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var parent_span = self.tracer.startSpan(allocator, "parent_span", .{}) catch return;
            defer parent_span.deinit();
            defer parent_span.end(null);

            var child_span = self.tracer.startSpan(allocator, "child_span", .{}) catch return;
            defer child_span.deinit();
            defer child_span.end(null);
        }
    }{
        .tracer = tracer,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_Nested_Creation", &nested_spans, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_Non_Recording" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const non_recording = struct {
        tracer: *TracerAPI,

        pub fn run(self: *@This(), allocator: std.mem.Allocator) void {
            var span = self.tracer.startSpan(allocator, "non_recording_span", .{
                .kind = .Internal,
            }) catch return;
            defer span.deinit();
            defer span.end(null);

            span.setAttribute("key", .{ .string = "value" }) catch return;
            span.addEvent("test_event", null, null) catch return;
        }
    }{
        .tracer = tracer,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Span_Non_Recording", &non_recording, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}

test "Span_Concurrent_Creation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tp = try createTracerProvider(std.testing.allocator, io);
    defer tp.deinit();

    const tracer = try tp.getTracer(.{
        .name = "benchmark.trace",
    });

    const bench_config = zbench.Config{
        .iterations = 10_000,
        .max_iterations = 100_000,
        .time_budget_ns = 2_000_000_000, // 2 seconds
        .track_allocations = true,
    };

    // One arena per thread to avoid synchronization overhead and keep allocations
    // outside the std.testing.allocator domain.
    var arenas = [4]std.heap.ArenaAllocator{
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
        std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    defer for (&arenas) |*arena| arena.deinit();

    const concurrent_spans = struct {
        tracer: *TracerAPI,
        arenas: *[4]std.heap.ArenaAllocator,

        pub fn run(self: *@This(), _: std.mem.Allocator) void {
            const thread_count = 4;
            var threads: [4]std.Thread = undefined;

            const worker = struct {
                fn work(t: *TracerAPI, arena: *std.heap.ArenaAllocator, index: usize) void {
                    _ = arena.reset(.retain_capacity);
                    for (0..10) |_| {
                        var span = t.startSpan(arena.allocator(), "concurrent_span", .{}) catch return;
                        defer span.deinit();
                        defer span.end(null);
                        span.setAttribute("thread_id", .{ .int = @intCast(index) }) catch {};
                    }
                }
            };

            var spawned: usize = 0;
            for (0..thread_count) |i| {
                threads[spawned] = std.Thread.spawn(.{}, worker.work, .{ self.tracer, &self.arenas[i], i }) catch {
                    continue;
                };
                spawned += 1;
            }

            for (0..spawned) |i| {
                threads[i].join();
            }
        }
    }{
        .tracer = tracer,
        .arenas = &arenas,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Span_Concurrent_Creation", &concurrent_spans, .{});

    const stderr: std.Io.File = .stderr();
    try bench.run(io, stderr);
}
