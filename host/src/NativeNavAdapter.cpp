#include "NativeNavAdapter.hpp"
#include "NativeNavBoundary.hpp"
#include "register_layout.hpp"
#include <algorithm>
#include <cstring>
namespace as6_large_nav {
namespace {
struct Range{std::uint32_t at;std::uint64_t bytes;};
bool valid(Range a)noexcept{return a.at>=4096&&a.bytes&&a.bytes<=0x100000000ULL-a.at;}
bool overlap(Range a,Range b)noexcept{return std::uint64_t(a.at)<std::uint64_t(b.at)+b.bytes&&std::uint64_t(b.at)<std::uint64_t(a.at)+a.bytes;}
std::uint32_t reg(const as6aot::Context&c,unsigned i)noexcept{return std::uint32_t(as6aot::read_bytes(c.registers,as6aot::layout::r0+4*i,4));}
}
Workspace::Workspace(std::size_t capacity,Storage storage) noexcept {
 if(storage==Storage::Allocate&&capacity&&capacity<=65536){
  points_.reset(new(std::nothrow) as6::navigation::large_effects::Point[capacity]);
  if(points_)capacity_=capacity;
 }
}
Result query(as6native::Core &core,as6aot::Context &ctx,Workspace &workspace,std::uint64_t remainingTotalBudget,std::uint32_t stop,bool stopThumb) noexcept {
 Result result;
 if(workspace.busy_.test_and_set(std::memory_order_acquire)){result.reason=Reason::WorkspaceBusy;return result;}
 struct Release{std::atomic_flag&flag;~Release(){flag.clear(std::memory_order_release);}} release{workspace.busy_};
 if(!workspace.points_){result.reason=Reason::WorkspaceUnavailable;return result;}
 if(&ctx!=&core.state().context()||!core.ready()||!core.nav_context_data_is_owned()||ctx.status!=as6aot::UnresolvedTarget||ctx.fault_address||!as6_nav_boundary::isBoundary(ctx))return result;
 if(ctx.budget!=remainingTotalBudget){result.reason=Reason::BudgetMismatch;return result;}
 if(!stopThumb&&stop>=as6_nav_boundary::Entry&&stop<=as6_nav_boundary::LastInstruction){result.reason=Reason::StopInsideBody;return result;}
 const auto available=remainingTotalBudget;
 if(!available){result.reason=Reason::InsufficientBudget;return result;}
 auto lease=core.native_execution_lease();
 if(!lease.valid())return result;
 as6hostdata::ArmAtomicMemory::Snapshot monitor;
 if(!core.nav_monitor_snapshot(monitor))return result;
 // Active reservations are retained; exact ordered batch mutations update
 // their granule/version state under the same complete execution lease.
 const auto fpscr=std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::fpscr,4));
 constexpr std::uint32_t UnsupportedFp=(0x1fu<<8)|(1u<<15)|(7u<<16)|(3u<<20);
 if(fpscr&UnsupportedFp){result.reason=Reason::UnsupportedMode;return result;}
 // Public-function projection with arbitrary high lanes: Guest FPSCR0x9f
 // is not full-state equivalent. Controls/NZCV and raw D8 bytes remain exact.
 // This internal numeric primitive does not authenticate providers. Actual VM
 // admission requires the pinned unique linked-provider capability/exact final
 // pointer and a fresh observer/source closure for that build. Opaque CPU
 // snapshots and raw diagnostics transport bits without granting full-state
 // observational equivalence.
 const auto output=reg(ctx,0),manager=reg(ctx,1),index=reg(ctx,2),position=reg(ctx,3),sp=reg(ctx,13),lr=reg(ctx,14);
 if((output|manager|position)&3u||sp&7u||sp<4096+44||index>4095||
    (lr&~1u)<4096||((lr&~1u)&((lr&1u)?1u:3u))){result.reason=Reason::UnsupportedLayout;return result;}
 if((lr&~1u)>=as6_nav_boundary::Entry&&(lr&~1u)<=as6_nav_boundary::LastInstruction){result.reason=Reason::ReturnInsideBody;return result;}
 // Bound to frozen original ARM BL sites, callsite-flags.json fc430a47... .
 constexpr std::uint32_t PublicReturns[]={0x81bf8,0x183b20,0x183b80,0x184a04,0x184d10,0x1996c4,0x199750,0x1a350c,0x1a3bb8,0x1efa88,0x255f04};
 if((lr&1u)||std::find(std::begin(PublicReturns),std::end(PublicReturns),lr)==std::end(PublicReturns)){result.reason=Reason::UnknownReturn;return result;}
 const auto slot64=std::uint64_t(manager)+4*(std::uint64_t(index)+1);
 if(slot64>0xffffffffu){result.reason=Reason::UnsupportedLayout;return result;}
 const auto slot=std::uint32_t(slot64);
 const Range frame{sp-44,44},outputRange{output,8},queryRange{position,12},slotRange{slot,4};
 std::uint32_t line=0;
 if(!valid(frame)||!valid(outputRange)||!valid(queryRange)||!valid(slotRange)){result.reason=Reason::UnsupportedLayout;return result;}
 if((!core.nav_accessible(slot,4,1)||!core.read(slot,&line,4))){result.reason=Reason::ReadFailure;return result;}
 if(line&3u||std::uint64_t(line)+0x18>0x100000000ULL){result.reason=Reason::UnsupportedLayout;return result;}
 const Range metadata{line+0x10,8};
 std::uint32_t fields[2];
 if(!valid(metadata)||(!core.nav_accessible(metadata.at,metadata.bytes,1)||!core.read(metadata.at,fields,sizeof(fields)))){result.reason=Reason::ReadFailure;return result;}
 const auto count=fields[0],pointAddress=fields[1];
 if(!count||count>65536){result.reason=Reason::UnsupportedCount;return result;}
 if(count>workspace.capacity_){result.reason=Reason::WorkspaceTooSmall;return result;}
 if(available<33ULL+62ULL*count){result.reason=Reason::BudgetLowerBound;return result;}
 const Range pointRange{pointAddress,12ULL*count};
 if(pointAddress&3u||!valid(pointRange)){result.reason=Reason::UnsupportedLayout;return result;}
 const Range ranges[]={frame,outputRange,queryRange,slotRange,metadata,pointRange};
 for(unsigned i=0;i<6;++i)for(unsigned j=0;j<i;++j)
  if(overlap(ranges[i],ranges[j])){result.reason=Reason::Alias;return result;}
 for(unsigned i=0;i<6;++i){const auto permissions=std::uint8_t(i==0?3:i==1?2:1);
  if(!core.nav_accessible(ranges[i].at,ranges[i].bytes,permissions)){result.reason=Reason::PermissionFailure;return result;}}
 as6::navigation::large_effects::Point query;
 if(!core.read(position,&query,12)||!core.read(pointAddress,workspace.points_.get(),std::size_t(pointRange.bytes))){result.reason=Reason::ReadFailure;return result;}
 auto computed=as6::navigation::large_effects::closestSegment({workspace.points_.get(),count},query,{std::uint8_t((fpscr>>22)&3),bool(fpscr&(1u<<24)),bool(fpscr&(1u<<25))});
 if(computed.status==as6::navigation::large_effects::Status::CapacityDeclined){result.reason=Reason::CapacityDeclined;return result;}
 if(computed.status!=as6::navigation::large_effects::Status::Complete||!computed.floatingPoint.compared||computed.originalInstructions>225ULL*(count+1)||computed.scratchWriteCount<1||computed.scratchWriteCount>count+1||computed.scratchWriteCount>50){result.reason=Reason::KernelFailure;return result;}
 if(computed.originalInstructions>available){result.reason=Reason::InsufficientBudget;return result;}
 // Freeze all data and register results before the one fallible publication.
 std::array<std::uint8_t,as6aot::layout::Size> nextRegisters;
 std::memcpy(nextRegisters.data(),ctx.registers,nextRegisters.size());
 const auto set=[&](std::size_t offset,unsigned size,std::uint64_t value){as6aot::write_bytes(nextRegisters.data(),offset,size,value);};
 const auto target=lr&~1u;const bool thumb=lr&1u;
 set(as6aot::layout::r0,4,output);set(as6aot::layout::r0+9*4,4,computed.usedNearestPointFallback?count:count-1);
 set(as6aot::layout::pc,4,target);set(as6aot::layout::TB,1,thumb);
 set(as6aot::layout::fpscr,4,(fpscr&0x0fffffffu)|computed.floatingPoint.nzcv|computed.floatingPoint.exceptionDelta);
 const auto flags=computed.usedNearestPointFallback?computed.floatingPoint.nzcv:0u;
 const std::size_t offsets[]={as6aot::layout::NG,as6aot::layout::ZR,as6aot::layout::CY,as6aot::layout::OV};
 for(unsigned i=0;i<4;++i)set(offsets[i],1,(flags>>(31-i))&1u);
 std::array<as6native::Core::WriteSpan,63> spans{};
 const auto append=[&](std::uint32_t at,unsigned width,std::uint64_t value){
  auto &w=result.writes[result.writeCount];w={at,width,value};spans[result.writeCount]={at,&w.value,width};++result.writeCount;
 };
 // Bind to current frozen AOT DataAccess order. Original ARM STM event order
 // differs within push groups; no complete ARM bus/write-prefix claim is made.
 append(sp-4,4,lr);append(sp-8,4,reg(ctx,7));append(sp-12,4,reg(ctx,6));append(sp-16,4,reg(ctx,5));append(sp-20,4,reg(ctx,4));
 append(sp-24,4,reg(ctx,11));append(sp-28,4,reg(ctx,10));append(sp-32,4,reg(ctx,8));
 append(sp-40,8,std::uint64_t(as6aot::read_bytes(ctx.registers,as6aot::layout::d8,8)));
 for(unsigned i=0;i<computed.scratchWriteCount;++i)append(sp-44,4,std::uint32_t(computed.scratchWrites[i]));
 if(computed.usedNearestPointFallback){append(output,4,0xffffffffu);append(output+4,4,0xffffffffu);append(output+4,4,std::uint32_t(computed.second));append(output,4,std::uint32_t(computed.first));}
 else{append(output,4,std::uint32_t(computed.first));append(output+4,4,std::uint32_t(computed.second));}
 if(!core.write_batch(spans.data(),result.writeCount)){result=Result{};result.reason=Reason::PublicationRejected;return result;}
 // No allocation, checked API, CLREX or failure branch after real publication.
 std::memcpy(ctx.registers,nextRegisters.data(),nextRegisters.size());ctx.next_pc=target;ctx.isa_thumb=thumb;ctx.budget-=computed.originalInstructions;ctx.status=as6aot::Returned;
 result.decision=Decision::Handled;result.reason=Reason::Complete;result.originalInstructions=computed.originalInstructions;result.computed=computed;return result;
}
}
