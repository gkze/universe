#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  arm64) expected='ARM aarch64' ;;
  x64) expected='x86-64' ;;
  *)
    echo 'Expected arm64 or x64 test target' >&2
    exit 2
    ;;
esac

# Input is a read-only source snapshot, never the live macOS checkout.
tar xf /input/source.tar -C /workspace
cd /workspace
git init -q
export MISE_YES=1
export MISE_TRUSTED_CONFIG_PATHS=/workspace
# The default configuration declares only Tangram's build inputs.
bin/seed.sh
bin/mise install
bin/mise run build-tangram
binary=$(file bin/tg)
printf '%s\n' "$binary"
[[ $binary == *'ELF 64-bit'* && $binary == *"$expected"* ]]
bin/tg --version
echo 'Linux compilation and CLI startup passed'
