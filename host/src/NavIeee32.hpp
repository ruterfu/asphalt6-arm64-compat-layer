#pragma once
#include <cstdint>
namespace as6::math::ieee32 {
enum class Rounding:std::uint8_t {Nearest,PlusInfinity,MinusInfinity,TowardZero};
struct Mode {
 Rounding rounding=Rounding::Nearest;
 bool flushToZero=false,defaultNaN=false,alternativeHalf=false;
 std::uint8_t exceptionEnables=0,vectorLength=0,vectorStride=0;
};
struct Environment {Mode mode;std::uint32_t exceptionBits=0,nzcv=0;};
enum class Operation:std::uint8_t {
 AddPairLow,SubtractPairLow,MultiplyPairLow,Divide,Absolute,
 FromSigned,ToSignedTowardZero,CompareQuiet,CompareSignaling
};
enum class Relation:std::uint8_t {Less,Equal,Greater,Unordered};
enum class Path:std::uint8_t {Native,Software,Bits};
enum class Status:std::uint8_t {Complete,UnsupportedEnvironment,LibraryRejected};
struct Result {
 Status status=Status::LibraryRejected;
 std::uint32_t bits=0;
 Environment environment;
 Relation relation=Relation::Equal;
 Path path=Path::Software;
};
// Shared IEEE32 mathematical backend for standalone source libraries; no App integration.
// Values are IEEE32/integer bit patterns. PairLow arithmetic deliberately uses
// the original NEON RNE/FZ/DN policy with a harmless zero companion lane.
// This reproduces low mathematical data, not original odd-lane status effects.
Result evaluate(Operation,std::uint32_t a,std::uint32_t b,Environment={},bool nativeFast=true) noexcept;
bool equal(Relation) noexcept;
bool notEqual(Relation) noexcept;
bool negativeComparison(Relation) noexcept; // Less only; unordered is false.
bool notNegativeComparison(Relation) noexcept; // Equal/Greater/Unordered.
bool lessIncludingUnordered(Relation) noexcept;
bool atMostIncludingUnordered(Relation) noexcept;
bool greaterOrdered(Relation) noexcept;
bool atLeastOrdered(Relation) noexcept;
}
