#!/usr/bin/env bash
# Prepare a project-local zig toolchain in build/zig.
#
# Why: the macOS 27 SDK's math.h no longer defines INFINITY in C++20+,
# which breaks zig 0.15.x's bundled libcxx compilation. We copy the
# homebrew zig@0.15 install and apply a one-line fallback patch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build/zig"

ZIG_SRC=""
for cand in "$(brew --prefix zig@0.15 2>/dev/null || true)" /opt/homebrew/opt/zig@0.15; do
  if [ -n "$cand" ] && [ -x "$cand/bin/zig" ]; then ZIG_SRC="$cand"; break; fi
done
if [ -z "$ZIG_SRC" ]; then
  echo "error: zig 0.15.x not found. Install with: brew install zig@0.15" >&2
  exit 1
fi

if [ -x "$DEST/bin/zig" ] && [ -f "$DEST/.shade-patched" ]; then
  echo "zig already prepared at $DEST"
  exit 0
fi

rm -rf "$DEST"
cp -R "$ZIG_SRC" "$DEST"
chmod -R u+w "$DEST"

python3 - "$DEST/lib/zig/libcxx/include/math.h" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """#    if __has_include_next(<math.h>)
#      include_next <math.h>
#    endif
"""
new = old + """
// [shade] The macOS 27 SDK math.h no longer defines INFINITY in C++20+
// language modes; libc++ headers (e.g. __random/clamp_to_integral.h,
// complex) rely on it being present. Provide a fallback.
#    ifndef INFINITY
#      define INFINITY __builtin_inf()
#    endif
"""
assert s.count(old) == 1, "patch target not found (zig version changed?)"
open(p, "w").write(s.replace(old, new))
PYEOF

touch "$DEST/.shade-patched"
echo "prepared $DEST (from $ZIG_SRC, with libcxx INFINITY patch)"
