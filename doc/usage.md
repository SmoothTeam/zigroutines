# Usage examples

Full runnable files live under **`examples/`**. Build all:

```bash
zig build examples
```

One example:

```bash
zig build example -Dexample=01_minimal_spawn
zig build example -Dexample=04_work_stealing
```

| File | Demonstrates |
|------|----------------|
| `examples/01_minimal_spawn.zig` | Runtime, spawn, yield |
| `examples/02_channel_pipeline.zig` | Buffered channel pipeline |
| `examples/03_select_timeout.zig` | select + timeout |
| `examples/04_work_stealing.zig` | WS scheduler, spawnResult, metrics |
| `examples/05_nursery_cancel.zig` | Nursery deadline + cooperative cancel |
| `examples/06_actor_mailbox.zig` | Actor mailbox |
| `examples/07_sync_and_backpressure.zig` | Mutex/Semaphore + drop_oldest |
| `examples/08_priority_scheduler.zig` | Priority order |

## Minimal spawn (snippet)

```zig
const std = @import("std");
const zr = @import("zigroutines");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rt = try zr.Runtime.init(alloc, .{ .workers = 1 });
    defer rt.deinit();

    _ = try rt.spawn(.{}, struct {
        fn hello(name: []const u8) void {
            std.debug.print("hello from {s}\n", .{name});
            zr.yield();
        }
    }.hello, .{"A"});

    try rt.run();
}
```

## Channel

```zig
const Ch = zr.Channel(usize);
const ch = try Ch.create(alloc, 16);
defer ch.destroy();

_ = try rt.spawn(.{}, struct {
    fn producer(c: *Ch, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) c.send(i) catch return;
        c.close();
    }
}.producer, .{ ch, 5 });

_ = try rt.spawn(.{}, struct {
    fn consumer(c: *Ch) void {
        while (true) {
            const v = c.recv() catch break;
            std.debug.print("got {d}\n", .{v});
        }
    }
}.consumer, .{ch});

try rt.run();
```

## Work-stealing + result

```zig
var rt = try zr.Runtime.init(alloc, .{
    .workers = 4,
    .policy = .work_stealing,
    .stack_pool = true,
    .metrics = true,
});
const h = try rt.spawnResult(.{}, add, .{ 20, 22 });
const sum = h.join();
```

## Select with timeout

```zig
const r = zr.select.recv(u32, ch, .{
    .timeout_ns = 1 * std.time.ns_per_ms,
    .timers = &rt.timers,
});
switch (r) {
    .value => |v| ...,
    .timeout => ...,
    .closed => ...,
    .canceled => ...,
}
```

## Nursery

```zig
var nursery = zr.Nursery.init(rt, .{
    .timeout_ns = 10 * std.time.ns_per_ms,
    .cancel_on_leave = true,
});
defer nursery.deinit();
_ = try nursery.spawn(.{}, child, .{nursery.token()});
_ = nursery.join() catch |err| { ... };
```

## C ABI

```c
#include "zigroutines.h"

static void worker(void *ud) {
    zr_channel *ch = ud;
    uintptr_t v = 0;
    if (zr_channel_recv(ch, &v) == 0)
        zr_channel_send(ch, v + 1);
}

int main(void) {
    zr_runtime *rt = zr_runtime_create(1);
    zr_channel *ch = zr_channel_create(1);
    zr_spawn(rt, worker, ch);
    zr_channel_send(ch, 41);
    zr_runtime_run(rt);
    zr_channel_destroy(ch);
    zr_runtime_destroy(rt);
    return 0;
}
```

