#!/usr/bin/env bash
# Rebuild libghostty.a from the per-target archives in .zig-cache, working
# around Xcode 26+ libtool silently dropping zig 0.15 objects that are not
# 8-byte aligned. Approach adapted from menemy/macuake (MIT).
#
# Usage: tools/fix-lib.sh <output.a>
set -euo pipefail

GHOSTTY_DIR="$(cd "$(dirname "$0")/../vendor/ghostty" && pwd)"
OUT="${1:?usage: fix-lib.sh <output.a>}"

MERGE="$(mktemp -d)"

for archive in "$GHOSTTY_DIR"/.zig-cache/o/*/lib*.a; do
  [ -f "$archive" ] || continue
  base="$(basename "$archive")"
  # Skip the fat (multi-arch) archive and the standalone vt parser lib.
  [ "$base" = "libghostty-fat.a" ] && continue
  echo "$base" | grep -q "libghostty-vt" && continue

  # ar cannot extract fat archives; keep single-arch arm64 members only.
  arch_count="$(lipo -info "$archive" 2>/dev/null | grep -oE 'arm64|x86_64' | wc -l | tr -d ' ')"
  [ "$arch_count" -gt 1 ] && continue
  file_arch="$(lipo -info "$archive" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1 || true)"
  [ "$file_arch" = "arm64" ] || continue

  # Keep macOS objects only (LC_BUILD_VERSION platform 1 = MACOSX).
  platform="$( (otool -l "$archive" 2>/dev/null || true) | awk '/^ *platform /{print $2; exit}' )"
  [ -z "$platform" ] && continue
  [ "$platform" = "1" ] || continue

  SUB="$(mktemp -d)"
  (cd "$SUB" && ar x "$archive" && chmod 644 ./*.o 2>/dev/null || true)
  prefix="${base%.a}_"
  for obj in "$SUB"/*.o; do
    [ -f "$obj" ] || continue
    name="${prefix}$(basename "$obj")"
    [ ! -f "$MERGE/$name" ] && mv "$obj" "$MERGE/$name"
  done
  rm -rf "$SUB"
done

count="$(ls "$MERGE"/*.o 2>/dev/null | wc -l | tr -d ' ')"
echo "merged $count objects"
[ "$count" -gt 0 ]

rm -f "$OUT"
ar rcs "$OUT" "$MERGE"/*.o
ranlib "$OUT"
echo "wrote $OUT"
