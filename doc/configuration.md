# Runtime configuration (cheat sheet)

```zig
var rt = try zr.Runtime.init(alloc, .{
    .workers = 4,                    // 0 = CPU count
    .policy = .work_stealing,        // auto | single_thread_fifo | work_stealing | priority | thread_per_task
    .stack_pool = true,              // 2 KiB stack freelist (default)
    .task_freelist = true,           // recycle Task control blocks (default)
    .stack_protect = .none,          // none | canary | guard (opt-in)
    .stack_guard_page = false,       // compat: true → .guard
    .stack_paint_canary = false,     // opt-in high-water measurement
    .io = .none,                     // none | poll | iocp | io_uring
    .metrics = false,
    .preempt = .{ .enabled = false, .quantum_ns = ... },
});

// Fixed 2 KiB stack for all stackful tasks
_ = try rt.spawn(.{}, work, .{});
// Opt-in stackless leaf (no private stack; must run to completion — no park/yield/channel):
_ = try rt.spawnLeaf(.{}, pureCompute, .{});
```

Optional features (all opt-in):

```
Runtime.workers / policy     : multi-core WS, priority, 1:1
Runtime.io                   : poll | iocp | io_uring
Runtime.stack_pool           : reuse
Runtime.stack_protect        : none | canary | guard
Runtime.stack_guard_page     : compat alias for guard
Runtime.stack_paint_canary   : high-water scan
Runtime.metrics              : counters
Runtime.preempt / checkpoint : cooperative quantum
Channel full_policy          : block | drop_newest | drop_oldest | error_full
select timeout / cancel      : timer + CancelToken
Scope / Nursery              : structured join (WaitGroup), deadline
spawnResult                  : typed JoinHandle (args/result on the fiber stack when they fit)
TcpListener / TcpStream / UdpSocket
IoAdapter (std.Io)
Actor(Message)
C ABI / tracing hooks
```

