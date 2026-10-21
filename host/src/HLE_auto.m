// Automatic HLE bridge: any import the original armv7 binary expects that the
// arm64 host system already provides is forwarded straight to the host
// implementation, with the 32-bit guest calling convention translated to AAPCS64.
//
// Guest pointers below GUEST_HOST_TAG_BASE address guest memory and are passed
// through unchanged; values at or above it are host handles that are turned back
// into real 64-bit host pointers here.

#import "HLE.h"
#import "GuestVM.h"
#import "HLE_motion.h"
// Core-only Mac tests do not link the optional UIKit motion provider.
extern Class GuestMotionSubstituteClass(const char *) __attribute__((weak_import));
#import "GuestObjC.h"
#import "GuestTypes.h"
#import "HLE_media.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <string.h>
#import <string>
#import <unordered_map>
#import <unordered_set>
#import <mutex>
#import <vector>
#import <algorithm>
#import <utility>

// These three original class imports survive only as metadata after the store
// feature is removed. Give them an explicit unavailable identity without
// loading StoreKit. An unexpected attempt to construct one fails visibly.
@interface AS6RemovedStore : NSObject
@end
@implementation AS6RemovedStore
+ (id)alloc { return [self allocWithZone:NULL]; }
+ (id)allocWithZone:(NSZone *)zone {
    (void)zone;
    GuestVM *vm = GuestVMShared();
    GuestTrace(vm, @"[store] unexpected construction of removed Apple Store component");
    GuestRequestFault(vm);
    return nil;
}
+ (BOOL)canMakePayments { return NO; }
@end

// --- host handle tables -----------------------------------------------------
// Objects and classes live in GuestObjC; everything else opaque (CF objects,
// file handles, opaque structs, host malloc'd blocks that the guest only ever
// hands back to us) lives here.
#define GUEST_HOST_OPAQUE_BASE 0xE2000000u

static std::unordered_map<uint32_t, void *> g_opaque;
static std::unordered_map<void *, uint32_t> g_opaqueRev;
static uint32_t g_nextOpaque = GUEST_HOST_OPAQUE_BASE;

uint32_t HLEWrapOpaque(GuestVM *vm, void *p) {
    (void)vm;
    if (!p) return 0;
    auto it = g_opaqueRev.find(p);
    if (it != g_opaqueRev.end()) return it->second;
    uint32_t h = g_nextOpaque;
    g_nextOpaque += 4;
    g_opaque[h] = p;
    g_opaqueRev[p] = h;
    return h;
}

void *HLEUnwrapOpaque(GuestVM *vm, uint32_t v) {
    if(GuestObjCMetadataWord(v)){GuestRequestFault(vm);return nullptr;}
    (void)vm;
    if (v < GUEST_HOST_OPAQUE_BASE || v >= GUEST_HOST_OPAQUE_BASE + 0x10000000u) return NULL;
    auto it = g_opaque.find(v);
    return it == g_opaque.end() ? NULL : it->second;
}

// --- guest C strings handed to host callees --------------------------------
// A guest address is only an index into emulated memory: the moment a host
// function dereferences one the process dies (SCNetworkReachabilityCreateWithName
// with a guest hostname was a SIGSEGV at the guest heap address). When the
// bytes at a guest address form a plausible C string, the callee gets a host
// copy from a rotating arena instead -- the callee only needs it for the
// duration of the call.
static const size_t kStrSlotSize = 512;
static const int kStrSlotCount = 8192;
static char *g_strArena = nullptr;
static int g_strNext = 0;

static void *HostStringCopyFor(GuestVM *vm, uint32_t v) {
    if (!v || v >= GUEST_HOST_OPAQUE_BASE) return NULL;
    char probe[kStrSlotSize];
    if (!GuestRead(vm, v, probe, sizeof(probe))) return NULL;
    size_t len = 0;
    while (len < sizeof(probe) - 1 && probe[len]) len++;
    if (probe[len] != '\0' || len < 3) return NULL;   // not a terminated string
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)probe[i];
        if (c < 0x20 || (c >= 0x7f && c < 0xc2)) return NULL;  // binary, not text
    }
    if (!g_strArena) g_strArena = (char *)calloc(kStrSlotCount, kStrSlotSize);
    if (!g_strArena) return NULL;
    char *slot = g_strArena + (size_t)g_strNext * kStrSlotSize;
    g_strNext = (g_strNext + 1) % kStrSlotCount;
    memcpy(slot, probe, len + 1);
    return slot;
}

// Translate one guest register/stack word into what the host callee expects.
void *HLEGuestToHostArg(GuestVM *vm, uint32_t v) {
    if(GuestObjCMetadataWord(v)){GuestRequestFault(vm);return nullptr;}
    if (GuestIsHostObject(v)) return (__bridge void *)GuestObjCUnwrap(vm, v);
    if (GuestIsHostClass(v)) return (__bridge void *)GuestObjCUnwrapClass(vm, v);
    if (v >= GUEST_HOST_OPAQUE_BASE) return HLEUnwrapOpaque(vm, v);
    void *text = HostStringCopyFor(vm, v);
    if (text) return text;
    return (void *)(uintptr_t)v;   // guest address, passed through verbatim
}

// --- host symbol lookup -----------------------------------------------------
static std::unordered_map<std::string, void *> g_hostSyms;
static std::mutex g_hostLock;

// --- is this host pointer actually mapped? ---------------------------------
// A bound data slot is only a guess until it is read: the original image binds
// CF struct constants, class references and string constants through the same
// opcode, and dereferencing the wrong one of those is a SIGSEGV inside
// objc_msgSend.  Every candidate is checked against the VM map first.
static std::vector<std::pair<uintptr_t, uintptr_t>> g_readable;
static bool g_readableReady = false;

static void BuildReadableRanges(void) {
    if (g_readableReady) return;
    g_readableReady = true;
    mach_port_t task = mach_task_self();
    vm_address_t addr = 0;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    int guard = 0;
    while (guard++ < 20000) {
        kern_return_t kr = vm_region_64(task, &addr, &size, VM_REGION_BASIC_INFO_64,
                                       (vm_region_info_t)&info, &count, &objectName);
        if (kr != KERN_SUCCESS) break;
        if (info.protection & VM_PROT_READ) g_readable.push_back({addr, addr + size});
        addr += size;
        if (addr == 0) break;
    }
    std::sort(g_readable.begin(), g_readable.end());
}

// --- is this host value really an Objective-C object? ----------------------
// Reading the first word of an arbitrary dylib variable and treating it as an
// isa pointer is enough to send objc_retain/objc_msgSend into a data page.
// The only cheaply verifiable property is that the isa names a class the runtime
// actually knows about, so the registered-class list is snapshotted once and
// consulted instead of chasing pointers through class_rw_t.
static std::unordered_set<void *> g_hostClasses;
static bool g_hostClassesReady = false;

static void BuildHostClassSet(void) {
    if (g_hostClassesReady) return;
    g_hostClassesReady = true;
    unsigned int count = 0;
    Class *list = objc_copyClassList(&count);
    if (!list) return;
    g_hostClasses.reserve(count * 2);
    for (unsigned int i = 0; i < count; i++) g_hostClasses.insert((__bridge void *)list[i]);
    free(list);
}

BOOL HostValueIsObjCObject(const void *p) {
    if (!p) return NO;
    if (((uintptr_t)p) & 7) return NO;   // tagged/cached pointers are not dyld data symbols
    BuildHostClassSet();
    if (g_hostClasses.empty()) return NO;
    if (!HostPointerIsReadable(p, sizeof(void *))) return NO;
    void *isa = *(void *const *)p;
    if (!isa) return NO;
    if (g_hostClasses.count(isa)) return YES;
    void *masked = (void *)((uintptr_t)isa & 0x00000FFFFFFFCFFFULL);
    return g_hostClasses.count(masked) ? YES : NO;
}

BOOL HostPointerIsReadable(const void *p, size_t len) {
    if (!p || len == 0) return NO;
    BuildReadableRanges();
    uintptr_t lo = (uintptr_t)p, hi = lo + len;
    size_t l = 0, r = g_readable.size();
    while (l < r) {
        size_t m = (l + r) / 2;
        if (g_readable[m].second < lo) l = m + 1; else r = m;
    }
    if (l < g_readable.size() && lo >= g_readable[l].first && hi <= g_readable[l].second) return YES;
    if (l + 1 < g_readable.size() && lo >= g_readable[l + 1].first && hi <= g_readable[l + 1].second) return YES;
    return NO;
    return NO;
}

void *HLEHostSymbol(const char *symbol) {
    if (!symbol || symbol[0] == '\0') return NULL;
    std::lock_guard<std::mutex> lk(g_hostLock);
    auto it = g_hostSyms.find(symbol);
    if (it != g_hostSyms.end()) return it->second;
    const char *plain = (symbol[0] == '_') ? symbol + 1 : symbol;
    void *p = dlsym(RTLD_DEFAULT, plain);
    g_hostSyms[symbol] = p;
    return p;
}

// --- which imports hand back a host object/opaque pointer -------------------
// Anything the guest may later pass back to us has to come back as a handle,
// never as a raw 64-bit host pointer.
static bool ReturnsHostPointer(const char *s) {
    static const char *kPrefixes[] = {
        "_objc_", "_OBJC_", "_class_", "_method_", "_sel_", "_protocol_",
        "_CF", "_CG", "_NS", "_UI", "_CA", "_AV", "_MP", "_AB", "_ABRecord",
        "_AudioSession", "_EAGL", "_glGet", "_CA", "_SB", "_FB",
    };
    for (const char *p : kPrefixes) {
        if (strncmp(s, p, strlen(p)) == 0) {
            // Pure geometry / scalar helpers must NOT be wrapped.
            static const char *kScalar[] = {
                "_CGRectZero", "_CGSizeZero", "_CGPointZero", "_CGAffineTransformIdentity",
                "_CGColorSpaceRelease", "_CGContextRelease", "_CGPathRelease",
                "_CFRelease", "_CFRetain", "_CFMakeCollectable", "_CFAbsoluteTimeGetCurrent",
                "_CFGetTypeID", "_CFHash", "_CFEqual", "_CFGetRetainCount",
                "_CGRectIsNull", "_CGSizeEqualToSize", "_CGRectEqualToRect",
                "_CGRectContainsPoint", "_CGRectIntersectsRect", "_CGPointEqualToPoint",
                "_UIEdgeInsetsFromString", "_UIApplicationMain",
            };
            for (const char *q : kScalar) {
                if (strcmp(s, q) == 0) return false;
            }
            return true;
        }
    }
    static const char *kExact[] = {
        "_malloc", "_calloc", "_realloc", "_strdup", "_mmap", "_memalign",
        "_glGetString", "_glGetShaderiv", "_time", "_getenv",
    };
    for (const char *q : kExact) {
        if (strcmp(s, q) == 0) return true;
    }
    return false;
}

// --- the generic AAPCS trampoline ------------------------------------------
// Guest side: r0-r3 then the stack. Host side: x0-x7 then the stack. Passing
// eight words is harmless for callees with fewer parameters (caller cleanup).
typedef uint64_t (*HLEFn8)(uint64_t, uint64_t, uint64_t, uint64_t,
                           uint64_t, uint64_t, uint64_t, uint64_t);

static void hle_auto_generic(GuestVM *vm) {
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return;}
    const char *name = HLECurrentSymbol();
    void *target = name ? HLEHostSymbol(name) : NULL;
    if (!target) { GuestSetRet(vm, 0); return; }
    for(int i=0;i<8;++i)if(GuestObjCMetadataWord(GuestArg(vm,i))) {GuestRequestFault(vm);GuestSetRet(vm,0);return;}
    uint64_t a[8];
    for (int i = 0; i < 8; i++) a[i] = (uint64_t)(uintptr_t)HLEGuestToHostArg(vm, GuestArg(vm, i));
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return;}
    HLEFn8 fn = (HLEFn8)target;
    uint64_t r = fn(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    if (r == 0) { GuestSetRet(vm, 0); return; }
    if (name && ReturnsHostPointer(name)) {
        if (strncmp(name, "_OBJC_CLASS_$_", 14) == 0) {
            GuestSetRet(vm, GuestObjCWrapClass(vm, (__bridge Class)(void *)r));
        } else {
            if (HostValueIsObjCObject((void *)r)) {
                GuestSetRet(vm, GuestObjCWrap(vm, (__bridge __unsafe_unretained id)(void *)r));
            } else {
                GuestSetRet(vm, HLEWrapOpaque(vm, (void *)r));
            }
        }
        return;
    }
    GuestSetRet(vm, (uint32_t)(uint32_t)r);
}

HLEImpl HLEAutoImpl(const char *symbol) {
    if (!symbol) return NULL;
    if (symbol[0] == '_') {
        // Data symbols are patched by the loader, never called as code.
        if (strncmp(symbol, "_OBJC_CLASS_$_", 14) == 0) return NULL;
    }
    return HLEHostSymbol(symbol) ? hle_auto_generic : NULL;
}

// --- data symbols -----------------------------------------------------------
// The original image has 890 __cfstring slots, 77 external class references and
// a pile of C++ vtables/typeinfo that dyld would have bound for it. The loader
// asks here for the 32-bit value each slot should hold.
BOOL GuestCgDataValue(GuestVM *vm, const char *symbol, uint32_t *out);
BOOL GuestCFDataValue(GuestVM *vm, const char *symbol, uint32_t *out);
BOOL GuestCTypeDataValue(GuestVM *vm, const char *symbol, uint32_t *out);
BOOL GuestStdioDataValue(GuestVM *vm, const char *symbol, uint32_t *out);
BOOL GuestPlatformScalarDataValue(GuestVM *vm, const char *symbol, uint32_t *out);

BOOL HLEObjectConstantAddress(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!vm || !symbol || !out) return NO;
    // These exact imports are declared as NSString * const (or CFStringRef)
    // in their SDK headers. Do not infer data from prefixes: NS/MP also export
    // functions, which must remain executable trampolines.
    static const char *const names[] = {
        "_MPMediaItemPropertyAlbumTitle", "_MPMediaItemPropertyArtist",
        "_MPMediaItemPropertyPersistentID", "_MPMediaItemPropertyPlaybackDuration",
        "_MPMediaItemPropertyTitle", "_MPMediaLibraryDidChangeNotification",
        "_MPMediaPlaylistPropertyName",
        "_MPMusicPlayerControllerNowPlayingItemDidChangeNotification",
        "_MPMusicPlayerControllerPlaybackStateDidChangeNotification",
        "_NSDefaultRunLoopMode", "_NSErrorFailingURLStringKey",
        "_NSHTTPCookieDomain", "_NSHTTPCookieName", "_NSHTTPCookiePath",
        "_NSHTTPCookieValue", "_NSLocaleCountryCode", "_NSLocalizedDescriptionKey",
        "_UIApplicationLaunchOptionsRemoteNotificationKey",
        "_UIDeviceOrientationDidChangeNotification", "_UIKeyboardDidHideNotification",
        "_UIKeyboardDidShowNotification", "_UIKeyboardWillHideNotification",
        "_UIKeyboardWillShowNotification", "_UITextFieldTextDidChangeNotification",
        "_kCFBundleVersionKey", "_kCFRunLoopDefaultMode",
        "_kABWorkLabel", "_kCAMediaTimingFunctionEaseInEaseOut",
        "_kCAMediaTimingFunctionEaseOut", "_kCAMediaTimingFunctionLinear",
        "_kCATransitionFromBottom", "_kCATransitionFromLeft",
        "_kCATransitionFromRight", "_kCATransitionFromTop",
        "_kCATransitionMoveIn", "_kCATransitionPush", "_kCATransitionReveal",
        "_kEAGLColorFormatRGB565", "_kEAGLColorFormatRGBA8",
        "_kEAGLDrawablePropertyColorFormat", "_kEAGLDrawablePropertyRetainedBacking",
    };
    NSString *substitute = GuestMediaStringConstant(symbol);
    BOOL known = substitute != nil;
    for (const char *name : names) if (strcmp(symbol, name) == 0) { known = YES; break; }
    if (!known) return NO;

    // Each VM owns its address space; never reuse a cell from an older VM.
    static std::unordered_map<uintptr_t, std::unordered_map<std::string, uint32_t>> cells;
    auto &cache = cells[(uintptr_t)(__bridge void *)vm];
    auto found = cache.find(symbol);
    if (found != cache.end()) { *out = found->second; return YES; }

    id object = nil;
    void *addr = HLEHostSymbol(symbol);
    if (addr && HostPointerIsReadable(addr, sizeof(void *))) {
        void *value = *(void **)addr;
        if (HostValueIsObjCObject(value)) object = (__bridge id)value;
    }
    if (!object) object = substitute;
    if (!object) return NO;
    uint32_t handle = GuestObjCWrap(vm, object);
    uint32_t cell = GuestAlloc(vm, sizeof(handle));
    if (!handle || !cell) return NO;
    GuestWriteU32(vm, cell, handle);
    cache[symbol] = cell;
    *out = cell;
    char line[224];
    snprintf(line, sizeof(line), "[bind] string variable %s -> cell %#x = %#x",
             symbol, cell, handle);
    GuestRawLog(line);
    return YES;
}

BOOL HLEDataAddress(GuestVM *vm, const char *symbol, uint32_t *out) {
    return HLEObjectConstantAddress(vm, symbol, out) ||
           HLEStdCxxData(symbol, vm, out) || GuestCgDataValue(vm, symbol, out) ||
           GuestCFDataValue(vm, symbol, out) || GuestCTypeDataValue(vm, symbol, out) ||
           GuestStdioDataValue(vm, symbol, out) || GuestPlatformScalarDataValue(vm, symbol, out);
}

uint32_t HLEDataValue(GuestVM *vm, const char *symbol, uint32_t slotAddr) {
    if (!symbol) return 0;
    if(!strcmp(symbol,"__objc_empty_vtable")) {uint32_t word=0;return GuestObjCMetadataDataValue(vm,symbol,slotAddr,HLEHostSymbol(symbol),GuestObjCSend,&word)?word:0;}
    if (strncmp(symbol, "_OBJC_CLASS_$_", 14) == 0) {
        const char *cname = symbol + 14;
        if (!strcmp(cname, "SKProductsRequest") || !strcmp(cname, "SKPayment") ||
            !strcmp(cname, "SKPaymentQueue"))
            return GuestObjCWrapClass(vm, [AS6RemovedStore class]);
        gva_t guestCls = GuestObjCClassNamed(vm, [NSString stringWithUTF8String:cname]);
        if (guestCls) return guestCls;
        Class motion = GuestMotionSubstituteClass ? GuestMotionSubstituteClass(cname) : Nil;
        if (motion) return GuestObjCWrapClass(vm, motion);
        Class sub = GuestMediaSubstituteClass(cname);
        if (sub) return GuestObjCWrapClass(vm, sub);
        Class cls = objc_getClass(cname);
        if (!cls) {
            // iOS 27 removed a few frameworks the original linked against
            // (UIAccelerometer, AddressBook UI, ...). A nil class makes the
            // guest's own nil checks fire instead of crashing.
            return 0;
        }
        return GuestObjCWrapClass(vm, cls);
    }
    if (strncmp(symbol, "_OBJC_METACLASS_$_", 18) == 0) {
        Class motion = GuestMotionSubstituteClass ? GuestMotionSubstituteClass(symbol + 18) : Nil;
        if (motion) return GuestObjCWrapClass(vm, object_getClass(motion));
        Class substitute = GuestMediaSubstituteClass(symbol + 18);
        Class cls = substitute ? object_getClass(substitute) : objc_getMetaClass(symbol + 18);
        return cls ? GuestObjCWrapClass(vm, cls) : 0;
    }
    uint32_t objectCell = 0;
    if (HLEDataAddress(vm, symbol, &objectCell)) return objectCell;
    // CF constants (kCFAllocatorDefault, __kCFAllocatorSystemDefault...) and
    // Foundation string constants live in a dylib: bind the *variable*, not a
    // copy of it, so later reads see the real object.
    void *addr = HLEHostSymbol(symbol);
    if (!addr || !HostPointerIsReadable(addr, sizeof(void *))) return 0;
    void *value = *(void **)addr;
    if (HostValueIsObjCObject(value)) {
        static int s_objLog = 0;
        if (s_objLog++ < 80) {
            char line[224];
            snprintf(line, sizeof(line), "[bind] object symbol %s", symbol);
            GuestRawLog(line);
        }
        return GuestObjCWrap(vm, (__bridge __unsafe_unretained id)value);
    }
    return HLEWrapOpaque(vm, addr);
}
