//! Prometheus Exporter for OpenTelemetry metrics.
//!
//! This exporter converts OpenTelemetry metrics to Prometheus text format
//! following the Prometheus exposition format specification.
//! See: https://prometheus.io/docs/instrumenting/exposition_formats/
//! See: https://opentelemetry.io/docs/specs/otel/metrics/sdk_exporters/prometheus/

const std = @import("std");
const Allocator = std.mem.Allocator;

const Measurements = @import("../../../api/metrics/measurement.zig").Measurements;
const MeasurementsData = @import("../../../api/metrics/measurement.zig").MeasurementsData;
const DataPoint = @import("../../../api/metrics/measurement.zig").DataPoint;
const HistogramDataPoint = @import("../../../api/metrics/measurement.zig").HistogramDataPoint;
const Attribute = @import("../../../attributes.zig").Attribute;
const AttributeValue = @import("../../../attributes.zig").AttributeValue;
const Kind = @import("../../../api/metrics/instrument.zig").Kind;

/// Naming convention for metric names in Prometheus format.
pub const NamingConvention = enum {
    /// Replace discouraged characters with underscores and add type suffixes.
    /// This is the default recommended by the OpenTelemetry specification.
    UnderscoreEscapingWithSuffixes,

    /// Replace discouraged characters with underscores but don't add suffixes.
    UnderscoreEscapingWithoutSuffixes,

    /// Don't escape UTF-8 characters but add type suffixes.
    NoUTF8EscapingWithSuffixes,

    /// Don't translate metric names at all.
    NoTranslation,
};

/// Configuration for the Prometheus formatter.
pub const FormatterConfig = struct {
    /// Naming convention to use for metric names.
    naming_convention: NamingConvention = .UnderscoreEscapingWithSuffixes,

    /// Include OpenTelemetry scope information as labels.
    include_scope_labels: bool = true,

    /// Include resource attributes as labels on each metric.
    include_resource_attributes: bool = false,
};

/// Formatter that converts OpenTelemetry measurements to Prometheus text format.
pub const PrometheusFormatter = struct {
    allocator: Allocator,
    config: FormatterConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: FormatterConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Format measurements into Prometheus text format.
    /// The writer must be a *std.Io.Writer.
    pub fn format(self: Self, writer: *std.Io.Writer, measurements: []const Measurements) !void {
        for (measurements) |measurement| {
            try self.formatMeasurement(writer, measurement);
        }
    }

    fn formatMeasurement(self: Self, writer: *std.Io.Writer, measurement: Measurements) !void {
        // Translate the metric name according to naming convention
        const base_name = try self.translateName(measurement.instrumentOptions.name, measurement.instrumentOptions.unit, measurement.instrumentKind);
        defer self.allocator.free(base_name);

        // Get the Prometheus metric type
        const prom_type = self.getPrometheusType(measurement.instrumentKind);

        // Write HELP line if description is provided
        if (measurement.instrumentOptions.description) |desc| {
            if (desc.len > 0) {
                try writer.print("# HELP {s} {s}\n", .{ base_name, desc });
            }
        }

        // Write TYPE line
        try writer.print("# TYPE {s} {s}\n", .{ base_name, prom_type });

        // Format the actual metric data based on type
        switch (measurement.data) {
            .int => |datapoints| try self.formatDataPoints(writer, base_name, measurement, datapoints),
            .double => |datapoints| try self.formatDataPoints(writer, base_name, measurement, datapoints),
            .histogram => |datapoints| try self.formatHistogram(writer, base_name, measurement, datapoints),
            .exponential_histogram => {
                // Exponential histograms are not yet supported
                // TODO: implement conversion to native histogram format
                return;
            },
        }
    }

    fn formatDataPoints(self: Self, writer: *std.Io.Writer, base_name: []const u8, measurement: Measurements, datapoints: anytype) !void {
        // Determine if we need to add suffix based on instrument kind
        const metric_name = try self.getMetricNameWithSuffix(base_name, measurement.instrumentKind);
        defer if (metric_name.ptr != base_name.ptr) self.allocator.free(metric_name);

        for (datapoints) |dp| {
            try writer.print("{s}", .{metric_name});

            // Write labels
            try self.writeLabels(writer, measurement, dp.attributes);

            // Write value - use scientific notation for floats, decimal for integers
            const ValueType = @TypeOf(dp.value);
            if (ValueType == f32 or ValueType == f64) {
                try writer.print(" {e}", .{dp.value});
            } else {
                try writer.print(" {d}", .{dp.value});
            }

            // Write timestamp if available (in seconds, not milliseconds)
            if (dp.timestamps) |ts| {
                try writer.print(" {d}", .{ts.time_ns / 1_000_000_000}); // Convert to seconds
            }

            try writer.writeAll("\n");
        }
    }

    fn formatHistogram(self: Self, writer: *std.Io.Writer, base_name: []const u8, measurement: Measurements, datapoints: []const DataPoint(HistogramDataPoint)) !void {
        for (datapoints) |dp| {
            const hist = dp.value;

            // Write bucket counts
            for (hist.bucket_counts, 0..) |count, i| {
                try writer.print("{s}_bucket", .{base_name});

                // Build labels including 'le' for bucket boundary
                var labels = std.array_list.Managed(LabelPair).init(self.allocator);
                defer labels.deinit();

                // Add existing attributes
                if (dp.attributes) |attrs| {
                    for (attrs) |attr| {
                        try labels.append(.{
                            .name = attr.key,
                            .value = try self.attributeValueToString(attr.value),
                        });
                    }
                }

                // Add 'le' label for bucket upper bound
                const le_value = if (i < hist.explicit_bounds.len)
                    try std.fmt.allocPrint(self.allocator, "{d}", .{hist.explicit_bounds[i]})
                else
                    try self.allocator.dupe(u8, "+Inf");
                defer self.allocator.free(le_value);

                try labels.append(.{ .name = "le", .value = le_value });

                try self.writeLabelsFromList(writer, labels.items);
                try writer.print(" {d}\n", .{count});
            }

            // Write sum if available
            if (hist.sum) |sum| {
                try writer.print("{s}_sum", .{base_name});
                try self.writeLabels(writer, measurement, dp.attributes);
                try writer.print(" {d}\n", .{sum});
            }

            // Write count
            try writer.print("{s}_count", .{base_name});
            try self.writeLabels(writer, measurement, dp.attributes);
            try writer.print(" {d}\n", .{hist.count});
        }
    }

    fn writeLabels(self: Self, writer: *std.Io.Writer, measurement: Measurements, attributes: ?[]Attribute) !void {
        var labels = std.array_list.Managed(LabelPair).init(self.allocator);
        defer labels.deinit();

        // Track which values need to be freed (those from attributeValueToString)
        var allocated_values = std.array_list.Managed([]const u8).init(self.allocator);
        defer {
            for (allocated_values.items) |value| {
                self.allocator.free(value);
            }
            allocated_values.deinit();
        }

        // Add scope labels if configured
        if (self.config.include_scope_labels) {
            try labels.append(.{
                .name = "otel_scope_name",
                .value = measurement.scope.name,
            });

            if (measurement.scope.version) |version| {
                try labels.append(.{
                    .name = "otel_scope_version",
                    .value = version,
                });
            }
        }

        // Add metric attributes
        if (attributes) |attrs| {
            for (attrs) |attr| {
                const value = try self.attributeValueToString(attr.value);
                try allocated_values.append(value);
                try labels.append(.{
                    .name = attr.key,
                    .value = value,
                });
            }
        }

        try self.writeLabelsFromList(writer, labels.items);
    }

    const LabelPair = struct {
        name: []const u8,
        value: []const u8,
    };

    fn writeLabelsFromList(self: Self, writer: *std.Io.Writer, labels: []const LabelPair) !void {
        if (labels.len == 0) {
            return;
        }

        try writer.writeAll("{");

        for (labels, 0..) |label, i| {
            if (i > 0) try writer.writeAll(",");

            const escaped_value = try self.escapeLabelValue(label.value);
            defer self.allocator.free(escaped_value);

            try writer.print("{s}=\"{s}\"", .{ label.name, escaped_value });
        }

        try writer.writeAll("}");
    }

    /// Translate OTel metric name to Prometheus format.
    fn translateName(self: Self, name: []const u8, unit: ?[]const u8, kind: Kind) ![]const u8 {
        switch (self.config.naming_convention) {
            .NoTranslation => return try self.allocator.dupe(u8, name),
            .NoUTF8EscapingWithSuffixes, .UnderscoreEscapingWithSuffixes, .UnderscoreEscapingWithoutSuffixes => {
                var result = std.array_list.Managed(u8).init(self.allocator);
                errdefer result.deinit();

                // Translate discouraged characters to underscores if needed
                const escape_unicode = self.config.naming_convention != .NoUTF8EscapingWithSuffixes;

                for (name) |c| {
                    if (isValidPrometheusChar(c, escape_unicode)) {
                        try result.append(c);
                    } else {
                        try result.append('_');
                    }
                }

                // Add unit suffix if present
                if (unit) |u| {
                    if (u.len > 0 and !std.mem.eql(u8, u, "1")) {
                        const unit_suffix = try self.translateUnit(u);
                        defer self.allocator.free(unit_suffix);

                        if (unit_suffix.len > 0) {
                            try result.append('_');
                            try result.appendSlice(unit_suffix);
                        }
                    }
                }

                // Add type suffix if naming convention includes suffixes
                const add_suffixes = self.config.naming_convention != .UnderscoreEscapingWithoutSuffixes;
                if (add_suffixes) {
                    switch (kind) {
                        .Counter => {
                            // Add _total suffix for monotonic counters
                            try result.appendSlice("_total");
                        },
                        else => {},
                    }
                }

                // Collapse consecutive underscores
                const collapsed = try self.collapseUnderscores(result.items);
                result.deinit(); // Free the intermediate buffer
                return collapsed;
            },
        }
    }

    fn isValidPrometheusChar(c: u8, escape_unicode: bool) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or
            (!escape_unicode and c >= 128); // Allow UTF-8 if not escaping
    }

    fn translateUnit(self: Self, unit: []const u8) ![]const u8 {
        // Common unit translations per OTel spec
        if (std.mem.eql(u8, unit, "ms")) return try self.allocator.dupe(u8, "milliseconds");
        if (std.mem.eql(u8, unit, "s")) return try self.allocator.dupe(u8, "seconds");
        if (std.mem.eql(u8, unit, "m")) return try self.allocator.dupe(u8, "meters");
        if (std.mem.eql(u8, unit, "By")) return try self.allocator.dupe(u8, "bytes");
        if (std.mem.eql(u8, unit, "1")) return try self.allocator.dupe(u8, "ratio");

        // Convert "/" to "_per_"
        if (std.mem.indexOf(u8, unit, "/")) |_| {
            var result = std.array_list.Managed(u8).init(self.allocator);
            errdefer result.deinit();

            var parts = std.mem.splitScalar(u8, unit, '/');
            var first = true;
            while (parts.next()) |part| {
                if (!first) {
                    try result.appendSlice("_per_");
                }
                try result.appendSlice(part);
                first = false;
            }

            return try result.toOwnedSlice();
        }

        return try self.allocator.dupe(u8, unit);
    }

    fn collapseUnderscores(self: Self, name: []const u8) ![]const u8 {
        var result = std.array_list.Managed(u8).init(self.allocator);
        errdefer result.deinit();

        var prev_underscore = false;
        for (name) |c| {
            if (c == '_') {
                if (!prev_underscore) {
                    try result.append(c);
                    prev_underscore = true;
                }
            } else {
                try result.append(c);
                prev_underscore = false;
            }
        }

        return try result.toOwnedSlice();
    }

    fn getMetricNameWithSuffix(self: Self, base_name: []const u8, kind: Kind) ![]const u8 {
        const add_suffixes = switch (self.config.naming_convention) {
            .UnderscoreEscapingWithSuffixes, .NoUTF8EscapingWithSuffixes => true,
            .UnderscoreEscapingWithoutSuffixes, .NoTranslation => false,
        };

        if (!add_suffixes) {
            return try self.allocator.dupe(u8, base_name);
        }

        // Add _total suffix for monotonic counters
        if (kind == .Counter) {
            if (!std.mem.endsWith(u8, base_name, "_total")) {
                return try std.fmt.allocPrint(self.allocator, "{s}_total", .{base_name});
            }
        }

        return try self.allocator.dupe(u8, base_name);
    }

    fn getPrometheusType(self: Self, kind: Kind) []const u8 {
        _ = self;
        return switch (kind) {
            .Counter => "counter",
            .UpDownCounter => "gauge",
            .Gauge => "gauge",
            .Histogram => "histogram",
            .ObservableCounter => "counter",
            .ObservableUpDownCounter => "gauge",
            .ObservableGauge => "gauge",
        };
    }

    fn escapeLabelValue(self: Self, value: []const u8) ![]const u8 {
        var result = std.array_list.Managed(u8).init(self.allocator);
        errdefer result.deinit();

        for (value) |c| {
            switch (c) {
                '\\' => try result.appendSlice("\\\\"),
                '"' => try result.appendSlice("\\\""),
                '\n' => try result.appendSlice("\\n"),
                else => try result.append(c),
            }
        }

        return try result.toOwnedSlice();
    }

    fn attributeValueToString(self: Self, value: AttributeValue) ![]const u8 {
        return switch (value) {
            .string => |s| try self.allocator.dupe(u8, s),
            .bool => |b| if (b) try self.allocator.dupe(u8, "true") else try self.allocator.dupe(u8, "false"),
            .int => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
            .double => |d| try std.fmt.allocPrint(self.allocator, "{d}", .{d}),
            .baggage => try self.allocator.dupe(u8, "<baggage>"),
        };
    }
};

// ============================================================================
// Prometheus Exporter with HTTP Server
// ============================================================================

const MetricReader = @import("../reader.zig").MetricReader;
const MetricExporter = @import("../exporter.zig").MetricExporter;
const ExporterImpl = @import("../exporter.zig").ExporterImpl;
const MetricReadError = @import("../reader.zig").MetricReadError;
const InMemoryExporter = @import("in_memory.zig").InMemoryExporter;
const MeterProvider = @import("../../../api/metrics/meter.zig").MeterProvider;
const view = @import("../view.zig");

/// Configuration options for the Prometheus exporter HTTP server.
pub const ExporterConfig = struct {
    /// Host address to bind to. Default: "127.0.0.1"
    host: []const u8 = "127.0.0.1",
    /// Port to listen on. Default: 9464 (official Prometheus exporter port)
    port: u16 = 9464,
    /// Formatter configuration
    formatter_config: FormatterConfig = .{},
};

/// Prometheus exporter that exposes metrics via HTTP server.
/// Implements the pull-based model where Prometheus scrapes the /metrics endpoint.
/// This exporter implements the ExporterImpl interface and MUST be used with
/// Cumulative temporality as per OpenTelemetry specification.
pub const PrometheusExporter = struct {
    const Self = @This();

    allocator: Allocator,
    config: ExporterConfig,
    formatter: PrometheusFormatter,
    server_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    // Cached measurements from the last exportBatch call
    last_measurements: []Measurements = &[_]Measurements{},
    // Implement the ExporterImpl interface
    exporter: ExporterImpl,

    pub fn init(allocator: Allocator, config: ExporterConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .formatter = PrometheusFormatter.init(allocator, config.formatter_config),
            .should_stop = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .exporter = ExporterImpl{
                .exportFn = exportBatch,
            },
        };

        return self;
    }

    /// ExporterImpl interface implementation.
    /// This is called by the MetricReader during collection.
    /// The exporter takes ownership of the measurements and caches them for HTTP serving.
    fn exportBatch(iface: *ExporterImpl, measurements: []Measurements) MetricReadError!void {
        const self: *Self = @fieldParentPtr("exporter", iface);
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up old cached measurements
        for (self.last_measurements) |*m| {
            m.deinit(self.allocator);
        }
        if (self.last_measurements.len > 0) {
            self.allocator.free(self.last_measurements);
        }

        // Cache the new measurements for HTTP serving
        // Note: We take ownership of the measurements array
        self.last_measurements = measurements;
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        // Clean up cached measurements
        for (self.last_measurements) |*m| {
            m.deinit(self.allocator);
        }
        if (self.last_measurements.len > 0) {
            self.allocator.free(self.last_measurements);
        }
        self.allocator.destroy(self);
    }

    /// Start the HTTP server in a background thread.
    pub fn start(self: *Self) !void {
        if (self.server_thread != null) return error.AlreadyStarted;

        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    /// Stop the HTTP server and wait for the thread to finish.
    pub fn stop(self: *Self) void {
        if (self.server_thread) |thread| {
            self.should_stop.store(true, .release);

            // Make a dummy connection to wake up the accept() call
            const address = std.net.Address.parseIp(self.config.host, self.config.port) catch {
                thread.join();
                self.server_thread = null;
                self.should_stop.store(false, .release);
                return;
            };
            const wake_stream = std.net.tcpConnectToAddress(address) catch {
                // Connection failed, but thread might have already exited
                thread.join();
                self.server_thread = null;
                self.should_stop.store(false, .release);
                return;
            };
            wake_stream.close();

            thread.join();
            self.server_thread = null;
            // Reset flag so server can be restarted
            self.should_stop.store(false, .release);
        }
    }

    fn serverLoop(self: *Self) void {
        self.serverLoopImpl() catch |err| {
            std.log.err("Prometheus exporter server error: {}", .{err});
        };
    }

    fn serverLoopImpl(self: *Self) !void {
        const address = try std.net.Address.parseIp(self.config.host, self.config.port);
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        defer listener.deinit();

        std.log.info("Prometheus exporter listening on {s}:{d}", .{ self.config.host, self.config.port });

        while (!self.should_stop.load(.acquire)) {
            // Accept connection (will block until we get one or server stops)
            const connection = listener.accept() catch |err| {
                // If we get an error and should_stop is true, exit gracefully
                if (self.should_stop.load(.acquire)) {
                    return;
                }
                return err;
            };

            // Check if we should stop before handling the connection
            if (self.should_stop.load(.acquire)) {
                connection.stream.close();
                return;
            }

            // Handle the connection
            self.handleConnection(connection.stream) catch |err| {
                std.log.err("Error handling connection: {}", .{err});
            };
            connection.stream.close();
        }
    }

    fn handleConnection(self: *Self, stream: std.net.Stream) !void {
        var buf: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buf);
        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Simple HTTP request parsing - just check if it's GET /metrics
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
            try self.handleMetricsRequest(stream);
        } else if (std.mem.startsWith(u8, request, "GET /")) {
            try self.handleNotFound(stream);
        } else {
            try self.handleBadRequest(stream);
        }
    }

    fn handleMetricsRequest(self: *Self, stream: std.net.Stream) !void {
        // Serve cached metrics from the last exportBatch call (thread-safe)
        self.mutex.lock();
        defer self.mutex.unlock();

        // Format metrics to Prometheus text format
        var output = std.ArrayListUnmanaged(u8).empty;
        var writer_alloc = std.Io.Writer.Allocating.fromArrayList(self.allocator, &output);
        defer writer_alloc.deinit();

        try self.formatter.format(&writer_alloc.writer, self.last_measurements);
        try writer_alloc.writer.flush();

        // Send HTTP response
        const headers =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" ++
            "Connection: close\r\n" ++
            "\r\n";

        try stream.writeAll(headers);
        try stream.writeAll(writer_alloc.writer.buffer[0..writer_alloc.writer.end]);
    }

    fn handleNotFound(self: *Self, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "404 Not Found\n" ++
            "Only /metrics endpoint is available\n";
        try stream.writeAll(response);
    }

    fn handleBadRequest(self: *Self, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 400 Bad Request\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "400 Bad Request\n";
        try stream.writeAll(response);
    }
};

test "PrometheusFormatter: format counter with suffix" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{
        .naming_convention = .UnderscoreEscapingWithSuffixes,
    });

    const DataPointType = DataPoint(i64);
    var datapoints = try allocator.alloc(DataPointType, 1);
    defer allocator.free(datapoints);

    datapoints[0] = .{ .value = 42, .timestamps = .{ .time_ns = 1000000000 } };

    var measurements = [_]Measurements{.{
        .scope = .{ .name = "test_scope" },
        .instrumentKind = .Counter,
        .instrumentOptions = .{
            .name = "http_requests",
            .description = "Total HTTP requests",
        },
        .data = .{ .int = datapoints },
    }};

    var output = std.ArrayListUnmanaged(u8).empty;
    var writer_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &output);
    defer writer_alloc.deinit();

    try formatter.format(&writer_alloc.writer, &measurements);
    try writer_alloc.writer.flush();

    const expected =
        \\# HELP http_requests_total Total HTTP requests
        \\# TYPE http_requests_total counter
        \\http_requests_total{otel_scope_name="test_scope"} 42 1
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer_alloc.writer.buffer[0..writer_alloc.writer.end]);
}

test "PrometheusFormatter: format gauge without suffix" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{
        .naming_convention = .UnderscoreEscapingWithSuffixes,
        .include_scope_labels = false,
    });

    const DataPointType = DataPoint(f64);
    var datapoints = try allocator.alloc(DataPointType, 1);
    defer allocator.free(datapoints);

    datapoints[0] = .{ .value = 3.14 };

    var measurements = [_]Measurements{.{
        .scope = .{ .name = "test_scope" },
        .instrumentKind = .Gauge,
        .instrumentOptions = .{
            .name = "temperature",
            .unit = "celsius",
        },
        .data = .{ .double = datapoints },
    }};

    var output = std.ArrayListUnmanaged(u8).empty;
    var writer_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &output);
    defer writer_alloc.deinit();

    try formatter.format(&writer_alloc.writer, &measurements);
    try writer_alloc.writer.flush();

    const expected =
        \\# TYPE temperature_celsius gauge
        \\temperature_celsius 3.14e0
        \\
    ;

    try std.testing.expectEqualStrings(expected, writer_alloc.writer.buffer[0..writer_alloc.writer.end]);
}

test "PrometheusFormatter: format with labels and escaping" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{
        .include_scope_labels = false,
    });

    const DataPointType = DataPoint(i64);
    var datapoints = try allocator.alloc(DataPointType, 1);
    defer allocator.free(datapoints);

    var attributes = try allocator.alloc(Attribute, 2);
    defer allocator.free(attributes);

    const method_value = try allocator.dupe(u8, "GET");
    defer allocator.free(method_value);
    const path_value = try allocator.dupe(u8, "/api/\"test\"\n");
    defer allocator.free(path_value);

    attributes[0] = .{ .key = "method", .value = .{ .string = method_value } };
    attributes[1] = .{ .key = "path", .value = .{ .string = path_value } };

    datapoints[0] = .{ .value = 100, .attributes = attributes };

    var measurements = [_]Measurements{.{
        .scope = .{ .name = "test" },
        .instrumentKind = .Counter,
        .instrumentOptions = .{ .name = "requests" },
        .data = .{ .int = datapoints },
    }};

    var output = std.ArrayListUnmanaged(u8).empty;
    var writer_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &output);
    defer writer_alloc.deinit();

    try formatter.format(&writer_alloc.writer, &measurements);
    try writer_alloc.writer.flush();

    // Verify label escaping
    try std.testing.expect(std.mem.indexOf(u8, writer_alloc.writer.buffer[0..writer_alloc.writer.end], "path=\"/api/\\\"test\\\"\\n\"") != null);
}

test "PrometheusFormatter: metric name with unit conversion" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{});

    // Test milliseconds conversion
    const name1 = try formatter.translateName("duration", "ms", .Gauge);
    defer allocator.free(name1);
    try std.testing.expectEqualStrings("duration_milliseconds", name1);

    // Test ratio (unit "1")
    const name2 = try formatter.translateName("ratio", "1", .Gauge);
    defer allocator.free(name2);
    try std.testing.expectEqualStrings("ratio", name2);

    // Test per-unit conversion
    const name3 = try formatter.translateName("speed", "m/s", .Gauge);
    defer allocator.free(name3);
    try std.testing.expectEqualStrings("speed_m_per_s", name3);
}

test "PrometheusFormatter: underscore collapsing" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{});

    const name = try formatter.collapseUnderscores("test___multiple____underscores");
    defer allocator.free(name);

    try std.testing.expectEqualStrings("test_multiple_underscores", name);
}

test "PrometheusFormatter: histogram formatting" {
    const allocator = std.testing.allocator;

    var formatter = PrometheusFormatter.init(allocator, .{
        .include_scope_labels = false,
    });

    var bounds = try allocator.alloc(f64, 3);
    defer allocator.free(bounds);
    bounds[0] = 0.1;
    bounds[1] = 0.5;
    bounds[2] = 1.0;

    var bucket_counts = try allocator.alloc(u64, 4);
    defer allocator.free(bucket_counts);
    bucket_counts[0] = 10;
    bucket_counts[1] = 25;
    bucket_counts[2] = 40;
    bucket_counts[3] = 50;

    var datapoints = try allocator.alloc(DataPoint(HistogramDataPoint), 1);
    defer allocator.free(datapoints);

    datapoints[0] = .{
        .value = .{
            .explicit_bounds = bounds,
            .bucket_counts = bucket_counts,
            .sum = 15.5,
            .count = 50,
        },
    };

    var measurements = [_]Measurements{.{
        .scope = .{ .name = "test" },
        .instrumentKind = .Histogram,
        .instrumentOptions = .{ .name = "request_duration" },
        .data = .{ .histogram = datapoints },
    }};

    var output = std.ArrayListUnmanaged(u8).empty;
    var writer_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &output);
    defer writer_alloc.deinit();

    try formatter.format(&writer_alloc.writer, &measurements);
    try writer_alloc.writer.flush();

    const formatted_output = writer_alloc.writer.buffer[0..writer_alloc.writer.end];

    // Verify histogram output contains buckets, sum, and count
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_bucket{le=\"0.1\"} 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_bucket{le=\"0.5\"} 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_bucket{le=\"1\"} 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_bucket{le=\"+Inf\"} 50") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_sum 15.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_output, "request_duration_count 50") != null);
}

// HTTP Server Lifecycle Tests

test "PrometheusExporter: server start and stop" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19465, // Use unique port for test
    });
    defer exporter.deinit();

    // Server should not be running initially
    try std.testing.expectEqual(@as(?std.Thread, null), exporter.server_thread);

    // Start the server
    try exporter.start();
    try std.testing.expect(exporter.server_thread != null);

    // Wait a bit for server to be ready
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Stop the server (should not block)
    exporter.stop();
    try std.testing.expectEqual(@as(?std.Thread, null), exporter.server_thread);
}

test "PrometheusExporter: double start returns error" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19466, // Use unique port for test
    });
    defer exporter.deinit();

    // Start the server
    try exporter.start();
    defer exporter.stop();

    // Trying to start again should return error
    try std.testing.expectError(error.AlreadyStarted, exporter.start());
}

test "PrometheusExporter: repeated start/stop cycles" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19467, // Use unique port for test
    });
    defer exporter.deinit();

    // Perform multiple start/stop cycles
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try exporter.start();
        std.Thread.sleep(50 * std.time.ns_per_ms);
        exporter.stop();
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Verify server is stopped
    try std.testing.expectEqual(@as(?std.Thread, null), exporter.server_thread);
}

test "PrometheusExporter: concurrent HTTP requests" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19468, // Use unique port for test
    });
    defer exporter.deinit();

    try exporter.start();
    defer exporter.stop();

    // Wait for server to be ready
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Make multiple concurrent requests
    const RequestThread = struct {
        fn makeRequest(port: u16) void {
            const address = std.net.Address.parseIp("127.0.0.1", port) catch return;
            const stream = std.net.tcpConnectToAddress(address) catch return;
            defer stream.close();

            const request = "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            stream.writeAll(request) catch return;

            var buf: [4096]u8 = undefined;
            _ = stream.read(&buf) catch return;
        }
    };

    var threads: [3]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, RequestThread.makeRequest, .{19468});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Server should still be running after concurrent requests
    try std.testing.expect(exporter.server_thread != null);
}

test "PrometheusExporter: shutdown does not block" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19469, // Use unique port for test
    });
    defer exporter.deinit();

    try exporter.start();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Measure shutdown time (should be fast, not blocked)
    const start_time = std.time.milliTimestamp();
    exporter.stop();
    const end_time = std.time.milliTimestamp();

    const shutdown_time = end_time - start_time;
    // Shutdown should complete within 1 second (generous timeout)
    try std.testing.expect(shutdown_time < 1000);
}

test "PrometheusExporter: server handles invalid path with 404" {
    const allocator = std.testing.allocator;

    const exporter = try PrometheusExporter.init(allocator, .{
        .host = "127.0.0.1",
        .port = 19470, // Use unique port for test
    });
    defer exporter.deinit();

    try exporter.start();
    defer exporter.stop();

    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Make request to invalid path
    const address = try std.net.Address.parseIp("127.0.0.1", 19470);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    const request = "GET /invalid HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    try stream.writeAll(request);

    var buf: [1024]u8 = undefined;
    const n = try stream.read(&buf);
    const response = buf[0..n];

    // Should return 404
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404"));
}
