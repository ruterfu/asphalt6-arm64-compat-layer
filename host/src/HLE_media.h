#ifndef PORT_HLE_MEDIA_H
#define PORT_HLE_MEDIA_H

#import "GuestTypes.h"
#import <Foundation/Foundation.h>

@class GuestVM;

#ifdef __cplusplus
extern "C" {
#endif

// iOS 27 removed the whole MPMoviePlayer stack the 2011 intro videos are built
// on: the class still exists in the simulator runtime but never plays, and the
// MPMoviePlayer*Notification symbols it observes through are gone from the
// binary image entirely.  These three hooks give the guest a working video
// path without touching its own state machine.

// A host class to hand the guest instead of a dead one, or nil.
Class GuestMediaSubstituteClass(const char *className);

// The iPod music player feature is removed: these MediaPlayer music-library
// classes bind as nil, so the guest's own nil checks report no system music
// and the system never asks for media library access.
BOOL GuestMediaRemovedClass(const char *className);

// The NSString a missing Foundation/MediaPlayer string constant used to hold,
// or nil.  Without these the guest registers for every notification in the
// process because its name pointer binds to zero.
NSString *GuestMediaStringConstant(const char *symbol);

// -[NSNotificationCenter addObserver:selector:name:object:] where the observer
// is a guest object: the host centre cannot retain or message guest memory, so
// the registration is rebuilt as a block that re-enters guest code.
BOOL GuestMediaOverride(GuestVM *vm, id target, SEL sel);

#ifdef __cplusplus
}
#endif

#endif  // PORT_HLE_MEDIA_H
