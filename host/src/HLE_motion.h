#pragma once
#import "GuestVM.h"
#import <Foundation/Foundation.h>
Class GuestMotionSubstituteClass(const char *name);
BOOL GuestMotionOverride(GuestVM *vm,id target,SEL selector);
// Call with the VM lock held, before validating/invoking the original callback.
BOOL GuestMotionCallbackIsCurrent(GuestVM *vm,id accelerometer,id acceleration);
// Call with the VM lock held, before invalidating/destroying its native state.
void GuestMotionForgetVM(GuestVM *vm);
NSDictionary *GuestMotionPerformanceSnapshot(void);
