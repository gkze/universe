#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/repo with spaces/packages/linux-bootstrap" \
  "$fixture/repo with spaces/bin"
repo="$fixture/repo with spaces"
cp "$root/packages/linux-bootstrap/run.sh" \
  "$repo/packages/linux-bootstrap/"
git -C "$repo" init -q
printf '.build/\nbin/tg\n' >"$repo/.gitignore"
touch "$repo/.root" "$repo/new file.sh" "$repo/deleted.sh" "$repo/bin/tg"
git -C "$repo" add deleted.sh
rm "$repo/deleted.sh"
cat >"$repo/bin/mise" <<'MOCK'
#!/usr/bin/env bash
printf '%s/container\n' "$TEST_FIXTURE"
MOCK
cat >"$fixture/container" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_FIXTURE/calls"
if [[ $1 != run ]]; then exit 0; fi
args=" $* "
[[ $args == *" --platform $TEST_PLATFORM "* ]]
if [[ $TEST_PLATFORM == linux/amd64 ]]; then
  [[ $args == *' --rosetta '* ]]
else
  [[ $args != *' --rosetta '* ]]
fi
while [[ $# -gt 0 ]]; do
  if [[ $1 == --mount ]]; then
    shift
    [[ $1 == type=bind,source=*,target=/input,readonly ]]
    source=${1#type=bind,source=}
    source=${source%,target=/input,readonly}
  fi
  shift
done
listing=$(tar tf "$source/source.tar")
[[ $listing == *'new file.sh'* && $listing == *'.root'* ]]
[[ $listing != *'bin/tg'* && $listing != *'deleted.sh'* ]]
exit "${TEST_EXIT:-0}"
MOCK

chmod +x "$repo/bin/mise" "$fixture/container"
export TEST_FIXTURE="$fixture"
TEST_PLATFORM=linux/arm64 bash "$repo/packages/linux-bootstrap/run.sh" arm64
if TEST_PLATFORM=linux/amd64 TEST_EXIT=23 \
  bash "$repo/packages/linux-bootstrap/run.sh" x64; then
  echo 'Runner swallowed guest failure' >&2
  exit 1
else
  [[ $? == 23 ]]
fi
[[ -f "$repo/bin/tg" ]]
for run in "$repo/.build/linux-bootstrap/"*; do
  [[ ! -e "$run/source.tar" && -f "$run/build.log" ]]
done
[[ $(grep -c '^image delete --force ' "$fixture/calls") == 2 ]]
[[ $(grep -c '^run ' "$fixture/calls") == 2 ]]
echo 'Linux runner snapshot, platform, failure, and cleanup checks passed'
