## What / why

<!-- What does this change do, and why? Link related issues if any. -->

## Checklist

- [ ] New files have an SPDX header matching their directory's license (see `CONTRIBUTING.md`), or
      a `REUSE.toml` annotation if a header doesn't fit the file format
- [ ] `reuse lint` passes
- [ ] `zig build test -Doptimize=ReleaseSafe` passes
- [ ] `zig fmt .` applied (CI's formatting check is currently non-blocking, see `CONTRIBUTING.md`)
