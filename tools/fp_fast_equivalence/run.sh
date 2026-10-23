#!/bin/sh
# Compares every hardware fast path of aot/math/arm_float.c with the pure
# software path (bits, status and FPSCR). Must run on an arm64 Mac (the fast
# paths are aarch64-only). Optional argument: rounds (30 calls each).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FLAGS="-I$ROOT/aot/math/include -I$ROOT/aot/math/support -I$ROOT/aot/math/vendor/include
       -DTARGET_ARM=1 -DAS6_FORCE_SOFTFLOAT=1 -O2 -UNDEBUG -fno-fast-math -ffp-contract=off -fno-common"
clang $FLAGS -c "$ROOT/aot/math/arm_float.c" -o "$OUT/fast.o"
clang $FLAGS -DAS6_NO_FAST_NEON -c "$ROOT/aot/math/arm_float.c" -o "$OUT/ref0.o"
# The reference copy's public symbols get a ref_ prefix.
nm -gU "$OUT/ref0.o" | awk '/ _as6_/{print $3}' | while read -r sym; do
    echo "$sym _ref_${sym#_}"; done > "$OUT/aliases"
ALIASES=$(awk '{printf " -alias %s %s -exported_symbol %s", $1, $2, $2}' "$OUT/aliases")
ld -r "$OUT/ref0.o" -o "$OUT/ref.o" $ALIASES
clang $FLAGS -c "$ROOT/aot/math/vendor/fpu/softfloat.c" -o "$OUT/softfloat.o"
clang $FLAGS -c "$ROOT/aot/math/support/fatal.c" -o "$OUT/fatal.o"
clang $FLAGS -include stdlib.h "$(dirname "$0")/fp_fast.c" "$OUT/fast.o" "$OUT/ref.o" "$OUT/softfloat.o" "$OUT/fatal.o" -o "$OUT/test"
"$OUT/test" "$@"
