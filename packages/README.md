# Packages

Each direct child owns a reusable component or an upstream integration. Keep
package-specific source, configuration, and tests beside that owner.

| Package | Purpose |
| --- | --- |
| [tangram](tangram/README.md) | Build pinned upstream Tangram into root `bin/tg` |
| [mise-apple-sdk](mise-apple-sdk/README.md) | Install and verify an Apple SDK through Mise |
| [linux-bootstrap](linux-bootstrap/README.md) | Build Tangram in disposable Linux guests |

These packages support the bootstrap. Tangram-owned project toolchain recipes
are a future stage; see [architecture](../docs/architecture.md).
