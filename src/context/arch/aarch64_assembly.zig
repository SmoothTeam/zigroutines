const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("arch/aarch64_assembly.zig is only for aarch64");
    }
}

pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;
pub const is_freebsd = builtin.os.tag == .freebsd;
pub const supported = is_linux or is_macos or is_freebsd;

pub const Entry = *const fn (arg: *anyopaque) callconv(.c) void;

/// Layout: x19..x28 (10), fp, lr, sp  → 13 × usize
pub const Context = extern struct {
    x19: usize = 0,
    x20: usize = 0,
    x21: usize = 0,
    x22: usize = 0,
    x23: usize = 0,
    x24: usize = 0,
    x25: usize = 0,
    x26: usize = 0,
    x27: usize = 0,
    x28: usize = 0,
    fp: usize = 0, // x29
    lr: usize = 0, // x30 — resume address
    sp: usize = 0,
};

pub fn isInitialized(ctx: *const Context) bool {
    return ctx.lr != 0 or ctx.sp != 0;
}

fn fiberReturned() callconv(.c) noreturn {
    @panic("zigroutines: context entry returned without swapping out");
}

pub fn make(ctx: *Context, stack: []u8, entry: Entry, arg: *anyopaque) void {
    if (stack.len < 4096) {
        @panic("zigroutines: stack too small (need at least 4KiB)");
    }

    var top: usize = @intFromPtr(stack.ptr) + stack.len;
    // AAPCS64: SP 16-byte aligned
    top &= ~@as(usize, 15);

    // Fake return address
    top -= 8;
    @as(*usize, @ptrFromInt(top)).* = @intFromPtr(&fiberReturned);
    // Align again after push
    top &= ~@as(usize, 15);

    ctx.* = .{};
    ctx.lr = @intFromPtr(&wrapMain);
    ctx.sp = top;
    // Pass entry/arg in callee-saved regs
    ctx.x19 = @intFromPtr(entry);
    ctx.x20 = @intFromPtr(arg);
}

fn wrapMain() callconv(.naked) void {
    // AAPCS64: first arg in x0
    asm volatile (
        \\ mov x0, x20
        \\ br x19
    );
}

pub fn swap(from: *Context, to: *Context) void {
    // AAPCS64: from=x0, to=x1
    asm volatile (
        \\ // save
        \\ str x19, [x0, #0]
        \\ str x20, [x0, #8]
        \\ str x21, [x0, #16]
        \\ str x22, [x0, #24]
        \\ str x23, [x0, #32]
        \\ str x24, [x0, #40]
        \\ str x25, [x0, #48]
        \\ str x26, [x0, #56]
        \\ str x27, [x0, #64]
        \\ str x28, [x0, #72]
        \\ str x29, [x0, #80]
        \\ str x30, [x0, #88]
        \\ mov x2, sp
        \\ str x2, [x0, #96]
        \\ // restore
        \\ ldr x19, [x1, #0]
        \\ ldr x20, [x1, #8]
        \\ ldr x21, [x1, #16]
        \\ ldr x22, [x1, #24]
        \\ ldr x23, [x1, #32]
        \\ ldr x24, [x1, #40]
        \\ ldr x25, [x1, #48]
        \\ ldr x26, [x1, #56]
        \\ ldr x27, [x1, #64]
        \\ ldr x28, [x1, #72]
        \\ ldr x29, [x1, #80]
        \\ ldr x30, [x1, #88]
        \\ ldr x2, [x1, #96]
        \\ mov sp, x2
        \\ ret
        :
        : [from] "{x0}" (from),
          [to] "{x1}" (to),
        : .{
          .x2 = true,
          .x3 = true,
          .x4 = true,
          .x5 = true,
          .x6 = true,
          .x7 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x11 = true,
          .x12 = true,
          .x13 = true,
          .x14 = true,
          .x15 = true,
          .x16 = true,
          .x17 = true,
          .memory = true,
        });
}
