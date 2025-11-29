const std = @import("std");
const zbench = @import("benchmark");

const sdk = @import("opentelemetry-sdk");
const LoggerProvider = sdk.logs.LoggerProvider;
const Logger = sdk.logs.Logger;
const ReadableLogRecord = sdk.logs.ReadableLogRecord;
const SimpleLogRecordProcessor = sdk.logs.SimpleLogRecordProcessor;
const InMemoryExporter = sdk.logs.InMemoryExporter;

const Attribute = sdk.Attribute;
const AttributeValue = sdk.AttributeValue;
const InstrumentationScope = sdk.scope.InstrumentationScope;

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

// Benchmark context that holds all necessary state
const BenchmarkContext = struct {
    provider: *LoggerProvider,
    buffer: std.ArrayList(u8),
    exporter: InMemoryExporter,
    processor: SimpleLogRecordProcessor,

    fn init(allocator: std.mem.Allocator) !*BenchmarkContext {
        const ctx = try allocator.create(BenchmarkContext);
        errdefer allocator.destroy(ctx);

        ctx.buffer = std.ArrayList(u8){};
        ctx.exporter = InMemoryExporter.init(ctx.buffer.writer(allocator));
        ctx.processor = SimpleLogRecordProcessor.init(allocator, ctx.exporter.asLogRecordExporter());

        ctx.provider = try LoggerProvider.init(allocator, null);
        errdefer ctx.provider.deinit();

        try ctx.provider.addLogRecordProcessor(ctx.processor.asLogRecordProcessor());

        return ctx;
    }

    fn deinit(self: *BenchmarkContext, allocator: std.mem.Allocator) void {
        self.provider.deinit();
        self.buffer.deinit(allocator);
        allocator.destroy(self);
    }
};

// Generate random attributes similar to other benchmarks
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

test "Logger_Emit_W/O_Attributes" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const without_attributes = struct {
        logger: *Logger,

        pub fn setup(_: @This(), _: std.mem.Allocator) void {}
        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.logger.emit(9, "INFO", "test log message", null);
        }
        pub fn teardown(_: @This(), _: std.mem.Allocator) void {}
    }{ .logger = logger };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_Without_Attributes", &without_attributes, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Emit_With_Attributes" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const with_attributes = struct {
        logger: *Logger,
        attrs: [5]Attribute,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.logger.emit(9, "INFO", "test log message", &self.attrs);
        }
    }{
        .logger = logger,
        .attrs = [_]Attribute{
            Attribute{ .key = "user.id", .value = AttributeValue{ .int = 12345 } },
            Attribute{ .key = "request.path", .value = AttributeValue{ .string = "/api/users" } },
            Attribute{ .key = "request.method", .value = AttributeValue{ .string = "GET" } },
            Attribute{ .key = "response.status", .value = AttributeValue{ .int = 200 } },
            Attribute{ .key = "duration.ms", .value = AttributeValue{ .int = 42 } },
        },
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_With_Attributes", &with_attributes, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Emit_Different_Severities" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const bench_config = Config;

    // Test different severity levels (TRACE=1, DEBUG=5, INFO=9, WARN=13, ERROR=17, FATAL=21)
    var counter = std.atomic.Value(u32).init(0);
    const severities = struct {
        logger: *Logger,
        severity_levels: [6]u8,
        counter: *std.atomic.Value(u32),

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            const idx = self.counter.fetchAdd(1, .monotonic) % self.severity_levels.len;
            const severity = self.severity_levels[idx];
            const severity_text = switch (severity) {
                1 => "TRACE",
                5 => "DEBUG",
                9 => "INFO",
                13 => "WARN",
                17 => "ERROR",
                21 => "FATAL",
                else => "UNKNOWN",
            };
            self.logger.emit(severity, severity_text, "test log message", null);
        }
    }{
        .logger = logger,
        .severity_levels = [_]u8{ 1, 5, 9, 13, 17, 21 },
        .counter = &counter,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_Different_Severities", &severities, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Emit_Small_Body" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const small_body = struct {
        logger: *Logger,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.logger.emit(9, "INFO", "OK", null);
        }
    }{ .logger = logger };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_Small_Body", &small_body, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Emit_Large_Body" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const large_message = "This is a longer log message that contains more details about what happened " ++
        "in the application. It might include stack traces, error messages, or other diagnostic " ++
        "information that is useful for debugging. The message is long enough to test performance " ++
        "with larger payloads that are more representative of real-world logging scenarios.";

    const large_body = struct {
        logger: *Logger,
        message: []const u8,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.logger.emit(9, "INFO", self.message, null);
        }
    }{
        .logger = logger,
        .message = large_message,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_Large_Body", &large_body, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Emit_With_Many_Attributes" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const many_attributes = struct {
        logger: *Logger,
        attrs: [10]Attribute,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            self.logger.emit(9, "INFO", "test log with many attributes", &self.attrs);
        }
    }{
        .logger = logger,
        .attrs = [_]Attribute{
            Attribute{ .key = "attr_0", .value = AttributeValue{ .string = "value_0" } },
            Attribute{ .key = "attr_1", .value = AttributeValue{ .string = "value_1" } },
            Attribute{ .key = "attr_2", .value = AttributeValue{ .string = "value_2" } },
            Attribute{ .key = "attr_3", .value = AttributeValue{ .string = "value_3" } },
            Attribute{ .key = "attr_4", .value = AttributeValue{ .string = "value_4" } },
            Attribute{ .key = "attr_5", .value = AttributeValue{ .string = "value_5" } },
            Attribute{ .key = "attr_6", .value = AttributeValue{ .string = "value_6" } },
            Attribute{ .key = "attr_7", .value = AttributeValue{ .string = "value_7" } },
            Attribute{ .key = "attr_8", .value = AttributeValue{ .string = "value_8" } },
            Attribute{ .key = "attr_9", .value = AttributeValue{ .string = "value_9" } },
        },
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_Emit_With_Many_Attributes", &many_attributes, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_Concurrent_Emission" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
    };
    const logger = try ctx.provider.getLogger(scope);

    const bench_config = zbench.Config{
        .iterations = 10_000,
        .max_iterations = 100_000,
        .time_budget_ns = 2_000_000_000, // 2 seconds
        .track_allocations = true,
    };

    const concurrent_logs = struct {
        logger: *Logger,

        pub fn run(self: @This(), allocator: std.mem.Allocator) void {
            const thread_count = 4;
            const threads = allocator.alloc(std.Thread, thread_count) catch return;
            defer allocator.free(threads);

            const worker = struct {
                fn work(l: *Logger, thread_id: usize) void {
                    for (0..10) |i| {
                        var buf: [32]u8 = undefined;
                        const message = std.fmt.bufPrint(&buf, "thread {} log {}", .{ thread_id, i }) catch "log";
                        l.emit(9, "INFO", message, null);
                    }
                }
            };

            for (threads, 0..) |*thread, i| {
                thread.* = std.Thread.spawn(.{}, worker.work, .{ self.logger, i }) catch {
                    continue;
                };
            }

            for (threads) |thread| {
                thread.join();
            }
        }
    }{ .logger = logger };

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    try bench.addParam("Logger_Concurrent_Emission", &concurrent_logs, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}

test "Logger_GetLogger_Same_Scope" {
    const ctx = try BenchmarkContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const scope = InstrumentationScope{
        .name = "benchmark.logs",
        .version = "1.0.0",
    };

    const get_logger = struct {
        provider: *LoggerProvider,
        scope: InstrumentationScope,

        pub fn run(self: @This(), _: std.mem.Allocator) void {
            _ = self.provider.getLogger(self.scope) catch return;
        }
    }{
        .provider = ctx.provider,
        .scope = scope,
    };

    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.addParam("Logger_GetLogger_Same_Scope", &get_logger, .{});

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buffer);
    try bench.run(&writer.interface);
    try writer.interface.flush();
}
