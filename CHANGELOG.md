# Changelog

## 1.0.0 (2026-08-15)

### Runtime / fibers

- **TCB vs frames.** Was: the task control block lived where a growing frame could overwrite it (Windows `chkstk` / deep spawn made this worse). Problem: silent corruption and Debug-mode crashes on a 2 KiB stack. Now: 512 B TCB sits in a suffix *above* the 2 KiB usable stack; frames grow down and cannot smash control state.
- **Spawn on a 2 KiB stack.** Was: `spawn` / `spawnResult` ran on the caller fiber. Problem: the spawn path itself does not fit in 2 KiB, so nested spawn (skynet, nursery) overflowed or had to bounce ad-hoc. Now: spawn always hops onto the worker stack and resumes the child immediately only if the ready queue is empty.
- **Mutex unlock under work-stealing.** Was: unlock woke the waiter onto a stealable ready queue. Problem: another worker could steal the continuation and the unlocking fiber resumed with the mutex conceptually still “in flight”. Now: unlock installs a non-stealable `handoff_cont`; park returns to the worker loop and the waiter runs next on that worker.
- **Linux context switch.** Was: `swapLinux` used the `to` pointer from a general-purpose register while also restoring `r12`–`r15`. Problem: if LLVM put `to` in one of those regs, restore clobbered the pointer → SEGV on the first fiber bench. Now: `to` is copied to `r11` first, same pattern as the Windows path.
- **Stack-pool cap.** Was: default `max_per_class = 1024`. Problem: a 100k-fiber wave (`timer_many`, skynet) freed ~99k stacks back to the OS on join, dominating dispatch time. Now: default cache is 131072 slots; the wave returns to the pool instead of `HeapFree`.

### Timers

- **Finding the next deadline.** Was: SmoothTeam scanned wheel slots linearly. Problem: idle `nextDeadlineNs` paid O(256) even when almost nothing was armed. Now: occupied bitmap `[4]u64` + `@ctz` jumps to the next live slot.
- **Sub-tick sleep.** Was: `sleep(500 ns)` parked on the 1 ms wheel (and Windows `Sleep` rounds up to 1 ms). Problem: `timer_many_100k_dispatch` and `timer_sleep_batch` measured a millisecond wait, not a nanosecond sleep — 1197 ns/op and 798 ns/op. Now: `duration < 1 ms` yields until the deadline and never enters the wheel. Dispatch **1197 → 761 ns**, batch **798 → 471 ns**.

### Channels / sync

- **Hot-path channel.** Was: mutex around the whole ring (or a coarse lock) for every send/recv. Problem: uncontended pipeline and rendezvous paid a lock even with no waiters. Now: Vyukov MPMC seq-slot ring; the lock is only for the waiter lists. Optional `spsc` / `mpsc` skip the extra atomics.
- **Cold `Channel.create`.** Was: two heap allocations (header + slots) and `destroy` always ran `close()`. Problem: `chan_create_buf8` was **10.1k ns** (plus DebugAllocator in the harness made it look even worse). Now: one `alignedAlloc` for header+slots; unused destroy skips close. Harness uses `smp_allocator`. Cold create **10.1k → 20.9 ns**, pooled **28.7 → 20.3 ns**.
- **Channel recycle.** Was: every create hit the heap; SmoothTeam had no pool. Problem: tests that used a leak-checking allocator could not recycle, so production code had no safe hot-create API. Now: `createPooled` / `recycle=true` is opt-in; default `create` stays leak-free under test allocators.
- **RwLock readers.** Was: shared acquires took the big lock even with no writer. Problem: `rwlock_shared_4` serialized readers. Now: atomic reader count; park only if a writer is present or waiting.
- **Rate limiter.** Was: no token-bucket primitive. Problem: callers built their own sleep loops and missed wake-on-refill. Now: `RateLimiter` parks waiters and wakes them as tokens refill (`rate_limiter_try` bench).

### I/O

- **Poller.** Was: SmoothTeam created/destroyed poll and had a poll-only TCP echo; a blocked `select`/`epoll` did not see waiters registered after it went to sleep. Problem: hang on “add waiter while poller is in the kernel”. Now: Windows `select` (256 fds) + UDP wakeup, Linux epoll + eventfd, POSIX poll + pipe; `wakeup` only while the poller is blocked.
- **IOCP.** Was: backend existed as “create/destroy + `supports_async`”, no overlapped echo. Problem: Windows I/O still went through readiness `select`, leaving 110k RT/s on the table and no `CancelIoEx` path. Now: heap `IoRequest` + freelist, `WSARecv`/`WSASend`, `PostQueuedCompletionStatus`, `CancelIoEx`. UDP stays readiness-based (not IOCP-associated). Echo + `cancelAll` are tested. IOCP pingpong **146k RT/s**.
- **io_uring.** Was: placeholder “Linux / WSL2” in the tables; SmoothTeam never shipped an e2e number. Problem: no CQE-lifetime rules, cancel could use-after-free, and Zig 0.17 deleted `std.posix.socket`/`close`/`nanosleep`/`mprotect` so Linux did not even build. Now: heap `UringReq` + freelist, CQE harvest never blocks under the lock, `ASYNC_CANCEL` on `cancelAll`, Linux syscalls via `std.os.linux`. Measured on WSL2 5.15 (`CONFIG_IO_URING=y`): TCP **321k RT/s**, UDP **1651k pkt/s**.
- **TCP helpers.** Was: bind/connect/accept/`read`/`write` ran on the fiber stack and used blocking sockets unless the backend said otherwise. Problem: Windows stack probes + sync `connect` blew the 2 KiB stack. Now: bind/connect/accept bounce to the worker; `read`/`write` use overlapped/async ops when `supports_async`.

### C ABI

- **Foreign surface.** Was: none on SmoothTeam. Problem: C/C++ (and anything that cannot import a Zig module) had no way to construct a runtime or a channel. Now: `include/zigroutines.h` + static lib from `zig build` (Windows also needs `ws2_32` + `ntdll`). Covered by `tests/abi/c_abi.zig` and `zig build c-abi-test`.

### Tests / benches

- **Windows Debug tests.** Was: `zig build test` in Debug was treated as the gate. Problem: 2 KiB + MSVC `chkstk` is unsafe; the suite red-herringed real bugs. Now: authoritative gate is `zig build test -Doptimize=ReleaseSafe`.
- **Harness allocator.** Was: `DebugAllocator` (even with `safety=false`). Problem: ~10 µs per malloc, so `chan_create` / `skynet` measured the allocator, not the library. Now: `std.heap.smp_allocator`.
- **`skynet_join_10k`.** Was: 11k stackful `spawnResult`s on one FIFO worker — **22.8k ns**/spawn (SmoothTeam published 14k). Problem: 10k leaves never park but still paid a 2 KiB stack and a bounce; one core vs Go’s `GOMAXPROCS`. Now: size-1 nodes are `spawnLeaf`, internals run on work-stealing across CPUs. **22.8k → 404 ns** (ahead of Go 538 ns).
- **Coverage.** Was: poll echo only; no RateLimiter/Notify/`createPooled` unit tests. Now: TCP/UDP echo + `cancelAll` on poll and IOCP (Windows) and io_uring (Linux/WSL2); unit tests for pooled recycle, RateLimiter N waiters, `Notify.notifyAll`, timer-wheel bitmap.
- **Tables.** Was: Go, Rust, C++, zigcoro, libxev, zio in one grid. Problem: a language runtime and an event loop were compared as if they were the same kind of peer. Now: 5.1 languages, 5.2 Zig libraries.
- **C++ / Rust harness.** Was: C++ `mutex`+`queue`+`notify_all`, capacity 0 coerced to 1, skynet as 10k OS threads; Rust skynet as `std::thread`. Problem: the numbers measured the worst possible implementation, not a serious peer, and reviewers called the benches unsafe/slow. Now: C++ helping pool + ring/`rendezvous` `Chan` + `TCP_NODELAY` + UDP recv timeout; Rust skynet is `tokio::spawn` (`Send` future). Re-measured in 5.1 (Rust skynet **45.5k → 219 ns**, C++ TCP **54.9k → 67.6k** RT/s).
- **Peer name matrix.** Was: zigcoro/libxev/zio only printed the primitives they own; most rows were `n/a`. Problem: a missing cell looks like “we hid a loss,” and you cannot scan one name across every peer. Now: every workload name is printed. Stand-ins are tagged (`(q)`, `(FIFO)`, `(thread)`, …) and never bolded. zio covers the full runtime surface; zigcoro I/O is blocking Winsock; libxev fiber/channel/sync names are queues and loops.

### Benches sped up


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
