// Explicit absence of device motion in Foundation-only macOS VM fixtures.
// This source is not a production provider and must never enter App inputs.
#include <TargetConditionals.h>
#if !TARGET_OS_OSX || !defined(AS6_MACOS_MOTION_ABSENCE_FIXTURE)
#error MotionAbsence.mm is restricted to explicitly selected macOS test fixtures
#endif
#import "HLE_motion.h"

Class GuestMotionSubstituteClass(const char *) { return Nil; }
void GuestMotionForgetVM(GuestVM *) {}
