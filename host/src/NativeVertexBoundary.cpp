#include "NativeVertexBoundary.hpp"

extern "C" as6aot::NativeFunction as6_native_vertex_lookup_02556(std::uint32_t,bool);
namespace as6_vertex_boundary {
namespace {
const as6aot::NativeProgram *baseProgram=nullptr;
thread_local const as6aot::Context *resumeContext=nullptr;
as6aot::NativeFunction lookup(std::uint32_t pc,bool thumb) {
    // Own every real entry in the copied original shard, including loop
    // continuations. Internal gotos therefore cannot bypass the boundary.
    const auto key=(std::uint64_t(pc)<<1)|std::uint64_t(thumb);
    if(key>=0xa8add0ULL&&key<=0xa8bdf0ULL)
        if(const auto found=as6_native_vertex_lookup_02556(pc,thumb))return found;
    return baseProgram->lookup(pc,thumb);
}
struct Provider {
    const as6native::Provider *const original;
    const as6aot::NativeModule module{0,0x1ffffffffULL,lookup};
    const as6aot::NativeProgram program{&module,1,as6aot::layout::Size,as6aot::layout::pc};
    as6native::Provider provider;
    explicit Provider(const as6native::Provider *base):original(base),provider(*base) {
        baseProgram=base->program;provider.program=&program;
    }
};
}
bool isBoundary(const as6aot::Context &ctx) noexcept {
    return ctx.next_pc==Entry&&!ctx.isa_thumb&&ctx.registers&&
           ctx.register_size>=as6aot::layout::Size;
}
bool stopInsideLoop(std::uint32_t stop,bool stopThumb) noexcept {
    return !stopThumb&&stop>=Entry&&stop<=LastInstruction;
}
bool shouldSuspend(as6aot::Context &ctx,std::uint32_t stop,bool stopThumb) noexcept {
    if(!isBoundary(ctx))return false;
    if(resumeContext==&ctx){resumeContext=nullptr;return false;}
    const auto count=as6aot::read_bytes(ctx.registers,as6aot::layout::r1,4);
    return count&&count<=65535&&ctx.budget>=InstructionsPerVertex&&!stopInsideLoop(stop,stopThumb);
}
bool arm(as6aot::Context &ctx) noexcept {
    if(resumeContext||!isBoundary(ctx))return false;
    resumeContext=&ctx;return true;
}
void cancel(as6aot::Context &ctx) noexcept {
    if(resumeContext==&ctx)resumeContext=nullptr;
}
const as6native::Provider *withVertices(const as6native::Provider *base,ImmutableLinkedProvider) {
    if(!base||base->version!=as6native::ProviderVersion||!base->program||!base->program->valid()||
       base->program->register_size()!=as6aot::layout::Size||!base->program->lookup(Entry,false))return nullptr;
    static const Provider owned(base);
    return owned.original==base&&baseProgram==base->program&&owned.program.valid()?&owned.provider:nullptr;
}
}
