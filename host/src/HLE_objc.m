// Host implementations of the 11 libobjc symbols the original binary imports,
// plus the guest-side NSObject primitives (alloc/init) that the original got
// from Foundation's NSObject, whose class is external to the image.

#import "HLE.h"
#import "GuestObjC.h"
#import "GuestVM.h"
#import "HLE_media.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <vector>

static NSString *GuestNSString(GuestVM *vm, gva_t word) {
    id object = GuestIsHostObject(word) ? GuestObjCUnwrap(vm, word) : GuestObjCCFString(vm, word);
    return [object isKindOfClass:[NSString class]] ? object : nil;
}

HLE_DEFINE(hle_NSClassFromString) {
    NSString *name = GuestNSString(vm, GuestArg(vm, 0));
    gva_t original = name ? GuestObjCClassNamed(vm, name) : 0;
    Class host = name ? GuestMediaSubstituteClass(name.UTF8String) : Nil;
    if (!host && name && !GuestMediaRemovedClass(name.UTF8String)) host = NSClassFromString(name);
    GuestSetRet(vm, original ?: GuestObjCWrapClass(vm, host));
}
HLE_BIND("_NSClassFromString", hle_NSClassFromString)

HLE_DEFINE(hle_NSSelectorFromString) {
    NSString *name = GuestNSString(vm, GuestArg(vm, 0));
    GuestSetRet(vm, name ? GuestObjCGuestSelNamed(vm, name.UTF8String) : 0);
}
HLE_BIND("_NSSelectorFromString", hle_NSSelectorFromString)

HLE_DEFINE(hle_NSStringFromClass) {
    gva_t word = GuestArg(vm, 0);
    NSString *name = GuestIsHostClass(word) ? NSStringFromClass(GuestObjCUnwrapClass(vm, word)) :
        GuestObjCNameForClass(vm, word);
    GuestSetRet(vm, GuestObjCWrap(vm, name));
}
HLE_BIND("_NSStringFromClass", hle_NSStringFromClass)

HLE_DEFINE(hle_NSStringFromSelector) {
    SEL selector = GuestObjCSelFromGuest(vm, GuestArg(vm, 0));
    GuestSetRet(vm, GuestObjCWrap(vm, selector ? NSStringFromSelector(selector) : nil));
}
HLE_BIND("_NSStringFromSelector", hle_NSStringFromSelector)

HLE_DEFINE(hle_objc_msgSend) {
    GuestObjCSend(vm, GuestArg(vm, 0), GuestArg(vm, 1), NO);
}
HLE_BIND("_objc_msgSend", hle_objc_msgSend)

HLE_DEFINE(hle_objc_msgSend_stret) {
    // r0 is the guest destination struct pointer, r1 the receiver, r2 the sel.
    gva_t dst = GuestArg(vm, 0);
    gva_t recv = GuestArg(vm, 1);
    gva_t sel = GuestArg(vm, 2);
    uint32_t oldSp = GuestSP(vm);
    uint32_t firstArg = GuestArg(vm, 3);
    uint32_t secondArg = GuestArg(vm, 4);
    GuestSetReg(vm, 0, recv);
    GuestSetReg(vm, 1, sel);
    GuestSetReg(vm, 2, firstArg);
    GuestSetReg(vm, 3, secondArg);
    GuestSetReg(vm, 13, oldSp + 4);
    const gva_t savedStretDestination=GuestStretDestination();
    @try {
        GuestSetStretDestination(dst);
        GuestObjCSend(vm,recv,sel,YES);
    } @finally {
        GuestSetStretDestination(savedStretDestination);
        GuestSetReg(vm,13,oldSp);
    }
}
HLE_BIND("_objc_msgSend_stret", hle_objc_msgSend_stret)

HLE_DEFINE(hle_objc_msgSendSuper2) {
    // struct objc_super { id receiver; Class class; } -- the search starts at
    // the *superclass* of `class` for instance methods.
    gva_t superGva = GuestArg(vm, 0);
    gva_t recv = GuestReadU32(vm, superGva);
    gva_t cls = GuestReadU32(vm, superGva + 4);
    gva_t sel = GuestArg(vm, 1);
    if (GuestIsHostClass(cls)) {
        Class hostCls = GuestObjCUnwrapClass(vm, cls);
        Class superCls = class_getSuperclass(hostCls);
        if (superCls) {
            gva_t h = GuestObjCWrapClass(vm, superCls);
            GuestObjCSend(vm, GuestIsHostObject(recv) ? recv : h, sel, NO);
            return;
        }
        // A native root class has no guest class_t.superclass field to read.
        GuestRequestFault(vm);GuestSetRet(vm,0);return;
    }
    gva_t startAt = cls ? GuestReadU32(vm, cls + 4) : 0;  // class->superclass
    if (!startAt) { GuestSetRet(vm, 0); return; }
    if (GuestIsHostClass(startAt)) {
        // The guest class's superclass is a real arm64 class.  Its instance
        // methods live on the host side, so run them against the guest object's
        // shadow view; a failed super-init would abort the guest's own init.
        if (GuestSendToSuperclass(vm, recv, sel, GuestObjCUnwrapClass(vm, startAt))) return;
        GuestSetRet(vm, 0);
        return;
    }
    GuestObjCSend(vm, recv, sel, NO);
}
HLE_BIND("_objc_msgSendSuper2", hle_objc_msgSendSuper2)

HLE_DEFINE(hle_objc_setProperty) {
    // objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic,
    //                  signed char copy).  -[EAGLView setContext:] disassembles to
    //   mov r3, r2 / ldr r2, [pc, r2]
    // which pins the order: r2 is the ivar offset, r3 the value.  Reading them the
    // other way round made every guest property setter store the offset into the
    // object at an address derived from the value.
    gva_t self = GuestArg(vm, 0), offset = GuestArg(vm, 2), value = GuestArg(vm, 3);
    if (self) GuestWriteU32(vm, self + offset, value);
    GuestSetRet(vm, 0);
}
HLE_BIND("_objc_setProperty", hle_objc_setProperty)
HLE_BIND("_objc_setProperty_nonatomic_copy", hle_objc_setProperty)
HLE_BIND("_objc_setProperty_atomic", hle_objc_setProperty)
HLE_BIND("_objc_setProperty_nonatomic", hle_objc_setProperty)

HLE_DEFINE(hle_objc_sync_enter) {
    id obj = GuestObjCUnwrap(vm, GuestArg(vm, 0));
    if (obj) @synchronized(obj) { /* scope is advisory for the guest */ }
    GuestSetRet(vm, 0);
}
HLE_BIND("_objc_sync_enter", hle_objc_sync_enter)
HLE_BIND("_objc_sync_exit", hle_objc_sync_enter)

HLE_DEFINE(hle_objc_enumerationMutation) {
    GuestSetRet(vm, 0);
}
HLE_BIND("_objc_enumerationMutation", hle_objc_enumerationMutation)

HLE_DEFINE(hle_objc_copyStruct) {
    gva_t src = GuestArg(vm, 1), size = GuestArg(vm, 2), dst = GuestArg(vm, 0);
    std::vector<uint8_t> buf(size ? size : 1);
    if (src && dst && GuestRead(vm, src, buf.data(), buf.size())) {
        GuestWrite(vm, dst, buf.data(), buf.size());
    }
    GuestSetRet(vm, dst);
}
HLE_BIND("_objc_copyStruct", hle_objc_copyStruct)

// C++/ObjC exception plumbing. The original uses SJLJ unwinding (libgcc_s),
// so a throw cannot be propagated into guest code; the catch sites are logged
// instead so the gap is visible rather than silent.
HLE_DEFINE(hle_objc_begin_catch) { GuestSetRet(vm, GuestArg(vm, 0)); }
HLE_BIND("_objc_begin_catch", hle_objc_begin_catch)
HLE_DEFINE(hle_objc_end_catch) { GuestSetRet(vm, 0); }
HLE_BIND("_objc_end_catch", hle_objc_end_catch)
HLE_DEFINE(hle_objc_personality) { GuestSetRet(vm, 0); }
HLE_BIND("___objc_personality_v0", hle_objc_personality)

// --- NSObject primitives the guest cannot get from the host runtime ---------
// The guest's classes inherit from an external NSObject, so +alloc/+new must
// produce *guest* instances: guest memory with isa pointing at the guest class.

static gva_t GuestAllocInstance(GuestVM *vm, gva_t guestClass) {
    return GuestObjCAllocInstance(vm, guestClass);
}

// Intercept the two selectors before generic dispatch so guest classes can be
// instantiated even though their superclass lives on the host side.
static BOOL HandleAllocLike(GuestVM *vm) {
    gva_t recv = GuestArg(vm, 0);
    NSString *selName = GuestReadCString(vm, GuestArg(vm, 1), 128);
    if (GuestObjCNameForClass(vm, recv) && [selName isEqualToString:@"alloc"]) {
        GuestSetRet(vm, GuestAllocInstance(vm, recv));
        return YES;
    }
    if (GuestObjCNameForClass(vm, recv) && [selName isEqualToString:@"new"]) {
        GuestSetRet(vm, GuestObjCNew(vm, recv));
        return YES;
    }
    return NO;
}

HLE_DEFINE(hle_objc_msgSend_with_alloc) {
    if (HandleAllocLike(vm)) return;
    hle_objc_msgSend(vm);
}
// Rebind the primary entry point to the alloc-aware wrapper.
__attribute__((constructor)) static void rebind_msgSend(void) {
    HLERegister("_objc_msgSend", hle_objc_msgSend_with_alloc);
}
