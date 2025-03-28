const std = @import("std");

const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterIface = @import("../exporter.zig").ExporterIface;

const MetricReadError = @import("../reader.zig").MetricReadError;

const DataPoint = @import("../../../api/metrics/measurement.zig").DataPoint;
const Measurements = @import("../../../api/metrics/measurement.zig").Measurements;

/// InMemoryExporter stores in memory the metrics data to be exported.
/// The metics' representation in memory uses the types defined in the library.
pub const InMemoryExporter = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    data: std.ArrayListUnmanaged(Measurements) = undefined,
    // Implement the interface via @fieldParentPtr
    exporter: ExporterIface,

    mx: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .data = .empty,
            .exporter = ExporterIface{
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
    fn exportBatch(iface: *ExporterIface, metrics: []Measurements) MetricReadError!void {
        // Get a pointer to the instance of the struct that implements the interface.
        const self: *Self = @fieldParentPtr("exporter", iface);
        self.mx.lock();
        defer self.mx.unlock();

        // Free up the allocated data points from the previous export.
        for (self.data.items) |*d| {
            d.*.deinit(self.allocator);
        }
        self.data.clearAndFree(self.allocator);
        self.data = std.ArrayListUnmanaged(Measurements).fromOwnedSlice(metrics);
    }

    /// Read the metrics from the in memory exporter.
    pub fn fetch(self: *Self) ![]Measurements {
        self.mx.lock();
        defer self.mx.unlock();
        // FIXME we should return a copy of the data, using an allocator provided as an argument,
        // instead of the one in the struct.
        return self.data.items;
    }
};

test "in memory exporter stores data" {
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

    const data = try inMemExporter.fetch();

    try std.testing.expect(data.len == 2);
    try std.testing.expectEqualDeep(counter_dp, data[0].data.int[0]);
}
