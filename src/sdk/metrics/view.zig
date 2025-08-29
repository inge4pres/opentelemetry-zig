const std = @import("std");

const log = std.log.scoped(.view);

const pbmetrics = @import("opentelemetry-proto").metrics_v1;
const instrument = @import("../../api/metrics/instrument.zig");
const Instrument = instrument.Instrument;
const spec = @import("../../api/metrics/spec.zig");
const Attribute = @import("../../attributes.zig").Attribute;
const Attributes = @import("../../attributes.zig").Attributes;
const InstrumentationScope = @import("../../scope.zig").InstrumentationScope;

/// Instrument selector criteria for matching instruments to views
pub const InstrumentSelector = struct {
    /// Match instruments by exact name (case-sensitive)
    name: ?[]const u8 = null,
    /// Match instruments by kind
    kind: ?instrument.Kind = null,
    /// Match instruments by meter name
    meter_name: ?[]const u8 = null,
    /// Match instruments by meter version
    meter_version: ?[]const u8 = null,
    /// Match instruments by meter schema URL
    meter_schema_url: ?[]const u8 = null,

    /// Check if this selector matches the given instrument and meter scope
    pub fn matches(self: InstrumentSelector, instr: *const instrument.Instrument, scope: *const InstrumentationScope) bool {
        // Check instrument name
        if (self.name) |name| {
            if (!std.mem.eql(u8, name, instr.opts.name)) return false;
        }

        // Check instrument kind
        if (self.kind) |kind| {
            if (kind != instr.kind) return false;
        }

        // Check meter name
        if (self.meter_name) |meter_name| {
            if (!std.mem.eql(u8, meter_name, scope.name)) return false;
        }

        // Check meter version
        if (self.meter_version) |meter_version| {
            if (scope.version == null or !std.mem.eql(u8, meter_version, scope.version.?)) return false;
        }

        // Check meter schema URL
        if (self.meter_schema_url) |meter_schema_url| {
            if (scope.schema_url == null or !std.mem.eql(u8, meter_schema_url, scope.schema_url.?)) return false;
        }

        return true;
    }
};

/// Attribute filter for selecting which attributes to include in metrics
pub const AttributeFilter = struct {
    /// Include only these attribute keys (if null, include all)
    include_keys: ?[]const []const u8 = null,
    /// Exclude these attribute keys
    exclude_keys: ?[]const []const u8 = null,

    /// Apply this filter to a set of attributes
    pub fn apply(self: AttributeFilter, allocator: std.mem.Allocator, attributes: ?Attributes) !?Attributes {
        if (attributes == null) return null;

        const attrs = attributes.?;
        var filtered = std.ArrayList(Attribute).init(allocator);
        defer filtered.deinit();

        for (attrs) |attr| {
            var include = true;

            // Check include list (if specified, only these keys are included)
            if (self.include_keys) |include_keys| {
                include = false;
                for (include_keys) |key| {
                    if (std.mem.eql(u8, key, attr.key)) {
                        include = true;
                        break;
                    }
                }
            }

            // Check exclude list (these keys are always excluded)
            if (self.exclude_keys) |exclude_keys| {
                for (exclude_keys) |key| {
                    if (std.mem.eql(u8, key, attr.key)) {
                        include = false;
                        break;
                    }
                }
            }

            if (include) {
                try filtered.append(attr);
            }
        }

        if (filtered.items.len == 0) return null;
        return try allocator.dupe(Attribute, filtered.items);
    }
};

/// View configures the way metrics are read from Meters.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#view
pub const View = struct {
    /// Selector for matching instruments
    instrument_selector: InstrumentSelector,
    /// Optional name override for the metric
    name: ?[]const u8 = null,
    /// Optional description override for the metric
    description: ?[]const u8 = null,
    /// Attribute filter for selecting which attributes to include
    attribute_filter: ?AttributeFilter = null,
    /// Aggregation to apply to matching instruments
    aggregation: Aggregation,
    /// Temporality to apply to matching instruments
    temporality: Temporality,

    const Self = @This();

    /// Check if this view matches the given instrument and meter scope
    pub fn matches(self: *const Self, instr: *const instrument.Instrument, scope: *const InstrumentationScope) bool {
        return self.instrument_selector.matches(instr, scope);
    }

    /// Create a default view that matches all instruments with default aggregation and temporality
    pub fn default() Self {
        return Self{
            .instrument_selector = .{}, // Empty selector matches all
            .aggregation = .Sum, // Will be overridden by DefaultAggregation function
            .temporality = .Cumulative, // Will be overridden by DefaultTemporality function
        };
    }
};

/// Configuration for explicit bucket histogram aggregation
pub const ExplicitBucketHistogramConfig = struct {
    /// Bucket boundaries for the histogram. If null, uses SDK default buckets.
    buckets: []const f64 = spec.default_histogram_explicit_bucket_boundaries,
    /// Whether to record min and max values
    record_min_max: bool = true,
};

/// Configuration for exponential bucket histogram aggregation
pub const ExponentialBucketHistogramConfig = struct {
    /// Maximum scale parameter (determines bucket resolution)
    max_scale: i32 = 20,
    /// Maximum number of buckets before scale reduction
    max_size: u32 = 1024,
    /// Whether to record min and max values
    record_min_max: bool = true,
};

/// Defines the ways and means to compute aggregated metrics.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#aggregation
pub const Aggregation = union(enum) {
    Drop,
    Sum,
    LastValue,
    ExplicitBucketHistogram: ExplicitBucketHistogramConfig,
    ExponentialBucketHistogram: ExponentialBucketHistogramConfig,

    /// Get the aggregation type tag
    // TODO there might be some meta-programmin trick to do this...
    pub fn getType(self: Aggregation) AggregationType {
        return switch (self) {
            .Drop => .Drop,
            .Sum => .Sum,
            .LastValue => .LastValue,
            .ExplicitBucketHistogram => .ExplicitBucketHistogram,
            .ExponentialBucketHistogram => .ExponentialBucketHistogram,
        };
    }
};

/// Simple enum for aggregation type matching
pub const AggregationType = enum {
    Drop,
    Sum,
    LastValue,
    ExplicitBucketHistogram,
    ExponentialBucketHistogram,
};

/// Default aggregation for a given kind of instrument.
pub fn DefaultAggregation(kind: instrument.Kind) Aggregation {
    return switch (kind) {
        .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => .Sum,
        .Gauge, .ObservableGauge => .LastValue,
        .Histogram => .{ .ExplicitBucketHistogram = .{} },
    };
}

/// Temporality describes how the value should be used.
/// See https://opentelemetry.io/docs/specs/otel/metrics/data-model/#temporality
pub const Temporality = enum {
    Cumulative,
    Delta,
    Unspecified,

    pub fn toProto(self: Temporality) pbmetrics.AggregationTemporality {
        return switch (self) {
            .Cumulative => .AGGREGATION_TEMPORALITY_CUMULATIVE,
            .Delta => .AGGREGATION_TEMPORALITY_DELTA,
            .Unspecified => .AGGREGATION_TEMPORALITY_UNSPECIFIED,
        };
    }
};

pub fn DefaultTemporality(kind: instrument.Kind) Temporality {
    return switch (kind) {
        .Counter, .UpDownCounter, .ObservableCounter, .ObservableUpDownCounter => .Cumulative,
        .Gauge, .ObservableGauge => .Delta,
        .Histogram => .Cumulative,
    };
}

pub const TemporalitySelector = *const fn (instrument.Kind) Temporality;

pub const AggregationSelector = *const fn (instrument.Kind) Aggregation;

pub fn TemporalityCumulative(_: instrument.Kind) Temporality {
    return .Cumulative;
}

pub fn TemporalityDelta(_: instrument.Kind) Temporality {
    return .Delta;
}

/// Helper struct to accumulate view configurations additively
pub const CombinedViewConfig = struct {
    aggregation: ?Aggregation = null,
    temporality: ?Temporality = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    attribute_filter: ?AttributeFilter = null,
    default_kind: instrument.Kind,

    const Self = @This();

    pub fn init(kind: instrument.Kind) Self {
        return Self{
            .default_kind = kind,
        };
    }

    pub fn applyView(self: *Self, v: *const View) void {
        // Apply aggregation with conflict detection
        if (self.aggregation) |existing_agg| {
            if (!aggregationEqual(existing_agg, v.aggregation)) {
                log.warn("View aggregation conflict detected: existing={}, new={}", .{ existing_agg, v.aggregation });
            }
        }
        self.aggregation = v.aggregation;

        // Apply temporality with conflict detection
        if (self.temporality) |existing_temp| {
            if (existing_temp != v.temporality) {
                log.warn("View temporality conflict detected: existing={}, new={}", .{ existing_temp, v.temporality });
            }
        }
        self.temporality = v.temporality;

        // Apply name override (last one wins)
        if (v.name) |new_name| {
            if (self.name) |existing_name| {
                if (!std.mem.eql(u8, existing_name, new_name)) {
                    log.warn("View name conflict detected: existing={s}, new={s}", .{ existing_name, new_name });
                }
            }
            self.name = new_name;
        }

        // Apply description override (longer one wins)
        if (v.description) |new_desc| {
            if (self.description) |existing_desc| {
                if (new_desc.len > existing_desc.len) self.description = new_desc;
            } else self.description = new_desc;
        }

        // Apply attribute filter (last one wins, could be enhanced to merge filters)
        if (v.attribute_filter) |new_filter| {
            if (self.attribute_filter != null) {
                log.warn("View attribute filter conflict detected: overriding existing filter", .{});
            }
            self.attribute_filter = new_filter;
        }
    }

    pub fn combinedAggregation(self: Self) Aggregation {
        return self.aggregation orelse DefaultAggregation(self.default_kind);
    }

    pub fn combinedTemporality(self: Self) Temporality {
        return self.temporality orelse DefaultTemporality(self.default_kind);
    }

    fn aggregationEqual(a: Aggregation, b: Aggregation) bool {
        return switch (a) {
            .Drop => b == .Drop,
            .Sum => b == .Sum,
            .LastValue => b == .LastValue,
            .ExplicitBucketHistogram => |aconfig| switch (b) {
                .ExplicitBucketHistogram => |bconfig| std.mem.eql(f64, aconfig.buckets, bconfig.buckets) and aconfig.record_min_max == bconfig.record_min_max,
                else => false,
            },
            .ExponentialBucketHistogram => |aconfig| switch (b) {
                .ExponentialBucketHistogram => |bconfig| aconfig.max_scale == bconfig.max_scale and aconfig.max_size == bconfig.max_size and aconfig.record_min_max == bconfig.record_min_max,
                else => false,
            },
        };
    }
};

/// Get the aggregation to use for the given instrument and meter scope from a views slice.
/// Uses the view system to determine the appropriate aggregation, applying all matching views additively.
pub fn aggregationForViews(views: []const View, instr: *const Instrument, scope: *const InstrumentationScope) Aggregation {
    var combined_config = CombinedViewConfig.init(instr.kind);

    for (views) |*v| {
        if (v.matches(instr, scope)) {
            combined_config.applyView(v);
        }
    }

    return combined_config.combinedAggregation();
}

/// Get the temporality to use for the given instrument and meter scope from a views slice.
/// Uses the view system to determine the appropriate temporality, applying all matching views additively.
pub fn temporalityForViews(views: []const View, instr: *const Instrument, scope: *const InstrumentationScope) Temporality {
    var combined_config = CombinedViewConfig.init(instr.kind);

    for (views) |*v| {
        if (v.matches(instr, scope)) {
            combined_config.applyView(v);
        }
    }

    return combined_config.combinedTemporality();
}

const MeterProvider = @import("../../api/metrics/meter.zig").MeterProvider;
