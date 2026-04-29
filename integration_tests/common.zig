const std = @import("std");
const clock = @import("clock");

pub const COLLECTOR_HTTP_PORT = "4318";
pub const COLLECTOR_GRPC_PORT = "4317";

/// Context for running integration tests with a containerized collector
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    tmp_subpath: []const u8,
    container_name: []const u8,

    pub fn deinit(self: *TestContext) void {
        self.allocator.free(self.container_name);
        self.allocator.free(self.tmp_subpath);
    }
};

/// Generate a unique container name to avoid conflicts when running tests in parallel
pub fn generateContainerName(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = clock.milliTimestamp();
    var prng = std.Random.DefaultPrng.init(@intCast(timestamp));
    const random_suffix = prng.random().int(u32);
    return std.fmt.allocPrint(allocator, "otel-test-{s}-{d}-{x}", .{ test_name, timestamp, random_suffix });
}

pub fn checkDockerAvailable(allocator: std.mem.Allocator, io: std.Io) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "docker", "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited != 0) {
        std.debug.print("Docker is not available. Please install Docker.\n", .{});
        return error.DockerNotAvailable;
    }
}

pub fn startCollectorContainer(allocator: std.mem.Allocator, io: std.Io, container_name: []const u8, data_path: []const u8) !void {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "integration_tests", "otel-collector-config.yaml" });
    defer allocator.free(config_path);

    const config_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/etc/otel-collector-config.yaml:ro", .{config_path});
    defer allocator.free(config_mount_arg);

    const data_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/tmp/otel-data", .{data_path});
    defer allocator.free(data_mount_arg);

    const grpc_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_GRPC_PORT, COLLECTOR_GRPC_PORT });
    defer allocator.free(grpc_port_arg);

    const http_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_HTTP_PORT, COLLECTOR_HTTP_PORT });
    defer allocator.free(http_port_arg);

    const result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{
            "docker",
            "run",
            "-d",
            "--name",
            container_name,
            "-p",
            grpc_port_arg,
            "-p",
            http_port_arg,
            "-v",
            config_mount_arg,
            "-v",
            data_mount_arg,
            "otel/opentelemetry-collector:latest",
            "--config=/etc/otel-collector-config.yaml",
        },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited != 0) {
        std.debug.print("Failed to start collector container.\n", .{});
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.ContainerStartFailed;
    }
}

pub fn waitForCollector(allocator: std.mem.Allocator, io: std.Io, container_name: []const u8) !void {
    const max_retries = 30;
    var retry: usize = 0;

    while (retry < max_retries) : (retry += 1) {
        const result = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{
                "docker",
                "inspect",
                "-f",
                "{{.State.Running}}",
                container_name,
            },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term == .exited and result.term.exited == 0 and std.mem.startsWith(u8, result.stdout, "true")) {
            clock.sleep(2 * std.time.ns_per_s);
            return;
        }

        clock.sleep(1 * std.time.ns_per_s);
    }

    return error.CollectorNotReady;
}

pub fn cleanupContainer(allocator: std.mem.Allocator, io: std.Io, container_name: []const u8) !void {
    const stop_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "docker", "stop", container_name },
    });
    defer allocator.free(stop_result.stdout);
    defer allocator.free(stop_result.stderr);

    const rm_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "docker", "rm", container_name },
    });
    defer allocator.free(rm_result.stdout);
    defer allocator.free(rm_result.stderr);
}

pub fn readJsonFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8) ![]const u8 {
    const file = try dir.openFile(io, file_name, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const content = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(content);
    const read_len = try file.readPositionalAll(io, content, 0);

    if (read_len != stat.size) {
        const shrunk = try allocator.realloc(content, read_len);
        return shrunk;
    }
    return content;
}

pub fn waitForFile(io: std.Io, dir: std.Io.Dir, file_name: []const u8, max_retries: usize) !void {
    var retry: usize = 0;
    while (retry < max_retries) : (retry += 1) {
        const file = dir.openFile(io, file_name, .{}) catch |err| {
            if (err == error.FileNotFound and retry < max_retries - 1) {
                clock.sleep(1 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.size > 0) {
            return;
        }

        if (retry < max_retries - 1) {
            clock.sleep(1 * std.time.ns_per_s);
        }
    }
    return error.FileNotFound;
}

pub fn waitForFileContent(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file_name: []const u8, expected_content: []const u8, max_retries: usize) ![]const u8 {
    var retry: usize = 0;
    while (retry < max_retries) : (retry += 1) {
        const content = readJsonFile(allocator, io, dir, file_name) catch |err| {
            if (err == error.FileNotFound and retry < max_retries - 1) {
                clock.sleep(1 * std.time.ns_per_s);
                continue;
            }
            return err;
        };

        if (std.mem.indexOf(u8, content, expected_content) != null) {
            return content;
        }

        allocator.free(content);
        if (retry < max_retries - 1) {
            clock.sleep(1 * std.time.ns_per_s);
        }
    }
    return error.ExpectedContentNotFound;
}

pub fn setupTestContext(allocator: std.mem.Allocator, io: std.Io, test_name: []const u8) !TestContext {
    std.debug.print("Checking container availability...\n", .{});
    try checkDockerAvailable(allocator, io);
    std.debug.print("✓ Docker daemon is available\n\n", .{});

    std.debug.print("Setting up data directory...\n", .{});

    var random_bytes: [12]u8 = undefined;
    var io_source = std.Random.IoSource{ .io = io };
    io_source.interface().bytes(&random_bytes);
    var sub_path_buf: [std.base64.url_safe.Encoder.calcSize(12)]u8 = undefined;
    const sub_path = std.base64.url_safe.Encoder.encode(&sub_path_buf, &random_bytes);
    const tmp_subpath = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/otel-test-{s}-{s}", .{ test_name, sub_path });
    errdefer allocator.free(tmp_subpath);

    try std.Io.Dir.cwd().createDirPath(io, tmp_subpath);
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_subpath, .{ .iterate = true });
    errdefer {
        tmp_dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, tmp_subpath) catch {};
    }

    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const tmp_path = try std.fs.path.join(allocator, &.{ cwd, tmp_subpath });
    defer allocator.free(tmp_path);

    const chmod_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "chmod", "777", tmp_path },
    });
    defer allocator.free(chmod_result.stdout);
    defer allocator.free(chmod_result.stderr);

    if (chmod_result.term == .exited and chmod_result.term.exited != 0) {
        return error.ChmodFailed;
    }

    std.debug.print("✓ Data directory ready: {s}\n\n", .{tmp_path});

    const container_name = try generateContainerName(allocator, test_name);
    errdefer allocator.free(container_name);

    cleanupContainer(allocator, io, container_name) catch {};

    std.debug.print("Starting OTLP collector container: {s}\n", .{container_name});
    try startCollectorContainer(allocator, io, container_name, tmp_path);

    std.debug.print("Waiting for collector to be ready...\n", .{});
    try waitForCollector(allocator, io, container_name);
    std.debug.print("✓ Collector is ready\n\n", .{});

    return TestContext{
        .allocator = allocator,
        .tmp_dir = tmp_dir,
        .tmp_subpath = tmp_subpath,
        .container_name = container_name,
    };
}

pub fn cleanupTestContext(ctx: *TestContext, io: std.Io) void {
    cleanupContainer(ctx.allocator, io, ctx.container_name) catch |err| {
        std.debug.print("Warning: Failed to cleanup container: {}\n", .{err});
    };
    ctx.tmp_dir.close(io);
    std.Io.Dir.cwd().deleteTree(io, ctx.tmp_subpath) catch |err| {
        std.debug.print("Warning: Failed to cleanup temp dir: {}\n", .{err});
    };
    ctx.deinit();
}
