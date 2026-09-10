const std = @import("std");

const log = std.log.scoped(.reader);

const pbcommon = @import("opentelemetry-proto").common;
const pbresource = @import("opentelemetry-proto").resource;
const pbmetrics = @import("opentelemetry-proto").metrics;

// Import configuration module for tests
const Configuration = @import("../config.zig").Configuration;

const instrument = @import("../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const Kind = instrument.Kind;
const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
const AggregatedMetrics = @import("../../api/metrics/meter.zig").AggregatedMetrics;

const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const Measurements = @import("../../api/metrics/measurement.zig").Measurements;
const MeasurementsData = @import("../../api/metrics/measurement.zig").MeasurementsData;
const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

const view = @import("view.zig");
const TemporalitySelector = view.TemporalitySelector;
const AggregationSelector = view.AggregationSelector;

const exporter = @import("exporter.zig");
const MetricExporter = exporter.MetricExporter;
const ExporterIface = exporter.ExporterImpl;
const ExportResult = exporter.ExportResult;
const Temporality = @import("temporality.zig");
const clock = @import("clock");
const HistogramDataPoint = @import("../../api/metrics/measurement.zig").HistogramDataPoint;

const InMemoryExporter = @import("exporters/in_memory.zig").InMemoryExporter;

/// ExportError represents the failure to export data points
/// to a destination.
pub const MetricReadError = error{
    CollectFailedOnMissingMeterProvider,
    ExportFailed,
    ForceFlushTimedOut,
    ConcurrentCollectNotAllowed,
    OutOfMemory,
};

/// MetricReader reads metrics' data from a MeterProvider.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#metricreader
pub const MetricReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // Exporter is the destination of the metrics data.
    // It takes ownership of the collected metrics.
    exporter: *MetricExporter = undefined,
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    // Data transform configuration
    temporality: TemporalitySelector = view.DefaultTemporality,
    aggregation: AggregationSelector = view.DefaultAggregation,
    // Composes the .Cumulative data points.
    temporal_aggregation: *Temporality = undefined,

    // Optional timeout for export operations (in milliseconds)
    exportTimeout: ?u64 = null,

    // Signal that shutdown has been called.
    hasShutDown: bool = false,
    mx: std.Io.Mutex = std.Io.Mutex.init,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, metric_exporter: *MetricExporter) !*Self {
        const s = try allocator.create(Self);
        s.* = Self{
            .allocator = allocator,
            .io = io,
            .exporter = metric_exporter,
            .temporality = metric_exporter.temporality orelse view.DefaultTemporality,
            .aggregation = metric_exporter.aggregation orelse view.DefaultAggregation,
            .temporal_aggregation = try Temporality.init(allocator),
        };

        return s;
    }

    pub fn collect(self: *Self) !void {
        if (@atomicLoad(bool, &self.hasShutDown, .acquire)) {
            // When shutdown has already been called, collect is a no-op.
            return;
        }
        if (!self.mx.tryLock()) {
            return MetricReadError.ConcurrentCollectNotAllowed;
        }
        defer self.mx.unlock(self.io);
        var toBeExported = std.ArrayList(Measurements).empty;
        defer toBeExported.deinit(self.allocator);

        errdefer {
            for (toBeExported.items) |*m| {
                m.deinit(self.allocator);
            }
        }

        if (self.meterProvider) |mp| {
            // Collect the data from each meter provider.
            // Measurements can be ported to protobuf structs during OTLP export.
            var meters = mp.meters.valueIterator();
            while (meters.next()) |meter| {
                const measurements = AggregatedMetrics.fetch(self.allocator, meter, mp.views.items, self.aggregation) catch |err| {
                    log.err("error aggregating data points from meter {s}: {}", .{ meter.scope.name, err });
                    continue;
                };
                defer self.allocator.free(measurements);

                errdefer {
                    for (measurements) |*m| {
                        m.deinit(self.allocator);
                    }
                }

                for (measurements) |*m| {
                    try self.temporal_aggregation.process(m, self.temporality);
                    m.resource = mp.resource;
                }

                // The exporter takes ownership of the data points, which are deinitialized
                // by calling deinit() on the Measurements once done.
                // MetricExporter must be built with the same allocator as MetricReader
                // to ensure that the memory is managed correctly.
                try toBeExported.appendSlice(self.allocator, measurements);
            }

            try self.appendMissingCumulativeHistograms(mp, &toBeExported);
            const owned = try toBeExported.toOwnedSlice(self.allocator);
            switch (self.exporter.exportBatch(owned, self.exportTimeout)) {
                ExportResult.Success => return,
                ExportResult.Failure => return MetricReadError.ExportFailed,
            }
        } else {
            // No meter provider to collect from.
            return MetricReadError.CollectFailedOnMissingMeterProvider;
        }
    }

    fn appendMissingCumulativeHistograms(
        self: *Self,
        mp: *MeterProvider,
        toBeExported: *std.ArrayList(Measurements),
    ) !void {
        if (self.temporal_aggregation.histograms.count() == 0) return;

        const Group = struct {
            target_index: ?usize = null,
            missing: std.ArrayList(DataPoint(HistogramDataPoint)) = .empty,
        };
        var groups = std.HashMap(Temporality.ScopedDataPoint, Group, Temporality.HashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer {
            var values = groups.valueIterator();
            while (values.next()) |group| {
                for (group.missing.items) |*dp| dp.deinit(self.allocator);
                group.missing.deinit(self.allocator);
            }
            groups.deinit();
        }
        var seen = std.HashMap(Temporality.ScopedDataPoint, void, Temporality.HashContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer seen.deinit();

        // These temporary keys borrow attributes from the current output.
        for (toBeExported.items, 0..) |m, index| {
            if (m.data != .histogram) continue;
            var key = Temporality.ScopedDataPoint{
                .scope = m.scope,
                .instrument_options = m.instrumentOptions,
                .instrument_kind = m.instrumentKind,
                .datapoint_attributes = null,
            };
            try groups.put(key, .{ .target_index = index });
            for (m.data.histogram) |dp| {
                key.datapoint_attributes = dp.attributes;
                try seen.put(key, {});
            }
        }

        const collection_time: u64 = @intCast(clock.nanoTimestamp());
        var iter = self.temporal_aggregation.histograms.iterator();
        while (iter.next()) |entry| {
            if (seen.contains(entry.key_ptr.*)) continue;
            var key = entry.key_ptr.*;
            key.datapoint_attributes = null;
            const gop = try groups.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .{};

            const timestamps = entry.value_ptr.timestamps orelse
                return Temporality.TemporalAggregationError.MissingTimestampTimeUnixNano;
            var dp = try entry.value_ptr.deepCopy(self.allocator);
            errdefer dp.deinit(self.allocator);
            dp.attributes = try Attributes.with(entry.key_ptr.datapoint_attributes).dupe(self.allocator);
            dp.timestamps = .{
                .start_time_ns = timestamps.start_time_ns,
                .time_ns = collection_time,
            };
            try gop.value_ptr.missing.append(self.allocator, dp);
        }

        var group_iter = groups.iterator();
        while (group_iter.next()) |entry| {
            const group = entry.value_ptr;
            if (group.missing.items.len == 0) continue;
            if (group.target_index) |index| {
                const existing = toBeExported.items[index].data.histogram;
                const extended = try self.allocator.realloc(existing, existing.len + group.missing.items.len);
                @memcpy(extended[existing.len..], group.missing.items);
                toBeExported.items[index].data.histogram = extended;
                group.missing.clearRetainingCapacity();
            } else {
                // Reserve first so transferring the owned slice cannot fail afterward.
                try toBeExported.ensureUnusedCapacity(self.allocator, 1);
                toBeExported.appendAssumeCapacity(Measurements{
                    .scope = entry.key_ptr.scope,
                    .instrumentKind = entry.key_ptr.instrument_kind,
                    .instrumentOptions = entry.key_ptr.instrument_options,
                    .data = .{ .histogram = try group.missing.toOwnedSlice(self.allocator) },
                    .resource = mp.resource,
                });
            }
        }
    }

    pub fn shutdown(self: *Self) void {
        @atomicStore(bool, &self.hasShutDown, true, .release);
        self.collect() catch |e| {
            log.err("shutdown: error while collecting metrics: {}", .{e});
        };
        self.exporter.shutdown();
        self.temporal_aggregation.deinit();
        self.allocator.destroy(self);
    }
};

test "metric reader shutdown prevents collect() to execute" {
    const io = std.testing.io;
    var noop = exporter.ExporterImpl{ .exportFn = exporter.noopExporter };
    const metric_exporter = try MetricExporter.new(std.testing.allocator, io, &noop);
    var metric_reader = try MetricReader.init(std.testing.allocator, io, metric_exporter);
    const e = metric_reader.collect();
    try std.testing.expectEqual(MetricReadError.CollectFailedOnMissingMeterProvider, e);
    metric_reader.shutdown();
}

test "metric reader collects data from meter provider" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);

    var reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    var hist = try m.createHistogram(u16, .{ .name = "my-histogram" });
    const v: []const u8 = "success";

    try hist.record(10, .{ "amazing", v });

    var histFloat = try m.createHistogram(f64, .{ .name = "my-histogram-float" });
    try histFloat.record(10.0, .{ "wonderful", v });

    try reader.collect();

    const data = try inMem.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }
}

test "metric reader cumulative aggregation survives freeing exported measurements" {
    // page_allocator unmaps freed pages, so the use-after-free this guards
    // against segfaults instead of silently reading recycled bytes (which the
    // testing allocator would do, hiding the bug). Reaching the end proves no UAF.
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);

    var reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    const meter = try mp.getMeter(.{ .name = "reproduce.metrics.temporality" });
    var counter = try meter.createCounter(u64, .{ .name = "requests" });

    // Cumulative temporality: the running total must persist across collect
    // cycles even though the caller takes ownership of and frees the exported
    // measurements (and thus their attributes) between cycles.
    const route: []const u8 = "/reproducer";
    const want = [_]i64{ 1, 3 };
    for (1..3) |round| {
        try counter.add(@intCast(round), .{ "route", route });

        try reader.collect();

        const stored = try inMem.fetch(allocator);
        defer {
            for (stored) |*m| m.deinit(allocator);
            allocator.free(stored);
        }

        try std.testing.expectEqual(@as(usize, 1), stored.len);
        try std.testing.expectEqual(want[round - 1], stored[0].data.int[0].value);
    }
}

fn deltaTemporality(_: Kind) view.Temporality {
    return .Delta;
}

fn dropAll(_: Kind) view.Aggregation {
    return .Drop;
}

test "metric reader custom temporality and aggregation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();

    var metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);
    metric_exporter.temporality = deltaTemporality;
    metric_exporter.aggregation = dropAll;

    var reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();

    std.debug.assert(reader.temporality(.Counter) == .Delta);
    std.debug.assert(reader.aggregation(.Histogram) == .Drop);

    try mp.addReader(reader);

    const m = try mp.getMeter(.{ .name = "my-meter" });

    var counter = try m.createCounter(u32, .{ .name = "my-counter" });
    try counter.add(1, .{});

    try reader.collect();

    const data = try inMem.fetch(allocator);
    defer {
        for (data) |*d| {
            d.*.deinit(allocator);
        }
        allocator.free(data);
    }
    // Since we are using the .Drop aggregation, no data should be collected.
    try std.testing.expectEqual(0, data.len);
}

test "metric reader correctness exporting cumulative temporality" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);

    var reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    // Generate data
    const meter = try mp.getMeter(.{ .name = "test", .schema_url = "http://example.com" });
    var counter = try meter.createCounter(u64, .{ .name = "test-counter" });
    try counter.add(1, .{});
    try counter.add(2, .{});

    // first collection cycle: the value should be 3
    try reader.collect();
    const result = try inMem.fetch(allocator);
    defer {
        for (result) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result);
    }

    try std.testing.expectEqual(3, result[0].data.int[0].value);

    try counter.add(1, .{});
    try counter.add(2, .{});

    // Second collection cycle: the value should be 6
    try reader.collect();
    const result2 = try inMem.fetch(allocator);
    defer {
        for (result2) |m| {
            var data = m;
            data.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(result2);
    }

    // Assert value is actually summed up with .Cumulative
    try std.testing.expectEqual(6, result2[0].data.int[0].value);
    // and that timestamp is preserved in a long-running series
    try std.testing.expectEqual(result[0].data.int[0].timestamps.?.time_ns, result2[0].data.int[0].timestamps.?.start_time_ns);
}

test "metric reader cumulative histogram across collection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bounds = @import("../../api/metrics/spec.zig").default_histogram_explicit_bucket_boundaries;

    inline for (.{ f64, i64 }) |T| {
        const mp = try MeterProvider.init(allocator, io);
        defer mp.shutdown();
        var inMem = try InMemoryExporter.init(allocator, io);
        defer inMem.deinit();
        const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);
        const reader = try MetricReader.init(allocator, io, metric_exporter);
        defer reader.shutdown();
        try mp.addReader(reader);
        const meter = try mp.getMeter(.{ .name = "test" });
        const histogram = try meter.createHistogram(T, .{ .name = "test-histogram" });
        const first: T = if (T == f64) 0.25 else 1;
        const second: T = if (T == f64) 0.5 else 6;
        var start_time: ?u64 = null;

        for (0..3) |cycle| {
            if (cycle == 0) try histogram.record(first, .{});
            if (cycle == 1) try histogram.record(second, .{});
            const before: u64 = @intCast(clock.nanoTimestamp());
            try reader.collect();
            const after: u64 = @intCast(clock.nanoTimestamp());
            const result = try inMem.fetch(allocator);
            defer {
                for (result) |*m| m.deinit(allocator);
                allocator.free(result);
            }
            try std.testing.expectEqual(1, result.len);
            try std.testing.expectEqual(1, result[0].data.histogram.len);
            const dp = result[0].data.histogram[0];
            const value = dp.value;
            try std.testing.expectEqual(@as(u64, if (cycle == 0) 1 else 2), value.count);
            if (T == f64) {
                try std.testing.expectEqual(@as(f64, if (cycle == 0) 0.25 else 0.75), value.sum.?);
            } else {
                // Signed integer histogram aggregation omits sum.
                try std.testing.expectEqual(null, value.sum);
            }
            const expected_min: f64 = if (T == f64) first else @floatFromInt(first);
            const expected_max: f64 = if (cycle == 0) expected_min else if (T == f64) second else @floatFromInt(second);
            try std.testing.expectEqual(expected_min, value.min.?);
            try std.testing.expectEqual(expected_max, value.max.?);
            var counts = [_]u64{0} ** (bounds.len + 1);
            counts[1] = 1;
            if (cycle > 0) counts[if (T == f64) 1 else 2] += 1;
            try std.testing.expectEqualSlices(u64, &counts, value.bucket_counts);

            const timestamps = dp.timestamps.?;
            if (cycle == 0) {
                start_time = timestamps.start_time_ns;
                try std.testing.expectEqual(timestamps.time_ns, start_time);
            }
            try std.testing.expectEqual(start_time, timestamps.start_time_ns);
            try std.testing.expect(timestamps.time_ns >= before and timestamps.time_ns <= after);
        }
    }
}

test "metric reader frees pending histograms on collection failure" {
    const Sink = struct {
        allocator: std.mem.Allocator,
        exporter: ExporterIface = .{ .exportFn = exportBatch },
        calls: usize = 0,
        series: usize = 0,
        count: u64 = 0,
        sum: f64 = 0,

        // Consume output without allocating so failures stay in the collection path.
        fn exportBatch(iface: *ExporterIface, metrics: []Measurements) MetricReadError!void {
            const self: *@This() = @fieldParentPtr("exporter", iface);
            defer self.allocator.free(metrics);
            self.calls += 1;
            self.series = 0;
            self.count = 0;
            self.sum = 0;
            for (metrics) |*m| {
                defer m.deinit(self.allocator);
                for (m.data.histogram) |dp| {
                    self.series += 1;
                    self.count += dp.value.count;
                    self.sum += dp.value.sum.?;
                }
            }
        }
    };

    var failure_offset: usize = 0;
    while (true) : (failure_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        const io = std.testing.io;

        const mp = try MeterProvider.init(allocator, io);
        defer mp.shutdown();

        var sink = Sink{ .allocator = allocator };
        const metric_exporter = try MetricExporter.new(allocator, io, &sink.exporter);
        const reader = try MetricReader.init(allocator, io, metric_exporter);
        defer reader.shutdown();
        try mp.addReader(reader);

        const meter = try mp.getMeter(.{ .name = "test" });
        const histogram = try meter.createHistogram(f64, .{ .name = "test-histogram" });
        const get: []const u8 = "GET";
        const post: []const u8 = "POST";
        try histogram.record(0.25, .{ "http.request.method", get });
        try histogram.record(1.0, .{ "http.request.method", post });
        try reader.collect();
        try std.testing.expectEqual(1, sink.calls);

        // Fail each allocation while rebuilding inactive output.
        failing.fail_index = failing.alloc_index + failure_offset;
        failing.resize_fail_index = failing.resize_index;
        const result = reader.collect();
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);

        if (!failing.has_induced_failure) {
            try result;
            try std.testing.expect(failure_offset > 0);
            try std.testing.expectEqual(2, sink.calls);
        } else {
            try std.testing.expectError(error.OutOfMemory, result);
            try std.testing.expectEqual(1, sink.calls);

            // A failed output must leave the saved cumulative state usable.
            try reader.collect();
            try std.testing.expectEqual(2, sink.calls);
        }
        try std.testing.expectEqual(2, sink.series);
        try std.testing.expectEqual(2, sink.count);
        try std.testing.expectEqual(1.25, sink.sum);

        if (!failing.has_induced_failure) break;
    }
}

test "metric reader cumulative histogram retains inactive series" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();

    var inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();

    const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);

    var reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();
    try mp.addReader(reader);

    const meter = try mp.getMeter(.{ .name = "test" });
    const histogram = try meter.createHistogram(f64, .{ .name = "test-histogram" });

    const get: []const u8 = "GET";
    const post: []const u8 = "POST";
    try histogram.record(0.25, .{ "http.request.method", get });
    try histogram.record(1.0, .{ "http.request.method", post });

    for (0..2) |cycle| {
        if (cycle == 1) try histogram.record(0.5, .{ "http.request.method", get });
        try reader.collect();
        const collected = try inMem.fetch(allocator);
        defer {
            for (collected) |*m| m.deinit(allocator);
            allocator.free(collected);
        }
        try std.testing.expectEqual(1, collected.len);
        try std.testing.expectEqual(2, collected[0].data.histogram.len);

        var seen_get = false;
        var seen_post = false;
        for (collected[0].data.histogram) |dp| {
            const attrs = dp.attributes orelse return error.MissingAttributes;
            try std.testing.expectEqual(1, attrs.len);
            try std.testing.expectEqualStrings("http.request.method", attrs[0].key);
            const method = switch (attrs[0].value) {
                .string => |value| value,
                else => return error.UnexpectedAttributeType,
            };
            const sum = dp.value.sum orelse return error.MissingSum;

            if (std.mem.eql(u8, method, get)) {
                try std.testing.expect(!seen_get);
                seen_get = true;
                try std.testing.expectEqual(@as(u64, if (cycle == 0) 1 else 2), dp.value.count);
                try std.testing.expectEqual(@as(f64, if (cycle == 0) 0.25 else 0.75), sum);
            } else if (std.mem.eql(u8, method, post)) {
                try std.testing.expect(!seen_post);
                seen_post = true;
                try std.testing.expectEqual(1, dp.value.count);
                try std.testing.expectEqual(1.0, sum);
            } else {
                return error.UnexpectedMethod;
            }
        }
        try std.testing.expect(seen_get and seen_post);
    }
}

test "metric reader cumulative histogram separates instrument options" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mp = try MeterProvider.init(allocator, io);
    defer mp.shutdown();
    const inMem = try InMemoryExporter.init(allocator, io);
    defer inMem.deinit();
    const metric_exporter = try MetricExporter.new(allocator, io, &inMem.exporter);
    const reader = try MetricReader.init(allocator, io, metric_exporter);
    defer reader.shutdown();
    try mp.addReader(reader);
    const meter = try mp.getMeter(.{ .name = "test" });
    const ms = try meter.createHistogram(f64, .{ .name = "duration", .unit = "ms" });
    const seconds = try meter.createHistogram(f64, .{ .name = "duration", .unit = "s" });
    const other = try meter.createHistogram(f64, .{ .name = "duration", .unit = "ms", .description = "other" });
    try ms.record(0.25, .{});
    try seconds.record(0.5, .{});
    try other.record(0.75, .{});

    for (0..3) |cycle| {
        if (cycle == 1) try ms.record(0.25, .{});
        try reader.collect();
        const result = try inMem.fetch(allocator);
        defer {
            for (result) |*m| m.deinit(allocator);
            allocator.free(result);
        }
        try std.testing.expectEqual(3, result.len);
        var seen = [_]bool{ false, false, false };
        for (result) |m| {
            const index: usize = if (m.instrumentOptions.description != null) 2 else if (std.mem.eql(u8, m.instrumentOptions.unit.?, "s")) 1 else 0;
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            try std.testing.expectEqualStrings("duration", m.instrumentOptions.name);
            try std.testing.expectEqualStrings(if (index == 1) "s" else "ms", m.instrumentOptions.unit.?);
            try std.testing.expectEqualStrings(if (index == 2) "other" else "", m.instrumentOptions.description orelse "");
            try std.testing.expectEqual(1, m.data.histogram.len);
            try std.testing.expectEqual(@as(u64, if (index == 0 and cycle > 0) 2 else 1), m.data.histogram[0].value.count);
            const sums = [_]f64{ if (cycle == 0) 0.25 else 0.5, 0.5, 0.75 };
            try std.testing.expectEqual(sums[index], m.data.histogram[0].value.sum.?);
        }
    }
}
