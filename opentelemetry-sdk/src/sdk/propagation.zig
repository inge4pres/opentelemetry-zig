//! OpenTelemetry Propagation Module
//!
//! This module provides a registry for context propagators and a composite
//! propagator that uses configured propagators based on OTEL_PROPAGATORS.
//!
//! The propagation system allows for inject/extract operations across service
//! boundaries using various propagation formats (W3C Trace Context, W3C Baggage,
//! B3, Jaeger, etc.).

const std = @import("std");
const Configuration = @import("config.zig").Configuration;
const TracePropagator = @import("config.zig").TracePropagator;
const baggage_propagator = @import("../api/baggage/propagator.zig");
const Baggage = @import("../api/baggage.zig").Baggage;
const trace_propagator = @import("../api/trace/propagator.zig");
const SpanContext = @import("../api/trace.zig").SpanContext;
const propagation = @import("../api/propagation.zig");
const trace_api = @import("../api/trace.zig");
const TracerProvider = @import("trace/provider.zig").TracerProvider;
const RandomIDGenerator = @import("trace/id_generator.zig").RandomIDGenerator;

// Note: Generic TextMapPropagator interface is challenging in Zig due to
// limitations with anytype in function pointers. Instead, we use direct
// delegation to specific propagator implementations in CompositePropagator.

/// Propagator registry for managing available propagators
pub const PropagatorRegistry = struct {
    allocator: std.mem.Allocator,
    baggage_enabled: bool,
    tracecontext_enabled: bool,
    // Future: Add other propagator types here
    // b3_enabled: bool,
    // etc.

    const Self = @This();

    /// Initialize the propagator registry from configuration.
    /// Copies the enabled flags; does not retain the configuration.
    pub fn init(allocator: std.mem.Allocator, config: *const Configuration) !Self {
        var baggage_enabled = false;
        var tracecontext_enabled = false;

        // Check which propagators are configured
        for (config.trace_propagators) |prop| {
            switch (prop) {
                .baggage => baggage_enabled = true,
                .tracecontext => tracecontext_enabled = true,
                .b3, .b3multi => {
                    // TODO: Enable when B3 propagator is implemented
                    std.log.warn("B3 propagator not yet implemented", .{});
                },
                .jaeger => {
                    // TODO: Enable when Jaeger propagator is implemented
                    std.log.warn("Jaeger propagator not yet implemented", .{});
                },
                .xray => {
                    // TODO: Enable when X-Ray propagator is implemented
                    std.log.warn("X-Ray propagator not yet implemented", .{});
                },
                .ottrace => {
                    // TODO: Enable when OT Trace propagator is implemented
                    std.log.warn("OT Trace propagator not yet implemented", .{});
                },
                .none => {}, // Explicitly disabled
            }
        }

        return Self{
            .allocator = allocator,
            .baggage_enabled = baggage_enabled,
            .tracecontext_enabled = tracecontext_enabled,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

/// Composite propagator that delegates to multiple propagators
///
/// This propagator injects and extracts using all configured propagators
/// in the order they are specified in OTEL_PROPAGATORS.
pub const CompositePropagator = struct {
    allocator: std.mem.Allocator,
    registry: PropagatorRegistry,

    const Self = @This();

    /// Create a composite propagator from configuration.
    /// Borrows the configuration for the duration of the call.
    pub fn initFromConfig(allocator: std.mem.Allocator, config: *const Configuration) !Self {
        const registry = try PropagatorRegistry.init(allocator, config);

        return Self{
            .allocator = allocator,
            .registry = registry,
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
    }

    /// Inject baggage into HTTP headers carrier
    ///
    /// This will call inject on all enabled propagators for the given context type.
    pub fn injectBaggage(
        self: *Self,
        baggage: Baggage,
        carrier: *std.StringHashMap([]const u8),
    ) !void {
        if (self.registry.baggage_enabled) {
            try baggage_propagator.inject(
                self.allocator,
                baggage,
                carrier,
                baggage_propagator.HttpSetter,
            );
        }
    }

    /// Extract baggage from HTTP headers carrier
    ///
    /// This will call extract on all enabled propagators and merge the results.
    pub fn extractBaggage(
        self: *Self,
        carrier: *const std.StringHashMap([]const u8),
    ) !?Baggage {
        if (self.registry.baggage_enabled) {
            return try baggage_propagator.extract(
                self.allocator,
                carrier,
                baggage_propagator.HttpGetter,
            );
        }
        return null;
    }

    /// Inject a SpanContext into HTTP headers carrier as `traceparent` and `tracestate`
    ///
    /// The injected header values are allocated with the propagator's allocator
    /// and owned by the carrier.
    pub fn injectTraceContext(
        self: *Self,
        span_context: SpanContext,
        carrier: *std.StringHashMap([]const u8),
    ) !void {
        if (self.registry.tracecontext_enabled) {
            try trace_propagator.inject(
                self.allocator,
                span_context,
                carrier,
                propagation.HttpSetter,
            );
        }
    }

    /// Extract a remote SpanContext from HTTP headers carrier
    ///
    /// Returns null when trace context propagation is disabled or the carrier
    /// has no valid `traceparent`. Release the returned TraceState with
    /// `trace_state.deinit()`.
    pub fn extractTraceContext(
        self: *Self,
        carrier: *const std.StringHashMap([]const u8),
    ) !?SpanContext {
        if (self.registry.tracecontext_enabled) {
            return try trace_propagator.extract(
                self.allocator,
                carrier,
                propagation.HttpGetter,
            );
        }
        return null;
    }

    /// Get the list of all fields that might be read or written by this propagator
    pub fn fields(self: *Self) ![]const []const u8 {
        var field_list: std.ArrayList([]const u8) = .empty;
        errdefer field_list.deinit(self.allocator);

        if (self.registry.tracecontext_enabled) {
            try field_list.appendSlice(self.allocator, trace_propagator.fields());
        }

        if (self.registry.baggage_enabled) {
            try field_list.append(self.allocator, baggage_propagator.baggage_header);
        }

        return try field_list.toOwnedSlice(self.allocator);
    }
};

/// Create a global composite propagator from environment configuration
///
/// This is a convenience function that creates a composite propagator using
/// the global configuration singleton. If no global configuration exists,
/// it will initialize one from the supplied environment map and install it.
/// The returned propagator does not retain the configuration.
/// Release an installed singleton at shutdown with Configuration.deinitGlobal().
pub fn createGlobalPropagator(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !CompositePropagator {
    const config = Configuration.get() orelse blk: {
        // No global config exists, create and set one.
        const new_config = try Configuration.init(allocator, io, env_map);
        Configuration.set(new_config);
        break :blk new_config;
    };
    // Do not deinit here. The configuration is owned by the caller or the
    // singleton and may be referenced by other providers.
    return try CompositePropagator.initFromConfig(allocator, config);
}

// Tests

test "PropagatorRegistry initialization with baggage" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{.baggage},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var registry = try PropagatorRegistry.init(allocator, &config);
    defer registry.deinit();

    try std.testing.expect(registry.baggage_enabled);
    try std.testing.expect(!registry.tracecontext_enabled);
}

test "PropagatorRegistry initialization with multiple propagators" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{ .tracecontext, .baggage },
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var registry = try PropagatorRegistry.init(allocator, &config);
    defer registry.deinit();

    try std.testing.expect(registry.baggage_enabled);
    try std.testing.expect(registry.tracecontext_enabled);
}

test "PropagatorRegistry with none" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{.none},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var registry = try PropagatorRegistry.init(allocator, &config);
    defer registry.deinit();

    try std.testing.expect(!registry.baggage_enabled);
    try std.testing.expect(!registry.tracecontext_enabled);
}

test "CompositePropagator inject and extract baggage" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{.baggage},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    // Create baggage
    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    defer baggage.deinit();

    // Inject into headers
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var value_it = headers.valueIterator();
        while (value_it.next()) |value| {
            allocator.free(value.*);
        }
        headers.deinit();
    }

    try propagator.injectBaggage(baggage, &headers);

    // Verify header was set
    try std.testing.expect(headers.get("baggage") != null);

    // Extract from headers
    var extracted = (try propagator.extractBaggage(&headers)).?;
    defer extracted.deinit();

    const entry = extracted.getValue("user_id").?;
    try std.testing.expectEqualStrings("alice", entry.value);
}

test "CompositePropagator with baggage disabled" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{.none},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    // Create baggage
    var baggage = Baggage.init();
    try baggage.setValue(allocator, "user_id", "alice", null);
    defer baggage.deinit();

    // Inject should do nothing
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try propagator.injectBaggage(baggage, &headers);

    // Verify no header was set
    try std.testing.expect(headers.get("baggage") == null);

    // Extract should return null
    const extracted = try propagator.extractBaggage(&headers);
    try std.testing.expect(extracted == null);
}

test "CompositePropagator fields list" {
    const allocator = std.testing.allocator;

    var config = Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = &[_]TracePropagator{.baggage},
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };

    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    const field_list = try propagator.fields();
    defer allocator.free(field_list);

    try std.testing.expectEqual(@as(usize, 1), field_list.len);
    try std.testing.expectEqualStrings("baggage", field_list[0]);
}

test "createGlobalPropagator leaves a caller-owned Configuration alive" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cfg = try Configuration.init(allocator, std.testing.io, &env_map);
    defer cfg.deinit();
    Configuration.set(cfg);

    var propagator = try createGlobalPropagator(allocator, std.testing.io, &env_map);
    defer propagator.deinit();

    // Verify the singleton was not released.
    try std.testing.expectEqual(@as(?*const Configuration, cfg), Configuration.get());

    // Verify the cached configuration is still readable.
    try std.testing.expectEqual(@as(u32, 2048), cfg.trace_config.bsp_max_queue_size);
}

test "createGlobalPropagator installs a Configuration when none exists" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    // Only release what this test installed.
    const before = Configuration.get();

    var propagator = try createGlobalPropagator(allocator, std.testing.io, &env_map);
    defer propagator.deinit();

    try std.testing.expect(Configuration.get() != null);

    if (before == null) Configuration.deinitGlobal();
}

fn testConfig(allocator: std.mem.Allocator, propagators: []const TracePropagator) Configuration {
    return Configuration{
        .allocator = allocator,
        .sdk_disabled = false,
        .service_name = null,
        .resource_attributes = null,
        .log_level = .info,
        .trace_propagators = propagators,
        .trace_config = undefined,
        .metrics_config = undefined,
        .logs_config = undefined,
    };
}

fn freeInjectedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var value_it = headers.valueIterator();
    while (value_it.next()) |value| {
        allocator.free(value.*);
    }
    headers.deinit();
}

test "CompositePropagator inject and extract trace context" {
    const allocator = std.testing.allocator;

    var config = testConfig(allocator, &[_]TracePropagator{.tracecontext});
    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    var trace_state = trace_api.TraceState.init(allocator);
    defer trace_state.deinit();
    const span_context = trace_api.SpanContext.init(
        try trace_api.TraceID.fromHex("0af7651916cd43dd8448eb211c80319c"),
        try trace_api.SpanID.fromHex("b7ad6b7169203331"),
        trace_api.TraceFlags.sampled(),
        trace_state,
        false,
    );

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer freeInjectedHeaders(allocator, &headers);

    try propagator.injectTraceContext(span_context, &headers);
    try std.testing.expectEqualStrings(
        "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        headers.get("traceparent").?,
    );

    var extracted = (try propagator.extractTraceContext(&headers)).?;
    defer extracted.trace_state.deinit();

    try std.testing.expectEqualSlices(u8, &span_context.trace_id.value, &extracted.trace_id.value);
    try std.testing.expectEqualSlices(u8, &span_context.span_id.value, &extracted.span_id.value);
    try std.testing.expect(extracted.isRemote());
}

test "CompositePropagator with trace context disabled" {
    const allocator = std.testing.allocator;

    var config = testConfig(allocator, &[_]TracePropagator{.baggage});
    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    var trace_state = trace_api.TraceState.init(allocator);
    defer trace_state.deinit();
    const span_context = trace_api.SpanContext.init(
        try trace_api.TraceID.fromHex("0af7651916cd43dd8448eb211c80319c"),
        try trace_api.SpanID.fromHex("b7ad6b7169203331"),
        trace_api.TraceFlags.sampled(),
        trace_state,
        false,
    );

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer freeInjectedHeaders(allocator, &headers);

    try propagator.injectTraceContext(span_context, &headers);
    try std.testing.expectEqual(@as(u32, 0), headers.count());

    try headers.put("traceparent", try allocator.dupe(u8, "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"));
    try std.testing.expect(try propagator.extractTraceContext(&headers) == null);
}

test "CompositePropagator fields list with trace context and baggage" {
    const allocator = std.testing.allocator;

    var config = testConfig(allocator, &[_]TracePropagator{ .tracecontext, .baggage });
    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    const field_list = try propagator.fields();
    defer allocator.free(field_list);

    try std.testing.expectEqual(@as(usize, 3), field_list.len);
    try std.testing.expectEqualStrings("traceparent", field_list[0]);
    try std.testing.expectEqualStrings("tracestate", field_list[1]);
    try std.testing.expectEqualStrings("baggage", field_list[2]);
}

test "extracted trace context parents a server span that is injected downstream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var config = testConfig(allocator, &[_]TracePropagator{.tracecontext});
    var propagator = try CompositePropagator.initFromConfig(allocator, &config);
    defer propagator.deinit();

    var default_prng = std.Random.DefaultPrng.init(0);
    var provider = try TracerProvider.init(allocator, io, .{ .Random = RandomIDGenerator.init(default_prng.random()) });
    defer provider.shutdown();
    const tracer = try provider.getTracer(.{ .name = "test-tracer", .version = "1.0.0" });

    // Incoming request from an upstream service
    var incoming = std.StringHashMap([]const u8).init(allocator);
    defer incoming.deinit();
    try incoming.put("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");
    try incoming.put("tracestate", "rojo=00f067aa0ba902b7");

    var span = blk: {
        var remote = (try propagator.extractTraceContext(&incoming)).?;
        defer remote.trace_state.deinit();

        var parent_context = try trace_api.insertSpanContext(allocator, remote);
        defer {
            trace_api.freeSerializedSpanContext(allocator, parent_context);
            parent_context.deinit();
        }

        break :blk try tracer.startSpan(allocator, "GET /api", .{ .kind = .Server, .parent_context = parent_context });
    };
    // The remote SpanContext and parent context are released; the span keeps its own TraceState
    defer span.deinit();

    const remote_trace_id = try trace_api.TraceID.fromHex("0af7651916cd43dd8448eb211c80319c");
    const remote_span_id = try trace_api.SpanID.fromHex("b7ad6b7169203331");

    try std.testing.expectEqualSlices(u8, &remote_trace_id.value, &span.span_context.trace_id.value);
    try std.testing.expectEqualSlices(u8, &remote_span_id.value, &span.parent_span_id.?.value);
    try std.testing.expect(span.span_context.trace_flags.isSampled());

    // Outgoing request to a downstream service carries the same trace, with the server span as parent
    var outgoing = std.StringHashMap([]const u8).init(allocator);
    defer freeInjectedHeaders(allocator, &outgoing);
    try propagator.injectTraceContext(span.getContext(), &outgoing);

    var span_id_buf: [16]u8 = undefined;
    const expected = try std.fmt.allocPrint(allocator, "00-0af7651916cd43dd8448eb211c80319c-{s}-01", .{span.span_context.span_id.toHex(&span_id_buf)});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, outgoing.get("traceparent").?);
    try std.testing.expectEqualStrings("rojo=00f067aa0ba902b7", outgoing.get("tracestate").?);

    // Ended spans are non-recording, and must still release their TraceState
    span.end(null);
}
