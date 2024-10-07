const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const Instrument = @import("instrument.zig");

/// Defines the ways and means to compute aggregated metrics.
/// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#aggregation
pub const Aggregation = enum {
    Drop,
    Default,
    Sum,
    LastValue,
    ExplicitBucketHistogram,
};

/// Default aggregation for a given kind of instrument.
pub fn DefaultAggregationFor(kind: Instrument.Kind) Aggregation {
    return switch (kind) {
        .Counter => Aggregation.Sum,
        .UpDownCounter => Aggregation.Sum,
        .Gauge => Aggregation.LastValue,
        .Histogram => Aggregation.ExplicitBucketHistogram,
    };
}

// Temporality
pub const Temporality = enum {
    Cumulative,
    Delta,

    pub fn toProto(self: Temporality) pbmetrics.AggregationTemporality {
        return switch (self) {
            .Cumulative => .AGGREGATION_TEMPORALITY_CUMULATIVE,
            .Delta => .AGGREGATION_TEMPORALITY_DELTA,
        };
    }
};

pub fn DefaultTemporalityFor(kind: Instrument.Kind) Temporality {
    return switch (kind) {
        .Counter => Temporality.Cumulative,
        .UpDownCounter => Temporality.Cumulative,
        .Gauge => Temporality.Delta,
        .Histogram => Temporality.Cumulative,
    };
}
