const std = @import("std");
const builtin = @import("builtin");
const sync = @import("../core/synchronization.zig");

pub const default_stack_size: usize = 64 * 1024;

pub const pool_size_classes = [_]usize{
    16 * 1024,
    64 * 1024,
    256 * 1024,
    1024 * 1024,
};

pub const AllocOptions = struct {
    guard_page: bool = false,
    paint_canary: bool = false,
};

const canary_byte: u8 = 0xA5;
const page_size: usize = 4096;

pub const Stack = struct {
    memory: []align(16) u8 = &.{},
    usable: []u8 = &.{},
    from_pool: bool = false,
    class_index: ?u8 = null,
    has_guard: bool = false,
    os_base: ?[*]align(page_size) u8 = null,
    os_total: usize = 0,

    pub fn isEmpty(self: Stack) bool {
        return self.memory.len == 0 and self.os_base == null;
    }

    pub fn size(self: Stack) usize {
        return self.usable.len;
    }

    pub fn bytes(self: Stack) []u8 {
        return self.usable;
    }

    pub fn highWaterUsed(self: Stack) usize {
        if (self.usable.len == 0) return 0;
        var i: usize = 0;
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

pub fn alloc(allocator: std.mem.Allocator, size: usize) !Stack {
    return allocWith(allocator, size, .{});
}

pub fn allocWith(allocator: std.mem.Allocator, size: usize, opts: AllocOptions) !Stack {
    const usable_size = @max(page_size, std.mem.alignForward(usize, size, 16));

    if (opts.guard_page) {
        return allocGuarded(usable_size, opts.paint_canary);
    }

    const memory = try allocator.alignedAlloc(u8, .fromByteUnits(16), usable_size);
    if (opts.paint_canary) {
        @memset(memory, canary_byte);
    }
    return .{
        .memory = memory,
        .usable = memory,
    };
}

fn allocGuarded(usable_size: usize, paint: bool) !Stack {
    const total = page_size + usable_size;
    if (comptime builtin.os.tag == .windows) {
        const base = VirtualAlloc(
            null,
            total,
            MEM_COMMIT | MEM_RESERVE,
            PAGE_READWRITE,
        ) orelse return error.OutOfMemory;

        var old: u32 = undefined;
        if (VirtualProtect(base, page_size, PAGE_NOACCESS, &old) == 0) {
            _ = VirtualFree(base, 0, MEM_RELEASE);
            return error.Unexpected;
        }
        const all: [*]align(page_size) u8 = @ptrCast(@alignCast(base));
        const usable = all[page_size .. page_size + usable_size];
        if (paint) @memset(usable, canary_byte);
        return .{
            .memory = all[0..total],
            .usable = usable,
            .has_guard = true,
            .os_base = all,
            .os_total = total,
        };
    } else {
        const proto = std.posix.PROT.READ | std.posix.PROT.WRITE;
        const flags = std.posix.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const mapped = std.posix.mmap(null, total, proto, flags, -1, 0) catch return error.OutOfMemory;
        std.posix.mprotect(mapped[0..page_size], std.posix.PROT.NONE) catch {
            std.posix.munmap(mapped);
            return error.Unexpected;
        };
        const usable = mapped[page_size .. page_size + usable_size];
        if (paint) @memset(usable, canary_byte);
        return .{
            .memory = mapped,
            .usable = usable,
            .has_guard = true,
            .os_base = @ptrCast(@alignCast(mapped.ptr)),
            .os_total = total,
        };
    }
}

pub fn free(allocator: std.mem.Allocator, stack: Stack) void {
    if (stack.os_base) |base| {
        if (comptime builtin.os.tag == .windows) {
            _ = VirtualFree(base, 0, MEM_RELEASE);
        } else {
            const slice: []align(page_size) u8 = @alignCast(base[0..stack.os_total]);
            std.posix.munmap(slice);
        }
        return;
    }
    if (stack.memory.len != 0) {
        allocator.free(stack.memory);
    }
}

pub const Pool = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    free_lists: [pool_size_classes.len]std.ArrayListUnmanaged([]align(16) u8) = @splat(.empty),
    max_per_class: usize = 64,
    guard_page: bool = false,
    paint_canary: bool = false,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }

    pub fn initWith(allocator: std.mem.Allocator, opts: struct {
        guard_page: bool = false,
        paint_canary: bool = false,
        max_per_class: usize = 64,
    }) Pool {
        return .{
            .allocator = allocator,
            .guard_page = opts.guard_page,
            .paint_canary = opts.paint_canary,
            .max_per_class = opts.max_per_class,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.drain();
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.free_lists) |*list| {
            list.deinit(self.allocator);
        }
        self.* = undefined;
    }

    pub fn acquire(self: *Pool, min_size: usize) !Stack {
        if (self.guard_page) {
            return allocWith(self.allocator, min_size, .{
                .guard_page = true,
                .paint_canary = self.paint_canary,
            });
        }

        const idx = classIndex(min_size) orelse {
            return allocWith(self.allocator, min_size, .{ .paint_canary = self.paint_canary });
        };
        const class_size = pool_size_classes[idx];

        self.lock.lock();
        defer self.lock.unlock();

        if (self.free_lists[idx].items.len > 0) {
            const memory = self.free_lists[idx].pop().?;
            if (self.paint_canary) @memset(memory, canary_byte);
            return .{
                .memory = memory,
                .usable = memory,
                .from_pool = true,
                .class_index = @intCast(idx),
            };
        }
        const memory = try self.allocator.alignedAlloc(u8, .fromByteUnits(16), class_size);
        if (self.paint_canary) @memset(memory, canary_byte);
        return .{
            .memory = memory,
            .usable = memory,
            .from_pool = true,
            .class_index = @intCast(idx),
        };
    }

    pub fn release(self: *Pool, stack: Stack) void {
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
        defer self.lock.unlock();
        for (&self.free_lists) |*list| {
            for (list.items) |mem| {
                self.allocator.free(mem);
            }
            list.clearRetainingCapacity();
        }
    }

    fn classIndex(min_size: usize) ?usize {
        for (pool_size_classes, 0..) |sz, i| {
            if (min_size <= sz) return i;
        }
        return null;
    }
};

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;
const PAGE_NOACCESS: u32 = 0x01;

extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) ?[*]align(1) u8;
extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) u32;
extern "kernel32" fn VirtualProtect(lpAddress: ?*anyopaque, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(.winapi) u32;
