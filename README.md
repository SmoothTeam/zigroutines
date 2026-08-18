# 🧵 Zigroutines

Links for repositories: [![GitHub](https://img.shields.io/badge/GitHub-SmoothTeam%2Fzigroutines-181717?logo=github)](https://github.com/SmoothTeam/zigroutines)

General information: [![Version](https://img.shields.io/github/v/tag/SmoothTeam/zigroutines?label=version&color=green)](https://github.com/SmoothTeam/zigroutines/tags) [![REUSE](https://github.com/SmoothTeam/zigroutines/actions/workflows/reuse.yml/badge.svg?branch=main)](https://github.com/SmoothTeam/zigroutines/actions/workflows/reuse.yml) [![Zig](https://img.shields.io/badge/zig-0.17--dev.1503%2B-orange)](https://ziglang.org/)

Platforms: [![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS%20%7C%20FreeBSD-lightgrey)](README.md) [![Arch](https://img.shields.io/badge/arch-x86__64%20%7C%20aarch64-lightgrey)](README.md)

Licensing: [![lib: LGPL-3.0-or-later](https://img.shields.io/badge/lib-LGPL--3.0--or--later-blue.svg)](LICENSES/LGPL-3.0-or-later.txt) [![docs: CC-BY-4.0](https://img.shields.io/badge/docs-CC--BY--4.0-blue.svg)](LICENSES/CC-BY-4.0.txt)

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

## 2. Documentation

- [Architecture](doc/architecture.md) — layers, control flow, full entity/mechanism catalog with file locations
- [Usage examples](doc/usage.md) — runnable snippets (spawn, channels, select, nursery, C ABI)
- [Tests and coverage](doc/testing.md) — suite map, what is treated as a necessary case
- [Benchmarks](doc/benchmarks.md) — Go/Rust/C++ and Zig-library comparisons, methodology
- [Runtime configuration](doc/configuration.md) — full options cheat sheet
- [Changelog](CHANGELOG.md) — 1.0.0 release notes
