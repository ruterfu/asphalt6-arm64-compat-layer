#ifndef AS6_NATIVE_GUEST_CPU_H
#define AS6_NATIVE_GUEST_CPU_H
#include <stdint.h>

#ifdef __OBJC__
@class GuestVM;
#else
typedef struct GuestVM GuestVM;
#endif
typedef struct GuestCpuSnapshot GuestCpuSnapshot;

typedef enum GuestExecutionResult {
    GuestExecutionSuccess = 0,
    GuestExecutionReturned = GuestExecutionSuccess,
    GuestExecutionUnresolvedTarget = 1,
    GuestExecutionMemoryFault = 2,
    GuestExecutionBudgetExhausted = 3,
    GuestExecutionInvalidState = 4,
    GuestExecutionArithmeticFault = 5,
    GuestExecutionUnsupportedSemantics = 7,
    GuestExecutionOriginalTrap = 8,
    GuestExecutionInvalidArgument = 0x100,
    GuestExecutionResourceLimit = 0x101,
    GuestExecutionForeignSnapshot = 0x102,
    GuestExecutionUnavailable = 0x103,
    GuestExecutionHalted = 0x104,
    GuestExecutionYielded = 0x105,
    // Only a stopped audio producer waiting for its unacquired mixer mutex.
    // This unwinds that callback without setting a permanent game fault.
    GuestExecutionCancelled = 0x106,
} GuestExecutionResult;

#ifdef __cplusplus
extern "C" {
#endif
// Caller owns the VM execution/bridge lock. Snapshots preserve CPU state only,
// including VFP/FPSCR/CPSR/PC and native budget/status; shared data is not copied.
// Allocate requires *output == NULL and binds the handle to this state's owner.
GuestExecutionResult GuestCPUAllocate(GuestVM *vm, GuestCpuSnapshot **output);
GuestExecutionResult GuestCPUSave(GuestVM *vm, GuestCpuSnapshot *snapshot);
GuestExecutionResult GuestCPURestore(GuestVM *vm, const GuestCpuSnapshot *snapshot);
// Free never dereferences the VM; a snapshot may safely outlive its owner.
void GuestCPUFree(GuestCpuSnapshot *snapshot);
GuestExecutionResult GuestGetCPSR(GuestVM *vm, uint32_t *output);
GuestExecutionResult GuestSetCPSR(GuestVM *vm, uint32_t value);
const char *GuestExecutionErrorText(GuestExecutionResult result);
#ifdef __cplusplus
}
#endif
#endif
