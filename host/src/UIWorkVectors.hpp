#pragma once
#include <cstdint>

// Restored source algorithms, not instruction handlers. The memory/allocator
// adapter owns address validation and failure policy. No ARM register context,
// dispatch loop or instruction container is used here.
namespace as6_ui_source {
using U32=std::uint32_t;
inline bool signedLess(U32 a,U32 b) noexcept {return (a^0x80000000u)<(b^0x80000000u);}
inline U32 growth(U32 n) noexcept {
    const U32 arithmeticHalf=(n>>1)|(n&0x80000000u);
    return n+arithmeticHalf;
}

// Original 0x324a64 (8-byte pair) and 0x324b9c (4-byte level).
// The capacity store precedes the allocator call, including failed allocations.
template<unsigned Shift,class M> void reserve(M &m,U32 vector,U32 capacity) {
    static_assert(Shift==2||Shift==3);
    if(m.read8(vector+12))return;
    const auto oldCapacity=m.read32(vector+8);
    m.write32(vector+8,capacity);
    const auto oldData=m.read32(vector);
    if(!capacity){
        if(oldData)m.release(oldData,oldCapacity<<Shift);
        m.write32(vector,0);
    } else {
        const auto data=oldData?m.reallocate(oldData,capacity<<Shift,oldCapacity<<Shift)
                               :m.allocate(capacity<<Shift);
        m.write32(vector,data);
    }
}

// Original 0x324b48 and 0x324c78. Do not combine the loads/stores:
// source can alias metadata or destination. Both pair words are loaded before
// either store, and count is reloaded only after the reserve call.
template<unsigned Shift,class M> void append(M &m,U32 vector,U32 source) {
    auto count=m.read32(vector+4);
    const auto capacity=m.read32(vector+8),next=count+1;
    if(signedLess(capacity,next)){
        reserve<Shift>(m,vector,growth(next));
        count=m.read32(vector+4);
    }
    const auto destination=m.read32(vector)+(count<<Shift);
    if(destination){
        const auto first=m.read32(source);
        if constexpr(Shift==3){
            const auto second=m.read32(source+4);
            m.write32(destination,first);m.write32(destination+4,second);
        } else m.write32(destination,first);
    }
    m.write32(vector+4,next);
}

// Original 0x324adc and 0x324c14. The initial count survives allocation;
// unlike append, resize does not reload it after the allocator callback.
template<unsigned Shift,class M> void resize(M &m,U32 vector,U32 requested) {
    auto count=m.read32(vector+4);
    if(requested&&signedLess(m.read32(vector+8),requested))
        reserve<Shift>(m,vector,growth(requested));
    auto offset=count<<Shift;
    for(;signedLess(count,requested);++count,offset+=(1u<<Shift)){
        const auto destination=m.read32(vector)+offset;
        if(destination){
            if constexpr(Shift==3){
                const auto defaults=m.read32(0x324b44);
                const auto first=m.read32(defaults),second=m.read32(defaults+4);
                m.write32(destination,first);m.write32(destination+4,second);
            } else m.write32(destination,0);
        }
    }
    m.write32(vector+4,requested);
}

// Original 0x324cc8. Here vector+0 is levels and vector+0x10 is pairs.
// The path-evaluation function receives a different containing-object base;
// its corresponding offsets are +0x18/+0x28. Keep that distinction explicit.
template<class M> void configure(M &m,U32 vector,U32 node,U32 path) {
    resize<3>(m,vector+0x10,0);
    resize<2>(m,vector,0);
    const auto boundary=m.read32(vector+0x14);
    m.withTemporaryWords(boundary,0,[&](U32 source){append<2>(m,vector,source);});
    m.withTemporaryWords(node,path,[&](U32 source){append<3>(m,vector+0x10,source);});
}
} // namespace as6_ui_source
