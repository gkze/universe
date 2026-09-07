#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/packages/mise-apple-sdk"
touch "$fixture/bin/seed.sh"

# Exercise cleanup only against disposable artifacts, retaining source files.
mkdir -p "$fixture/apps/seed/zig-out" "$fixture/apps/seed/.zig-cache" \
  "$fixture/.build/tangram" "$fixture/.build/unrelated"
touch "$fixture/bin/mise" "$fixture/bin/tg" "$fixture/apps/seed/main.zig"
cp "$root/mise.toml" "$fixture/"
export MISE_TRUSTED_CONFIG_PATHS="$fixture"
for task in clean-zig clean-tangram clean-mise; do
  "$root/bin/mise" -C "$fixture" run "$task"
done
[[ ! -e "$fixture/apps/seed/zig-out" && ! -e "$fixture/apps/seed/.zig-cache" ]]
[[ ! -e "$fixture/.build/tangram" ]]
[[ ! -e "$fixture/bin/mise" && ! -e "$fixture/bin/tg" ]]
[[ -d "$fixture/.build/unrelated" ]]
[[ -f "$fixture/apps/seed/main.zig" && -f "$fixture/bin/seed.sh" ]]

echo "Bootstrap cleanup preserves source and unrelated artifacts"
