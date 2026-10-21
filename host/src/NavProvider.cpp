#include "NavProvider.hpp"
#include "NativeDispatchCache.hpp"
#include <atomic>
extern "C" as6aot::NativeFunction as6_aot_lookup_native_00720_nav_prototype(std::uint32_t,bool);
namespace as6_nav_vm {namespace {
const as6aot::NativeProgram *baseProgram=nullptr;
std::atomic<const as6native::Provider *> authorized{nullptr};
// Cache the final immutable resolution, including navigation overrides and holes.
// This replaces the inner cache; there is still only one 64 KiB cache per thread.
as6aot::NativeFunction resolve(std::uint32_t pc, bool thumb) {
    const auto key = (std::uint64_t(pc) << 1) | std::uint64_t(thumb);
    if (key >= 0x3054c0 && key <= 0x3064e0)
        if (const auto found = as6_aot_lookup_native_00720_nav_prototype(pc, thumb))
            return found;
    return baseProgram->lookup(pc, thumb);
}
as6aot::NativeFunction lookup(std::uint32_t pc, bool thumb) {
    thread_local as6_native_dispatch::detail::LookupCache cache;
    return cache.lookup(pc, thumb, resolve);
}
struct Owned{const as6native::Provider*const original;const as6aot::NativeModule module{0,0x1ffffffffULL,lookup};const as6aot::NativeProgram program{&module,1,as6aot::layout::Size,as6aot::layout::pc};as6native::Provider provider;explicit Owned(const as6native::Provider*p):original(p),provider(*p){baseProgram=p->program;provider.program=&program;}};
}
const as6native::Provider*withNavigation(const as6native::Provider*p,ImmutableLinkedProvider){if(!p||p->version!=as6native::ProviderVersion||!p->program||!p->program->valid()||p->program->register_size()!=as6aot::layout::Size||!p->program->lookup(0x18320c,false))return nullptr;static const Owned owned(p);if(owned.original!=p||baseProgram!=p->program||!owned.program.valid())return nullptr;authorized.store(&owned.provider,std::memory_order_release);return &owned.provider;}
bool isLinkedProvider(const as6native::Provider*p)noexcept{return p&&p==authorized.load(std::memory_order_acquire);}
}
