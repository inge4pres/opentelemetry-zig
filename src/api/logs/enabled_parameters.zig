const Context = @import("../context/context.zig").Context;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// Parameters for checking if logging is enabled.
/// Used by Logger.enabled() to determine if a log record would be processed.
///
/// This follows the OpenTelemetry specification for the Logger Enabled API.
/// See: https://opentelemetry.io/docs/specs/otel/logs/bridge-api/#enabled
pub const EnabledParameters = struct {
    /// The instrumentation scope of the logger
    scope: InstrumentationScope,

    /// Optional severity level to check
    severity: ?u8 = null,

    /// Optional event name to check
    event_name: ?[]const u8 = null,

    /// Context for the enabled check
    context: Context,
};
