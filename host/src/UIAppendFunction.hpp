#pragma once
#include "UIAppendAdapter.hpp"

namespace as6_ui_append_function {
using U32=std::uint32_t;
using Span=as6_ui_append::Span;
using Storage=as6_ui_append::Storage;
using Result=as6_ui_append::Result;
constexpr U32 Entry=0x324b48,End=0x324b9c;
inline bool overlaps(U32 a,U32 length,U32 b,U32 other) noexcept {
    return std::uint64_t(a)<std::uint64_t(b)+other&&std::uint64_t(b)<std::uint64_t(a)+length;
}
struct Plan {
    const Storage &storage;
    struct Word{U32 address,value;};
    std::array<Word,5> reads{};unsigned readCount=0;
    std::array<U32,8> values{};std::array<Span,8> writes{};unsigned count=0;
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
// Whole original pair append, including observable stack stores in their
// original descending order. Growth, interrupted execution and stack/data
// aliasing replay the original body before any side effect is published.
inline Result append(const Storage &storage,as6aot::Context &ctx,U32 stop,bool thumb) noexcept {
    using namespace as6aot;
    if(!ctx.registers||ctx.register_size<layout::Size||ctx.next_pc!=Entry||ctx.isa_thumb||
       ctx.status!=Returned||ctx.budget<18||(!thumb&&stop>=Entry&&stop<End)||
       !storage.owner||!storage.read||!storage.publish||
       read_bytes(ctx.registers,layout::pc,4)!=Entry)return {};
    const auto reg=[&](unsigned n){return U32(read_bytes(ctx.registers,layout::r0+4*n,4));};
    const auto vector=reg(0),source=reg(1),sp=reg(13),lr=reg(14);
    if(vector<4096||vector>0xfffffff3u||(vector&3)||(source&3)||sp<4116||(sp&3))return {};
    const auto stack=sp-20;
    if(overlaps(vector,12,stack,20))return {};
    try {
        Plan plan{storage};
        const auto count=plan.read32(vector+4),capacity=plan.read32(vector+8),next=count+1;
        if(as6_ui_source::signedLess(capacity,next))return {};
        const auto base=plan.read32(vector),offset=count<<3,destination=base+offset;
        if(destination&&(destination<4096||destination>0xfffffff7u||source<4096||source>0xfffffff7u||
           (destination&3)||overlaps(source,8,stack,20)||overlaps(destination,8,stack,20)))return {};
        // A successful stack write alone does not prove the epilogue can read
        // it. Preflight read permission/validity without changing any state.
        std::array<std::uint8_t,20> stackBytes;
        if(!storage.read(storage.owner,stack,stackBytes.data(),stackBytes.size()))return {};
        plan.write32(sp-4,lr);plan.write32(sp-8,reg(7));plan.write32(sp-12,reg(6));
        plan.write32(sp-16,reg(5));plan.write32(sp-20,reg(4));
        as6_ui_source::append<3>(plan,vector,source);
        U32 first=0,second=0;
        if(destination){first=plan.read32(source);second=plan.read32(source+4);}
        if(!storage.publish(storage.owner,plan.writes.data(),plan.count))return {};
        const auto set=[&](std::size_t at,unsigned n,U32 value){write_bytes(ctx.registers,at,n,value);};
        if(destination){set(layout::r0,4,first);set(layout::r1,4,second);}
        set(layout::r2,4,offset);set(layout::r3,4,base);set(layout::r12,4,destination);
        // Callee-saved r4..r7 and sp have their original values after return.
        set(128,4,sp);
        const auto carry=std::uint64_t(base)+offset>0xffffffffULL;
        const auto overflow=((~(base^offset)&(base^destination))>>31)&1;
        set(layout::NG,1,destination>>31);set(layout::ZR,1,destination==0);
        set(layout::CY,1,carry);set(layout::OV,1,overflow);
        set(0x64,1,destination>>31);set(0x65,1,destination==0);
        set(0x66,1,carry);set(0x67,1,overflow);set(0x68,1,next>=capacity);
        ctx.isa_thumb=bool(lr&1);set(105,1,ctx.isa_thumb);
        ctx.next_pc=lr&~1u;set(layout::pc,4,ctx.next_pc);
        ctx.budget-=18;ctx.status=Returned;
        return {true,plan.count,18};
    }catch(...){return {};}
}
}
