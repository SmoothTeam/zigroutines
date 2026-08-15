# Contributing to zigroutines

## Before you start

The design and entity catalog live in [`doc/architecture.md`](doc/architecture.md) — read it before
touching the scheduler, stack pool, or I/O backends; it explains where each mechanism lives and why
(e.g. why the TCB sits *above* the usable stack, why cancellation is cooperative, why I/O is a
plugin instead of baked into the core).

## Building and testing

See the [README](README.md) for prerequisites (`build.zig.zon` pins the minimum Zig version) and the
full command list. The authoritative test gate is:

```bash
zig build test -Doptimize=ReleaseSafe
```

Debug is not a valid gate here: a 2 KiB stack plus MSVC `chkstk` / unoptimized frame sizes can fail
in Debug for reasons that have nothing to do with a real bug. See
[`doc/testing.md`](doc/testing.md) for the suite map and what each layer (unit / integration / I/O /
stress) is expected to cover.

## License and REUSE

This repo is [REUSE](https://reuse.software/)-compliant and licensed by directory:

- `src/*`, `tests/*`, `examples/*`, `include/*` — LGPL-3.0-or-later (SPDX header inline in each file)
- `benchmarks/*` — LGPL-3.0-or-later (via `REUSE.toml`, no inline header)
- `doc/*`, `README.md`, `CHANGELOG.md`, `.gitignore`, `LICENSE` — CC-BY-4.0 (via `REUSE.toml`)

`examples/*` also has a `CC-BY-4.0` entry in `REUSE.toml`, but it's currently shadowed by the inline
LGPL header each example file carries — inline SPDX tags win over `REUSE.toml` annotations for the
same file. Until that's resolved, treat `examples/*` as LGPL-3.0-or-later in practice.

Every new source file under `src/`, `tests/`, `examples/`, or `include/` needs an SPDX header:

```zig
// SPDX-FileCopyrightText: <year> <your name>
//
// SPDX-License-Identifier: LGPL-3.0-or-later
```

For files where a comment header doesn't make sense (Markdown, TOML, lockfiles, `.gitignore`), add an
annotation to `REUSE.toml` instead — match the license of the directory the file lives in. Run
`reuse lint` before submitting; it must be clean.

## Pull requests

Keep PRs scoped to one change. Make sure `zig build test -Doptimize=ReleaseSafe` and `reuse lint`
both pass before opening.
