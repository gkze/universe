#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
case "${1:-}" in
  arm64)
    platform=linux/arm64
    ;;
  x64)
    platform=linux/amd64
    ;;
  *)
    echo 'usage: run.sh {arm64|x64}' >&2
    exit 2
    ;;
esac

run_args=(--rm --platform "$platform")
if [[ $1 == x64 ]]; then run_args+=(--rosetta); fi

container_cli=$(bin/mise -E dev which container)
"$container_cli" system status
mkdir -p .build/linux-bootstrap
staging=$(mktemp -d "$PWD/.build/linux-bootstrap/run-$1.XXXXXX")
image="universe-linux-bootstrap:$(basename "$staging")"

# Keep logs for diagnosis while removing the snapshot and this run's image.
cleanup() {
  local status=$?
  "$container_cli" image delete --force "$image" >/dev/null ||
    echo "Could not remove test image: $image" >&2
  rm -f "$staging/source.tar" "$staging/files"
  echo "Logs: $staging"
  return "$status"
}
trap cleanup EXIT

# New source files are included; deleted and ignored build outputs are omitted.
git ls-files --cached --others --exclude-standard -z |
  while IFS= read -r -d '' path; do
    [[ -f $path || -L $path ]] || continue
    printf '%s\0' "$path"
  done >"$staging/files"
tar --null -T "$staging/files" -cf "$staging/source.tar"

# Unique tags prevent simultaneous runs from selecting each other's image.
"$container_cli" build --platform "$platform" --cpus 4 --memory 4G \
  --tag "$image" packages/linux-bootstrap 2>&1 | tee "$staging/image.log"
"$container_cli" run "${run_args[@]}" \
  --cpus "${LINUX_TEST_CPUS:-8}" --memory "${LINUX_TEST_MEMORY:-16G}" \
  --mount "type=bind,source=$staging,target=/input,readonly" \
  "$image" "$1" 2>&1 | tee "$staging/build.log"
