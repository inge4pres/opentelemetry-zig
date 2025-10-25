const std = @import("std");

pub const COLLECTOR_HTTP_PORT = "4318";
pub const COLLECTOR_GRPC_PORT = "4317";

/// Context for running integration tests with a containerized collector
pub const TestContext = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.fs.Dir,
    container_name: []const u8,

    pub fn deinit(self: *TestContext) void {
        self.allocator.free(self.container_name);
    }
};

/// Generate a unique container name to avoid conflicts when running tests in parallel
pub fn generateContainerName(allocator: std.mem.Allocator, test_name: []const u8) ![]const u8 {
    const timestamp = std.time.milliTimestamp();
    var prng = std.Random.DefaultPrng.init(@intCast(timestamp));
    const random_suffix = prng.random().int(u32);
    return std.fmt.allocPrint(allocator, "otel-test-{s}-{d}-{x}", .{ test_name, timestamp, random_suffix });
}

pub fn checkDockerAvailable(allocator: std.mem.Allocator) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("Docker is not available. Please install Docker.\n", .{});
        return error.DockerNotAvailable;
    }
}

pub fn startCollectorContainer(allocator: std.mem.Allocator, container_name: []const u8, data_path: []const u8) !void {
    // Get the current working directory to mount the config file
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);

    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "integration_tests", "otel-collector-config.yaml" });
    defer allocator.free(config_path);

    const config_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/etc/otel-collector-config.yaml:ro", .{config_path});
    defer allocator.free(config_mount_arg);

    // Mount the data directory for output files
    const data_mount_arg = try std.fmt.allocPrint(allocator, "{s}:/tmp/otel-data", .{data_path});
    defer allocator.free(data_mount_arg);

    const grpc_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_GRPC_PORT, COLLECTOR_GRPC_PORT });
    defer allocator.free(grpc_port_arg);

    const http_port_arg = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ COLLECTOR_HTTP_PORT, COLLECTOR_HTTP_PORT });
    defer allocator.free(http_port_arg);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
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

    if (result.term.Exited != 0) {
        std.debug.print("Failed to start collector container.\n", .{});
        std.debug.print("stderr: {s}\n", .{result.stderr});
        return error.ContainerStartFailed;
    }
}

pub fn waitForCollector(allocator: std.mem.Allocator, container_name: []const u8) !void {
    // Wait up to 30 seconds for the collector to be ready
    const max_retries = 30;
    var retry: usize = 0;

    while (retry < max_retries) : (retry += 1) {
        // Check if container is running
        const result = try std.process.Child.run(.{
            .allocator = allocator,
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

        if (result.term.Exited == 0 and std.mem.startsWith(u8, result.stdout, "true")) {
            // Container is running, wait a bit more for OTLP endpoint to be ready
            std.Thread.sleep(2 * std.time.ns_per_s);
            return;
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }

    return error.CollectorNotReady;
}

pub fn cleanupContainer(allocator: std.mem.Allocator, container_name: []const u8) !void {
    // Stop the container
    const stop_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "stop", container_name },
    });
    defer allocator.free(stop_result.stdout);
    defer allocator.free(stop_result.stderr);

    // Remove the container
    const rm_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "docker", "rm", container_name },
    });
    defer allocator.free(rm_result.stdout);
    defer allocator.free(rm_result.stderr);
}

pub fn readJsonFile(allocator: std.mem.Allocator, dir: std.fs.Dir, file_name: []const u8) ![]const u8 {
    const file = try dir.openFile(file_name, .{});
    defer file.close();

    const max_size = 10 * 1024 * 1024; // 10 MB max
    const content = try file.readToEndAlloc(allocator, max_size);
    return content;
}

pub fn waitForFile(dir: std.fs.Dir, file_name: []const u8, max_retries: usize) !void {
    var retry: usize = 0;
    while (retry < max_retries) : (retry += 1) {
        const file = dir.openFile(file_name, .{}) catch |err| {
            if (err == error.FileNotFound and retry < max_retries - 1) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }
            return err;
        };
        defer file.close();

        // Check if file has content (not just exists but is empty)
        const stat = try file.stat();
        if (stat.size > 0) {
            return;
        }

        // File exists but is empty, wait and retry
        if (retry < max_retries - 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
    return error.FileNotFound;
}

pub fn waitForFileContent(allocator: std.mem.Allocator, dir: std.fs.Dir, file_name: []const u8, expected_content: []const u8, max_retries: usize) ![]const u8 {
    var retry: usize = 0;
    while (retry < max_retries) : (retry += 1) {
        const content = readJsonFile(allocator, dir, file_name) catch |err| {
            if (err == error.FileNotFound and retry < max_retries - 1) {
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            }
            return err;
        };

        // Check if content contains expected string
        if (std.mem.indexOf(u8, content, expected_content) != null) {
            return content;
        }

        // Content doesn't match, free and retry
        allocator.free(content);
        if (retry < max_retries - 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
    return error.ExpectedContentNotFound;
}

/// Setup a test context with a temporary directory and container
pub fn setupTestContext(allocator: std.mem.Allocator, test_name: []const u8) !TestContext {
    // Check if Docker is available
    std.debug.print("Checking container availability...\n", .{});
    try checkDockerAvailable(allocator);
    std.debug.print("✓ Docker daemon is available\n\n", .{});

    // Create temporary directory for output files
    std.debug.print("Setting up data directory...\n", .{});
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    // Get the real path of the temporary directory for Docker mounting
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Make directory writable by all users so the collector container can write to it
    const chmod_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "chmod", "777", tmp_path },
    });
    defer allocator.free(chmod_result.stdout);
    defer allocator.free(chmod_result.stderr);

    if (chmod_result.term.Exited != 0) {
        return error.ChmodFailed;
    }

    std.debug.print("✓ Data directory ready: {s}\n\n", .{tmp_path});

    // Generate unique container name
    const container_name = try generateContainerName(allocator, test_name);
    errdefer allocator.free(container_name);

    // Clean up any previous test containers with the same name (just in case)
    cleanupContainer(allocator, container_name) catch {};

    // Start the OTLP collector container
    std.debug.print("Starting OTLP collector container: {s}\n", .{container_name});
    try startCollectorContainer(allocator, container_name, tmp_path);

    // Wait for collector to be ready
    std.debug.print("Waiting for collector to be ready...\n", .{});
    try waitForCollector(allocator, container_name);
    std.debug.print("✓ Collector is ready\n\n", .{});

    return TestContext{
        .allocator = allocator,
        .tmp_dir = tmp.dir,
        .container_name = container_name,
    };
}

/// Cleanup test context and remove container
pub fn cleanupTestContext(ctx: *TestContext) void {
    cleanupContainer(ctx.allocator, ctx.container_name) catch |err| {
        std.debug.print("Warning: Failed to cleanup container: {}\n", .{err});
    };
    ctx.deinit();
}
