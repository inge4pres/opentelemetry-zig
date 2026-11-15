const std = @import("std");

const log = std.log.scoped(.instrument);

const spec = @import("spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const DataPoint = @import("measurement.zig").DataPoint;
const HistogramDataPoint = @import("measurement.zig").HistogramDataPoint;
const aggregation = @import("../../sdk/metrics/aggregation.zig");
const ExponentialHistogramDataPoint = aggregation.ExponentialHistogramDataPoint;

const MeasurementsData = @import("measurement.zig").MeasurementsData;

const exemplar = @import("../../sdk/metrics/exemplar.zig");

const AsyncInstrument = @import("async_instrument.zig");
const trace_api = @import("../trace.zig");
const context_api = @import("../context.zig");
const MeterProvider = @import("meter.zig").MeterProvider;

pub const Kind = enum {
    // Synchronous instruments
    Counter,
    UpDownCounter,
    Histogram,
    Gauge,
    // Observable instruments (ascynchronous)
    ObservableCounter,
    ObservableUpDownCounter,
    ObservableGauge,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .Counter => "Counter",
            .UpDownCounter => "UpDownCounter",
            .Histogram => "Histogram",
            .Gauge => "Gauge",
            .ObservableCounter => "ObservableCounter",
            .ObservableUpDownCounter => "ObservableUpDownCounter",
            .ObservableGauge => "ObservableGauge",
        };
    }

    /// Instruments that only record non-negative increments.
    /// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#sum-aggregation
    pub fn isMonotonic(self: Kind) bool {
        return switch (self) {
            .Counter, .ObservableCounter, .Histogram => true,
            .UpDownCounter, .ObservableUpDownCounter, .Gauge, .ObservableGauge => false,
        };
    }
};

const instrumentData = union(enum) {
    // Synchronous instruments.
    Counter_u16: *Counter(u16),
    Counter_u32: *Counter(u32),
    Counter_u64: *Counter(u64),
    UpDownCounter_i16: *Counter(i16),
    UpDownCounter_i32: *Counter(i32),
    UpDownCounter_i64: *Counter(i64),
    Histogram_u16: *Histogram(u16),
    Histogram_u32: *Histogram(u32),
    Histogram_u64: *Histogram(u64),
    Histogram_i16: *Histogram(i16),
    Histogram_i32: *Histogram(i32),
    Histogram_i64: *Histogram(i64),
    Histogram_f32: *Histogram(f32),
    Histogram_f64: *Histogram(f64),
    Gauge_i16: *Gauge(i16),
    Gauge_i32: *Gauge(i32),
    Gauge_i64: *Gauge(i64),
    Gauge_f32: *Gauge(f32),
    Gauge_f64: *Gauge(f64),
    // Async instruments.
    ObservableCounter: *AsyncInstrument.ObservableInstrument(.ObservableCounter),
    ObservableUpDownCounter: *AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter),
    ObservableGauge: *AsyncInstrument.ObservableInstrument(.ObservableGauge),
};

/// Instrument is a container of all supported instrument types.
/// When the Meter wants to create a new instrument, it calls the new() function.
pub const Instrument = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    kind: Kind,
    opts: InstrumentOptions,
    data: instrumentData,

    pub fn new(kind: Kind, opts: InstrumentOptions, allocator: std.mem.Allocator) !*Self {
        // Validate name, unit anddescription, optionally throwing an error if non conformant.
        // See https://opentelemetry.io/docs/specs/otel/metrics/api/#instrument-name-syntax
        try spec.validateInstrumentOptions(opts);
        const i = try allocator.create(Self);
        i.* = Self{
            .allocator = allocator,
            .kind = kind,
            .opts = opts,
            .data = undefined,
        };
        return i;
    }

    pub fn counter(self: *Self, io: std.Io, comptime T: type) !*Counter(T) {
        const c = try self.allocator.create(Counter(T));
        c.* = Counter(T).init(self.allocator, io);
        errdefer self.allocator.destroy(c);
        self.data = switch (T) {
            u16 => .{ .Counter_u16 = c },
            u32 => .{ .Counter_u32 = c },
            u64 => .{ .Counter_u64 = c },
            else => {
                log.err("Unsupported monotonic counter value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn upDownCounter(self: *Self, io: std.Io, comptime T: type) !*Counter(T) {
        const c = try self.allocator.create(Counter(T));
        c.* = Counter(T).init(self.allocator, io);
        errdefer self.allocator.destroy(c);
        self.data = switch (T) {
            i16 => .{ .UpDownCounter_i16 = c },
            i32 => .{ .UpDownCounter_i32 = c },
            i64 => .{ .UpDownCounter_i64 = c },
            else => {
                log.err("Unsupported Up Down counter value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return c;
    }

    pub fn histogram(self: *Self, io: std.Io, comptime T: type) !*Histogram(T) {
        const h = try self.allocator.create(Histogram(T));
        h.* = Histogram(T).init(self.allocator, io);
        errdefer self.allocator.destroy(h);
        self.data = switch (T) {
            u16 => .{ .Histogram_u16 = h },
            u32 => .{ .Histogram_u32 = h },
            u64 => .{ .Histogram_u64 = h },
            i16 => .{ .Histogram_i16 = h },
            i32 => .{ .Histogram_i32 = h },
            i64 => .{ .Histogram_i64 = h },
            f32 => .{ .Histogram_f32 = h },
            f64 => .{ .Histogram_f64 = h },
            else => {
                log.err("Unsupported histogram value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return h;
    }

    pub fn gauge(self: *Self, io: std.Io, comptime T: type) !*Gauge(T) {
        const g = try self.allocator.create(Gauge(T));
        g.* = Gauge(T).init(self.allocator, io);
        errdefer self.allocator.destroy(g);
        self.data = switch (T) {
            i16 => .{ .Gauge_i16 = g },
            i32 => .{ .Gauge_i32 = g },
            i64 => .{ .Gauge_i64 = g },
            f32 => .{ .Gauge_f32 = g },
            f64 => .{ .Gauge_f64 = g },
            else => {
                log.err("Unsupported gauge value type: {s}", .{@typeName(T)});
                return spec.FormatError.UnsupportedValueType;
            },
        };
        return g;
    }

    pub fn asyncCounter(
        self: *Self,
        io: std.Io,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableCounter) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableCounter));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableCounter).init(self.allocator, io, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableCounter = i };
        return i;
    }

    pub fn asyncUpDownCounter(
        self: *Self,
        io: std.Io,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableUpDownCounter).init(self.allocator, io, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableUpDownCounter = i };
        return i;
    }

    pub fn asyncGauge(
        self: *Self,
        io: std.Io,
        context: AsyncInstrument.ObservedContext,
        callbacks: ?[]AsyncInstrument.ObserveMeasures,
    ) !*AsyncInstrument.ObservableInstrument(.ObservableGauge) {
        const i = try self.allocator.create(AsyncInstrument.ObservableInstrument(.ObservableGauge));
        i.* = AsyncInstrument.ObservableInstrument(.ObservableGauge).init(self.allocator, io, context);

        if (callbacks) |cb| {
            for (cb) |c| {
                try i.registerCallback(c);
            }
        }
        self.data = .{ .ObservableGauge = i };
        return i;
    }

    pub fn deinit(self: *Self) void {
        switch (self.data) {
            inline else => |i| {
                i.deinit();
                self.allocator.destroy(i);
            },
        }
        self.allocator.destroy(self);
    }

    pub fn getInstrumentsData(self: Self, allocator: std.mem.Allocator) !MeasurementsData {
        switch (self.data) {
            inline else => |i| {
                return i.measurementsData(allocator);
            },
        }
    }
};

/// InstrumentOptions is used to configure the instrument.
/// Base instrument options are name, description and unit.
/// Kind is inferred from the concrete type of the instrument.
pub const InstrumentOptions = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    // Advisory parameters are in development, we don't support them yet, so we set to null.
    advisory: ?[]Attribute = null,
};

/// A Counter is a monotonically increasing value used to record cumulative events.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#counter
fn copyNormalizedPoints(comptime From: type, comptime To: type, allocator: std.mem.Allocator, io: std.Io, points: []const DataPoint(From), collection_start_ns: *u64) ![]DataPoint(To) {
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

pub fn Counter(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        lock: std.Io.Mutex,
        exemplar_filter: exemplar.ExemplarFilter = .trace_based,
        collection_start_ns: u64 = 0,
        pre_sum: bool = true,
        cardinality_limit: usize,

        /// Pre-aggregated data points when every reader and view resolves to Sum.
        aggregated_points: std.ArrayHashMapUnmanaged(Attributes, DataPoint(i64), Attributes.ArrayHashContext, true),

        /// Raw data points kept as fallback when any reader or view resolves to non-Sum (e.g. LastValue, Histogram, Drop).
        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        const overflow_attrs = [_]Attribute{
            .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
        };
        const overflow_key = Attributes.with(@constCast(&overflow_attrs));

        fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return Self{
                .pre_sum = true,
                .cardinality_limit = spec.default_cardinality_limit,
                .aggregated_points = .empty,
                .data_points = .empty,
                .allocator = allocator,
                .io = io,
                .lock = std.Io.Mutex.init,
                .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            };
        }

        fn deinit(self: *Self) void {
            for (self.aggregated_points.values()) |*m| {
                m.deinit(self.allocator);
            }
            self.aggregated_points.deinit(self.allocator);

            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);
        }

        /// Fold `dp` into the pre-aggregated series.
        ///
        /// Whatever gets moved into the map is cleared from `dp`, so the caller
        /// must always call `dp.deinit` afterwards, whether this succeeded or not:
        /// it frees what was not moved (everything on error, the merged duplicate on success).
        ///
        /// `capture_exemplar` is false for points that were already recorded: their exemplar
        /// candidate was captured, or filtered out, in the context of the original measurement.
        fn recordSumPoint(self: *Self, dp: *DataPoint(T), capture_exemplar: bool) !void {
            const val: i64 = @intCast(dp.value);
            const key = Attributes.with(dp.attributes);
            if (self.aggregated_points.getPtr(key)) |existing| {
                if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
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
                    if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
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

                if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                if (dp.exemplar_candidate) |sample| {
                    overflow_dp.exemplar_candidate = sample;
                    dp.exemplar_candidate = null;
                }

                try self.aggregated_points.put(self.allocator, Attributes.with(overflow_slice), overflow_dp);
                overflow_stored = true;
                return;
            }

            if (capture_exemplar) try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);

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

        pub fn setPreSum(self: *Self, enabled: bool) void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (self.pre_sum == enabled) return;
            self.pre_sum = enabled;

            if (enabled) {
                // Switching back to Sum: drain any pending raw points into aggregated_points.
                // On allocation failure, the failed point and the ones after it stay in data_points.
                const items = self.data_points.items;
                var drained: usize = 0;
                for (items) |*raw_dp| {
                    self.recordSumPoint(raw_dp, false) catch break;
                    drained += 1;
                }
                // Drained points were moved out of or merged, so only the leftovers need freeing.
                for (items[0..drained]) |*raw_dp| raw_dp.deinit(self.allocator);
                const remaining = items.len - drained;
                std.mem.copyForwards(DataPoint(T), items[0..remaining], items[drained..]);
                self.data_points.shrinkRetainingCapacity(remaining);
            }
        }

        /// Add the given delta to the counter, using the provided attributes.
        pub fn add(self: *Self, delta: T, attributes: anytype) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (self.pre_sum) {
                var dp = try DataPoint(T).new(self.allocator, delta, attributes);
                defer dp.deinit(self.allocator);
                try self.recordSumPoint(&dp, true);
            } else {
                var dp = try DataPoint(T).new(self.allocator, delta, attributes);
                errdefer dp.deinit(self.allocator);
                try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                try self.data_points.append(self.allocator, dp);
            }
        }

        /// Add the given delta to the counter with a pre-built attribute slice.
        /// This is primarily used for C interop where attributes are passed as a slice.
        pub fn addWithSlice(self: *Self, delta: T, attributes: ?[]Attribute) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            var dp = DataPoint(T){
                .value = delta,
                .attributes = if (attributes) |attrs|
                    try self.allocator.dupe(Attribute, attrs)
                else
                    null,
            };
            if (self.pre_sum) {
                defer dp.deinit(self.allocator);
                try self.recordSumPoint(&dp, true);
            } else {
                errdefer dp.deinit(self.allocator);
                try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                try self.data_points.append(self.allocator, dp);
            }
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // Both batches share one window, which only advances once the collection succeeds.
            var agg_end_ns = self.collection_start_ns;
            const agg_copied = try copyNormalizedPoints(i64, i64, allocator, self.io, self.aggregated_points.values(), &agg_end_ns);
            defer allocator.free(agg_copied);
            errdefer for (agg_copied) |*p| p.deinit(allocator);
            var raw_end_ns = self.collection_start_ns;
            const raw_copied = try copyNormalizedPoints(T, i64, allocator, self.io, self.data_points.items, &raw_end_ns);
            defer allocator.free(raw_copied);
            errdefer for (raw_copied) |*p| p.deinit(allocator);
            const combined = try std.mem.concat(allocator, DataPoint(i64), &.{ agg_copied, raw_copied });
            self.collection_start_ns = @max(agg_end_ns, raw_end_ns);

            for (self.aggregated_points.values()) |*m| m.deinit(self.allocator);
            self.aggregated_points.clearRetainingCapacity();
            for (self.data_points.items) |*m| m.deinit(self.allocator);
            self.data_points.clearRetainingCapacity();

            return .{ .int = combined };
        }
    };
}

/// A Histogram is used to sample observations and count them in pre-defined buckets.
/// Aggregates measurements in place by attribute set to avoid unbounded memory growth.
/// See https://opentelemetry.io/docs/specs/otel/metrics/api/#histogram
pub fn Histogram(comptime T: type) type {
    comptime {
        switch (@typeInfo(T)) {
            .int, .float => {},
            else => @compileError("Histogram only supports integer and floating-point types, found " ++ @typeName(T)),
        }
    }

    return struct {
        const Self = @This();

        fn toF64(value: T) f64 {
            return switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(value)),
                .float => @as(f64, @floatCast(value)),
                else => @compileError("Histogram only supports integer and floating-point types, found " ++ @typeName(T)),
            };
        }

        pub const Mode = enum {
            explicit,
            exponential,
        };

        pub const ExplicitState = struct {
            data: DataPoint(HistogramDataPoint),
            bucket_exemplars: []?exemplar.Exemplar,

            fn deinit(self: *ExplicitState, allocator: std.mem.Allocator) void {
                self.data.deinit(allocator);
                for (self.bucket_exemplars) |*slot| {
                    if (slot.*) |*sample| sample.deinit(allocator);
                }
                allocator.free(self.bucket_exemplars);
            }
        };

        pub const ExponentialState = struct {
            state: aggregation.ExponentialHistogramState,
            attributes: ?[]Attribute = null,
            attributes_owned: bool = false,
            exemplar_candidate: ?exemplar.Exemplar = null,

            fn deinit(self: *ExponentialState, allocator: std.mem.Allocator) void {
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

        allocator: std.mem.Allocator,
        io: std.Io,
        lock: std.Io.Mutex,
        exemplar_filter: exemplar.ExemplarFilter = .trace_based,
        collection_start_ns: u64 = 0,

        pre_aggregate: bool = false,
        mode: Mode = .explicit,
        cardinality_limit: usize = spec.default_cardinality_limit,

        /// Keeps track of the raw recorded values for each set of attributes.
        /// Used when pre_aggregate is false (e.g. standalone instruments or custom pipelines).
        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        // Explicit bucket configuration
        buckets: []const f64 = spec.default_histogram_explicit_bucket_boundaries,
        record_min_max: bool = true,
        record_sum: bool = true,

        /// Aggregated explicit bucket measurement values keyed by distinct attribute sets.
        explicit_points: std.ArrayHashMapUnmanaged(
            Attributes,
            ExplicitState,
            Attributes.ArrayHashContext,
            true,
        ),

        // Exponential bucket configuration
        max_scale: i32 = 20,
        max_size: u32 = 1024,

        /// Aggregated exponential bucket measurement values keyed by distinct attribute sets.
        exponential_points: std.ArrayHashMapUnmanaged(
            Attributes,
            ExponentialState,
            Attributes.ArrayHashContext,
            true,
        ),

        const overflow_attrs = [_]Attribute{
            .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
        };
        const overflow_key = Attributes.with(@constCast(&overflow_attrs));

        fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return Self{
                .allocator = allocator,
                .io = io,
                .lock = std.Io.Mutex.init,
                .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
                .data_points = .empty,
                .explicit_points = .empty,
                .exponential_points = .empty,
                .pre_aggregate = false,
            };
        }

        fn deinit(self: *Self) void {
            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);

            for (self.explicit_points.values()) |*val| {
                val.deinit(self.allocator);
            }
            self.explicit_points.deinit(self.allocator);

            for (self.exponential_points.values()) |*val| {
                val.deinit(self.allocator);
            }
            self.exponential_points.deinit(self.allocator);
        }

        fn updateExplicitPoint(self: *Self, state: *ExplicitState, f64_val: f64, candidate: *?exemplar.Exemplar) void {
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

        fn insertExplicitPoint(self: *Self, attributes: ?[]const Attribute, f64_val: f64, candidate: *?exemplar.Exemplar) !void {
            var bucket_counts: ?[]u64 = try self.allocator.alloc(u64, self.buckets.len + 1);
            defer if (bucket_counts) |b| self.allocator.free(b);
            @memset(bucket_counts.?, 0);

            var bucket_exemplars: ?[]?exemplar.Exemplar = try self.allocator.alloc(?exemplar.Exemplar, self.buckets.len + 1);
            defer if (bucket_exemplars) |slots| {
                for (slots) |*slot| {
                    if (slot.*) |*sample| sample.deinit(self.allocator);
                }
                self.allocator.free(slots);
            };
            @memset(bucket_exemplars.?, null);

            var bucket_index = self.buckets.len;
            for (self.buckets, 0..) |boundary, i| {
                if (f64_val <= boundary) {
                    bucket_index = i;
                    break;
                }
            }
            bucket_counts.?[bucket_index] = 1;

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

            if (candidate.*) |sample| {
                bucket_exemplars.?[bucket_index] = sample;
                candidate.* = null;
            }

            var state = ExplicitState{
                .data = DataPoint(HistogramDataPoint){
                    .value = HistogramDataPoint{
                        .explicit_bounds = self.buckets,
                        .bucket_counts = bucket_counts.?,
                        .sum = if (self.record_sum) f64_val else null,
                        .count = 1,
                        .min = if (self.record_min_max) f64_val else null,
                        .max = if (self.record_min_max) f64_val else null,
                    },
                    .attributes = owned_attrs,
                    .attributes_owned = (owned_attrs != null),
                },
                .bucket_exemplars = bucket_exemplars.?,
            };
            bucket_counts = null;
            bucket_exemplars = null;
            owned_attrs = null;

            var state_stored = false;
            defer if (!state_stored) state.deinit(self.allocator);

            try self.explicit_points.put(self.allocator, Attributes.with(state.data.attributes), state);
            state_stored = true;
        }

        fn insertExponentialPoint(self: *Self, attributes: ?[]const Attribute, f64_val: f64, candidate: *?exemplar.Exemplar) !void {
            var exp_state: ?aggregation.ExponentialHistogramState = aggregation.ExponentialHistogramState.init(self.allocator, self.max_scale);
            defer if (exp_state) |*s| s.deinit(self.allocator);
            try exp_state.?.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);

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

            var state = ExponentialState{
                .state = exp_state.?,
                .attributes = owned_attrs,
                .attributes_owned = (owned_attrs != null),
                .exemplar_candidate = candidate.*,
            };
            exp_state = null;
            owned_attrs = null;
            candidate.* = null;

            var state_stored = false;
            defer if (!state_stored) state.deinit(self.allocator);

            try self.exponential_points.put(self.allocator, Attributes.with(state.attributes), state);
            state_stored = true;
        }

        /// Add the given value to the histogram, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            if (self.pre_aggregate) {
                const ArgsType = @TypeOf(attributes);
                const args_type_info = @typeInfo(ArgsType);
                if (args_type_info != .@"struct") {
                    @compileError("expected a tuple argument, found " ++ @typeName(ArgsType));
                }
                const count = args_type_info.@"struct".field_names.len / 2;
                var stack_buf: [count]Attribute = undefined;
                const attrs = Attributes.fromBuffer(&stack_buf, attributes);
                return self.recordWithSlice(value, attrs);
            } else {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);

                var dp = try DataPoint(T).new(self.allocator, value, attributes);
                errdefer dp.deinit(self.allocator);
                try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                try self.data_points.append(self.allocator, dp);
            }
        }

        /// Record a value with a pre-built attribute slice.
        /// This is primarily used for C interop where attributes are passed as a slice.
        pub fn recordWithSlice(self: *Self, value: T, attributes: ?[]Attribute) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (!self.pre_aggregate) {
                var dp = DataPoint(T){
                    .value = value,
                    .attributes = if (attributes) |attrs|
                        try self.allocator.dupe(Attribute, attrs)
                    else
                        null,
                };
                errdefer dp.deinit(self.allocator);
                try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                try self.data_points.append(self.allocator, dp);
                return;
            }

            const f64_val = toF64(value);

            var candidate = try exemplar.Exemplar.capture(T, self.allocator, self.io, value, attributes, self.exemplar_filter);
            defer if (candidate) |*s| s.deinit(self.allocator);

            const key = Attributes.with(attributes);

            switch (self.mode) {
                .explicit => {
                    // An existing time-series matching this attribute set is always updated in place
                    // regardless of cardinality limits, because the limit restricts the number of distinct
                    // series, not the number of measurements per series.
                    if (self.explicit_points.getPtr(key)) |state_ptr| {
                        self.updateExplicitPoint(state_ptr, f64_val, &candidate);
                        return;
                    }

                    // For new attribute sets, check whether the cardinality limit has been reached.
                    // When at capacity, divert all excess series into the reserved overflow series.
                    if (self.cardinality_limit > 0 and self.explicit_points.count() >= self.cardinality_limit - 1) {
                        if (self.explicit_points.getPtr(overflow_key)) |overflow_ptr| {
                            self.updateExplicitPoint(overflow_ptr, f64_val, &candidate);
                            return;
                        }

                        log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
                        try self.insertExplicitPoint(&overflow_attrs, f64_val, &candidate);
                        return;
                    }

                    try self.insertExplicitPoint(attributes, f64_val, &candidate);
                },
                .exponential => {
                    // An existing time-series matching this attribute set is always updated in place
                    // regardless of cardinality limits, because the limit restricts the number of distinct
                    // series, not the number of measurements per series.
                    if (self.exponential_points.getPtr(key)) |state_ptr| {
                        try state_ptr.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);
                        if (candidate) |sample| {
                            if (state_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                            state_ptr.exemplar_candidate = sample;
                            candidate = null;
                        }
                        return;
                    }

                    // For new attribute sets, check whether the cardinality limit has been reached.
                    // When at capacity, divert all excess series into the reserved overflow series.
                    if (self.cardinality_limit > 0 and self.exponential_points.count() >= self.cardinality_limit - 1) {
                        if (self.exponential_points.getPtr(overflow_key)) |overflow_ptr| {
                            try overflow_ptr.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum);
                            if (candidate) |sample| {
                                if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                                overflow_ptr.exemplar_candidate = sample;
                                candidate = null;
                            }
                            return;
                        }

                        log.warn("cardinality limit {d} reached; aggregating excess measurements into overflow series", .{self.cardinality_limit});
                        try self.insertExponentialPoint(&overflow_attrs, f64_val, &candidate);
                        return;
                    }

                    try self.insertExponentialPoint(attributes, f64_val, &candidate);
                },
            }
        }

        /// Caller owns the returned point; partial allocations are freed on error.
        fn snapshotExplicitPoint(
            allocator: std.mem.Allocator,
            state: *const ExplicitState,
            sample: ?exemplar.Exemplar,
        ) !DataPoint(HistogramDataPoint) {
            var dp = try state.data.deepCopy(allocator);
            errdefer dp.deinit(allocator);
            if (sample) |s| dp.exemplar_candidate = try s.deepCopy(allocator);
            return dp;
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            const has_explicit = self.explicit_points.count() > 0;
            const has_exponential = self.exponential_points.count() > 0;
            const has_raw = self.data_points.items.len > 0;

            if (has_raw and has_explicit) {
                for (self.data_points.items) |*raw_dp| {
                    const f64_val = toF64(raw_dp.value);
                    var cand = raw_dp.exemplar_candidate;
                    raw_dp.exemplar_candidate = null;
                    defer if (cand) |*s| s.deinit(self.allocator);
                    const key = Attributes.with(raw_dp.attributes);
                    if (self.explicit_points.getPtr(key)) |state_ptr| {
                        self.updateExplicitPoint(state_ptr, f64_val, &cand);
                    } else {
                        self.insertExplicitPoint(raw_dp.attributes, f64_val, &cand) catch break;
                    }
                }
                for (self.data_points.items) |*m| m.deinit(self.allocator);
                self.data_points.clearRetainingCapacity();
            } else if (has_raw and has_exponential) {
                for (self.data_points.items) |*raw_dp| {
                    const f64_val = toF64(raw_dp.value);
                    var cand = raw_dp.exemplar_candidate;
                    raw_dp.exemplar_candidate = null;
                    defer if (cand) |*s| s.deinit(self.allocator);
                    const key = Attributes.with(raw_dp.attributes);
                    if (self.exponential_points.getPtr(key)) |state_ptr| {
                        state_ptr.state.addValue(self.allocator, f64_val, self.max_size, self.record_min_max, self.record_sum) catch break;
                        if (cand) |sample| {
                            if (state_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                            state_ptr.exemplar_candidate = sample;
                            cand = null;
                        }
                    } else {
                        self.insertExponentialPoint(raw_dp.attributes, f64_val, &cand) catch break;
                    }
                }
                for (self.data_points.items) |*m| m.deinit(self.allocator);
                self.data_points.clearRetainingCapacity();
            }

            if (!has_explicit and !has_exponential) {
                defer {
                    for (self.data_points.items) |*m| {
                        m.deinit(self.allocator);
                    }
                    self.data_points.clearRetainingCapacity();
                }
                switch (@typeInfo(T)) {
                    .int => {
                        return .{ .int = try copyNormalizedPoints(T, i64, allocator, self.io, self.data_points.items, &self.collection_start_ns) };
                    },
                    .float => {
                        return .{ .double = try copyNormalizedPoints(T, f64, allocator, self.io, self.data_points.items, &self.collection_start_ns) };
                    },
                    else => @compileError("Histogram only supports integer and floating-point types, found " ++ @typeName(T)),
                }
            }

            if (has_explicit) {
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

                for (self.explicit_points.values()) |*val| {
                    val.deinit(self.allocator);
                }
                self.explicit_points.clearRetainingCapacity();

                return .{ .histogram = data };
            } else {
                const count = self.exponential_points.count();
                var data = try allocator.alloc(DataPoint(ExponentialHistogramDataPoint), count);
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

                for (self.exponential_points.values()) |*val| {
                    val.deinit(self.allocator);
                }
                self.exponential_points.clearRetainingCapacity();

                return .{ .exponential_histogram = data };
            }
        }
    };
}

pub fn Gauge(comptime T: type) type {
    comptime {
        switch (@typeInfo(T)) {
            .int, .float => {},
            else => @compileError("Gauge only supports integer and floating-point types, found " ++ @typeName(T)),
        }
    }

    return struct {
        const Self = @This();

        pub const AggType = switch (@typeInfo(T)) {
            .int => i64,
            .float => f64,
            else => unreachable,
        };

        fn toAgg(value: T) AggType {
            return switch (@typeInfo(T)) {
                .int => @intCast(value),
                .float => @floatCast(value),
                else => unreachable,
            };
        }

        fn wrapData(points: []DataPoint(AggType)) MeasurementsData {
            return switch (AggType) {
                i64 => .{ .int = points },
                f64 => .{ .double = points },
                else => unreachable,
            };
        }

        allocator: std.mem.Allocator,
        io: std.Io,
        lock: std.Io.Mutex,
        exemplar_filter: exemplar.ExemplarFilter = .trace_based,
        collection_start_ns: u64 = 0,
        pre_last_value: bool = true,
        cardinality_limit: usize,

        /// Pre-aggregated data points when every reader and view resolves to LastValue.
        aggregated_points: std.ArrayHashMapUnmanaged(Attributes, DataPoint(AggType), Attributes.ArrayHashContext, true),

        /// Raw data points kept as fallback when any reader or view resolves to non-LastValue (e.g. Drop).
        data_points: std.ArrayListUnmanaged(DataPoint(T)),

        const overflow_attrs = [_]Attribute{
            .{ .key = "otel.metric.overflow", .value = .{ .bool = true } },
        };
        const overflow_key = Attributes.with(@constCast(&overflow_attrs));

        fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return Self{
                .pre_last_value = true,
                .cardinality_limit = spec.default_cardinality_limit,
                .aggregated_points = .empty,
                .data_points = .empty,
                .allocator = allocator,
                .io = io,
                .lock = std.Io.Mutex.init,
                .collection_start_ns = @intCast(std.Io.Clock.real.now(io).nanoseconds),
            };
        }

        fn deinit(self: *Self) void {
            for (self.aggregated_points.values()) |*m| {
                m.deinit(self.allocator);
            }
            self.aggregated_points.deinit(self.allocator);

            for (self.data_points.items) |*m| {
                m.deinit(self.allocator);
            }
            self.data_points.deinit(self.allocator);
        }

        /// Fold `raw_dp` into the pre-aggregated series.
        ///
        /// Used when draining raw points into aggregated points upon switching to pre-aggregation.
        /// Whatever gets moved into the map is cleared from `raw_dp`, so the caller
        /// must always call `raw_dp.deinit` afterwards:
        /// it frees what was not moved (everything on error, the merged duplicate on success).
        fn recordRawPoint(self: *Self, raw_dp: *DataPoint(T)) !void {
            const val = toAgg(raw_dp.value);
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

            // The map owns these now.
            raw_dp.attributes = null;
            raw_dp.attributes_owned = false;
            raw_dp.exemplar_candidate = null;
            raw_dp.exemplars = &.{};
        }

        pub fn setPreLastValue(self: *Self, enabled: bool) void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (self.pre_last_value == enabled) return;
            self.pre_last_value = enabled;

            if (enabled) {
                // Switching back to LastValue: drain any pending raw points into aggregated_points.
                // On allocation failure, the failed point and the ones after it stay in data_points,
                // and we revert pre_last_value to false so subsequent measurements preserve chronological order.
                const items = self.data_points.items;
                var drained: usize = 0;
                for (items) |*raw_dp| {
                    self.recordRawPoint(raw_dp) catch {
                        self.pre_last_value = false;
                        break;
                    };
                    drained += 1;
                }
                // Drained points were moved out of or merged, so only the leftovers need freeing.
                for (items[0..drained]) |*raw_dp| raw_dp.deinit(self.allocator);
                const remaining = items.len - drained;
                std.mem.copyForwards(DataPoint(T), items[0..remaining], items[drained..]);
                self.data_points.shrinkRetainingCapacity(remaining);
            }
        }

        /// Record the given value to the gauge, using the provided attributes.
        pub fn record(self: *Self, value: T, attributes: anytype) !void {
            const ArgsType = @TypeOf(attributes);
            const args_type_info = @typeInfo(ArgsType);
            if (args_type_info != .@"struct") {
                @compileError("expected a tuple argument, found " ++ @typeName(ArgsType));
            }
            const count = args_type_info.@"struct".field_names.len / 2;
            var stack_buf: [count]Attribute = undefined;
            const attrs = Attributes.fromBuffer(&stack_buf, attributes);
            return self.recordWithSlice(value, attrs);
        }

        /// Record a value with a pre-built attribute slice.
        /// This is primarily used for C interop where attributes are passed as a slice.
        pub fn recordWithSlice(self: *Self, value: T, attributes: ?[]Attribute) !void {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            if (!self.pre_last_value) {
                var dp = DataPoint(T){
                    .value = value,
                    .attributes = if (attributes) |attrs|
                        try self.allocator.dupe(Attribute, attrs)
                    else
                        null,
                };
                errdefer dp.deinit(self.allocator);
                try dp.captureExemplar(self.allocator, self.io, self.exemplar_filter);
                try self.data_points.append(self.allocator, dp);
                return;
            }

            const val = toAgg(value);

            var candidate = try exemplar.Exemplar.capture(T, self.allocator, self.io, value, attributes, self.exemplar_filter);
            defer if (candidate) |*s| s.deinit(self.allocator);

            const key = Attributes.with(attributes);

            if (self.aggregated_points.getPtr(key)) |existing| {
                existing.value = val;
                if (candidate) |sample| {
                    if (existing.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                    existing.exemplar_candidate = sample;
                    candidate = null;
                }
                return;
            }

            // The spec requires creating the overflow series prior to reaching the cardinality limit,
            // and does not say whether it counts towards the limit. Like the Go and Java SDKs, it does:
            // at most `cardinality_limit - 1` regular series are kept, leaving the last slot to the overflow series.
            // https://github.com/open-telemetry/opentelemetry-specification/blob/v1.48.0/specification/metrics/sdk.md#overflow-attribute
            if (self.cardinality_limit > 0 and self.aggregated_points.count() >= self.cardinality_limit - 1) {
                if (self.aggregated_points.getPtr(overflow_key)) |overflow_ptr| {
                    overflow_ptr.value = val;
                    if (candidate) |sample| {
                        if (overflow_ptr.exemplar_candidate) |*prev| prev.deinit(self.allocator);
                        overflow_ptr.exemplar_candidate = sample;
                        candidate = null;
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

                if (candidate) |sample| {
                    overflow_dp.exemplar_candidate = sample;
                    candidate = null;
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
                .exemplar_candidate = candidate,
            };
            owned_attrs = null;
            candidate = null;

            var dp_stored = false;
            defer if (!dp_stored) new_dp.deinit(self.allocator);

            try self.aggregated_points.put(self.allocator, Attributes.with(new_dp.attributes), new_dp);
            dp_stored = true;
        }

        fn measurementsData(self: *Self, allocator: std.mem.Allocator) !MeasurementsData {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);

            // Both batches share one window, which only advances once the collection succeeds.
            var agg_end_ns = self.collection_start_ns;
            const agg_copied = try copyNormalizedPoints(AggType, AggType, allocator, self.io, self.aggregated_points.values(), &agg_end_ns);
            defer allocator.free(agg_copied);
            errdefer for (agg_copied) |*p| p.deinit(allocator);
            var raw_end_ns = self.collection_start_ns;
            const raw_copied = try copyNormalizedPoints(T, AggType, allocator, self.io, self.data_points.items, &raw_end_ns);
            defer allocator.free(raw_copied);
            errdefer for (raw_copied) |*p| p.deinit(allocator);
            const combined = try std.mem.concat(allocator, DataPoint(AggType), &.{ agg_copied, raw_copied });
            self.collection_start_ns = @max(agg_end_ns, raw_end_ns);

            for (self.aggregated_points.values()) |*m| m.deinit(self.allocator);
            self.aggregated_points.clearRetainingCapacity();
            for (self.data_points.items) |*m| m.deinit(self.allocator);
            self.data_points.clearRetainingCapacity();

            return wrapData(combined);
        }
    };
}

test "counter with unsupported type does not leak" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    const err = meter.createCounter(u1, .{ .name = "a-counter" });
    try std.testing.expectError(spec.FormatError.UnsupportedValueType, err);
}

test "meter can create counter instrument and record increase without attributes" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{ .name = "a-counter" });

    try counter.add(10, .{});
    std.debug.assert(counter.aggregated_points.count() == 1);
}

test "meter can create counter instrument and record increase with attributes" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createCounter(u32, .{
        .name = "a-counter",
        .description = "a funny counter",
        .unit = "KiB",
    });

    try counter.add(100, .{});
    try counter.add(1000, .{});

    // In record-time sum aggregation, identical attributes aggregate into 1 point
    std.debug.assert(counter.aggregated_points.count() == 1);
    std.debug.assert(counter.aggregated_points.values()[0].value == 1100);

    const val1: []const u8 = "some-value";
    const val2: []const u8 = "another-value";

    try counter.add(2, .{ "some-key", val1, "another-key", val2 });
    std.debug.assert(counter.aggregated_points.count() == 2);
    std.debug.assert(counter.aggregated_points.values()[1].value == 2);
}

test "histogram records value without explicit buckets" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "anything" });

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    // Aggregates in place at record time: single attribute set yields 1 HistogramDataPoint
    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.histogram);
    }

    try std.testing.expectEqual(1, measurements.histogram.len);
    const dp = measurements.histogram[0].value;
    try std.testing.expectEqual(3, dp.count);
    try std.testing.expectEqual(21, dp.sum.?);
    try std.testing.expectEqual(1, dp.min.?);
    try std.testing.expectEqual(15, dp.max.?);
}

test "histogram records value with explicit buckets" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });
    histogram.buckets = &[_]f64{ 2.0, 10.0 };

    try histogram.record(1, .{});
    try histogram.record(5, .{});
    try histogram.record(15, .{});

    try std.testing.expectEqual(1, histogram.explicit_points.count());

    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.histogram);
    }

    try std.testing.expectEqual(1, measurements.histogram.len);
    const dp = measurements.histogram[0].value;
    try std.testing.expectEqual(3, dp.count);
    try std.testing.expectEqual(21, dp.sum.?);
    try std.testing.expectEqual(1, dp.min.?);
    try std.testing.expectEqual(15, dp.max.?);
    // Buckets: <= 2.0 (1), <= 10.0 (1), > 10.0 (1)
    try std.testing.expectEqual(3, dp.bucket_counts.len);
    try std.testing.expectEqual(1, dp.bucket_counts[0]);
    try std.testing.expectEqual(1, dp.bucket_counts[1]);
    try std.testing.expectEqual(1, dp.bucket_counts[2]);
}

test "histogram keeps track of bucket counts by attribute" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });

    const val: []const u8 = "some-value";
    try histogram.record(1, .{ "some-key", val });
    try histogram.record(1000, .{ "other-key", val });

    try std.testing.expectEqual(2, histogram.explicit_points.count());

    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.histogram);
    }

    try std.testing.expectEqual(2, measurements.histogram.len);
}

test "histogram keeps track of count, sum and min/max by attribute" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "a-histogram" });

    const val: []const u8 = "some-val";
    try histogram.record(1, .{});
    try histogram.record(5, .{ "key", val });
    try histogram.record(15, .{ "key", val });

    std.debug.assert(histogram.explicit_points.count() == 2);

    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.histogram);
    }

    // 2 attribute sets: empty attributes and {"key": "some-val"}
    try std.testing.expectEqual(2, measurements.histogram.len);

    var found_empty = false;
    var found_key = false;

    for (measurements.histogram) |dp| {
        if (dp.attributes == null) {
            found_empty = true;
            try std.testing.expectEqual(1, dp.value.count);
            try std.testing.expectEqual(1, dp.value.sum.?);
            try std.testing.expectEqual(1, dp.value.min.?);
            try std.testing.expectEqual(1, dp.value.max.?);
        } else {
            found_key = true;
            try std.testing.expectEqual(2, dp.value.count);
            try std.testing.expectEqual(20, dp.value.sum.?);
            try std.testing.expectEqual(5, dp.value.min.?);
            try std.testing.expectEqual(15, dp.value.max.?);
        }
    }

    try std.testing.expect(found_empty);
    try std.testing.expect(found_key);
}

test "histogram aggregates measurements in place without growing memory" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(f64, .{ .name = "latency" });

    const val: []const u8 = "127.0.0.1";
    for (0..10_000) |i| {
        try histogram.record(@floatFromInt(i % 100), .{ "server.address", val });
    }

    // Must be exactly 1 series in memory despite 10,000 recordings
    try std.testing.expectEqual(1, histogram.explicit_points.count());

    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.histogram);
    }

    try std.testing.expectEqual(1, measurements.histogram.len);
    try std.testing.expectEqual(10_000, measurements.histogram[0].value.count);
}

test "histogram enforces cardinality limit" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(u32, .{ .name = "cardinality-test" });
    histogram.cardinality_limit = 2;

    try histogram.record(1, .{ "attr", @as([]const u8, "a") });
    try histogram.record(2, .{ "attr", @as([]const u8, "b") });
    try histogram.record(3, .{ "attr", @as([]const u8, "c") }); // dropped

    try std.testing.expectEqual(2, histogram.explicit_points.count());
}

test "histogram exponential bucket mode aggregates in place" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var histogram = try meter.createHistogram(f64, .{ .name = "exp-test" });
    histogram.mode = .exponential;
    histogram.max_scale = 10;
    histogram.max_size = 4;

    try histogram.record(1.0, .{});
    try histogram.record(2.0, .{});
    try histogram.record(4.0, .{});

    try std.testing.expectEqual(1, histogram.exponential_points.count());

    const measurements = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (measurements.exponential_histogram) |*dp| {
            dp.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(measurements.exponential_histogram);
    }

    try std.testing.expectEqual(1, measurements.exponential_histogram.len);
    const dp = measurements.exponential_histogram[0].value;
    try std.testing.expectEqual(3, dp.count);
    try std.testing.expectEqual(7.0, dp.sum.?);
}

test "gauge instrument records value without attributes" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i16, .{ .name = "a-gauge" });

    try gauge.record(42, .{});
    try gauge.record(-42, .{});
    // In record-time last-value aggregation, identical attributes aggregate into 1 point
    std.debug.assert(gauge.aggregated_points.count() == 1);
    std.debug.assert(gauge.aggregated_points.values()[0].value == -42);
}

test "gauge keeps separate last value per attribute set" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(f64, .{ .name = "temperature" });

    try gauge.record(20.5, .{ "room", @as([]const u8, "kitchen") });
    try gauge.record(22.0, .{ "room", @as([]const u8, "living_room") });
    try gauge.record(21.0, .{ "room", @as([]const u8, "kitchen") });

    try std.testing.expectEqual(@as(usize, 2), gauge.aggregated_points.count());

    var measurements = try gauge.measurementsData(std.testing.allocator);
    defer measurements.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), measurements.double.len);
    for (measurements.double) |dp| {
        const room = dp.attributes.?[0].value.string;
        if (std.mem.eql(u8, room, "kitchen")) {
            try std.testing.expectEqual(21.0, dp.value);
        } else if (std.mem.eql(u8, room, "living_room")) {
            try std.testing.expectEqual(22.0, dp.value);
        } else {
            return error.UnexpectedAttribute;
        }
    }
}

test "gauge cardinality limit creates overflow series and records excess measurements" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i64, .{ .name = "gauge-cardinality" });
    gauge.cardinality_limit = 3;

    try gauge.record(10, .{ "k", @as([]const u8, "v1") });
    try gauge.record(20, .{ "k", @as([]const u8, "v2") });
    // Limit is 3, so at 3 - 1 = 2 regular series, next series goes to overflow
    try gauge.record(30, .{ "k", @as([]const u8, "v3") });
    try gauge.record(40, .{ "k", @as([]const u8, "v4") });

    // Should have 3 points: v1, v2, and the overflow series
    try std.testing.expectEqual(@as(usize, 3), gauge.aggregated_points.count());

    // The overflow series should hold the latest value (40)
    var found_overflow = false;
    for (gauge.aggregated_points.values()) |dp| {
        if (dp.attributes) |attrs| {
            if (attrs.len == 1 and std.mem.eql(u8, attrs[0].key, "otel.metric.overflow")) {
                found_overflow = true;
                try std.testing.expectEqual(@as(i64, 40), dp.value);
            }
        }
    }
    try std.testing.expect(found_overflow);
}

test "gauge record existing series performs zero heap allocations" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(f64, .{ .name = "zero-alloc-gauge" });

    // Initial record creates the series
    try gauge.record(1.0, .{ "host", @as([]const u8, "server-1") });

    // Subsequent records to the same series must not allocate any heap memory
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const prev_allocator = gauge.allocator;
    gauge.allocator = failing_allocator.allocator();
    defer gauge.allocator = prev_allocator;

    try gauge.record(2.5, .{ "host", @as([]const u8, "server-1") });
    try gauge.record(3.5, .{ "host", @as([]const u8, "server-1") });

    try std.testing.expectEqual(@as(usize, 1), gauge.aggregated_points.count());
    try std.testing.expectEqual(3.5, gauge.aggregated_points.values()[0].value);
}

test "gauge setPreLastValue drains pending raw data points" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i32, .{ .name = "drain-gauge" });

    // Disable pre-aggregation to accumulate raw points
    gauge.setPreLastValue(false);
    try gauge.record(10, .{ "color", @as([]const u8, "red") });
    try gauge.record(20, .{ "color", @as([]const u8, "blue") });
    try gauge.record(30, .{ "color", @as([]const u8, "red") });
    try std.testing.expectEqual(@as(usize, 3), gauge.data_points.items.len);
    try std.testing.expectEqual(@as(usize, 0), gauge.aggregated_points.count());

    // Switch back to pre-aggregation: drains into aggregated_points
    gauge.setPreLastValue(true);
    try std.testing.expectEqual(@as(usize, 0), gauge.data_points.items.len);
    try std.testing.expectEqual(@as(usize, 2), gauge.aggregated_points.count());
}

test "gauge setPreLastValue failed drain reverts to raw recording mode" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var gauge = try meter.createGauge(i32, .{ .name = "drain-fail-gauge" });

    gauge.setPreLastValue(false);
    try gauge.record(10, .{ "color", @as([]const u8, "red") });
    try std.testing.expectEqual(@as(usize, 1), gauge.data_points.items.len);

    // Make allocations fail during drain
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const prev_allocator = gauge.allocator;
    gauge.allocator = failing_allocator.allocator();

    // Drain fails because put/copyAttributes fails:
    gauge.setPreLastValue(true);
    // Mode must revert to false so new points are not inserted out of order
    try std.testing.expectEqual(false, gauge.pre_last_value);
    try std.testing.expectEqual(@as(usize, 1), gauge.data_points.items.len);

    // Restore allocator
    gauge.allocator = prev_allocator;
    // Record another measurement: appends to raw data_points in chronological order
    try gauge.record(20, .{ "color", @as([]const u8, "red") });
    try std.testing.expectEqual(@as(usize, 2), gauge.data_points.items.len);

    // Subsequent drain succeeds
    gauge.setPreLastValue(true);
    try std.testing.expectEqual(true, gauge.pre_last_value);
    try std.testing.expectEqual(@as(usize, 0), gauge.data_points.items.len);
    try std.testing.expectEqual(@as(usize, 1), gauge.aggregated_points.count());
    try std.testing.expectEqual(@as(i64, 20), gauge.aggregated_points.values()[0].value);
}

test "gauge mixed aggregated and raw points share the collection start time" {
    const io = std.testing.io;
    var g = Gauge(i32).init(std.testing.allocator, io);
    defer g.deinit();
    g.collection_start_ns = 1;

    try g.record(10, .{ "color", @as([]const u8, "red") });
    g.setPreLastValue(false);
    try g.record(20, .{ "color", @as([]const u8, "blue") });

    var data = try g.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, data.int.len);
    for (data.int) |point| try std.testing.expectEqual(1, point.timestamps.?.start_time_ns);
    try std.testing.expectEqual(@max(data.int[0].timestamps.?.time_ns, data.int[1].timestamps.?.time_ns), g.collection_start_ns);
}

fn testGaugeAllocationFailures(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var g = Gauge(f64).init(allocator, io);
    defer g.deinit();
    g.cardinality_limit = 2;

    try g.record(10.0, .{ "status", @as([]const u8, "200") });
    try g.record(5.0, .{ "status", @as([]const u8, "200") });
    try g.record(20.0, .{ "status", @as([]const u8, "404") });
    try g.record(30.0, .{ "status", @as([]const u8, "500") });

    var data = try g.measurementsData(allocator);
    defer data.deinit(allocator);
}

test "gauge in-place aggregation handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testGaugeAllocationFailures, .{});
}

test "upDownCounter instrument records and stores value" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();
    const meter = try mp.getMeter(.{ .name = "my-meter" });
    var counter = try meter.createUpDownCounter(i32, .{ .name = "up-down-counter" });

    try counter.add(10, .{});
    try counter.add(-5, .{});
    try counter.add(-4, .{});
    std.debug.assert(counter.aggregated_points.count() == 1);
    try std.testing.expectEqual(1, counter.aggregated_points.values()[0].value);

    try counter.add(1, .{ "some-key", @as(i64, 42) });

    std.debug.assert(counter.aggregated_points.count() == 2);
    try std.testing.expectEqual(1, counter.aggregated_points.values()[1].value);
}

test "instrument in meter and instrument in data are the same" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });
    try c.add(100, .{});

    const id = try spec.instrumentIdentifier(
        std.testing.allocator,
        name,
        Kind.Counter.toString(),
        "",
        "",
    );
    defer std.testing.allocator.free(id);

    if (meter.instruments.get(id)) |instrument| {
        std.debug.assert(instrument.kind == Kind.Counter);

        const counter_value = instrument.data.Counter_u64.aggregated_points.get(Attributes.with(null)) orelse unreachable;
        try std.testing.expectEqual(100, counter_value.value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.scope.name });
    }
}

test "instrument fetches measurements from inner" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });
    try c.add(100, .{});

    const id = try spec.instrumentIdentifier(
        std.testing.allocator,
        name,
        Kind.Counter.toString(),
        "",
        "",
    );
    defer std.testing.allocator.free(id);

    if (meter.instruments.get(id)) |instrument| {
        const measurements = try instrument.getInstrumentsData(std.testing.allocator);
        defer switch (measurements) {
            inline else => |list| std.testing.allocator.free(list),
        };

        std.debug.assert(measurements.int.len == 1);
        try std.testing.expectEqual(@as(i64, 100), measurements.int[0].value);
    } else {
        std.debug.panic("Counter {s} not found in meter {s} after creation", .{ name, meter.scope.name });
    }
}

test "counter thread-safety between datapoints collection and recording" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });

    // We use attributes to perform memory allocation,
    // slowing down the add() call, retaining the lock
    // for longer
    const val: []const u8 = "test-val";
    try c.add(1, .{ "cde", val });

    const adding_job = try std.Thread.spawn(.{}, testCounterAddingOne, .{c});
    const fetch_compare = try std.Thread.spawn(.{}, testCounterCollect, .{c});
    adding_job.join();
    fetch_compare.join();
}

fn testCounterAddingOne(counter: *Counter(u64)) !void {
    const val: []const u8 = "test-val";
    try counter.add(2, .{ "abc", val });
}

fn testCounterCollect(counter: *Counter(u64)) !void {
    // FIXME flaky test can result in failure, so we added a sleep but we should find a more robust solution.
    for (0..1000) |_| {
        counter.lock.lockUncancelable(counter.io);
        counter.lock.unlock(counter.io);
        std.Io.sleep(std.testing.io, .fromNanoseconds(25), .awake) catch {};
    }

    const fetched = try counter.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }
    // Assert that we have 2 data points: the first added by the test thread,
    // the second added by `testAddingOne` called in a separate thread.
    try std.testing.expectEqual(2, fetched.int.len);
    try std.testing.expectEqual(1, fetched.int[0].value);
    try std.testing.expectEqual(2, fetched.int[1].value);
}

test "histogram thread-safety" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var h = try meter.createHistogram(u64, .{ .name = name });

    const val: []const u8 = "same-val";
    try h.record(20, .{ "same-key", val });

    const adding_job = try std.Thread.spawn(.{}, testHistogramRecordOne, .{h});
    const fetch_compare = try std.Thread.spawn(.{}, testHistogramCollect, .{h});
    adding_job.join();
    fetch_compare.join();
}

fn testHistogramRecordOne(histogram: *Histogram(u64)) !void {
    const val: []const u8 = "same-val";
    try histogram.record(1, .{ "same-key", val });
}

fn testHistogramCollect(histogram: *Histogram(u64)) !void {
    // FIXME flaky test can result in failure, so we added a sleep but we should find a more robust solution.
    for (0..1000) |_| {
        histogram.lock.lockUncancelable(histogram.io);
        histogram.lock.unlock(histogram.io);
        std.Io.sleep(std.testing.io, .fromNanoseconds(25), .awake) catch {};
    }

    const fetched = try histogram.measurementsData(std.testing.allocator);
    defer {
        for (fetched.histogram) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.histogram);
    }
    // Both recordings have the same attribute set, aggregating into 1 HistogramDataPoint
    try std.testing.expectEqual(1, fetched.histogram.len);
    try std.testing.expectEqual(2, fetched.histogram[0].value.count);
    try std.testing.expectEqual(21, fetched.histogram[0].value.sum.?);
}

test "instrument cleans up internal state when datapoints are fetched" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const name = "test-instrument";

    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var c = try meter.createCounter(u64, .{ .name = name });

    const val: []const u8 = "test-val";
    try c.add(1, .{ "cde", val });

    const fetched = try c.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }
    // Assert that we have 1 data point: the first added by the test thread.
    try std.testing.expectEqual(0, c.aggregated_points.count());
    try std.testing.expectEqual(0, c.data_points.items.len);
}

const MetricObserveError = AsyncInstrument.MetricObserveError;

test "async instrument registered in meter" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const background = struct {
        fn observe(_: AsyncInstrument.ObservedContext, _: std.mem.Allocator) MetricObserveError!MeasurementsData {
            // This is a dummy callback that does nothing.
            // In a real-world scenario, it would collect data asynchronously.
            return MeasurementsData{
                .int = &.{},
            };
        }
    };

    const name = "test-async-counter";
    const meter = try mp.getMeter(.{ .name = "test-meter" });

    var callbacks = [_]AsyncInstrument.ObserveMeasures{
        background.observe,
    };

    var async_counter = try meter.createObservableCounter(
        .{ .name = name },
        .{},
        &callbacks,
    );

    // SDK users aren't expected to call measurementsData on the async instrument,
    // rather simply use the meter to register the instrument
    const data = try async_counter.measurementsData(std.testing.allocator);
    try std.testing.expectEqual(0, data.int.len);
}

test "exemplar recording snapshots caller attributes before draining" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const instr = try Instrument.new(.Counter, .{ .name = "exemplar-counter" }, allocator);
    defer instr.deinit();
    const counter = try instr.counter(std.testing.io, u64);
    counter.exemplar_filter = .always_on;
    var value = [_]u8{ 'f', 'i', 'r', 's', 't' };
    var attrs = [_]Attribute{.{ .key = "request", .value = .{ .string = &value } }};
    const before: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    try counter.addWithSlice(7, &attrs);
    const after: u64 = @intCast(std.Io.Clock.real.now(io).nanoseconds);
    @memcpy(&value, "later");
    var data = try instr.getInstrumentsData(allocator);
    defer data.deinit(allocator);
    const sample = data.int[0].exemplar_candidate.?;
    try std.testing.expectEqualStrings("first", sample.filtered_attributes[0].value.string);
    try std.testing.expect(sample.time_ns >= before and sample.time_ns <= after);
    try std.testing.expectEqual(@as(i64, 7), sample.value.int);
    try std.testing.expectEqual(@as(usize, 0), counter.aggregated_points.count());
    try std.testing.expectEqual(@as(usize, 0), counter.data_points.items.len);
}

test "exemplar recording keeps sampled span IDs after context ends" {
    const allocator = std.testing.allocator;
    const instr = try Instrument.new(.Histogram, .{ .name = "exemplar-histogram" }, allocator);
    defer instr.deinit();
    const histogram = try instr.histogram(std.testing.io, f64);
    {
        defer context_api.cleanup();
        const sc = trace_api.SpanContext.init(trace_api.TraceID.init(@splat(1)), trace_api.SpanID.init(@splat(2)), .sampled(), trace_api.TraceState.init(allocator), false);
        const ctx = try trace_api.insertSpanContext(allocator, sc);
        defer trace_api.freeSerializedSpanContext(allocator, ctx);
        _ = try context_api.attachContext(ctx);
        try histogram.record(2.5, .{});
    }
    var data = try instr.getInstrumentsData(allocator);
    defer data.deinit(allocator);
    const sample = data.double[0].exemplar_candidate.?;
    try std.testing.expectEqualSlices(u8, &@as([16]u8, @splat(1)), &sample.trace_id.?);
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(2)), &sample.span_id.?);
    try std.testing.expectEqual(@as(f64, 2.5), sample.value.double);
}

fn recordRequests(counter: *Counter(u64), count: usize) !void {
    const route: []const u8 = "/api/v1/users";
    for (0..count) |_| {
        try counter.add(1, .{ "http.route", route, "http.status_code", @as(i64, 200) });
    }
}

test "counter aggregates measurements in place in constant memory" {
    const io = std.testing.io;

    // Large enough for one series, far too small for thousands of raw measurements.
    var buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var counter = Counter(u64).init(fixed.allocator(), io);
    defer counter.deinit();

    try recordRequests(&counter, 10_000);
    try std.testing.expectEqual(1, counter.aggregated_points.count());
    try std.testing.expectEqual(10_000, counter.aggregated_points.values()[0].value);

    // Control: the same buffer cannot hold the raw measurements.
    var raw_buffer: [16 * 1024]u8 = undefined;
    var raw_fixed = std.heap.FixedBufferAllocator.init(&raw_buffer);
    var raw_counter = Counter(u64).init(raw_fixed.allocator(), io);
    defer raw_counter.deinit();
    raw_counter.setPreSum(false);
    try std.testing.expectError(error.OutOfMemory, recordRequests(&raw_counter, 10_000));

    const fetched = try counter.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }

    try std.testing.expectEqual(1, fetched.int.len);
    try std.testing.expectEqual(10_000, fetched.int[0].value);
    try std.testing.expectEqual(0, counter.aggregated_points.count());
}

test "counter enforces cardinality limit with overflow series" {
    const io = std.testing.io;
    const mp = try MeterProvider.init(std.testing.allocator, io);
    defer mp.deinit();

    const meter = try mp.getMeter(.{ .name = "test-meter" });
    var counter = try meter.createCounter(u64, .{ .name = "high.cardinality" });
    counter.cardinality_limit = 3;

    // The overflow series is created before the limit is reached and takes one of its slots:
    // with a limit of 3, only 2 regular series fit.
    try counter.add(1, .{ "id", @as(i64, 1) });
    try counter.add(2, .{ "id", @as(i64, 2) });
    try std.testing.expectEqual(2, counter.aggregated_points.count());

    // The 3rd distinct attribute set goes to the overflow series (otel.metric.overflow=true),
    // and so do the following ones.
    try counter.add(3, .{ "id", @as(i64, 3) });
    try std.testing.expectEqual(3, counter.aggregated_points.count());
    try counter.add(4, .{ "id", @as(i64, 4) });
    try std.testing.expectEqual(3, counter.aggregated_points.count());

    // Existing attribute sets can still be updated
    try counter.add(10, .{ "id", @as(i64, 1) });
    try std.testing.expectEqual(11, counter.aggregated_points.values()[0].value);

    const fetched = try counter.measurementsData(std.testing.allocator);
    defer {
        for (fetched.int) |*m| {
            m.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(fetched.int);
    }

    try std.testing.expectEqual(3, fetched.int.len);
    // The overflow series holds the sum of the measurements that did not fit: 3 + 4.
    var found_overflow = false;
    for (fetched.int) |point| {
        if (point.attributes) |attrs| {
            for (attrs) |attr| {
                if (std.mem.eql(u8, attr.key, "otel.metric.overflow")) {
                    found_overflow = true;
                    try std.testing.expectEqual(@as(i64, 7), point.value);
                }
            }
        }
    }
    try std.testing.expect(found_overflow);
}

test "counter falls back to raw data points when non-Sum view is configured" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const mp = try MeterProvider.init(allocator, io);
    defer mp.deinit();

    // Register a view specifying ExplicitBucketHistogram for this counter
    const view_mod = @import("../../sdk/metrics/view.zig");
    try mp.addView(view_mod.View{
        .instrument_selector = .{ .name = "histogram_counter" },
        .aggregation = .{ .ExplicitBucketHistogram = .{} },
        .temporality = .Cumulative,
    });

    var meter = try mp.getMeter(.{ .name = "test-fallback" });
    const counter = try meter.createCounter(u64, .{ .name = "histogram_counter" });

    // Counter must have pre_sum disabled because view does not resolve to Sum
    try std.testing.expect(!counter.pre_sum);

    try counter.add(10, .{ "status", @as([]const u8, "200") });
    try counter.add(20, .{ "status", @as([]const u8, "200") });

    // Measurements are retained as raw items in data_points
    try std.testing.expectEqual(@as(usize, 2), counter.data_points.items.len);
    try std.testing.expectEqual(@as(usize, 0), counter.aggregated_points.count());

    var data = try counter.measurementsData(allocator);
    defer data.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), data.int.len);
    try std.testing.expectEqual(@as(i64, 10), data.int[0].value);
    try std.testing.expectEqual(@as(i64, 20), data.int[1].value);
}

test "counter running total stored as i64 does not overflow small types" {
    const io = std.testing.io;
    var counter = Counter(u16).init(std.testing.allocator, io);
    defer counter.deinit();

    // Adding 50,000 twice to a u16 counter (u16 max is 65,535)
    try counter.add(50_000, .{ "key", @as([]const u8, "val") });
    try counter.add(50_000, .{ "key", @as([]const u8, "val") });

    try std.testing.expectEqual(1, counter.aggregated_points.count());
    try std.testing.expectEqual(@as(i64, 100_000), counter.aggregated_points.values()[0].value);

    var data = try counter.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 100_000), data.int[0].value);
}

fn testCounterAllocationFailures(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var c = Counter(u32).init(allocator, io);
    defer c.deinit();
    c.cardinality_limit = 2;

    try c.add(10, .{ "status", @as([]const u8, "200") });
    try c.add(5, .{ "status", @as([]const u8, "200") });
    try c.add(20, .{ "status", @as([]const u8, "404") });
    try c.add(30, .{ "status", @as([]const u8, "500") });
    try c.add(40, .{ "status", @as([]const u8, "502") });

    var data = try c.measurementsData(allocator);
    defer data.deinit(allocator);
}

test "counter in-place aggregation handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCounterAllocationFailures, .{});
}

fn testSwitchBackToSumAllocationFailures(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var c = Counter(u32).init(allocator, io);
    defer c.deinit();
    c.cardinality_limit = 3;

    c.setPreSum(false);
    try c.add(1, .{ "status", @as([]const u8, "200") });
    try c.add(2, .{ "status", @as([]const u8, "200") });
    try c.add(3, .{ "status", @as([]const u8, "404") });
    try c.add(4, .{ "status", @as([]const u8, "500") });
    try c.add(5, .{ "status", @as([]const u8, "502") });

    // A failure while draining must leave the remaining raw points valid.
    c.setPreSum(true);

    var data = try c.measurementsData(allocator);
    defer data.deinit(allocator);

    var total: i64 = 0;
    for (data.int) |point| total += point.value;
    try std.testing.expectEqual(15, total);
}

test "switching back to Sum handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testSwitchBackToSumAllocationFailures, .{});
}

test "counter mixed aggregated and raw points share the collection start time" {
    const io = std.testing.io;
    var c = Counter(u32).init(std.testing.allocator, io);
    defer c.deinit();
    c.collection_start_ns = 1;

    try c.add(1, .{ "status", @as([]const u8, "200") });
    c.setPreSum(false);
    try c.add(2, .{ "status", @as([]const u8, "404") });

    var data = try c.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, data.int.len);
    for (data.int) |point| try std.testing.expectEqual(1, point.timestamps.?.start_time_ns);
    try std.testing.expectEqual(@max(data.int[0].timestamps.?.time_ns, data.int[1].timestamps.?.time_ns), c.collection_start_ns);
}

test "switching back to Sum keeps the exemplars captured at record time" {
    const io = std.testing.io;
    var c = Counter(u64).init(std.testing.allocator, io);
    defer c.deinit();

    c.setPreSum(false);
    c.exemplar_filter = .always_on;
    try c.add(7, .{ "route", @as([]const u8, "/sampled") });
    c.exemplar_filter = .always_off;
    try c.add(3, .{ "route", @as([]const u8, "/filtered") });

    // The filter in effect while draining must not matter.
    c.exemplar_filter = .always_off;
    c.setPreSum(true);

    var data = try c.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(2, data.int.len);
    for (data.int) |point| {
        switch (point.value) {
            7 => try std.testing.expectEqual(@as(i64, 7), point.exemplar_candidate.?.value.int),
            3 => try std.testing.expect(point.exemplar_candidate == null),
            else => return error.UnexpectedPoint,
        }
    }
}

test "switching back to Sum does not invent exemplars for filtered measurements" {
    const io = std.testing.io;
    var c = Counter(u64).init(std.testing.allocator, io);
    defer c.deinit();

    c.setPreSum(false);
    c.exemplar_filter = .always_off;
    try c.add(3, .{ "route", @as([]const u8, "/filtered") });

    c.exemplar_filter = .always_on;
    c.setPreSum(true);

    var data = try c.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(1, data.int.len);
    try std.testing.expect(data.int[0].exemplar_candidate == null);
}

test "histogram cardinality limit creates overflow series and aggregates excess measurements" {
    const io = std.testing.io;
    var h = Histogram(f64).init(std.testing.allocator, io);
    defer h.deinit();
    h.pre_aggregate = true;
    h.cardinality_limit = 3; // Allows 2 regular series + 1 overflow series

    try h.record(10.0, .{ "status", @as([]const u8, "200") });
    try h.record(20.0, .{ "status", @as([]const u8, "200") });
    try h.record(30.0, .{ "status", @as([]const u8, "404") });

    // 3rd distinct series reaches limit - 1, creating the overflow series
    try h.record(40.0, .{ "status", @as([]const u8, "500") });
    // 4th distinct series aggregates into the overflow series
    try h.record(50.0, .{ "status", @as([]const u8, "502") });

    try std.testing.expectEqual(3, h.explicit_points.count());

    var data = try h.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(3, data.histogram.len);
    var found_overflow = false;
    for (data.histogram) |point| {
        if (point.attributes) |attrs| {
            for (attrs) |attr| {
                if (std.mem.eql(u8, attr.key, "otel.metric.overflow")) {
                    found_overflow = true;
                    try std.testing.expect(attr.value.bool);
                    try std.testing.expectEqual(2, point.value.count);
                    try std.testing.expectEqual(90.0, point.value.sum.?);
                }
            }
        }
    }
    try std.testing.expect(found_overflow);
}

test "histogram explicit buckets retain candidates per bucket" {
    const io = std.testing.io;
    var h = Histogram(f64).init(std.testing.allocator, io);
    defer h.deinit();
    h.pre_aggregate = true;
    h.exemplar_filter = .always_on;

    // Record value in bucket 0 (<= 0)
    try h.record(-5.0, .{ "status", @as([]const u8, "200") });
    // Record value in bucket with boundary 10
    try h.record(7.0, .{ "status", @as([]const u8, "200") });

    var data = try h.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    // 2 bucket exemplars emitted for reservoir attachment
    try std.testing.expectEqual(2, data.histogram.len);
    try std.testing.expect(data.histogram[0].exemplar_candidate != null);
    try std.testing.expect(data.histogram[1].exemplar_candidate != null);
}

test "exponential histogram retains exemplar candidate" {
    const io = std.testing.io;
    var h = Histogram(f64).init(std.testing.allocator, io);
    defer h.deinit();
    h.pre_aggregate = true;
    h.mode = .exponential;
    h.exemplar_filter = .always_on;

    try h.record(12.5, .{ "route", @as([]const u8, "/api") });

    var data = try h.measurementsData(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, data.exponential_histogram.len);
    try std.testing.expect(data.exponential_histogram[0].exemplar_candidate != null);
    try std.testing.expectEqual(12.5, data.exponential_histogram[0].exemplar_candidate.?.value.double);
}

fn testHistogramAllocationFailures(allocator: std.mem.Allocator) !void {
    const io = std.testing.io;
    var h = Histogram(f64).init(allocator, io);
    defer h.deinit();
    h.pre_aggregate = true;
    h.cardinality_limit = 2;

    try h.record(10.0, .{ "status", @as([]const u8, "200") });
    try h.record(5.0, .{ "status", @as([]const u8, "200") });
    try h.record(20.0, .{ "status", @as([]const u8, "404") });
    try h.record(30.0, .{ "status", @as([]const u8, "500") });

    var data = try h.measurementsData(allocator);
    defer data.deinit(allocator);
}

test "histogram in-place aggregation handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testHistogramAllocationFailures, .{});
}

fn testHistogramBucketExemplarAllocationFailures(allocator: std.mem.Allocator) !void {
    var h = Histogram(f64).init(allocator, std.testing.io);
    defer h.deinit();
    h.pre_aggregate = true;
    h.exemplar_filter = .always_on;

    // Exemplars in one series but two separate buckets make collection emit an extra exemplar point,
    // whose allocations can fail after the main point was handed to the output slice.
    try h.record(-5.0, .{ "status", @as([]const u8, "200") });
    try h.record(7.0, .{ "status", @as([]const u8, "200") });

    var data = try h.measurementsData(allocator);
    defer data.deinit(allocator);
}

test "histogram bucket exemplar collection handles allocation failures without leaks or double-frees" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testHistogramBucketExemplarAllocationFailures, .{});
}
