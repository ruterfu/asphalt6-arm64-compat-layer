#pragma once
#include "GuestNativeProvider.hpp"
namespace as6_copy_boundary {
constexpr std::uint32_t Primary=0x3cfea4,Secondary=0x3d0098;
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withCopies(const as6native::Provider *,ImmutableLinkedProvider);
inline thread_local const as6aot::Context *resume=nullptr;
inline thread_local std::uint32_t resumePC=0;
inline bool isBoundary(const as6aot::Context &c) noexcept {
    return (c.next_pc==Primary||c.next_pc==Secondary)&&!c.isa_thumb&&c.registers&&
        c.register_size>=as6aot::layout::Size&&
        as6aot::read_bytes(c.registers,as6aot::layout::pc,4)==c.next_pc;
}
inline bool shouldSuspend(as6aot::Context &c,std::uint32_t stop,bool thumb) noexcept {
    if(!isBoundary(c))return false;
    if(resume==&c) {
        const auto expected=resumePC;resume=nullptr;resumePC=0;
        if(expected==c.next_pc)return false;
    }
    // Keep all original in-loop stops and tiny remaining slices on the original
    // path. The source loop is at most21 records (231 original instructions).
    const auto count=as6aot::read_bytes(c.registers,as6aot::layout::r10,4);
    const auto counter=as6aot::read_bytes(c.registers,c.next_pc==Secondary?as6aot::layout::r12:as6aot::layout::r0,4);
    return count<=65535&&counter<count&&count-counter>=8&&c.budget>=88&&
        (thumb||stop<c.next_pc||stop>=c.next_pc+44);
}
inline bool arm(as6aot::Context &c) noexcept {
    if(resume||!isBoundary(c))return false;
    resume=&c;resumePC=c.next_pc;return true;
}
inline void cancel(as6aot::Context &c) noexcept {if(resume==&c){resume=nullptr;resumePC=0;}}
inline bool pending(const as6aot::Context &c) noexcept {return resume==&c;}
}
