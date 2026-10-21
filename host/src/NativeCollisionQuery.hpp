#pragma once

#include "HostDataMemory.hpp"
#include "OctreeLineQuery.hpp"
#include <cstddef>
#include <cstdint>

namespace as6_collision {
// Narrow data-layout adapter. Its owner holds one stable memory transaction
// from the first read through publication; no Host callbacks or waits occur.
struct Storage {
    void *owner;
    bool (*read)(void *,std::uint32_t,void *,std::size_t);
    bool (*publish)(void *,const as6hostdata::DataMemory::WriteSpan *,std::size_t);
};
enum class Decision : std::uint8_t { Original, Handled };
enum class Reason : std::uint8_t {
    Complete, InvalidStorage, InvalidSelector, InvalidNode, InputOutputAlias,
    ReadFailure, ResourceLimit, KernelUnsupported, PublicationRejected
};
struct Result {
    Decision decision=Decision::Original;
    Reason reason=Reason::InvalidStorage;
    as6::collision::QueryStatus kernelStatus=as6::collision::QueryStatus::UnsupportedInput;
    as6::collision::FloatEffects floatingPoint;
    std::uint32_t totalCount=0;
    std::size_t nodesRead=0,triangleBytesRead=0;
};

// selector/root are original 32-bit data identities, never native pointers.
// This runs only at the verified original public call boundary, not at an
// arbitrary internal continuation. Output/count remain untouched on Original.
// Caller-clobbered registers and FPSCR status bits follow the Darwin function
// ABI; the caller preserves FPSCR control bits and callee-saved registers.
Result query(const Storage &,std::uint32_t selector,std::uint32_t root,
             std::uint32_t fpscr) noexcept;
}
