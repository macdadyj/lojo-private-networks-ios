#!/usr/bin/env bash
# Mirror App/ from the repo into the ext4 build dir (codesign must run on ext4, never NTFS).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${LOJO_BUILD_DIR:-$HOME/.local/share/ios-dev/apps/LojoNetworks}"

case "$(stat -f -c %T "$(dirname "$BUILD_DIR")")" in
  ext2/ext3|ext4|btrfs|xfs) ;;
  *) echo "refusing: $BUILD_DIR is not on ext4/btrfs/xfs (signing breaks on NTFS)" >&2; exit 1 ;;
esac

mkdir -p "$BUILD_DIR"
rsync -a --delete \
  --exclude '.build/' --exclude 'xtool/' --exclude '.sourcekit-lsp/' --exclude '.swiftpm/' \
  "$REPO/App/" "$BUILD_DIR/"
echo "$BUILD_DIR"
