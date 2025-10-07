const std = @import("std");

const log = std.log.scoped(.stdout_exporter);

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterImpl = @import("../exporter.zig").ExporterImpl;

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
    exporter: ExporterImpl,

    file: std.fs.File = std.fs.File.stdout(),

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .exporter = ExporterImpl{
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
    pub fn withOutputFile(self: *Self, file: std.fs.File) void {
        self.file = file;
    }

    fn exportBatch(iface: *ExporterImpl, metrics: []Measurements) MetricReadError!void {
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
            const fmt = std.fmt.allocPrint(self.allocator, "{any}\n", .{m}) catch |err| {
                log.err("Failed to format metrics: {}", .{err});
                return MetricReadError.ExportFailed;
            };
            defer self.allocator.free(fmt);

            // Use writeAll to directly write to file without buffering
            self.file.writeAll(fmt) catch |err| {
                log.err("Failed to write to file: {}", .{err});
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
        .scope = .{
            .name = "first-meter",
        },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "counter-abc" },
        .data = .{ .int = counter_measures },
    });
    try underTest.append(allocator, Measurements{
        .scope = .{
            .name = "another-meter",
        },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "histogram-abc" },
        .data = .{ .double = hist_measures },
    });

    // Create a temporary file to check the output
    const filename = "stdout_exporter_test.txt";
    // Delete file if it exists first
    std.fs.cwd().deleteFile(filename) catch {};
    const file = try std.fs.cwd().createFile(filename, .{
        .truncate = true,
        .read = true,
        .exclusive = true,
    });
    defer std.fs.cwd().deleteFile(filename) catch unreachable;

    var stdoutExporter = try StdoutExporter.init(allocator);
    defer stdoutExporter.deinit();
    stdoutExporter.withOutputFile(file);

    const exporter = try MetricExporter.new(allocator, &stdoutExporter.exporter);
    defer exporter.shutdown();

    const result = exporter.exportBatch(try underTest.toOwnedSlice(allocator), null);
    try std.testing.expect(result == .Success);

    // Close the file to read the content
    file.close();

    const buf = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(buf);

    const read = try std.fs.cwd().readFile(filename, buf);

    // Check that we actually wrote something to the file
    try std.testing.expect(read.len > 0);

    // In Zig 0.15.1, the {any} format changed, so just check for some expected content
    try std.testing.expect(std.mem.indexOf(u8, read, ".scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, ".name") != null);
}
