# Executable artifacts

This directory holds the bootstrap entry point, distributable seeds, and tools
materialized by the bootstrap. [mise.toml](../mise.toml) adds it to PATH.

| Files | Owner | Git policy |
| --- | --- | --- |
| `seed.sh` | Host-dispatch wrapper for the seed | Tracked source |
| `universe-seed-*` | [Seed build](../apps/seed/README.md) | Four tracked binaries |
| `mise` | Installed from [seed.zon](../seed.zon) | Ignored |
| `tg` | [Tangram build](../packages/tangram/README.md) | Ignored |

Run `bin/seed.sh` from the repository root to install Mise. The committed seeds
support macOS and Linux on ARM64 and x86-64, so a new machine does not need Zig
for this step. See the [bootstrap guide](../BOOTSTRAP.md) for the full procedure
and the [seed README](../apps/seed/README.md) for destination and argument
rules.

Regenerate the four seed binaries through the owning build task:

```sh
bin/mise -E dev run build-seed
bin/mise -E dev run check-seed-artifacts
```

Commit regenerated seed artifacts with their source changes. The downloaded
Mise executable, built Tangram executable, and temporary `.tangram.*`
publication directories remain ignored. The `.seeds.*` ignore rule covers
legacy publication directories. Zig now prepares atomic replacement files
directly in `bin`; abrupt termination can leave these temporary files behind.
Build and test sources live with their owning app or package.
