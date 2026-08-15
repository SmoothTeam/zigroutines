# Benchmarks

| Peer | Product | Measured in harness |
|------|---------|---------------------|
| **Go** | goroutines + `chan` / `select` | full matrix including TCP/UDP |
| **Rust/Tokio** | multi-thread Tokio + `mpsc` / `select!` | full matrix including TCP/UDP |
| **C++** | OS threads + helping thread-pool + ring/`rendezvous` `Chan` (not fibers) | full matrix including TCP/UDP (Winsock, `TCP_NODELAY`) |
| **zigcoro** | single-thread stackful fibers + executor `Channel` | full name matrix; WS/priority/select/mutex/timer/I/O are stand-ins |
| **libxev** | event loop (not fibers) | full name matrix; fiber/channel/select/sync stand-ins; real timers + TCP/UDP |
| **zio** | Runtime + Channel + select + sync + net | full name matrix; priority = FIFO spawn; pooled create = stack init |


## Languages (Go / Rust / C++)

**zigroutines column:** this tree, Windows x86_64, `zig build bench -Doptimize=ReleaseFast`.  
**Language columns:** same machine (Windows x86_64  12 CPUs), same workloads, `go run` / `cargo build --release` / `g++ -O3 -pthread`. Bold = fastest in-row among measured.  
C++ is an **OS-thread** baseline (helping pool + ring channel), not stackful fibers. Rust skynet/spawn/timers run on Tokio tasks, not `std::thread`.

### Fiber / spawn

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

### Channel / actor

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

### Select

| Workload | **zigroutines** | **Go** | **Rust/Tokio** | **C++** |
|----------|----------------:|-------:|---------------:|--------:|
| `select_fanin_2` | **26.3 ns** | 179 | 155 | 192 |
| `select_uncontended` | **26.4 ns** | 99.7 | 98.8 | 30.1 |
| `select_nonblock` | 17.6 ns | 69.8 | **15.0** | 23.0 |
| `select_sync_contended` | **30.1 ns** | 300 | 122 | 193 |

### Sync / timers

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

### I/O

| Workload | **zigroutines** | **Go** | **Rust** | **C++** |
|----------|----------------:|-------:|---------:|--------:|
| `tcp_pingpong` (poll) | **110k RT/s** | 55.0k | 38.3k | 67.6k |
| `tcp_pingpong` (IOCP) | **146k RT/s** | 55.0k | 38.3k | 67.6k |
| `tcp_pingpong` (io_uring) | **321k RT/s** (WSL2 5.15) | 55.0k | 38.3k | 67.6k |
| `udp_ping` (poll) | **376k pkt/s** | 148k | 336k | 250k |
| `udp_ping` (io_uring) | **1651k pkt/s** (WSL2 5.15) | 148k | 336k | 250k |

## Zig libraries (zigcoro / libxev / zio)

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



### Fiber / spawn

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

### Channel / actor

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

### Select

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `select_fanin_2` | **26.3 ns** | 7.9 ns (poll) | 26.4 ns (q) | 85.4 ns |
| `select_uncontended` | **26.4 ns** | 4.0 ns (poll) | 12.8 ns (q) | 62.1 ns |
| `select_nonblock` | 17.6 ns | **3.0 ns** (try) | 6.6 ns (q) | 33.1 ns |
| `select_sync_contended` | **30.1 ns** | 8.2 ns (poll) | 12.8 ns (q) | 81.2 ns |

### Sync / timers

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

### I/O

| Workload | **zigroutines** | **zigcoro** | **libxev** | **zio** |
|----------|----------------:|------------:|-----------:|--------:|
| `tcp_pingpong` (poll) | **110k RT/s** | 66.4k (thread) | 48.9k | 94.2k |
| `tcp_pingpong` (IOCP) | **146k RT/s** | 66.4k (thread) | 48.9k | 94.2k |
| `tcp_pingpong` (io_uring) | **321k RT/s** (WSL2 5.15) | 66.4k (thread) | 48.9k | 94.2k |
| `udp_ping` (poll) | **376k pkt/s** | 259k (thread) | 178k | 167k |
| `udp_ping` (io_uring) | **1651k pkt/s** (WSL2 5.15) | 259k (thread) | 178k | 167k |

## Why you cannot compare these libraries as if they were the same product


### They are different machines

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

### What a “loss” actually paid for

These are the rows a skimming reader will use against us. Each one is a constraint we refused to drop.

- **`yield_single` / `yield_ws_4w` — zio 3.1 / 6.0 ns vs 6.7 / 11.9.** zio’s yield is a thinner “give up this executor.” Ours goes through the **same** scheduler that has to be correct under work-stealing, priority, cancel, and “parked on a channel.” You do not get a special fast yield that stops working when you turn workers on.
- **`skynet_join_10k` / `spawn_join` — zigcoro 65 / 78 ns vs 404 / 127.** zigcoro is creating frames on one thread and awaiting them. We create a task that a **worker** can steal, with a pooled 2 KiB stack, a join handle, and (for skynet) `spawnLeaf` only on the nodes that never park. The extra nanoseconds are the M:N tax. Tokio beats us on skynet and `n_tasks_*` for the same reason it beats everyone stackful: a Tokio task is a **state machine**, not 2 KiB of stack. That model colors every function `async`. We will not take that deal on Zig.
- **`chan_pipeline` — zigcoro 6.8 ns vs 19.9.** Their `Channel` is a single-thread ring on the executor. Ours is safe for four producers and four consumers, has rendezvous, close, `select`, and four full policies. The 13 ns is the price of “this channel still works when you add a worker.”
- **`timer_many_100k` — zio 432 ns vs 761.** They have a tighter timer path. Ours is a 256×1 ms wheel plus heap overflow plus a sub-tick yield so `sleep(50 ns)` is not quantized to 1 ms. We lose the “arm 100k and fire” cell; we keep one sleep API that is honest at both 50 ns and 50 ms.


### Why this is still the library to take on Zig

You are not choosing a nanosecond. You are choosing **what you will write for the next two years**.

1. **One surface, not a kit.** libxev does not give you tasks. zigcoro does not give you a scheduler, I/O, or cancel. zio gives you a runtime you cannot turn the poller off of, and stacks that grow. With zigroutines you `Runtime.init`, `spawn`, `Channel.create`, `select`, and — if you need it — set `.io = .iocp`. The same program can be compute-only on Monday and IOCP on Tuesday without a rewrite.

2. **The model matches how you already want to write Zig.** `send` / `recv` / `sleep` / `accept` look like ordinary calls. The task parks; another task runs. No `async` infection, no `Pin`/`Send` puzzle, no callback inversion. That is the whole point of stackful. zigcoro has the swap and stops there. zio has the swap and then ties you to its I/O. We have the swap **and** the product around it.

3. **Resources stay a number you picked.** Fixed 2 KiB, pool on, guard optional and shared. Ten thousand tasks are ~40 MiB of stacks, not “however far the growable mapping went after the JSON parser recursed.” zio’s growable stacks are a genuine convenience. They are also how you get a surprise RSS bill. We made the inconvenient choice on purpose.

4. **The scheduler is a policy, not a fork.** FIFO on one worker, work-stealing on N, priority when a timer must cut the line, thread-per-task when you must. Same `spawn`. zigcoro is one thread. zio is steal-or-pin. libxev is not a scheduler. If your program’s shape changes, you change a field, not a library.

5. **I/O is a backend, not the religion.** A lot of concurrent Zig is *not* a network server. Embedding a netpoller in the core so that `yield` is fast is how you get a library that is wrong for half its users. We lose a yield cell to zio and keep “no poller” as the default. When you do want I/O, poll / IOCP / io_uring are the same TCP helpers, and on this machine that path is the fastest one in the table (110k / 146k / 321k RT/s).

6. **A loss in 5.2 is usually a feature you will need by week two.** Multi-worker safety. `select` with timeout and cancel. A nursery that tears the children down. A channel that still has backpressure when the consumer is slow. A stack that cannot silently become 64 KiB. The library that “won” that row typically does not have that feature. Shipping the thinner machine means you will re-implement the missing piece — and then you no longer have the nanosecond you bought.

zio is a serious runtime and the only fair *category* peer. If you want growable stacks and `std.Io` as the center of the universe, take zio. If you want a completion loop, take libxev. If you want a coroutine brick to build your own runtime, take zigcoro.

If you want **to write concurrent Zig** — tasks that look synchronous, channels you can `select` on, cancel that actually unwinds a tree, I/O you can leave off, and a memory bill you can explain — take zigroutines. The benches where we are not first are the benches where the winner was allowed to be a smaller library.

