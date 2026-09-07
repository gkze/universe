#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Substitute host detection and executables; preserve real shell dispatch.
mkdir -p "$fixture/bin" "$fixture/apps/seed" "$fixture/mock"
cp "$root/bin/seed.sh" "$fixture/bin/"
cat >"$fixture/mock/uname" <<'MOCK'
#!/usr/bin/env sh
case "$1" in
  -s) printf '%s\n' "$TEST_OS" ;;
  -m) printf '%s\n' "$TEST_ARCH" ;;
esac
MOCK
for suffix in aarch64-macos x86_64-macos aarch64-linux-musl \
  x86_64-linux-musl; do
  cat >"$fixture/bin/universe-seed-$suffix" <<'MOCK'
#!/usr/bin/env sh
printf '%s\n' "${0##*/}" "$@"
MOCK
done
chmod +x "$fixture/mock/uname" "$fixture/bin/"*

# Exercise absolute, relative, and PATH invocation with argument boundaries intact.
for platform in 'Darwin arm64 aarch64-macos' 'Darwin x86_64 x86_64-macos' \
  'Linux aarch64 aarch64-linux-musl' 'Linux x86_64 x86_64-linux-musl'; do
  read -r TEST_OS TEST_ARCH suffix <<<"$platform"
  export TEST_OS TEST_ARCH
  result=$(PATH="$fixture/mock:$PATH" "$fixture/bin/seed.sh" \
    'space argument' '--flag')
  expected=$(printf '%s\n' "universe-seed-$suffix" \
    'space argument' '--flag')
  [[ "$result" == "$expected" ]]

  result=$(cd "$fixture/mock" && PATH="$fixture/mock:$PATH" \
    ../bin/seed.sh 'space argument' '--flag')
  [[ "$result" == "$expected" ]]

  result=$(cd "$fixture/apps/seed" && PATH="$fixture/mock:$fixture/bin:$PATH" \
    seed.sh 'space argument' '--flag')
  [[ "$result" == "$expected" ]]
done

# Unsupported operating systems fail with a useful diagnostic.
if TEST_OS=unsupported TEST_ARCH=unknown PATH="$fixture/mock:$PATH" \
  "$fixture/bin/seed.sh" >"$fixture/output" 2>&1; then
  exit 1
fi
grep -q 'unsupported platform' "$fixture/output"

echo "Seed platform dispatch and argument forwarding passed"
