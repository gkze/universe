#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Run assertions inside the same embedded Lua runtime as real plugins.
mkdir "$fixture/plugin"
cp "$root/packages/mise-apple-sdk/metadata.lua" "$fixture/plugin/"
cp "$root/packages/mise-apple-sdk/releases.lua" "$fixture/plugin/"
cp -R "$root/packages/mise-apple-sdk/hooks" "$fixture/plugin/"
cp "$fixture/plugin/hooks/available.lua" \
  "$fixture/plugin/original_available.lua"
cp -R "$root/packages/mise-apple-sdk/tests" "$fixture/plugin/"
printf 'PLUGIN.Available = require("tests.behavior")\n' \
  >"$fixture/plugin/hooks/available.lua"
printf '[plugins]\n"vfox:sdk-tests" = "./plugin"\n' >"$fixture/mise.toml"
export MISE_DATA_DIR="$fixture/data"
export MISE_CACHE_DIR="$fixture/cache"
export MISE_TRUSTED_CONFIG_PATHS="$fixture"
"$root/bin/mise" plugins link sdk-tests "$fixture/plugin"
result=$("$root/bin/mise" -C "$fixture" ls-remote sdk-tests)
[[ "$result" == "passed" ]]
echo "Apple SDK behavior tests passed in Mise Lua"
