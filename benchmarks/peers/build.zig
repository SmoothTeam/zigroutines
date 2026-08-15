const std = @import("std");

const libxev_url = "https://github.com/mitchellh/libxev";
const libxev_commit = "9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf";
const zigcoro_url = "https://github.com/rsepassi/zigcoro";
const zigcoro_commit = "5fccda31deb16f11616f1e2572d2704b1c5a4b03";
const zio_url = "https://github.com/lalinsky/zio";
const zio_commit = "550e459e7b4125e2b3ed48b870ab62382d094377";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    ensurePeer(b, "libxev", libxev_url, libxev_commit);
    ensurePeer(b, "zigcoro", zigcoro_url, zigcoro_commit);
    ensurePeer(b, "zio", zio_url, zio_commit);
    applyPeerFixes(b);

    const xev = b.createModule(.{
        .root_source_file = b.path(".peer-src/libxev/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const coro_options = b.addOptions();
    coro_options.addOption(usize, "default_stack_size", 4 * 1024);
    coro_options.addOption(usize, "debug_log_level", 0);
    const libcoro = b.createModule(.{
        .root_source_file = b.path("libcoro_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "libcoro_options", .module = coro_options.createModule() },
        },
    });

    const zio_options = b.addOptions();
    zio_options.addOption(?[]const u8, "backend", null);
    zio_options.addOption(enum { strict, best_effort }, "resolve_beneath_mode", .strict);
    zio_options.addOption(bool, "no_hacks", false);
    zio_options.addOption(bool, "task_migration", true);
    zio_options.addOption(bool, "scheduler_metrics", false);
    const zio = b.createModule(.{
        .root_source_file = b.path(".peer-src/zio/src/zio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio_options", .module = zio_options.createModule() },
        },
    });

    const common = b.createModule(.{
        .root_source_file = b.path("common.zig"),
        .target = target,
        .optimize = optimize,
    });

    const want_zigcoro = b.option(bool, "zigcoro", "Build the zigcoro peer (upstream needs a 0.17 port)") orelse false;
    if (want_zigcoro) {
        const coro_mod = b.createModule(.{
            .root_source_file = b.path("zigcoro_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "libcoro", .module = libcoro },
                .{ .name = "common", .module = common },
            },
        });
        if (target.result.os.tag == .windows) {
            coro_mod.linkSystemLibrary("ws2_32", .{});
        }
        const coro_exe = b.addExecutable(.{
            .name = "bench-zigcoro",
            .root_module = coro_mod,
        });
        b.installArtifact(coro_exe);
        const run_coro = b.addRunArtifact(coro_exe);
        b.step("run-zigcoro", "Run zigcoro peer benches").dependOn(&run_coro.step);
    }

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

    const all = b.step("run-all", "Run libxev and zio peer benches");
    all.dependOn(&run_xev.step);
    all.dependOn(&run_zio.step);
}

fn ensurePeer(b: *std.Build, name: []const u8, url: []const u8, commit: []const u8) void {
    const dest = b.root.joinString(b.allocator, b.fmt(".peer-src/{s}", .{name})) catch @panic("OOM");
    const ready = b.pathJoin(&.{ dest, "build.zig" });
    if (fileExists(b, ready)) return;

    const parent = b.root.joinString(b.allocator, ".peer-src") catch @panic("OOM");
    std.Io.Dir.cwd().createDirPath(b.graph.io, parent) catch @panic("cannot create .peer-src");
    b.graph.poisonCache();
    std.debug.print("cloning {s} ({s})…\n", .{ name, commit[0..@min(commit.len, 12)] });
    runGit(b, &.{ "git", "clone", "--filter=blob:none", url, dest });
    runGit(b, &.{ "git", "-C", dest, "-c", "advice.detachedHead=false", "checkout", "--detach", commit });
}

fn applyPeerFixes(b: *std.Build) void {
    const files = [_][]const u8{
        ".peer-src/libxev/src/backend/io_uring.zig",
        ".peer-src/libxev/src/queue.zig",
        ".peer-src/libxev/src/queue_mpsc.zig",
        ".peer-src/libxev/src/watcher/tcp.zig",
        ".peer-src/zigcoro/src/coro.zig",
    };
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    for (files) |rel| {
        const path = b.root.joinString(b.allocator, rel) catch continue;
        const data = cwd.readFileAlloc(io, path, b.allocator, .limited(8 * 1024 * 1024)) catch continue;
        if (std.mem.indexOf(u8, data, " ** ") == null) continue;
        const replaced = std.mem.replaceOwned(u8, b.allocator, data, " ** ", "**") catch continue;
        var file = cwd.createFile(io, path, .{}) catch continue;
        defer file.close(io);
        var w = file.writer(io, &.{});
        w.interface.writeAll(replaced) catch {};
        w.interface.flush() catch {};
    }
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}

fn runGit(b: *std.Build, argv: []const []const u8) void {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv }) catch |err| {
        std.debug.print("peer benches need git on PATH ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (!result.term.success()) {
        std.debug.print("{s}\n", .{result.stderr});
        std.process.exit(1);
    }
}
