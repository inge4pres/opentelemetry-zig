// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

const attribute_types = @import("../../attributes.zig");
const Attribute = attribute_types.Attribute;
const Attributes = attribute_types.Attributes;
const trace = @import("../../api/trace.zig");
const context = @import("../../api/context.zig");
const clock = @import("clock");
pub const ExemplarFilter = @import("../config.zig").MetricsConfig.ExemplarFilter;

/// An owned snapshot of a measurement. Raw candidates contain all attributes;
/// collected exemplars contain only attributes absent from their metric point.
pub const Exemplar = struct {
    value: union(enum) { int: i64, double: f64 },
    time_ns: u64,
    trace_id: ?[16]u8 = null,
    span_id: ?[8]u8 = null,
    filtered_attributes: []Attribute = &.{},

    pub fn capture(comptime T: type, allocator: std.mem.Allocator, value: T, attributes: ?[]const Attribute, filter: ExemplarFilter) !?Exemplar {
        if (filter == .always_off) return null;
        var ids: ?struct { trace_id: [16]u8, span_id: [8]u8, sampled: bool } = null;
        if (trace.extractSpanContext(context.getCurrentContext())) |sc| {
            var state = sc.trace_state;
            defer state.deinit();
            if (sc.isValid()) ids = .{
                .trace_id = sc.trace_id.value,
                .span_id = sc.span_id.value,
                .sampled = sc.trace_flags.isSampled(),
            };
        }
        if (filter == .trace_based and (ids == null or !ids.?.sampled)) return null;
        const time_ns: u64 = @intCast(clock.nanoTimestamp());
        return .{
            .value = switch (@typeInfo(T)) {
                .int => .{ .int = @intCast(value) },
                .float => .{ .double = @floatCast(value) },
                else => @compileError("Exemplars require an integer or floating-point measurement"),
            },
            .time_ns = time_ns,
            .trace_id = if (ids) |id| id.trace_id else null,
            .span_id = if (ids) |id| id.span_id else null,
            .filtered_attributes = try copyAttributes(allocator, attributes orelse &.{}),
        };
    }

    pub fn deepCopy(self: Exemplar, allocator: std.mem.Allocator) !Exemplar {
        var copy = self;
        copy.filtered_attributes = try copyAttributes(allocator, self.filtered_attributes);
        return copy;
    }

    pub fn deinit(self: *Exemplar, allocator: std.mem.Allocator) void {
        for (self.filtered_attributes) |attr| freeAttribute(allocator, attr);
        allocator.free(self.filtered_attributes);
        self.filtered_attributes = &.{};
    }

    pub fn deinitList(allocator: std.mem.Allocator, samples: []Exemplar) void {
        for (samples) |*sample| sample.deinit(allocator);
        allocator.free(samples);
    }

    pub fn copyAttributes(allocator: std.mem.Allocator, attributes: []const Attribute) ![]Attribute {
        const copy = try allocator.alloc(Attribute, attributes.len);
        var initialized: usize = 0;
        errdefer {
            for (copy[0..initialized]) |attr| freeAttribute(allocator, attr);
            allocator.free(copy);
        }
        for (attributes, 0..) |attr, i| {
            copy[i] = try Attribute.dupe(allocator, attr);
            initialized += 1;
        }
        return copy;
    }

    /// Remove attributes already carried by the associated timeseries.
    pub fn retainFilteredAttributes(self: *Exemplar, allocator: std.mem.Allocator, point_attributes: ?[]const Attribute) !void {
        const retained = point_attributes orelse return;
        var count: usize = 0;
        for (self.filtered_attributes) |attr| {
            if (!containsKey(retained, attr.key)) count += 1;
        }
        const filtered = try allocator.alloc(Attribute, count);
        var index: usize = 0;
        for (self.filtered_attributes) |attr| {
            if (containsKey(retained, attr.key)) {
                freeAttribute(allocator, attr);
            } else {
                filtered[index] = attr;
                index += 1;
            }
        }
        allocator.free(self.filtered_attributes);
        self.filtered_attributes = filtered;
    }
};

fn freeAttribute(allocator: std.mem.Allocator, attr: Attribute) void {
    allocator.free(attr.key);
    if (attr.value == .string) allocator.free(attr.value.string);
}

fn containsKey(attributes: []const Attribute, key: []const u8) bool {
    for (attributes) |attr| if (std.mem.eql(u8, attr.key, key)) return true;
    return false;
}

/// Implementations own their sampled payloads and allocate collected slices with
/// the factory allocator. Methods must be safe for concurrent calls. A successful
/// collect transfers ownership and resets the collection; reset discards pending
/// samples without allocating, including after a failed collection.
pub const ExemplarReservoir = union(enum) {
    fixed_size: *BuiltinReservoir,
    aligned: *BuiltinReservoir,
    custom: Custom,

    /// User extensions remain open-ended; built-ins use direct method calls.
    pub const Custom = struct {
        context: *anyopaque,
        vtable: *const VTable,
    };
    pub const VTable = struct {
        offer: *const fn (*anyopaque, *const Exemplar) anyerror!void,
        collect: *const fn (*anyopaque) anyerror![]Exemplar,
        reset: *const fn (*anyopaque) void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn offer(self: ExemplarReservoir, sample: *const Exemplar) !void {
        return switch (self) {
            .fixed_size => |state| state.offer(false, sample),
            .aligned => |state| state.offer(true, sample),
            .custom => |state| state.vtable.offer(state.context, sample),
        };
    }
    pub fn collect(self: ExemplarReservoir) ![]Exemplar {
        return switch (self) {
            .fixed_size, .aligned => |state| state.collect(),
            .custom => |state| state.vtable.collect(state.context),
        };
    }
    pub fn reset(self: ExemplarReservoir) void {
        switch (self) {
            .fixed_size, .aligned => |state| state.reset(),
            .custom => |state| state.vtable.reset(state.context),
        }
    }
    pub fn deinit(self: ExemplarReservoir) void {
        switch (self) {
            .fixed_size, .aligned => |state| state.deinit(),
            .custom => |state| state.vtable.deinit(state.context),
        }
    }
};

pub const ReservoirOptions = union(enum) {
    fixed_size: usize,
    aligned: []const f64,

    pub fn create(self: ReservoirOptions, allocator: std.mem.Allocator, io: std.Io) !ExemplarReservoir {
        return BuiltinReservoir.init(allocator, io, self);
    }
};

pub const ReservoirFactory = *const fn (std.mem.Allocator, std.Io, ReservoirOptions) anyerror!ExemplarReservoir;

pub const SimpleFixedSizeExemplarReservoir = struct {
    pub fn init(allocator: std.mem.Allocator, io: std.Io, size: usize) !ExemplarReservoir {
        return BuiltinReservoir.init(allocator, io, .{ .fixed_size = size });
    }
};

pub const AlignedHistogramBucketExemplarReservoir = struct {
    pub fn init(allocator: std.mem.Allocator, io: std.Io, bounds: []const f64) !ExemplarReservoir {
        return BuiltinReservoir.init(allocator, io, .{ .aligned = bounds });
    }
};

const BuiltinReservoir = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    lock: std.Io.Mutex = .init,
    slots: []?Exemplar,
    bounds: ?[]f64,
    seen: u64 = 0,
    prng: std.Random.DefaultPrng,

    fn init(allocator: std.mem.Allocator, io: std.Io, options: ReservoirOptions) !ExemplarReservoir {
        const size = switch (options) {
            .fixed_size => |size| size,
            .aligned => |bounds| try std.math.add(usize, bounds.len, 1),
        };
        if (size == 0) return error.InvalidExemplarReservoirSize;
        const state = try allocator.create(BuiltinReservoir);
        errdefer allocator.destroy(state);
        const slots = try allocator.alloc(?Exemplar, size);
        errdefer allocator.free(slots);
        @memset(slots, null);
        const bounds = switch (options) {
            .aligned => |bounds| try allocator.dupe(f64, bounds),
            .fixed_size => null,
        };
        var seed: u64 = undefined;
        io.random(std.mem.asBytes(&seed));
        state.* = .{ .allocator = allocator, .io = io, .slots = slots, .bounds = bounds, .prng = std.Random.DefaultPrng.init(seed) };
        return switch (options) {
            .fixed_size => .{ .fixed_size = state },
            .aligned => .{ .aligned = state },
        };
    }

    fn offer(self: *BuiltinReservoir, comptime aligned: bool, sample: *const Exemplar) !void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        const index = if (aligned) blk: {
            const bounds = self.bounds.?;
            const value = switch (sample.value) {
                .int => |v| @as(f64, @floatFromInt(v)),
                .double => |v| v,
            };
            for (bounds, 0..) |bound, i| if (value <= bound) break :blk i;
            break :blk bounds.len;
        } else blk: {
            self.seen = try std.math.add(u64, self.seen, 1);
            break :blk if (self.seen <= self.slots.len)
                @as(usize, @intCast(self.seen - 1))
            else
                @as(usize, @intCast(self.prng.random().uintLessThan(u64, self.seen)));
        };
        if (index >= self.slots.len) return;
        const copy = try sample.deepCopy(self.allocator);
        if (self.slots[index]) |*previous| previous.deinit(self.allocator);
        self.slots[index] = copy;
    }

    fn collect(self: *BuiltinReservoir) ![]Exemplar {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        var count: usize = 0;
        for (self.slots) |slot| if (slot != null) {
            count += 1;
        };
        const collected = try self.allocator.alloc(Exemplar, count);
        var index: usize = 0;
        for (self.slots) |*slot| {
            if (slot.*) |sample| {
                collected[index] = sample;
                index += 1;
                slot.* = null;
            }
        }
        self.seen = 0;
        return collected;
    }

    fn reset(self: *BuiltinReservoir) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.clear();
    }

    fn clear(self: *BuiltinReservoir) void {
        for (self.slots) |*slot| {
            if (slot.*) |*sample| sample.deinit(self.allocator);
            slot.* = null;
        }
        self.seen = 0;
    }

    fn deinit(self: *BuiltinReservoir) void {
        self.lock.lockUncancelable(self.io);
        self.clear();
        self.allocator.free(self.slots);
        if (self.bounds) |bounds| self.allocator.free(bounds);
        self.lock.unlock(self.io);
        self.allocator.destroy(self);
    }
};

pub const StreamIdentity = struct {
    instrument_id: usize,
    aggregation: enum { sum, last_value, explicit_histogram, exponential_histogram } = .sum,
    max_scale: i32 = 0,
    max_size: u32 = 0,
    record_min_max: bool = false,
};

/// Reservoirs for recently sampled streams of one meter. Inactive streams are
/// retired after collection; active streams reuse their reservoir. The optional
/// allocator fixes cache ownership independently of the collection allocator.
pub const Sampler = struct {
    allocator: ?std.mem.Allocator = null,
    reservoirs: std.HashMapUnmanaged(Key, ExemplarReservoir, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

    const Key = struct {
        stream: StreamIdentity,
        options: ReservoirOptions,
        factory: ?ReservoirFactory,
        attributes: ?[]Attribute,
        active: bool = true,
    };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, key: Key) u64 {
            var h = std.hash.Wyhash.init(0);
            std.hash.autoHash(&h, key.stream);
            std.hash.autoHash(&h, if (key.factory) |factory| @intFromPtr(factory) else @as(usize, 0));
            switch (key.options) {
                .fixed_size => |size| {
                    h.update("fixed");
                    std.hash.autoHash(&h, size);
                },
                .aligned => |bounds| {
                    h.update("aligned");
                    h.update(std.mem.sliceAsBytes(bounds));
                },
            }
            std.hash.autoHash(&h, (AttributeSetContext{}).hash(key.attributes));
            return h.final();
        }
        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            if (!std.meta.eql(a.stream, b.stream) or a.factory != b.factory) return false;
            const same_options = switch (a.options) {
                .fixed_size => |size| b.options == .fixed_size and size == b.options.fixed_size,
                .aligned => |bounds| b.options == .aligned and
                    std.mem.eql(u8, std.mem.sliceAsBytes(bounds), std.mem.sliceAsBytes(b.options.aligned)),
            };
            return same_options and (AttributeSetContext{}).eql(a.attributes, b.attributes);
        }
    };

    pub fn deinit(self: *Sampler, fallback_allocator: std.mem.Allocator) void {
        const allocator = self.allocator orelse fallback_allocator;
        var entries = self.reservoirs.iterator();
        while (entries.next()) |entry| {
            entry.value_ptr.deinit();
            freeKey(allocator, entry.key_ptr.*);
        }
        self.reservoirs.deinit(allocator);
        self.reservoirs = .empty;
    }

    pub fn beginCollection(self: *Sampler) void {
        var keys = self.reservoirs.keyIterator();
        while (keys.next()) |key| key.active = false;
    }

    /// Keep reservoirs for active series, releasing historical label sets.
    pub fn endCollection(self: *Sampler) void {
        const allocator = self.allocator orelse return;
        var entries = self.reservoirs.iterator();
        while (entries.next()) |entry| {
            if (entry.key_ptr.active) continue;
            entry.value_ptr.deinit();
            freeKey(allocator, entry.key_ptr.*);
            self.reservoirs.removeByPtr(entry.key_ptr);
        }
    }

    fn freeKey(allocator: std.mem.Allocator, key: Key) void {
        if (key.attributes) |attrs| {
            for (attrs) |attr| freeAttribute(allocator, attr);
            allocator.free(attrs);
        }
        if (key.options == .aligned) allocator.free(key.options.aligned);
    }

    fn getOrCreate(self: *Sampler, allocator: std.mem.Allocator, io: std.Io, lookup: Key) !*ExemplarReservoir {
        if (self.reservoirs.getEntry(lookup)) |existing| {
            existing.key_ptr.active = true;
            return existing.value_ptr;
        }
        var key = lookup;
        key.attributes = if (lookup.attributes) |attrs| try Exemplar.copyAttributes(allocator, attrs) else null;
        errdefer if (key.attributes) |attrs| {
            for (attrs) |attr| freeAttribute(allocator, attr);
            allocator.free(attrs);
        };
        key.options = switch (lookup.options) {
            .fixed_size => |size| .{ .fixed_size = size },
            .aligned => |bounds| .{ .aligned = try allocator.dupe(f64, bounds) },
        };
        errdefer if (key.options == .aligned) allocator.free(key.options.aligned);
        const reservoir = if (key.factory) |factory|
            try factory(allocator, io, key.options)
        else
            try key.options.create(allocator, io);
        errdefer reservoir.deinit();
        try self.reservoirs.putNoClobber(allocator, key, reservoir);
        return self.reservoirs.getPtr(lookup).?;
    }

    fn reset(self: *Sampler) void {
        var reservoirs = self.reservoirs.valueIterator();
        while (reservoirs.next()) |reservoir| reservoir.reset();
    }

    /// Inputs have already been grouped using the selected View's attributes.
    /// The meter serializes access; reservoir implementations serialize their
    /// own offer/collect methods. No reservoir work occurs without candidates.
    pub fn attach(self: *Sampler, output_allocator: std.mem.Allocator, io: std.Io, stream: StreamIdentity, options: ReservoirOptions, factory: ?ReservoirFactory, raw: anytype, output: anytype) !void {
        var has_candidates = false;
        for (raw) |point| if (point.exemplar_candidate != null) {
            has_candidates = true;
            break;
        };
        if (!has_candidates) return;
        const cache_allocator = self.allocator orelse output_allocator;
        self.allocator = cache_allocator;
        errdefer self.reset();
        var indices = std.HashMapUnmanaged(?[]Attribute, usize, AttributeSetContext, std.hash_map.default_max_load_percentage).empty;
        defer indices.deinit(output_allocator);
        for (output, 0..) |point, index| try indices.put(output_allocator, point.attributes, index);
        for (raw) |point| {
            const sample = point.exemplar_candidate orelse continue;
            const index = indices.get(point.attributes) orelse continue;
            const reservoir = try self.getOrCreate(cache_allocator, io, .{
                .stream = stream,
                .options = options,
                .factory = factory,
                .attributes = output[index].attributes,
            });
            try reservoir.offer(&sample);
        }
        for (output) |*point| {
            const reservoir = self.reservoirs.get(.{
                .stream = stream,
                .options = options,
                .factory = factory,
                .attributes = point.attributes,
            }) orelse continue;
            const owned = try reservoir.collect();
            var samples = owned;
            if (cache_allocator.ptr != output_allocator.ptr or cache_allocator.vtable != output_allocator.vtable) {
                defer Exemplar.deinitList(cache_allocator, owned);
                samples = try copyList(output_allocator, owned);
            }
            errdefer Exemplar.deinitList(output_allocator, samples);
            for (samples) |*sample| {
                try sample.retainFilteredAttributes(output_allocator, point.attributes);
            }
            Exemplar.deinitList(output_allocator, point.exemplars);
            point.exemplars = samples;
        }
    }
};

pub fn copyList(allocator: std.mem.Allocator, samples: []const Exemplar) ![]Exemplar {
    const copied = try allocator.alloc(Exemplar, samples.len);
    var initialized: usize = 0;
    errdefer {
        for (copied[0..initialized]) |*sample| sample.deinit(allocator);
        allocator.free(copied);
    }
    for (samples, 0..) |sample, i| {
        copied[i] = try sample.deepCopy(allocator);
        initialized += 1;
    }
    return copied;
}

const AttributeSetContext = struct {
    pub fn hash(_: AttributeSetContext, attributes: ?[]Attribute) u64 {
        var result: u64 = 0;
        for (attributes orelse &.{}) |attr| {
            var h = std.hash.Wyhash.init(0);
            h.update(attr.key);
            std.hash.autoHash(&h, std.meta.activeTag(attr.value));
            switch (attr.value) {
                .string => |value| h.update(value),
                .int => |value| std.hash.autoHash(&h, value),
                .bool => |value| std.hash.autoHash(&h, value),
                .double => |value| std.hash.autoHash(&h, @as(u64, @bitCast(if (value == 0) @as(f64, 0) else value))),
                .baggage => h.update("baggage"),
            }
            result +%= h.final();
        }
        return result;
    }
    pub fn eql(_: AttributeSetContext, a: ?[]Attribute, b: ?[]Attribute) bool {
        const left = a orelse &.{};
        const right = b orelse &.{};
        if (left.len != right.len) return false;
        for (left) |attr| {
            var found = false;
            for (right) |other| {
                if (!std.mem.eql(u8, attr.key, other.key) or std.meta.activeTag(attr.value) != std.meta.activeTag(other.value)) continue;
                const same_value = switch (attr.value) {
                    .string => |value| std.mem.eql(u8, value, other.value.string),
                    .double => |value| value == other.value.double or
                        @as(u64, @bitCast(value)) == @as(u64, @bitCast(other.value.double)),
                    else => std.meta.eql(attr.value, other.value),
                };
                if (same_value) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
};

test "exemplar fixed reservoir owns samples and resets after collection" {
    const allocator = std.testing.allocator;
    var reservoir = try SimpleFixedSizeExemplarReservoir.init(allocator, std.testing.io, 1);
    defer reservoir.deinit();
    const attrs = [_]Attribute{
        .{ .key = "route", .value = .{ .string = "/one" } },
    };
    var sample = Exemplar{ .value = .{ .int = 7 }, .time_ns = 123, .filtered_attributes = try Exemplar.copyAttributes(allocator, &attrs) };
    try reservoir.offer(&sample);
    sample.deinit(allocator);
    const collected = try reservoir.collect();
    defer Exemplar.deinitList(allocator, collected);
    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqual(@as(i64, 7), collected[0].value.int);
    try std.testing.expectEqual(@as(u64, 123), collected[0].time_ns);
    try std.testing.expectEqualStrings("/one", collected[0].filtered_attributes[0].value.string);
    const empty = try reservoir.collect();
    defer Exemplar.deinitList(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "exemplar aligned reservoir uses inclusive boundaries and last value" {
    const allocator = std.testing.allocator;
    var reservoir = try AlignedHistogramBucketExemplarReservoir.init(allocator, std.testing.io, &.{ 0, 10 });
    defer reservoir.deinit();
    for ([_]f64{ -1, 0, 5, 10, 11, 12 }, 0..) |value, index| {
        const sample = Exemplar{ .value = .{ .double = value }, .time_ns = index + 1 };
        try reservoir.offer(&sample);
    }
    const collected = try reservoir.collect();
    defer Exemplar.deinitList(allocator, collected);
    try std.testing.expectEqual(@as(usize, 3), collected.len);
    try std.testing.expectEqual(@as(f64, 0), collected[0].value.double);
    try std.testing.expectEqual(@as(f64, 10), collected[1].value.double);
    try std.testing.expectEqual(@as(f64, 12), collected[2].value.double);
}

test "exemplar fixed reservoir uniformly samples across a collection" {
    const allocator = std.testing.allocator;
    var reservoir = try SimpleFixedSizeExemplarReservoir.init(allocator, std.testing.io, 1);
    defer reservoir.deinit();
    const state = reservoir.fixed_size;
    state.prng = std.Random.DefaultPrng.init(123);
    var counts: [4]usize = @splat(0);
    for (0..1000) |_| {
        for (0..4) |index| {
            const sample = Exemplar{ .value = .{ .int = @intCast(index) }, .time_ns = 1 };
            try reservoir.offer(&sample);
        }
        const collected = try reservoir.collect();
        defer Exemplar.deinitList(allocator, collected);
        try std.testing.expectEqual(@as(usize, 1), collected.len);
        counts[@intCast(collected[0].value.int)] += 1;
    }
    for (counts) |count| try std.testing.expect(count > 180 and count < 320);
}

test "exemplar disabled filter makes no allocations without a span" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const sample = try Exemplar.capture(i64, failing.allocator(), 1, null, .always_off);
    try std.testing.expectEqual(null, sample);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try std.testing.expectEqual(null, try Exemplar.capture(i64, failing.allocator(), 1, null, .trace_based));
}

test "exemplar copying and sampling clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exemplarAllocationFailure, .{});
}

fn exemplarAllocationFailure(allocator: std.mem.Allocator) !void {
    const attrs = [_]Attribute{
        .{ .key = "route", .value = .{ .string = "/one" } },
    };
    var sample = (try Exemplar.capture(i64, allocator, 7, &attrs, .always_on)).?;
    defer sample.deinit(allocator);
    var reservoir = try SimpleFixedSizeExemplarReservoir.init(allocator, std.testing.io, 2);
    defer reservoir.deinit();
    try reservoir.offer(&sample);
    const collected = try reservoir.collect();
    defer Exemplar.deinitList(allocator, collected);
    for (collected) |*e| try e.retainFilteredAttributes(allocator, &attrs);
}

const SamplerTestPoint = struct {
    attributes: ?[]Attribute = null,
    exemplar_candidate: ?Exemplar = null,
    exemplars: []Exemplar = &.{},
    timestamps: ?struct { time_ns: u64, start_time_ns: ?u64 = null } = .{ .time_ns = 200 },
};

test "exemplar sampler preserves custom reservoirs per series across collections" {
    const allocator = std.testing.allocator;
    const Factory = struct {
        var calls: usize = 0;
        fn create(a: std.mem.Allocator, io: std.Io, _: ReservoirOptions) !ExemplarReservoir {
            calls += 1;
            return SimpleFixedSizeExemplarReservoir.init(a, io, 1);
        }
    };
    Factory.calls = 0;
    var sampler: Sampler = .{};
    defer sampler.deinit(allocator);
    var attrs_a = [_]Attribute{.{ .key = "region", .value = .{ .string = "a" } }};
    var attrs_b = [_]Attribute{.{ .key = "region", .value = .{ .string = "b" } }};
    const raw = [_]SamplerTestPoint{
        .{ .attributes = &attrs_a, .exemplar_candidate = .{ .value = .{ .int = 7 }, .time_ns = 100 } },
        .{ .attributes = &attrs_b, .exemplar_candidate = .{ .value = .{ .int = 9 }, .time_ns = 110 } },
    };
    for (0..2) |_| {
        var output = [_]SamplerTestPoint{ .{ .attributes = &attrs_a }, .{ .attributes = &attrs_b } };
        defer for (&output) |*dp| Exemplar.deinitList(allocator, dp.exemplars);
        try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, Factory.create, &raw, &output);
        try std.testing.expectEqual(@as(usize, 1), output[0].exemplars.len);
        try std.testing.expectEqual(@as(i64, 7), output[0].exemplars[0].value.int);
        try std.testing.expectEqual(@as(i64, 9), output[1].exemplars[0].value.int);
        try std.testing.expectEqual(@as(?u64, null), output[0].timestamps.?.start_time_ns);
    }
    try std.testing.expectEqual(@as(usize, 2), Factory.calls);
}

test "exemplar sampler cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, samplerAllocationFailure, .{});
}

fn samplerAllocationFailure(allocator: std.mem.Allocator) !void {
    var sampler: Sampler = .{};
    defer sampler.deinit(allocator);
    var attrs = [_]Attribute{.{ .key = "region", .value = .{ .string = "a" } }};
    const raw = [_]SamplerTestPoint{.{ .attributes = &attrs, .exemplar_candidate = .{ .value = .{ .int = 7 }, .time_ns = 100 } }};
    var output = [_]SamplerTestPoint{.{ .attributes = &attrs }};
    defer Exemplar.deinitList(allocator, output[0].exemplars);
    try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .aligned = &.{ 1, 10 } }, null, &raw, &output);
}

test "exemplar owned attributes preserve timeseries identity" {
    const allocator = std.testing.allocator;
    var attrs = [_]Attribute{.{ .key = "region", .value = .{ .string = "west" } }};
    var copied = Exemplar{ .value = .{ .int = 1 }, .time_ns = 1, .filtered_attributes = try Exemplar.copyAttributes(allocator, &attrs) };
    defer copied.deinit(allocator);
    try std.testing.expect((Attributes.HashContext{}).eql(Attributes.with(&attrs), Attributes.with(copied.filtered_attributes)));
}

test "exemplar sampling leaves collection boundaries unchanged when a later sample wins" {
    const allocator = std.testing.allocator;
    const Factory = struct {
        fn last(a: std.mem.Allocator, io: std.Io, _: ReservoirOptions) !ExemplarReservoir {
            return AlignedHistogramBucketExemplarReservoir.init(a, io, &.{});
        }
    };
    var sampler: Sampler = .{};
    defer sampler.deinit(allocator);
    const raw = [_]SamplerTestPoint{
        .{ .exemplar_candidate = .{ .value = .{ .int = 1 }, .time_ns = 100 } },
        .{ .exemplar_candidate = .{ .value = .{ .int = 2 }, .time_ns = 110 } },
    };
    var output = [_]SamplerTestPoint{.{}};
    defer Exemplar.deinitList(allocator, output[0].exemplars);
    try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, Factory.last, &raw, &output);
    try std.testing.expectEqual(@as(i64, 2), output[0].exemplars[0].value.int);
    try std.testing.expectEqual(@as(?u64, null), output[0].timestamps.?.start_time_ns);
}

test "exemplar filters require a valid sampled context only for trace based sampling" {
    const allocator = std.testing.allocator;
    const Case = struct { filter: ExemplarFilter, sampled: bool, trace_valid: bool = true, span_valid: bool = true, eligible: bool };
    const cases = [_]Case{
        .{ .filter = .trace_based, .sampled = true, .eligible = true },
        .{ .filter = .trace_based, .sampled = false, .eligible = false },
        .{ .filter = .trace_based, .sampled = true, .trace_valid = false, .eligible = false },
        .{ .filter = .trace_based, .sampled = true, .span_valid = false, .eligible = false },
        .{ .filter = .always_on, .sampled = false, .eligible = true },
        .{ .filter = .always_on, .sampled = true, .trace_valid = false, .eligible = true },
        .{ .filter = .always_off, .sampled = true, .eligible = false },
    };
    for (cases) |case| {
        defer context.cleanup();
        const sc = trace.SpanContext.init(trace.TraceID.init(if (case.trace_valid) @splat(1) else @splat(0)), trace.SpanID.init(if (case.span_valid) @splat(2) else @splat(0)), trace.TraceFlags.init(if (case.sampled) 1 else 0), trace.TraceState.init(allocator), false);
        var ctx = try trace.insertSpanContext(allocator, sc);
        var attached = false;
        errdefer if (!attached) ctx.deinit();
        defer trace.freeSerializedSpanContext(allocator, ctx);
        _ = try context.attachContext(ctx);
        attached = true;
        var sample = try Exemplar.capture(i64, allocator, 7, null, case.filter);
        defer if (sample) |*value| value.deinit(allocator);
        try std.testing.expectEqual(case.eligible, sample != null);
        if (sample) |value| {
            try std.testing.expectEqual(case.trace_valid and case.span_valid, value.trace_id != null);
            try std.testing.expectEqual(case.trace_valid and case.span_valid, value.span_id != null);
        }
    }
}

test "exemplar collected payloads outlive a cache using another allocator" {
    const allocator = std.testing.allocator;
    var tracked = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    var sampler = Sampler{ .allocator = tracked.allocator() };
    var live = true;
    defer if (live) sampler.deinit(allocator);
    var attributes = [_]Attribute{.{ .key = "request", .value = .{ .string = "abc" } }};
    const raw = [_]SamplerTestPoint{.{ .exemplar_candidate = .{
        .value = .{ .int = 7 },
        .time_ns = 100,
        .filtered_attributes = &attributes,
    } }};
    var output = [_]SamplerTestPoint{.{}};
    defer Exemplar.deinitList(allocator, output[0].exemplars);
    try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, null, &raw, &output);
    sampler.deinit(allocator);
    live = false;
    try std.testing.expectEqual(tracked.allocated_bytes, tracked.freed_bytes);
    try std.testing.expectEqualStrings("abc", output[0].exemplars[0].filtered_attributes[0].value.string);
}

test "exemplar sampler retains NaN attribute series and signed zero identity" {
    const allocator = std.testing.allocator;
    const values = [_]f64{ @bitCast(@as(u64, 0x7ff8000000000001)), @bitCast(@as(u64, 0x7ff8000000000002)), std.math.inf(f64), -std.math.inf(f64), 0, -0.0 };
    for (values) |value| {
        var sampler: Sampler = .{};
        defer sampler.deinit(allocator);
        var raw_attrs = [_]Attribute{.{ .key = "value", .value = .{ .double = value } }};
        var output_attrs = raw_attrs;
        const raw = [_]SamplerTestPoint{.{ .attributes = &raw_attrs, .exemplar_candidate = .{ .value = .{ .int = 7 }, .time_ns = 100 } }};
        var output = [_]SamplerTestPoint{.{ .attributes = &output_attrs }};
        defer Exemplar.deinitList(allocator, output[0].exemplars);
        try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, null, &raw, &output);
        try std.testing.expectEqual(@as(usize, 1), output[0].exemplars.len);
        try std.testing.expectEqual(@as(i64, 7), output[0].exemplars[0].value.int);
    }
    var positive = [_]Attribute{.{ .key = "zero", .value = .{ .double = 0 } }};
    var negative = [_]Attribute{.{ .key = "zero", .value = .{ .double = -0.0 } }};
    const ctx = AttributeSetContext{};
    try std.testing.expect(ctx.eql(&positive, &negative));
    try std.testing.expectEqual(ctx.hash(&positive), ctx.hash(&negative));
}

test "exemplar custom extension keeps offer collect reset and ownership hooks" {
    const Custom = struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        inner: ExemplarReservoir,
        offers: usize = 0,
        reset_calls: usize = 0,
        fail_collect: bool = false,
        fn create(a: std.mem.Allocator, io: std.Io, options: ReservoirOptions) !ExemplarReservoir {
            const inner = try options.create(a, io);
            const self = a.create(Self) catch |err| {
                inner.deinit();
                return err;
            };
            self.* = .{ .allocator = a, .inner = inner };
            return .{ .custom = .{ .context = self, .vtable = &.{ .offer = offer, .collect = collect, .reset = reset, .deinit = deinit } } };
        }
        fn allocationFailure(a: std.mem.Allocator) !void {
            var sampler: Sampler = .{};
            defer sampler.deinit(a);
            const raw = [_]SamplerTestPoint{.{ .exemplar_candidate = .{ .value = .{ .int = 7 }, .time_ns = 100 } }};
            var output = [_]SamplerTestPoint{.{}};
            defer Exemplar.deinitList(a, output[0].exemplars);
            try sampler.attach(a, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, create, &raw, &output);
        }
        fn offer(ptr: *anyopaque, sample: *const Exemplar) !void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.offers += 1;
            try self.inner.offer(sample);
        }
        fn collect(ptr: *anyopaque) ![]Exemplar {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.fail_collect) return error.TestCollectionFailed;
            return self.inner.collect();
        }
        fn reset(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.reset_calls += 1;
            self.inner.reset();
        }
        fn deinit(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.inner.deinit();
            self.allocator.destroy(self);
        }
    };
    const allocator = std.testing.allocator;
    const reservoir = try Custom.create(allocator, std.testing.io, .{ .fixed_size = 1 });
    const state: *Custom = @ptrCast(@alignCast(reservoir.custom.context));
    defer reservoir.deinit();
    const sample = Exemplar{ .value = .{ .int = 7 }, .time_ns = 100 };
    try reservoir.offer(&sample);
    const collected = try reservoir.collect();
    defer Exemplar.deinitList(allocator, collected);
    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqual(@as(i64, 7), collected[0].value.int);
    try reservoir.offer(&sample);
    reservoir.reset();
    const empty = try reservoir.collect();
    defer Exemplar.deinitList(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(usize, 2), state.offers);
    try std.testing.expectEqual(@as(usize, 1), state.reset_calls);
    try std.testing.checkAllAllocationFailures(allocator, Custom.allocationFailure, .{});
    var sampler: Sampler = .{};
    defer sampler.deinit(allocator);
    const raw = [_]SamplerTestPoint{.{ .exemplar_candidate = sample }};
    var output = [_]SamplerTestPoint{.{}};
    defer Exemplar.deinitList(allocator, output[0].exemplars);
    try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, Custom.create, &raw, &output);
    var entries = sampler.reservoirs.valueIterator();
    const cached: *Custom = @ptrCast(@alignCast(entries.next().?.custom.context));
    cached.fail_collect = true;
    try std.testing.expectError(error.TestCollectionFailed, sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, Custom.create, &raw, &output));
    try std.testing.expectEqual(@as(usize, 1), cached.reset_calls);
    cached.fail_collect = false;
    const discarded = try cached.inner.collect();
    defer Exemplar.deinitList(allocator, discarded);
    try std.testing.expectEqual(@as(usize, 0), discarded.len);
    try sampler.attach(allocator, std.testing.io, .{ .instrument_id = 1 }, .{ .fixed_size = 1 }, Custom.create, &raw, &output);
    try std.testing.expectEqual(@as(usize, 1), sampler.reservoirs.count());
    try std.testing.expectEqual(@as(usize, 1), output[0].exemplars.len);
}
