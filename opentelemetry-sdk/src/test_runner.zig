// Custom test runner for OpenTelemetry SDK — Zig 0.16
// Based on https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const test_options = @import("test_options");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

// Thread-safe log buffer for capturing test logs
const LogCapture = struct {
    mutex: std.Io.Mutex = .init,
    buffer: std.ArrayList(u8),
    allocator: Allocator,
    io: std.Io,
    enabled: bool = false,

    fn init(allocator: Allocator, io: std.Io) LogCapture {
        return .{
            .buffer = std.ArrayList(u8).empty,
            .allocator = allocator,
            .io = io,
        };
    }

    fn deinit(self: *LogCapture) void {
        self.buffer.deinit(self.allocator);
    }

    fn enable(self: *LogCapture) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.enabled = true;
        self.buffer.clearRetainingCapacity();
    }

    fn disable(self: *LogCapture) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.enabled = false;
    }

    fn write(self: *LogCapture, bytes: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.enabled) {
            self.buffer.appendSlice(self.allocator, bytes) catch {};
        }
    }

    fn getContents(self: *LogCapture) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.buffer.items;
    }

    fn contains(self: *LogCapture, needle: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return std.mem.indexOf(u8, self.buffer.items, needle) != null;
    }
};

var log_capture: ?*LogCapture = null;

// Custom log function that captures output instead of writing to stderr
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (log_capture) |capture| {
        if (capture.enabled) {
            var buf: [4096]u8 = undefined;
            const level_txt = comptime level.asText();
            const scope_txt = if (scope == .default) "" else @tagName(scope);

            const prefix = if (scope == .default)
                std.fmt.bufPrint(&buf, "[{s}]: ", .{level_txt}) catch return
            else
                std.fmt.bufPrint(&buf, "[{s}] ({s}): ", .{ scope_txt, level_txt }) catch return;

            capture.write(prefix);

            const msg = std.fmt.bufPrint(buf[prefix.len..], format, args) catch return;
            capture.write(msg);
            capture.write("\n");
            return;
        }
    }

    std.log.defaultLog(level, scope, format, args);
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn main(init: std.process.Init) !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const allocator = fba.allocator();

    const env = Env.init(init.environ_map);

    std.testing.io_instance = .init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
    });
    defer std.testing.io_instance.deinit();

    const io = std.testing.io;

    // Initialize log capture
    var capture = LogCapture.init(allocator, io);
    defer capture.deinit();
    log_capture = &capture;
    defer log_capture = null;

    var slowest = SlowTracker.init(allocator, io, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            capture.enable();
            defer capture.disable();

            t.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                const logs = capture.getContents();
                if (logs.len > 0) {
                    Printer.fmt("Captured logs:\n{s}\n", .{logs});
                }
                return err;
            };
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming(io);

        const is_unnamed_test = isUnnamed(t);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, t.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = t.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .{};

        capture.enable();
        const result = t.func();
        const captured_logs = capture.getContents();
        capture.disable();

        current_test = null;

        const ns_taken = slowest.endTiming(io, friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });

                // Show captured logs for failed tests
                if (captured_logs.len > 0) {
                    Printer.fmt("Captured logs:\n{s}\n", .{captured_logs});
                }

                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (test_options.fail_first) {
                    break;
                }
            },
        }

        if (test_options.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;

            // For passing tests that logged warnings/errors, optionally show them in verbose mode
            if (status == .pass and captured_logs.len > 0) {
                if (std.mem.indexOf(u8, captured_logs, "(warn):") != null or
                    std.mem.indexOf(u8, captured_logs, "(err):") != null or
                    std.mem.indexOf(u8, captured_logs, "(error):") != null or
                    std.mem.indexOf(u8, captured_logs, "[warning]:") != null or
                    std.mem.indexOf(u8, captured_logs, "[error]:") != null)
                {
                    Printer.status(status, "{s} ({d:.2}ms) [with log output]\n", .{ friendly_name, ms });
                    if (test_options.show_logs) {
                        Printer.fmt("  Log output:\n", .{});
                        var iter = std.mem.splitScalar(u8, captured_logs, '\n');
                        while (iter.next()) |line| {
                            if (line.len > 0) {
                                Printer.fmt("    {s}\n", .{line});
                            }
                        }
                    }
                } else {
                    Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
                }
            } else {
                Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
            }
        } else {
            Printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            capture.enable();
            defer capture.disable();

            t.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                const logs = capture.getContents();
                if (logs.len > 0) {
                    Printer.fmt("Captured logs:\n{s}\n", .{logs});
                }
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    max: usize,
    slowest: SlowestQueue,
    start: Io.Timestamp,
    allocator: Allocator,

    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);

    fn init(allocator: Allocator, io: Io, count: u32) SlowTracker {
        const timestamp = Io.Clock.awake.now(io);
        var slowest: SlowestQueue = .empty;
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .max = count,
            .start = timestamp,
            .slowest = slowest,
            .allocator = allocator,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker) void {
        self.slowest.deinit(self.allocator);
    }

    fn startTiming(self: *SlowTracker, io: Io) void {
        self.start = Io.Clock.awake.now(io);
    }

    fn endTiming(self: *SlowTracker, io: Io, test_name: []const u8) u64 {
        const timestamp = Io.Clock.awake.now(io);
        const start = self.start;
        self.start = timestamp;
        const ns: u64 = @intCast(start.durationTo(timestamp).toNanoseconds());

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                return ns;
            }
        }

        _ = slowest.popMin();
        slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    filter: ?[]const u8,

    fn init(map: *const std.process.Environ.Map) Env {
        return .{
            .filter = readEnv(map, "TEST_FILTER"),
        };
    }

    fn readEnv(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
        return map.get(key);
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}
