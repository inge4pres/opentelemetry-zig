const std = @import("std");

const log = std.log.scoped(.storage);

const spec = @import("../../api/metrics/spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("../../api/metrics/measurement.zig").DataPoint;
const HistogramDataPoint = @import("../../api/metrics/measurement.zig").HistogramDataPoint;
const aggregation = @import("aggregation.zig");
const ExponentialHistogramDataPoint = aggregation.ExponentialHistogramDataPoint;
const exemplar = @import("exemplar.zig");

fn toKey(attributes: ?[]const Attribute) Attributes {
    return Attributes.with(if (attributes) |attrs| @constCast(attrs) else null);
}

/// Deep-copy and normalize points to the target type with timestamps assigned from collection_start_ns.
pub fn copyNormalizedPoints(comptime From: type, comptime To: type, allocator: std.mem.Allocator, io: std.Io, points: []const DataPoint(From), collection_start_ns: *u64) ![]DataPoint(To) {
    const copied = try allocator.alloc(DataPoint(To), points.len);
    var initialized: usize = 0;
    errdefer {
        for (copied[0..initialized]) |*point| point.deinit(allocator);
        allocator.free(copied);
    }
    for (points, 0..) |point, i| {
        const copy = try point.deepCopy(allocator);
        copied[i] = .{
            .value = switch (@typeInfo(To)) {
                .int => @intCast(copy.value),
                .float => @floatCast(copy.value),
                else => @compileError("Unsupported metric value type"),
            },
            .attributes = copy.attributes,
            .attributes_owned = copy.attributes_owned,
            .timestamps = copy.timestamps,
            .exemplar_candidate = copy.exemplar_candidate,
            .exemplars = copy.exemplars,
        };
        initialized += 1;
    }
    // Callers hold the recording lock, so the next batch starts after this cut.
    if (copied.len > 0) {
        const collection_time: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
        for (copied) |*point| point.timestamps = .{ .start_time_ns = collection_start_ns.*, .time_ns = collection_time };
        collection_start_ns.* = collection_time;
    }
    return copied;
}

/// Sum aggregation storage. Keeps running totals keyed by distinct attribute sets.
pub const SumStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cardinality_limit: usize,
    collection_start_ns: u64,
    aggregated_points: std.ArrayHashMapUnmanaged(Attributes, DataPoint(i64), Attributes.ArrayHashContext, true),

    pub const overflow_attrs = [_]Attribute{
        .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
    };
    pub const overflow_key = Attributes.with(@constCast(&overflow_attrs));

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cardinality_limit: usize) SumStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .cardinality_limit = cardinality_limit,
            .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            .aggregated_points = .empty,
        };
    }

    pub fn deinit(self: *SumStorage) void {
        for (self.aggregated_points.values()) |*m| {
            m.deinit(self.allocator);
        }
        self.aggregated_points.deinit(self.allocator);
    }

    /// Fold `dp` into the pre-aggregated sum series.
    ///
    /// Whatever gets moved into the map is cleared from `dp`, so the caller
    /// must always call `dp.deinit` afterwards: it frees what was not moved.
    pub fn recordPoint(self: *SumStorage, comptime T: type, dp: *DataPoint(T), capture_exemplar: bool, exemplar_filter: exemplar.ExemplarFilter) !void {
        const val: i64 = @intCast(dp.value);
        const key = Attributes.with(dp.attributes);
        if (self.aggregated_points.getPtr(key)) |existing| {
            if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, exemplar_filter);
            existing.value += val;
            if (dp.exemplar_candidate) |sample| {
                if (existing.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                existing.exemplar_candidate = sample;
                dp.exemplar_candidate = null;
            }
            return;
        }

        // The spec requires creating the overflow series prior to reaching the cardinality limit,
        // and does not say whether it counts towards the limit. Like the Go and Java SDKs, it does:
        // at most `cardinality_limit - 1` regular series are kept, leaving the last slot to the overflow series.
        // https://github.com/open-telemetry/opentelemetry-specification/blob/v1.48.0/specification/metrics/sdk.md#overflow-attribute
        if (self.cardinality_limit > 0 and self.aggregated_points.count() >= self.cardinality_limit - 1) {
            if (self.aggregated_points.getPtr(overflow_key)) |overflow_ptr| {
                if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, exemplar_filter);
                overflow_ptr.value += val;
                if (dp.exemplar_candidate) |sample| {
                    if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                    overflow_ptr.exemplar_candidate = sample;
                    dp.exemplar_candidate = null;
                }
                return;
            }

            log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
            const overflow_slice = try self.allocator.dupe(Attribute, &overflow_attrs);
            var overflow_dp = DataPoint(i64){
                .value = val,
                .attributes = overflow_slice,
                .attributes_owned = false,
            };
            var overflow_stored = false;
            defer if (!overflow_stored) overflow_dp.deinit(self.allocator);

            if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, exemplar_filter);
            if (dp.exemplar_candidate) |sample| {
                overflow_dp.exemplar_candidate = sample;
                dp.exemplar_candidate = null;
            }

            try self.aggregated_points.put(self.allocator, Attributes.with(overflow_slice), overflow_dp);
            overflow_stored = true;
            return;
        }

        if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, exemplar_filter);

        const dp_i64 = DataPoint(i64){
            .value = val,
            .attributes = dp.attributes,
            .attributes_owned = dp.attributes_owned,
            .exemplar_candidate = dp.exemplar_candidate,
            .exemplars = dp.exemplars,
            .timestamps = dp.timestamps,
        };
        try self.aggregated_points.put(self.allocator, Attributes.with(dp.attributes), dp_i64);

        // The map owns these now.
        dp.attributes = null;
        dp.attributes_owned = false;
        dp.exemplar_candidate = null;
        dp.exemplars = &.{};
    }

    /// Snapshot the current aggregated points for collection.
    pub fn snapshot(self: *SumStorage, allocator: std.mem.Allocator, end_time_ns: *u64) ![]DataPoint(i64) {
        return copyNormalizedPoints(i64, i64, allocator, self.io, self.aggregated_points.values(), end_time_ns);
    }

    /// Clear aggregated points while retaining map capacity.
    pub fn clearRetainingCapacity(self: *SumStorage) void {
        for (self.aggregated_points.values()) |*m| m.deinit(self.allocator);
        self.aggregated_points.clearRetainingCapacity();
    }

    pub fn count(self: *const SumStorage) usize {
        return self.aggregated_points.count();
    }
};

/// LastValue aggregation storage. Keeps the latest recorded measurement per attribute set.
pub fn LastValueStorage(comptime AggType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: std.Io,
        cardinality_limit: usize,
        collection_start_ns: u64,
        aggregated_points: std.ArrayHashMapUnmanaged(Attributes, DataPoint(AggType), Attributes.ArrayHashContext, true),

        pub const overflow_attrs = [_]Attribute{
            .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
        };
        pub const overflow_key = Attributes.with(@constCast(&overflow_attrs));

        pub fn init(allocator: std.mem.Allocator, io: std.Io, cardinality_limit: usize) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .cardinality_limit = cardinality_limit,
                .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
                .aggregated_points = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.aggregated_points.values()) |*m| {
                m.deinit(self.allocator);
            }
            self.aggregated_points.deinit(self.allocator);
        }

        /// Record a measurement value into the latest-value series.
        pub fn record(self: *Self, val: AggType, attributes: ?[]const Attribute, candidate: *?exemplar.Exemplar) !void {
            const key = toKey(attributes);
            if (self.aggregated_points.getPtr(key)) |existing| {
                existing.value = val;
                if (candidate.*) |sample| {
                    if (existing.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                    existing.exemplar_candidate = sample;
                    candidate.* = null;
                }
                return;
            }

            if (self.cardinality_limit > 0 and self.aggregated_points.count() >= self.cardinality_limit - 1) {
                if (self.aggregated_points.getPtr(overflow_key)) |overflow_ptr| {
                    overflow_ptr.value = val;
                    if (candidate.*) |sample| {
                        if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                        overflow_ptr.exemplar_candidate = sample;
                        candidate.* = null;
                    }
                    return;
                }

                log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
                const overflow_slice = try self.allocator.dupe(Attribute, &overflow_attrs);
                var overflow_dp = DataPoint(AggType){
                    .value = val,
                    .attributes = overflow_slice,
                    .attributes_owned = false,
                };
                var overflow_stored = false;
                defer if (!overflow_stored) overflow_dp.deinit(self.allocator);

                if (candidate.*) |sample| {
                    overflow_dp.exemplar_candidate = sample;
                    candidate.* = null;
                }

                try self.aggregated_points.put(self.allocator, Attributes.with(overflow_slice), overflow_dp);
                overflow_stored = true;
                return;
            }

            var owned_attrs = if (attributes) |attrs|
                try exemplar.Exemplar.copyAttributes(self.allocator, attrs)
            else
                null;
            defer if (owned_attrs) |attrs| {
                for (attrs) |attr| {
                    self.allocator.free(attr.key);
                    if (attr.value == .string) self.allocator.free(attr.value.string);
                }
                self.allocator.free(attrs);
            };

            var new_dp = DataPoint(AggType){
                .value = val,
                .attributes = owned_attrs,
                .attributes_owned = (owned_attrs != null),
                .exemplar_candidate = candidate.*,
            };
            owned_attrs = null;
            candidate.* = null;

            var dp_stored = false;
            defer if (!dp_stored) new_dp.deinit(self.allocator);

            try self.aggregated_points.put(self.allocator, Attributes.with(new_dp.attributes), new_dp);
            dp_stored = true;
        }

        /// Fold `raw_dp` into the pre-aggregated series (e.g. upon switching to pre-aggregation).
        pub fn recordRawPoint(self: *Self, comptime T: type, raw_dp: *DataPoint(T)) !void {
            const val: AggType = switch (@typeInfo(T)) {
                .int => @intCast(raw_dp.value),
                .float => @floatCast(raw_dp.value),
                else => unreachable,
            };
            const key = Attributes.with(raw_dp.attributes);
            if (self.aggregated_points.getPtr(key)) |existing| {
                existing.value = val;
                if (raw_dp.exemplar_candidate) |sample| {
                    if (existing.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                    existing.exemplar_candidate = sample;
                    raw_dp.exemplar_candidate = null;
                }
                return;
            }

            if (self.cardinality_limit > 0 and self.aggregated_points.count() >= self.cardinality_limit - 1) {
                if (self.aggregated_points.getPtr(overflow_key)) |overflow_ptr| {
                    overflow_ptr.value = val;
                    if (raw_dp.exemplar_candidate) |sample| {
                        if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                        overflow_ptr.exemplar_candidate = sample;
                        raw_dp.exemplar_candidate = null;
                    }
                    return;
                }

                log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
                const overflow_slice = try self.allocator.dupe(Attribute, &overflow_attrs);
                var overflow_dp = DataPoint(AggType){
                    .value = val,
                    .attributes = overflow_slice,
                    .attributes_owned = false,
                };
                var overflow_stored = false;
                defer if (!overflow_stored) overflow_dp.deinit(self.allocator);

                if (raw_dp.exemplar_candidate) |sample| {
                    overflow_dp.exemplar_candidate = sample;
                    raw_dp.exemplar_candidate = null;
                }

                try self.aggregated_points.put(self.allocator, Attributes.with(overflow_slice), overflow_dp);
                overflow_stored = true;
                return;
            }

            const dp_agg = DataPoint(AggType){
                .value = val,
                .attributes = raw_dp.attributes,
                .attributes_owned = raw_dp.attributes_owned,
                .exemplar_candidate = raw_dp.exemplar_candidate,
                .exemplars = raw_dp.exemplars,
                .timestamps = raw_dp.timestamps,
            };
            try self.aggregated_points.put(self.allocator, Attributes.with(raw_dp.attributes), dp_agg);

            raw_dp.attributes = null;
            raw_dp.attributes_owned = false;
            raw_dp.exemplar_candidate = null;
            raw_dp.exemplars = &.{};
        }

        /// Snapshot the current aggregated points for collection.
        pub fn snapshot(self: *Self, allocator: std.mem.Allocator, end_time_ns: *u64) ![]DataPoint(AggType) {
            return copyNormalizedPoints(AggType, AggType, allocator, self.io, self.aggregated_points.values(), end_time_ns);
        }

        /// Clear aggregated points while retaining map capacity.
        pub fn clearRetainingCapacity(self: *Self) void {
            for (self.aggregated_points.values()) |*m| m.deinit(self.allocator);
            self.aggregated_points.clearRetainingCapacity();
        }

        pub fn count(self: *const Self) usize {
            return self.aggregated_points.count();
        }
    };
}

/// State for a single explicit histogram time series.
pub const ExplicitState = struct {
    data: DataPoint(HistogramDataPoint),
    bucket_exemplars: []?exemplar.Exemplar,

    pub fn deinit(self: *ExplicitState, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        for (self.bucket_exemplars) |*slot| {
            if (slot.*) |*sample| sample.deinit(allocator);
        }
        allocator.free(self.bucket_exemplars);
    }
};

/// Caller owns the returned point; partial allocations are freed on error.
pub fn snapshotExplicitPoint(
    allocator: std.mem.Allocator,
    state: *const ExplicitState,
    sample: ?exemplar.Exemplar,
) !DataPoint(HistogramDataPoint) {
    var dp = try state.data.deepCopy(allocator);
    errdefer dp.deinit(allocator);
    if (sample) |s| dp.exemplar_candidate = try s.deepCopy(allocator);
    return dp;
}

/// Explicit bucket histogram aggregation storage.
pub const ExplicitBucketHistogramStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cardinality_limit: usize,
    collection_start_ns: u64,
    buckets: []const f64,
    record_min_max: bool,
    record_sum: bool,
    explicit_points: std.ArrayHashMapUnmanaged(
        Attributes,
        ExplicitState,
        Attributes.ArrayHashContext,
        true,
    ),

    pub const overflow_attrs = [_]Attribute{
        .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
    };
    pub const overflow_key = Attributes.with(@constCast(&overflow_attrs));

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cardinality_limit: usize,
        buckets: []const f64,
        record_min_max: bool,
        record_sum: bool,
    ) ExplicitBucketHistogramStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .cardinality_limit = cardinality_limit,
            .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            .buckets = buckets,
            .record_min_max = record_min_max,
            .record_sum = record_sum,
            .explicit_points = .empty,
        };
    }

    pub fn deinit(self: *ExplicitBucketHistogramStorage) void {
        for (self.explicit_points.values()) |*val| {
            val.deinit(self.allocator);
        }
        self.explicit_points.deinit(self.allocator);
    }

    pub fn updateExplicitPoint(self: *ExplicitBucketHistogramStorage, state: *ExplicitState, f64_val: f64, candidate: *?exemplar.Exemplar) void {
        const dp = &state.data;
        if (self.record_sum) {
            dp.value.sum = (dp.value.sum orelse 0) + f64_val;
        }
        dp.value.count += 1;
        if (self.record_min_max) {
            dp.value.min = if (dp.value.min) |curr| @min(curr, f64_val) else f64_val;
            dp.value.max = if (dp.value.max) |curr| @max(curr, f64_val) else f64_val;
        }
        var bucket_index = self.buckets.len;
        for (self.buckets, 0..) |boundary, i| {
            if (f64_val <= boundary) {
                bucket_index = i;
                break;
            }
        }
        dp.value.bucket_counts[bucket_index] += 1;
        if (candidate.*) |sample| {
            if (state.bucket_exemplars[bucket_index]) |*prev| prev.deinit(self.allocator);
            state.bucket_exemplars[bucket_index] = sample;
            candidate.* = null;
        }
    }

    pub fn insertExplicitPoint(self: *ExplicitBucketHistogramStorage, attributes: ?[]const Attribute, f64_val: f64, candidate: *?exemplar.Exemplar) !void {
        // alloc returns undefined memory: counts must start at 0 and exemplar slots at null,
        // otherwise deinit frees garbage pointers.
        const bucket_counts = try self.allocator.alloc(u64, self.buckets.len + 1);
        @memset(bucket_counts, 0);
        var state = ExplicitState{
            .data = DataPoint(HistogramDataPoint){
                .value = HistogramDataPoint{
                    .explicit_bounds = self.buckets,
                    .bucket_counts = bucket_counts,
                    .sum = if (self.record_sum) f64_val else null,
                    .count = 1,
                    .min = if (self.record_min_max) f64_val else null,
                    .max = if (self.record_min_max) f64_val else null,
                },
            },
            .bucket_exemplars = &.{},
        };
        errdefer state.deinit(self.allocator);

        state.bucket_exemplars = try self.allocator.alloc(?exemplar.Exemplar, self.buckets.len + 1);
        @memset(state.bucket_exemplars, null);

        if (attributes) |attrs| {
            state.data.attributes = try exemplar.Exemplar.copyAttributes(self.allocator, attrs);
            state.data.attributes_owned = true;
        }

        var bucket_index = self.buckets.len;
        for (self.buckets, 0..) |boundary, i| {
            if (f64_val <= boundary) {
                bucket_index = i;
                break;
            }
        }
        bucket_counts[bucket_index] = 1;

        if (candidate.*) |sample| {
            state.bucket_exemplars[bucket_index] = sample;
            candidate.* = null;
        }

        try self.explicit_points.put(self.allocator, Attributes.with(state.data.attributes), state);
    }

    pub fn record(self: *ExplicitBucketHistogramStorage, f64_val: f64, attributes: ?[]const Attribute, candidate: *?exemplar.Exemplar) !void {
        const key = toKey(attributes);
        if (self.explicit_points.getPtr(key)) |state_ptr| {
            self.updateExplicitPoint(state_ptr, f64_val, candidate);
            return;
        }

        if (self.cardinality_limit > 0 and self.explicit_points.count() >= self.cardinality_limit - 1) {
            if (self.explicit_points.getPtr(overflow_key)) |overflow_ptr| {
                self.updateExplicitPoint(overflow_ptr, f64_val, candidate);
                return;
            }

            log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
            try self.insertExplicitPoint(&overflow_attrs, f64_val, candidate);
            return;
        }

        try self.insertExplicitPoint(attributes, f64_val, candidate);
    }

    pub fn snapshot(self: *ExplicitBucketHistogramStorage, allocator: std.mem.Allocator) ![]DataPoint(HistogramDataPoint) {
        var total_points: usize = 0;
        for (self.explicit_points.values()) |*val| {
            var ex_count: usize = 0;
            for (val.bucket_exemplars) |slot| {
                if (slot != null) ex_count += 1;
            }
            total_points += if (ex_count > 1) ex_count else 1;
        }

        var data = try allocator.alloc(DataPoint(HistogramDataPoint), total_points);
        var success_count: usize = 0;
        errdefer {
            for (data[0..success_count]) |*dp| {
                dp.deinit(allocator);
            }
            allocator.free(data);
        }

        var out_idx: usize = 0;
        for (self.explicit_points.values()) |*val| {
            const first_idx: ?usize = for (val.bucket_exemplars, 0..) |slot, b_i| {
                if (slot != null) break b_i;
            } else null;

            data[out_idx] = try snapshotExplicitPoint(allocator, val, if (first_idx) |f_i| val.bucket_exemplars[f_i] else null);
            out_idx += 1;
            success_count += 1;

            if (first_idx) |f_i| {
                for (val.bucket_exemplars[f_i + 1 ..]) |slot| {
                    const s = slot orelse continue;
                    // Carries only the exemplar; aggregate() merges it into the main point.
                    var extra = try snapshotExplicitPoint(allocator, val, s);
                    @memset(extra.value.bucket_counts, 0);
                    extra.value.count = 0;
                    extra.value.sum = null;
                    extra.value.min = null;
                    extra.value.max = null;
                    data[out_idx] = extra;
                    out_idx += 1;
                    success_count += 1;
                }
            }
        }

        if (data.len > 0) {
            const collection_time: u64 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
            for (data) |*point| point.timestamps = .{ .start_time_ns = self.collection_start_ns, .time_ns = collection_time };
            self.collection_start_ns = collection_time;
        }

        return data;
    }

    pub fn clearRetainingCapacity(self: *ExplicitBucketHistogramStorage) void {
        for (self.explicit_points.values()) |*val| {
            val.deinit(self.allocator);
        }
        self.explicit_points.clearRetainingCapacity();
    }

    pub fn count(self: *const ExplicitBucketHistogramStorage) usize {
        return self.explicit_points.count();
    }
};

/// State for a single exponential histogram time series.
pub const ExponentialState = struct {
    state: aggregation.ExponentialHistogramState,
    attributes: ?[]Attribute = null,
    attributes_owned: bool = false,
    exemplar_candidate: ?exemplar.Exemplar = null,

    pub fn deinit(self: *ExponentialState, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
        if (self.attributes) |attrs| {
            if (self.attributes_owned) for (attrs) |attr| {
                allocator.free(attr.key);
                if (attr.value == .string) allocator.free(attr.value.string);
            };
            allocator.free(attrs);
        }
        if (self.exemplar_candidate) |*sample| sample.deinit(allocator);
    }
};

/// Exponential bucket histogram aggregation storage.
pub const ExponentialHistogramStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cardinality_limit: usize,
    collection_start_ns: u64,
    max_scale: i32,
    max_size: u32,
    record_min_max: bool,
    record_sum: bool,
    exponential_points: std.ArrayHashMapUnmanaged(
        Attributes,
        ExponentialState,
        Attributes.ArrayHashContext,
        true,
    ),

    pub const overflow_attrs = [_]Attribute{
        .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
    };
    pub const overflow_key = Attributes.with(@constCast(&overflow_attrs));

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cardinality_limit: usize,
        max_scale: i32,
        max_size: u32,
        record_min_max: bool,
        record_sum: bool,
    ) ExponentialHistogramStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .cardinality_limit = cardinality_limit,
            .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            .max_scale = max_scale,
            .max_size = max_size,
            .record_min_max = record_min_max,
            .record_sum = record_sum,
            .exponential_points = .empty,
        };
    }

    pub fn deinit(self: *ExponentialHistogramStorage) void {
        for (self.exponential_points.values()) |*val| {
            val.deinit(self.allocator);
        }
        self.exponential_points.deinit(self.allocator);
    }

    pub fn insertExponentialPoint(self: *ExponentialHistogramStorage, attributes: ?[]const Attribute, f64_val: f64, candidate: *?exemplar.Exemplar) !void {
        var state = ExponentialState{ .state = aggregation.ExponentialHistogramState.init(self.max_scale) };
        errdefer state.deinit(self.allocator);

        try state.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);

        if (attributes) |attrs| {
            state.attributes = try exemplar.Exemplar.copyAttributes(self.allocator, attrs);
            state.attributes_owned = true;
        }

        state.exemplar_candidate = candidate.*;
        candidate.* = null;

        try self.exponential_points.put(self.allocator, Attributes.with(state.attributes), state);
    }

    pub fn record(self: *ExponentialHistogramStorage, f64_val: f64, attributes: ?[]const Attribute, candidate: *?exemplar.Exemplar) !void {
        const key = toKey(attributes);
        if (self.exponential_points.getPtr(key)) |state_ptr| {
            try state_ptr.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);
            if (candidate.*) |sample| {
                if (state_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                state_ptr.exemplar_candidate = sample;
                candidate.* = null;
            }
            return;
        }

        if (self.cardinality_limit > 0 and self.exponential_points.count() >= self.cardinality_limit - 1) {
            if (self.exponential_points.getPtr(overflow_key)) |overflow_ptr| {
                try overflow_ptr.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);
                if (candidate.*) |sample| {
                    if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                    overflow_ptr.exemplar_candidate = sample;
                    candidate.* = null;
                }
                return;
            }

            log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
            try self.insertExponentialPoint(&overflow_attrs, f64_val, candidate);
            return;
        }

        try self.insertExponentialPoint(attributes, f64_val, candidate);
    }

    pub fn snapshot(self: *ExponentialHistogramStorage, allocator: std.mem.Allocator) ![]DataPoint(ExponentialHistogramDataPoint) {
        const cnt = self.exponential_points.count();
        var data = try allocator.alloc(DataPoint(ExponentialHistogramDataPoint), cnt);
        var success_count: usize = 0;
        errdefer {
            for (data[0..success_count]) |*dp| {
                dp.deinit(allocator);
            }
            allocator.free(data);
        }

        for (self.exponential_points.values(), 0..) |*val, idx| {
            var point = DataPoint(ExponentialHistogramDataPoint){
                .value = try val.state.toDataPoint(allocator),
            };
            errdefer point.deinit(allocator);

            point.attributes = if (val.attributes) |attrs|
                try exemplar.Exemplar.copyAttributes(allocator, attrs)
            else
                null;
            point.attributes_owned = (val.attributes != null);

            if (val.exemplar_candidate) |sample| {
                point.exemplar_candidate = try sample.deepCopy(allocator);
            }

            data[idx] = point;
            success_count += 1;
        }

        if (data.len > 0) {
            const collection_time: u64 = @intCast(std.Io.Clock.real.now(self.io).nanoseconds);
            for (data) |*point| point.timestamps = .{ .start_time_ns = self.collection_start_ns, .time_ns = collection_time };
            self.collection_start_ns = collection_time;
        }

        return data;
    }

    pub fn clearRetainingCapacity(self: *ExponentialHistogramStorage) void {
        for (self.exponential_points.values()) |*val| {
            val.deinit(self.allocator);
        }
        self.exponential_points.clearRetainingCapacity();
    }

    pub fn count(self: *const ExponentialHistogramStorage) usize {
        return self.exponential_points.count();
    }
};

test "SumStorage basic recording and snapshot" {
    const io = std.testing.io;
    var sum_storage = SumStorage.init(std.testing.allocator, io, 100);
    defer sum_storage.deinit();

    var dp1 = DataPoint(u64){
        .value = 10,
        .attributes = null,
    };
    try sum_storage.recordPoint(u64, &dp1, false, .always_off);

    var dp2 = DataPoint(u64){
        .value = 25,
        .attributes = null,
    };
    try sum_storage.recordPoint(u64, &dp2, false, .always_off);

    try std.testing.expectEqual(@as(usize, 1), sum_storage.count());

    var end_time: u64 = sum_storage.collection_start_ns;
    const points = try sum_storage.snapshot(std.testing.allocator, &end_time);
    defer {
        for (points) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(points);
    }

    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(i64, 35), points[0].value);
}

test "SumStorage cardinality limit with overflow series" {
    const io = std.testing.io;
    var sum_storage = SumStorage.init(std.testing.allocator, io, 3);
    defer sum_storage.deinit();

    var dp1 = try DataPoint(i64).new(std.testing.allocator, 1, .{ "id", @as(i64, 1) });
    defer dp1.deinit(std.testing.allocator);
    try sum_storage.recordPoint(i64, &dp1, false, .always_off);

    var dp2 = try DataPoint(i64).new(std.testing.allocator, 2, .{ "id", @as(i64, 2) });
    defer dp2.deinit(std.testing.allocator);
    try sum_storage.recordPoint(i64, &dp2, false, .always_off);

    // Limit is 3, so at most 2 regular series; 3rd goes into overflow series
    var dp3 = try DataPoint(i64).new(std.testing.allocator, 3, .{ "id", @as(i64, 3) });
    defer dp3.deinit(std.testing.allocator);
    try sum_storage.recordPoint(i64, &dp3, false, .always_off);

    try std.testing.expectEqual(@as(usize, 3), sum_storage.count());

    var end_time: u64 = sum_storage.collection_start_ns;
    const points = try sum_storage.snapshot(std.testing.allocator, &end_time);
    defer {
        for (points) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(points);
    }

    try std.testing.expectEqual(@as(usize, 3), points.len);
}

test "LastValueStorage basic recording and snapshot" {
    const io = std.testing.io;
    var storage_i64 = LastValueStorage(i64).init(std.testing.allocator, io, 100);
    defer storage_i64.deinit();

    var candidate: ?exemplar.Exemplar = null;
    try storage_i64.record(42, null, &candidate);
    try storage_i64.record(100, null, &candidate);

    try std.testing.expectEqual(@as(usize, 1), storage_i64.count());

    var end_time: u64 = storage_i64.collection_start_ns;
    const points = try storage_i64.snapshot(std.testing.allocator, &end_time);
    defer {
        for (points) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(points);
    }

    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(i64, 100), points[0].value);
}

test "ExplicitBucketHistogramStorage basic recording" {
    const io = std.testing.io;
    const buckets = [_]f64{ 5.0, 10.0 };
    var hist_storage = ExplicitBucketHistogramStorage.init(std.testing.allocator, io, 100, &buckets, true, true);
    defer hist_storage.deinit();

    var candidate: ?exemplar.Exemplar = null;
    try hist_storage.record(3.0, null, &candidate);
    try hist_storage.record(7.0, null, &candidate);
    try hist_storage.record(12.0, null, &candidate);

    try std.testing.expectEqual(@as(usize, 1), hist_storage.count());

    const points = try hist_storage.snapshot(std.testing.allocator);
    defer {
        for (points) |*p| p.deinit(std.testing.allocator);
        std.testing.allocator.free(points);
    }

    try std.testing.expectEqual(@as(usize, 1), points.len);
    try std.testing.expectEqual(@as(u64, 3), points[0].value.count);
    try std.testing.expectEqual(@as(f64, 22.0), points[0].value.sum.?);
    try std.testing.expectEqual(@as(f64, 3.0), points[0].value.min.?);
    try std.testing.expectEqual(@as(f64, 12.0), points[0].value.max.?);
}

const test_attrs = [_]Attribute{.{ .key = "status", .value = .{ .string = "200" } }};

fn insertExplicitPointAllocationFailure(allocator: std.mem.Allocator) !void {
    const buckets = [_]f64{ 5.0, 10.0 };
    var hist_storage = ExplicitBucketHistogramStorage.init(allocator, std.testing.io, 100, &buckets, true, true);
    defer hist_storage.deinit();

    // Like the instrument caller, the test owns the candidate until storage takes it.
    var candidate: ?exemplar.Exemplar = .{ .value = .{ .double = 7.0 }, .time_ns = 1, .filtered_attributes = try exemplar.Exemplar.copyAttributes(allocator, &test_attrs) };
    defer if (candidate) |*s| s.deinit(allocator);

    try hist_storage.record(7.0, &test_attrs, &candidate);

    try std.testing.expect(candidate == null);
    const state = hist_storage.explicit_points.values()[0];
    // Buckets the value did not hit must be initialized, not left as undefined memory.
    try std.testing.expectEqualSlices(u64, &.{ 0, 1, 0 }, state.data.value.bucket_counts);
    try std.testing.expect(state.bucket_exemplars[0] == null);
    try std.testing.expect(state.bucket_exemplars[1] != null);
    try std.testing.expect(state.bucket_exemplars[2] == null);
}

test "ExplicitBucketHistogramStorage insert handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, insertExplicitPointAllocationFailure, .{});
}

fn insertExponentialPointAllocationFailure(allocator: std.mem.Allocator) !void {
    var hist_storage = ExponentialHistogramStorage.init(allocator, std.testing.io, 100, 20, 160, true, true);
    defer hist_storage.deinit();

    var candidate: ?exemplar.Exemplar = .{ .value = .{ .double = 7.0 }, .time_ns = 1, .filtered_attributes = try exemplar.Exemplar.copyAttributes(allocator, &test_attrs) };
    defer if (candidate) |*s| s.deinit(allocator);

    try hist_storage.record(7.0, &test_attrs, &candidate);

    try std.testing.expect(candidate == null);
    const state = hist_storage.exponential_points.values()[0];
    try std.testing.expectEqual(@as(u64, 1), state.state.count);
    try std.testing.expect(state.exemplar_candidate != null);
}

test "ExponentialHistogramStorage insert handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, insertExponentialPointAllocationFailure, .{});
}
