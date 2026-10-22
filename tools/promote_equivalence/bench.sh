#!/bin/sh
# usage: bench.sh WORK_DIR module...   (macOS arm64; needs WORK_DIR/obj/math.a from run.sh)
set -eu
W=$1; shift
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CXX="xcrun clang++ -std=c++17 -O2 -fno-strict-aliasing -fno-exceptions -fno-rtti -fno-fast-math -ffp-contract=off -Wno-unused-label -Wno-unused-but-set-variable -I$ROOT/aot/runtime -I$ROOT/aot/math/include"
mkdir -p "$W/promoted" "$W/obj"
$CXX -c "$ROOT/tools/promote_equivalence/bench.cpp" -o "$W/obj/bench.o"
for m in "$@"; do
    python3 -I "$ROOT/scripts/as6build/promote.py" "$ROOT/build/generated/aot" "$W/promoted" --only "$m.cpp" 2>/dev/null
    $CXX -D"as6_aot_lookup_$m=orig_lookup" -c "$ROOT/build/generated/aot/$m.cpp" -o "$W/obj/$m.orig.o" &
    $CXX -D"as6_aot_lookup_$m=prom_lookup" -c "$W/promoted/$m.cpp" -o "$W/obj/$m.prom.o" &
    wait
    # Start at block leaders (fast-path entries); keys are pc<<1 for ARM mode.
    grep -oE 'case 0x[0-9a-f]+u: goto ins_' "$W/promoted/$m.cpp" | sed 's/case 0x//;s/u: goto ins_//' |
        while read pc; do printf '%x\n' $((0x$pc << 1)); done > "$W/obj/$m.keys"
    xcrun clang++ "$W/obj/bench.o" "$W/obj/$m.orig.o" "$W/obj/$m.prom.o" "$W/obj/math.a" -o "$W/obj/$m.bench"
    echo "== $m  text: orig $(xcrun size "$W/obj/$m.orig.o" | awk 'NR==2{print $1}') prom $(xcrun size "$W/obj/$m.prom.o" | awk 'NR==2{print $1}')"
    "$W/obj/$m.bench" "$W/obj/$m.keys"
    echo "-- with direct page view"; "$W/obj/$m.bench" "$W/obj/$m.keys" direct
done
