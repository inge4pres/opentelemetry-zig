const pbmetrics = @import("../../opentelemetry/proto/metrics/v1.pb.zig");
const instrument = @import("../../api/metrics/instrument.zig");

/// Defines the ways and means to compute aggregated metrics.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#aggregation
pub const Aggregation = enum {
    Drop,
    Sum,
    LastValue,
    ExplicitBucketHistogram,
};

/// Default aggregation for a given kind of instrument.
pub fn DefaultAggregationFor(kind: instrument.Kind) Aggregation {
    return switch (kind) {
        .Counter => Aggregation.Sum,
        .UpDownCounter => Aggregation.Sum,
        .Gauge => Aggregation.LastValue,
        .Histogram => Aggregation.ExplicitBucketHistogram,
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

pub fn DefaultTemporalityFor(kind: instrument.Kind) Temporality {
    return switch (kind) {
        .Counter => Temporality.Cumulative,
        .UpDownCounter => Temporality.Cumulative,
        .Gauge => Temporality.Delta,
        .Histogram => Temporality.Cumulative,
    };
}

pub const TemporalitySelector = *const fn (instrument.Kind) Temporality;

pub const AggregationSelector = *const fn (instrument.Kind) Aggregation;
