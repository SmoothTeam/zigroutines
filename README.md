<!--
SPDX-FileCopyrightText: 2026 Apanazar

SPDX-License-Identifier: LGPL-3.0-or-later
-->

# zigroutines

| | |
|--|--|
| **Version** | **1.0.0** |
| **License** | **LGPL-3.0-or-later** ([LICENSE](LICENSE)) |
| **Platforms** | **x86_64/aarch64**;  Windows, Linux, macOS, FreeBSD |
| **Zig** | **0.17-dev.1503+** |

```bash
zig build test -Doptimize=ReleaseSafe
zig build c-abi-test -Doptimize=ReleaseSafe
zig build bench -Doptimize=ReleaseFast
zig build run
zig build examples
zig build example -Dexample=01_minimal_spawn
```

`zig build` also installs the static C library (`libzigroutines/zigroutines.lib`) and `include/zigroutines.h`.

---

## 1. What is zigroutines?

### 1.1. In short

**zigroutines** is a library for **explicit stackful concurrency** in Zig. It gives you a Go-shaped model (tasks, channels, `select`, cancellation, timers) with Zig’s philosophy: **nothing global, nothing hidden, pay only for what you enable**.

Unlike a "runtime baked into the language", **you construct** a `Runtime`, choose the scheduler policy, I/O backend, and metrics. Stacks are **fixed 2 KiB** (no growth, no per-task dial). No GC. No netpoller until you plug one in.

At a glance:

| Property | Value |
|----------|--------|
| Model | M:N **stackful** tasks on **fixed 2 KiB** stacks (no growth, no per-task size choice) + opt-in **leaf** (stackless run-to-completion) |
| Schedulers | FIFO · work-stealing · priority · 1 OS thread per task |
| CSP | `Channel(T)`, rendezvous / buffered, multi-arm `select` (up to 32 arms per kind) |
| Cancellation | Cooperative, hierarchical `CancelToken`, `Scope` / `Nursery` |
| I/O | Plugin: `none` / `poll` / `iocp` / `io_uring` |
| Synchronization | Mutex (adaptive), Semaphore, RwLock, RateLimiter, **Notify**, **Watch(T)** — park the **task**, not the OS thread |
| Timers | Hierarchical **wheel** (256×1 ms) + heap overflow |
| Cost | Pay-for-what-you-use; stack pool + task freelist on; in-stack spawn args/result; channel `createPooled` for hot create |

### 1.2. What it gives Zig developers

1. **Write top-down “sync-looking” code** — `send` / `recv` / `sleep` / `yield` look like ordinary calls; under the hood the task parks and yields the CPU to other fibers. No function coloring (`async`/`await` does not infect the call tree).

2. **Predictable resources** — every fiber has a **fixed 2 KiB** stack (no size dial). Heavy buffers go on the heap. Stack pool on by default. Overflow policy is opt-in (`none` / `canary` / `guard`); guard pages share a reserved arena so they do not cost 8 KiB committed + one VMA per task.

3. **Swap scheduling policy without changing the API** — the same `spawn` works on FIFO (1 worker), work-stealing (many cores), priority, and thread-per-task.

4. **Go-style CSP** — channels, rendezvous, backpressure policies (`block`, `drop_newest`, `drop_oldest`, `error_full`), `select` with timeout and cancel.

5. **Structured concurrency** — `Scope` / `Nursery` with deadline, `cancel_on_leave`, `cancel_on_first_done`, typed `spawnResult` + `JoinHandle`.

6. **Pluggable I/O** — I/O off by default (the core stays quiet); when needed — poll / IOCP / io_uring, TCP/UDP helpers, bridge to `std.Io`.

7. **Observability** — optional atomic metrics, tracing hooks, preemption checkpoints.

8. **Actors and C ABI** — `Actor(Message)` (mailbox = channel + loop), optional C surface.

### 1.3. Advantages over similar libraries

#### Within the Zig ecosystem

| | **libxev** | **zigcoro / zio** | **zigroutines** |
|--|------------|-------------------|-----------------|
| Primary job | Event loop / completions | Coroutines + some I/O | **Full concurrency stack** |
| Stackful sync style | No (callback / future) | Yes | **Yes** |
| Channels + multi-select | No | Partial / ad-hoc | **First-class CSP** |
| Pluggable scheduler policies | N/A | Limited | **FIFO / WS / priority / 1:1** |
| Fixed stack + pool + guard | N/A | Varies | **Explicit and default** |
| Structured cancel / nursery | No | Limited | **Scope + Nursery** |
| Quiet netpoller by default | You wire it | Often coupled to the runtime | **Off until you configure it** |


#### Versus Go, C++, Rust

| | Go | C++20 / fiber libs | async Rust + Tokio | **zigroutines** |
|--|----|--------------------|--------------------|-----------------|
| DX | Excellent (`go`, `chan`, `select`) | Assemble the pieces | `async`/`await`, Pin/Send | **Same shape**, native Zig |
| Runtime | Hidden M:N | Zoo of executors | Multiple runtimes | **Explicit `Runtime`** |
| Stack | Grows (copy) | Stackless or 3rd-party fibers | Stackless state machines | **Fixed only** |
| GC | Yes, STW risk | No | No | **No** |
| Netpoller | Built-in, not optional | Whatever you build | Usually in the runtime | **Off by default** |
| Function coloring | No | `co_await` | `async` everywhere | **No** |

Go wins “ship a service in an afternoon.” zigroutines wins when you **cannot** accept GC, silent stack growth, or an immovable runtime. C++ can match the control if you are an expert and assemble the stack yourself. Tokio is world-class for Rust; on **Zig**, zigroutines keeps the mental model “task + stack + channel” without async coloring.

The Zig-library table above is a glance. **5.3** is why a nanosecond in 5.2 is not a product verdict: zigcoro, zio, and libxev are different machines, and a cell we lose is usually a constraint they do not have.

### 1.4. Why choose this

1. **One coherent surface** — scheduler, I/O, cancel, CSP, stacks, metrics: policies you enable, not a hidden runtime.
2. **Honest to Zig** — no process-global runtime, no GC, no silent growth; pay only for enabled features.
3. **Go-shaped DX** — write top-down; park on channels/timers/I/O without rewriting the call tree.
4. **Measurable cost** — fixed stacks, context saved on the fiber stack (not in the TCB), optional metrics/canary, explicit park/wake rules.


### 1.5. How to depend on it in your project

Package version: **1.0.0**. Repository: [Apanazar/zigroutines](https://github.com/Apanazar/zigroutines).

#### Via `build.zig.zon` (recommended)

Pin a release (hash is filled by `zig fetch --save`):

```bash
zig fetch --save=zigroutines https://github.com/Apanazar/zigroutines/archive/refs/tags/v1.0.0.tar.gz
```

Or from a local checkout:

```bash
zig fetch --save=zigroutines ./path/to/zigroutines
```

Then in `build.zig.zon` you will have something like:

```zig
.{
    .name = .my_app,
    .version = "0.0.1",
    .dependencies = .{
        .zigroutines = .{
            .url = "https://github.com/Apanazar/zigroutines/archive/refs/tags/v1.0.0.tar.gz",
            .hash = "…", // written by zig fetch --save
        },
    },
    .paths = .{""},
}
```

Wire the module in `build.zig`:

```zig
const zr_dep = b.dependency("zigroutines", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigroutines", zr_dep.module("zigroutines"));
```

#### Import in code

```zig
const zr = @import("zigroutines");

var rt = try zr.Runtime.init(allocator, .{ .workers = 1 });
defer rt.deinit();
_ = try rt.spawn(.{}, myFn, .{});
try rt.run();
```
---

## 2. Architecture

### 2.1. Diagram (logical view)

```
                    your code (sync-looking style)
             spawn · channel · select · nursery · sleep
                              │
       ┌──────────────────────┼──────────────────────┐
       ▼                      ▼                      ▼
  ┌─────────┐           ┌──────────┐           ┌────────────┐
  │  Task   │◄──park/── │ Channel  │           │ Scope /    │
  │ (fiber) │    wake   │ + select │           │ Nursery    │
  └────┬────┘           └──────────┘           └─────┬──────┘
       │                                             │
       ▼                                             ▼
  ┌──────────────────────────────────────────────────────────┐
  │  Runtime  (you construct it - not process-global)        │
  │  scheduler · timers · metrics · cancel · I/O backend     │
  └──────────────┬───────────────────────────┬───────────────┘
                 │                           │
        ┌────────┴────────┐         ┌────────┴────────┐
        ▼                 ▼         ▼                 ▼
   FIFO / work-steal   fixed     poll / IOCP /     std.Io
   priority / 1:1      stacks    io_uring          adapter
                       + pool
```

**Defaults:** 1 worker · FIFO · **fixed 2 KiB** stacks · stack pool on · task freelist on · `stack_protect = .none` · I/O off · metrics off · preemption off. (Channel recycle is opt-in via `createPooled` so test allocators stay leak-free.)

### 2.2. Layers and control flow

1. **Application layer** — your functions invoked via `Runtime.spawn` / `spawnResult` / `Nursery.spawn` / `Actor`.
2. **CSP / sync** — `Channel`, `select`, Mutex/Semaphore/…: on block, call `parkFromRunning` on the current executor.
3. **Task** — unit of execution: id, state, fixed stack, context saved **on the fiber stack**, join-waiters, optional result slot (also on the stack when it fits).
4. **Scheduler backend** — ready queue, worker↔task context swap, live/dead accounting, timer/I/O poll in idle.
5. **Runtime** — facade: config, backend creation, stack pool, timer queue, I/O ownership, TLS “current runtime”.
6. **Context / arch** — assembly stack switch (x86_64 / aarch64).
7. **Utils** — lock-free / intrusive structures (Chase-Lev deque, ring queue, lists).

### 2.3. Entities, mechanisms, policies, algorithms

Below is a full catalog of “what exists in the system” and **where the code lives**.

#### 2.3.1. Core (Runtime, Task, Executor)

| Entity | Role | Files |
|--------|------|--------|
| **Runtime** | Owns scheduler, timers, optional I/O/metrics; API `init` / `spawn` / `run` / `sleep` | `src/core/runtime.zig` |
| **Config** | workers, policy, stack options, io, metrics, preempt | `src/core/runtime.zig` |
| **Task** | Fiber: stack, context, state machine, join | `src/core/task.zig` |
| **JoinHandle / TypedJoinHandle** | Wait for completion; typed result | `src/core/task.zig` |
| **Executor** | VTable: enqueue, yield, park, finish | `src/core/executor.zig` |
| **yield / current / sleep** | Cooperative CPU yield; TLS current task; sleep via timers | `task.zig`, `runtime.zig` |

**Rules:** `yield` / `channel` / `sync` are allowed **only inside a task**. Outside a task — panic with a clear message. `sleep` requires a TLS runtime (set by `run`). `Runtime.spawn` / `spawnResult` from a fiber bounce onto the worker stack (2 KiB is not enough for the spawn path).

#### 2.3.2. Schedulers (policies)

| Policy | Behavior | Files |
|--------|----------|--------|
| **auto** | 1 worker → FIFO; ≥2 → work-stealing | `runtime.zig` |
| **single_thread_fifo** | One queue, one thread, strict FIFO | `src/scheduler/fifo_scheduler.zig` |
| **work_stealing** | N workers, local deques, steal | `src/scheduler/work_stealing_scheduler.zig` + `utils/chase_lev.zig` |
| **priority** | 1 worker, min-heap / priority queue by `SpawnOptions.priority` (0 = highest) | `src/scheduler/priority_scheduler.zig` + `utils/priority_queues.zig` |
| **thread_per_task** | 1 OS thread per task (1:1), for comparison / blocking FFI | `src/scheduler/thread_per_task_scheduler.zig` |
| Shared facade | | `src/scheduler/scheduler.zig` |


#### 2.3.3. Stacks

| Mechanism | Role | Files |
|-----------|------|--------|
| **Stack** | Fixed 2 KiB usable region | `src/stack/stack.zig` |
| **Pool slot** | `[2 KiB usable \| 512 B TCB]`; TCB sits *above* the stack so frames cannot smash it | `stack.zig`, `task.zig` |
| **Pool** | Reuse; heap class for `none`/`canary`, arena slots for `guard` | `stack.zig` |
| **`StackProtect.none`** | Default: no extra RSS, no check | `stack.zig` |
| **`StackProtect.canary`** | Opt-in 16-byte cookie; checked on yield/park/finish | `stack.zig` |
| **`StackProtect.guard`** | Opt-in OS fault via a reserved arena (not one mmap per task) | `stack.zig` |
| **paint_canary** | Full pattern fill; `highWaterUsed()` (word scan) | `stack.zig` |


#### 2.3.4. Context switch

| Entity | Role | Files |
|--------|------|--------|
| **Context** | Saved registers; stored at the **top** of the fiber stack (TCB holds a pointer) | `src/context/context.zig`, `src/core/task.zig` |
| **x86_64 / aarch64 asm** | `make` / `swap` | `src/context/arch/x86_64_assembly.zig`, `aarch64_assembly.zig` |
| **supported** | comptime flag for the target platform | `context.zig` |

#### 2.3.5. CSP: channels and select

| Entity | Role | Files |
|--------|------|--------|
| **Channel(T)** | Buffered or rendezvous (capacity 0); MPMC seq-slot ring (lock only for waiters); optional `spsc`/`mpsc` topology | `src/csp/channel.zig` |
| **FullPolicy** | `block` · `drop_newest` · `drop_oldest` · `error_full` | `channel.zig` |
| **send / recv / try\*** | Blocking and non-blocking ops | `channel.zig` |
| **select.multi / recv / recvAny** | Up to 32 recv + 32 send arms; timeout; cancel; default | `src/csp/select.zig` |
| **Fairness** | `random` (default) / `fifo` when several arms are ready | `select.zig` |

**Scenarios:** pipeline, fan-in/fan-out, rendezvous handoff, backpressure telemetry (`drop_*`), non-blocking poll (`try` / `default` arm).

#### 2.3.6. Cancellation and structured concurrency

| Entity | Role | Files |
|--------|------|--------|
| **CancelToken** | Atomic flag, parent→children link, waiters | `src/core/cancellation.zig` |
| **Scope** | Group of children + token; `WaitGroup` join (last child wakes the parent) | `src/core/structured_concurrency.zig` |
| **Nursery** | Scope + deadline/timeout + `cancel_on_first_done` + `tryJoin` | `structured_concurrency.zig` |

**Cooperative rule:** cancel **does not interrupt** machine code. Children must **poll** the token (or wait on select/channel with cancel). A deliberate “explicit over implicit” choice.

#### 2.3.7. Timers

| Entity | Role | Files |
|--------|------|--------|
| **TimerQueue** | Near-term **wheel** (256×1 ms) + min-heap for long deadlines; occupied **bitmap** (`@ctz` on 4×u64) for `nextDeadlineNs`; `sleep`, `fireExpired` | `src/core/timer_queue.zig` |
| Integration | Scheduler in idle fires expired timers | `fifo_scheduler.zig`, `work_stealing_scheduler.zig`, … |

#### 2.3.8. Synchronization (task-aware)

| Primitive | Behavior | Files |
|-----------|----------|--------|
| **SpinLock** | Short spin + OS yield | `src/core/synchronization.zig` |
| **ParkingLot** | Park/wake a waiter list | `synchronization.zig` |
| **Semaphore / Mutex** | Atomic/CAS uncontended; multi-worker short spin; else park. Mutex unlock **handoffs** to the waiter on the same worker via a non-stealable continuation (park returns to the worker loop, not the unlocker frame) | `synchronization.zig`, `work_stealing_scheduler.zig` |
| **RwLock** | Shared/exclusive; **atomic reader count**; park only when a writer is present or waiting; writer preference | `synchronization.zig` |
| **RateLimiter** | Token bucket; sleep + wake waiters | `synchronization.zig` |
| **Notify** | One/all wake of parked tasks | `synchronization.zig` |
| **Watch(T)** | Broadcast latest value + version | `synchronization.zig` |

**Invariant:** blocking **does not hold an OS worker in a useless wait** (except a short multi-worker spin). Single-worker runtimes never spin on mutex/sem (would starve the holder).

#### 2.3.9. I/O

| Entity | Role | Files |
|--------|------|--------|
| **Backend** (vtable) | `wait` / `poll` / `wakeup` / optional overlapped `async_read`/`async_write` | `src/io/io_backend.zig` |
| **PollReactor** | Linux epoll + eventfd · Windows `select` (256 fds) + UDP wakeup · POSIX poll + pipe; one poller, `wakeup` only while blocked | `src/io/poll_reactor.zig` |
| **IocpBackend** | Windows IOCP: `WSARecv`/`WSASend` completions (request on the heap), `PostQueuedCompletionStatus` wakeup, `CancelIoEx` + `cancelAll` | `src/io/iocp_backend.zig` |
| **IoUringBackend** | Linux io_uring completions (heap `UringReq` + CQE lifetime) + poll fallback; `ASYNC_CANCEL` on `cancelAll` | `src/io/io_uring_backend.zig` |
| **MockBackend** | Tests without a real network | `src/io/mock_backend.zig` |
| **TcpListener / TcpStream / UdpSocket** | Fiber-friendly sockets; TCP read/write use overlapped I/O when the backend `supports_async`; else park on readiness | `src/io/network.zig` |
| **Backend.cancelAll** | Drop readiness waiters and cancel pending overlapped ops with `Closed` | `src/io/io_backend.zig`, backends |
| **IoAdapter** | Bridge to `std.Io` (async/await-style I/O from a fiber) | `src/io/std_io_adapter.zig`, `async_future.zig` |
| Re-exports | | `src/io/io.zig` |

#### 2.3.10. Actors, metrics, preemption, tracing, ABI

| Entity | Role | Files |
|--------|------|--------|
| **Actor(Message)** | Mailbox channel + loop; optional link/on_stop | `src/actors/actor.zig` |
| **Metrics** | Atomic counters: spawns, yields, parks, steals, … | `src/core/metrics.zig` |
| **Preemption / checkpoint** | Cooperative quantum yield | `src/core/preemption.zig` |
| **Tracing / RingTracer** | Opt-in event emit | `src/core/tracing.zig` |
| **C bindings** | Foreign surface (`include/zigroutines.h`, static lib) | `src/abi/c_bindings.zig` |

#### 2.3.11. Utilities

| Structure | Role | Files |
|-----------|------|--------|
| Chase-Lev deque | Lock-free work-stealing queues | `src/utils/chase_lev.zig` |
| Intrusive list | Wait queues (channel, sync, join) | `src/utils/intrusive_list.zig` |
| Ring queue | FIFO ready queue | `src/utils/ring_queue.zig` |
| Priority queues | Priority scheduler | `src/utils/priority_queues.zig` |
| task_wake / worker_wake | Safe wake with on_cpu spin | `src/utils/task_wake.zig`, `worker_wake.zig` |
| windows_api | Windows helpers | `src/utils/windows_api.zig` |


---

## 3. Usage examples

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

### 3.1. Minimal spawn (snippet)

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

### 3.2. Channel

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

### 3.3. Work-stealing + result

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

### 3.4. Select with timeout

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

### 3.5. Nursery

```zig
var nursery = zr.Nursery.init(rt, .{
    .timeout_ns = 10 * std.time.ns_per_ms,
    .cancel_on_leave = true,
});
defer nursery.deinit();
_ = try nursery.spawn(.{}, child, .{nursery.token()});
_ = nursery.join() catch |err| { ... };
```

### 3.6. C ABI

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

---

## 4. Tests and coverage

```bash
zig build test
```

### 4.1. Suite map (`tests/suite.zig`)

| Layer | Files | Cases |
|-------|-------|--------|
| **Unit** | `stack_pool`, `channel_lifecycle`, `cancellation_token`, `metrics`, `preemption`, `stack_guard_and_canary`, `synchronization`, `rwlock_exclusive`, `timer_queue`, `actor_lifecycle` | alloc/free, `createPooled` recycle, policies construct, cancel flag, metrics on/off, checkpoint, canary/guard, mutex/sem/park, exclusive + concurrent shared RwLock, Notify `notifyAll`, RateLimiter multi-waiter, wheel `nextDeadline`, actor destroy/cancel |
| **C ABI** | `abi/c_abi.zig` + `c_abi_main.c` | version, empty run, spawn+yield, channel send/recv, try+sleep, null handles, would-block, recv-after-close; C executable linked against `zigroutines.lib` |
| **Integration** | `context_switch`, `fifo_scheduler`, `work_stealing_scheduler`, `channel_messaging`, `select_cancellation_scope`, `advanced_features`, `drop_newest_and_nursery` | swap/deep stack, spawn/yield, multi-worker, buffered/rendezvous/close/try/mpmc, select timeout/cancel/recvAny, multi-select, drop_*, nursery timeout/tryJoin/cancel_on_first_done, spawnResult error, priority, thread_per_task, actor, tracer, I/O backend create |
| **I/O** | `mock_and_poll_backend`, `std_io_adapter`, `tcp_echo` | reactor, mock park/wake, IoAdapter, **TCP/UDP echo** on poll and **IOCP**, `cancelAll` (poll + IOCP + io_uring); **io_uring TCP/UDP echo + cancelAll** (Linux) |
| **Stress** | `multi_worker_channels` | WS pipeline, spawnResult, priority order |

### 4.2. What we treat as “necessary” cases

Covered and important:

- Context switch (including deep stack)
- FIFO / WS / priority / thread_per_task
- Channel: buffered, rendezvous, close, try, mpmc, drop_oldest, drop_newest, error_full
- Select: timeout, value, recvAny, cancel, multi + default
- Hierarchical cancel, Scope join, Nursery timeout / tryJoin / cancel_on_first_done
- Sync: mutex, semaphore handoff, rwlock shared+exclusive (atomic readers), rate limiter
- Stack pool, opt-in canary cookie, guard arena reuse
- Metrics, preemption, tracing
- Actor lifecycle + cancel
- spawnResult / error union
- I/O mock, poll adapter; IOCP/io_uring backends
- **TCP echo loopback** on poll and **IOCP** (overlapped read/write); UDP loopback on both
- **io_uring** TCP/UDP echo + `cancelAll` (Linux; heap `UringReq` + CQE lifetime)
- `Backend.cancelAll` — poll waiters, IOCP `CancelIoEx`, io_uring `ASYNC_CANCEL`
- Poller `wakeup` so a blocked `select`/`epoll`/`GetQueuedCompletionStatusEx` sees new waiters
- Multi-arm select without double-enqueue (idempotent schedule)
- **C ABI** Zig tests + C-linked executable (`include/zigroutines.h`)
- Channel `createPooled` recycle; RateLimiter N waiters; Notify `notifyAll`


---

## 5. Benchmarks

| Peer | Product | Measured in harness |
|------|---------|---------------------|
| **Go** | goroutines + `chan` / `select` | full matrix including TCP/UDP |
| **Rust/Tokio** | multi-thread Tokio + `mpsc` / `select!` | full matrix including TCP/UDP |
| **C++** | OS threads + helping thread-pool + ring/`rendezvous` `Chan` (not fibers) | full matrix including TCP/UDP (Winsock, `TCP_NODELAY`) |
| **zigcoro** | single-thread stackful fibers + executor `Channel` | full name matrix; WS/priority/select/mutex/timer/I/O are stand-ins |
| **libxev** | event loop (not fibers) | full name matrix; fiber/channel/select/sync stand-ins; real timers + TCP/UDP |
| **zio** | Runtime + Channel + select + sync + net | full name matrix; priority = FIFO spawn; pooled create = stack init |


### 5.1. Languages (Go / Rust / C++)

**zigroutines column:** this tree, Windows x86_64, `zig build bench -Doptimize=ReleaseFast`.  
**Language columns:** same machine (Windows x86_64  12 CPUs), same workloads, `go run` / `cargo build --release` / `g++ -O3 -pthread`. Bold = fastest in-row among measured.  
C++ is an **OS-thread** baseline (helping pool + ring channel), not stackful fibers. Rust skynet/spawn/timers run on Tokio tasks, not `std::thread`.

#### Fiber / spawn

| Workload | **zigroutines** | **Go** | **Rust/Tokio** | **C++** |
|----------|----------------:|-------:|---------------:|--------:|
| `ctx_switch_bounce` | **4.2 ns** | 313 ns | 437 ns | 12.1k |
| `yield_pingpong` | **5.6 ns** | 103 ns | 272 ns | 28.5 ns |
| `yield_single` | **6.7 ns** | 150 ns | 18.4 ns | 71.5 ns |
| `yield_ws_4w` | **11.9 ns** | 137 ns | 162 ns | 33.3 ns |
| `leaf_spawn_batch` | **85.3 ns** | 489 ns | 559 ns | 9.2k |
| `spawn_join` | **127 ns** | 897 ns | 1130 ns | 58.5k |
| `spawn_result_join` | **141 ns** | 997 ns | 1186 ns | 75.8k |
| `nursery_join` | **154 ns** | 499 ns | 529 ns | 9.2k |
| `priority_dispatch` | **284 ns** | 399 ns | 516 ns | 59.6k |
| `skynet_join_10k` | 404 ns | 538 ns | **219 ns** | 10.2k |
| `n_tasks_1000` | 66.2 ns | 199 ns | **54.6 ns** | 127 ns |
| `n_tasks_10000` | 240 ns | 314 ns | **69.8 ns** | 370 ns |
| `n_tasks_50000` | 247 ns | 425 ns | **64.0 ns** | 155 ns |
| density / stack | **2 KiB** fixed (guard ≈ 4 KiB RSS) | growable | stackless | OS thr |

#### Channel / actor

| Workload | **zigroutines** | **Go** | **Rust** | **C++** |
|----------|----------------:|-------:|---------:|--------:|
| `chan_pipeline_buf256` | **19.9 ns** | 74.8 | 114 | 140 |
| `chan_rendezvous` | **56.9 ns** | 324 | 370 | 8.8k |
| `chan_mpmc_4x4` | 134 ns | 74.9 | **69.3** | 193 |
| `chan_try_uncontended` | **17.2 ns** | 52.8 | 18.0 | 24.9 |
| `chan_create_buf8` cold | **20.9 ns** | 229 | 168 | 58.1 |
| `chan_create_buf8_pooled` | **20.3 ns** | 229 | 168 | 58.1 |
| `chan_closed_drain` | 27.6 ns | 29.9 | **12.6** | 15.2 |
| `chan_prodcons_work` | **21.6 ns** | 319 | 31.6 | 350 |
| `chan_popular_256` | **57.3 ns** | 567 | 3972 | 8.8k |
| `chan_sem` | **13.7 ns** | 44.9 | 22.5 | 26.9 |
| `actor_mailbox` | **21.5 ns** | 79.7 | 39.7 | 138 |

#### Select

| Workload | **zigroutines** | **Go** | **Rust/Tokio** | **C++** |
|----------|----------------:|-------:|---------------:|--------:|
| `select_fanin_2` | **26.3 ns** | 179 | 155 | 192 |
| `select_uncontended` | **26.4 ns** | 99.7 | 98.8 | 30.1 |
| `select_nonblock` | 17.6 ns | 69.8 | **15.0** | 23.0 |
| `select_sync_contended` | **30.1 ns** | 300 | 122 | 193 |

#### Sync / timers

| Workload | **zigroutines** | **Go** | **Rust** | **C++** |
|----------|----------------:|-------:|---------:|--------:|
| `mutex_uncontended` | 13.0 ns | 14.9 | **9.2** | 11.8 |
| `mutex_contended_4` | **26.6 ns** | 29.9 | 61.8 | 27.9 |
| `sem_handoff` | **19.3 ns** | 59.8 | 55.4 | 107 |
| `rwlock_shared_4` | **36.3 ns** | 44.9 | 68.6 | 339 |
| `rwlock_exclusive` | 12.1 ns | 29.9 | **10.9** | 53.5 |
| `rate_limiter_try` | **38.8 ns** | n/a | n/a | n/a |
| `timer_sleep_batch` | **471 ns** | 997 | 3826 | 8.0k |
| `timer_many_100k_dispatch` | 761 ns | **409** | 835 | 8.7k |

#### I/O

| Workload | **zigroutines** | **Go** | **Rust** | **C++** |
|----------|----------------:|-------:|---------:|--------:|
| `tcp_pingpong` (poll) | **110k RT/s** | 55.0k | 38.3k | 67.6k |
| `tcp_pingpong` (IOCP) | **146k RT/s** | 55.0k | 38.3k | 67.6k |
| `tcp_pingpong` (io_uring) | **321k RT/s** (WSL2 5.15) | 55.0k | 38.3k | 67.6k |
| `udp_ping` (poll) | **376k pkt/s** | 148k | 336k | 250k |
| `udp_ping` (io_uring) | **1651k pkt/s** (WSL2 5.15) | 148k | 336k | 250k |

### 5.2. Zig libraries (zigcoro / libxev / zio)

Same machine and workloads as 5.1. Every name is printed even when the peer has no matching primitive — those cells are tagged stand-ins, not the same mechanism. Bold = fastest **real** implementation of that named workload (stand-ins are never bolded).

| Tag | Meaning |
|-----|---------|
| `(FIFO)` | no priority scheduler; timed as ordinary spawn |
| `(1T)` | single-thread round-robin, not work-stealing / MPMC |
| `(q)` | spinlock `ArrayList` queue, not a channel |
| `(stack)` | `Channel.init` on a stack buffer, not a heap allocate |
| `(loop)` | empty increment loop (libxev has no fibers) |
| `(async)` | libxev `Async.notify` as a yield/switch stand-in |
| `(spin)` | spin-loop, not a scheduler yield |
| `(ch)` | capacity-1 channel used as a mutex |
| `(load)` | plain load, no reader lock |
| `(spawn)` | spawn+resume, not a timer wheel |
| `(poll)` | `tryRecv` / `recv` fallback, not `select` |
| `(try)` | `tryRecv` only, no wait set |
| `(thr)` | OS threads + spinlock, not fiber mutexes |
| `(thread)` | blocking Winsock on an OS thread |



#### Fiber / spawn

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `ctx_switch_bounce` | **4.2 ns** | 14.8 ns | 144 ns (async) | 79.8 ns |
| `yield_pingpong` | **5.6 ns** | 31.8 ns | 136 ns (async) | 11.0 ns |
| `yield_single` | 6.7 ns | 32.9 ns | 275 ns (async) | **3.1 ns** |
| `yield_ws_4w` | 11.9 ns | 31.4 ns (1T) | 37.7 ns (spin) | **6.0 ns** |
| `leaf_spawn_batch` | **85.3 ns** | 96.5 ns | 0.7 ns (loop) | 178 ns |
| `spawn_join` | 127 ns | **78.4 ns** | 0.7 ns (loop) | 537 ns |
| `spawn_result_join` | 141 ns | **80.8 ns** | 0.7 ns (loop) | 220 ns |
| `nursery_join` | 154 ns | **78.5 ns** | 0.7 ns (loop) | 178 ns (Group) |
| `priority_dispatch` | **284 ns** | 69.6 ns (FIFO) | 0.7 ns (loop) | 180 ns (FIFO) |
| `skynet_join_10k` | 404 ns | **64.9 ns** | 0.7 ns (loop) | 456 ns |
| `n_tasks_1000` | 66.2 ns | **29.9 ns** | 36.6 ns (spin) | 40.7 ns |
| `n_tasks_10000` | 240 ns | 126 ns | 38.3 ns (spin) | **37.5 ns** |
| `n_tasks_50000` | 247 ns | 123 ns | 38.7 ns (spin) | **38.3 ns** |
| density / stack | **2 KiB** fixed (guard ≈ 4 KiB RSS) | 4 KiB default | n/a | growable |

#### Channel / actor

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `chan_pipeline_buf256` | 19.9 ns | **6.8 ns** | 21.6 ns (q) | 42.4 ns |
| `chan_rendezvous` | **56.9 ns** | 114 ns | 12.8 ns (q) | 94.1 ns |
| `chan_mpmc_4x4` | 134 ns | 7.2 ns (1T) | 12.8 ns (q) | **55.4 ns** |
| `chan_try_uncontended` | 17.2 ns | **3.2 ns** | 13.1 ns (q) | 34.3 ns |
| `chan_create_buf8` cold | 20.9 ns | **1.6 ns** (stack) | 1.2 ns (q) | 2.1 ns (stack) |
| `chan_create_buf8_pooled` | **20.3 ns** | 1.4 ns (stack) | 1.2 ns (q) | 1.9 ns (stack) |
| `chan_closed_drain` | 27.6 ns | **7.9 ns** | 6.9 ns (q) | 40.3 ns |
| `chan_prodcons_work` | 21.6 ns | **8.0 ns** | 13.7 ns (q) | 43.7 ns |
| `chan_popular_256` | **57.3 ns** | 185 ns | 12.8 ns (q) | 101 ns |
| `chan_sem` | **13.7 ns** | 120 ns | 14.0 ns (q) | 39.8 ns |
| `actor_mailbox` | 21.5 ns | **4.2 ns** | 13.0 ns (q) | 54.0 ns |

#### Select

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `select_fanin_2` | **26.3 ns** | 7.9 ns (poll) | 26.4 ns (q) | 85.4 ns |
| `select_uncontended` | **26.4 ns** | 4.0 ns (poll) | 12.8 ns (q) | 62.1 ns |
| `select_nonblock` | 17.6 ns | **3.0 ns** (try) | 6.6 ns (q) | 33.1 ns |
| `select_sync_contended` | **30.1 ns** | 8.2 ns (poll) | 12.8 ns (q) | 81.2 ns |

#### Sync / timers

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `mutex_uncontended` | **13.0 ns** | 4.1 ns (ch) | 6.8 ns (spin) | 15.8 ns |
| `mutex_contended_4` | 26.6 ns | 5.7 ns (ch) | 48.4 ns (thr) | **24.4 ns** |
| `sem_handoff` | **19.3 ns** | 122 ns (ch) | 97.9 ns (spin) | 47.6 ns |
| `rwlock_shared_4` | **36.3 ns** | 0.5 ns (load) | 59.9 ns (spin) | 38.0 ns |
| `rwlock_exclusive` | **12.1 ns** | 4.2 ns (ch) | 6.5 ns (spin) | 24.2 ns |
| `rate_limiter_try` | **38.8 ns** | n/a | n/a | n/a |
| `timer_sleep_batch` | **471 ns** | 104 ns (spawn) | 8.7k | 1021 ns |
| `timer_many_100k_dispatch` | 761 ns | 100 ns (spawn) | 1034 ns | **432 ns** |

#### I/O

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `tcp_pingpong` (poll) | **110k RT/s** | 66.4k (thread) | 48.9k | 94.2k |
| `tcp_pingpong` (IOCP) | **146k RT/s** | 66.4k (thread) | 48.9k | 94.2k |
| `tcp_pingpong` (io_uring) | **321k RT/s** (WSL2 5.15) | 66.4k (thread) | 48.9k | 94.2k |
| `udp_ping` (poll) | **376k pkt/s** | 259k (thread) | 178k | 167k |
| `udp_ping` (io_uring) | **1651k pkt/s** (WSL2 5.15) | 259k (thread) | 178k | 167k |

### 5.3. Why you cannot compare these libraries as if they were the same product


#### They are different machines

| | **libxev** | **zigcoro** | **zio** | **zigroutines** |
|--|------------|-------------|---------|-----------------|
| Job | Event loop (proactor / completions) | Thin stackful coroutines + a single-thread executor | Async **runtime** (Tokio/Go spirit): coroutines + I/O + `std.Io` | Explicit **concurrency stack**: you construct a `Runtime` |
| Unit of work | Completion callback | `xasync` / `xresume` / `xsuspend` | Stackful task on an executor | Stackful task (`spawn`) + opt-in stackless `spawnLeaf` |
| Stack | None (callbacks) | You pass a buffer (default 4 KiB) | **Growable** — VM reservation that extends | **Fixed 2 KiB only** — pool, optional canary/guard |
| Schedule | No task scheduler | One thread, cooperative | M:N, work-steal **or** pin; wake is I/O-coupled | FIFO / work-steal / **priority** / 1:1 — same `spawn` |
| CSP | None | Executor `Channel` (one thread) | Channel + wait-protocol “select” | First-class `Channel` + 32-arm `select`, backpressure, cancel |
| I/O | The product | Optional, via libxev | **Baked into** the runtime | **Plugin** — `none` until you set poll / IOCP / io_uring |
| Cancel / nursery | You build it | Limited | Task groups + cancel | Hierarchical `CancelToken`, `Scope` / `Nursery` |
| Quiet by default | You wire a loop | Executor is the program | Runtime **is** the netpoller | Core stays quiet; no poller until configured |
| Function color | Callbacks | No | Native API or `std.Io` | No — `send` / `recv` / `sleep` look like ordinary calls |

**libxev** is not a concurrency library. It is a cross-platform completion loop (the Zig-shaped cousin of libuv / io_uring). Ghostty uses it that way. There is no task, no stack, no channel, no `select`. A “spawn” number against libxev is either an empty loop or “arm a completion.” A channel number is a mutex queue we invented so the name would print. Use libxev when you **want** a loop. Do not use a fiber table to decide between a loop and a runtime.

**zigcoro** is a coroutine primitive: swap a stack, maybe run an `Executor`, maybe put a `Channel` on it. That is a useful brick. It is not a product you write a service in. There is no work-stealing, no priority, no multi-arm `select`, no timer wheel, no mutex that parks a fiber, no I/O reactor of its own, no structured cancel. Stacks are your problem. When zigcoro “wins” `ctx_switch`, `spawn_join`, `skynet`, or `chan_pipeline`, it wins because the path is **one thread, no steal, no TCB policy, no cancel metadata, no MPMC atomics**. That is a thinner machine. It is also why those wins do not transfer to a multi-core server.

**zio** is the only peer in the same *category*: a real runtime. Coroutines, executors, channels, select-like waits, sync, network, structured groups. It is also a different **design bet**. Stacks **grow** by extending a VM reservation (convenient, Go-like, RSS is not a number you picked). I/O is not a plugin — the runtime *is* an async I/O framework that happens to schedule coroutines, and the blessed path is `std.Io`. There is no priority scheduler. There is no “leave the netpoller off.” You take the runtime as a whole. That is a coherent choice. It is not the zigroutines choice.

**zigroutines** starts from the opposite end. The thing you construct is a `Runtime`, not a loop. The thing you spawn is a task with a **fixed** stack. I/O is a backend you enable. The scheduler is a **policy** on the same API. Channels and `select` are the API, not an add-on. Cancel is hierarchical. Density is a number (2 KiB, pool, optional guard arena) instead of “it will grow.” The cost of that bet is visible in 5.2: we pay atomics, a TCB, a steal-safe queue, a join handle, and a 2 KiB stack on paths where zigcoro only swaps and zio only yields.

#### What a “loss” actually paid for

These are the rows a skimming reader will use against us. Each one is a constraint we refused to drop.

- **`yield_single` / `yield_ws_4w` — zio 3.1 / 6.0 ns vs 6.7 / 11.9.** zio’s yield is a thinner “give up this executor.” Ours goes through the **same** scheduler that has to be correct under work-stealing, priority, cancel, and “parked on a channel.” You do not get a special fast yield that stops working when you turn workers on.
- **`skynet_join_10k` / `spawn_join` — zigcoro 65 / 78 ns vs 404 / 127.** zigcoro is creating frames on one thread and awaiting them. We create a task that a **worker** can steal, with a pooled 2 KiB stack, a join handle, and (for skynet) `spawnLeaf` only on the nodes that never park. The extra nanoseconds are the M:N tax. Tokio beats us on skynet and `n_tasks_*` for the same reason it beats everyone stackful: a Tokio task is a **state machine**, not 2 KiB of stack. That model colors every function `async`. We will not take that deal on Zig.
- **`chan_pipeline` — zigcoro 6.8 ns vs 19.9.** Their `Channel` is a single-thread ring on the executor. Ours is safe for four producers and four consumers, has rendezvous, close, `select`, and four full policies. The 13 ns is the price of “this channel still works when you add a worker.”
- **`timer_many_100k` — zio 432 ns vs 761.** They have a tighter timer path. Ours is a 256×1 ms wheel plus heap overflow plus a sub-tick yield so `sleep(50 ns)` is not quantized to 1 ms. We lose the “arm 100k and fire” cell; we keep one sleep API that is honest at both 50 ns and 50 ms.


#### Why this is still the library to take on Zig

You are not choosing a nanosecond. You are choosing **what you will write for the next two years**.

1. **One surface, not a kit.** libxev does not give you tasks. zigcoro does not give you a scheduler, I/O, or cancel. zio gives you a runtime you cannot turn the poller off of, and stacks that grow. With zigroutines you `Runtime.init`, `spawn`, `Channel.create`, `select`, and — if you need it — set `.io = .iocp`. The same program can be compute-only on Monday and IOCP on Tuesday without a rewrite.

2. **The model matches how you already want to write Zig.** `send` / `recv` / `sleep` / `accept` look like ordinary calls. The task parks; another task runs. No `async` infection, no `Pin`/`Send` puzzle, no callback inversion. That is the whole point of stackful. zigcoro has the swap and stops there. zio has the swap and then ties you to its I/O. We have the swap **and** the product around it.

3. **Resources stay a number you picked.** Fixed 2 KiB, pool on, guard optional and shared. Ten thousand tasks are ~40 MiB of stacks, not “however far the growable mapping went after the JSON parser recursed.” zio’s growable stacks are a genuine convenience. They are also how you get a surprise RSS bill. We made the inconvenient choice on purpose.

4. **The scheduler is a policy, not a fork.** FIFO on one worker, work-stealing on N, priority when a timer must cut the line, thread-per-task when you must. Same `spawn`. zigcoro is one thread. zio is steal-or-pin. libxev is not a scheduler. If your program’s shape changes, you change a field, not a library.

5. **I/O is a backend, not the religion.** A lot of concurrent Zig is *not* a network server. Embedding a netpoller in the core so that `yield` is fast is how you get a library that is wrong for half its users. We lose a yield cell to zio and keep “no poller” as the default. When you do want I/O, poll / IOCP / io_uring are the same TCP helpers, and on this machine that path is the fastest one in the table (110k / 146k / 321k RT/s).

6. **A loss in 5.2 is usually a feature you will need by week two.** Multi-worker safety. `select` with timeout and cancel. A nursery that tears the children down. A channel that still has backpressure when the consumer is slow. A stack that cannot silently become 64 KiB. The library that “won” that row typically does not have that feature. Shipping the thinner machine means you will re-implement the missing piece — and then you no longer have the nanosecond you bought.

zio is a serious runtime and the only fair *category* peer. If you want growable stacks and `std.Io` as the center of the universe, take zio. If you want a completion loop, take libxev. If you want a coroutine brick to build your own runtime, take zigcoro.

If you want **to write concurrent Zig** — tasks that look synchronous, channels you can `select` on, cancel that actually unwinds a tree, I/O you can leave off, and a memory bill you can explain — take zigroutines. The benches where we are not first are the benches where the winner was allowed to be a smaller library.


## 6. Runtime configuration (cheat sheet)

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

---

## 7. Changelog

### 1.0.0 (2026-08-15)

#### Runtime / fibers

- **TCB vs frames.** Was: the task control block lived where a growing frame could overwrite it (Windows `chkstk` / deep spawn made this worse). Problem: silent corruption and Debug-mode crashes on a 2 KiB stack. Now: 512 B TCB sits in a suffix *above* the 2 KiB usable stack; frames grow down and cannot smash control state.
- **Spawn on a 2 KiB stack.** Was: `spawn` / `spawnResult` ran on the caller fiber. Problem: the spawn path itself does not fit in 2 KiB, so nested spawn (skynet, nursery) overflowed or had to bounce ad-hoc. Now: spawn always hops onto the worker stack and resumes the child immediately only if the ready queue is empty.
- **Mutex unlock under work-stealing.** Was: unlock woke the waiter onto a stealable ready queue. Problem: another worker could steal the continuation and the unlocking fiber resumed with the mutex conceptually still “in flight”. Now: unlock installs a non-stealable `handoff_cont`; park returns to the worker loop and the waiter runs next on that worker.
- **Linux context switch.** Was: `swapLinux` used the `to` pointer from a general-purpose register while also restoring `r12`–`r15`. Problem: if LLVM put `to` in one of those regs, restore clobbered the pointer → SEGV on the first fiber bench. Now: `to` is copied to `r11` first, same pattern as the Windows path.
- **Stack-pool cap.** Was: default `max_per_class = 1024`. Problem: a 100k-fiber wave (`timer_many`, skynet) freed ~99k stacks back to the OS on join, dominating dispatch time. Now: default cache is 131072 slots; the wave returns to the pool instead of `HeapFree`.

#### Timers

- **Finding the next deadline.** Was: SmoothTeam scanned wheel slots linearly. Problem: idle `nextDeadlineNs` paid O(256) even when almost nothing was armed. Now: occupied bitmap `[4]u64` + `@ctz` jumps to the next live slot.
- **Sub-tick sleep.** Was: `sleep(500 ns)` parked on the 1 ms wheel (and Windows `Sleep` rounds up to 1 ms). Problem: `timer_many_100k_dispatch` and `timer_sleep_batch` measured a millisecond wait, not a nanosecond sleep — 1197 ns/op and 798 ns/op. Now: `duration < 1 ms` yields until the deadline and never enters the wheel. Dispatch **1197 → 761 ns**, batch **798 → 471 ns**.

#### Channels / sync

- **Hot-path channel.** Was: mutex around the whole ring (or a coarse lock) for every send/recv. Problem: uncontended pipeline and rendezvous paid a lock even with no waiters. Now: Vyukov MPMC seq-slot ring; the lock is only for the waiter lists. Optional `spsc` / `mpsc` skip the extra atomics.
- **Cold `Channel.create`.** Was: two heap allocations (header + slots) and `destroy` always ran `close()`. Problem: `chan_create_buf8` was **10.1k ns** (plus DebugAllocator in the harness made it look even worse). Now: one `alignedAlloc` for header+slots; unused destroy skips close. Harness uses `smp_allocator`. Cold create **10.1k → 20.9 ns**, pooled **28.7 → 20.3 ns**.
- **Channel recycle.** Was: every create hit the heap; SmoothTeam had no pool. Problem: tests that used a leak-checking allocator could not recycle, so production code had no safe hot-create API. Now: `createPooled` / `recycle=true` is opt-in; default `create` stays leak-free under test allocators.
- **RwLock readers.** Was: shared acquires took the big lock even with no writer. Problem: `rwlock_shared_4` serialized readers. Now: atomic reader count; park only if a writer is present or waiting.
- **Rate limiter.** Was: no token-bucket primitive. Problem: callers built their own sleep loops and missed wake-on-refill. Now: `RateLimiter` parks waiters and wakes them as tokens refill (`rate_limiter_try` bench).

#### I/O

- **Poller.** Was: SmoothTeam created/destroyed poll and had a poll-only TCP echo; a blocked `select`/`epoll` did not see waiters registered after it went to sleep. Problem: hang on “add waiter while poller is in the kernel”. Now: Windows `select` (256 fds) + UDP wakeup, Linux epoll + eventfd, POSIX poll + pipe; `wakeup` only while the poller is blocked.
- **IOCP.** Was: backend existed as “create/destroy + `supports_async`”, no overlapped echo. Problem: Windows I/O still went through readiness `select`, leaving 110k RT/s on the table and no `CancelIoEx` path. Now: heap `IoRequest` + freelist, `WSARecv`/`WSASend`, `PostQueuedCompletionStatus`, `CancelIoEx`. UDP stays readiness-based (not IOCP-associated). Echo + `cancelAll` are tested. IOCP pingpong **146k RT/s**.
- **io_uring.** Was: placeholder “Linux / WSL2” in the tables; SmoothTeam never shipped an e2e number. Problem: no CQE-lifetime rules, cancel could use-after-free, and Zig 0.17 deleted `std.posix.socket`/`close`/`nanosleep`/`mprotect` so Linux did not even build. Now: heap `UringReq` + freelist, CQE harvest never blocks under the lock, `ASYNC_CANCEL` on `cancelAll`, Linux syscalls via `std.os.linux`. Measured on WSL2 5.15 (`CONFIG_IO_URING=y`): TCP **321k RT/s**, UDP **1651k pkt/s**.
- **TCP helpers.** Was: bind/connect/accept/`read`/`write` ran on the fiber stack and used blocking sockets unless the backend said otherwise. Problem: Windows stack probes + sync `connect` blew the 2 KiB stack. Now: bind/connect/accept bounce to the worker; `read`/`write` use overlapped/async ops when `supports_async`.

#### C ABI

- **Foreign surface.** Was: none on SmoothTeam. Problem: C/C++ (and anything that cannot import a Zig module) had no way to construct a runtime or a channel. Now: `include/zigroutines.h` + static lib from `zig build` (Windows also needs `ws2_32` + `ntdll`). Covered by `tests/abi/c_abi.zig` and `zig build c-abi-test`.

#### Tests / benches

- **Windows Debug tests.** Was: `zig build test` in Debug was treated as the gate. Problem: 2 KiB + MSVC `chkstk` is unsafe; the suite red-herringed real bugs. Now: authoritative gate is `zig build test -Doptimize=ReleaseSafe`.
- **Harness allocator.** Was: `DebugAllocator` (even with `safety=false`). Problem: ~10 µs per malloc, so `chan_create` / `skynet` measured the allocator, not the library. Now: `std.heap.smp_allocator`.
- **`skynet_join_10k`.** Was: 11k stackful `spawnResult`s on one FIFO worker — **22.8k ns**/spawn (SmoothTeam published 14k). Problem: 10k leaves never park but still paid a 2 KiB stack and a bounce; one core vs Go’s `GOMAXPROCS`. Now: size-1 nodes are `spawnLeaf`, internals run on work-stealing across CPUs. **22.8k → 404 ns** (ahead of Go 538 ns).
- **Coverage.** Was: poll echo only; no RateLimiter/Notify/`createPooled` unit tests. Now: TCP/UDP echo + `cancelAll` on poll and IOCP (Windows) and io_uring (Linux/WSL2); unit tests for pooled recycle, RateLimiter N waiters, `Notify.notifyAll`, timer-wheel bitmap.
- **Tables.** Was: Go, Rust, C++, zigcoro, libxev, zio in one grid. Problem: a language runtime and an event loop were compared as if they were the same kind of peer. Now: 5.1 languages, 5.2 Zig libraries.
- **C++ / Rust harness.** Was: C++ `mutex`+`queue`+`notify_all`, capacity 0 coerced to 1, skynet as 10k OS threads; Rust skynet as `std::thread`. Problem: the numbers measured the worst possible implementation, not a serious peer, and reviewers called the benches unsafe/slow. Now: C++ helping pool + ring/`rendezvous` `Chan` + `TCP_NODELAY` + UDP recv timeout; Rust skynet is `tokio::spawn` (`Send` future). Re-measured in 5.1 (Rust skynet **45.5k → 219 ns**, C++ TCP **54.9k → 67.6k** RT/s).
- **Peer name matrix.** Was: zigcoro/libxev/zio only printed the primitives they own; most rows were `n/a`. Problem: a missing cell looks like “we hid a loss,” and you cannot scan one name across every peer. Now: every workload name is printed. Stand-ins are tagged (`(q)`, `(FIFO)`, `(thread)`, …) and never bolded. zio covers the full runtime surface; zigcoro I/O is blocking Winsock; libxev fiber/channel/sync names are queues and loops.

#### Benches sped up


| Workload | Before | After | What was wrong | What we did |
|----------|-------:|------:|----------------|-------------|
| `skynet_join_10k` | 22.8k ns | **404 ns** | 10k stackful leaves + 1 worker | `spawnLeaf` + work-stealing |
| `chan_create_buf8` cold | 10.1k ns | **20.9 ns** | 2 mallocs + `close()` + DebugAllocator | single alloc, skip unused close, `smp_allocator` |
| `chan_create_buf8_pooled` | 28.7 ns | **20.3 ns** | extra reset/`close` on recycle | cheaper unused destroy |
| `timer_many_100k_dispatch` | 1197 ns | **761 ns** | 1–1000 ns sleep sat on a 1 ms wheel; 99k stacks hit `HeapFree` | sub-tick yield; pool cap 131072 |
| `timer_sleep_batch` | 798 ns | **471 ns** | same 1 ms quantization (`sleep(50)` was 50 ns) | sub-tick yield |
| `priority_dispatch` | 539 ns | **284 ns** | spawn/heap path paid DebugAllocator + small pool | `smp_allocator` + larger stack cache |
| `select_fanin_2` | 55.4 ns | **26.3 ns** | lock + DebugAllocator noise on the wait path | MPMC ring; harness allocator |
| `select_sync_contended` | 68.5 ns | **30.1 ns** | same | same |
| `tcp_pingpong` (io_uring) | n/a | **321k RT/s** | Linux did not build; no e2e | 0.17 syscalls + WSL2 5.15 |
| `udp_ping` (io_uring) | n/a | **1651k pkt/s** | same | same |
