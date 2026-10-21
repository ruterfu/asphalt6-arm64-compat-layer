#pragma once
#include "HostDataMemory.hpp"
#include "native_program.hpp"
#include "VertexTransform.hpp"

namespace as6_vertex {
struct Storage {
    void *owner;
    bool (*read)(void *,std::uint32_t,void *,std::size_t);
    bool (*publish)(void *,const as6hostdata::DataMemory::WriteSpan *,std::size_t);
};
enum class Decision:std::uint8_t {Original,Handled};
enum class Reason:std::uint8_t {
    Complete,InvalidContext,UnsupportedCount,InsufficientBudget,StopInsideLoop,
    UnsupportedLayout,InputOutputAlias,ReadFailure,ResourceLimit,
    KernelUnsupported,PublicationRejected
};
struct Result {
    Decision decision=Decision::Original;
    Reason reason=Reason::InvalidContext;
    as6::geometry::vertex::Status kernelStatus=as6::geometry::vertex::Status::InvalidInput;
    std::uint32_t vertices=0,vectorizedVertices=0,backgroundTasks=0;
    bool extendedBatch=false,parallelUsed=false,parallelReplayed=false;
    std::uint64_t instructions=0,sourceBytes=0,outputBytes=0;
};
// The caller owns the VM lock and a stable storage transaction throughout.
// ctx.budget is the caller's total remainder; nativeBudget is the untouched
// slice remainder captured when the copied shard suspended. Success debits
// exactly 44*vertices and publishes all architectural state after data commit.
// An explicitly authorized large positive-zero-lane batch with contiguous output may use
// up to16384 records from the total, independently of the native slice. The VM
// grants this only for the linked provider, owned data access, inactive monitor.
// Original leaves both data and the complete Context/register file unchanged.
Result transform(const Storage &,as6aot::Context &,std::uint64_t nativeBudget,
                 std::uint32_t stop,bool stopThumb,bool allowExtendedBatch=false) noexcept;
}
