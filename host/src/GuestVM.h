#ifndef PORT_GUEST_VM_H
#define PORT_GUEST_VM_H

#import <Foundation/Foundation.h>
#import "GuestCPU.h"
#import "GuestTypes.h"

#ifdef __cplusplus
namespace as6native { struct Provider; }
#endif

#ifdef __cplusplus
extern "C" {
#endif

@class GuestVM;

// --- lifecycle -------------------------------------------------------------
GuestVM *GuestVMCreate(NSError **error);
#ifdef __cplusplus
// Immutable static descriptors must outlive the VM. Only declared data spans
// are copied; code comes exclusively from the linked NativeProgram.
GuestVM *GuestVMCreateNative(const as6native::Provider *provider, NSError **error);
#endif
GuestExecutionResult GuestLastExecutionResult(GuestVM *vm);
// Permanent atomic stop latches only; a retryable stored budget status is not
// a stop request. Native bridges use this before host-side effects.
BOOL GuestHasStopRequest(GuestVM *vm);
// Migration failure only: this never opens, maps or parses an executable.
BOOL GuestVMLoadMachO(GuestVM *vm, NSString *path, NSError **error);
BOOL GuestVMRun(GuestVM *vm, gva_t entry, uint32_t cpsrInit, uint64_t maxInsns, NSError **error);
void GuestVMDestroy(GuestVM *vm);

// --- guest memory ----------------------------------------------------------
BOOL GuestRead(GuestVM *vm, gva_t gva, void *dst, size_t len);
BOOL GuestWrite(GuestVM *vm, gva_t gva, const void *src, size_t len);
BOOL GuestFill(GuestVM *vm, gva_t gva, size_t len);   // map zeroed RW pages
gva_t GuestAlloc(GuestVM *vm, size_t size);
uint32_t GuestReadU32(GuestVM *vm, gva_t gva);
void GuestWriteU32(GuestVM *vm, gva_t gva, uint32_t value);
// Copies a NUL-terminated guest C string into an NSString (UTF-8, lossy).
NSString *GuestReadCString(GuestVM *vm, gva_t gva, size_t maxLen);
// Copies an NSString into freshly allocated guest memory as UTF-8.
gva_t GuestWriteCString(GuestVM *vm, NSString *s);
// Length of a NUL-terminated guest string, scanning in bounded chunks so a
// wild pointer can never make the host allocate an unbounded buffer.
size_t GuestStrLen(GuestVM *vm, gva_t gva, size_t cap);
// Byte-exact strcpy between two guest addresses.  Returns the number of bytes
// written including the terminating NUL, or (size_t)-1 on failure.
size_t GuestStrCopy(GuestVM *vm, gva_t dst, gva_t src, size_t cap);

// --- registers -------------------------------------------------------------
uint32_t GuestReg(GuestVM *vm, int regIndex);   // 0..15 = r0..r15
void GuestSetReg(GuestVM *vm, int regIndex, uint32_t value);
float GuestRegS0(GuestVM *vm);
double GuestRegD0(GuestVM *vm);
void GuestSetRegD0(GuestVM *vm, double value);
void GuestSetRegS0(GuestVM *vm, float value);
uint32_t GuestPC(GuestVM *vm);
void GuestSetPC(GuestVM *vm, uint32_t pc);
uint32_t GuestSP(GuestVM *vm);
uint32_t GuestLR(GuestVM *vm);

// Darwin armv7 softfp argument words (r0-r3, then stack).
uint32_t GuestArg(GuestVM *vm, int i);
// Floating helpers use float-word indices / consecutive double indices.
double GuestArgD(GuestVM *vm, int i);
float GuestArgF(GuestVM *vm, int i);
void GuestSetRet(GuestVM *vm, uint32_t v);
void GuestSetRetD(GuestVM *vm, double v);
void GuestSetRetF(GuestVM *vm, float v);
// Returns after a call: pops the AAPCS frame and resumes at the saved link.
void GuestReturn(GuestVM *vm);

// --- host -> guest calls ---------------------------------------------------
// Invokes a guest function with up to 4 integer arguments and returns r0.
uint32_t GuestCall(GuestVM *vm, gva_t fn, const uint32_t *args, int nargs, uint64_t maxInsns);
// Fixed original-address/native-bridge-ID lookup. Unknown symbols return zero;
// no trap slots are allocated and no instruction bytes are written.
gva_t GuestHLEAddress(GuestVM *vm, const char *symbol);
// Serialises every entry into guest code; host threads that need to run guest
// code take it around GuestCall.
void GuestLock(GuestVM *vm);
BOOL GuestTryLock(GuestVM *vm);
void GuestUnlock(GuestVM *vm);
NSUInteger GuestSuspendLocks(GuestVM *vm);
void GuestResumeLocks(GuestVM *vm, NSUInteger depth);
// HLE dispatch happens after native execution has returned, so blocking host calls can
// safely hand the VM to another guest thread without overlapping native CPU frames.
GuestExecutionResult GuestEmulate(GuestVM *vm, gva_t begin, gva_t until, uint64_t maxInsns);
void GuestRegisterStack(GuestVM *vm, gva_t base, uint32_t size);
BOOL GuestStackContains(GuestVM *vm, gva_t sp, uint32_t headroom);
// The single shared VM, installed by the app host.
GuestVM *GuestVMShared(void);
void GuestVMSetShared(GuestVM *vm);

// --- image metadata --------------------------------------------------------
uint32_t GuestSectionAddress(GuestVM *vm, const char *name);
uint32_t GuestSectionSize(GuestVM *vm, const char *name);
// True when gva points at a section's file-backed range.
BOOL GuestSectionContains(GuestVM *vm, const char *name, uint32_t gva);

// --- tracing ---------------------------------------------------------------
void GuestTrace(GuestVM *vm, NSString *fmt, ...);
void GuestRunModInitFuncs(GuestVM *vm);   // dyld's C++ static initialisers
// Allocation-free trace line, safe to call where even NSString formatting
// could be the thing that traps.
void GuestRawLog(const char *line);
// Load the original image's function table (address<TAB>name<TAB>size) so every
// trace line can name the 2011 Gameloft routine it is inside.
void GuestLoadSymbols(NSString *tsvPath);
// "drawView+0x268" for a guest PC, or "0xADDR" when nothing contains it.
NSString *GuestSymbolAt(uint32_t pc);
// Recent native execution/bridge boundaries, resolved to original identities.
// Allocation-free so it is safe from a signal handler.
int GuestRecentPcsRaw(GuestVM *vm, char *dst, size_t cap, int count);
int GuestRecentSpsRaw(char *dst, size_t cap, int count);
void GuestInstallProbe(GuestVM *vm, uint32_t lo, uint32_t hi);
void GuestDumpRecentTraps(GuestVM *vm, int count);
// Stop at the next bridge boundary; halt/fault latches survive CPU restore.
void GuestRequestHalt(GuestVM *vm);
// Return this entry invocation to the host UI loop. Future native callbacks
// remain valid; this request cannot clear a permanent halt or fault.
void GuestYieldToHostRunLoop(GuestVM *vm);
// A bridge detected invalid guest state; later timer/callback entries must
// not continue through a partially initialized original program.
void GuestRequestFault(GuestVM *vm);
NSString *GuestTraceText(GuestVM *vm);
NSArray<NSString *> *GuestTraceLog(GuestVM *vm);
// Diagnostic snapshot survives nested callback CPU restoration.
NSDictionary<NSString *, id> *GuestExecutionDiagnostics(GuestVM *vm);
void GuestSetTraceEnabled(GuestVM *vm, BOOL enabled);
NSUInteger GuestUnimplementedCount(GuestVM *vm);
NSDictionary<NSString *, NSNumber *> *GuestUnimplementedCounts(GuestVM *vm);
NSUInteger GuestCallCount(GuestVM *vm);
NSUInteger GuestAutoBridgeCount(GuestVM *vm);
NSUInteger GuestBindSlotCount(GuestVM *vm);

#ifdef __cplusplus
}
#endif

@interface GuestVM : NSObject
@property(nonatomic, readonly) BOOL loaded;
@property(nonatomic, readonly) gva_t entryPoint;
// Executable text is never mapped into data storage; these return zero.
@property(nonatomic, readonly) gva_t textBase;
@property(nonatomic, readonly) gva_t textSize;
// CPU snapshots and CPSR access use GuestCPU.h; no backend engine is public.
@end

#endif  // PORT_GUEST_VM_H
