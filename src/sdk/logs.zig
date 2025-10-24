//! OpenTelemetry Logs SDK.

// Logger Provider
pub const LoggerProvider = @import("../api/logs/logger_provider.zig").LoggerProvider;

// Processors
pub const LogRecordProcessor = @import("logs/log_record_processor.zig").LogRecordProcessor;
pub const SimpleLogRecordProcessor = @import("logs/log_record_processor.zig").SimpleLogRecordProcessor;
pub const BatchingLogRecordProcessor = @import("logs/log_record_processor.zig").BatchingLogRecordProcessor;

// Exporters
pub const LogRecordExporter = @import("logs/log_record_exporter.zig").LogRecordExporter;
pub const StdoutExporter = @import("logs/exporters/generic.zig").StdoutExporter;
pub const InMemoryExporter = @import("logs/exporters/generic.zig").InMemoryExporter;
pub const OTLPExporter = @import("logs/exporters/otlp.zig").OTLPExporter;

test {
    _ = @import("logs/log_record_processor.zig");
    _ = @import("logs/log_record_exporter.zig");
    _ = @import("logs/exporters/generic.zig");
    _ = @import("logs/exporters/otlp.zig");
}
