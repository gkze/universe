#!/usr/bin/env bash
set -euo pipefail

project_dir="${MISE_PROJECT_ROOT:-$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd
)}"
cache_dir="$project_dir/.build/tangram"
out_dir="$project_dir/bin"
source_dir=${TANGRAM_SOURCE:?Use bin/mise run build-tangram}
commit=${source_dir##*/}

[[ $commit =~ ^[[:xdigit:]]{40}$ ]] || {
  echo "Mise source installation must be keyed by a full commit hash" >&2
  exit 1
}
src_dir="$cache_dir/verified-$commit"
staging=""
publish_dir=""

cleanup() {
  [[ -z $staging ]] || rm -rf -- "$staging"
  [[ -z $publish_dir ]] || rm -rf -- "$publish_dir"
  rmdir -- "$cache_dir/.lock"
}

configure_toolchain() {
  local tool linker_var
  local -a rustflags

  # Mise owns installed tool paths; this adapter validates the build boundary.
  for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$TANGRAM_LINKER"; do
    [[ -x $tool ]] || {
      echo "Missing bootstrap tool: $tool" >&2
      exit 1
    }
  done

  linker_var="CARGO_TARGET_$(
    printf '%s' "$host" | tr '[:lower:]-' '[:upper:]_'
  )_LINKER"
  export "$linker_var=$CC"

  # Encode dynamic paths without splitting spaces. Do not pass --target: Cargo
  # must apply these flags to host build scripts and proc macros as well.
  rustflags=("-C" "link-arg=-fuse-ld=$TANGRAM_LINKER")
  if [[ $host == *-apple-darwin ]]; then
    : "${SDKROOT:?Activate SDK: bin/mise run build-tangram}"
    rustflags+=("-C" "link-arg=-isysroot" "-C" "link-arg=$SDKROOT")
    echo ">> SDK: $SDKROOT"
  fi

  export CARGO_ENCODED_RUSTFLAGS
  CARGO_ENCODED_RUSTFLAGS=$(
    IFS=$'\x1f'
    echo "${rustflags[*]}"
  )
  echo ">> C compiler: $CC"
  echo ">> linker: $TANGRAM_LINKER"
}

prepare_source() {
  [[ ! -d $src_dir ]] || return 0

  staging=$(mktemp -d "$cache_dir/.source.XXXXXX")
  cp -R "$source_dir/." "$staging/"
  test -f "$staging/Cargo.toml"
  test -f "$staging/Cargo.lock"

  # Give oxlint its own root so Universe's ignored .build does not hide sources.
  git -C "$staging" init -q
  mv -- "$staging" "$src_dir"
  staging=""
}

build_and_publish() {
  local target_dir="$src_dir/target"
  (
    cd "$src_dir"
    cargo build --locked --release --package tangram_cli \
      --target-dir "$target_dir"
  )

  # Validate a staged executable before atomically replacing the published CLI.
  mkdir -p "$out_dir"
  publish_dir=$(mktemp -d "$out_dir/.tangram.XXXXXX")
  install -m 0755 "$target_dir/release/tangram" "$publish_dir/tg"
  "$publish_dir/tg" --version
  mv -f -- "$publish_dir/tg" "$out_dir/tg"
  echo ">> built: $out_dir/tg"
}

# Hold the lock across source preparation, compilation, and publication.
mkdir -p "$cache_dir"
mkdir "$cache_dir/.lock" || {
  echo "Tangram build already locked: $cache_dir/.lock" >&2
  exit 1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

test -f "$RUSTY_V8_ARCHIVE"
host=$(rustc -vV | sed -n 's/^host: //p')
# Keep direct invocations within the pinned archive support contract.
# tests/build.sh checks both configured hosts and rejected compiler targets.
case "$host" in
  aarch64-apple-darwin | aarch64-unknown-linux-gnu | \
    x86_64-unknown-linux-gnu) ;;
  *)
    echo "No pinned V8 archive for Rust host: $host" >&2
    exit 1
    ;;
esac

configure_toolchain
if [[ $host == *-unknown-linux-gnu ]]; then
  test -f "$TANGRAM_SANDBOX_ROOTFS/opt/tangram/bin/tangram"
  test -d "$TANGRAM_SANDBOX_ROOTFS/opt/tangram/lib"
  echo ">> sandbox rootfs: $TANGRAM_SANDBOX_ROOTFS"
fi

echo ">> building tangram @ $commit"
prepare_source
build_and_publish
