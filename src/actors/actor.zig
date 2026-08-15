// SPDX-FileCopyrightText: 2026 Apanazar
//
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const channel_mod = @import("../csp/channel.zig");
const task_mod = @import("../core/task.zig");
const runtime_mod = @import("../core/runtime.zig");
const cancel_mod = @import("../core/cancellation.zig");

pub const ActorError = error{
    Closed,
    WouldBlock,
    Full,
};

pub fn Actor(comptime Message: type) type {
    return struct {
        mailbox: *channel_mod.Channel(Message),
        handle: ?task_mod.JoinHandle = null,
        token: cancel_mod.CancelToken,
        allocator: std.mem.Allocator,
        runtime: *runtime_mod.Runtime,
        parent: ?*cancel_mod.CancelToken = null,
        on_stop: ?*const fn (*Self) void = null,

        const Self = @This();

        pub const SpawnOpts = struct {
            mailbox_capacity: usize = 64,
            full_policy: channel_mod.FullPolicy = .block,
            name: ?[:0]const u8 = null,
            link: ?*cancel_mod.CancelToken = null,
            on_stop: ?*const fn (*Self) void = null,
        };

        pub fn spawn(
            runtime: *runtime_mod.Runtime,
            opts: SpawnOpts,
            comptime handler: anytype,
        ) !*Self {
            const self = try runtime.allocator.create(Self);
            errdefer runtime.allocator.destroy(self);

            const mb = try channel_mod.Channel(Message).createWith(runtime.allocator, opts.mailbox_capacity, .{
                .full_policy = opts.full_policy,
            });
            errdefer mb.destroy();

            self.* = .{
                .mailbox = mb,
                .token = cancel_mod.CancelToken.initWithAllocator(runtime.allocator),
                .allocator = runtime.allocator,
                .runtime = runtime,
                .parent = opts.link,
                .on_stop = opts.on_stop,
            };
            errdefer self.token.deinit();

            if (opts.link) |parent| {
                parent.linkChild(&self.token);
            }

            const Runner = struct {
                fn run(a: *Self) void {
                    while (true) {
                        if (a.token.isCanceled()) break;
                        const msg = a.mailbox.recv() catch break;
                        const info = @typeInfo(@TypeOf(handler)).@"fn";
                        if (info.param_types.len == 2) {
                            handler(msg, a);
                        } else {
                            handler(msg);
                        }
                    }
                    if (a.on_stop) |cb| cb(a);
                }
            };

            self.handle = try runtime.spawn(
                .{ .name = opts.name },
                Runner.run,
                .{self},
            );
            return self;
        }

        pub fn send(self: *Self, msg: Message) ActorError!void {
            self.mailbox.send(msg) catch |err| switch (err) {
                error.Closed => return error.Closed,
                error.WouldBlock => return error.WouldBlock,
                error.Full => return error.Full,
            };
        }

        pub fn trySend(self: *Self, msg: Message) ActorError!void {
            self.mailbox.trySend(msg) catch |err| switch (err) {
                error.Closed => return error.Closed,
                error.WouldBlock => return error.WouldBlock,
                error.Full => return error.Full,
            };
        }

        pub fn cancel(self: *Self) void {
            self.token.cancel();
            self.mailbox.close();
        }

        pub fn join(self: *Self) void {
            if (self.handle) |h| h.join();
        }

        pub fn isDone(self: *const Self) bool {
            if (self.handle) |h| return h.isDone();
            return true;
        }

        pub fn destroy(self: *Self) void {
            self.cancel();
            self.join();
            const Impl = struct {
                fn free(a: *Self) void {
                    a.mailbox.destroy();
                    a.token.deinit();
                    a.allocator.destroy(a);
                }
            };
            task_mod.callOnWorkerStack(Impl.free, .{self});
        }
    };
}
