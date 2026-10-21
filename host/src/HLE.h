#ifndef PORT_HLE_H
#define PORT_HLE_H

#import "GuestTypes.h"
#import <Foundation/Foundation.h>

@class GuestVM;

#ifdef __cplusplus
extern "C" {
#endif

// One host-side implementation of a symbol the original armv7 binary imports.
// The guest follows AAPCS: r0-r3 then stack for integers, s0-d7 for floats.
typedef void (*HLEImpl)(GuestVM *vm);

// Register a host implementation for an import name exactly as it appears in
// the original binary's symbol table (leading underscore included).
void HLERegister(const char *symbol, HLEImpl impl);
// NULL when the original binary imports a symbol the host has not implemented.
HLEImpl HLELookup(const char *symbol);
// When an import has no hand-written implementation, forward it to the host
// dylib that exports the same symbol (NULL when the host has no such symbol).
HLEImpl HLEAutoImpl(const char *symbol);
// The import currently being dispatched, for the generic trampoline.
void HLESetCurrentSymbol(const char *symbol);
const char *HLECurrentSymbol(void);
// Host dylib symbol lookup, cached.
void *HLEHostSymbol(const char *symbol);
// True when the host bytes [p, p+len) are actually mapped readable.  Bound data
// slots are only a guess until they are read, so every candidate is checked.
BOOL HostPointerIsReadable(const void *p, size_t len);
// The 32-bit value the loader must write into a bound data slot.
uint32_t HLEDataValue(GuestVM *vm, const char *symbol, uint32_t slotAddr);
BOOL HLEDataAddress(GuestVM *vm, const char *symbol, uint32_t *out);
// NSString/CFString exported variables need guest-resident storage: an imported
// symbol pointer addresses this cell, whose word is the host object handle.
BOOL HLEObjectConstantAddress(GuestVM *vm, const char *symbol, uint32_t *out);
// Guest-resident C++ objects (COW empty-string rep, vtables, operator-new tags).
BOOL HLEStdCxxData(const char *symbol, GuestVM *vm, uint32_t *out);
void HLEInstallCxxAbi(void);
// Shared reusable per-VM libc heap, with 16-byte-aligned payloads (including
// size zero). Call while holding the VM lock. Owns is
// true only for the exact payload pointer of a currently live arena block.
// Permanent GuestAlloc storage and foreign/interior pointers are never owned.
gva_t GuestHeapAlloc(GuestVM *vm, size_t size);
BOOL GuestHeapFree(GuestVM *vm, gva_t pointer);
BOOL GuestHeapOwns(GuestVM *vm, gva_t pointer);
// Guest word <-> host pointer translation for the auto bridge.
void *HLEGuestToHostArg(GuestVM *vm, uint32_t v);
uint32_t HLEWrapOpaque(GuestVM *vm, void *p);
void *HLEUnwrapOpaque(GuestVM *vm, uint32_t v);
// Attach the host frame driver that keeps -[EAGLView drawView] running.
void GuestStartFrameDriver(void);
// The guest EAGLView instance the nib replay created.
gva_t GuestGLView(void);
gva_t GuestAppDelegate(void);
BOOL GuestExitRequested(void);
// Called only after an original native frame callback has returned.
void GuestNativeFrameDidComplete(GuestVM *vm, gva_t guestView);
// Present a root guest view in the original nib's 320x480 coordinate space.
BOOL GuestWindowAddSubview(GuestVM *vm, id window, gva_t guestSubview);
void GuestPlaceOriginalSkipControls(GuestVM *vm, gva_t guestView, id window);
// Commit completed native file I/O and deliver original guest signal handlers.
void HLEPosixPoll(GuestVM *vm);
void HLEPthreadTakeCPU(GuestVM *vm);
// Only call from deferred HLE dispatch while owning the VM lock. The
// synchronous native callback must use host storage, not guest memory/CPU.
// Release/restore all VM lock levels and the captured CPU owner. Failure to
// begin returns -1/errno with no callback or wait. After normal callback return,
// restore failure is -1/EIO; permanent VM stop is -1/ECANCELED. Otherwise preserve
// callback result/errno. NS/C++ exceptions propagate after cleanup, preserving
// immediate callback errno; host side effects and caller CPU are not rolled back.
int HLEPthreadBlockingCall(GuestVM *vm, int (*operation)(void *), void *context);
#ifdef __cplusplus
bool HLEPthreadCanYieldLocked(GuestVM *vm);
#endif
// Every import name the original binary needs, for coverage reporting.
void HLERecordNeeded(NSString *symbol);
NSUInteger HLENeededCount(void);
NSUInteger HLEImplementedCount(void);
NSArray<NSString *> *HLEMissingSymbols(void);

#ifdef __cplusplus
}
#endif

// Define a host implementation and bind it to an original import name.
#define HLE_DEFINE(fn) static void fn(GuestVM *vm)
#define HLE_CAT2(a, b) a##b
#define HLE_CAT(a, b) HLE_CAT2(a, b)
#define HLE_BIND(sym, fn)                                                       \
    __attribute__((constructor)) static void HLE_CAT(fn##_registrar_, __COUNTER__)(void) { \
        HLERegister((sym), (fn));                                                \
    }

#define GUEST_HOST_OPAQUE_BASE 0xE2000000u

#endif  // PORT_HLE_H

// --- system library provisioning (HLE_frameworks.m) -------------------------
#ifdef __cplusplus
extern "C" {
#endif
void HLELoadGuestFrameworks(void);
NSArray<NSString *> *HLELoadedLibraries(void);
NSArray<NSString *> *HLEAbsentLibraries(void);
NSDictionary<NSString *, NSNumber *> *HLEAuditImports(NSString *listPath,
                                                      NSArray<NSString *> **firstMissing);
#ifdef __cplusplus
}
#endif
