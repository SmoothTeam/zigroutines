# zigroutines

 **x86_64 / aarch64** · Windows, Linux, macOS, FreeBSD

Supported toolchains: **Zig 0.16** and **Zig 0.17-dev**

```bash
zig build test
zig build bench
zig build run
zig build examples
zig build example -Dexample=01_minimal_spawn
```

---

## 1. What is zigroutines?

### 1.1. In short

**zigroutines** is a library for **explicit stackful concurrency** in Zig. It gives you a Go-shaped model (tasks, channels, `select`, cancellation, timers) with Zig’s philosophy: **nothing global, nothing hidden, pay only for what you enable**.

Unlike a “runtime baked into the language,” **you construct** a `Runtime`, choose the scheduler policy, stack size, I/O backend, and metrics. No GC. No automatic stack growth. No netpoller until you plug one in.

At a glance:

| Property | Value |
|----------|--------|
| Model | M:N **stackful** tasks (fibers) on **fixed-size** stacks |
| Schedulers | FIFO · work-stealing · priority · 1 OS thread per task |
| CSP | `Channel(T)`, rendezvous / buffered, multi-arm `select` (up to 32 arms per kind) |
| Cancellation | Cooperative, hierarchical `CancelToken`, `Scope` / `Nursery` |
| I/O | Plugin: `none` / `poll` / `iocp` / `io_uring` |
| Synchronization | Mutex, Semaphore, RwLock, RateLimiter — park the **task**, not the OS thread |
| Cost | Pay-for-what-you-use; hot paths avoid extra heap traffic |

### 1.2. What it gives Zig developers

1. **Write top-down “sync-looking” code** — `send` / `recv` / `sleep` / `yield` look like ordinary calls; under the hood the task parks and yields the CPU to other fibers. No function coloring (`async`/`await` does not infect the call tree).

2. **Predictable resources** — fixed-size stacks (default 64 KiB). RSS ≈ size × live tasks. Optional pool, guard page, and canary for diagnostics.

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
| Primary job | Event loop / completions | Coroutines + some I/O | **Full concurrency product** |
| Stackful sync style | No (callback / future) | Yes | **Yes** |
| Channels + multi-select | No | Partial / ad-hoc | **First-class CSP** |
| Pluggable scheduler policies | N/A | Limited | **FIFO / WS / priority / 1:1** |
| Fixed stack + pool + guard | N/A | Varies | **Explicit and default** |
| Structured cancel / nursery | No | Limited | **Scope + Nursery** |
| Quiet netpoller by default | You wire it | Often coupled to the runtime | **Off until you configure it** |

**Takeaway:** use **libxev** for a pure completion loop. Use **zigcoro/zio** if you only need fibers. Use **zigroutines** when you want Go-shaped coordination (channels, select, cancel) **and** Zig-shaped control (explicit Runtime, fixed stacks, pluggable I/O/scheduler) in one package.

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

### 1.4. Why choose this

1. **Policy-complete** — scheduler, I/O, cancel, CSP, stacks, metrics: one coherent surface.
2. **Honest to Zig** — no process-global runtime, no GC, no silent growth; pay only for enabled features.
3. **Go-shaped DX** — write top-down; park on channels/timers/I/O without rewriting the call tree.
4. **Measurable cost** — fixed stacks, optional metrics/canary, explicit park/wake rules.

**Not** the best choice for “absolute max pps on one echo path” (a specialized loop may win) or full BEAM/OTP-style supervision. **Best** choice for **one** concurrency stack on Zig that does not betray the language.

### 1.5. How to depend on it in your project

#### Via `build.zig.zon` (recommended)

```zig
.{
    .name = .my_app,
    .version = "0.0.1",
    .dependencies = .{
        .zigroutines = .{
            .url = "https://github.com/.../...tar.gz",
        },
    },
    .paths = .{""},
}
```

```zig
const zr_dep = b.dependency("zigroutines", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigroutines", zr_dep.module("zigroutines"));
```

Locally (path):

```bash
zig fetch --save=zigroutines ./path/to/zigroutines
```

#### Import in code

```zig
const zr = @import("zigroutines");

var rt = try zr.Runtime.init(allocator, .{ .workers = 1 });
defer rt.deinit();
_ = try rt.spawn(.{}, myFn, .{});
try rt.run();
```

#### Requirements

- Zig **0.16** or **0.17-dev** (see also `minimum_zig_version` in `build.zig.zon` for the CI/dev pin)
- Architectures with context-switch support: **x86_64**, **aarch64**
- OS: Windows, Linux, macOS, FreeBSD

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
  │  Runtime  (you construct it — not process-global)        │
  │  scheduler · timers · metrics · cancel · I/O backend     │
  └──────────────┬───────────────────────────┬───────────────┘
                 │                           │
        ┌────────┴────────┐         ┌────────┴────────┐
        ▼                 ▼         ▼                 ▼
   FIFO / work-steal   fixed     poll / IOCP /     std.Io
   priority / 1:1      stacks    io_uring          adapter
                       + pool
```

**Defaults (pay nothing extra):** 1 worker · FIFO · 64 KiB fixed stack · I/O off · metrics off · preemption off.

### 2.2. Layers and control flow

1. **Application layer** — your functions invoked via `Runtime.spawn` / `spawnResult` / `Nursery.spawn` / `Actor`.
2. **CSP / sync** — `Channel`, `select`, Mutex/Semaphore/…: on block, call `parkFromRunning` on the current executor.
3. **Task** — unit of execution: id, state, fixed stack, context (registers), join-waiters, optional result slot.
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

**Rules:** `yield` / `channel` / `sync` are allowed **only inside a task**. Outside a task — panic with a clear message. `sleep` requires a TLS runtime (set by `run`).

#### 2.3.2. Schedulers (policies)

| Policy | Behavior | Files |
|--------|----------|--------|
| **auto** | 1 worker → FIFO; ≥2 → work-stealing | `runtime.zig` |
| **single_thread_fifo** | One queue, one thread, strict FIFO | `src/scheduler/fifo_scheduler.zig` |
| **work_stealing** | N workers, local deques, steal | `src/scheduler/work_stealing_scheduler.zig` + `utils/chase_lev.zig` |
| **priority** | 1 worker, min-heap / priority queue by `SpawnOptions.priority` (0 = highest) | `src/scheduler/priority_scheduler.zig` + `utils/priority_queues.zig` |
| **thread_per_task** | 1 OS thread per task (1:1), for comparison / blocking FFI | `src/scheduler/thread_per_task_scheduler.zig` |
| Shared facade | | `src/scheduler/scheduler.zig` |

**Work-stealing algorithm:** each worker has a Chase-Lev deque; when the local queue is empty it steals from others. Metric `steals` (if metrics on).

#### 2.3.3. Stacks

| Mechanism | Role | Files |
|-----------|------|--------|
| **Stack** | Fixed buffer; usable region | `src/stack/stack.zig` |
| **Pool** | Size-class reuse across tasks | `stack.zig` |
| **guard_page** | PROT_NONE / PAGE_NOACCESS under the stack → fault on overflow | `stack.zig` |
| **paint_canary** | Pattern fill; `highWaterUsed()` | `stack.zig` |

**Rule:** the stack **does not grow**. Overflow is either a guard-page fault or silent memory corruption without a guard. Size is set via `Config.default_stack_size` / `SpawnOptions.stack_size`.

#### 2.3.4. Context switch

| Entity | Role | Files |
|--------|------|--------|
| **Context** | Saved registers + entry trampoline | `src/context/context.zig` |
| **x86_64 / aarch64 asm** | `make` / `swap` | `src/context/arch/x86_64_assembly.zig`, `aarch64_assembly.zig` |
| **supported** | comptime flag for the target platform | `context.zig` |

#### 2.3.5. CSP: channels and select

| Entity | Role | Files |
|--------|------|--------|
| **Channel(T)** | Buffered or rendezvous (capacity 0); MPMC | `src/csp/channel.zig` |
| **FullPolicy** | `block` · `drop_newest` · `drop_oldest` · `error_full` | `channel.zig` |
| **send / recv / try\*** | Blocking and non-blocking ops | `channel.zig` |
| **select.multi / recv / recvAny** | Up to 32 recv + 32 send arms; timeout; cancel; default | `src/csp/select.zig` |
| **Fairness** | `random` (default) / `fifo` when several arms are ready | `select.zig` |

**Scenarios:** pipeline, fan-in/fan-out, rendezvous handoff, backpressure telemetry (`drop_*`), non-blocking poll (`try` / `default` arm).

#### 2.3.6. Cancellation and structured concurrency

| Entity | Role | Files |
|--------|------|--------|
| **CancelToken** | Atomic flag, parent→children link, waiters | `src/core/cancellation.zig` |
| **Scope** | Group of children + token; `joinAll`; optional cancel-on-leave | `src/core/structured_concurrency.zig` |
| **Nursery** | Scope + deadline/timeout + `cancel_on_first_done` + `tryJoin` | `structured_concurrency.zig` |

**Cooperative rule:** cancel **does not interrupt** machine code. Children must **poll** the token (or wait on select/channel with cancel). A deliberate “explicit over implicit” choice.

#### 2.3.7. Timers

| Entity | Role | Files |
|--------|------|--------|
| **TimerQueue** | Min-heap by deadline; `sleep`, `fireExpired` | `src/core/timer_queue.zig` |
| Integration | Scheduler in idle fires expired timers | `fifo_scheduler.zig`, `work_stealing_scheduler.zig`, … |

#### 2.3.8. Synchronization (task-aware)

| Primitive | Behavior | Files |
|-----------|----------|--------|
| **SpinLock** | Short spin + OS yield | `src/core/synchronization.zig` |
| **ParkingLot** | Park/wake a waiter list | `synchronization.zig` |
| **Semaphore / Mutex** | Counter / binary; park fiber | `synchronization.zig` |
| **RwLock** | Shared/exclusive; writer preference | `synchronization.zig` |
| **RateLimiter** | Token bucket; sleep + wake waiters | `synchronization.zig` |

**Invariant:** blocking **does not hold an OS worker in a useless wait** (except spin on very short critical sections). The waiter is removed from the ready queue.

#### 2.3.9. I/O

| Entity | Role | Files |
|--------|------|--------|
| **Backend** (vtable) | poll / register / readiness | `src/io/io_backend.zig` |
| **PollReactor** | Linux epoll · Windows `select` · POSIX poll; `cancelAll` | `src/io/poll_reactor.zig` |
| **IocpBackend** | Windows IOCP | `src/io/iocp_backend.zig` |
| **IoUringBackend** | Linux io_uring | `src/io/io_uring_backend.zig` |
| **MockBackend** | Tests without a real network | `src/io/mock_backend.zig` |
| **TcpListener / TcpStream / UdpSocket** | Fiber-friendly sockets; park on readiness | `src/io/network.zig` |
| **Backend.cancelAll** | Drop all I/O waiters with `Closed` (hang safety) | `src/io/io_backend.zig`, backends |
| **IoAdapter** | Bridge to `std.Io` (async/await-style I/O from a fiber) | `src/io/std_io_adapter.zig`, `async_future.zig` |
| Re-exports | | `src/io/io.zig` |

#### 2.3.10. Actors, metrics, preemption, tracing, ABI

| Entity | Role | Files |
|--------|------|--------|
| **Actor(Message)** | Mailbox channel + loop; optional link/on_stop | `src/actors/actor.zig` |
| **Metrics** | Atomic counters: spawns, yields, parks, steals, … | `src/core/metrics.zig` |
| **Preemption / checkpoint** | Cooperative quantum yield | `src/core/preemption.zig` |
| **Tracing / RingTracer** | Opt-in event emit | `src/core/tracing.zig` |
| **C bindings** | Foreign surface | `src/abi/c_bindings.zig` |

#### 2.3.11. Utilities

| Structure | Role | Files |
|-----------|------|--------|
| Chase-Lev deque | Work-stealing queues | `src/utils/chase_lev.zig` |
| Intrusive list | Wait queues (channel, sync, join) | `src/utils/intrusive_list.zig` |
| Ring queue | FIFO ready queue | `src/utils/ring_queue.zig` |
| Priority queues | Priority scheduler | `src/utils/priority_queues.zig` |
| task_wake / worker_wake | Safe wake with on_cpu spin | `src/utils/task_wake.zig`, `worker_wake.zig` |
| windows_api | Windows helpers | `src/utils/windows_api.zig` |


### 2.5. Invariants (brief)

1. Park/wake: waiter is marked `parked` **under the lock** before `parkFromRunning`; the waker waits for `!on_cpu` and only then `enqueue`.
2. Channel close: all send/recv waiters get `Closed` and are woken.
3. Destroy channel: assert empty wait queues (no dangling parked waiters).
4. Runtime deinit: drain pool, destroy I/O, collect unjoined dead tasks.
5. Cancellation: hierarchical, but **cooperative**.

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

---

## 4. Tests and coverage

```bash
zig build test
```

### 4.1. Suite map (`tests/suite.zig`)

| Layer | Files | Cases |
|-------|-------|--------|
| **Unit** | `stack_pool`, `channel_lifecycle`, `cancellation_token`, `metrics`, `preemption`, `stack_guard_and_canary`, `synchronization`, `rwlock_exclusive`, `actor_lifecycle` | alloc/free, policies construct, cancel flag, metrics on/off, checkpoint, canary/guard, mutex/sem/park, exclusive RwLock, actor destroy/cancel |
| **Integration** | `context_switch`, `fifo_scheduler`, `work_stealing_scheduler`, `channel_messaging`, `select_cancellation_scope`, `advanced_features`, `drop_newest_and_nursery` | swap/deep stack, spawn/yield, multi-worker, buffered/rendezvous/close/try/mpmc, select timeout/cancel/recvAny, multi-select, drop_*, nursery timeout/tryJoin/cancel_on_first_done, spawnResult error, priority, thread_per_task, actor, tracer, I/O backend create |
| **I/O** | `mock_and_poll_backend`, `std_io_adapter`, `tcp_echo` | reactor, mock park/wake, IoAdapter, **TCP echo loopback**, UDP loopback, `cancelAll` watchdog |
| **Stress** | `multi_worker_channels` | WS pipeline, spawnResult, priority order |

### 4.2. What we treat as “necessary” cases

Covered and important:

- Context switch (including deep stack)
- FIFO / WS / priority / thread_per_task
- Channel: buffered, rendezvous, close, try, mpmc, drop_oldest, drop_newest, error_full
- Select: timeout, value, recvAny, cancel, multi + default
- Hierarchical cancel, Scope join, Nursery timeout / tryJoin / cancel_on_first_done
- Sync: mutex, semaphore handoff, rwlock shared+exclusive, rate limiter
- Stack pool, guard, canary
- Metrics, preemption, tracing
- Actor lifecycle + cancel
- spawnResult / error union
- I/O mock, poll adapter; create IOCP/io_uring backends
- **TCP echo loopback** (poll backend, select-based readiness on Windows) + UDP loopback
- `Backend.cancelAll` — safe abort of stuck I/O waiters (tests / shutdown)
- Multi-arm select without double-enqueue (idempotent schedule)

Intentionally weaker (future hardening):

- Exhaustive multi-thread races on every primitive (mpmc + stress exist, not model checking)
- Full e2e echo over **IOCP / io_uring** (create/destroy + `supports_async` covered; round-trip on poll)
- C ABI integration tests
- RateLimiter multi-waiter fairness under load

---

## 5. Benchmarks

```bash
zig build bench -Doptimize=ReleaseFast
```

Code: `benchmarks/bench_main.zig`. Covers yield (ping-pong / single / work-stealing×4), spawn_join, spawn_result_join, channel (pipeline / rendezvous / mpmc / try), select fan-in, mutex, semaphore, priority dispatch, nursery join, timer batch, actor mailbox.

### 5.1. Results (measured on one machine)

**Environment:** Windows x86_64 · Zig `0.17.0-dev` `-Doptimize=ReleaseFast` · Go `1.26` · g++ C++17 `-O3 -pthread` · 12 logical CPUs.

**What was compared (one-shot, outside the repo):**

| | **zigroutines** | **Go** | **C++** |
|--|-----------------|--------|---------|
| Model | M:N fibers, fixed stack | goroutines + channels | OS threads + mutex/cv “channels” |
| Code in repo | `benchmarks/bench_main.zig` | reference run, not shipped | reference run, not shipped |

Numbers are **ns/op** (lower is better). A dash means that workload had no direct analog in that reference.

| Workload | **zigroutines** | **Go** | **C++ (threads)** |
|----------|----------------:|-------:|------------------:|
| `yield_pingpong` | **27.5** | 113.4 | 164.4 |
| `yield_single` | **49.6** | 145.5 | 113.8 |
| `yield_ws_4w` | 124.5 | 301.8 | **42.6** |
| `spawn_join` | 3711 | **949** | 105240 |
| `chan_pipeline_buf256` | **25.4** | 79.7 | 180.8 |
| `chan_rendezvous` | **114** | 339 | 211 |
| `chan_mpmc_4x4` | 188 | **100** | 301 |
| `chan_try_uncontended` | **25.8** | 51.8 | 40.0 |
| `select_fanin_2` | **38.2** | 219 | — |
| `mutex_uncontended` | 22.1 | **14.9** | 17.3 |
| `mutex_contended_4` | 651 | 39.9 | **33.5** |
| `sem_handoff` | **20.1** | 299 | 8505 |
| `nursery_join` | 3358 | **498** | 58339 |
| `timer_sleep_batch` | 6598 | **1392** | 48462 |
| `actor_mailbox` | **20.2** | 75.9 | 180 |
| `spawn_result_join` | 4877 | — | — |
| `priority_dispatch` | 882 | — | — |

### 5.2. How to read the table

1. **Closest fair match — Go.** Both models: stackful M:N + CSP. On this run, zigroutines is faster than Go on yield and channel pipeline; Go wins on `spawn_join` / contended mutex / nursery (mature runtime, OS futex, cheap spawn).
2. **C++ is a thread baseline, not “C++ fibers.”** ISO C++ has no standard fiber runtime. `spawn_join` and `nursery_join` on OS threads are predictably 1–2 orders of magnitude heavier. C++ `yield_ws_4w` looks “fast” because `std::this_thread::yield` is not a fiber context-switch.
3. **Rust (Tokio / crossbeam)** is not in this table: the machine lacked a toolchain. Expectation: threads+crossbeam ≈ C++ class; Tokio is a *different* model (stackless async), not ns-for-ns with fibers.
4. **Not absolute truth.** One run, one OS, quiet load. Re-check locally: `zig build bench -Doptimize=ReleaseFast`.
5. **Product takeaway:** on the hot path (yield, buffered/rendezvous channel, select, actor mailbox) zigroutines is competitive with a Go-shaped API **without GC and without a hidden runtime**. Where an OS primitive (contended mutex) or amortized Go spawn wins — that is a mechanism difference, not a table bug.


## 6. Runtime configuration (cheat sheet)

```zig
var rt = try zr.Runtime.init(alloc, .{
    .workers = 4,                    // 0 = CPU count
    .policy = .work_stealing,        // auto | single_thread_fifo | work_stealing | priority | thread_per_task
    .default_stack_size = 64 * 1024,
    .stack_pool = true,
    .stack_guard_page = false,
    .stack_paint_canary = false,
    .io = .none,                     // none | poll | iocp | io_uring
    .metrics = false,
    .preempt = .{ .enabled = false, .quantum_ns = ... },
});
```

Optional features (all opt-in):

```
Runtime.workers / policy     : multi-core WS, priority, 1:1
Runtime.io                   : poll | iocp | io_uring
Runtime.stack_pool           : reuse
Runtime.stack_guard_page     : overflow fault
Runtime.stack_paint_canary   : high-water scan
Runtime.metrics              : counters
Runtime.preempt / checkpoint : cooperative quantum
Channel full_policy          : block | drop_newest | drop_oldest | error_full
select timeout / cancel      : timer + CancelToken
Scope / Nursery              : structured join, deadline
spawnResult                  : typed JoinHandle
TcpListener / TcpStream / UdpSocket
IoAdapter (std.Io)
Actor(Message)
C ABI / tracing hooks
```

---
