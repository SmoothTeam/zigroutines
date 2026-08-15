// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../core/synchronization.zig");
const sys_posix = @import("../utils/sys_posix.zig");

pub const fiber_stack_size: usize = 2 * 1024;
pub const default_stack_size: usize = fiber_stack_size;
pub const min_stack_size: usize = fiber_stack_size;
pub const tcb_prefix: usize = 512;
pub const fiber_slot_size: usize = tcb_prefix + fiber_stack_size;
pub const pool_size_classes = [_]usize{fiber_slot_size};

pub const cookie_size: usize = 16;
pub const page_size: usize = 4096;
pub const slot_stride: usize = 2 * page_size;
pub const slab_size: usize = 2 * 1024 * 1024;
pub const slots_per_slab: usize = slab_size / slot_stride;

pub const StackProtect = enum {
    none,
    canary,
    guard,
};

pub const AllocOptions = struct {
    protect: StackProtect = .none,
    guard_page: bool = false,
    paint_canary: bool = false,

    pub fn resolved(self: AllocOptions) StackProtect {
        if (self.protect != .none) return self.protect;
        if (self.guard_page) return .guard;
        return .none;
    }
};

const canary_byte: u8 = 0xA5;
const cookie_words = [2]u64{ 0xC0DEF00DDEADBEEF, 0xBADC0FFEE0DDF00D };

const canary_word: usize = blk: {
    var p: usize = 0;
    for (0..@sizeOf(usize)) |_| {
        p = (p << 8) | canary_byte;
    }
    break :blk p;
};

pub const Stack = struct {
    memory: []align(16) u8 = &.{},
    usable: []u8 = &.{},
    from_pool: bool = false,
    class_index: ?u8 = null,
    has_guard: bool = false,
    has_cookie: bool = false,
    os_base: ?[*]align(page_size) u8 = null,
    os_total: usize = 0,
    arena: ?*Arena = null,
    slab_index: u32 = 0,
    slot_index: u16 = 0,

    pub fn isEmpty(self: Stack) bool {
        return self.memory.len == 0 and self.os_base == null and self.arena == null;
    }

    pub fn size(self: Stack) usize {
        return self.usable.len;
    }

    pub fn bytes(self: Stack) []u8 {
        return self.usable;
    }

    pub fn cookieIntact(self: Stack) bool {
        if (!self.has_cookie or self.usable.len < cookie_size) return true;
        const p: [*]const u64 = @ptrCast(@alignCast(self.usable.ptr));
        return p[0] == cookie_words[0] and p[1] == cookie_words[1];
    }

    pub fn highWaterUsed(self: Stack) usize {
        if (self.usable.len == 0) return 0;
        const start: usize = if (self.has_cookie) cookie_size else 0;
        var i = start;
        const aligned = self.usable.len & ~@as(usize, @sizeOf(usize) - 1);
        while (i + @sizeOf(usize) <= aligned) : (i += @sizeOf(usize)) {
            const w = std.mem.bytesToValue(usize, self.usable[i..][0..@sizeOf(usize)]);
            if (w != canary_word) {
                return self.usable.len - i;
            }
        }
        while (i < self.usable.len) : (i += 1) {
            if (self.usable[i] != canary_byte) {
                return self.usable.len - i;
            }
        }
        return 0;
    }

    pub fn highWaterRatio(self: Stack) f64 {
        if (self.usable.len == 0) return 0;
        return @as(f64, @floatFromInt(self.highWaterUsed())) / @as(f64, @floatFromInt(self.usable.len));
    }
};

fn writeCookie(usable: []u8) void {
    std.debug.assert(usable.len >= cookie_size);
    const p: [*]u64 = @ptrCast(@alignCast(usable.ptr));
    p[0] = cookie_words[0];
    p[1] = cookie_words[1];
}

fn applySurface(usable: []u8, protect: StackProtect, paint: bool) void {
    if (paint) @memset(usable, canary_byte);
    if (protect == .canary) writeCookie(usable);
}

pub fn alloc(allocator: std.mem.Allocator, size: usize) !Stack {
    _ = size;
    return allocWith(allocator, fiber_stack_size, .{});
}

pub fn allocWith(allocator: std.mem.Allocator, size: usize, opts: AllocOptions) !Stack {
    _ = size;
    const usable_size = fiber_stack_size;
    const protect = opts.resolved();

    if (protect == .guard) {
        return allocGuardedStandalone(usable_size, protect, opts.paint_canary);
    }

    const memory = try allocator.alignedAlloc(u8, .fromByteUnits(16), usable_size);
    applySurface(memory, protect, opts.paint_canary);
    return .{
        .memory = memory,
        .usable = memory,
        .has_cookie = protect == .canary,
    };
}

fn posixMapFlags() std.posix.MAP {
    var flags = std.posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    if (comptime @hasField(std.posix.MAP, "NORESERVE")) {
        flags.NORESERVE = true;
    }
    return flags;
}

fn reserveRegion(len: usize) ![]align(page_size) u8 {
    if (comptime builtin.os.tag == .windows) {
        const raw = VirtualAlloc(null, len, MEM_RESERVE, PAGE_NOACCESS) orelse return error.OutOfMemory;
        const all: [*]align(page_size) u8 = @ptrFromInt(@intFromPtr(raw));
        return all[0..len];
    } else {
        const flags = posixMapFlags();
        const mapped = std.posix.mmap(null, len, sys_posix.protNone(), flags, -1, 0) catch return error.OutOfMemory;
        return mapped;
    }
}

fn releaseRegion(base: [*]align(page_size) u8, len: usize) void {
    if (comptime builtin.os.tag == .windows) {
        _ = VirtualFree(base, 0, MEM_RELEASE);
    } else {
        const slice: []align(page_size) u8 = @alignCast(base[0..len]);
        std.posix.munmap(slice);
    }
}

fn stackPage(base: [*]align(page_size) u8, slot_off: usize) [*]align(page_size) u8 {
    const addr = @intFromPtr(base) + slot_off + page_size;
    return @ptrFromInt(addr);
}

fn commitStackPage(base: [*]align(page_size) u8, slot_off: usize) !void {
    const page = stackPage(base, slot_off);
    if (comptime builtin.os.tag == .windows) {
        const ok = VirtualAlloc(page, page_size, MEM_COMMIT, PAGE_READWRITE);
        if (ok == null) return error.OutOfMemory;
    } else {
        sys_posix.mprotect(page[0..page_size], sys_posix.protReadWrite()) catch return error.Unexpected;
    }
}

fn decommitStackPage(base: [*]align(page_size) u8, slot_off: usize) void {
    const page = stackPage(base, slot_off);
    if (comptime builtin.os.tag == .windows) {
        _ = VirtualFree(page, page_size, MEM_DECOMMIT);
    } else {
        if (comptime @hasDecl(std.posix, "madvise")) {
            std.posix.madvise(page, page_size, std.posix.MADV.DONTNEED) catch {};
        }
        sys_posix.mprotect(page[0..page_size], sys_posix.protNone()) catch {};
    }
}

fn stackFromReserved(base: [*]align(page_size) u8, total: usize, slot_off: usize, protect: StackProtect, paint: bool) Stack {
    const usable = (base + slot_off + page_size)[0..fiber_stack_size];
    applySurface(usable, protect, paint);
    return .{
        .memory = base[0..total],
        .usable = usable,
        .has_guard = true,
        .has_cookie = protect == .canary,
        .os_base = base,
        .os_total = total,
    };
}

fn allocGuardedStandalone(usable_size: usize, protect: StackProtect, paint: bool) !Stack {
    _ = usable_size;
    const total = slot_stride;
    const mapped = try reserveRegion(total);
    errdefer releaseRegion(mapped.ptr, total);
    try commitStackPage(mapped.ptr, 0);
    return stackFromReserved(mapped.ptr, total, 0, protect, paint);
}

pub fn free(allocator: std.mem.Allocator, stack: Stack) void {
    if (stack.arena) |arena| {
        arena.release(stack);
        return;
    }
    if (stack.os_base) |base| {
        releaseRegion(base, stack.os_total);
        return;
    }
    if (stack.memory.len != 0) {
        allocator.free(stack.memory);
    }
}

const SlotRef = struct {
    slab: u32,
    index: u16,
    committed: bool,
};

const Slab = struct {
    base: [*]align(page_size) u8,
    len: usize,
};

pub const Arena = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    slabs: std.ArrayListUnmanaged(Slab) = .empty,
    free_list: std.ArrayListUnmanaged(SlotRef) = .empty,
    committed_cached: usize = 0,
    max_cached: usize = 1024,
    paint_canary: bool = false,
    cookie: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: struct {
        paint_canary: bool = false,
        cookie: bool = false,
        max_cached: usize = 1024,
    }) Arena {
        return .{
            .allocator = allocator,
            .paint_canary = opts.paint_canary,
            .cookie = opts.cookie,
            .max_cached = opts.max_cached,
        };
    }

    pub fn deinit(self: *Arena) void {
        self.lock.lock();
        for (self.slabs.items) |slab| {
            releaseRegion(slab.base, slab.len);
        }
        self.slabs.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.lock.unlock();
        self.* = undefined;
    }

    pub fn acquire(self: *Arena) !Stack {
        self.lock.lock();
        if (self.free_list.pop()) |slot| {
            const base = self.slabs.items[slot.slab].base;
            const len = self.slabs.items[slot.slab].len;
            if (slot.committed and self.committed_cached > 0) {
                self.committed_cached -= 1;
            }
            self.lock.unlock();
            return self.activate(slot, base, len);
        }
        self.lock.unlock();
        try self.grow();
        self.lock.lock();
        const slot = self.free_list.pop() orelse {
            self.lock.unlock();
            return error.OutOfMemory;
        };
        const base = self.slabs.items[slot.slab].base;
        const len = self.slabs.items[slot.slab].len;
        if (slot.committed and self.committed_cached > 0) {
            self.committed_cached -= 1;
        }
        self.lock.unlock();
        return self.activate(slot, base, len);
    }

    fn activate(self: *Arena, slot: SlotRef, base: [*]align(page_size) u8, len: usize) !Stack {
        const off = @as(usize, slot.index) * slot_stride;
        if (!slot.committed) {
            try commitStackPage(base, off);
        }
        const protect: StackProtect = if (self.cookie) .canary else .none;
        var st = stackFromReserved(base, len, off, protect, self.paint_canary);
        st.os_base = null;
        st.os_total = 0;
        st.arena = self;
        st.slab_index = slot.slab;
        st.slot_index = slot.index;
        st.from_pool = true;
        return st;
    }

    pub fn release(self: *Arena, stack: Stack) void {
        const slot_off = @as(usize, stack.slot_index) * slot_stride;
        var committed = true;
        self.lock.lock();
        if (self.committed_cached >= self.max_cached) {
            if (stack.slab_index < self.slabs.items.len) {
                decommitStackPage(self.slabs.items[stack.slab_index].base, slot_off);
            }
            committed = false;
        } else {
            self.committed_cached += 1;
        }
        self.free_list.append(self.allocator, .{
            .slab = stack.slab_index,
            .index = stack.slot_index,
            .committed = committed,
        }) catch {
            if (committed and self.committed_cached > 0) self.committed_cached -= 1;
            if (stack.slab_index < self.slabs.items.len) {
                decommitStackPage(self.slabs.items[stack.slab_index].base, slot_off);
            }
            self.lock.unlock();
            return;
        };
        self.lock.unlock();
    }

    fn grow(self: *Arena) !void {
        const mapped = try reserveRegion(slab_size);
        errdefer releaseRegion(mapped.ptr, slab_size);

        self.lock.lock();
        defer self.lock.unlock();

        const slab_idx: u32 = @intCast(self.slabs.items.len);
        self.slabs.append(self.allocator, .{ .base = mapped.ptr, .len = slab_size }) catch {
            releaseRegion(mapped.ptr, slab_size);
            return error.OutOfMemory;
        };

        var i: u16 = 0;
        while (i < slots_per_slab) : (i += 1) {
            self.free_list.append(self.allocator, .{
                .slab = slab_idx,
                .index = i,
                .committed = false,
            }) catch {
                return error.OutOfMemory;
            };
        }
    }
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    free_lists: [pool_size_classes.len]std.ArrayListUnmanaged([]align(16) u8) = @splat(.empty),
    max_per_class: usize = 131072,
    protect: StackProtect = .none,
    paint_canary: bool = false,
    arena: ?Arena = null,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }

    pub fn initWith(allocator: std.mem.Allocator, opts: struct {
        protect: StackProtect = .none,
        guard_page: bool = false,
        paint_canary: bool = false,
        max_per_class: usize = 131072,
    }) Pool {
        const protect: StackProtect = if (opts.protect != .none) opts.protect else if (opts.guard_page) .guard else .none;
        var pool = Pool{
            .allocator = allocator,
            .protect = protect,
            .paint_canary = opts.paint_canary,
            .max_per_class = opts.max_per_class,
        };
        if (protect == .guard) {
            pool.arena = Arena.init(allocator, .{
                .paint_canary = opts.paint_canary,
                .cookie = false,
                .max_cached = opts.max_per_class,
            });
        }
        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.drain();
        if (self.arena) |*a| a.deinit();
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.free_lists) |*list| {
            list.deinit(self.allocator);
        }
        self.* = undefined;
    }

    pub fn acquire(self: *Pool, min_size: usize) !Stack {
        _ = min_size;
        return self.acquireFor(self.protect, self.paint_canary);
    }

    pub fn acquireFor(self: *Pool, protect: StackProtect, paint: bool) !Stack {
        if (protect == .guard) {
            if (self.arena) |*a| {
                var st = try a.acquire();
                st.has_cookie = false;
                return st;
            }
            return allocGuardedStandalone(fiber_stack_size, .none, paint);
        }

        const idx: usize = 0;
        self.lock.lock();
        if (self.free_lists[idx].items.len > 0) {
            const memory = self.free_lists[idx].pop().?;
            self.lock.unlock();
            return finishPoolSlot(memory, protect, paint);
        }
        self.lock.unlock();

        const memory = try self.allocator.alignedAlloc(u8, .fromByteUnits(16), fiber_slot_size);
        @memset(memory[fiber_stack_size..], 0);
        return finishPoolSlot(memory, protect, paint);
    }

    fn finishPoolSlot(memory: []align(16) u8, protect: StackProtect, paint: bool) Stack {
        const usable = memory[0..fiber_stack_size];
        applySurface(usable, protect, paint);
        return .{
            .memory = memory,
            .usable = usable,
            .from_pool = true,
            .class_index = 0,
            .has_cookie = protect == .canary,
        };
    }

    pub fn release(self: *Pool, stack: Stack) void {
        if (stack.arena != null) {
            if (self.arena) |*a| {
                a.release(stack);
                return;
            }
            free(self.allocator, stack);
            return;
        }
        if (stack.has_guard or stack.os_base != null) {
            free(self.allocator, stack);
            return;
        }
        if (stack.memory.len == 0) return;

        self.lock.lock();
        defer self.lock.unlock();

        if (stack.from_pool) {
            if (stack.class_index) |idx| {
                if (idx < pool_size_classes.len and self.free_lists[idx].items.len < self.max_per_class) {
                    self.free_lists[idx].append(self.allocator, stack.memory) catch {
                        self.allocator.free(stack.memory);
                    };
                    return;
                }
            }
        }
        self.allocator.free(stack.memory);
    }

    pub fn drain(self: *Pool) void {
        self.lock.lock();
        for (&self.free_lists) |*list| {
            for (list.items) |mem| {
                self.allocator.free(mem);
            }
            list.clearRetainingCapacity();
        }
        self.lock.unlock();
    }
};

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_DECOMMIT: u32 = 0x4000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;
const PAGE_NOACCESS: u32 = 0x01;

extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) ?[*]align(1) u8;
extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) u32;
