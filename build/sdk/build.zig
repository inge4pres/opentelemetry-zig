const std = @import("std");
const helpers = @import("../helpers.zig");

const BuildError = helpers.BuildError;
const BuildModules = helpers.BuildModules;
const CompilationInfo = helpers.CompilationInfo;

// Path of the OpenTelemetry SDK source root directory relative to the build.zig file.
const sdk_root = "opentelemetry-sdk";

// Sets up the dependencies, modules and static library for the OpenTelemetry
// SDK, and installs its artifacts and headers.
pub fn Setup(
    b: *std.Build,
    info: CompilationInfo,
    dependencies: *BuildModules,
) !void {
    try modules(b, info, dependencies);

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

    _ = try addTestStep(b, dependencies);
    _ = try addExamplesStep(b, dependencies, info);
    _ = try addExamplesCStep(b, sdk_lib, info);
    _ = try addBenchmarksStep(b, dependencies, info);
    _ = try addIntegrationStep(b, dependencies, info);

    const docs_step = try addDocsStep(b, dependencies, info);
    docs_step.dependOn(&sdk_lib.step);
}

fn modules(b: *std.Build, info: CompilationInfo, dependencies: *BuildModules) !void {
    const clock_mod = b.createModule(.{
        .root_source_file = b.path(sdk_root ++ "/src/clock.zig"),
        .target = info.target,
        .optimize = info.optimize,
        .link_libc = true,
    });
    try dependencies.put("clock", clock_mod);

    var sdk_dep_names = [_][]const u8{
        "protobuf",
        "opentelemetry-proto",
        "clock",
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
        .optimize = .Debug,
        .imports = try helpers.ImportsFromBuildModules(b.allocator, dependencies, &otlp_stub_dep_names),
    });
    try dependencies.put("otlp-stub", otel_stub_mod);

    return;
}

// Registers the "sdk-test" step, building and running the SDK unit tests.
fn addTestStep(b: *std.Build, mods: *const BuildModules) !*std.Build.Step {
    const step = b.step("sdk-test", "Run SDK unit tests");

    const test_verbose = b.option(bool, "test-verbose", "Show verbose test output") orelse false;
    const test_fail_first = b.option(bool, "test-fail-first", "Stop on first test failure") orelse false;
    const test_show_logs = b.option(bool, "test-show-logs", "Show captured log output for tests") orelse false;

    const sdk_unit_tests = b.addTest(.{
        .root_module = mods.get("opentelemetry-sdk") orelse return BuildError.ModuleNotFound,
        // Use custom test runner to capture log output
        .test_runner = .{ .path = b.path(sdk_root ++ "/src/test_runner.zig"), .mode = .simple },
        // Allow passing test filter using the build args.
        .filters = b.args orelse &[0][]const u8{},
    });

    // Pass test options as build options
    const test_options = b.addOptions();
    test_options.addOption(bool, "verbose", test_verbose);
    test_options.addOption(bool, "fail_first", test_fail_first);
    test_options.addOption(bool, "show_logs", test_show_logs);
    sdk_unit_tests.root_module.addOptions("test_options", test_options);

    const run_sdk_unit_tests = b.addRunArtifact(sdk_unit_tests);
    step.dependOn(&run_sdk_unit_tests.step);

    return step;
}

// Registers the "sdk-examples" step, building and running all Zig examples.
fn addExamplesStep(b: *std.Build, mods: *const BuildModules, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-examples", "Build and run all SDK examples");
    const examples_filter = b.option([]const u8, "examples-filter", "Filter examples to build");

    const examples_dirs: []const []const u8 = &.{ "metrics", "trace", "logs", "baggage", "propagation" };
    for (examples_dirs) |example_dir| {
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
            const run_example = b.addRunArtifact(exe);
            step.dependOn(&run_example.step);
        }
    }

    return step;
}

// Registers the "sdk-examples-c" step, building and running all C examples.
fn addExamplesCStep(b: *std.Build, sdk_lib_c: *std.Build.Step.Compile, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-examples-c", "Build and run SDK C examples");

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

        const run_c_example = b.addRunArtifact(c_example_exe);
        step.dependOn(&run_c_example.step);

        // Also install each C example executable
        b.installArtifact(c_example_exe);
    }

    return step;
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

// Registers the "sdk-integration" step, building and running integration tests.
fn addIntegrationStep(b: *std.Build, mods: *const BuildModules, info: CompilationInfo) !*std.Build.Step {
    const step = b.step("sdk-integration", "Run SDK integration tests (requires Docker)");

    const integration_tests = buildIntegrationTests(
        b,
        b.path(sdk_root ++ "/integration_tests"),
        mods,
        info,
    ) catch |err| {
        std.debug.print("Error building integration tests: {}\n", .{err});
        return err;
    };
    defer b.allocator.free(integration_tests);
    for (integration_tests) |exe| {
        const run_integration_test = b.addRunArtifact(exe);
        run_integration_test.setCwd(b.path(sdk_root));
        step.dependOn(&run_integration_test.step);
    }

    return step;
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
            .optimize = .Debug,
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

    var ex_dir = try examples_dir.getPath3(b, null).openDir(std.Options.debug_io, "", .{ .iterate = true });
    defer ex_dir.close(std.Options.debug_io);

    var ex_dir_iter = ex_dir.iterate();
    while (try ex_dir_iter.next(std.Options.debug_io)) |file| {
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
            try exes.append(b.allocator, b.addExecutable(.{
                .name = name,
                .root_module = b_mod,
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

    var test_dir = try bench_dir.getPath3(b, null).openDir(std.Options.debug_io, "", .{ .iterate = true });
    defer test_dir.close(std.Options.debug_io);

    var iter = test_dir.iterate();
    while (try iter.next(std.Options.debug_io)) |file| {
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
                .optimize = if (debug_mode) .Debug else .ReleaseFast,
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
                // Allow passing benchmark filter using the build args.
                .filters = b.args orelse &[0][]const u8{},
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
) ![]*std.Build.Step.Compile {
    const otel_mod = mods.get("opentelemetry-sdk") orelse return BuildError.ModuleNotFound;
    const clock_mod = mods.get("clock") orelse return BuildError.ModuleNotFound;

    var integration_tests: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer integration_tests.deinit(b.allocator);

    var test_dir = integration_dir.getPath3(b, null).openDir(std.Options.debug_io, "", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return integration_tests.toOwnedSlice(b.allocator),
        else => return err,
    };
    defer test_dir.close(std.Options.debug_io);

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

    var iter = test_dir.iterate();
    while (try iter.next(std.Options.debug_io)) |file| {
        if (helpers.getZigFileName(file.name)) |name| {
            // Skip common.zig as it's not a test executable
            if (std.mem.eql(u8, name, "common")) continue;

            // If integration filter is specified, skip non-matching tests
            const integration_filter = b.args;

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
