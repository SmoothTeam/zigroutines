# Tests and coverage

```bash
zig build test
```

## Suite map (`tests/suite.zig`)

| Layer | Files | Cases |
|-------|-------|--------|
| **Unit** | `stack_pool`, `channel_lifecycle`, `cancellation_token`, `metrics`, `preemption`, `stack_guard_and_canary`, `synchronization`, `rwlock_exclusive`, `timer_queue`, `actor_lifecycle` | alloc/free, `createPooled` recycle, policies construct, cancel flag, metrics on/off, checkpoint, canary/guard, mutex/sem/park, exclusive + concurrent shared RwLock, Notify `notifyAll`, RateLimiter multi-waiter, wheel `nextDeadline`, actor destroy/cancel |
| **C ABI** | `abi/c_abi.zig` + `c_abi_main.c` | version, empty run, spawn+yield, channel send/recv, try+sleep, null handles, would-block, recv-after-close; C executable linked against `zigroutines.lib` |
| **Integration** | `context_switch`, `fifo_scheduler`, `work_stealing_scheduler`, `channel_messaging`, `select_cancellation_scope`, `advanced_features`, `drop_newest_and_nursery` | swap/deep stack, spawn/yield, multi-worker, buffered/rendezvous/close/try/mpmc, select timeout/cancel/recvAny, multi-select, drop_*, nursery timeout/tryJoin/cancel_on_first_done, spawnResult error, priority, thread_per_task, actor, tracer, I/O backend create |
| **I/O** | `mock_and_poll_backend`, `std_io_adapter`, `tcp_echo` | reactor, mock park/wake, IoAdapter, **TCP/UDP echo** on poll and **IOCP**, `cancelAll` (poll + IOCP + io_uring); **io_uring TCP/UDP echo + cancelAll** (Linux) |
| **Stress** | `multi_worker_channels` | WS pipeline, spawnResult, priority order |

## What we treat as “necessary” cases

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


