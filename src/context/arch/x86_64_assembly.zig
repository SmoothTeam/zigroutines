const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86_64) {
        @compileError("arch/x86_64.zig is only for x86_64");
    }
}

pub const is_windows = builtin.os.tag == .windows;
pub const is_linux = builtin.os.tag == .linux;
pub const is_macos = builtin.os.tag == .macos;
pub const is_freebsd = builtin.os.tag == .freebsd;
pub const supported = is_windows or is_linux or is_macos or is_freebsd;
pub const Entry = *const fn (arg: *anyopaque) callconv(.c) void;

pub const ContextLinux = extern struct {
    rip: usize = 0,
    rsp: usize = 0,
    rbp: usize = 0,
    rbx: usize = 0,
    r12: usize = 0,
    r13: usize = 0,
    r14: usize = 0,
    r15: usize = 0,
};

pub const ContextWindows = extern struct {
    rip: usize = 0,
    rsp: usize = 0,
    rbp: usize = 0,
    rbx: usize = 0,
    r12: usize = 0,
    r13: usize = 0,
    r14: usize = 0,
    r15: usize = 0,
    rdi: usize = 0,
    rsi: usize = 0,
    xmm: [20]usize = @splat(0),
    fiber_storage: usize = 0,
    dealloc_stack: usize = 0,
    stack_limit: usize = 0,
    stack_base: usize = 0,
};

pub const Context = if (is_windows) ContextWindows else ContextLinux;

pub fn isInitialized(ctx: *const Context) bool {
    return ctx.rip != 0 or ctx.rsp != 0;
}

fn fiberReturned() callconv(.c) noreturn {
    @panic("zigroutines: context entry returned without swapping out");
}

pub fn make(ctx: *Context, stack: []u8, entry: Entry, arg: *anyopaque) void {
    if (stack.len < 4096) {
        @panic("zigroutines: stack too small (need at least 4KiB)");
    }

    var top: usize = @intFromPtr(stack.ptr) + stack.len;
    top &= ~@as(usize, 15);

    if (comptime is_windows) {
        top -= 32;
    } else {
        top -= 128;
    }

    top -= 8;
    @as(*usize, @ptrFromInt(top)).* = @intFromPtr(&fiberReturned);

    ctx.* = .{};
    ctx.rip = @intFromPtr(&wrapMain);
    ctx.rsp = top;
    ctx.r12 = @intFromPtr(entry);
    ctx.r13 = @intFromPtr(arg);

    if (comptime is_windows) {
        const base: usize = @intFromPtr(stack.ptr);
        const limit = base;
        const stack_top = base + stack.len;
        ctx.stack_base = stack_top;
        ctx.stack_limit = limit;
        ctx.dealloc_stack = base;
        ctx.fiber_storage = 0;
    }
}

fn wrapMain() callconv(.naked) void {
    if (comptime is_windows) {
        // Windows: first arg in RCX
        asm volatile (
            \\ movq %%r13, %%rcx
            \\ jmpq *%%r12
        );
    } else {
        // System V: first arg in RDI
        asm volatile (
            \\ movq %%r13, %%rdi
            \\ jmpq *%%r12
        );
    }
}

pub fn swap(from: *Context, to: *Context) void {
    if (comptime is_windows) {
        swapWindows(from, to);
    } else {
        swapLinux(from, to);
    }
}

fn swapLinux(from: *Context, to: *Context) callconv(.c) void {
    asm volatile (
        \\ leaq 1f(%%rip), %%rax
        \\ movq %%rax, 0(%[from])
        \\ movq %%rsp, 8(%[from])
        \\ movq %%rbp, 16(%[from])
        \\ movq %%rbx, 24(%[from])
        \\ movq %%r12, 32(%[from])
        \\ movq %%r13, 40(%[from])
        \\ movq %%r14, 48(%[from])
        \\ movq %%r15, 56(%[from])
        \\ movq 56(%[to]), %%r15
        \\ movq 48(%[to]), %%r14
        \\ movq 40(%[to]), %%r13
        \\ movq 32(%[to]), %%r12
        \\ movq 24(%[to]), %%rbx
        \\ movq 16(%[to]), %%rbp
        \\ movq 8(%[to]), %%rsp
        \\ jmpq *0(%[to])
        \\ 1:
        :
        : [from] "r" (from),
          [to] "r" (to),
        : .{
          .rax = true,
          .rcx = true,
          .rdx = true,
          .rsi = true,
          .rdi = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .memory = true,
        });
}

fn swapWindows(from: *Context, to: *Context) callconv(.c) void {
    asm volatile (
        \\ movq %[to], %%r11
        \\ leaq 1f(%%rip), %%rax
        \\ movq %%rax, 0(%[from])
        \\ movq %%rsp, 8(%[from])
        \\ movq %%rbp, 16(%[from])
        \\ movq %%rbx, 24(%[from])
        \\ movq %%r12, 32(%[from])
        \\ movq %%r13, 40(%[from])
        \\ movq %%r14, 48(%[from])
        \\ movq %%r15, 56(%[from])
        \\ movq %%rdi, 64(%[from])
        \\ movq %%rsi, 72(%[from])
        \\ movups %%xmm6, 80(%[from])
        \\ movups %%xmm7, 96(%[from])
        \\ movups %%xmm8, 112(%[from])
        \\ movups %%xmm9, 128(%[from])
        \\ movups %%xmm10, 144(%[from])
        \\ movups %%xmm11, 160(%[from])
        \\ movups %%xmm12, 176(%[from])
        \\ movups %%xmm13, 192(%[from])
        \\ movups %%xmm14, 208(%[from])
        \\ movups %%xmm15, 224(%[from])
        // TEB (GS:[0x30]) stack bookkeeping
        \\ movq %%gs:0x30, %%r10
        \\ movq 0x20(%%r10), %%rax
        \\ movq %%rax, 240(%[from])
        \\ movq 0x1478(%%r10), %%rax
        \\ movq %%rax, 248(%[from])
        \\ movq 0x10(%%r10), %%rax
        \\ movq %%rax, 256(%[from])
        \\ movq 0x08(%%r10), %%rax
        \\ movq %%rax, 264(%[from])
        // Restore TEB from `to` (r11)
        \\ movq 264(%%r11), %%rax
        \\ movq %%rax, 0x08(%%r10)
        \\ movq 256(%%r11), %%rax
        \\ movq %%rax, 0x10(%%r10)
        \\ movq 248(%%r11), %%rax
        \\ movq %%rax, 0x1478(%%r10)
        \\ movq 240(%%r11), %%rax
        \\ movq %%rax, 0x20(%%r10)
        // Restore XMM + GPRs from `to` (r11)
        \\ movups 224(%%r11), %%xmm15
        \\ movups 208(%%r11), %%xmm14
        \\ movups 192(%%r11), %%xmm13
        \\ movups 176(%%r11), %%xmm12
        \\ movups 160(%%r11), %%xmm11
        \\ movups 144(%%r11), %%xmm10
        \\ movups 128(%%r11), %%xmm9
        \\ movups 112(%%r11), %%xmm8
        \\ movups 96(%%r11), %%xmm7
        \\ movups 80(%%r11), %%xmm6
        \\ movq 72(%%r11), %%rsi
        \\ movq 64(%%r11), %%rdi
        \\ movq 56(%%r11), %%r15
        \\ movq 48(%%r11), %%r14
        \\ movq 40(%%r11), %%r13
        \\ movq 32(%%r11), %%r12
        \\ movq 24(%%r11), %%rbx
        \\ movq 16(%%r11), %%rbp
        \\ movq 8(%%r11), %%rsp
        \\ jmpq *0(%%r11)
        \\ 1:
        :
        : [from] "r" (from),
          [to] "r" (to),
        : .{
          .rax = true,
          .rcx = true,
          .rdx = true,
          .r8 = true,
          .r9 = true,
          .r10 = true,
          .r11 = true,
          .memory = true,
        });
}

const TestPair = struct {
    main: Context = .{},
    fiber: Context = .{},
    hits: usize = 0,
    depth_ok: bool = false,
};

fn pingPongEntry(arg: *anyopaque) callconv(.c) void {
    const p: *TestPair = @ptrCast(@alignCast(arg));
    p.hits += 1;
    swap(&p.fiber, &p.main);
    p.hits += 1;
    swap(&p.fiber, &p.main);
    p.hits += 1;
    swap(&p.fiber, &p.main);
}

fn deep(n: u32, p: *TestPair) void {
    var pad: [64]u8 = undefined;
    @memset(&pad, @truncate(n));
    if (n == 0) {
        p.depth_ok = (pad[0] == 0);
        swap(&p.fiber, &p.main);
        return;
    }
    deep(n - 1, p);
    std.mem.doNotOptimizeAway(&pad);
}

fn deepEntry(arg: *anyopaque) callconv(.c) void {
    const p: *TestPair = @ptrCast(@alignCast(arg));
    deep(200, p);
    swap(&p.fiber, &p.main);
}

test "context swap ping-pong" {
    if (comptime !supported) return error.SkipZigTest;

    var pair: TestPair = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), 64 * 1024);
    defer std.testing.allocator.free(stack_mem);

    make(&pair.fiber, stack_mem, pingPongEntry, &pair);

    try std.testing.expect(isInitialized(&pair.fiber));
    try std.testing.expectEqual(@as(usize, 0), pair.hits);

    swap(&pair.main, &pair.fiber); // hit 1
    try std.testing.expectEqual(@as(usize, 1), pair.hits);
    swap(&pair.main, &pair.fiber); // hit 2
    try std.testing.expectEqual(@as(usize, 2), pair.hits);
    swap(&pair.main, &pair.fiber); // hit 3
    try std.testing.expectEqual(@as(usize, 3), pair.hits);
}

test "context preserves deep call stack" {
    if (comptime !supported) return error.SkipZigTest;

    var pair: TestPair = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), 64 * 1024);
    defer std.testing.allocator.free(stack_mem);

    make(&pair.fiber, stack_mem, deepEntry, &pair);
    swap(&pair.main, &pair.fiber);
    try std.testing.expect(pair.depth_ok);
}

test "many swaps stress" {
    if (comptime !supported) return error.SkipZigTest;

    const State = struct {
        main: Context = .{},
        fiber: Context = .{},
        count: usize = 0,
        target: usize = 10_000,
    };

    const entry = struct {
        fn f(arg: *anyopaque) callconv(.c) void {
            const s: *State = @ptrCast(@alignCast(arg));
            while (s.count < s.target) {
                s.count += 1;
                swap(&s.fiber, &s.main);
            }
            swap(&s.fiber, &s.main);
        }
    }.f;

    var state: State = .{};
    const stack_mem = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16), 32 * 1024);
    defer std.testing.allocator.free(stack_mem);

    make(&state.fiber, stack_mem, entry, &state);
    while (state.count < state.target) {
        swap(&state.main, &state.fiber);
    }
    swap(&state.main, &state.fiber);
    try std.testing.expectEqual(@as(usize, 10_000), state.count);
}
