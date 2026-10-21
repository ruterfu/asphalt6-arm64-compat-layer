#include "SceneAffineCore.hpp"
#include "register_layout.hpp"
#include <algorithm>
#include <cstring>

namespace as6_scene_affine {
namespace {
struct Interval {std::uint32_t address=0;std::uint64_t length=0;std::size_t offset=0;};
bool valid(Interval interval) noexcept {
    return interval.address>=4096&&interval.length&&interval.length<=0x100000000ULL-interval.address;
}
std::uint32_t reg(const as6aot::Context &ctx,unsigned index) noexcept {
    return std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::r0+index*4,4));
}
}
Result queryDirect(as6native::Core &core,as6aot::Context &ctx,Workspace &workspace,
             std::uint64_t sliceRemaining,std::uint32_t stop,bool stopThumb) noexcept {
    Result result;
    if(workspace.busy_.test_and_set(std::memory_order_acquire)){result.reason=Reason::WorkspaceBusy;return result;}
    struct Release {std::atomic_flag &flag;~Release(){flag.clear(std::memory_order_release);}} release{workspace.busy_};
    if(&ctx!=&core.state().context()||!core.ready()||!core.nav_context_data_is_owned()||
       !ctx.registers||ctx.register_size!=as6aot::layout::Size||ctx.next_pc!=Entry||ctx.isa_thumb||
       ctx.status!=as6aot::Returned||ctx.fault_address)return result;
    if(ctx.budget!=sliceRemaining){result.reason=Reason::BudgetMismatch;return result;}
    if(!stopThumb&&stop>=Entry&&stop<=LastInstruction){result.reason=Reason::StopInside;return result;}
    if(sliceRemaining<OriginalInstructions){result.reason=Reason::InsufficientBudget;return result;}
    const auto fpscr=std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::fpscr,4));
    if(fpscr&(0x9f00u|(7u<<16)|(3u<<20))){result.reason=Reason::UnsupportedEnvironment;return result;}
    const auto parent=reg(ctx,4),local=reg(ctx,1);
    const auto destination64=std::uint64_t(reg(ctx,5))+16;
    if(destination64>UINT32_MAX||reg(ctx,2)!=0||reg(ctx,0)!=destination64||
       ((parent|local|std::uint32_t(destination64))&3u)){
        result.reason=Reason::UnsupportedLayout;return result;
    }
    const auto destination=std::uint32_t(destination64);
    const Interval parentRange{parent,60,0},localRange{local,60,0},outputRange{destination,65,0};
    if(!valid(parentRange)||!valid(localRange)||!valid(outputRange)){result.reason=Reason::UnsupportedLayout;return result;}
    // All fallible locking happens before any guest publication. Once this
    // exact-object lease is held, Core reads/validation/batch publication borrow
    // it; they neither reacquire a mutex nor allocate. The post-batch CPU commit
    // consists solely of bounded byte copies and scalar assignments.
    try {
        auto lease=core.native_execution_lease();
        if(!lease.valid())return result;
        if(!core.nav_accessible(parent,60,1)||!core.nav_accessible(local,60,1)||
           !core.nav_accessible(destination,65,2)){
            result.reason=Reason::PermissionFailure;return result;
        }
        std::array<Interval,3> sorted{{parentRange,localRange,outputRange}},merged{};
        std::sort(sorted.begin(),sorted.end(),[](Interval a,Interval b){return a.address<b.address;});
        std::size_t count=0,bytes=0;
        for(const auto &interval:sorted){
            if(count&&std::uint64_t(interval.address)<=std::uint64_t(merged[count-1].address)+merged[count-1].length){
                auto &last=merged[count-1];last.length=std::max(std::uint64_t(last.address)+last.length,
                    std::uint64_t(interval.address)+interval.length)-last.address;
            }else merged[count++]=interval;
        }
        for(std::size_t i=0;i<count;++i){merged[i].offset=bytes;bytes+=std::size_t(merged[i].length);}
        if(bytes>workspace.bytes_.size()){result.reason=Reason::KernelFailure;return result;}
        workspace.bytes_.fill(0);
        const auto pointer=[&](std::uint32_t address,std::uint64_t length)->std::uint8_t* {
            for(std::size_t i=0;i<count;++i){const auto &part=merged[i];
                if(address>=part.address&&std::uint64_t(address)+length<=std::uint64_t(part.address)+part.length)
                    return workspace.bytes_.data()+part.offset+(address-part.address);
            }
            return nullptr;
        };
        auto *ownedParent=pointer(parent,60),*ownedLocal=pointer(local,60),*ownedOutput=pointer(destination,65);
        if(!ownedParent||!ownedLocal||!ownedOutput){result.reason=Reason::KernelFailure;return result;}
        // The overlapping guest bytes copied by these two reads agree under
        // this one lease and map to the SAME owned bytes. Output-only bytes
        // remain zero initially; no original load can consume those bytes.
        if(!core.read(parent,ownedParent,60)||!core.read(local,ownedLocal,60)){
            result.reason=Reason::ReadFailure;return result;
        }
        const as6::scene::affine::Carry input{
            std::uint64_t(as6aot::read_bytes(ctx.registers,as6aot::layout::d5,8)),
            std::uint64_t(as6aot::read_bytes(ctx.registers,as6aot::layout::d6,8)),
            std::uint64_t(as6aot::read_bytes(ctx.registers,as6aot::layout::d7,8)),fpscr};
        auto computed=as6::scene::affine::compose({ownedParent,60},{ownedLocal,60},{ownedOutput,65},input,true,nullptr);
        if(computed.status!=as6::scene::affine::Status::Complete||computed.reads!=75||computed.writes!=17||
           computed.nativeOperations+computed.softwareOperations!=63){
            result.reason=Reason::KernelFailure;return result;
        }
        std::array<as6native::Core::WriteSpan,17> spans{};
        constexpr std::uint32_t offsets[]={0,4,12,8,16,20,28,24,32,36,44,40,48,52,64,60,56};
        // The original17write intervals are disjoint and cover every output
        // byte exactly once. Later alias reads do not overwrite those fields;
        // final owned bytes therefore retain each original publication value.
        for(std::size_t ordinal=0;ordinal<17;++ordinal){
            auto &write=result.writes[ordinal];write.address=destination+offsets[ordinal];
            write.width=std::uint8_t(ordinal==14?1:4);
            for(unsigned byte=0;byte<write.width;++byte){
                const auto value=ownedOutput[offsets[ordinal]+byte];
                write.bytes[byte]=value;write.value|=std::uint32_t(value)<<(byte*8);
            }
            spans[ordinal]={write.address,write.bytes.data(),write.width};++result.writeCount;
        }
        if(result.writeCount!=17){result=Result{};result.reason=Reason::KernelFailure;return result;}
        std::array<std::uint8_t,as6aot::layout::Size> next;
        std::memcpy(next.data(),ctx.registers,next.size());
        as6aot::write_bytes(next.data(),as6aot::layout::d5,8,computed.carry.middle);
        as6aot::write_bytes(next.data(),as6aot::layout::d6,8,computed.carry.accumulator);
        as6aot::write_bytes(next.data(),as6aot::layout::d7,8,computed.carry.term);
        as6aot::write_bytes(next.data(),as6aot::layout::fpscr,4,computed.carry.fpscr);
        as6aot::write_bytes(next.data(),as6aot::layout::r3,4,computed.structuralWord);
        as6aot::write_bytes(next.data(),as6aot::layout::pc,4,Exit);
        if(!core.write_batch(spans.data(),spans.size())){
            result=Result{};result.reason=Reason::PublicationRejected;return result;
        }
        // No fallible call, allocation, scheduler or monitor reset follows.
        std::memcpy(ctx.registers,next.data(),next.size());ctx.next_pc=Exit;
        ctx.budget-=OriginalInstructions;ctx.status=as6aot::Returned;
        result.computed=computed;result.overlayBytes=bytes;result.overlaySegments=count;
        result.decision=Decision::Handled;result.reason=Reason::Complete;return result;
    }catch(...){
        // The pinned exact-object batch path cannot throw after publication.
        // Lock acquisition/other prepublication failures retain original data.
        result=Result{};result.reason=Reason::ExceptionBeforePublication;return result;
    }
}
}
