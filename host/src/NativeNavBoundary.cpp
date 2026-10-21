#include "NativeNavBoundary.hpp"
#include "register_layout.hpp"
namespace as6_nav_boundary {
namespace {thread_local const as6aot::Context *resume=nullptr;}
bool isBoundary(const as6aot::Context &c) noexcept {return c.registers&&c.register_size>=as6aot::layout::Size&&c.next_pc==Entry&&!c.isa_thumb&&as6aot::read_bytes(c.registers,as6aot::layout::pc,4)==Entry;}
bool shouldSuspend(as6aot::Context &c,std::uint32_t,bool) noexcept {
 if(!isBoundary(c))return false;
 if(resume==&c){resume=nullptr;return false;}
 return true;
}
bool arm(as6aot::Context &c) noexcept {if(resume||!isBoundary(c))return false;resume=&c;return true;}
void cancel(as6aot::Context &c) noexcept {if(resume==&c)resume=nullptr;}
bool pending(const as6aot::Context &c) noexcept{return resume==&c;}
}
