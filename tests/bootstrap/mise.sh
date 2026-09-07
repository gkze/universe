#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Resolve platform templates using the real host, without build-test mocks.
export TEST_NATIVE_SYSTEM TEST_COMMIT=2222222222222222222222222222222222222222
TEST_NATIVE_SYSTEM=$(uname -s)

# Exercise the actual task's environment templates with Mise and disposable
# installations. The task command reaches an assertion script instead of Cargo.
config_project="$fixture/mise project"
export TEST_CONFIG_DATA="$fixture/mise data"
mkdir -p "$config_project/packages/tangram" \
  "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin" \
  "$TEST_CONFIG_DATA/installs/http-rusty-v8/fixture/lib" \
  "$TEST_CONFIG_DATA/installs/http-tangram-source/$TEST_COMMIT" \
  "$TEST_CONFIG_DATA/installs/http-tangram-sandbox/fixture"
cp "$root/mise.toml" "$config_project/"
cat >"$config_project/mise.local.toml" <<TOML
[tools]
rust = { version = 'fixture', os = ['windows'] }
bun = { version = 'fixture', os = ['windows'] }
apple-sdk = { version = 'fixture', os = ['windows'] }
'http:llvm' = 'fixture'
'http:rusty-v8' = 'fixture'
'http:tangram-source' = '$TEST_COMMIT'
'http:tangram-sandbox' = { version = 'fixture', os = ['linux'] }
TOML
cat >"$config_project/packages/tangram/build.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[[ $TANGRAM_SOURCE == "$TEST_CONFIG_DATA/installs/http-tangram-source/$TEST_COMMIT" ]]
[[ $CC == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/clang" ]]
[[ $CXX == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/clang++" ]]
[[ $AR == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/llvm-ar" ]]
[[ $RANLIB == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/llvm-ranlib" ]]
[[ $RUSTY_V8_ARCHIVE == "$TEST_CONFIG_DATA/installs/http-rusty-v8/fixture/lib/librusty_v8.a" ]]
case "$TEST_NATIVE_SYSTEM" in
  Darwin)
    [[ $TANGRAM_LINKER == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/ld64.lld" ]]
    [[ -z $TANGRAM_SANDBOX_ROOTFS ]]
    ;;
  Linux)
    [[ $TANGRAM_LINKER == "$TEST_CONFIG_DATA/installs/http-llvm/fixture/bin/ld.lld" ]]
    [[ $TANGRAM_SANDBOX_ROOTFS == "$TEST_CONFIG_DATA/installs/http-tangram-sandbox/fixture" ]]
    ;;
  *) exit 1 ;;
esac
CHECK

(
  cd "$config_project"
  MISE_DATA_DIR="$TEST_CONFIG_DATA" MISE_CONFIG_DIR="$fixture/mise config" \
    MISE_CACHE_DIR="$fixture/mise cache" MISE_STATE_DIR="$fixture/mise state" \
    MISE_GLOBAL_CONFIG_FILE="$fixture/mise config/global.toml" \
    MISE_YES=1 MISE_TRUSTED_CONFIG_PATHS="$fixture" MISE_AUTO_INSTALL=0 \
    env -u MISE_ENV "$root/bin/mise" run --skip-tools build-tangram
)

echo "Mise bootstrap tool paths passed"
