const std = @import("std");
const helpers = @import("../helpers.zig");

const BuildError = helpers.BuildError;
const BuildModules = helpers.BuildModules;
const CompilationInfo = helpers.CompilationInfo;

// Path of the OpenTelemetry SDK source root directory relative to the build.zig file.
const sdk_root = "opentelemetry-sdk";

const GrpcProvider = enum { none, libgrpc };

// Sets up the dependencies, modules and static library for the OpenTelemetry
// SDK, and installs its artifacts and headers.
pub fn Setup(
    b: *std.Build,
    info: CompilationInfo,
    dependencies: *BuildModules,
) !void {
    const grpc = try modules(b, info, dependencies);

    const sdk_lib = b.addLibrary(.{
        .name = "opentelemetry-sdk",
        .linkage = .static,
        .root_module = dependencies.get("sdk_c_lib") orelse return BuildError.ModuleNotFound,
    });

    b.installArtifact(sdk_lib);

    // Install include headers for C users
    b.installDirectory(.{
        .source_dir = b.path(sdk_root ++ "/include"),
        .install_dir = .header,
        .install_subdir = "",
    });

    _ = try addTestStep(b, dependencies, info);
    try addExamplesStep(b, dependencies, sdk_lib, info, grpc);
    _ = try addBenchmarksStep(b, dependencies, info);
    try addIntegrationStep(b, dependencies, info, grpc);

    const docs_step = try addDocsStep(b, dependencies, info);
    docs_step.dependOn(&sdk_lib.step);
}

// Returns the selected gRPC backend.
fn modules(b: *std.Build, info: CompilationInfo, dependencies: *BuildModules) !GrpcProvider {
    const clock_mod = b.createModule(.{
        .root_source_file = b.path(sdk_root ++ "/src/clock.zig"),
        .target = info.target,
        .optimize = info.optimize,
        .link_libc = true,
    });
    try dependencies.put("clock", clock_mod);

    const grpc_provider = b.option(GrpcProvider, "grpc-provider", "Which gRPC implementation to use, if any") orelse .none;
    const grpc_link_mode = b.option(std.builtin.LinkMode, "grpc-link-mode", "Link libgrpc statically or dynamically, with -Dgrpc-provider=libgrpc");

    // The selected gRPC backend is exposed to the SDK as the `grpc_transport`
    // module. Every backend's entry file lives under `opentelemetry-sdk/src/grpc/`
    // and exports the same `send` and `Configuration` surface.
    const grpc_transport_mod = switch (grpc_provider) {
        .none => b.createModule(.{
            .root_source_file = b.path(sdk_root ++ "/src/grpc/noop.zig"),
            .target = info.target,
            .optimize = info.optimize,
        }),
        .libgrpc => blk: {
            // A lazy dependency: if it is not fetched yet, this stops the
            // configuration right away, and Zig fetches it and starts over.
            // Returning early instead would leave the options and modules
            // declared after this point missing from that first pass.
            const cgrpc_dep = b.dependency("cgrpc_wrapper", .{
                .target = info.target,
                .optimize = info.optimize,
                .link_mode = grpc_link_mode,
            });

            // Dependents look libgrpc up through this package to install it
            // when dynamic, and `Dependency.artifact()` only finds installed
            // artifacts: install it whatever the linking mode. With
            // `-fsys=grpc` there is no artifact to install.
            if (!b.systemIntegrationOption("grpc", .{}))
                b.installArtifact(cgrpc_dep.artifact("grpc"));

            break :blk b.createModule(.{
                .root_source_file = b.path(sdk_root ++ "/src/grpc/libgrpc.zig"),
                .target = info.target,
                .optimize = info.optimize,
                .imports = &.{
                    .{ .name = "cgrpc_wrapper", .module = cgrpc_dep.module("cgrpc_wrapper") },
                },
            });
        },
    };
    try dependencies.put("grpc_transport", grpc_transport_mod);

    var sdk_dep_names = [_][]const u8{
        "protobuf",
        "opentelemetry-proto",
        "clock",
        "grpc_transport",
    };
    const sdk_mod = b.addModule("sdk", .{
        .root_source_file = b.path(sdk_root ++ "/src/sdk.zig"),
        .target = info.target,
        .optimize = info.optimize,
        .strip = false,
        .unwind_tables = .sync,
        .link_libc = true,
        .imports = try helpers.ImportsFromBuildModules(b.allocator, dependencies, &sdk_dep_names),
    });
    { // Build info
        const build_info = b.addOptions();
        build_info.addOption([]const u8, "version", info.version);
        build_info.addOption([]const u8, "name", info.pkg_name);
        sdk_mod.addOptions("build_info", build_info);
    }
    try dependencies.put("opentelemetry-sdk", sdk_mod);

    // Static library for the OpenTelemetry SDK C users
    const sdk_c_lib_mod = b.createModule(.{
        .root_source_file = b.path(sdk_root ++ "/src/c.zig"),
        .target = info.target,
        .optimize = info.optimize,
        .link_libc = true,
        .imports = try helpers.ImportsFromBuildModules(b.allocator, dependencies, &sdk_dep_names),
    });
    try dependencies.put("sdk_c_lib", sdk_c_lib_mod);

    // Attach an OTLP stub module to allow examples to use it.
    var otlp_stub_dep_names = [_][]const u8{
        "opentelemetry-sdk",
        "protobuf",
        "opentelemetry-proto",
    };
    const otel_stub_mod = b.createModule(.{
        .root_source_file = b.path(sdk_root ++ "/examples/otlp_stub/server.zig"),
        .target = info.target,
        // Examples are always run in Debug mode to catch potential API issues.
        .optimize = .debug,
        .imports = try helpers.ImportsFromBuildModules(b.allocator, dependencies, &otlp_stub_dep_names),
    });
    try dependencies.put("otlp-stub", otel_stub_mod);

    return grpc_provider;
}

// Registers the "sdk-test" step, building and running the SDK unit tests.
fn addTestStep(b: *std.Build, mods: *const BuildModules, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-test", "Run SDK unit tests");

    const test_verbose = b.option(bool, "test-verbose", "Show verbose test output") orelse false;
    const test_fail_first = b.option(bool, "test-fail-first", "Stop on first test failure") orelse false;
    const test_show_logs = b.option(bool, "test-show-logs", "Show captured log output for tests") orelse false;

    const sdk_unit_tests = b.addTest(.{
        .root_module = mods.get("opentelemetry-sdk") orelse return BuildError.ModuleNotFound,
        // Use custom test runner to capture log output
        .test_runner = .{ .path = b.path(sdk_root ++ "/src/test_runner.zig"), .mode = .simple },
        .filters = info.test_filters,
    });

    // Pass test options as build options
    const test_options = b.addOptions();
    test_options.addOption(bool, "verbose", test_verbose);
    test_options.addOption(bool, "fail_first", test_fail_first);
    test_options.addOption(bool, "show_logs", test_show_logs);
    sdk_unit_tests.root_module.addOptions("test_options", test_options);

    const run_sdk_unit_tests = b.addRunArtifact(sdk_unit_tests);
    step.dependOn(&run_sdk_unit_tests.step);

    // The selected gRPC transport is a separate module, so its tests are not
    // reached by sdk_unit_tests. Run them as their own test step that the
    // top-level "sdk-test" step depends on.
    const grpc_transport_unit_tests = b.addTest(.{
        .root_module = mods.get("grpc_transport") orelse return BuildError.ModuleNotFound,
        .test_runner = .{ .path = b.path(sdk_root ++ "/src/test_runner.zig"), .mode = .simple },
        .filters = info.test_filters,
    });
    {
        const grpc_test_options = b.addOptions();
        grpc_test_options.addOption(bool, "verbose", test_verbose);
        grpc_test_options.addOption(bool, "fail_first", test_fail_first);
        grpc_test_options.addOption(bool, "show_logs", test_show_logs);
        grpc_transport_unit_tests.root_module.addOptions("test_options", grpc_test_options);
    }
    const run_grpc_transport_unit_tests = b.addRunArtifact(grpc_transport_unit_tests);
    step.dependOn(&run_grpc_transport_unit_tests.step);

    return step;
}

// Registers the "sdk-examples" step (build and install every Zig and C example
// to zig-out/bin/<category>/, without running them) and the "sdk-run-examples"
// step (run the installed binaries). Splitting build from run means an example
// can be built once and then re-run by hand straight from zig-out/bin.
fn addExamplesStep(
    b: *std.Build,
    mods: *const BuildModules,
    sdk_lib_c: *std.Build.Step.Compile,
    info: CompilationInfo,
    grpc: GrpcProvider,
) !void {
    const step = b.step("sdk-examples", "Build and install all SDK examples to zig-out/bin/<category>/");
    const run_step = b.step("sdk-run-examples", "Run installed SDK examples from zig-out");
    const examples_filter = b.option([]const u8, "examples-filter", "Filter examples to build");

    const examples_dirs: []const []const u8 = &.{ "metrics", "trace", "logs", "baggage", "propagation", "grpc" };
    for (examples_dirs) |example_dir| {
        // The gRPC examples export over OTLP/gRPC on every run, which the noop
        // backend can only fail: build them for a real backend only.
        if (grpc == .none and std.mem.eql(u8, example_dir, "grpc")) continue;

        const example = buildExamples(
            b,
            b.path(b.pathJoin(&.{ sdk_root, "examples", example_dir })),
            mods,
            info,
            examples_filter,
        ) catch |err| {
            std.debug.print("Error building {s} examples: {}\n", .{ example_dir, err });
            return err;
        };
        defer b.allocator.free(example);
        for (example) |exe| {
            helpers.wireExample(b, exe, b.fmt("bin/{s}", .{example_dir}), step, run_step, null);
        }
    }

    const c_examples = [_][]const u8{
        "logs",
        "metrics",
        "trace",
    };

    for (c_examples) |example_name| {
        const c_example_exe = b.addExecutable(.{
            .name = example_name,
            .root_module = b.createModule(.{
                .target = info.target,
                .optimize = info.optimize,
                .link_libc = true,
            }),
        });

        c_example_exe.root_module.addCSourceFile(.{
            .file = b.path(b.pathJoin(&.{
                sdk_root,
                "examples",
                "c",
                b.fmt("{s}.c", .{example_name}),
            })),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
            },
        });
        c_example_exe.root_module.addIncludePath(b.path(sdk_root ++ "/include"));
        c_example_exe.root_module.linkLibrary(sdk_lib_c);

        helpers.wireExample(b, c_example_exe, "bin/c", step, run_step, null);
    }
}

// Registers the "sdk-benchmarks" step, building and running all benchmarks.
pub fn addBenchmarksStep(b: *std.Build, mods: *const BuildModules, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-benchmarks", "Build and run all SDK benchmarks");
    const benchmark_output = b.option([]const u8, "benchmark-output", "Path to write benchmark results to a file");
    const benchmark_debug = b.option(bool, "benchmark-debug", "Enable debug build mode for benchmarks") orelse false;

    var captured_stderr: std.ArrayList(std.Build.LazyPath) = .empty;
    defer captured_stderr.deinit(b.allocator);

    const benchmarked_signals: []const []const u8 = &.{ "logs", "metrics", "trace" };
    for (benchmarked_signals) |signal| {
        const signal_benchmarks = buildBenchmarks(
            b,
            b.path(b.pathJoin(&.{ sdk_root, "benchmarks", signal })),
            mods,
            info,
            benchmark_debug,
        ) catch |err| {
            std.debug.print("Error building {s} benchmarks: {}\n", .{ signal, err });
            return err;
        };
        defer b.allocator.free(signal_benchmarks);
        for (signal_benchmarks) |bench_exe| {
            const run_signal_benchmark = b.addRunArtifact(bench_exe);

            if (benchmark_output != null) {
                try captured_stderr.append(b.allocator, run_signal_benchmark.captureStdErr(.{}));
            }

            step.dependOn(&run_signal_benchmark.step);
        }
    }

    if (benchmark_output) |output_path| {
        const concat = b.addSystemCommand(&.{"cat"});
        for (captured_stderr.items) |p| concat.addFileArg(p);
        const merged = concat.captureStdOut(.{});

        const write = b.addUpdateSourceFiles();
        write.addCopyFileToSource(merged, output_path);
        step.dependOn(&write.step);
    }

    return step;
}

// Registers the "sdk-integration" step (build and install integration tests to
// zig-out/bin/integration_tests/, without running them) and the
// "sdk-run-integration" step (run the installed binaries; requires Docker).
fn addIntegrationStep(
    b: *std.Build,
    mods: *const BuildModules,
    info: CompilationInfo,
    grpc: GrpcProvider,
) !void {
    const integration_filter = b.option(
        []const []const u8,
        "integration-filter",
        "Only build the integration tests with this exact name (repeatable)",
    );
    const step = b.step("sdk-integration", "Build and install SDK integration tests to zig-out/bin/integration_tests/");
    const run_step = b.step("sdk-run-integration", "Run installed SDK integration tests (requires Docker)");

    const integration_tests = buildIntegrationTests(
        b,
        b.path(sdk_root ++ "/integration_tests"),
        mods,
        info,
        integration_filter,
        grpc,
    ) catch |err| {
        std.debug.print("Error building integration tests: {}\n", .{err});
        return err;
    };
    defer b.allocator.free(integration_tests);
    for (integration_tests) |exe| {
        helpers.wireExample(b, exe, "bin/integration_tests", step, run_step, b.path(sdk_root));
    }
}

// Registers the "sdk-docs" step, emitting autodoc for the SDK module.
fn addDocsStep(b: *std.Build, mods: *const BuildModules, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-docs", "Copy SDK documentation artifacts to prefix path");

    var dep_names = [_][]const u8{
        "protobuf",
        "opentelemetry-proto",
        "clock",
    };

    const sdk_docs = b.addObject(.{
        .name = "sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path(sdk_root ++ "/src/sdk.zig"),
            .target = info.target,
            // Doc emission is independent of optimize mode; pin to Debug
            // for the fastest doc builds.
            .optimize = .debug,
            .link_libc = true,
            .imports = try helpers.ImportsFromBuildModules(b.allocator, mods, &dep_names),
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = sdk_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    step.dependOn(&install_docs.step);

    return step;
}

fn buildExamples(
    b: *std.Build,
    examples_dir: std.Build.LazyPath,
    mods: *const BuildModules,
    info: CompilationInfo,
    name_filter: ?[]const u8,
) ![]*std.Build.Step.Compile {
    var exes: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer exes.deinit(b.allocator);

    var ex_dir = try helpers.openSourceDir(b, examples_dir);
    defer ex_dir.close(b.graph.io);

    var ex_dir_iter = ex_dir.iterate();
    while (try ex_dir_iter.next(b.graph.io)) |file| {
        if (helpers.getZigFileName(file.name)) |name| {
            // Discard the modules that do not match the filter
            if (name_filter) |filter| {
                if (std.mem.indexOf(u8, name, filter) == null) continue;
            }
            const file_name = try examples_dir.join(b.allocator, file.name);

            var dep_names = [_][]const u8{
                "opentelemetry-sdk",
                "otlp-stub",
                "opentelemetry-proto",
                "clock",
            };

            const b_mod = b.createModule(.{
                .root_source_file = file_name,
                .target = info.target,
                .optimize = info.optimize,
                .imports = try helpers.ImportsFromBuildModules(b.allocator, mods, &dep_names),
            });
            // Wrap the execution of example main so that a memory leak reports a failing error code.
            try exes.append(b.allocator, b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("build/sdk/example_runner.zig"),
                    .target = info.target,
                    .optimize = info.optimize,
                    .imports = &.{.{ .name = "example", .module = b_mod }},
                }),
            }));
        }
    }

    return exes.toOwnedSlice(b.allocator);
}

fn buildBenchmarks(
    b: *std.Build,
    bench_dir: std.Build.LazyPath,
    mods: *const BuildModules,
    info: CompilationInfo,
    debug_mode: bool,
) ![]*std.Build.Step.Compile {
    var bench_tests: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer bench_tests.deinit(b.allocator);

    var test_dir = try helpers.openSourceDir(b, bench_dir);
    defer test_dir.close(b.graph.io);

    var iter = test_dir.iterate();
    while (try iter.next(b.graph.io)) |file| {
        if (helpers.getZigFileName(file.name)) |name| {
            const file_name = try bench_dir.join(b.allocator, file.name);

            var dep_names = [_][]const u8{
                "opentelemetry-sdk",
                "benchmark",
                "clock",
            };
            const b_mod = b.createModule(.{
                .root_source_file = file_name,
                .target = info.target,
                // We set the optimization level to ReleaseFast for benchmarks
                // because we want to have the best performance.
                .optimize = if (debug_mode) .debug else .fast,
                .strip = !debug_mode,
                .imports = try helpers.ImportsFromBuildModules(b.allocator, mods, &dep_names),
            });

            // Provide dummy test_options so the custom test runner compiles
            const benchmark_test_options = b.addOptions();
            benchmark_test_options.addOption(bool, "verbose", false);
            benchmark_test_options.addOption(bool, "fail_first", false);
            benchmark_test_options.addOption(bool, "show_logs", false);
            b_mod.addOptions("test_options", benchmark_test_options);

            const test_step = b.addTest(.{
                .name = name,
                .root_module = b_mod,
                // Use custom test runner to avoid server protocol (--listen=-)
                .test_runner = .{ .path = b.path("opentelemetry-sdk/src/test_runner.zig"), .mode = .simple },
                .filters = info.test_filters,
            });

            try bench_tests.append(b.allocator, test_step);
        }
    }

    return bench_tests.toOwnedSlice(b.allocator);
}

fn buildIntegrationTests(
    b: *std.Build,
    integration_dir: std.Build.LazyPath,
    mods: *const BuildModules,
    info: CompilationInfo,
    integration_filter: ?[]const []const u8,
    grpc_provider: GrpcProvider,
) ![]*std.Build.Step.Compile {
    const otel_mod = mods.get("opentelemetry-sdk") orelse return BuildError.ModuleNotFound;
    const clock_mod = mods.get("clock") orelse return BuildError.ModuleNotFound;

    var integration_tests: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer integration_tests.deinit(b.allocator);

    var test_dir = helpers.openSourceDir(b, integration_dir) catch |err| switch (err) {
        error.FileNotFound => return integration_tests.toOwnedSlice(b.allocator),
        else => return err,
    };
    defer test_dir.close(b.graph.io);

    // Create common module for shared integration test utilities
    const common_path = try integration_dir.join(b.allocator, "common.zig");

    var dep_names = [_][]const u8{
        "opentelemetry-sdk",
        "clock",
    };
    const common_mod = b.createModule(.{
        .root_source_file = common_path,
        .target = info.target,
        .optimize = info.optimize,
        .imports = try helpers.ImportsFromBuildModules(b.allocator, mods, &dep_names),
    });
    {
        // Tests covering a transport that may not be compiled in (currently
        // only gRPC) read this to skip themselves instead of failing.
        const integration_options = b.addOptions();
        integration_options.addOption(GrpcProvider, "grpc_provider", grpc_provider);
        common_mod.addOptions("integration_options", integration_options);
    }

    var iter = test_dir.iterate();
    while (try iter.next(b.graph.io)) |file| {
        if (helpers.getZigFileName(file.name)) |name| {
            // Skip common.zig as it's not a test executable
            if (std.mem.eql(u8, name, "common")) continue;

            // If integration filter is specified, skip non-matching tests

            const file_name = try integration_dir.join(b.allocator, file.name);
            if (integration_filter) |filter| {
                for (filter) |filter_entry| {
                    if (std.mem.eql(u8, name, filter_entry)) {
                        const b_mod = b.createModule(.{
                            .root_source_file = file_name,
                            .target = info.target,
                            .optimize = info.optimize,
                            .imports = &.{
                                .{ .name = "opentelemetry-sdk", .module = otel_mod },
                                .{ .name = "common", .module = common_mod },
                                .{ .name = "clock", .module = clock_mod },
                            },
                        });

                        try integration_tests.append(b.allocator, b.addExecutable(.{
                            .name = name,
                            .root_module = b_mod,
                        }));
                    }
                }
            } else {
                const b_mod = b.createModule(.{
                    .root_source_file = file_name,
                    .target = info.target,
                    .optimize = info.optimize,
                    .imports = &.{
                        .{ .name = "opentelemetry-sdk", .module = otel_mod },
                        .{ .name = "common", .module = common_mod },
                        .{ .name = "clock", .module = clock_mod },
                    },
                });

                try integration_tests.append(b.allocator, b.addExecutable(.{
                    .name = name,
                    .root_module = b_mod,
                }));
            }
        }
    }

    return integration_tests.toOwnedSlice(b.allocator);
}
