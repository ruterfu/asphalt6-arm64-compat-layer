#ifndef PORT_GUEST_OBJC_H
#define PORT_GUEST_OBJC_H

#import "GuestTypes.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@class GuestVM;
@class UIView;

#ifdef __cplusplus
extern "C" {
#endif

// Guest handle ranges. Host objects cannot be represented as 32-bit guest
// pointers, so they are handed to the guest as tagged handles.
#define GUEST_HOST_CLASS_BASE   0xE0000000u
#define GUEST_HOST_OBJECT_BASE  0xE0800000u
#define GUEST_HOST_SEL_BASE     0xE1000000u

#define GuestIsHostClass(h)  ((h) >= GUEST_HOST_CLASS_BASE  && (h) < GUEST_HOST_CLASS_BASE  + 0x800000u)
#define GuestIsHostObject(h) ((h) >= GUEST_HOST_OBJECT_BASE && (h) < GUEST_HOST_OBJECT_BASE + 0x800000u)

// Build the guest class registry from __objc_classlist. Must run after the
// image is mapped.
void GuestObjCBuildRegistry(GuestVM *vm);
BOOL GuestObjCBuildRegistryForBinding(GuestVM *vm, NSString **error);
// Guest class address -> class name, or nil.
NSString *GuestObjCNameForClass(GuestVM *vm, gva_t guestClass);
// Class name -> guest class address (in-image classes only).
gva_t GuestObjCClassNamed(GuestVM *vm, NSString *name);
// Guest metaclass address -> class name.
NSString *GuestObjCNameForMetaclass(GuestVM *vm, gva_t guestMeta);

// Guest SEL values are pointers to their name C-string in __TEXT,__cstring.
SEL GuestObjCSelFromGuest(GuestVM *vm, gva_t guestSel);
// Selector name -> the guest SEL value (pointer to a host-owned C string).
gva_t GuestObjCGuestSelNamed(GuestVM *vm, const char *name);

// Host object <-> guest handle.
// Unwrapped handles are *not* retained: the handle table owns the reference,
// and some Foundation objects (NSAutoreleasePool) reject objc_retain outright.
// The typedef is required -- clang silently ignores a lifetime qualifier
// written directly on a return type, which reintroduces the hidden retain.
typedef id __unsafe_unretained GuestUnsafeId;
GuestUnsafeId GuestObjCUnwrap(GuestVM *vm, gva_t handle);
gva_t GuestObjCWrap(GuestVM *vm, GuestUnsafeId object);
// Native delegates retain their original guest identity and invoke its IMPs.
id GuestObjCDelegateProxy(GuestVM *vm, gva_t guestObject);
gva_t GuestObjCDelegateGuestAddress(GuestUnsafeId object);
gva_t GuestObjCWrapClass(GuestVM *vm, Class cls);
Class GuestObjCUnwrapClass(GuestVM *vm, gva_t handle);

// Guest CFString (struct in __cfstring) -> NSString, nil if not one.
NSString *GuestObjCCFString(GuestVM *vm, gva_t gva);

// The old class_t.vtable import is an explicitly typed native dispatch
// identity. It is not a host object, generic opaque handle, array or function.
typedef BOOL (*GuestObjCSlowDispatchImpl)(GuestVM*,gva_t,gva_t,BOOL);
BOOL GuestObjCMetadataDataValue(GuestVM *vm,const char *symbol,gva_t slot,const void *nativeExport,GuestObjCSlowDispatchImpl dispatcher,uint32_t *out);
BOOL GuestObjCMetadataDataValid(GuestVM *vm,const char *symbol,gva_t slot,uint32_t word);
BOOL GuestObjCMetadataDispatchReady(GuestVM *vm,gva_t originalClass,GuestObjCSlowDispatchImpl dispatcher);
BOOL GuestObjCMetadataWord(uint32_t word);
gva_t GuestObjCMetadataIdentity(GuestVM *vm);
BOOL GuestObjCMetadataUsesExport(GuestVM *vm);

// Allocate a *guest* instance of a guest class: guest memory with isa set.
gva_t GuestObjCAllocInstance(GuestVM *vm, gva_t guestClass);
// class_ro_t.instanceSize for a guest class.
uint32_t GuestObjCInstanceSize(GuestVM *vm, gva_t guestClass);
// Convenience: guest alloc + -init (runs the guest's own -init if it has one).
gva_t GuestObjCNew(GuestVM *vm, gva_t guestClass);
// Send `name:` to a guest receiver and return r0. 0 when the class has no such
// method (the guest's superclass lives on the host side).
uint32_t GuestObjCSendName(GuestVM *vm, gva_t recv, const char *name);

// Dispatch one message. Returns YES when handled.
BOOL GuestObjCSend(GuestVM *vm, gva_t recv, gva_t sel, BOOL stret);

// The struct destination objc_msgSend_stret was given.  The trampoline has to
// move the receiver into r0 to reuse the normal dispatch path, so the buffer
// pointer is parked here for the code that writes the struct back.
void GuestSetStretDestination(gva_t dst);
gva_t GuestStretDestination(void);

// A guest UIView subclass gets a real arm64 view of the same shape as its
// shadow: -layer, -bounds, -setNeedsDisplay and friends have to answer with
// something UIKit actually composites.
UIView *GuestObjCShadow(GuestVM *vm, gva_t guestObject);
// Run `sel` against the host superclass of a guest object's shadow.
BOOL GuestSendToSuperclass(GuestVM *vm, gva_t recv, gva_t sel, Class hostSuper);

// The 2011 build sizes everything from [UIScreen mainScreen].bounds; the host
// answers with the display it was shipped for.  See HLE_device.m.
// Unified backing scale: Simulator may opt in to1; physical devices stay2.
double GuestScreenBackingScale(void);
BOOL GuestScreenOverride(GuestVM *vm, id target, SEL sel);
BOOL GuestDeviceOverride(GuestVM *vm, id target, SEL sel);

// +[NSTimer scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:]
// with a guest target: rebuilt as a block timer that calls back into guest code.
BOOL GuestTimerOverride(GuestVM *vm, id target, SEL sel);

#ifdef __cplusplus
}
#endif

#endif  // PORT_GUEST_OBJC_H
