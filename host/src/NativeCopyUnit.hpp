#pragma once
#include "aot_support.hpp"
#include "register_layout.hpp"
#include "HostDataMemory.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>

// Two no-callback CopyUnit loops; called only under the real Core data lease.
namespace as6_copy_unit {
using Span = as6hostdata::DataMemory::WriteSpan;
struct Storage {
    void *owner=nullptr;
    // Read failure is side-effect-free. Publication validates ALL spans before
    // any store, then preserves their order and existing monitor side effects.
    bool (*read)(void *,std::uint32_t,void *,std::size_t)=nullptr;
    bool (*publish)(void *,const Span *,std::size_t)=nullptr;
};
struct Result {bool handled=false;std::uint32_t records=0;std::uint64_t instructions=0;};
inline constexpr std::uint32_t Primary=0x3cfea4,Secondary=0x3d0098;
inline Result copy(const Storage &storage,as6aot::Context &ctx,
                   std::uint64_t totalRemaining,std::uint32_t stop,bool stopThumb) noexcept {
    const bool secondary=ctx.next_pc==Secondary;
    const auto entry=secondary?Secondary:Primary,exit=entry+44;
    if((ctx.next_pc!=Primary&&!secondary)||ctx.isa_thumb||(ctx.status!=as6aot::Returned&&ctx.status!=as6aot::UnresolvedTarget)||
       !ctx.registers||ctx.register_size<as6aot::layout::Size||!storage.owner||
       !storage.read||!storage.publish||ctx.budget!=totalRemaining||
       (!stopThumb&&stop>=entry&&stop<exit))return {};
    const auto reg=[&](unsigned n){return std::uint32_t(as6aot::read_bytes(ctx.registers,as6aot::layout::r0+n*4,4));};
    const unsigned counterRegister=secondary?12:0;
    const auto count=reg(10),counter=reg(counterRegister),src=reg(1),dst=reg(3),ss=reg(secondary?14:6),ds=reg(11);
    if(!count||count>65535||counter>=count||ss<12||ds<12||((src|dst|ss|ds)&3))return {};
    // Keep the current Core's 64 ordered-span publication bound. Each original
    // record has three distinct stores; merging them would change store ordinals.
    const auto records=std::uint32_t(std::min<std::uint64_t>({count-counter,ctx.budget/11,21}));
    if(!records)return {};
    const std::uint64_t sn=std::uint64_t(records-1)*ss+12,dn=std::uint64_t(records-1)*ds+12;
    if(src<4096||dst<4096||sn>(1u<<20)||sn>0x100000000ULL-src||dn>0x100000000ULL-dst||
       (std::uint64_t(src)<std::uint64_t(dst)+dn&&std::uint64_t(dst)<std::uint64_t(src)+sn))return {};
    try {
        std::vector<std::uint8_t> source(static_cast<std::size_t>(sn));
        if(!storage.read(storage.owner,src,source.data(),source.size()))return {};
        std::array<std::uint32_t,63> values{};
        std::array<Span,63> writes{};
        for(unsigned i=0;i<records;++i)for(unsigned lane=0;lane<3;++lane){
            const auto n=i*3+lane;
            std::memcpy(&values[n],source.data()+std::size_t(i)*ss+lane*4,4);
            writes[n]={std::uint32_t(std::uint64_t(dst)+std::uint64_t(i)*ds+lane*4),&values[n],4};
        }
        std::array<std::uint8_t,as6aot::layout::Size> next;
        std::memcpy(next.data(),ctx.registers,next.size());
        const auto set=[&](std::size_t at,unsigned width,std::uint32_t value){as6aot::write_bytes(next.data(),at,width,value);};
        const auto current=counter+records,remaining=count-current;
        const auto difference=current-count;
        const auto nextSrc=std::uint32_t(std::uint64_t(src)+std::uint64_t(records)*ss);
        const auto previousDst=std::uint32_t(std::uint64_t(dst)+std::uint64_t(records-1)*ds);
        const auto nextDst=std::uint32_t(std::uint64_t(previousDst)+ds);
        const auto nextPC=remaining?entry:exit;
        set(as6aot::layout::r0+4*counterRegister,4,current);
        set(as6aot::layout::r1,4,nextSrc);set(as6aot::layout::r2,4,values[3*records-1]);
        set(as6aot::layout::r3,4,nextDst);set(as6aot::layout::pc,4,nextPC);
        set(as6aot::layout::NG,1,difference>>31);set(as6aot::layout::ZR,1,current==count);
        set(as6aot::layout::CY,1,current>=count);
        set(as6aot::layout::OV,1,((current^count)&(current^difference))>>31);
        // Preserve the translated non-S final ADD's private scratch flags too.
        set(0x64,1,nextDst>>31);set(0x65,1,nextDst==0);
        set(0x66,1,std::uint64_t(previousDst)+ds>0xffffffffULL);
        set(0x67,1,((~(previousDst^ds)&(previousDst^nextDst))>>31)&1);
        set(0x68,1,current>=count);
        if(!storage.publish(storage.owner,writes.data(),records*3))return {};
        std::memcpy(ctx.registers,next.data(),next.size());
        ctx.next_pc=nextPC;ctx.budget-=records*11;
        ctx.status=as6aot::Returned;
        return {true,records,std::uint64_t(records)*11};
    } catch(...){return {};}
}
} // namespace as6_copy_unit
