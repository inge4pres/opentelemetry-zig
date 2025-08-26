const pbmetrics = @import("opentelemetry-proto").metrics_v1;
const instrument = @import("../../api/metrics/instrument.zig");

/// Defines the ways and means to compute aggregated metrics.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#aggregation
pub const Aggregation = enum {
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
        .Histogram => .ExplicitBucketHistogram,
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
