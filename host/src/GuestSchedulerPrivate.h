#pragma once
// Private scheduler/VM lifecycle contract. Every *Locked call requires the
// actual VM lock. Owner ids come from the current NativeState snapshot owner;
// no raw VM address grants snapshot authority. These functions do not execute
// guest code. ResumeLocks restores locks only; scheduler ownership follows an
// explicit captured-owner check before touching CPU state.
#include "GuestCPU.h"
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
uint64_t GuestSchedulerOwnerLocked(GuestVM *vm);
GuestExecutionResult GuestSchedulerCanBlockLocked(GuestVM *vm);
int GuestSchedulerBorrowBeginLocked(GuestVM *vm,uint64_t owner);
void GuestSchedulerBorrowEndLocked(GuestVM *vm,uint64_t owner);
void GuestSchedulerResumeLocks(GuestVM *vm,size_t depth);
void HLEPthreadForgetCPUOwner(uint64_t owner);
#ifdef __cplusplus
}
#endif
