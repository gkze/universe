#!/usr/bin/env sh
os=$(uname -s)
arch=$(uname -m)

# Normalize platform names
[ "$os" = Darwin ] && os=macos
[ "$arch" = arm64 ] && arch=aarch64

# Map to binary suffix
case "$os" in
  Linux) suffix=$arch-linux-musl ;;
  macos) suffix=$arch-macos ;;
  *)
    echo "seed: unsupported platform $os-$arch" >&2
    exit 1
    ;;
esac

exec "$(dirname "$0")/universe-seed-$suffix" "$@"
