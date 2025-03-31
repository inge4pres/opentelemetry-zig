const std = @import("std");

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterIface = @import("../exporter.zig").ExporterIface;

const MetricReadError = @import("../reader.zig").MetricReadError;

const DataPoint = @import("../../../api/metrics/measurement.zig").DataPoint;
const Measurements = @import("../../../api/metrics/measurement.zig").Measurements;

/// Stdout is an exporter that writes the metrics to stdout.
/// This exporter is intended for debugging and learning purposes.
/// It is not recommended for production use. The output format is not standardized and can change at any time.
/// If a standardized format for exporting metrics to stdout is desired, consider using the File Exporter, if available.
/// However, please review the status of the File Exporter and verify if it is stable and production-ready.
pub const StdoutExporter = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    exporter: ExporterIface,

    file: std.fs.File = std.io.getStdOut(),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = ExporterIface{
                .exportFn = exportBatch,
            },
        };
        return s;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    // Helper test function to set the output file
    // since zig build does not allow writing to stdout.
    fn withOutputFile(self: *Self, file: std.fs.File) void {
        self.file = file;
    }

    fn exportBatch(iface: *ExporterIface, metrics: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);
        // We  need to clear the metrics after exporting them.
        defer {
            for (metrics) |*m| {
                m.deinit(self.allocator);
            }
            self.allocator.free(metrics);
        }

        for (metrics) |m| {
            const fmt = std.fmt.allocPrint(self.allocator, "{?}\n", .{m}) catch |err| {
                std.debug.print("Failed to format metrics: {?}\n", .{err});
                return MetricReadError.ExportFailed;
            };
            defer self.allocator.free(fmt);

            self.file.writeAll(fmt) catch |err| {
                std.debug.print("Failed to write to stdout: {?}\n", .{err});
                return MetricReadError.ExportFailed;
            };
            self.file.sync() catch |err| {
                std.debug.print("Failed to sync file content: {?}\n", .{err});
                return MetricReadError.ExportFailed;
            };
        }
    }
};

test "exporters/stdout" {
    const allocator = std.testing.allocator;

    const val = @as(u64, 42);

    const counter_dp = try DataPoint(i64).new(allocator, 1, .{ "key", val });
    var counter_measures = try allocator.alloc(DataPoint(i64), 1);
    counter_measures[0] = counter_dp;

    const hist_dp = try DataPoint(f64).new(allocator, 2.0, .{ "key", val });
    var hist_measures = try allocator.alloc(DataPoint(f64), 1);
    hist_measures[0] = hist_dp;

    var underTest: std.ArrayListUnmanaged(Measurements) = .empty;

    try underTest.append(allocator, Measurements{
        .meterName = "first-meter",
        .meterAttributes = null,
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-abc" },
        .data = .{ .int = counter_measures },
    });
    try underTest.append(allocator, Measurements{
        .meterName = "another-meter",
        .meterAttributes = null,
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-abc" },
        .data = .{ .double = hist_measures },
    });

    // Create a temporary file to check the output
    const filename = "stdout_exporter_test.txt";
    const file = try std.fs.cwd().createFile(filename, .{
        .truncate = true,
        .read = true,
        .exclusive = true,
    });
    defer std.fs.cwd().deleteFile(filename) catch unreachable;
    //

    var stdoutExporter = try StdoutExporter.init(allocator);
    stdoutExporter.withOutputFile(file);

    defer stdoutExporter.deinit();

    const exporter = try MetricExporter.new(allocator, &stdoutExporter.exporter);
    defer exporter.shutdown();

    const result = exporter.exportBatch(try underTest.toOwnedSlice(allocator));
    try std.testing.expect(result == .Success);

    // TODO add assertions on the file
}
