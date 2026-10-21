#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace as6::geometry::vertex {
struct SourceSpan { const std::uint8_t *bytes=nullptr;std::size_t size=0,stride=0; };
struct ScratchSpan { std::uint8_t *bytes=nullptr;std::size_t size=0,stride=0; };
// x/y/z output rows, each ordered [source x, source y, source z, translation].
struct Affine3x4 { std::array<std::uint32_t,4> x{},y{},z{}; };
struct LoopInput {
    std::uint32_t fpscr=0;
    // Original S7, S9, S11, S13, S15. They are real secondary NEON lanes,
    // including their accumulated exception effects and final S13/S15 values.
    std::array<std::uint32_t,5> oddS{};
};
enum class Status : std::uint32_t { Complete,InvalidInput,UnsupportedEnvironment,
                                  UnsupportedFloat,UnsupportedPlatform };
struct Result {
    Status status=Status::InvalidInput;
    std::uint32_t written=0,fpscr=0;
    std::uint32_t vectorizedVertices=0;
    std::array<std::uint64_t,5> d3ToD7{};
    std::size_t sourceAdvance=0,destinationAdvance=0;
    std::uint32_t remaining=0,r3=0,nzcv=0;
};
// Fixed ordinary mathematical batch for original loop 545abc..545b68.
// Inputs must be stable and source/scratch ranges disjoint. Count is nonzero;
// iterations is a nonzero chunk <= currentCount, strides are bytes >=12.
// No GuestVM, ARM decoder or code image is used.
// Scratch is caller-owned staging, never live game memory: on unsupported
// arithmetic a prefix may have been written, and the caller must publish none.
// Host adaptation separately owns locks, guest address/alias/fault validation,
// stop/budget admission, architectural register publication and bulk commit.
// Semantic low lanes accept zero or finite magnitudes in [2^-100,2^100]; an
// out-of-domain low intermediate falls back. Auxiliary high lanes retain their
// full input bits, results and RNE/FZ/DN exceptions, including NaN/Inf/subnormal.
Result transform(const SourceSpan &,const ScratchSpan &,std::uint16_t currentCount,
                 std::uint16_t iterations,
                 const Affine3x4 &,const LoopInput &) noexcept;
} // namespace as6::geometry::vertex
