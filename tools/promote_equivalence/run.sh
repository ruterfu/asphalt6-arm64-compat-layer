#!/bin/sh
# usage: run.sh WORK_DIR TRIALS module.cpp...   (macOS arm64, from the repository root)
# Builds orig/promoted copies of each module beside the driver and diffs them.
set -eu
WORK=$1; TRIALS=$2; shift 2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$WORK/promoted" "$WORK/obj"
CXX="xcrun clang++ -std=c++17 -O2 -fno-strict-aliasing -fno-exceptions -fno-rtti -fno-fast-math -ffp-contract=off -Wno-unused-label -Wno-unused-but-set-variable -I$ROOT/aot/runtime -I$ROOT/aot/math/include"
if [ ! -f "$WORK/obj/math.a" ]; then
    for f in arm_float.c support/fatal.c vendor/fpu/softfloat.c; do
        xcrun clang -O2 -std=c11 -DTARGET_ARM=1 -DAS6_FORCE_SOFTFLOAT=1 -fno-fast-math -ffp-contract=off \
            -I"$ROOT/aot/math/include" -I"$ROOT/aot/math/support" -I"$ROOT/aot/math/vendor/include" \
            -c "$ROOT/aot/math/$f" -o "$WORK/obj/$(basename "$f" .c).o"
    done
    xcrun ar rcs "$WORK/obj/math.a" "$WORK/obj/arm_float.o" "$WORK/obj/fatal.o" "$WORK/obj/softfloat.o"
fi
[ -f "$WORK/obj/driver.o" ] || $CXX -c "$ROOT/tools/promote_equivalence/driver.cpp" -o "$WORK/obj/driver.o"
for module in "$@"; do
    name=$(basename "$module" .cpp)
    python3 -I "$ROOT/scripts/as6build/promote.py" "$ROOT/build/generated/aot" "$WORK/promoted" --only "$name.cpp" 2>/dev/null
    lookup="as6_aot_lookup_$name"
    $CXX -D"$lookup=orig_lookup" -c "$ROOT/build/generated/aot/$name.cpp" -o "$WORK/obj/$name.orig.o"
    $CXX -D"$lookup=prom_lookup" -c "$WORK/promoted/$name.cpp" -o "$WORK/obj/$name.prom.o"
    grep -oE 'case 0x[0-9a-f]+ULL' "$ROOT/build/generated/aot/$name.cpp" | sed 's/case 0x//;s/ULL//' > "$WORK/obj/$name.keys"
    xcrun clang++ "$WORK/obj/driver.o" "$WORK/obj/$name.orig.o" "$WORK/obj/$name.prom.o" "$WORK/obj/math.a" -o "$WORK/obj/$name.test"
    printf '%s ' "$name"; "$WORK/obj/$name.test" "$WORK/obj/$name.keys" "$TRIALS"
    rm -f "$WORK/obj/$name.orig.o" "$WORK/obj/$name.prom.o" "$WORK/obj/$name.test"
done
