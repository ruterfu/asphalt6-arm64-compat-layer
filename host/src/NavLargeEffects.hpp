#pragma once
#include <cstddef>
#include <cstdint>
#include <array>

namespace as6::navigation::large_effects {
struct Point {float x,y,z;};
struct PointSpan {const Point *points=nullptr;std::size_t count=0;};
struct FloatMode {
    // Scalar DIV/compare policy. Pair operations retain original RNE/FZ/DN.
    std::uint8_t rounding=0;
    bool flushToZero=false,defaultNaN=false;
};
enum class Status:std::uint8_t {UnsupportedInput,UnsupportedFloatMode,ArithmeticFailure,Complete,CapacityDeclined};
struct FloatingPointEffects {
 std::uint32_t exceptionDelta=0,nzcv=0;
 bool compared=false;
};
struct Result {
    Status status=Status::UnsupportedInput;
    std::int32_t first=-1,second=-1;
    bool usedNearestPointFallback=false;
    bool usedNativeArithmetic=false;
    FloatingPointEffects floatingPoint;
    std::uint64_t originalInstructions=0;
    // Original private scratch writes: initial -1, then each accepted predecessor.
    std::array<std::int32_t,50> scratchWrites{};
    std::uint8_t scratchWriteCount=0;
};
// Isolated bounded effects derivative (1..65536 points), never a live Host target.
// Caller owns the point span. No allocation; at most49 main improvements are
// recorded after the initial scratch write. CapacityDeclined publishes no effects.
// Exposes low-lane exception union, final scalar comparison NZCV, instruction
// ledger and original scratch-store sequence for an independently gated adapter.
// Nonzero high-lane poison requires a separate observational projection proof.
// Native failure uses a sticky status and whole-function exact restart; no throw.
// Unusual values/intermediates and non-RNE scalar modes use exact C math.
// This API still describes ordered indices, not complete original FP effects.
// Returns the ordered cyclic segment indices. No guest addresses, register
// transport, data writes, callbacks or public ABI/odd-lane FP-status claim.
// A future adapter must prove the result object does not alias any input.
Result closestSegment(PointSpan,Point position,FloatMode={}) noexcept;
}
