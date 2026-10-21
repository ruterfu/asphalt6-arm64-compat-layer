#pragma once
#include "HostDataMemory.hpp"
#include "TrailRibbon.hpp"

namespace as6_trail {
struct Storage {
    void *owner;
    bool (*read)(void *,std::uint32_t,void *,std::size_t);
    bool (*publish)(void *,const as6hostdata::DataMemory::WriteSpan *,std::size_t);
};
enum class Decision:std::uint8_t {Original,Handled};
enum class Reason:std::uint8_t {
    Complete,InvalidStorage,InvalidNode,InvalidBuffers,InputOutputAlias,
    ReadFailure,KernelUnsupported,PublicationRejected,ResourceLimit
};
struct Result {
    Decision decision=Decision::Original;
    Reason reason=Reason::InvalidStorage;
    as6::geometry::trail::Status kernelStatus=as6::geometry::trail::Status::InvalidState;
    as6::geometry::trail::FloatEffects floatingPoint;
    std::uint64_t indexBytesRead=0,vertexBytesWritten=0,indexBytesWritten=0,stateBytesWritten=0;
    std::size_t publicationSpans=0;
};
// A stable storage lease and the owning VM lock surround this entire call.
// The source kernel reads no old vertices and reads old indices only for the
// initial compaction. Original means no data/CPU state was published.
Result update(const Storage &,std::uint32_t node,std::uint32_t stackPointer,
              std::uint32_t fpscr) noexcept;
}
