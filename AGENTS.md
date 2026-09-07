# Working in Universe

Read [README.md](README.md) for current scope and [BOOTSTRAP.md](BOOTSTRAP.md)
for the supported workflow. Component READMEs own detailed behavior;
[docs/architecture.md](docs/architecture.md) distinguishes accepted decisions
from future work.

## Ownership and layout

- Keep units flat under `apps/<name>` and `packages/<name>`. Organize by
  purpose; languages can coexist inside a unit. Apps expose executable
  interfaces; packages own reusable components or upstream integration.
- Mise provisions the bootstrap floor and optional repository development
  tools. Tangram is the intended owner of project toolchains. Do not describe
  future recipes or semantic analysis as implemented functionality.
- Keep substantive scripts and tests with their component. Use Mise for task
  orchestration and tool selection, Zig for seed compilation and native tests,
  and Lua for plugin behavior. Shell entry points have `.sh` extensions.
- Preserve lifecycle ownership when simplifying wrappers: staging, validation,
  publication, child processes, and cleanup must remain coordinated.
- Root `bin/` contains the seed launcher, four shipped seeds, and ignored local
  installations. It is not the source directory for build tasks.

## Authoritative configuration

| Concern | Authority |
| --- | --- |
| Mise release, download URL, archive and binary hashes | `seed.zon` |
| Rust/Bun bootstrap versions and base tasks | `mise.toml` |
| Tangram source commit and verified bootstrap archives | `mise.toml` |
| Development tool versions, source patterns, task graph | `mise.dev.toml` |
| Seed targets, build options, stripping, native test matrix | `apps/seed/build.zig` |
| Zig dependencies | `apps/seed/build.zig.zon` |
| Apple release identity, hashes, signer, SDK metadata | `packages/mise-apple-sdk/releases.lua` |
| Linux guest image and system packages | `packages/linux-bootstrap/Containerfile` |
| Local hook selection and order | `prek.toml` |
| Commitlint dependencies and rules | `package.json`, `bun.lock`, `.commitlintrc.json` |

Change the authority, then update its consumers. Link to version declarations
instead of copying pins into prose. Keep Tangram's V8 archive compatible with
the pinned source lockfile, features, and host ABI. Preserve the conformance
check between configured archives and the Tangram adapter's host guard.

## Contracts to preserve

- Seed root discovery uses `.root` and terminates at the filesystem root. The
  default destination is the discovered repository's `bin/`; an explicit
  destination is relative to the invocation directory unless absolute.
- The seed keeps bounded in-memory downloads and extraction. Verify both
  archive and executable hashes, select only the exact regular-file entry, and
  reject duplicate entries. See the seed README for limits and HTTP behavior.
- Installation owns executable mode `0755` and atomic replacement. Preserve
  existing symlink targets. Atomic visibility does not imply crash durability.
- Zig owns all seed release targets. The publication step waits for all
  producers, validates candidates, and prepares every replacement before
  publishing. Replacement is atomic per binary, not across the four-file set.
- Tangram builds use a writable copy of verified source, a nested Git root,
  an invocation-owned lock, and validated atomic publication. Preserve paths
  containing spaces and compiler/linker behavior for host build scripts and
  procedural macros.
- The SDK plugin delegates download/hash mechanics to Mise and uses Apple's
  tools for signature and SDK metadata verification. Preserve primary failures
  and report cleanup failures separately.
- Linux test guests receive a source snapshot. Do not mount the live checkout,
  host installed binaries, or host caches writable into the guest.

## Validation and generated artifacts

From the repository root, after installing `dev`:

```sh
bin/mise -E dev run check
bin/mise -E dev run check-seed-artifacts
```

`check` runs lint, formatting checks, and ordinary component/integration tests.
The second command independently rebuilds and compares all four shipped seeds;
it does not replace them. Real Linux VM builds are separate manual tasks.
[tests/README.md](tests/README.md) lists focused commands and their limits.

For a documentation-only change, run Markdown checks and verify relative links
and documented commands. For executable or build changes, run the affected
behavior tests and appropriate aggregate checks. When changing seed executable
or release-build semantics, regenerate through
`bin/mise -E dev run build-seed`, then compare the artifacts. Include the
resulting four tracked binaries with the source change; never edit them
directly.

Use `format-check` for checks and `format` for intentional source changes. Keep
new languages and components covered by Mise source patterns or native tool
discovery. TOML and Markdown use an 80-column formatting target; preserve URL,
path, and hash strings, and wrap long commands only at safe argument boundaries.
Evaluate new linter rules for useful diagnostics before making them mandatory.

GitHub Actions runs `check` and `check-seed-artifacts` on macOS ARM64 for pull
requests and pushes to `main`. Keep the workflow thin: Mise owns the checks
and tool versions. Validate workflow YAML with `lint-workflows`. Real Linux
VM builds remain manual. Do not equate fixtures, cross-compilation, artifact
comparison, native execution, and live provider verification. Document the
known Zig fuzz-runner limitation without claiming a successful native fuzz run.

## Workspace and documentation maintenance

- Use Conventional Commit messages. Prek's `commit-msg` hook runs commitlint
  with `@commitlint/config-conventional`; `tests/README.md` owns setup.
- Inspect Git status, including staged, unstaged, and untracked files, before
  editing or committing. Preserve unrelated work and reconcile concurrent
  changes before selecting a checkpoint.
- Keep `.build/`, Zig caches/outputs, downloaded dependencies, LuaLS logs,
  `bin/mise`, and `bin/tg` out of commits. `.gitignore` defines the actual
  paths.
- Do not clean active builds. Confirm a lock's owner has stopped before removing
  a stale lock. Retain shared Mise installations when cleaning this checkout.
- Use Mermaid fenced blocks where diagrams clarify architecture, workflows,
  lifecycles, or ownership boundaries. Keep diagrams beside the owning docs and
  synchronized with the implemented behavior; label future work explicitly.
- Maintain a README at each meaningful component boundary. Keep detailed
  contracts beside their owner and use links from overview documents. Do not
  duplicate manuals in every implementation subdirectory.
- Update commands, source-of-truth references, invariants, and platform claims
  with the owning change. Separate accepted behavior from proposals and record
  the date and scope of historical build evidence.
- Keep this file about repository rules. Do not copy personal instructions,
  session transcripts, secrets, or temporary download URLs into it.
