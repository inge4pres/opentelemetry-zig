//! OpenTelemetry Logs SDK.

// SDK Components
pub const LoggerProvider = @import("logs/provider.zig").LoggerProvider;
pub const Logger = @import("logs/provider.zig").Logger;

// Processors
pub const LogRecordProcessor = @import("logs/log_record_processor.zig").LogRecordProcessor;
pub const SimpleLogRecordProcessor = @import("logs/log_record_processor.zig").SimpleLogRecordProcessor;
pub const BatchingLogRecordProcessor = @import("logs/log_record_processor.zig").BatchingLogRecordProcessor;

// Exporters
pub const LogRecordExporter = @import("logs/log_record_exporter.zig").LogRecordExporter;
pub const StdoutExporter = @import("logs/exporters/generic.zig").StdoutExporter;
pub const InMemoryExporter = @import("logs/exporters/generic.zig").InMemoryExporter;

test {
    _ = @import("logs/provider.zig");
    _ = @import("logs/log_record_processor.zig");
    _ = @import("logs/log_record_exporter.zig");
    _ = @import("logs/exporters/generic.zig");
}
