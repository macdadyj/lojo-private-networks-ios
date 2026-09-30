#!/usr/bin/env bash
# Mirror App/ from the repo into the ext4 build dir (codesign must run on ext4, never NTFS),
# and put the pinned SwiftTerm checkout with our manifest in App/Vendor (docs/ssh-terminal.md §2.2).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${LOJO_BUILD_DIR:-$HOME/.local/share/ios-dev/apps/LojoNetworks}"
SWIFTTERM_URL="https://github.com/migueldeicaza/SwiftTerm.git"
SWIFTTERM_REV="b1262db5b6bea699a8260a8c66999436c508ca56" # v1.11.2, last release without the Metal renderer

case "$(stat -f -c %T "$(dirname "$BUILD_DIR")")" in
  ext2/ext3|ext4|btrfs|xfs) ;;
  *) echo "refusing: $BUILD_DIR is not on ext4/btrfs/xfs (signing breaks on NTFS)" >&2; exit 1 ;;
esac

mkdir -p "$BUILD_DIR"
rsync -a --delete \
  --exclude '.build/' --exclude 'xtool/' --exclude '.sourcekit-lsp/' --exclude '.swiftpm/' --exclude 'Vendor/' \
  "$REPO/App/" "$BUILD_DIR/"

ST="$BUILD_DIR/Vendor/SwiftTerm"
if [[ "$(git -C "$ST" rev-parse HEAD 2>/dev/null || true)" != "$SWIFTTERM_REV" ]]; then
  rm -rf "$ST"
  mkdir -p "$BUILD_DIR/Vendor"
  git clone -q --filter=blob:none "$SWIFTTERM_URL" "$ST" >&2
  git -C "$ST" -c advice.detachedHead=false checkout -q "$SWIFTTERM_REV" >&2
fi
cmp -s "$REPO/vendor/SwiftTerm.Package.swift" "$ST/Package.swift" || cp "$REPO/vendor/SwiftTerm.Package.swift" "$ST/Package.swift"

echo "$BUILD_DIR"
