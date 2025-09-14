const std = @import("std");
const sdk = @import("opentelemetry-sdk");
const TracerProvider = sdk.trace.SDKTracerProvider;
const SpanProcessor = sdk.trace.SpanProcessor;
const SimpleProcessor = sdk.trace.SimpleProcessor;
const BatchingProcessor = sdk.trace.BatchingProcessor;
const SpanExporter = sdk.trace.SpanExporter;
const benchmark = @import("benchmark");
const trace = sdk.api.trace;
const InstrumentationScope = sdk.InstrumentationScope;

// Thread-local random number generator
threadlocal var thread_rng: ?std.Random.DefaultPrng = null;

fn getThreadRng() *std.Random.DefaultPrng {
    if (thread_rng == null) {
        thread_rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    }
    return &thread_rng.?;
}

// Benchmark configuration
const bench_config = benchmark.Config{
    .max_iterations = 100000,
    .time_budget_ns = 2 * std.time.ns_per_s,
    .track_allocations = false,
};

// Mock exporter for benchmarks - designed to be fast and minimal
const MockExporter = struct {
    export_count: std.atomic.Value(u64),

    pub fn init() MockExporter {
        return MockExporter{
            .export_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn exportSpans(ctx: *anyopaque, spans: []trace.Span) anyerror!void {
        const self: *MockExporter = @ptrCast(@alignCast(ctx));
        _ = self.export_count.fetchAdd(@intCast(spans.len), .monotonic);
    }

    pub fn shutdown(_: *anyopaque) anyerror!void {}

    pub fn asSpanExporter(self: *MockExporter) SpanExporter {
        return SpanExporter{
            .ptr = self,
            .vtable = &.{
                .exportSpansFn = exportSpans,
                .shutdownFn = shutdown,
            },
        };
    }

    pub fn getExportCount(self: *MockExporter) u64 {
        return self.export_count.load(.monotonic);
    }

    pub fn reset(self: *MockExporter) void {
        self.export_count.store(0, .monotonic);
    }
};

// Generate random attributes for benchmarks
const ATTR_VALUES = [_][]const u8{
    "value_0", "value_1", "value_2", "value_3", "value_4",
    "value_5", "value_6", "value_7", "value_8", "value_9",
};

// Helper function to create a test span
fn createTestSpan(allocator: std.mem.Allocator, name: []const u8, index: u8) trace.Span {
    const trace_id = trace.TraceID.init([16]u8{ index, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 });
    const span_id = trace.SpanID.init([8]u8{ index, 2, 3, 4, 5, 6, 7, 8 });
    const trace_state = trace.TraceState.init(allocator);

    const span_context = trace.SpanContext.init(trace_id, span_id, trace.TraceFlags.default(), trace_state, false);
    const scope = InstrumentationScope{ .name = "benchmark-lib", .version = "1.0.0" };
    var span = trace.Span.init(allocator, span_context, name, .Internal, scope);
    span.is_recording = true;
    return span;
}

test "SimpleProcessor_OnEnd_Single" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = SimpleProcessor.init(std.testing.allocator, exporter);
    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const simple_single = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const counter = self.span_counter.fetchAdd(1, .monotonic);
            var test_span = createTestSpan(self.allocator, "benchmark-span", @intCast(counter % 256));
            defer test_span.deinit();

            self.processor.onEnd(test_span);
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("SimpleProcessor_OnEnd_Single", &simple_single, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "SimpleProcessor_OnEnd_With_Attributes" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = SimpleProcessor.init(std.testing.allocator, exporter);
    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const simple_with_attrs = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const counter = self.span_counter.fetchAdd(1, .monotonic);
            var test_span = createTestSpan(self.allocator, "benchmark-span-attrs", @intCast(counter % 256));
            defer test_span.deinit();

            // Add some attributes to make the benchmark more realistic
            test_span.setAttributes(&.{
                .{ .key = "service.name", .value = .{ .string = "benchmark-service" } },
                .{ .key = "http.method", .value = .{ .string = "GET" } },
                .{ .key = "http.status_code", .value = .{ .int = 200 } },
                .{ .key = "request.id", .value = .{ .string = ATTR_VALUES[counter % ATTR_VALUES.len] } },
            }) catch {};

            self.processor.onEnd(test_span);
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("SimpleProcessor_OnEnd_With_Attributes", &simple_with_attrs, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "BatchingProcessor_OnEnd_Single" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = try BatchingProcessor.init(std.testing.allocator, exporter, .{
        .max_export_batch_size = 512,
        .scheduled_delay_millis = 1000, // Long delay to avoid timing effects
        .max_queue_size = 2048,
    });
    defer {
        const span_processor = processor.asSpanProcessor();
        span_processor.shutdown() catch {};
        processor.deinit();
    }

    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const batch_single = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const counter = self.span_counter.fetchAdd(1, .monotonic);
            var test_span = createTestSpan(self.allocator, "batch-span", @intCast(counter % 256));
            defer test_span.deinit();

            self.processor.onEnd(test_span);
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("BatchingProcessor_OnEnd_Single", &batch_single, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "BatchingProcessor_OnEnd_With_Attributes" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = try BatchingProcessor.init(std.testing.allocator, exporter, .{
        .max_export_batch_size = 512,
        .scheduled_delay_millis = 1000, // Long delay to avoid timing effects
        .max_queue_size = 2048,
    });
    defer {
        const span_processor = processor.asSpanProcessor();
        span_processor.shutdown() catch {};
        processor.deinit();
    }

    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const batch_with_attrs = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const counter = self.span_counter.fetchAdd(1, .monotonic);
            var test_span = createTestSpan(self.allocator, "batch-span-attrs", @intCast(counter % 256));
            defer test_span.deinit();

            // Add some attributes to make the benchmark more realistic
            test_span.setAttribute("service.name", .{ .string = "benchmark-service" }) catch {};
            test_span.setAttribute("http.method", .{ .string = "GET" }) catch {};
            test_span.setAttribute("http.status_code", .{ .int = 200 }) catch {};
            test_span.setAttribute("request.id", .{ .string = ATTR_VALUES[counter % ATTR_VALUES.len] }) catch {};

            self.processor.onEnd(test_span);
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("BatchingProcessor_OnEnd_With_Attributes", &batch_with_attrs, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "BatchingProcessor_Batch_Full" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = try BatchingProcessor.init(std.testing.allocator, exporter, .{
        .max_export_batch_size = 10, // Small batch size to trigger frequent exports
        .scheduled_delay_millis = 100,
        .max_queue_size = 1000,
    });
    defer {
        const span_processor = processor.asSpanProcessor();
        span_processor.shutdown() catch {};
        processor.deinit();
    }

    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, .{
        .max_iterations = 1000, // Lower iterations since we're triggering batch exports
        .time_budget_ns = 2 * std.time.ns_per_s,
        .track_allocations = false,
    });
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const batch_full = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Create multiple spans to trigger batch export
            var spans: [12]trace.Span = undefined;
            defer {
                for (&spans) |*span| {
                    span.deinit();
                }
            }

            for (&spans, 0..) |*span, i| {
                const counter = self.span_counter.fetchAdd(1, .monotonic);
                span.* = createTestSpan(self.allocator, "batch-full-span", @intCast((counter + i) % 256));
                span.setAttribute("span.index", .{ .int = @intCast(i) }) catch {};
                self.processor.onEnd(span.*);
            }
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("BatchingProcessor_Batch_Full", &batch_full, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "BatchingProcessor_ForceFlush" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var processor = try BatchingProcessor.init(std.testing.allocator, exporter, .{
        .max_export_batch_size = 512,
        .scheduled_delay_millis = 10000, // Very long delay to rely on force flush
        .max_queue_size = 2048,
    });
    defer {
        const span_processor = processor.asSpanProcessor();
        span_processor.shutdown() catch {};
        processor.deinit();
    }

    const span_processor = processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, .{
        .max_iterations = 1000, // Lower iterations due to force flush overhead
        .time_budget_ns = 2 * std.time.ns_per_s,
        .track_allocations = false,
    });
    defer bench.deinit();

    // Initialize atomic counter
    var span_counter = std.atomic.Value(u32).init(0);

    const force_flush = struct {
        processor: SpanProcessor,
        allocator: std.mem.Allocator,
        span_counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            // Add several spans
            var spans: [5]trace.Span = undefined;
            defer {
                for (&spans) |*span| {
                    span.deinit();
                }
            }

            for (&spans, 0..) |*span, i| {
                const counter = self.span_counter.fetchAdd(1, .monotonic);
                span.* = createTestSpan(self.allocator, "force-flush-span", @intCast((counter + i) % 256));
                self.processor.onEnd(span.*);
            }

            // Force flush to export them immediately
            self.processor.forceFlush() catch @panic("forceFlush failed");
        }
    }{
        .processor = span_processor,
        .allocator = std.testing.allocator,
        .span_counter = &span_counter,
    };

    try bench.addParam("BatchingProcessor_ForceFlush", &force_flush, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

test "SpanProcessor_Concurrent" {
    var mock_exporter = MockExporter.init();
    const exporter = mock_exporter.asSpanExporter();

    var simple_processor = SimpleProcessor.init(std.testing.allocator, exporter);
    const simple_span_processor = simple_processor.asSpanProcessor();

    var batch_processor = try BatchingProcessor.init(std.testing.allocator, exporter, .{
        .max_export_batch_size = 100,
        .scheduled_delay_millis = 500,
        .max_queue_size = 1000,
    });
    defer {
        const batch_span_processor = batch_processor.asSpanProcessor();
        batch_span_processor.shutdown() catch {};
        batch_processor.deinit();
    }
    const batch_span_processor = batch_processor.asSpanProcessor();

    var bench = benchmark.Benchmark.init(std.testing.allocator, .{
        .max_iterations = 1000,
        .time_budget_ns = 2 * std.time.ns_per_s,
        .track_allocations = false,
    });
    defer bench.deinit();

    const concurrent_simple = ConcurrentProcessorBench{
        .processor = simple_span_processor,
        .name = "Simple",
    };
    try bench.addParam("SpanProcessor_Concurrent_Simple", &concurrent_simple, .{});

    const concurrent_batch = ConcurrentProcessorBench{
        .processor = batch_span_processor,
        .name = "Batch",
    };
    try bench.addParam("SpanProcessor_Concurrent_Batch", &concurrent_batch, .{});

    const writer = std.io.getStdErr().writer();
    try bench.run(writer);
}

const ConcurrentProcessorBench = struct {
    processor: SpanProcessor,
    name: []const u8,

    pub fn run(self: @This(), _: std.mem.Allocator) void {
        const t1 = std.Thread.spawn(.{}, processSpans, .{ self.processor, "thread1", 0 }) catch @panic("spawn failed");
        const t2 = std.Thread.spawn(.{}, processSpans, .{ self.processor, "thread2", 100 }) catch @panic("spawn failed");
        const t3 = std.Thread.spawn(.{}, processSpans, .{ self.processor, "thread3", 200 }) catch @panic("spawn failed");

        t1.join();
        t2.join();
        t3.join();
    }

    fn processSpans(processor: SpanProcessor, thread_name: []const u8, offset: u8) void {
        // Process a few spans per thread
        var spans: [3]trace.Span = undefined;
        defer {
            for (&spans) |*span| {
                span.deinit();
            }
        }

        for (&spans, 0..) |*span, i| {
            span.* = createTestSpan(std.testing.allocator, thread_name, offset + @as(u8, @intCast(i)));
            span.setAttribute("thread", .{ .string = thread_name }) catch {};
            processor.onEnd(span.*);
        }
    }
};
