#include "CollisionInverseCore.hpp"
#include "CollisionInverseState.hpp"
#include "register_layout.hpp"
#include <array>
#include <cstring>

namespace as6_collision_inverse {
namespace {
std::uint32_t reg(const as6aot::Context &ctx,unsigned index) noexcept {
    return std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::r0+4*index,4));
}
}
Result queryDirect(as6native::Core &core,as6aot::Context &ctx,Workspace &workspace,
                   std::uint64_t sliceRemaining,std::uint32_t stop,bool stopThumb) noexcept {
    Result result;
    if(workspace.busy_.test_and_set(std::memory_order_acquire)){
        result.reason=Reason::WorkspaceBusy;return result;
    }
    struct Release {std::atomic_flag &flag;~Release(){flag.clear(std::memory_order_release);}} release{workspace.busy_};
    if(&ctx!=&core.state().context()||!core.ready()||!core.nav_context_data_is_owned()||
       !ctx.registers||ctx.register_size!=as6aot::layout::Size||ctx.next_pc!=Entry||
       ctx.isa_thumb||ctx.status!=as6aot::Returned||ctx.fault_address||reg(ctx,15)!=Entry)return result;
    if(ctx.budget!=sliceRemaining){result.reason=Reason::BudgetMismatch;return result;}
    if(!stopThumb&&stop>=Entry&&stop<=LastInstruction){result.reason=Reason::StopInside;return result;}
    if(sliceRemaining<82){result.reason=Reason::InsufficientBudget;return result;}
    const auto stack=reg(ctx,13);
    if(stack<4096||(stack&3u)||std::uint64_t(stack)+216>0x100000000ULL){
        result.reason=Reason::UnsupportedLayout;return result;
    }
    // The original literal load follows scratch stores. Reject this unusual
    // alias rather than snapshot a value those stores could subsequently alter.
    if(std::uint64_t(stack)<std::uint64_t(ThresholdAddress)+4&&
       std::uint64_t(ThresholdAddress)<std::uint64_t(stack)+216){
        result.reason=Reason::LiteralAlias;return result;
    }
    try {
        auto lease=core.native_execution_lease();
        if(!lease.valid())return result;
        as6::collision::inverse_state::Input input{};
        input.stackAddress=stack;
        if(!core.read(stack+152,input.matrix.data(),64)){
            result.reason=Reason::ReadFailure;return result;
        }
        std::uint32_t threshold=0;
        if(!core.read(ThresholdAddress,&threshold,4)){
            result.reason=Reason::ReadFailure;return result;
        }
        if(threshold!=ThresholdWord){result.reason=Reason::ThresholdChanged;return result;}
        for(unsigned i=0;i<16;++i)
            input.fp[i]=std::uint64_t(as6aot::read_bytes(ctx.registers,as6aot::layout::d0+8*i,8));
        for(unsigned i=0;i<4;++i)input.gpr[i]=reg(ctx,i);
        input.fpscr=std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::fpscr,4));
        const auto computed=as6::collision::inverse_state::compute(input,true);
        if(computed.status!=as6::collision::inverse_state::Status::Complete){
            result.reason=Reason::KernelFailure;return result;
        }
        const bool small=computed.nextPc==SmallExit;
        if((!small&&computed.nextPc!=InverseExit)||
           computed.originalInstructions!=(small?82u:220u)||computed.writeCount!=(small?18u:38u)){
            result.reason=Reason::KernelFailure;return result;
        }
        if(sliceRemaining<computed.originalInstructions){result.reason=Reason::InsufficientBudget;return result;}
        std::array<as6native::Core::WriteSpan,38> spans{};
        std::array<std::array<std::uint8_t,4>,38> bytes{};
        for(std::size_t i=0;i<computed.writeCount;++i){
            const auto &write=computed.writes[i];
            if((write.size!=1&&write.size!=4)||std::uint64_t(write.offset)+write.size>149){
                result.reason=Reason::KernelFailure;return result;
            }
            for(unsigned byte=0;byte<write.size;++byte)
                bytes[i][byte]=std::uint8_t(write.value>>(8*byte));
            spans[i]={stack+write.offset,bytes[i].data(),write.size};
        }
        std::array<std::uint8_t,as6aot::layout::Size> next;
        std::memcpy(next.data(),ctx.registers,next.size());
        for(unsigned i=0;i<16;++i)
            as6aot::write_bytes(next.data(),as6aot::layout::d0+8*i,8,computed.fp[i]);
        for(unsigned i=0;i<4;++i)
            as6aot::write_bytes(next.data(),as6aot::layout::r0+4*i,4,computed.gpr[i]);
        as6aot::write_bytes(next.data(),as6aot::layout::fpscr,4,computed.fpscr);
        // VMRS changes these independent flag bytes. Keep the raw CPSR word,
        // every other status byte and D16..D31 exactly as the original does.
        for(unsigned i=0;i<4;++i)
            as6aot::write_bytes(next.data(),as6aot::layout::NG+i,1,(computed.apsrNzcv>>(31-i))&1u);
        if(!small){
            // Preserve the frozen translator's nonarchitectural temporary flag
            // bytes as well. Its last integer instruction is MOV r2,#65:
            // temporary N=Z=0, C=APSR.C, V=APSR.V, shifter carry=APSR.C.
            // These bytes are checked against the unchanged generated caller,
            // separately from the original ARM architectural-state oracle.
            as6aot::write_bytes(next.data(),100,1,0);
            as6aot::write_bytes(next.data(),101,1,0);
            as6aot::write_bytes(next.data(),102,1,(computed.apsrNzcv>>29)&1u);
            as6aot::write_bytes(next.data(),103,1,(computed.apsrNzcv>>28)&1u);
            as6aot::write_bytes(next.data(),104,1,(computed.apsrNzcv>>29)&1u);
        }
        as6aot::write_bytes(next.data(),as6aot::layout::pc,4,computed.nextPc);
        if(!core.write_batch(spans.data(),computed.writeCount)){
            result.reason=Reason::PublicationRejected;return result;
        }
        // The ordered batch preserves all original mutations/reservations.
        // No fallible operation remains after this successful publication.
        std::memcpy(ctx.registers,next.data(),next.size());ctx.next_pc=computed.nextPc;
        ctx.budget-=computed.originalInstructions;ctx.status=as6aot::Returned;
        result.decision=Decision::Handled;result.reason=Reason::Complete;
        result.instructions=computed.originalInstructions;result.writes=computed.writeCount;
        result.nativeOperations=computed.nativeOperations;result.softwareOperations=computed.softwareOperations;
        return result;
    }catch(...){result=Result{};result.reason=Reason::ExceptionBeforePublication;return result;}
}
}
