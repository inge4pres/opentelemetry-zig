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

// Note: Generic TextMapPropagator interface is challenging in Zig due to
// limitations with anytype in function pointers. Instead, we use direct
// delegation to specific propagator implementations in CompositePropagator.

/// Propagator registry for managing available propagators
pub const PropagatorRegistry = struct {
    allocator: std.mem.Allocator,
    baggage_enabled: bool,
    // Future: Add other propagator types here
    // tracecontext_enabled: bool,
    // b3_enabled: bool,
    // etc.

    const Self = @This();

    /// Initialize the propagator registry from configuration
    pub fn init(allocator: std.mem.Allocator, config: *Configuration) !Self {
        var baggage_enabled = false;

        // Check which propagators are configured
        for (config.trace_propagators) |prop| {
            switch (prop) {
                .baggage => baggage_enabled = true,
                .tracecontext => {
                    // TODO: Enable when W3C Trace Context propagator is implemented
                    std.log.warn("W3C Trace Context propagator not yet implemented", .{});
                },
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

    /// Create a composite propagator from configuration
    pub fn initFromConfig(allocator: std.mem.Allocator, config: *Configuration) !Self {
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

    /// Get the list of all fields that might be read or written by this propagator
    pub fn fields(self: *Self) ![]const []const u8 {
        var field_list: std.ArrayList([]const u8) = .empty;
        errdefer field_list.deinit(self.allocator);

        if (self.registry.baggage_enabled) {
            try field_list.append(self.allocator, baggage_propagator.baggage_header);
        }

        // TODO: Add fields for other propagators when implemented
        // if (self.registry.tracecontext_enabled) {
        //     try field_list.append(self.allocator, "traceparent");
        //     try field_list.append(self.allocator, "tracestate");
        // }

        return try field_list.toOwnedSlice(self.allocator);
    }
};

/// Create a global composite propagator from environment configuration
///
/// This is a convenience function that creates a composite propagator using
/// the global configuration singleton. If no global configuration exists,
/// it will initialize one from environment variables.
pub fn createGlobalPropagator(allocator: std.mem.Allocator) !CompositePropagator {
    const config = Configuration.get() orelse blk: {
        // No global config exists, create and set one
        const new_config = try Configuration.initFromEnv(allocator);
        Configuration.set(new_config);
        break :blk new_config;
    };
    var cfg = @constCast(config);
    defer cfg.deinit();
    return try CompositePropagator.initFromConfig(allocator, cfg);
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
    // tracecontext will be false until implemented
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
