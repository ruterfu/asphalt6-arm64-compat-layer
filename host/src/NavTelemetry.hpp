#pragma once
#include "NativeNavAdapter.hpp"
#include "register_layout.hpp"
#include <array>
#include <limits>
namespace as6_nav_vm {
inline void add(std::uint64_t &n,std::uint64_t amount=1) noexcept {const auto max=std::numeric_limits<std::uint64_t>::max();n=amount>max-n?max:n+amount;}
struct Telemetry {
 std::uint64_t attempts=0,handled=0,declined=0,native=0,exact=0,instructions=0,spans=0;
 std::uint64_t providerDeclines=0,workspaceDeclines=0,overQuantum=0;
 std::uint64_t clearsFinish=0,clearsFrame=0,clearsDestroy=0,clearsCall=0,clearsHandoff=0;
 std::array<std::uint64_t,std::size_t(as6_large_nav::Reason::CapacityDeclined)+1> reasons{};
 // unknown,zero,1..4,5..16,17..32,33..64,65..256,257..1024,1025..65536,over65536
 std::array<std::uint64_t,10> points{};
 // uniform+0,uniform-0,mixedzero,nonzero
 std::array<std::uint64_t,4> high{};
 void observe(as6native::Core &core,const as6aot::Context &c) noexcept {
  add(attempts);const auto first=as6aot::read_bytes(c.registers,as6aot::layout::d0+4,4);bool same=true,zero=!(first&0x7fffffffu);
  for(unsigned d=1;d<=8;++d){const auto word=as6aot::read_bytes(c.registers,as6aot::layout::d0+8*d+4,4);same&=word==first;zero&=!(word&0x7fffffffu);}
  add(high[!zero?3:!same?2:first?1:0]);unsigned bucket=0;
  const auto manager=std::uint32_t(as6aot::read_bytes(c.registers,as6aot::layout::r0+4,4)),index=std::uint32_t(as6aot::read_bytes(c.registers,as6aot::layout::r0+8,4));
  const auto slot=std::uint64_t(manager)+4*(std::uint64_t(index)+1);std::uint32_t line=0,n=0;
  if(index<=4095&&slot>=4096&&slot<=0xfffffffbu&&core.read(std::uint32_t(slot),&line,4)&&std::uint64_t(line)+0x14<=0x100000000ULL&&line+0x10>=4096&&core.read(line+0x10,&n,4))bucket=!n?1:n<=4?2:n<=16?3:n<=32?4:n<=64?5:n<=256?6:n<=1024?7:n<=65536?8:9;
  add(points[bucket]);
 }
 void finish(const as6_large_nav::Result&r) noexcept {add(reasons[std::size_t(r.reason)]);if(r.decision==as6_large_nav::Decision::Handled){add(handled);if(r.originalInstructions>8192)add(overQuantum);add(r.computed.usedNativeArithmetic?native:exact);add(instructions,r.originalInstructions);add(spans,r.writeCount);}else add(declined);}
};
}
