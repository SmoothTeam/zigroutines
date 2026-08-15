// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

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

    const c_lib = b.addLibrary(.{
        .name = "zigroutines",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    if (target.result.os.tag == .windows) {
        c_lib.root_module.linkSystemLibrary("ws2_32", .{});
        c_lib.root_module.linkSystemLibrary("ntdll", .{});
    }
    b.installArtifact(c_lib);
    b.installFile("include/zigroutines.h", "include/zigroutines.h");

    const c_abi_exe = b.addExecutable(.{
        .name = "c-abi-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/abi/c_abi_stub.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_abi_exe.root_module.addCSourceFile(.{
        .file = b.path("tests/abi/c_abi_main.c"),
        .flags = &.{ "-std=c11" },
    });
    c_abi_exe.root_module.addIncludePath(b.path("include"));
    c_abi_exe.root_module.linkLibrary(c_lib);
    const run_c_abi = b.addRunArtifact(c_abi_exe);
    test_step.dependOn(&run_c_abi.step);
    const c_abi_step = b.step("c-abi-test", "Run the C ABI integration executable");
    c_abi_step.dependOn(&run_c_abi.step);

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

    // Benchmarks (fiber/CSP/sync/timer/IO + scale)
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
