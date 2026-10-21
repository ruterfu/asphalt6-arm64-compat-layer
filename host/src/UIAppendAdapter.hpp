#pragma once
#include "UIWorkVectors.hpp"
#include "aot_support.hpp"
#include "register_layout.hpp"
#include "HostDataMemory.hpp"
#include <array>
#include <cstring>

namespace as6_ui_append {
using U32=std::uint32_t;
using Span=as6hostdata::DataMemory::WriteSpan;
inline constexpr U32 Entry=0x324b50,Exit=0x324b98;
struct Storage {
    void *owner=nullptr;
    // The caller holds the actual Core's native execution lease. Speculative
    // reads are side-effect-free. Publication checks all permissions first,
    // then keeps store order, including aliasing and exclusive-monitor effects.
    bool (*read)(void*,U32,void*,std::size_t)=nullptr;
    bool (*publish)(void*,const Span*,std::size_t)=nullptr;
};
struct Result {bool handled=false;U32 writes=0;std::uint64_t instructions=0;};
namespace detail {
struct Plan {
    const Storage &storage;
    struct Word {U32 address,value;};
    std::array<Word,5> reads{};unsigned readCount=0;
    std::array<U32,3> values{};std::array<Span,3> writes{};unsigned count=0;
    U32 read32(U32 address){
        for(unsigned i=0;i<readCount;++i)if(reads[i].address==address)return reads[i].value;
        U32 value;
        if(readCount==reads.size()||!storage.read(storage.owner,address,&value,4))throw false;
        reads[readCount++]={address,value};return value;
    }
    void write32(U32 address,U32 value){
        if(count==writes.size()||address<4096||address>0xfffffffbu||(address&3))throw false;
        values[count]=value;writes[count]={address,&values[count],4};++count;
    }
    U32 read8(U32){throw false;}
    U32 allocate(U32){throw false;}
    U32 reallocate(U32,U32,U32){throw false;}
    void release(U32,U32){throw false;}
};
}

// The existing prologue, growth call and epilogue remain ordinary original
// native code. This replaces the common no-growth append body with the source
// algorithm. A decline changes no register, memory, fault or budget state.
inline Result append(const Storage &storage,as6aot::Context &ctx,
                     std::uint64_t remaining,U32 stop,bool stopThumb) noexcept {
    using namespace as6aot;
    if(!ctx.registers||ctx.register_size<layout::Size||ctx.next_pc!=Entry||ctx.isa_thumb||
       (ctx.status!=Returned&&ctx.status!=UnresolvedTarget)||ctx.budget!=remaining||remaining<15||
       (!stopThumb&&stop>=Entry&&stop<Exit)||!storage.owner||!storage.read||!storage.publish||
       read_bytes(ctx.registers,layout::pc,4)!=Entry)return {};
    const auto reg=[&](unsigned n){return U32(read_bytes(ctx.registers,layout::r0+4*n,4));};
    const auto vector=reg(0),source=reg(1);
    if(vector<4096||vector>0xfffffff3u||(vector&3)||(source&3))return {};
    try {
        detail::Plan plan{storage};
        const auto count=plan.read32(vector+4),capacity=plan.read32(vector+8),next=count+1;
        if(as6_ui_source::signedLess(capacity,next))return {};
        const auto base=plan.read32(vector),offset=count<<3,destination=base+offset;
        if(destination&&(destination<4096||destination>0xfffffff7u||source<4096||source>0xfffffff7u||(destination&3)))return {};
        // Source algorithm produces the exact ordered write plan, including
        // source/destination/metadata aliases and null-destination suppression.
        as6_ui_source::append<3>(plan,vector,source);
        // Resolve every fallible read before publication. Once it succeeds,
        // only the known live-out bytes need committing; there is no reason
        // to copy all 1024 register bytes out and back for a tiny operation.
        U32 first=0,second=0;
        if(destination){first=plan.read32(source);second=plan.read32(source+4);}
        if(!storage.publish(storage.owner,plan.writes.data(),plan.count))return {};
        const auto set=[&](std::size_t at,unsigned n,U32 value){write_bytes(ctx.registers,at,n,value);};
        if(destination){set(layout::r0,4,first);set(layout::r1,4,second);}
        set(layout::r2,4,offset);set(layout::r3,4,base);set(layout::r4,4,next);
        set(layout::r5,4,vector);set(layout::r6,4,source);set(layout::r12,4,destination);
        set(layout::pc,4,Exit);
        const auto carry=std::uint64_t(base)+offset>0xffffffffULL;
        const auto overflow=((~(base^offset)&(base^destination))>>31)&1;
        set(layout::NG,1,destination>>31);set(layout::ZR,1,destination==0);
        set(layout::CY,1,carry);set(layout::OV,1,overflow);
        // Preserve private lowered flag scratch as well as architectural NZCV.
        set(0x64,1,destination>>31);set(0x65,1,destination==0);
        set(0x66,1,carry);set(0x67,1,overflow);set(0x68,1,next>=capacity);
        ctx.budget-=15;ctx.next_pc=Exit;ctx.status=Returned;
        return {true,plan.count,15};
    }catch(...){return {};}
}
} // namespace as6_ui_append
