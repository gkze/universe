# Applications

Each direct child is an application with an executable interface. Keep its
implementation, build adapter, and component tests together. Languages can be
colocated within an application; the directory boundary follows purpose.

| Application | Purpose |
| --- | --- |
| [seed](seed/README.md) | Install verified Mise using a shipped native executable |

The seed's distributable launcher and binaries live in
[root bin/](../bin/README.md). See [architecture](../docs/architecture.md) for
the application/package boundary.
