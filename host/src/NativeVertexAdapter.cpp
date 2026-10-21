#include "NativeVertexAdapter.hpp"
#include "NativeVertexBoundary.hpp"
#include "VertexJobs.hpp"
#include "register_layout.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

namespace as6_vertex {
namespace {
constexpr std::uint64_t MaximumSourceBytes=1024*1024;
constexpr std::uint32_t MinimumExtendedBatchVertices=512;
struct TransformScratch {
    std::vector<std::uint8_t> input,output;
    bool busy=false;
};
struct ScratchUse {
    TransformScratch &scratch;
    explicit ScratchUse(TransformScratch &value):scratch(value){scratch.busy=true;}
    ~ScratchUse(){scratch.busy=false;}
};
constexpr std::size_t MaximumStridedWrites=as6hostdata::DataMemory::MaximumWriteSpans;
bool range(std::uint32_t at,std::uint64_t bytes) {
    return at>=4096&&bytes&&bytes<=0x100000000ULL-at;
}
bool overlaps(std::uint32_t a,std::uint64_t an,std::uint32_t b,std::uint64_t bn) {
    return an&&bn&&std::uint64_t(a)<std::uint64_t(b)+bn&&std::uint64_t(b)<std::uint64_t(a)+an;
}
std::uint32_t word(const std::uint8_t *p) {
    return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|
           (std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);
}
std::uint32_t reg(const as6aot::Context &ctx,unsigned index) {
    return std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::r0+4*index,4));
}
}
Result transform(const Storage &storage,as6aot::Context &ctx,std::uint64_t nativeBudget,
                 std::uint32_t stop,bool stopThumb,bool allowExtendedBatch) noexcept {
    Result result;
    if(!storage.owner||!storage.read||!storage.publish||
       !as6_vertex_boundary::isBoundary(ctx))return result;
    if(as6_vertex_boundary::stopInsideLoop(stop,stopThumb)) {
        result.reason=Reason::StopInsideLoop;return result;
    }
    const auto count=reg(ctx,1);
    if(!count||count>65535){result.reason=Reason::UnsupportedCount;return result;}
    auto available=std::min(ctx.budget,nativeBudget);
    if(available<as6_vertex_boundary::InstructionsPerVertex) {
        result.reason=Reason::InsufficientBudget;return result;
    }
    const auto source=reg(ctx,0),destination=reg(ctx,4),sourceStride=reg(ctx,10),
               destinationStride=reg(ctx,9),sp=reg(ctx,13);
    if((source|destination|sp|sourceStride|destinationStride)&3||sourceStride<12||destinationStride<12) {
        result.reason=Reason::UnsupportedLayout;return result;
    }
    as6::geometry::vertex::LoopInput environment;
    environment.fpscr=std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::fpscr,4));
    bool positiveZero=true;
    for(unsigned i=0;i<5;++i) {
        environment.oddS[i]=std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::s0+(7+2*i)*4,4));
        positiveZero=positiveZero&&environment.oddS[i]==0;
    }
    using Jobs=as6::geometry::vertex::VertexJobs;
    const bool extended=allowExtendedBatch&&positiveZero&&destinationStride==12&&
        count>=MinimumExtendedBatchVertices&&
        (std::uint64_t(MinimumExtendedBatchVertices-1)*sourceStride+12)<=MaximumSourceBytes&&ctx.budget/as6_vertex_boundary::InstructionsPerVertex>=MinimumExtendedBatchVertices&&
        !(environment.fpscr&(0x9f00u|(7u<<16)|(3u<<20)));
    if(extended)available=std::min<std::uint64_t>(ctx.budget,as6_vertex_boundary::InstructionsPerVertex*Jobs::MaximumParallelVertices);
    result.extendedBatch=extended;
    auto iterations=std::uint32_t(std::min<std::uint64_t>(count,available/as6_vertex_boundary::InstructionsPerVertex));
    // Interleaved output commits only its xyz fields, never padding or other
    // attributes. Keep the bounded batch API's existing maximum unchanged.
    if(destinationStride!=12)iterations=std::min<std::uint32_t>(iterations,MaximumStridedWrites);
    iterations=std::min<std::uint32_t>(iterations,1+(MaximumSourceBytes-12)/sourceStride);
    const auto sourceBytes=std::uint64_t(iterations-1)*sourceStride+12;
    const auto destinationExtent=std::uint64_t(iterations-1)*destinationStride+12;
    if(sourceBytes>MaximumSourceBytes){result.reason=Reason::ResourceLimit;return result;}
    if(!range(source,sourceBytes)||!range(destination,destinationExtent)||!range(sp,0x2a8)) {
        result.reason=Reason::UnsupportedLayout;return result;
    }
    const auto matrixAddress=sp+0x26c;
    if(overlaps(source,sourceBytes,destination,destinationExtent)||
       overlaps(matrixAddress,60,destination,destinationExtent)) {
        result.reason=Reason::InputOutputAlias;return result;
    }
    try {
        std::array<std::uint8_t,60> rawMatrix{};
        // One bounded snapshot per host thread. Re-entrant publication gets
        // independent storage and cannot overwrite an outer call's staging.
        static thread_local TransformScratch reusable;
        TransformScratch nested;
        auto &scratch=reusable.busy?nested:reusable;
        ScratchUse use(scratch);
        const auto inputSize=static_cast<std::size_t>(sourceBytes);
        const auto outputSize=std::size_t(iterations)*12;
        if(scratch.input.size()<inputSize)scratch.input.resize(inputSize);
        if(scratch.output.size()<outputSize)scratch.output.resize(outputSize);
        auto &input=scratch.input;
        auto &output=scratch.output;
        if(!storage.read(storage.owner,matrixAddress,rawMatrix.data(),rawMatrix.size())||
           !storage.read(storage.owner,source,input.data(),inputSize)) {
            result.reason=Reason::ReadFailure;return result;
        }
        as6::geometry::vertex::Affine3x4 matrix;
        for(unsigned i=0;i<4;++i) {
            matrix.x[i]=word(rawMatrix.data()+16*i);
            matrix.y[i]=word(rawMatrix.data()+16*i+4);
            matrix.z[i]=word(rawMatrix.data()+16*i+8);
        }
        as6::geometry::vertex::Result computed;
        if(extended) {
            static Jobs jobs;
            const auto work=jobs.transform({input.data(),inputSize,sourceStride},
                {output.data(),outputSize,12},std::uint16_t(count),std::uint16_t(iterations),matrix,environment);
            computed=work.result;result.backgroundTasks=work.workers;
            result.parallelUsed=work.parallelUsed;result.parallelReplayed=work.replayed;
        } else {
            computed=as6::geometry::vertex::transform({input.data(),inputSize,sourceStride},
                {output.data(),outputSize,12},std::uint16_t(count),std::uint16_t(iterations),matrix,environment);
        }
        result.vectorizedVertices=computed.vectorizedVertices;
        result.kernelStatus=computed.status;
        if(computed.status!=as6::geometry::vertex::Status::Complete||computed.written!=iterations||
           computed.remaining!=count-iterations||computed.r3!=computed.remaining||
           computed.sourceAdvance!=std::uint64_t(iterations)*sourceStride||
           computed.destinationAdvance!=std::uint64_t(iterations)*12) {
            result.reason=Reason::KernelUnsupported;return result;
        }
        std::array<std::uint8_t,as6aot::layout::Size> nextRegisters;
        std::memcpy(nextRegisters.data(),ctx.registers,nextRegisters.size());
        const auto set=[&](std::size_t at,std::size_t width,as6aot::Word value) {
            as6aot::write_bytes(nextRegisters.data(),at,width,value);
        };
        const auto nextSource=std::uint32_t(std::uint64_t(source)+computed.sourceAdvance);
        const auto nextDestination=std::uint32_t(std::uint64_t(destination)+std::uint64_t(iterations)*destinationStride);
        const auto nextPC=computed.remaining?as6_vertex_boundary::Entry:as6_vertex_boundary::Exit;
        set(as6aot::layout::r0,4,nextSource);set(as6aot::layout::r1,4,computed.remaining);
        set(as6aot::layout::r3,4,computed.r3);set(as6aot::layout::r4,4,nextDestination);
        set(as6aot::layout::pc,4,nextPC);set(as6aot::layout::fpscr,4,computed.fpscr);
        for(unsigned i=0;i<5;++i)set(as6aot::layout::d3+8*i,8,computed.d3ToD7[i]);
        set(as6aot::layout::NG,1,0);set(as6aot::layout::ZR,1,computed.remaining==0);
        set(as6aot::layout::CY,1,1);set(as6aot::layout::OV,1,0);
        // The frozen translator also materializes temporary flags for its
        // final non-S ADD r4,r4,r9. Preserve those private bytes as well as
        // architectural NZCV, so arbitrary original continuations stay exact.
        const auto previousDestination=std::uint32_t(std::uint64_t(destination)+std::uint64_t(iterations-1)*destinationStride);
        set(0x64,1,nextDestination>>31);set(0x65,1,nextDestination==0);
        set(0x66,1,(std::uint64_t(previousDestination)+destinationStride)>0xffffffffULL);
        set(0x67,1,((~(previousDestination^destinationStride)&(previousDestination^nextDestination))>>31)&1);
        set(0x68,1,1);
        std::array<as6hostdata::DataMemory::WriteSpan,MaximumStridedWrites> writes{};
        std::size_t writeCount=0;
        if(destinationStride==12)writes[writeCount++]={destination,output.data(),outputSize};
        else for(std::uint32_t i=0;i<iterations;++i)
            writes[writeCount++]={std::uint32_t(std::uint64_t(destination)+std::uint64_t(i)*destinationStride),output.data()+12*i,12};
        if(!storage.publish(storage.owner,writes.data(),writeCount)) {
            result.reason=Reason::PublicationRejected;return result;
        }
        // No allocation, checked API or monitor-clear operation follows data
        // publication. Context identity and exclusive reservations are retained.
        std::memcpy(ctx.registers,nextRegisters.data(),nextRegisters.size());
        ctx.next_pc=nextPC;ctx.budget-=as6_vertex_boundary::InstructionsPerVertex*iterations;
        result.vertices=iterations;result.instructions=as6_vertex_boundary::InstructionsPerVertex*iterations;
        result.sourceBytes=sourceBytes;result.outputBytes=outputSize;
        result.reason=Reason::Complete;result.decision=Decision::Handled;return result;
    } catch(const std::bad_alloc &) {result.reason=Reason::ResourceLimit;return result;}
      catch(...) {result.reason=Reason::KernelUnsupported;return result;}
}
}
