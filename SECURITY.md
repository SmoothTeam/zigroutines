# Security Policy

zigroutines does not run with elevated privileges, but it does hand you fixed 2 KiB stacks,
hand-written assembly context switches (`src/context/arch/`), and a C ABI (`src/abi/c_bindings.zig`,
`include/zigroutines.h`) meant to be linked into other processes. Bugs in those areas — stack
corruption, a guard/canary bypass, a use-after-free in the io_uring/IOCP request lifetime, or
undefined behavior crossing the FFI boundary — are memory-safety issues with real impact on whatever
embeds the library. Please report them privately rather than through a public issue.

## Supported Versions

Only the latest release (currently 1.0.0) and the latest commit on `main` are supported. There is no
long-term support branch; security fixes are not backported to older tags.

## Reporting a Vulnerability

Please use one of the following instead of opening a public issue:

- GitHub's [private vulnerability reporting](https://github.com/SmoothTeam/zigroutines/security/advisories/new)
  (Security tab → "Report a vulnerability")
- Email: aksenovpaveldmitrievich@gmail.com

Include what you'd normally include in a report: affected component/file, a reproduction if you have
one, and the impact as you see it (e.g. stack smash, guard-page bypass, UAF on cancel, memory
corruption across the C ABI).

This is a small-team-maintained project, so there's no formal SLA — reports are handled on a
best-effort basis, but security reports get priority over everything else in the queue. A fix (or at
minimum an acknowledgment and mitigation advice) will be published via a GitHub Security Advisory
once resolved.

## Scope

Particularly relevant areas:

- `src/stack/stack.zig` — fixed-stack pool, `StackProtect` (`none` / `canary` / `guard`), TCB
  placement above the usable stack
- `src/context/arch/x86_64_assembly.zig`, `aarch64_assembly.zig` — raw register save/restore on
  context switch
- `src/abi/c_bindings.zig`, `include/zigroutines.h` — the C ABI surface and anything linking against
  `libzigroutines`
- `src/io/io_uring_backend.zig`, `src/io/iocp_backend.zig` — heap-allocated request/CQE lifetime
  around cancellation (`cancelAll`, `ASYNC_CANCEL`, `CancelIoEx`)
