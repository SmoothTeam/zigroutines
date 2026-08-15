// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");

const arch_impl = blk: {
    if (builtin.cpu.arch == .x86_64 and
        (builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd))
    {
        break :blk @import("arch/x86_64_assembly.zig");
    }
    if (builtin.cpu.arch == .aarch64 and
        (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd))
    {
        break :blk @import("arch/aarch64_assembly.zig");
    }
    break :blk void;
};

pub const supported: bool = if (arch_impl != void) arch_impl.supported else false;

pub const Entry = if (arch_impl != void) arch_impl.Entry else *const fn (*anyopaque) callconv(.c) void;

pub const Context = if (arch_impl != void) arch_impl.Context else struct {
    _unsupported: u8 = 0,
};

pub const ArchSupport = struct {
    pub const x86_64_linux = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;
    pub const x86_64_windows = builtin.cpu.arch == .x86_64 and builtin.os.tag == .windows;
    pub const x86_64_macos = builtin.cpu.arch == .x86_64 and builtin.os.tag == .macos;
    pub const aarch64_linux = builtin.cpu.arch == .aarch64 and builtin.os.tag == .linux;
    pub const aarch64_macos = builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos;

    pub fn currentSupported() bool {
        return supported;
    }
};

pub fn make(ctx: *Context, stack: []u8, entry: Entry, arg: *anyopaque) void {
    if (comptime !supported) @compileError("context.make: unsupported target");
    arch_impl.make(ctx, stack, entry, arg);
}

pub fn swap(from: *Context, to: *Context) void {
    if (comptime !supported) @compileError("context.swap: unsupported target");
    arch_impl.swap(from, to);
}

pub fn swapFiber(from: *Context, to: *Context) void {
    if (comptime !supported) @compileError("context.swapFiber: unsupported target");
    if (@hasDecl(arch_impl, "swapFiber")) {
        arch_impl.swapFiber(from, to);
    } else {
        arch_impl.swap(from, to);
    }
}

pub fn isInitialized(ctx: *const Context) bool {
    if (comptime !supported) return false;
    return arch_impl.isInitialized(ctx);
}

test {
    if (comptime supported) {
        if (builtin.cpu.arch == .x86_64) {
            _ = @import("arch/x86_64_assembly.zig");
        } else if (builtin.cpu.arch == .aarch64) {
            _ = @import("arch/aarch64_assembly.zig");
        }
    }
}

test "arch support matches runtime target" {
    if (comptime supported) {
        try std.testing.expect(ArchSupport.currentSupported());
    }
}
