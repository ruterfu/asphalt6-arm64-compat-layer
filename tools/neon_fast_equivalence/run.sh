#!/bin/sh
# Compares the hardware fast path of as6_neon_{add,sub,mul}_2f32 with the
# pure software path (bits and FPSCR) on 60M random and boundary inputs.
# Must run on an arm64 Mac (the fast path is aarch64-only).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FLAGS="-I$ROOT/aot/math/include -I$ROOT/aot/math/support -I$ROOT/aot/math/vendor/include
       -DTARGET_ARM=1 -DAS6_FORCE_SOFTFLOAT=1 -O2 -UNDEBUG -fno-fast-math -ffp-contract=off -fno-common"
clang $FLAGS -c "$ROOT/aot/math/arm_float.c" -o "$OUT/fast.o"
clang $FLAGS -DAS6_NO_FAST_NEON -Das6_neon_add_2f32=ref_add -Das6_neon_sub_2f32=ref_sub \
      -Das6_neon_mul_2f32=ref_mul -c "$ROOT/aot/math/arm_float.c" -o "$OUT/ref0.o"
ld -r "$OUT/ref0.o" -o "$OUT/ref.o" -exported_symbol _ref_add -exported_symbol _ref_sub -exported_symbol _ref_mul
clang $FLAGS -c "$ROOT/aot/math/vendor/fpu/softfloat.c" -o "$OUT/softfloat.o"
clang $FLAGS -c "$ROOT/aot/math/support/fatal.c" -o "$OUT/fatal.o"
clang $FLAGS "$(dirname "$0")/neon_fast.c" "$OUT/fast.o" "$OUT/ref.o" "$OUT/softfloat.o" "$OUT/fatal.o" -o "$OUT/test"
"$OUT/test"
