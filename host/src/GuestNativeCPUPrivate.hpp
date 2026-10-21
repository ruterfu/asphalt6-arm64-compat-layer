#pragma once
// Private native-backend seam. Common HLE/public headers never see NativeState
// or its storage. The native VM must return its live owned state under its lock.
#include "GuestCPU.h"
#include "native_state.hpp"

extern "C" as6aot::NativeState *GuestNativeCPUState(GuestVM *vm);

inline GuestExecutionResult GuestNativeExecutionResult(as6aot::Status status) {
    switch (status) {
        case as6aot::Returned: return GuestExecutionReturned;
        case as6aot::UnresolvedTarget: return GuestExecutionUnresolvedTarget;
        case as6aot::MemoryFault: return GuestExecutionMemoryFault;
        case as6aot::BudgetExhausted: return GuestExecutionBudgetExhausted;
        case as6aot::InvalidState: return GuestExecutionInvalidState;
        case as6aot::ArithmeticFault: return GuestExecutionArithmeticFault;
        case as6aot::UnsupportedSemantics: return GuestExecutionUnsupportedSemantics;
        case as6aot::OriginalTrap: return GuestExecutionOriginalTrap;
        default: return GuestExecutionInvalidState; // Internal Dispatch never escapes.
    }
}
