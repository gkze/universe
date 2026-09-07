#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Mock compilation while preserving source-copy, lock, and publication effects.
mkdir -p "$fixture/bin" "$fixture/mock" "$fixture/source" \
  "$fixture/packages/tangram"
export MISE_PROJECT_ROOT="$fixture" TEST_ROOT="$fixture"
rustc --print target-list >"$fixture/rust-targets"
export PATH="$fixture/mock:$PATH"

cat >"$fixture/mock/rustc" <<'MOCK'
#!/usr/bin/env sh
printf 'host: %s\n' "${TEST_HOST:-aarch64-unknown-linux-gnu}"
MOCK

# Paths with spaces exercise argument encoding at the Cargo boundary.
mkdir -p "$fixture/sandbox rootfs/opt/tangram/"{bin,lib}
touch "$fixture/sandbox rootfs/opt/tangram/bin/tangram"
mkdir -p "$fixture/v8/lib"
touch "$fixture/v8/lib/librusty_v8.a"
mkdir -p "$fixture/llvm tools/bin"
for tool in clang clang++ llvm-ar llvm-ranlib ld.lld ld64.lld; do
  printf '#!/usr/bin/env sh\nexit 0\n' >"$fixture/llvm tools/bin/$tool"
  chmod +x "$fixture/llvm tools/bin/$tool"
done

export CC="$fixture/llvm tools/bin/clang"
export CXX="$fixture/llvm tools/bin/clang++"
export AR="$fixture/llvm tools/bin/llvm-ar"
export RANLIB="$fixture/llvm tools/bin/llvm-ranlib"
export TANGRAM_LINKER="$fixture/llvm tools/bin/ld.lld"
export TANGRAM_SANDBOX_ROOTFS="$fixture/sandbox rootfs"
export RUSTY_V8_ARCHIVE="$fixture/v8/lib/librusty_v8.a"

cat >"$fixture/mock/cargo" <<'MOCK'
#!/usr/bin/env bash
set -eu
[[ "$RUSTY_V8_ARCHIVE" == "$TEST_ROOT/v8/lib/librusty_v8.a" ]]
[[ "$CC" == "$TEST_ROOT/llvm tools/bin/clang" ]]
[[ "$CXX" == "$TEST_ROOT/llvm tools/bin/clang++" ]]
[[ "$AR" == "$TEST_ROOT/llvm tools/bin/llvm-ar" ]]
[[ "$RANLIB" == "$TEST_ROOT/llvm tools/bin/llvm-ranlib" ]]

host=${TEST_HOST:-aarch64-unknown-linux-gnu}
if [[ $host == *-unknown-linux-gnu ]]; then
  [[ $TANGRAM_SANDBOX_ROOTFS == "$TEST_ROOT/sandbox rootfs" ]]
fi

key="CARGO_TARGET_${host//-/_}_LINKER"
key=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
[[ ${!key} == "$CC" ]]

linker=ld.lld
[[ $host != *-apple-darwin ]] || linker=ld64.lld
expected=$(printf '%s\x1f%s' -C \
  "link-arg=-fuse-ld=$TEST_ROOT/llvm tools/bin/$linker")
if [[ $host == *-apple-darwin ]]; then
  expected+=$(printf '\x1f%s\x1f%s\x1f%s\x1f%s' \
    -C link-arg=-isysroot -C "link-arg=$TEST_ROOT/sdk with spaces")
fi
[[ $CARGO_ENCODED_RUSTFLAGS == "$expected" ]]
if [[ ${FAIL_CARGO:-} == yes ]]; then exit 24; fi

while [[ $# -gt 0 ]]; do
  if [[ $1 == --target-dir ]]; then shift; target=$1; fi
  shift
done
mkdir -p "$target/release"
printf '#!/usr/bin/env sh\nprintf "fixture tangram\\n"\n' \
  >"$target/release/tangram"
MOCK

chmod +x "$fixture/mock/"*
# A failed source copy must be retryable without a published cache entry.
export TEST_COMMIT=1111111111111111111111111111111111111111
export TANGRAM_SOURCE="$fixture/source/$TEST_COMMIT"
mkdir "$fixture/source/$TEST_COMMIT"
touch "$fixture/source/$TEST_COMMIT/"{Cargo.toml,Cargo.lock}
if TANGRAM_SOURCE="$fixture/missing/$TEST_COMMIT" \
  bash "$root/packages/tangram/build.sh"; then exit 1; fi
[[ ! -e "$fixture/.build/tangram/verified-$TEST_COMMIT" ]]
bash "$root/packages/tangram/build.sh"

# Direct invocation must resolve the root without Mise or a root working directory.
cp "$root/packages/tangram/build.sh" "$fixture/packages/tangram/"
(
  unset MISE_PROJECT_ROOT
  cd "$fixture/mock"
  bash ../packages/tangram/build.sh
)
[[ ! -e "$fixture/source/$TEST_COMMIT/target" ]]

# Repeated builds reuse the writable source copy for the same commit.
touch "$fixture/.build/tangram/verified-$TEST_COMMIT/reused"

# The archive declarations are the support contract. Exercise every configured
# host through the build boundary so new pins cannot drift from its allowlist.
# Bun is already a bootstrap dependency and parses TOML without text scraping.
bun - "$root/mise.toml" >"$fixture/hosts" <<'JS'
const config = Bun.TOML.parse(await Bun.file(process.argv[2]).text());
const tools = config.tools;
for (const [platform, archive] of Object.entries(tools["http:rusty-v8"].platforms)) {
  if (!tools["http:llvm"].platforms[platform] ||
      (platform.startsWith("linux-") && !tools["http:tangram-sandbox"].platforms[platform])) {
    throw new Error(`Incomplete bootstrap inputs for ${platform}`);
  }
  // The upstream archive filename carries the Rust target triple.
  const match = new URL(archive.url).pathname.match(/\/librusty_v8_release_(.+)\.a\.gz$/);
  if (!match) throw new Error(`Unrecognized V8 archive for ${platform}`);
  console.log(match[1]);
}
JS
[[ -s "$fixture/hosts" ]]
while IFS= read -r host; do
  linker=ld.lld
  [[ $host != *-apple-darwin ]] || linker=ld64.lld
  SDKROOT="$fixture/sdk with spaces" TEST_HOST="$host" \
    TANGRAM_LINKER="$fixture/llvm tools/bin/$linker" \
    bash "$root/packages/tangram/build.sh"
done <"$fixture/hosts"
[[ -e "$fixture/.build/tangram/verified-$TEST_COMMIT/reused" ]]

# Check the opposite direction for every target known to the pinned compiler:
# a host without a configured archive must fail before Cargo is invoked.
# The target vocabulary was captured before PATH selected the compiler mock.
while IFS= read -r host; do
  if grep -Fxq "$host" "$fixture/hosts"; then continue; fi
  if TEST_HOST="$host" FAIL_CARGO=yes bash "$root/packages/tangram/build.sh" \
    >"$fixture/unsupported-host.log" 2>&1; then
    echo "Accepted unpinned Rust host: $host" >&2
    exit 1
  fi
  grep -Fq "No pinned V8 archive for Rust host: $host" "$fixture/unsupported-host.log"
done <"$fixture/rust-targets"

# Reject missing tool executables before attempting compilation.
chmod -x "$fixture/llvm tools/bin/ld.lld"
if bash "$root/packages/tangram/build.sh"; then exit 1; fi
chmod +x "$fixture/llvm tools/bin/ld.lld"

# A new source identity must get a fresh writable copy.
export TEST_COMMIT=2222222222222222222222222222222222222222
export TANGRAM_SOURCE="$fixture/source/$TEST_COMMIT"
mkdir "$fixture/source/$TEST_COMMIT"
touch "$fixture/source/$TEST_COMMIT/"{Cargo.toml,Cargo.lock}
bash "$root/packages/tangram/build.sh"
[[ ! -e "$fixture/.build/tangram/verified-$TEST_COMMIT/reused" ]]

# Input and compilation failures must preserve the previously published binary.
printf 'original\n' >"$fixture/bin/tg"
if TANGRAM_SANDBOX_ROOTFS="$fixture/missing rootfs" \
  bash "$root/packages/tangram/build.sh"; then exit 1; fi
[[ $(cat "$fixture/bin/tg") == original ]]
rm "$fixture/sandbox rootfs/opt/tangram/bin/tangram"
if bash "$root/packages/tangram/build.sh"; then exit 1; fi
[[ $(cat "$fixture/bin/tg") == original ]]
touch "$fixture/sandbox rootfs/opt/tangram/bin/tangram"
if FAIL_CARGO=yes bash "$root/packages/tangram/build.sh"; then exit 1; fi
[[ $(cat "$fixture/bin/tg") == original ]]

# A rejected contender must never remove another build's lock.
mkdir "$fixture/.build/tangram/.lock"
if bash "$root/packages/tangram/build.sh"; then exit 1; fi
[[ -d "$fixture/.build/tangram/.lock" ]]
rmdir "$fixture/.build/tangram/.lock"

echo "Tangram publication, cache identity, retries, and locking passed"
