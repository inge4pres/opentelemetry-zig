// Custom test runner for OpenTelemetry SDK
// https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b
// Modified to capture log output and prevent stderr messages during tests

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

// Thread-safe log buffer for capturing test logs
const LogCapture = struct {
    mutex: std.Thread.Mutex = .{},
    buffer: std.ArrayList(u8),
    enabled: bool = false,

    fn init(allocator: Allocator) LogCapture {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    fn deinit(self: *LogCapture) void {
        self.buffer.deinit();
    }

    fn enable(self: *LogCapture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = true;
        self.buffer.clearRetainingCapacity();
    }

    fn disable(self: *LogCapture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = false;
    }

    fn write(self: *LogCapture, bytes: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.enabled) {
            self.buffer.appendSlice(bytes) catch {};
        }
    }

    fn getContents(self: *LogCapture) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.items;
    }

    fn contains(self: *LogCapture, needle: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
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
    // During tests, capture log output instead of writing to stderr
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

    // If not capturing, use default log
    std.log.defaultLog(level, scope, format, args);
}

// Override std_options to use our custom log function
pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Initialize log capture
    var capture = LogCapture.init(allocator);
    defer capture.deinit();
    log_capture = &capture;
    defer log_capture = null;

    const env = Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const printer = Printer.init();
    printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    // Run setup tests
    for (builtin.test_functions) |t| {
        if (isSetup(t)) {
            capture.enable();
            defer capture.disable();

            t.func() catch |err| {
                printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                const logs = capture.getContents();
                if (logs.len > 0) {
                    printer.fmt("Captured logs:\n{s}\n", .{logs});
                }
                return err;
            };
        }
    }

    // Run main tests
    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

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

        // Enable log capture for this test
        capture.enable();
        const result = t.func();
        const captured_logs = capture.getContents();
        capture.disable();

        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() == .leak) {
            leak += 1;
            printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;

            // For passing tests that logged warnings/errors, optionally show them in verbose mode
            if (env.verbose and captured_logs.len > 0) {
                // Check if there are any warnings or errors in the captured logs
                if (std.mem.indexOf(u8, captured_logs, "(warn)") != null or
                    std.mem.indexOf(u8, captured_logs, "(err)") != null)
                {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    printer.status(status, "{s} ({d:.2}ms) [with log output]\n", .{ friendly_name, ms });
                    if (env.show_logs) {
                        printer.fmt("  Log output:\n", .{});
                        var iter = std.mem.splitScalar(u8, captured_logs, '\n');
                        while (iter.next()) |line| {
                            if (line.len > 0) {
                                printer.fmt("    {s}\n", .{line});
                            }
                        }
                    }
                } else {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
                }
            } else if (env.verbose) {
                const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
            } else {
                printer.status(status, ".", .{});
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });

                // Show captured logs for failed tests
                if (captured_logs.len > 0) {
                    printer.fmt("Captured logs:\n{s}\n", .{captured_logs});
                }

                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }
    }

    // Run teardown tests
    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            capture.enable();
            defer capture.disable();

            t.func() catch |err| {
                printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                const logs = capture.getContents();
                if (logs.len > 0) {
                    printer.fmt("Captured logs:\n{s}\n", .{logs});
                }
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    printer.fmt("\n", .{});
    try slowest.display(printer);
    printer.fmt("\n", .{});
    std.posix.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    out: std.fs.File.Writer,

    fn init() Printer {
        return .{
            .out = std.io.getStdErr().writer(),
        };
    }

    fn fmt(self: Printer, comptime format: []const u8, args: anytype) void {
        std.fmt.format(self.out, format, args) catch unreachable;
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) void {
        const color = switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        };
        const out = self.out;
        out.writeAll(color) catch @panic("writeAll failed?!");
        std.fmt.format(out, format, args) catch @panic("std.fmt.format failed?!");
        self.fmt("\x1b[0m", .{});
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        var timer = self.timer;
        const ns = timer.lap();

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker, printer: Printer) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    show_logs: bool,
    filter: ?[]const u8,

    fn init(allocator: Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", false),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .show_logs = readEnvBool(allocator, "TEST_SHOW_LOGS", false),
            .filter = readEnv(allocator, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

// Don't override panic for now - just track the current test
// pub const panic = ...

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
