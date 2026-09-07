#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export COMMITLINT_PROJECT_ROOT="$root"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

mkdir "$fixture/bin"
cp "$root/prek.toml" "$fixture/"
# Substitute only the task executor; exercise real prek installation/stashing.
cat >"$fixture/bin/mise" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -E && "$2" == dev && "$3" == run ]]
if [[ "$4" == lint-commit ]]; then
  shift 4
  exec "$COMMITLINT_PROJECT_ROOT/bin/mise" -C "$COMMITLINT_PROJECT_ROOT" \
    -E dev run lint-commit "$@"
fi
[[ $(cat example.txt) == staged ]] || exit 1
printf '%s\n' "$4" >>calls
MOCK

chmod +x "$fixture/bin/mise"
printf 'calls\n' >"$fixture/.gitignore"
printf 'initial\n' >"$fixture/example.txt"
git -C "$fixture" init -q
git -C "$fixture" add .
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm initial
prek -C "$fixture" install
[[ -x "$fixture/.git/hooks/pre-commit" ]]
[[ -x "$fixture/.git/hooks/commit-msg" ]]
printf 'staged\n' >"$fixture/example.txt"
git -C "$fixture" add example.txt
printf 'unstaged\n' >"$fixture/example.txt"
(cd "$fixture" && .git/hooks/pre-commit)
[[ $(cat "$fixture/example.txt") == unstaged ]]
[[ $(git -C "$fixture" show :example.txt) == staged ]]
[[ $(cat "$fixture/calls") == "$(printf 'lint\nformat-check\ntest')" ]]

# A failing task must fail prek, and the unstaged file must remain intact.
if prek -C "$fixture" run --all-files >"$fixture/calls" 2>&1; then
  echo 'prek accepted a failing task' >&2
  exit 1
fi
[[ $(cat "$fixture/example.txt") == unstaged ]]

# Exercise the real commitlint config through the installed commit-msg hook.
message="$fixture/commit message.txt"
printf 'feat(seed): verify downloaded tools\n' >"$message"
(cd "$fixture" && .git/hooks/commit-msg "$message")
printf 'update tools\n' >"$message"
if (cd "$fixture" && .git/hooks/commit-msg "$message") \
  >"$fixture/commitlint.log" 2>&1; then
  echo 'commit-msg hook accepted a non-conventional message' >&2
  exit 1
fi
grep -q 'type-empty' "$fixture/commitlint.log"
printf 'unknown: update tools\n' >"$message"
if (cd "$fixture" && .git/hooks/commit-msg "$message") \
  >"$fixture/commitlint.log" 2>&1; then
  echo 'commit-msg hook accepted an unsupported type' >&2
  exit 1
fi
grep -q 'type-enum' "$fixture/commitlint.log"
echo "Installed hook uses Mise tasks, rejects failures," \
  "preserves partial staging, and validates commit messages"
