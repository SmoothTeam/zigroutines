const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const xev = libxev_dep.module("xev");

    const coro_options = b.addOptions();
    coro_options.addOption(usize, "default_stack_size", 4 * 1024);
    coro_options.addOption(usize, "debug_log_level", 0);
    const coro_options_mod = coro_options.createModule();

    const libcoro = b.createModule(.{
        .root_source_file = b.path("libcoro_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libcoro_options", .module = coro_options_mod },
        },
    });

    const zio_options = b.addOptions();
    zio_options.addOption(?[]const u8, "backend", null);
    zio_options.addOption(enum { strict, best_effort }, "resolve_beneath_mode", .strict);
    zio_options.addOption(bool, "no_hacks", false);
    zio_options.addOption(bool, "task_migration", true);
    zio_options.addOption(bool, "scheduler_metrics", false);
    const zio_options_mod = zio_options.createModule();

    const zio = b.createModule(.{
        .root_source_file = b.path("deps/zio/src/zio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio_options", .module = zio_options_mod },
        },
    });

    const common = b.createModule(.{
        .root_source_file = b.path("common.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zigcoro
    const coro_exe = b.addExecutable(.{
        .name = "bench-zigcoro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zigcoro_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "libcoro", .module = libcoro },
                .{ .name = "common", .module = common },
            },
        }),
    });
    b.installArtifact(coro_exe);
    const run_coro = b.addRunArtifact(coro_exe);
    b.step("run-zigcoro", "Run zigcoro peer benches").dependOn(&run_coro.step);

    // libxev
    const xev_mod = b.createModule(.{
        .root_source_file = b.path("libxev_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "xev", .module = xev },
            .{ .name = "common", .module = common },
        },
    });
    if (target.result.os.tag == .windows) {
        xev_mod.linkSystemLibrary("ws2_32", .{});
        xev_mod.linkSystemLibrary("mswsock", .{});
    }
    const xev_exe = b.addExecutable(.{
        .name = "bench-libxev",
        .root_module = xev_mod,
    });
    b.installArtifact(xev_exe);
    const run_xev = b.addRunArtifact(xev_exe);
    b.step("run-libxev", "Run libxev peer benches").dependOn(&run_xev.step);

    // zio
    const zio_root = b.createModule(.{
        .root_source_file = b.path("zio_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio", .module = zio },
            .{ .name = "common", .module = common },
        },
    });
    if (target.result.os.tag == .windows) {
        zio_root.linkSystemLibrary("ws2_32", .{});
        zio_root.linkSystemLibrary("mswsock", .{});
    }
    const zio_exe = b.addExecutable(.{
        .name = "bench-zio",
        .root_module = zio_root,
    });
    b.installArtifact(zio_exe);
    const run_zio = b.addRunArtifact(zio_exe);
    b.step("run-zio", "Run zio peer benches").dependOn(&run_zio.step);

    const all = b.step("run-all", "Run all peer benches");
    all.dependOn(&run_coro.step);
    all.dependOn(&run_xev.step);
    all.dependOn(&run_zio.step);
}
