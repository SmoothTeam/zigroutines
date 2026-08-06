const std = @import("std");
const task_mod = @import("../core/task.zig");
const sync = @import("../core/synchronization.zig");
const backend = @import("io_backend.zig");

const Handle = backend.Handle;
const Interest = backend.Interest;
const Waiter = backend.Waiter;
const Backend = backend.Backend;
const BackendError = backend.BackendError;

const Entry = struct {
    handle: Handle,
    waiters: std.ArrayListUnmanaged(*Waiter) = .empty,
};

pub const MockBackend = struct {
    allocator: std.mem.Allocator,
    lock: sync.SpinLock = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    ready_read: std.AutoHashMapUnmanaged(Handle, void) = .empty,
    ready_write: std.AutoHashMapUnmanaged(Handle, void) = .empty,

    pub fn create(allocator: std.mem.Allocator) !*MockBackend {
        const self = try allocator.create(MockBackend);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *MockBackend) void {
        self.lock.lock();
        for (self.entries.items) |*e| e.waiters.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.ready_read.deinit(self.allocator);
        self.ready_write.deinit(self.allocator);
        self.lock.unlock();
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn asBackend(self: *MockBackend) Backend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .deinit = deinitV,
        .wait = waitV,
        .poll = pollV,
    };

    fn deinitV(ptr: *anyopaque) void {
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        self.destroy();
    }
    fn waitV(ptr: *anyopaque, handle: Handle, interest: Interest) BackendError!void {
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        return self.wait(handle, interest);
    }
    fn pollV(ptr: *anyopaque, timeout_ns: u64) BackendError!usize {
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        return self.poll(timeout_ns);
    }

    pub fn setReady(self: *MockBackend, handle: Handle, interest: Interest) !void {
        self.lock.lock();
        defer self.lock.unlock();
        switch (interest) {
            .read => try self.ready_read.put(self.allocator, handle, {}),
            .write => try self.ready_write.put(self.allocator, handle, {}),
        }
    }

    pub fn wait(self: *MockBackend, handle: Handle, interest: Interest) BackendError!void {
        const me = task_mod.current() orelse @panic("zigroutines: mock wait outside task");
        var waiter = Waiter{ .task = me, .interest = interest };

        self.lock.lock();
        const immediate = switch (interest) {
            .read => self.ready_read.contains(handle),
            .write => self.ready_write.contains(handle),
        };
        if (immediate) {
            switch (interest) {
                .read => _ = self.ready_read.remove(handle),
                .write => _ = self.ready_write.remove(handle),
            }
            self.lock.unlock();
            return;
        }

        var found: ?*Entry = null;
        for (self.entries.items) |*e| {
            if (e.handle == handle) {
                found = e;
                break;
            }
        }
        if (found == null) {
            self.entries.append(self.allocator, .{ .handle = handle }) catch {
                self.lock.unlock();
                return error.OutOfMemory;
            };
            found = &self.entries.items[self.entries.items.len - 1];
        }
        found.?.waiters.append(self.allocator, &waiter) catch {
            self.lock.unlock();
            return error.OutOfMemory;
        };
        waiter.parked = true;
        self.lock.unlock();

        const ex = me.executor orelse @panic("mock wait without executor");
        ex.parkFromRunning(.io);

        if (waiter.err) |e| return e;
        if (!waiter.done) return error.Unexpected;
    }

    pub fn poll(self: *MockBackend, timeout_ns: u64) BackendError!usize {
        _ = timeout_ns;
        var woken: usize = 0;
        var to_wake: std.ArrayListUnmanaged(*task_mod.Task) = .empty;
        defer to_wake.deinit(self.allocator);

        self.lock.lock();
        var ei: usize = 0;
        while (ei < self.entries.items.len) {
            const entry = &self.entries.items[ei];
            var wi: usize = 0;
            while (wi < entry.waiters.items.len) {
                const w = entry.waiters.items[wi];
                const ready = switch (w.interest) {
                    .read => self.ready_read.contains(entry.handle),
                    .write => self.ready_write.contains(entry.handle),
                };
                if (!ready) {
                    wi += 1;
                    continue;
                }
                switch (w.interest) {
                    .read => _ = self.ready_read.remove(entry.handle),
                    .write => _ = self.ready_write.remove(entry.handle),
                }
                w.done = true;
                if (w.parked) to_wake.append(self.allocator, w.task) catch {};
                _ = entry.waiters.orderedRemove(wi);
            }
            if (entry.waiters.items.len == 0) {
                entry.waiters.deinit(self.allocator);
                _ = self.entries.orderedRemove(ei);
            } else {
                ei += 1;
            }
        }
        self.lock.unlock();

        for (to_wake.items) |t| {
            @import("../utils/task_wake.zig").wakeTask(t);
            woken += 1;
        }
        return woken;
    }
};
