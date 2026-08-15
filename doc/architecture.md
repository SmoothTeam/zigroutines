# Architecture

## Diagram (logical view)

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

## Layers and control flow

1. **Application layer** — your functions invoked via `Runtime.spawn` / `spawnResult` / `Nursery.spawn` / `Actor`.
2. **CSP / sync** — `Channel`, `select`, Mutex/Semaphore/…: on block, call `parkFromRunning` on the current executor.
3. **Task** — unit of execution: id, state, fixed stack, context saved **on the fiber stack**, join-waiters, optional result slot (also on the stack when it fits).
4. **Scheduler backend** — ready queue, worker↔task context swap, live/dead accounting, timer/I/O poll in idle.
5. **Runtime** — facade: config, backend creation, stack pool, timer queue, I/O ownership, TLS “current runtime”.
6. **Context / arch** — assembly stack switch (x86_64 / aarch64).
7. **Utils** — lock-free / intrusive structures (Chase-Lev deque, ring queue, lists).

## Entities, mechanisms, policies, algorithms

Below is a full catalog of “what exists in the system” and **where the code lives**.

### Core (Runtime, Task, Executor)

| Entity | Role | Files |
|--------|------|--------|
| **Runtime** | Owns scheduler, timers, optional I/O/metrics; API `init` / `spawn` / `run` / `sleep` | `src/core/runtime.zig` |
| **Config** | workers, policy, stack options, io, metrics, preempt | `src/core/runtime.zig` |
| **Task** | Fiber: stack, context, state machine, join | `src/core/task.zig` |
| **JoinHandle / TypedJoinHandle** | Wait for completion; typed result | `src/core/task.zig` |
| **Executor** | VTable: enqueue, yield, park, finish | `src/core/executor.zig` |
| **yield / current / sleep** | Cooperative CPU yield; TLS current task; sleep via timers | `task.zig`, `runtime.zig` |

**Rules:** `yield` / `channel` / `sync` are allowed **only inside a task**. Outside a task — panic with a clear message. `sleep` requires a TLS runtime (set by `run`). `Runtime.spawn` / `spawnResult` from a fiber bounce onto the worker stack (2 KiB is not enough for the spawn path).

### Schedulers (policies)

| Policy | Behavior | Files |
|--------|----------|--------|
| **auto** | 1 worker → FIFO; ≥2 → work-stealing | `runtime.zig` |
| **single_thread_fifo** | One queue, one thread, strict FIFO | `src/scheduler/fifo_scheduler.zig` |
| **work_stealing** | N workers, local deques, steal | `src/scheduler/work_stealing_scheduler.zig` + `utils/chase_lev.zig` |
| **priority** | 1 worker, min-heap / priority queue by `SpawnOptions.priority` (0 = highest) | `src/scheduler/priority_scheduler.zig` + `utils/priority_queues.zig` |
| **thread_per_task** | 1 OS thread per task (1:1), for comparison / blocking FFI | `src/scheduler/thread_per_task_scheduler.zig` |
| Shared facade | | `src/scheduler/scheduler.zig` |


### Stacks

| Mechanism | Role | Files |
|-----------|------|--------|
| **Stack** | Fixed 2 KiB usable region | `src/stack/stack.zig` |
| **Pool slot** | `[2 KiB usable \| 512 B TCB]`; TCB sits *above* the stack so frames cannot smash it | `stack.zig`, `task.zig` |
| **Pool** | Reuse; heap class for `none`/`canary`, arena slots for `guard` | `stack.zig` |
| **`StackProtect.none`** | Default: no extra RSS, no check | `stack.zig` |
| **`StackProtect.canary`** | Opt-in 16-byte cookie; checked on yield/park/finish | `stack.zig` |
| **`StackProtect.guard`** | Opt-in OS fault via a reserved arena (not one mmap per task) | `stack.zig` |
| **paint_canary** | Full pattern fill; `highWaterUsed()` (word scan) | `stack.zig` |


### Context switch

| Entity | Role | Files |
|--------|------|--------|
| **Context** | Saved registers; stored at the **top** of the fiber stack (TCB holds a pointer) | `src/context/context.zig`, `src/core/task.zig` |
| **x86_64 / aarch64 asm** | `make` / `swap` | `src/context/arch/x86_64_assembly.zig`, `aarch64_assembly.zig` |
| **supported** | comptime flag for the target platform | `context.zig` |

### CSP: channels and select

| Entity | Role | Files |
|--------|------|--------|
| **Channel(T)** | Buffered or rendezvous (capacity 0); MPMC seq-slot ring (lock only for waiters); optional `spsc`/`mpsc` topology | `src/csp/channel.zig` |
| **FullPolicy** | `block` · `drop_newest` · `drop_oldest` · `error_full` | `channel.zig` |
| **send / recv / try\*** | Blocking and non-blocking ops | `channel.zig` |
| **select.multi / recv / recvAny** | Up to 32 recv + 32 send arms; timeout; cancel; default | `src/csp/select.zig` |
| **Fairness** | `random` (default) / `fifo` when several arms are ready | `select.zig` |

**Scenarios:** pipeline, fan-in/fan-out, rendezvous handoff, backpressure telemetry (`drop_*`), non-blocking poll (`try` / `default` arm).

### Cancellation and structured concurrency

| Entity | Role | Files |
|--------|------|--------|
| **CancelToken** | Atomic flag, parent→children link, waiters | `src/core/cancellation.zig` |
| **Scope** | Group of children + token; `WaitGroup` join (last child wakes the parent) | `src/core/structured_concurrency.zig` |
| **Nursery** | Scope + deadline/timeout + `cancel_on_first_done` + `tryJoin` | `structured_concurrency.zig` |

**Cooperative rule:** cancel **does not interrupt** machine code. Children must **poll** the token (or wait on select/channel with cancel). A deliberate “explicit over implicit” choice.

### Timers

| Entity | Role | Files |
|--------|------|--------|
| **TimerQueue** | Near-term **wheel** (256×1 ms) + min-heap for long deadlines; occupied **bitmap** (`@ctz` on 4×u64) for `nextDeadlineNs`; `sleep`, `fireExpired` | `src/core/timer_queue.zig` |
| Integration | Scheduler in idle fires expired timers | `fifo_scheduler.zig`, `work_stealing_scheduler.zig`, … |

### Synchronization (task-aware)

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

### I/O

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

### Actors, metrics, preemption, tracing, ABI

| Entity | Role | Files |
|--------|------|--------|
| **Actor(Message)** | Mailbox channel + loop; optional link/on_stop | `src/actors/actor.zig` |
| **Metrics** | Atomic counters: spawns, yields, parks, steals, … | `src/core/metrics.zig` |
| **Preemption / checkpoint** | Cooperative quantum yield | `src/core/preemption.zig` |
| **Tracing / RingTracer** | Opt-in event emit | `src/core/tracing.zig` |
| **C bindings** | Foreign surface (`include/zigroutines.h`, static lib) | `src/abi/c_bindings.zig` |

### Utilities

| Structure | Role | Files |
|-----------|------|--------|
| Chase-Lev deque | Lock-free work-stealing queues | `src/utils/chase_lev.zig` |
| Intrusive list | Wait queues (channel, sync, join) | `src/utils/intrusive_list.zig` |
| Ring queue | FIFO ready queue | `src/utils/ring_queue.zig` |
| Priority queues | Priority scheduler | `src/utils/priority_queues.zig` |
| task_wake / worker_wake | Safe wake with on_cpu spin | `src/utils/task_wake.zig`, `worker_wake.zig` |
| windows_api | Windows helpers | `src/utils/windows_api.zig` |


