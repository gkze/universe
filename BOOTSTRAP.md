# Bootstrap

The bootstrap installs verified Mise, provisions pinned build inputs, and builds
Tangram from source. The [root README](README.md) describes current platform
scope. Component contracts live in the [seed](apps/seed/README.md),
[Tangram](packages/tangram/README.md), and
[Apple SDK](packages/mise-apple-sdk/README.md) documentation.

## Host prerequisites

Requirements differ by stage:

| Stage | Host requirements |
| --- | --- |
| Seed dispatch and installation | Supported OS/CPU, POSIX shell, `uname`, `dirname`, network access, trusted CA store, writable destination |
| Tangram source build | Bash, Git, standard filesystem utilities, network access for dependency acquisition, platform headers and runtime libraries |
| Apple SDK installation | macOS with Apple's `pkgutil` and `plutil`; see the plugin's installation requirements |
| Linux source build | GNU userspace and native development libraries; the test [Containerfile](packages/linux-bootstrap/Containerfile) declares the guest environment |
| Seed development | Optional `dev` environment, including Zig; LLVM's strip tool for macOS release artifacts |
| Linux VM tests | Apple silicon with the configured `container` service; see the [runner guide](packages/linux-bootstrap/README.md) |

The seed implements HTTP, SHA-256, and archive reading in Zig. It does not call
`curl`, `wget`, `tar`, or `shasum`. Later provisioning and build steps have
their own subprocess and system-library requirements.

The macOS bootstrap uses pinned LLVM and an Apple SDK. A successful build with
`DEVELOPER_DIR` set to a nonexistent directory is not proof that a clean machine
without Xcode or Command Line Tools has every prerequisite.

## Build Tangram

From the repository root:

```sh
bin/seed.sh
bin/mise trust
bin/mise install
bin/mise run build-tangram
bin/tg --version
```

Review repository configuration before trusting it. `bin/seed.sh` selects a
committed native seed, which reads [seed.zon](seed.zon) and installs `bin/mise`.
Every seed invocation downloads and verifies Mise again; it does not provide an
offline reuse path. An explicit destination is supported by the
[seed CLI](apps/seed/README.md).

The build publishes `bin/tg` only after the candidate's version command
succeeds. The root `bin/` directory is on the Mise project PATH. Invoking
`bin/tg` directly also works without shell activation.

Later builds can reuse a commit-keyed source copy and Cargo's outputs under
`.build/tangram/`. The adapter builds a writable copy of the Mise installation;
it does not run Cargo in the shared installed source directory.

## Environments and trusted inputs

| Configuration | Contents |
| --- | --- |
| [mise.toml](mise.toml) | Bootstrap tools, Tangram inputs, PATH, plugin registration, build and cleanup tasks |
| [mise.dev.toml](mise.dev.toml) | Optional Zig and repository quality tools, plugin type definitions, and Linux VM tooling |

The default configuration supplies Tangram bootstrap inputs. Add `-E dev`
for repository development.
`MISE_ENV=dev` is the equivalent environment selection for an activated
shell. Mise's tool installations and caches are shared by default; `.mise/` is
an ignored legacy location, not the current tool installation root.

This stage trusts binary Rust, Bun, LLVM, V8, and platform SDK/runtime inputs.
Tangram source and explicitly configured HTTP artifacts are pinned by identity
and checksum. Linux system libraries and the VM service add inputs outside
those pins. The bootstrap does not build LLVM or Rust from source and does not
establish byte-for-byte reproducibility or a fully hermetic dependency closure.

See [architecture](docs/architecture.md) for the planned transition to
Tangram-owned project tools and
[the Tangram adapter](packages/tangram/README.md) for ABI, linker, SDK, and
sandbox details.

## Development checks

```sh
bin/mise -E dev install
bin/mise -E dev run install-commitlint
bin/mise -E dev exec -- prek install
bin/mise -E dev exec -- prek run --all-files
```

The local hook runs lint, formatting checks, and ordinary tests. It does not
rewrite source. Use `bin/mise -E dev run format` when you intend to apply
formatting. See [tests](tests/README.md) for focused checks, artifact
comparison, and manual platform tests.

When seed executable or release-build semantics change, regenerate the four
tracked binaries using the [seed maintenance procedure](apps/seed/README.md).
Downloaded `bin/mise`, built `bin/tg`, and intermediate outputs stay ignored.

## Recovery and cleanup

The Tangram build holds `.build/tangram/.lock` across source preparation,
compilation, and publication. If a build is killed, confirm that its processes
have stopped before removing a stale lock or cleaning its outputs. Avoid
cleanup while any build is active.

The previous `bin/tg` remains in place until a candidate passes its version
check and replaces it atomically. Failed source preparation is staged privately;
the next build can retry. Consult the component READMEs before manually changing
staging directories or shared Mise installations.

Run cleanup from the repository root:

| Command | Removes |
| --- | --- |
| `bin/mise run clean-zig` | `apps/*/zig-out` and `apps/*/.zig-cache` |
| `bin/mise run clean-tangram` | `.build/tangram` and `bin/tg` |
| `bin/mise run clean` | Both sets above |
| `bin/mise run clean-mise` | Only the downloaded `bin/mise` |

These tasks retain the four shipped seed binaries and shared Mise tools. They
do not remove every possible scratch output, dependency cache, or retained Linux
test log. After `clean-mise`, run `bin/seed.sh` to install Mise again.
