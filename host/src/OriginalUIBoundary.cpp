#include "OriginalUIBoundary.hpp"
#include "NativeStartupRecovery.hpp"
#if defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
#error The real original UI boundary provider cannot be compiled with the absence fixture
#endif

namespace as6_original_ui {
namespace {
thread_local unsigned depth;
thread_local const as6aot::Context *resumeContext;
thread_local std::uint32_t resumePC;
}
bool isBoundary(std::uint32_t pc, bool thumb) {
    return !thumb && (pc == Advance || pc == Touch || pc == Display || pc == Unload || pc == RemoveChildNodeType);
}
bool suppressed() { return depth != 0; }
Suppress::Suppress() { ++depth; }
Suppress::~Suppress() { --depth; }
bool arm(as6aot::Context &ctx, std::uint32_t pc) {
    if (resumeContext || suppressed() || !isBoundary(pc, ctx.isa_thumb) || ctx.next_pc != pc) return false;
    resumeContext = &ctx; resumePC = pc; return true;
}
void cancel(as6aot::Context &ctx) {
    if(resumeContext==&ctx){resumeContext=nullptr;resumePC=0;}
}
as6aot::Status boundary(as6aot::Context &ctx, bool legacy, std::uint32_t stop, bool thumb) {
    using namespace as6aot;
    if (!isBoundary(ctx.next_pc, ctx.isa_thumb)) return ctx.status = InvalidState;
    if (!legacy && ctx.next_pc == stop && ctx.isa_thumb == thumb) return ctx.status = Returned;
    if (suppressed() || (resumeContext == &ctx && resumePC == ctx.next_pc)) {
        if (resumeContext == &ctx && resumePC == ctx.next_pc) { resumeContext = nullptr; resumePC = 0; }
        const auto *base = AS6NativeProgramWithStartupRecovery();
        const auto original = base ? base->lookup(ctx.next_pc, false) : nullptr;
        return original ? original(ctx, legacy, stop, thumb) : (ctx.status = UnresolvedTarget);
    }
    // No architectural register, memory, flag, fault, or budget changes.
    return ctx.status = UnresolvedTarget;
}
}
