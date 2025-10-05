// Test SDK implementations
test {
    _ = @import("sdk/trace.zig");
    _ = @import("sdk/metrics.zig");
    _ = @import("sdk/logs.zig");
    // helpers
    _ = @import("attributes.zig");
    _ = @import("scope.zig");
    _ = @import("otlp.zig");
}

// Test API
test {
    _ = @import("api.zig");
}

// Export the entire API module for easy access
pub const api = @import("api.zig");

// SDK namespaces
pub const trace = @import("sdk/trace.zig");
pub const metrics = @import("sdk/metrics.zig");
pub const logs = @import("sdk/logs.zig");

// Direct exports for convenience
pub const otlp = @import("otlp.zig");

// Attribute system exports
pub const Attribute = @import("attributes.zig").Attribute;
pub const AttributeValue = @import("attributes.zig").AttributeValue;
pub const Attributes = @import("attributes.zig").Attributes;
pub const attributes = @import("attributes.zig");

// Scope exports
pub const InstrumentationScope = @import("scope.zig").InstrumentationScope;
pub const scope = @import("scope.zig");
