const std = @import("std");
const sdk = @import("opentelemetry-sdk");

// Override std.log to use OpenTelemetry bridge
pub const std_options: std.Options = .{
    .logFn = sdk.logs.std_log_bridge.logFn,
};

// Define custom log scopes for different parts of the application
const log = struct {
    pub const http = std.log.scoped(.http);
    pub const database = std.log.scoped(.database);
    pub const auth = std.log.scoped(.auth);
    pub const cache = std.log.scoped(.cache);
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("OpenTelemetry std.log Bridge - Per-Scope Example\n", .{});
    std.debug.print("=================================================\n\n", .{});
    std.debug.print("This example demonstrates per-scope logging:\n", .{});
    std.debug.print("- Each Zig log scope gets its own OpenTelemetry Logger\n", .{});
    std.debug.print("- Allows fine-grained control and filtering per component\n\n", .{});

    // Create a stdout exporter
    const stdout_file = std.fs.File.stdout();
    var stdout_exporter = sdk.logs.StdoutExporter.init(stdout_file.deprecatedWriter());
    const exporter = stdout_exporter.asLogRecordExporter();

    // Create a simple processor
    var simple_processor = sdk.logs.SimpleLogRecordProcessor.init(allocator, exporter);
    const processor = simple_processor.asLogRecordProcessor();

    // Create a logger provider
    var provider = try sdk.logs.LoggerProvider.init(allocator, null);
    defer provider.deinit();

    // Add the processor
    try provider.addLogRecordProcessor(processor);

    // Configure the std.log bridge with PER-SCOPE strategy
    try sdk.logs.std_log_bridge.configure(.{
        .provider = provider,
        .scope_strategy = .per_zig_scope, // Each Zig scope gets its own Logger
        .also_log_to_stderr = false,
        .include_scope_attribute = true,
        .include_source_location = true,
    });
    defer sdk.logs.std_log_bridge.shutdown();

    std.debug.print("Starting application with per-scope logging...\n\n", .{});

    // Use different scopes - each will create a separate Logger
    try simulateHttpServer();
    try simulateDatabaseOperations();
    try simulateAuthentication();

    std.debug.print("\n\nShutting down...\n", .{});

    // Shutdown (flushes all pending logs)
    try provider.shutdown();

    std.debug.print("Done!\n", .{});
}

fn simulateHttpServer() !void {
    // These logs will use the "http" scope -> Logger with scope "http"
    log.http.info("HTTP server starting on port 8080", .{});
    log.http.debug("Registering routes", .{});

    // Simulate some requests
    log.http.info("GET /api/users - 200 OK - 45ms", .{});
    log.http.info("POST /api/users - 201 Created - 120ms", .{});
    log.http.warn("GET /api/slow - 200 OK - 2500ms (slow request)", .{});
    log.http.err("POST /api/error - 500 Internal Server Error", .{});
}

fn simulateDatabaseOperations() !void {
    // These logs will use the "database" scope -> Logger with scope "database"
    log.database.info("Connecting to PostgreSQL database", .{});
    log.database.debug("Connection pool initialized with 10 connections", .{});

    // Simulate queries
    log.database.debug("Executing query: SELECT * FROM users WHERE id = $1", .{});
    log.database.info("Query executed successfully in 12ms", .{});

    log.database.debug("Starting transaction", .{});
    log.database.debug("INSERT INTO orders VALUES ($1, $2, $3)", .{});
    log.database.debug("UPDATE inventory SET quantity = quantity - 1", .{});
    log.database.info("Transaction committed successfully", .{});

    // Simulate a slow query
    log.database.warn("Slow query detected: took 3500ms", .{});
}

fn simulateAuthentication() !void {
    // These logs will use the "auth" scope -> Logger with scope "auth"
    log.auth.info("Authentication service initialized", .{});
    log.auth.debug("Loading JWT signing keys", .{});

    // Simulate auth attempts
    log.auth.info("User login attempt: username=alice", .{});
    log.auth.debug("Validating password hash", .{});
    log.auth.info("User authenticated successfully: user_id=12345", .{});

    // Failed attempt
    log.auth.warn("Failed login attempt: username=bob (invalid password)", .{});
    log.auth.warn("Multiple failed attempts detected for username=bob", .{});

    // Token operations
    log.auth.debug("Generating JWT token for user_id=12345", .{});
    log.auth.info("Access token generated, expires in 3600s", .{});
}
