const pbmetrics = @import("opentelemetry-proto").metrics_v1;
const instrument = @import("../../api/metrics/instrument.zig");
const spec = @import("../../api/metrics/spec.zig");

/// Configuration for explicit bucket histogram aggregation
pub const ExplicitBucketHistogramConfig = struct {
    /// Bucket boundaries for the histogram. If null, uses SDK default buckets.
    buckets: ?[]const f64 = spec.default_histogram_explicit_bucket_boundaries,
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
