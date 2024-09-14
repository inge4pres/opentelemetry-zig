const std = @import("std");
const protobuf = @import("protobuf");
const pbmetrics = @import("../opentelemetry/proto/metrics/v1.pb.zig");
const instrument = @import("instrument.zig");
const MeterProvider = @import("meter.zig").MeterProvider;
const view = @import("view.zig");

// MetricReader reads metrics' data from a MeterProvider.
// See https://opentelemetry.io/docs/specs/otel/metrics/sdk/#metricreader
pub const MetricReader = struct {
    // We can read the instruments' data points from the meters
    // stored in meterProvider.
    meterProvider: ?*MeterProvider = null,

    temporality: *const fn (instrument.Kind) view.Temporality = view.TemporalityFor,
    aggregation: *const fn (instrument.Kind) view.Aggregation = view.DefaultAggregationFor,
    // Signal that shutdown has been called.
    hasShutDown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // TODO add exporter
    // exporter: MetricExporter,

    const Self = @This();

    pub fn collect(self: Self) !void {
        if (self.hasShutDown.load(.acquire)) {
            // Shutdown has already been called so this is a no-op.
            return;
        }
        if (self.meterProvider) |_| {
            // Collect the data from the meter provider.

        } else {
            // No meter provider to collect from.
            return;
        }
        return; // TODO: Express a better error type.
    }

    pub fn shutdown(self: *Self) void {
        self.hasShutDown.store(true, .release);
    }
};

test "metric reader shutdown prevents Collect to execute" {
    var reader = MetricReader{};
    reader.shutdown();
    try reader.collect();
}
