const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zigroutines", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Demo
    const exe = b.addExecutable(.{
        .name = "zigroutines-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cmd/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigroutines", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Test suite: unit + integration + io
    const suite_mod = b.createModule(.{
        .root_source_file = b.path("tests/suite.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigroutines", .module = mod },
        },
    });
    const suite_tests = b.addTest(.{
        .root_module = suite_mod,
    });
    const run_suite = b.addRunArtifact(suite_tests);
    const test_step = b.step("test", "Run unit + integration + io tests");
    test_step.dependOn(&run_suite.step);

    // Manual TCP echo harness
    const tcp_echo_exe = b.addExecutable(.{
        .name = "tcp-echo-manual",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/harness/tcp_echo_manual.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigroutines", .module = mod },
            },
        }),
    });
    const tcp_echo_run = b.addRunArtifact(tcp_echo_exe);
    const tcp_echo_step = b.step("tcp-echo-manual", "Run TCP echo manual harness");
    tcp_echo_step.dependOn(&tcp_echo_run.step);

    // Micro-benchmarks
    const bench_exe = b.addExecutable(.{
        .name = "zigroutines-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigroutines", .module = mod },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run micro-benchmarks (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&bench_run.step);

    // Examples
    const example_files = [_][]const u8{
        "01_minimal_spawn",
        "02_channel_pipeline",
        "03_select_timeout",
        "04_work_stealing",
        "05_nursery_cancel",
        "06_actor_mailbox",
        "07_sync_and_backpressure",
        "08_priority_scheduler",
    };
    const examples_step = b.step("examples", "Build all examples");
    for (example_files) |name| {
        const path = b.fmt("examples/{s}.zig", .{name});
        const ex = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigroutines", .module = mod },
                },
            }),
        });
        const install_ex = b.addInstallArtifact(ex, .{});
        examples_step.dependOn(&install_ex.step);
    }

    const example_name = b.option([]const u8, "example", "Example name without .zig (e.g. 01_minimal_spawn)");
    if (example_name) |ename| {
        const path = b.fmt("examples/{s}.zig", .{ename});
        const ex = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{ename}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigroutines", .module = mod },
                },
            }),
        });
        const run_ex = b.addRunArtifact(ex);
        const example_step = b.step("example", "Build and run one example (-Dexample=NAME)");
        example_step.dependOn(&run_ex.step);
    }
}
