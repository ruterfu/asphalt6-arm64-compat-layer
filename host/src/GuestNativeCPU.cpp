#include "GuestNativeCPUPrivate.hpp"
#include "NativeNavBoundary.hpp"
#include "NativeCopyBoundary.hpp"
#include "NativeUIWorkBoundary.hpp"
#include <new>

struct GuestCpuSnapshot {
    as6aot::NativeState::Snapshot saved{};
    std::uint64_t owner = 0;
    bool initialized = false;
};

static as6aot::NativeState *state(GuestVM *vm) {
    return vm ? GuestNativeCPUState(vm) : nullptr;
}

static bool valid_current(const as6aot::NativeState::Snapshot &snapshot) {
    return snapshot.owner &&
           std::uint32_t(as6aot::read_bytes(snapshot.registers.data(), as6aot::layout::pc, 4)) == snapshot.pc &&
           !(snapshot.pc & (snapshot.thumb ? 1u : 3u)) &&
           snapshot.status <= as6aot::OriginalTrap && snapshot.status != as6aot::Dispatch;
}

extern "C" GuestExecutionResult GuestCPUAllocate(GuestVM *vm, GuestCpuSnapshot **output) {
    if (!output || *output) return GuestExecutionInvalidArgument;
    auto *cpu = state(vm);
    if (!cpu) return GuestExecutionUnavailable;
    auto current = cpu->save();
    if (!valid_current(current)) return GuestExecutionInvalidState;
    auto *snapshot = new (std::nothrow) GuestCpuSnapshot;
    if (!snapshot) return GuestExecutionResourceLimit;
    snapshot->owner = current.owner;
    *output = snapshot;
    return GuestExecutionSuccess;
}

extern "C" GuestExecutionResult GuestCPUSave(GuestVM *vm, GuestCpuSnapshot *snapshot) {
    if (!snapshot) return GuestExecutionInvalidArgument;
    auto *cpu = state(vm);
    if (!cpu) return GuestExecutionUnavailable;
    auto current = cpu->save();
    if (current.owner != snapshot->owner) return GuestExecutionForeignSnapshot;
    if (!valid_current(current)) return GuestExecutionInvalidState;
    snapshot->saved = current;
    snapshot->initialized = true;
    return GuestExecutionSuccess;
}

extern "C" GuestExecutionResult GuestCPURestore(GuestVM *vm, const GuestCpuSnapshot *snapshot) {
    if (!snapshot) return GuestExecutionInvalidArgument;
    auto *cpu = state(vm);
    if (!cpu) return GuestExecutionUnavailable;
    if (cpu->save().owner != snapshot->owner) return GuestExecutionForeignSnapshot;
    // A CPU image never carries a source-entry retry capability.
    as6_nav_boundary::cancel(cpu->context());
    as6_copy_boundary::cancel(cpu->context());
    
    if (!snapshot->initialized || !cpu->restore(snapshot->saved)) return GuestExecutionInvalidState;
    return GuestExecutionSuccess;
}

extern "C" void GuestCPUFree(GuestCpuSnapshot *snapshot) { delete snapshot; }

extern "C" GuestExecutionResult GuestGetCPSR(GuestVM *vm, std::uint32_t *output) {
    if (!output) return GuestExecutionInvalidArgument;
    auto *cpu = state(vm);
    if (!cpu) return GuestExecutionUnavailable;
    *output = cpu->cpsr();
    return GuestExecutionSuccess;
}

extern "C" GuestExecutionResult GuestSetCPSR(GuestVM *vm, std::uint32_t value) {
    auto *cpu = state(vm);
    if (!cpu) return GuestExecutionUnavailable;
    return cpu->set_cpsr(value) ? GuestExecutionSuccess : GuestExecutionUnsupportedSemantics;
}

extern "C" const char *GuestExecutionErrorText(GuestExecutionResult result) {
    switch (result) {
        case GuestExecutionSuccess: return "returned/success";
        case GuestExecutionUnresolvedTarget: return "unresolved native target";
        case GuestExecutionMemoryFault: return "data memory fault";
        case GuestExecutionBudgetExhausted: return "native instruction budget exhausted";
        case GuestExecutionInvalidState: return "invalid native CPU state";
        case GuestExecutionArithmeticFault: return "arithmetic fault";
        case GuestExecutionUnsupportedSemantics: return "unsupported native semantics";
        case GuestExecutionOriginalTrap: return "original undefined-instruction trap";
        case GuestExecutionInvalidArgument: return "invalid CPU bridge argument";
        case GuestExecutionResourceLimit: return "CPU snapshot allocation failed";
        case GuestExecutionForeignSnapshot: return "snapshot belongs to another CPU state";
        case GuestExecutionUnavailable: return "native CPU state unavailable";
        case GuestExecutionHalted: return "native execution halted";
        case GuestExecutionYielded: return "control handed to the host UI loop";
        case GuestExecutionCancelled: return "stopped audio callback cancelled before mutex acquisition";
        default: return "unknown native execution result";
    }
}
