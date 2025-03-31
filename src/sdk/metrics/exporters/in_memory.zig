const std = @import("std");

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterImpl = @import("../exporter.zig").ExporterImpl;

const MetricReadError = @import("../reader.zig").MetricReadError;

const DataPoint = @import("../../../api/metrics/measurement.zig").DataPoint;
const Measurements = @import("../../../api/metrics/measurement.zig").Measurements;

const Attributes = @import("../../../attributes.zig").Attributes;

/// InMemoryExporter stores in memory the metrics data to be exported.
/// The metics' representation in memory uses the types defined in the library.
pub const InMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(Measurements) = undefined,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterImpl,

    mx: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = .empty,
            .exporter = ExporterImpl{
                .exportFn = exportBatch,
            },
        };
        return s;
    }
    pub fn deinit(self: *Self) void {
        self.mx.lock();
        for (self.data.items) |*d| {
            d.*.deinit(self.allocator);
        }
        self.data.deinit(self.allocator);
        self.mx.unlock();

        self.allocator.destroy(self);
    }

    // Implements the ExportIFace interface only method.
    fn exportBatch(iface: *ExporterImpl, metrics: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);
        self.mx.lock();
        defer self.mx.unlock();

        // appendSlice will copy the data into the array list,
        // so we need to free their memory after the exportBatch call.
        self.data.appendSlice(self.allocator, metrics) catch {
            return MetricReadError.ExportFailed;
        };
        self.allocator.free(metrics);
    }

    /// Read the metrics from the in memory exporter.
    pub fn fetch(self: *Self, allocator: std.mem.Allocator) ![]Measurements {
        self.mx.lock();
        defer self.mx.unlock();

        return try self.data.toOwnedSlice(allocator);
    }
};

test "exporters/in_memory" {
    const allocator = std.testing.allocator;

    var inMemExporter = try InMemoryExporter.init(allocator);
    defer inMemExporter.deinit();

    const exporter = try MetricExporter.new(allocator, &inMemExporter.exporter);
    defer exporter.shutdown();

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

    const result = exporter.exportBatch(try underTest.toOwnedSlice(allocator));
    try std.testing.expect(result == .Success);

    const data = try inMemExporter.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }

    try std.testing.expect(data.len == 2);
    try std.testing.expectEqualDeep(counter_dp, data[0].data.int[0]);

    const expected_attrs = try Attributes.from(allocator, .{ "key", val });
    defer allocator.free(expected_attrs.?);

    try std.testing.expectEqualDeep(expected_attrs.?, data[0].data.int[0].attributes.?);
}
