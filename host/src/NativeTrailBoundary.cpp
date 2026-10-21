#include "NativeTrailBoundary.hpp"

namespace as6_trail_boundary {
namespace {
const as6aot::NativeProgram *baseProgram=nullptr;
as6aot::NativeFunction originalEntry=nullptr;
thread_local const as6aot::Context *resumeContext=nullptr;
as6aot::Status entry(as6aot::Context &ctx,bool legacy,std::uint32_t stop,bool stopThumb) {
    if(!ctx.registers||ctx.register_size<as6aot::layout::Size)return as6aot::InvalidState;
    if(ctx.next_pc!=Entry||ctx.isa_thumb)return as6aot::UnresolvedTarget;
    if(!legacy&&stop==Entry&&!stopThumb)return as6aot::Returned;
    if(!ctx.budget)return as6aot::BudgetExhausted;
    if(!legacy&&isBoundary(ctx)) {
        if(resumeContext==&ctx)resumeContext=nullptr;
        else if(!observesOriginalStop(stop,stopThumb))return as6aot::UnresolvedTarget;
    }
    return originalEntry(ctx,legacy,stop,stopThumb);
}
as6aot::NativeFunction lookup(std::uint32_t pc,bool thumb) {
    return pc==Entry&&!thumb?entry:baseProgram->lookup(pc,thumb);
}
struct Provider {
    const as6native::Provider *const original;
    const as6aot::NativeModule module{0,0x1ffffffffULL,lookup};
    const as6aot::NativeProgram program{&module,1,as6aot::layout::Size,as6aot::layout::pc};
    as6native::Provider provider;
    explicit Provider(const as6native::Provider *base):original(base),provider(*base) {
        baseProgram=base->program;originalEntry=baseProgram->lookup(Entry,false);
        provider.program=&program;
    }
};
}
bool isBoundary(const as6aot::Context &ctx) noexcept {
    // r4 belongs to TrailManager's already-advanced iterator, not this node.
    return ctx.next_pc==Entry&&!ctx.isa_thumb&&ctx.registers&&
           ctx.register_size>=as6aot::layout::Size&&
           as6aot::read_bytes(ctx.registers,as6aot::layout::lr,4)==PublicReturn;
}
bool observesOriginalStop(std::uint32_t stop,bool stopThumb) noexcept {
    if(stopThumb)return false;
    return (stop>=0x169fa0u&&stop<0x16aac0u)||
           (stop>=0x1690ecu&&stop<0x169300u)||
           (stop>=0x4cb17cu&&stop<0x4cb198u)||
           stop==0x6a32e0u||stop==0x6a3dc0u;
}
bool arm(as6aot::Context &ctx) noexcept {
    if(resumeContext||!isBoundary(ctx))return false;
    resumeContext=&ctx;return true;
}
void cancel(as6aot::Context &ctx) noexcept {
    if(resumeContext==&ctx)resumeContext=nullptr;
}
const as6native::Provider *withTrails(const as6native::Provider *base,ImmutableLinkedProvider) {
    if(!base||base->version!=as6native::ProviderVersion||!base->program||!base->program->valid()||
       base->program->register_size()!=as6aot::layout::Size||!base->program->lookup(Entry,false))return nullptr;
    static const Provider owned(base);
    return owned.original==base&&baseProgram==base->program&&originalEntry&&owned.program.valid()
        ?&owned.provider:nullptr;
}
}
