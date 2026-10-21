// Host implementations of the libSystem symbols the original armv7 binary
// imports. Guest pointers are 32-bit, so every host object handed back to the
// guest (FILE*, DIR*, malloc blocks, strings) goes through a handle table or
// real guest memory.

#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"
#import "BackgroundResources.h"
#import "ResourcePaths.h"

#import <dlfcn.h>
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <string>
#import <algorithm>
#import <cctype>
#import <unordered_map>
#import <sys/ioctl.h>
#import <vector>
#import <sys/stat.h>
#import <sys/time.h>
#import <time.h>
#import <unistd.h>

// errno belongs to a guest thread. Capture it immediately after failing host
// calls, before Foundation logging and emulator bookkeeping can change the
// host's TLS errno. Each host thread owns its own guest-visible errno cell.
static thread_local GuestVM *__unsafe_unretained g_errnoVM = nil;
static thread_local gva_t g_errnoCell = 0;
static thread_local int g_errnoValue = 0;
void HLESetGuestErrno(GuestVM *vm, int value) {
    if (g_errnoVM != vm) { g_errnoVM = vm; g_errnoCell = 0; }
    g_errnoValue = value;
    if (g_errnoCell) GuestWriteU32(vm, g_errnoCell, (uint32_t)value);
}
static void GuestSetSystemRet(GuestVM *vm, int64_t result) {
    int saved = errno;
    if (result < 0) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, (uint32_t)result);
}

// --- handle tables ---------------------------------------------------------

static NSMutableArray<NSValue *> *g_files = nil;      // handle -> FILE*
static NSMutableArray<NSValue *> *g_dirs = nil;       // handle -> DIR*
static NSMutableDictionary<NSNumber *, id> *g_opaque = nil;  // handle -> object
static uint32_t g_fileBase = 0xF0000000u;
static uint32_t g_dirBase = 0xF1000000u;
static uint32_t g_opaqueBase = 0xF2000000u;

static void EnsureTables(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_files = [NSMutableArray array];
        g_dirs = [NSMutableArray array];
        g_opaque = [NSMutableDictionary dictionary];
        [g_files addObject:[NSValue valueWithPointer:stdout]];
        [g_files addObject:[NSValue valueWithPointer:stderr]];
        [g_files addObject:[NSValue valueWithPointer:stdin]];
    });
}

static uint32_t FileHandle(FILE *f) {
    EnsureTables();
    for (NSUInteger i = 0; i < g_files.count; i++) {
        if (g_files[i].pointerValue == f) return g_fileBase + (uint32_t)i;
    }
    [g_files addObject:[NSValue valueWithPointer:f]];
    return g_fileBase + (uint32_t)(g_files.count - 1);
}

static FILE *FileOf(uint32_t h) {
    EnsureTables();
    if (h >= g_fileBase && (h - g_fileBase) < (uint32_t)g_files.count) {
        return (FILE *)g_files[h - g_fileBase].pointerValue;
    }
    return NULL;
}

static uint32_t DirHandle(DIR *d) {
    EnsureTables();
    [g_dirs addObject:[NSValue valueWithPointer:d]];
    return g_dirBase + (uint32_t)(g_dirs.count - 1);
}

static DIR *DirOf(uint32_t h) {
    EnsureTables();
    if (h >= g_dirBase && (h - g_dirBase) < (uint32_t)g_dirs.count) {
        return (DIR *)g_dirs[h - g_dirBase].pointerValue;
    }
    return NULL;
}

// ISOLATED CANDIDATE: not compiled by the shipping port until reviewed/landed.
// Call with GuestLock held. Native metadata is also protected per VM.
#include <map>
#include <mutex>
#include <array>
#include <algorithm>
#include <errno.h>
#include <objc/runtime.h>

struct Block { uint32_t size; uint32_t freeFlag; };
static_assert(sizeof(Block) == 8, "guest malloc header ABI");
// Preserve the old GuestAlloc/operator-new 16-byte payload alignment without
// accepting interior pointers. Headers remain exactly eight bytes before the
// payload. Start headers at base+8, and make header+capacity a multiple of16.
static constexpr uint32_t kArenaHeaderPad = 8;
static constexpr uint32_t kArenaMinimumCapacity = 8;
static_assert((GUEST_MMAP_BASE + kArenaHeaderPad + sizeof(Block)) % 16 == 0,
              "guest reusable heap payload alignment");
using ArenaFreeIndex = std::multimap<uint32_t, uint32_t>;
struct ArenaChunk {
    uint32_t capacity;
    bool used;
    ArenaFreeIndex::iterator freeEntry;
};
struct ArenaState {
    std::recursive_mutex mutex;
    std::map<uint32_t, ArenaChunk> chunks;
    ArenaFreeIndex freeBySize;
    uint32_t cursor = GUEST_MMAP_BASE + kArenaHeaderPad;
    uint32_t highWater = GUEST_MMAP_BASE + kArenaHeaderPad;
    uint32_t mappedEnd = GUEST_MMAP_BASE;
    uint64_t allocCalls = 0, freeCalls = 0, liveBytes = 0, reclaimedBytes = 0;
};
@interface GuestLibcArenaBox : NSObject { @public ArenaState state; }
@end
@implementation GuestLibcArenaBox
@end
static char g_libcArenaKey;
static GuestLibcArenaBox *ArenaBox(GuestVM *vm) {
    if (!vm) return nil;
    GuestLibcArenaBox *box = objc_getAssociatedObject(vm, &g_libcArenaKey);
    if (!box) {
        @synchronized(vm) {
            box = objc_getAssociatedObject(vm, &g_libcArenaKey);
            if (!box) {
                box = [GuestLibcArenaBox new];
                objc_setAssociatedObject(vm, &g_libcArenaKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    return box;
}
static uint32_t ArenaFail(GuestVM *vm, int error) {
    errno = error; HLESetGuestErrno(vm, error); return 0;
}
static bool ArenaCapacity(size_t size, uint32_t &capacity) {
    if (!size) size = 16;
    if (size > GUEST_MMAP_SIZE - sizeof(Block)) return false;
    uint64_t span = ((uint64_t)size + sizeof(Block) + 15u) & ~uint64_t(15);
    if (span + kArenaHeaderPad > GUEST_MMAP_SIZE) return false;
    capacity = (uint32_t)(span - sizeof(Block)); return true;
}
static bool ArenaHeader(GuestVM *vm, uint32_t at, uint32_t capacity, bool free) {
    Block header{capacity, free ? 1u : 0u};
    return GuestWrite(vm, at, &header, sizeof(header));
}
static bool ArenaEnsureSpace(GuestVM *vm, ArenaState &state, uint32_t end) {
    if (end <= state.mappedEnd) return true;
    uint64_t mappedEnd = ((uint64_t)end + 0xffffu) & ~uint64_t(0xffffu);
    mappedEnd = std::min(mappedEnd, (uint64_t)GUEST_MMAP_BASE + GUEST_MMAP_SIZE);
    if (!GuestFill(vm, state.mappedEnd, (size_t)(mappedEnd - state.mappedEnd))) return false;
    state.mappedEnd = (uint32_t)mappedEnd; return true;
}
static void ArenaAddFree(ArenaState &state, std::map<uint32_t, ArenaChunk>::iterator chunk) {
    chunk->second.used = false;
    chunk->second.freeEntry = state.freeBySize.emplace(chunk->second.capacity, chunk->first);
}
static void ArenaRemoveFree(ArenaState &state, std::map<uint32_t, ArenaChunk>::iterator chunk) {
    state.freeBySize.erase(chunk->second.freeEntry);
}
// Insert a newly freed region, merge both neighbors, and reclaim a free tail.
static void ArenaCoalesce(GuestVM *vm, ArenaState &state,
                          std::map<uint32_t, ArenaChunk>::iterator chunk) {
    chunk->second.used = false;
    if (chunk != state.chunks.begin()) {
        auto previous = std::prev(chunk);
        if (!previous->second.used &&
            (uint64_t)previous->first + sizeof(Block) + previous->second.capacity == chunk->first) {
            ArenaRemoveFree(state, previous);
            previous->second.capacity += sizeof(Block) + chunk->second.capacity;
            state.chunks.erase(chunk); chunk = previous;
        }
    }
    auto next = std::next(chunk);
    if (next != state.chunks.end() && !next->second.used &&
        (uint64_t)chunk->first + sizeof(Block) + chunk->second.capacity == next->first) {
        ArenaRemoveFree(state, next);
        chunk->second.capacity += sizeof(Block) + next->second.capacity;
        state.chunks.erase(next);
    }
    ArenaHeader(vm, chunk->first, chunk->second.capacity, true);
    if ((uint64_t)chunk->first + sizeof(Block) + chunk->second.capacity == state.cursor) {
        state.cursor = chunk->first;
        state.chunks.erase(chunk);
    } else ArenaAddFree(state, chunk);
}
static uint32_t ArenaAlloc(GuestVM *vm, size_t size) {
    uint32_t wanted = 0;
    if (!vm || !ArenaCapacity(size, wanted)) return ArenaFail(vm, ENOMEM);
    ArenaState &state = ArenaBox(vm)->state;
    std::lock_guard<std::recursive_mutex> lock(state.mutex);
    auto available = state.freeBySize.lower_bound(wanted);
    uint32_t at = state.cursor;
    if (available != state.freeBySize.end()) {
        auto chunk = state.chunks.find(available->second);
        at = chunk->first;
        uint32_t oldCapacity = chunk->second.capacity;
        bool split = (uint64_t)wanted + sizeof(Block) + kArenaMinimumCapacity <= oldCapacity;
        uint32_t capacity = split ? wanted : oldCapacity;
        if (!GuestFill(vm, at + sizeof(Block), capacity) || !ArenaHeader(vm, at, capacity, false))
            return ArenaFail(vm, ENOMEM);
        ArenaRemoveFree(state, chunk);
        chunk->second.capacity = capacity; chunk->second.used = true;
        if (split) {
            uint32_t restAt = at + sizeof(Block) + capacity;
            uint32_t restCapacity = oldCapacity - capacity - sizeof(Block);
            auto rest = state.chunks.emplace(restAt, ArenaChunk{restCapacity, false, {}}).first;
            ArenaHeader(vm, restAt, restCapacity, true); ArenaAddFree(state, rest);
        }
        state.liveBytes += capacity;
    } else {
        uint64_t end = (uint64_t)at + sizeof(Block) + wanted;
        if (end > (uint64_t)GUEST_MMAP_BASE + GUEST_MMAP_SIZE) return ArenaFail(vm, ENOMEM);
        if (!ArenaEnsureSpace(vm, state, (uint32_t)end) ||
            !GuestFill(vm, at, wanted + sizeof(Block)) || !ArenaHeader(vm, at, wanted, false))
            return ArenaFail(vm, ENOMEM);
        state.chunks.emplace(at, ArenaChunk{wanted, true, {}});
        state.cursor = (uint32_t)end;
        state.highWater = std::max(state.highWater, state.cursor);
        state.liveBytes += wanted;
    }
    state.allocCalls++;
    return at + sizeof(Block);
}
static bool ArenaFree(GuestVM *vm, uint32_t pointer) {
    if (!pointer) return true;
    if (!vm || pointer < GUEST_MMAP_BASE + sizeof(Block) ||
        pointer >= (uint64_t)GUEST_MMAP_BASE + GUEST_MMAP_SIZE) {
        ArenaFail(vm, EINVAL); return false;
    }
    ArenaState &state = ArenaBox(vm)->state;
    std::lock_guard<std::recursive_mutex> lock(state.mutex);
    auto chunk = state.chunks.find(pointer - sizeof(Block));
    if (chunk == state.chunks.end() || !chunk->second.used) {
        ArenaFail(vm, EINVAL); return false;
    }
    state.freeCalls++; state.liveBytes -= chunk->second.capacity;
    state.reclaimedBytes += chunk->second.capacity;
    ArenaCoalesce(vm, state, chunk); return true;
}
static uint32_t ArenaCalloc(GuestVM *vm, size_t count, size_t size) {
    if (count && size > UINT32_MAX / count) return ArenaFail(vm, ENOMEM);
    // ArenaAlloc explicitly clears reused payloads as well as fresh storage.
    return ArenaAlloc(vm, count * size);
}
static uint32_t ArenaRealloc(GuestVM *vm, uint32_t pointer, size_t size) {
    if (!pointer) return ArenaAlloc(vm, size);
    uint32_t wanted = 0;
    if (!vm || !ArenaCapacity(size, wanted)) return ArenaFail(vm, ENOMEM);
    ArenaState &state = ArenaBox(vm)->state;
    std::lock_guard<std::recursive_mutex> lock(state.mutex);
    auto chunk = state.chunks.find(pointer - sizeof(Block));
    if (pointer < GUEST_MMAP_BASE + sizeof(Block) || chunk == state.chunks.end() || !chunk->second.used)
        return ArenaFail(vm, EINVAL);
    uint32_t oldCapacity = chunk->second.capacity;
    if (wanted <= oldCapacity) {
        if ((uint64_t)wanted + sizeof(Block) + kArenaMinimumCapacity <= oldCapacity) {
            if (!ArenaHeader(vm, chunk->first, wanted, false)) return ArenaFail(vm, EFAULT);
            chunk->second.capacity = wanted;
            state.liveBytes -= oldCapacity - wanted;
            uint32_t restAt = pointer + wanted;
            auto rest = state.chunks.emplace(restAt, ArenaChunk{oldCapacity - wanted - (uint32_t)sizeof(Block), false, {}}).first;
            ArenaCoalesce(vm, state, rest);
        }
        return pointer;
    }
    auto next = std::next(chunk);
    if (next != state.chunks.end() && !next->second.used &&
        (uint64_t)pointer + oldCapacity == next->first &&
        (uint64_t)oldCapacity + sizeof(Block) + next->second.capacity >= wanted) {
        uint32_t available = oldCapacity + sizeof(Block) + next->second.capacity;
        bool split = (uint64_t)wanted + sizeof(Block) + kArenaMinimumCapacity <= available;
        uint32_t capacity = split ? wanted : available;
        if (!GuestFill(vm, pointer + oldCapacity, capacity - oldCapacity) ||
            !ArenaHeader(vm, chunk->first, capacity, false)) return ArenaFail(vm, ENOMEM);
        ArenaRemoveFree(state, next); state.chunks.erase(next);
        chunk->second.capacity = capacity; state.liveBytes += capacity - oldCapacity;
        if (split) {
            uint32_t restAt = pointer + capacity;
            auto rest = state.chunks.emplace(restAt, ArenaChunk{available - capacity - (uint32_t)sizeof(Block), false, {}}).first;
            ArenaHeader(vm, restAt, rest->second.capacity, true); ArenaAddFree(state, rest);
        }
        return pointer;
    }
    if ((uint64_t)pointer + oldCapacity == state.cursor) {
        uint64_t end = (uint64_t)pointer + wanted;
        if (end <= (uint64_t)GUEST_MMAP_BASE + GUEST_MMAP_SIZE) {
            if (!ArenaEnsureSpace(vm, state, (uint32_t)end) ||
                !GuestFill(vm, state.cursor, wanted - oldCapacity) ||
                !ArenaHeader(vm, chunk->first, wanted, false)) return ArenaFail(vm, ENOMEM);
            chunk->second.capacity = wanted; state.liveBytes += wanted - oldCapacity;
            state.cursor = (uint32_t)end; state.highWater = std::max(state.highWater, state.cursor);
            return pointer;
        }
    }
    uint32_t fresh = ArenaAlloc(vm, size);
    if (!fresh) return 0; // Failed realloc never releases the original block.
    std::array<uint8_t, 64 * 1024> buffer;
    size_t remaining = std::min((size_t)oldCapacity, size), copied = 0;
    while (remaining) {
        size_t length = std::min(remaining, buffer.size());
        if (!GuestRead(vm, pointer + (uint32_t)copied, buffer.data(), length) ||
            !GuestWrite(vm, fresh + (uint32_t)copied, buffer.data(), length)) {
            ArenaFree(vm, fresh); return ArenaFail(vm, EFAULT);
        }
        copied += length; remaining -= length;
    }
    ArenaFree(vm, pointer); return fresh;
}
gva_t GuestHeapAlloc(GuestVM *vm, size_t size) {
    return ArenaAlloc(vm, size);
}
BOOL GuestHeapFree(GuestVM *vm, gva_t pointer) {
    return ArenaFree(vm, pointer);
}
BOOL GuestHeapOwns(GuestVM *vm, gva_t pointer) {
    if (!vm || pointer < GUEST_MMAP_BASE + sizeof(Block) ||
        pointer >= (uint64_t)GUEST_MMAP_BASE + GUEST_MMAP_SIZE) return NO;
    // Inspect existing native metadata; do not manufacture a heap merely to
    // answer an ownership query, and never trust a guest-written Block header.
    GuestLibcArenaBox *box = objc_getAssociatedObject(vm, &g_libcArenaKey);
    if (!box) return NO;
    ArenaState &state = box->state;
    std::lock_guard<std::recursive_mutex> lock(state.mutex);
    auto chunk = state.chunks.find(pointer - sizeof(Block));
    return chunk != state.chunks.end() && chunk->second.used;
}
void GuestLibcHeapStats(GuestVM *vm) {
    if (!vm) return;
    ArenaState &state = ArenaBox(vm)->state;
    std::lock_guard<std::recursive_mutex> lock(state.mutex);
    GuestTrace(vm, @"[heap] arena live=%.2fMiB extent=%.2fMiB highWater=%.2fMiB allocCalls=%llu freeCalls=%llu reclaimed=%.2fMiB; bound=%uMiB",
               (double)state.liveBytes / 1048576.0,
               (double)(state.cursor - GUEST_MMAP_BASE) / 1048576.0,
               (double)(state.highWater - GUEST_MMAP_BASE) / 1048576.0,
               (unsigned long long)state.allocCalls, (unsigned long long)state.freeCalls,
               (double)state.reclaimedBytes / 1048576.0, GUEST_MMAP_SIZE / 1048576u);
}


// --- string helpers --------------------------------------------------------

static NSString *GStr(GuestVM *vm, uint32_t gva) {
    return GuestReadCString(vm, gva, 4096);
}

// --- logging ---------------------------------------------------------------
// The original logs through NSLog with guest NSString/__cfstring arguments.
// The generic bridge would hand those guest pointers straight to the host
// NSLog, which dereferences them and faults, so the format is expanded here
// against guest-readable values.
static NSString *GuestLogValue(GuestVM *vm, uint32_t gva) {
    if (!gva) return @"(nil)";
    if (GuestIsHostObject(gva) || GuestIsHostClass(gva)) {
        id obj = GuestIsHostClass(gva)
                     ? (id)GuestObjCUnwrapClass(vm, gva)
                     : (id)GuestObjCUnwrap(vm, gva);
        return obj ? [obj description] : @"(nil)";
    }
    NSString *cf = GuestObjCCFString(vm, gva);
    if (cf) return cf;
    NSString *s = GuestReadCString(vm, gva, 512);
    return s.length ? s : [NSString stringWithFormat:@"<%#x>", gva];
}

HLE_DEFINE(hle_NSLog) {
    gva_t fmtGva = GuestArg(vm, 0);
    NSString *fmt = fmtGva ? GuestReadCString(vm, fmtGva, 2048) : nil;
    if (!fmt.length) { GuestSetRet(vm, 0); return; }
    NSMutableString *out = [NSMutableString string];
    int argIndex = 1;
    for (NSUInteger i = 0; i < fmt.length; i++) {
        unichar c = [fmt characterAtIndex:i];
        if (c != '%' || i + 1 >= fmt.length) {
            [out appendFormat:@"%C", c];
            continue;
        }
        unichar next = [fmt characterAtIndex:i + 1];
        if (next == '%') { [out appendString:@"%"]; i++; continue; }
        // Consume any flags/width/precision, then look at the conversion.
        NSUInteger j = i + 1;
        NSMutableString *spec = [NSMutableString stringWithString:@"%"];
        while (j < fmt.length && strchr("-+ #0123456789.*lhqLz", (char)[fmt characterAtIndex:j])) {
            [spec appendFormat:@"%C", [fmt characterAtIndex:j]];
            j++;
        }
        if (j >= fmt.length) { [out appendString:spec]; break; }
        unichar conv = [fmt characterAtIndex:j];
        if (conv == '@' || conv == 's' || conv == 'S') {
            [out appendString:GuestLogValue(vm, GuestArg(vm, argIndex++))];
        } else {
            [spec appendFormat:@"%C", conv];
            uint32_t v = GuestArg(vm, argIndex++);
            if (conv == 'd' || conv == 'i') [out appendFormat:[spec stringByAppendingString:@"u"], v];
            else if (conv == 'f' || conv == 'g' || conv == 'e')
                [out appendFormat:@"%g", (double)GuestArgF(vm, argIndex - 1)];
            else if (conv == 'c') [out appendFormat:@"%c", (int)(v & 0xff)];
            else [out appendFormat:@"%s", spec.UTF8String];
        }
        i = j;
    }
    GuestTrace(vm, @"[nslog] %@", out);
    GuestSetRet(vm, 0);
}
HLE_BIND("_NSLog", hle_NSLog)
HLE_BIND("__NSLog", hle_NSLog)

// --- stdio -----------------------------------------------------------------

struct BackgroundPathWork {
    NSString *__strong path;
    NSString *__strong mode;
    int flags;
    bool stdio;
    NSString *__strong result=nil;
};
static int PrepareBackgroundPath(void *opaque) {
    auto &work=*static_cast<BackgroundPathWork *>(opaque);
    work.result=work.stdio ? AS6BackgroundFopenPath(work.path,work.mode)
                           : AS6BackgroundOpenPath(work.path,work.flags);
    return 0;
}
static NSString *BackgroundFopenReadPath(GuestVM *vm,NSString *path,NSString *mode) {
    if ((![mode isEqualToString:@"r"] && ![mode isEqualToString:@"rb"]) ||
        !AS6BackgroundMayPreparePath(path)) return path;
    BackgroundPathWork work{path,mode,0,true};
    // All guest arguments have been copied. Pure host background preparation
    // may be lengthy; allow the original mixer to run while it completes.
    if(HLEPthreadBlockingCall(vm,PrepareBackgroundPath,&work)<0)return nil;
    return work.result;
}
static NSString *BackgroundOpenReadPath(GuestVM *vm,NSString *path,int flags) {
    if ((flags&~O_CLOEXEC)!=O_RDONLY || !AS6BackgroundMayPreparePath(path)) return path;
    BackgroundPathWork work{path,nil,flags,false};
    if(HLEPthreadBlockingCall(vm,PrepareBackgroundPath,&work)<0)return nil;
    return work.result;
}

HLE_DEFINE(hle_fopen) {
    NSString *path = GStr(vm, GuestArg(vm, 0));
    NSString *mode = GStr(vm, GuestArg(vm, 1));
    NSString *effectiveMode=mode?:@"r";int routeError=0;
    NSString *mapped=AS6ResourceFopenReadPath(path,effectiveMode,&routeError);
    if(routeError){errno=routeError;HLESetGuestErrno(vm,routeError);GuestSetRet(vm,0);return;}
    NSString *readPath = BackgroundFopenReadPath(vm, mapped, effectiveMode);
    FILE *f = readPath ? fopen(readPath.UTF8String, (mode ?: @"r").UTF8String) : NULL;
    int saved = errno;
    if (!f) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, f ? FileHandle(f) : 0);
    if (!f) GuestTrace(vm, @"[libc] fopen(%@, %@) failed errno=%d", path, mode, saved);
}
HLE_BIND("_fopen", hle_fopen)

HLE_DEFINE(hle_fdopen) {
    FILE *f = fdopen((int)GuestArg(vm, 0), GStr(vm, GuestArg(vm, 1)).UTF8String ?: "r");
    if (!f) HLESetGuestErrno(vm, errno);
    GuestSetRet(vm, f ? FileHandle(f) : 0);
}
HLE_BIND("_fdopen", hle_fdopen)

HLE_DEFINE(hle_fclose) {
    uint32_t handle = GuestArg(vm, 0);
    FILE *f = FileOf(handle);
    if (!f) errno = EBADF;
    GuestSetSystemRet(vm, f ? fclose(f) : -1);
    if (f) g_files[handle - g_fileBase] = [NSValue valueWithPointer:NULL];
}
HLE_BIND("_fclose", hle_fclose)

HLE_DEFINE(hle_fread) {
    FILE *f = FileOf(GuestArg(vm, 3));
    gva_t dst = GuestArg(vm, 0);
    size_t s = GuestArg(vm, 1), m = GuestArg(vm, 2);
    if (!s || !m) { GuestSetRet(vm, 0); return; }
    if (!f || !dst || m > UINT32_MAX / s) {
        errno = !f ? EBADF : (!dst ? EFAULT : EOVERFLOW);
        HLESetGuestErrno(vm, errno);
        GuestSetRet(vm, 0);
        return;
    }
    size_t count = m * s;
    std::vector<uint8_t> buf(count ? count : 1);
    size_t got = fread(buf.data(), 1, count, f);
    if (got < count && ferror(f)) HLESetGuestErrno(vm, errno);
    if (got) GuestWrite(vm, dst, buf.data(), got);
    GuestSetRet(vm, (uint32_t)(got / s));
}
HLE_BIND("_fread", hle_fread)

HLE_DEFINE(hle_fwrite) {
    FILE *f = FileOf(GuestArg(vm, 3));
    gva_t src = GuestArg(vm, 0);
    size_t s = GuestArg(vm, 1), m = GuestArg(vm, 2);
    if (!s || !m) { GuestSetRet(vm, 0); return; }
    if (!f || !src || m > UINT32_MAX / s) {
        errno = !f ? EBADF : (!src ? EFAULT : EOVERFLOW);
        HLESetGuestErrno(vm, errno);
        GuestSetRet(vm, 0);
        return;
    }
    size_t count = m * s;
    std::vector<uint8_t> buf(count ? count : 1);
    if (!GuestRead(vm, src, buf.data(), count)) {
        errno = EFAULT;
        HLESetGuestErrno(vm, errno);
        GuestSetRet(vm, 0);
        return;
    }
    size_t put = fwrite(buf.data(), 1, count, f);
    if (put < count && ferror(f)) HLESetGuestErrno(vm, errno);
    GuestSetRet(vm, (uint32_t)(put / s));
}
HLE_BIND("_fwrite", hle_fwrite)

HLE_DEFINE(hle_fseek) {
    FILE *f = FileOf(GuestArg(vm, 0));
    if (!f) { HLESetGuestErrno(vm, EBADF); GuestSetRet(vm, (uint32_t)-1); return; }
    GuestSetSystemRet(vm, fseek(f, (long)(int32_t)GuestArg(vm, 1), (int)GuestArg(vm, 2)));
}
HLE_BIND("_fseek", hle_fseek)

HLE_DEFINE(hle_ftell) {
    FILE *f = FileOf(GuestArg(vm, 0));
    if (!f) { HLESetGuestErrno(vm, EBADF); GuestSetRet(vm, (uint32_t)-1); return; }
    GuestSetSystemRet(vm, ftell(f));
}
HLE_BIND("_ftell", hle_ftell)

HLE_DEFINE(hle_fflush) { GuestSetSystemRet(vm, fflush(FileOf(GuestArg(vm, 0)))); }
HLE_BIND("_fflush", hle_fflush)

HLE_DEFINE(hle_fileno) {
    FILE *f = FileOf(GuestArg(vm, 0));
    if (!f) { HLESetGuestErrno(vm, EBADF); GuestSetRet(vm, (uint32_t)-1); return; }
    GuestSetSystemRet(vm, fileno(f));
}
HLE_BIND("_fileno", hle_fileno)

HLE_DEFINE(hle_fputs) {
    NSString *s = GStr(vm, GuestArg(vm, 0));
    GuestSetRet(vm, s ? (uint32_t)fputs(s.UTF8String, FileOf(GuestArg(vm, 1))) : -1u);
}
HLE_BIND("_fputs", hle_fputs)

// Formatted output: the guest format string and varargs live in guest memory,
// so rebuild a host-visible printf by translating %s arguments.
NSString *GuestFormatCall(GuestVM *vm, NSString *fmt, int firstVarArg,
                         gva_t vaList = 0) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0;
    int argIndex = firstVarArg;
    // Darwin armv7 varargs occupy consecutive 32-bit words, including doubles
    // and long long. A va_list is a pointer to that word stream.
    auto Word = [&]() -> uint32_t {
        uint32_t v = vaList ? GuestReadU32(vm, vaList + (uint32_t)argIndex * 4)
                            : GuestArg(vm, argIndex);
        argIndex++;
        return v;
    };
    auto Pair = [&]() -> uint64_t {
        uint64_t lo = Word();
        return lo | ((uint64_t)Word() << 32);
    };
    while (i < fmt.length) {
        unichar c = [fmt characterAtIndex:i];
        if (c != '%') {
            [out appendFormat:@"%C", c];
            i++;
            continue;
        }
        i++;
        if (i >= fmt.length) break;
        if ([fmt characterAtIndex:i] == '%') { [out appendString:@"%"]; i++; continue; }
        NSMutableString *spec = [NSMutableString stringWithString:@"%"];
        while (i < fmt.length && strchr("-+ #0", (int)[fmt characterAtIndex:i])) {
            [spec appendFormat:@"%C", [fmt characterAtIndex:i++]];
        }
        if (i < fmt.length && [fmt characterAtIndex:i] == '*') {
            int width = (int32_t)Word();
            [spec appendFormat:@"%d", width];
            i++;
        } else {
            while (i < fmt.length && strchr("0123456789", (int)[fmt characterAtIndex:i]))
                [spec appendFormat:@"%C", [fmt characterAtIndex:i++]];
        }
        if (i < fmt.length && [fmt characterAtIndex:i] == '.') {
            i++;
            if (i < fmt.length && [fmt characterAtIndex:i] == '*') {
                int precision = (int32_t)Word();
                if (precision >= 0) [spec appendFormat:@".%d", precision];
                i++;
            } else {
                [spec appendString:@"."];
                while (i < fmt.length && strchr("0123456789", (int)[fmt characterAtIndex:i]))
                    [spec appendFormat:@"%C", [fmt characterAtIndex:i++]];
            }
        }
        if (i >= fmt.length) break;
        char length = 0;
        BOOL wide = NO;
        if (strchr("hlqjztL", (int)[fmt characterAtIndex:i])) {
            length = (char)[fmt characterAtIndex:i++];
            if (i < fmt.length && [fmt characterAtIndex:i] == length &&
                (length == 'h' || length == 'l')) {
                wide = length == 'l';
                if (length == 'h') [spec appendString:@"hh"];
                i++;
            } else if (length == 'h') [spec appendString:@"h"];
            wide = wide || length == 'q' || length == 'j';
        }
        if (i >= fmt.length) break;
        unichar conv = [fmt characterAtIndex:i];
        i++;
        BOOL integer = strchr("diuoxX", (int)conv) != NULL;
        if (wide && integer) [spec appendString:@"ll"];
        [spec appendFormat:@"%C", conv];
        const char *format = spec.UTF8String;
        auto Append = [&](auto value) {
            int needed = snprintf(NULL, 0, format, value);
            if (needed < 0) return;
            std::vector<char> text((size_t)needed + 1);
            snprintf(text.data(), text.size(), format, value);
            NSString *part = [[NSString alloc] initWithBytes:text.data() length:(NSUInteger)needed
                                                  encoding:NSUTF8StringEncoding];
            if (!part) part = [[NSString alloc] initWithBytes:text.data() length:(NSUInteger)needed
                                                    encoding:NSISOLatin1StringEncoding];
            if (part) [out appendString:part];
        };
        if (conv == '@') {
            gva_t at = Word();
            id object = GuestIsHostClass(at) ? (id)GuestObjCUnwrapClass(vm, at)
                                            : GuestObjCUnwrap(vm, at);
            if (!object && at) object = GuestObjCCFString(vm, at);
            [out appendFormat:spec, object];
        } else if (conv == 's') {
            uint32_t at = Word();
            NSString *s = at ? GStr(vm, at) : @"(null)";
            Append(s.UTF8String ?: "(null)");
        } else if (conv == 'c') {
            Append((int)Word());
        } else if (conv == 'p') {
            Append((void *)(uintptr_t)Word());
        } else if (integer) {
            if (conv == 'd' || conv == 'i') {
                if (wide) Append((long long)Pair()); else Append((int32_t)Word());
            } else {
                if (wide) Append((unsigned long long)Pair()); else Append(Word());
            }
        } else if (strchr("fFeEgGaA", (int)conv)) {
            uint64_t bits = Pair();
            double value;
            memcpy(&value, &bits, sizeof(value));
            Append(value);
        } else if (conv == 'n') {
            gva_t at = Word();
            uint64_t count = [out lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            size_t size = wide ? 8 : (length == 'h' ? ([spec hasPrefix:@"%hh"] ? 1 : 2) : 4);
            if (at) GuestWrite(vm, at, &count, size);
        } else {
            [out appendString:spec];
        }
    }
    return out;
}

HLE_DEFINE(hle_printf) {
    NSString *fmt = GStr(vm, GuestArg(vm, 0));
    NSString *s = fmt ? GuestFormatCall(vm, fmt, 1) : @"";
    fputs(s.UTF8String, stdout);
    GuestSetRet(vm, (uint32_t)s.length);
}
HLE_BIND("_printf", hle_printf)
HLE_DEFINE(hle_puts) {
    NSString *s = GStr(vm, GuestArg(vm, 0));
    int r = puts(s.UTF8String ?: "");
    GuestSetRet(vm, (uint32_t)r);
}
HLE_BIND("_puts", hle_puts)

HLE_DEFINE(hle_sprintf) {
    gva_t dst = GuestArg(vm, 0);
    NSString *fmt = GStr(vm, GuestArg(vm, 1));
    NSString *s = fmt ? GuestFormatCall(vm, fmt, 2) : @"";
    NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (dst) {
        if (bytes.length) GuestWrite(vm, dst, bytes.bytes, bytes.length);
        uint8_t nul = 0;
        GuestWrite(vm, dst + (uint32_t)bytes.length, &nul, 1);
    }
    GuestSetRet(vm, (uint32_t)bytes.length);
}
HLE_BIND("_sprintf", hle_sprintf)

HLE_DEFINE(hle_snprintf) {
    uint32_t buf = GuestArg(vm, 0);
    uint32_t cap = GuestArg(vm, 1);
    NSString *fmt = GStr(vm, GuestArg(vm, 2));
    NSString *s = fmt ? GuestFormatCall(vm, fmt, 3) : @"";
    NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (buf && cap) {
        size_t n = MIN((size_t)cap - 1, bytes.length);
        if (n) GuestWrite(vm, buf, bytes.bytes, n);
        uint8_t nul = 0;
        GuestWrite(vm, buf + (uint32_t)n, &nul, 1);
    }
    GuestSetRet(vm, (uint32_t)bytes.length);
}
HLE_BIND("_snprintf", hle_snprintf)
HLE_DEFINE(hle_vsnprintf) {
    gva_t buf = GuestArg(vm, 0), args = GuestArg(vm, 3);
    uint32_t cap = GuestArg(vm, 1);
    NSString *fmt = GStr(vm, GuestArg(vm, 2));
    NSString *s = fmt ? GuestFormatCall(vm, fmt, 0, args) : @"";
    NSData *bytes = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (buf && cap) {
        size_t n = MIN((size_t)cap - 1, bytes.length);
        if (n) GuestWrite(vm, buf, bytes.bytes, n);
        uint8_t nul = 0;
        GuestWrite(vm, buf + (uint32_t)n, &nul, 1);
    }
    GuestSetRet(vm, (uint32_t)bytes.length);
}
HLE_BIND("_vsnprintf", hle_vsnprintf)

HLE_DEFINE(hle_fprintf) {
    FILE *f = FileOf(GuestArg(vm, 0));
    NSString *fmt = GStr(vm, GuestArg(vm, 1));
    NSString *s = fmt ? GuestFormatCall(vm, fmt, 2) : @"";
    if (f) fputs(s.UTF8String, f);
    GuestSetRet(vm, (uint32_t)s.length);
}
HLE_BIND("_fprintf", hle_fprintf)

// __stdoutp/__stderrp are exported FILE* variables. The original first loads
// the variable's address through its GOT slot, then dereferences that cell to
// obtain FILE*. Our stdio shims consume the existing 32-bit FILE handle.
BOOL GuestStdioDataValue(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!vm || !symbol || !out) return NO;
    FILE *stream;
    if (!strcmp(symbol, "___stdoutp")) stream = stdout;
    else if (!strcmp(symbol, "___stderrp")) stream = stderr;
    else return NO;
    static std::unordered_map<uintptr_t, std::unordered_map<std::string, gva_t>> cells;
    auto &cache = cells[(uintptr_t)(__bridge void *)vm];
    auto found = cache.find(symbol);
    if (found != cache.end()) { *out = found->second; return YES; }
    uint32_t handle = FileHandle(stream);
    gva_t cell = GuestAlloc(vm, sizeof(handle));
    if (!cell || !GuestWrite(vm, cell, &handle, sizeof(handle))) return NO;
    cache[symbol] = cell;
    *out = cell;
    return YES;
}

// These four AddressBook exports are ABPropertyID variables (32-bit scalar
// values), not objects or functions. The guest dereferences their GOT address.
BOOL GuestPlatformScalarDataValue(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!vm || !symbol || !out) return NO;
    static const char *const names[] = {
        "_kABPersonEmailProperty", "_kABPersonFirstNameProperty",
        "_kABPersonLastNameProperty", "_kABPersonPhoneProperty",
    };
    bool known = false;
    for (const char *name : names) if (!strcmp(symbol, name)) { known = true; break; }
    if (!known) return NO;
    static std::unordered_map<uintptr_t, std::unordered_map<std::string, gva_t>> cells;
    auto &cache = cells[(uintptr_t)(__bridge void *)vm];
    auto found = cache.find(symbol);
    if (found != cache.end()) { *out = found->second; return YES; }
    void *host = HLEHostSymbol(symbol);
    if (!host || !HostPointerIsReadable(host, sizeof(uint32_t))) return NO;
    uint32_t value = 0;
    memcpy(&value, host, sizeof(value));
    gva_t cell = GuestAlloc(vm, sizeof(value));
    if (!cell || !GuestWrite(vm, cell, &value, sizeof(value))) return NO;
    cache[symbol] = cell;
    *out = cell;
    return YES;
}

HLE_DEFINE(hle_perror) { perror(GStr(vm, GuestArg(vm, 0)).UTF8String ?: ""); GuestSetRet(vm, 0); }
HLE_BIND("_perror", hle_perror)

// --- errno -----------------------------------------------------------------

HLE_DEFINE(hle_error) {
    if (g_errnoVM != vm) {
        g_errnoVM = vm; g_errnoCell = 0; g_errnoValue = 0;
    }
    if (!g_errnoCell) {
        g_errnoCell = GuestAlloc(vm, 4);
        GuestWriteU32(vm, g_errnoCell, (uint32_t)g_errnoValue);
    }
    GuestSetRet(vm, g_errnoCell);
}
HLE_BIND("___error", hle_error)

// --- string / memory -------------------------------------------------------

// C strings are byte sequences. Keep accesses inside mapped guest pages so a
// terminator at the end of a page never causes a speculative read past it.
static bool GuestByteFault(GuestVM *vm, uint64_t address, size_t size) {
    HLESetGuestErrno(vm, EFAULT);
    GuestTrace(vm, @"[libc] %s invalid guest byte range %#llx + %zu",
               HLECurrentSymbol() ?: "?", (unsigned long long)address, size);
    GuestSetRet(vm, 0);
    GuestRequestFault(vm);
    return false;
}
static bool GuestByteAddress(GuestVM *vm, gva_t base, size_t offset, size_t size, gva_t *out) {
    uint64_t address = (uint64_t)base + offset;
    if (!base || address > UINT32_MAX || size > (1ull << 32) - address)
        return GuestByteFault(vm, address, size);
    *out = (gva_t)address;
    return true;
}
static bool GuestByteRead(GuestVM *vm, gva_t base, size_t offset, void *bytes, size_t size) {
    if (!size) return true;
    gva_t address;
    if (!GuestByteAddress(vm, base, offset, size, &address)) return false;
    if (!GuestRead(vm, address, bytes, size)) return GuestByteFault(vm, address, size);
    return true;
}
static bool GuestByteWrite(GuestVM *vm, gva_t base, size_t offset, const void *bytes, size_t size) {
    if (!size) return true;
    gva_t address;
    if (!GuestByteAddress(vm, base, offset, size, &address)) return false;
    // GuestWrite is also the loader's map-and-write helper. A C byte operation
    // must not turn an invalid destination into a newly allocated guest page.
    size_t checked = 0;
    while (checked < size) {
        uint8_t old;
        gva_t at = address + (uint32_t)checked;
        if (!GuestRead(vm, at, &old, 1)) return GuestByteFault(vm, at, 1);
        checked += std::min(size - checked, (size_t)(0x1000u - (at & 0xfffu)));
    }
    if (!GuestWrite(vm, address, bytes, size)) return GuestByteFault(vm, address, size);
    return true;
}
static size_t GuestByteWindow(gva_t base, size_t offset, size_t limit) {
    uint32_t address = base + (uint32_t)offset;
    return std::min(std::min(limit, (size_t)256), (size_t)(0x1000u - (address & 0xfffu)));
}
static bool GuestByteLength(GuestVM *vm, gva_t source, size_t limit, size_t *length) {
    *length = 0;
    uint8_t bytes[256];
    while (*length < limit) {
        size_t count = GuestByteWindow(source, *length, limit - *length);
        if (!GuestByteRead(vm, source, *length, bytes, count)) return false;
        const uint8_t *nul = (const uint8_t *)memchr(bytes, 0, count);
        if (nul) { *length += (size_t)(nul - bytes); return true; }
        *length += count;
    }
    return true;
}
static bool GuestByteCompare(GuestVM *vm, gva_t a, gva_t b, size_t limit,
                             bool cString, bool foldCase, int32_t *result) {
    *result = 0;
    uint8_t left[256], right[256];
    for (size_t offset = 0; offset < limit;) {
        size_t count = std::min(GuestByteWindow(a, offset, limit - offset),
                                GuestByteWindow(b, offset, limit - offset));
        if (!GuestByteRead(vm, a, offset, left, count) ||
            !GuestByteRead(vm, b, offset, right, count)) return false;
        for (size_t i = 0; i < count; i++) {
            int l = foldCase ? std::tolower(left[i]) : left[i];
            int r = foldCase ? std::tolower(right[i]) : right[i];
            if (l != r) { *result = l - r; return true; }
            if (cString && !left[i]) return true;
        }
        offset += count;
    }
    return true;
}
static bool GuestByteFind(GuestVM *vm, gva_t source, uint8_t wanted, size_t limit,
                          bool cString, bool last, gva_t *result) {
    *result = 0;
    uint8_t bytes[256];
    for (size_t offset = 0; offset < limit;) {
        size_t count = GuestByteWindow(source, offset, limit - offset);
        if (!GuestByteRead(vm, source, offset, bytes, count)) return false;
        for (size_t i = 0; i < count; i++) {
            if (bytes[i] == wanted) {
                *result = source + (uint32_t)(offset + i);
                if (!last) return true;
            }
            if (cString && !bytes[i]) return true;
        }
        offset += count;
    }
    return true;
}
static bool GuestByteFill(GuestVM *vm, gva_t destination, uint8_t value, size_t size) {
    uint8_t bytes[4096];
    memset(bytes, value, sizeof(bytes));
    for (size_t offset = 0; offset < size;) {
        size_t count = std::min(size - offset, sizeof(bytes));
        if (!GuestByteWrite(vm, destination, offset, bytes, count)) return false;
        offset += count;
    }
    return true;
}


HLE_DEFINE(hle_strlen) {
    size_t length;
    if (GuestByteLength(vm, GuestArg(vm, 0), SIZE_MAX, &length)) GuestSetRet(vm, (uint32_t)length);
}
HLE_BIND("_strlen", hle_strlen)

static bool CopyGuest(GuestVM *vm, uint32_t dst, uint32_t src, size_t size) {
    if (!size) return true;
    uint8_t bytes[4096];
    bool backwards = dst > src && (uint64_t)dst < (uint64_t)src + size;
    size_t left = size;
    while (left) {
        size_t count = std::min(left, sizeof(bytes));
        size_t offset = backwards ? left - count : size - left;
        if (!GuestByteRead(vm, src, offset, bytes, count) ||
            !GuestByteWrite(vm, dst, offset, bytes, count)) return false;
        left -= count;
    }
    return true;
}

HLE_DEFINE(hle_memcpy) {
    gva_t dst = GuestArg(vm, 0);
    if (CopyGuest(vm, dst, GuestArg(vm, 1), GuestArg(vm, 2))) GuestSetRet(vm, dst);
}
HLE_BIND("_memcpy", hle_memcpy)
HLE_BIND("_memmove", hle_memcpy)

HLE_DEFINE(hle_memset) {
    gva_t dst = GuestArg(vm, 0);
    if (GuestByteFill(vm, dst, (uint8_t)GuestArg(vm, 1), GuestArg(vm, 2))) GuestSetRet(vm, dst);
}
HLE_BIND("_memset", hle_memset)

HLE_DEFINE(hle_strcmp) {
    int32_t result;
    if (GuestByteCompare(vm, GuestArg(vm, 0), GuestArg(vm, 1), SIZE_MAX, true, false, &result))
        GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_strcmp", hle_strcmp)

HLE_DEFINE(hle_strncmp) {
    int32_t result;
    if (GuestByteCompare(vm, GuestArg(vm, 0), GuestArg(vm, 1), GuestArg(vm, 2), true, false, &result))
        GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_strncmp", hle_strncmp)
HLE_DEFINE(hle_memcmp) {
    int32_t result;
    if (GuestByteCompare(vm, GuestArg(vm, 0), GuestArg(vm, 1), GuestArg(vm, 2), false, false, &result))
        GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_memcmp", hle_memcmp)

HLE_DEFINE(hle_strchr) {
    gva_t result;
    if (GuestByteFind(vm, GuestArg(vm, 0), (uint8_t)GuestArg(vm, 1), SIZE_MAX, true, false, &result))
        GuestSetRet(vm, result);
}
HLE_BIND("_strchr", hle_strchr)

HLE_DEFINE(hle_strrchr) {
    gva_t result;
    if (GuestByteFind(vm, GuestArg(vm, 0), (uint8_t)GuestArg(vm, 1), SIZE_MAX, true, true, &result))
        GuestSetRet(vm, result);
}
HLE_BIND("_strrchr", hle_strrchr)

HLE_DEFINE(hle_strstr) {
    gva_t source = GuestArg(vm, 0), needleAddress = GuestArg(vm, 1);
    size_t length;
    if (!GuestByteLength(vm, needleAddress, SIZE_MAX, &length)) return;
    if (!length) { GuestSetRet(vm, source); return; }
    std::vector<uint8_t> needle(length);
    if (!GuestByteRead(vm, needleAddress, 0, needle.data(), length)) return;
    std::vector<uint32_t> prefix(length, 0);
    for (size_t i = 1, matched = 0; i < length; i++) {
        while (matched && needle[i] != needle[matched]) matched = prefix[matched - 1];
        if (needle[i] == needle[matched]) matched++;
        prefix[i] = (uint32_t)matched;
    }
    uint8_t bytes[256];
    size_t matched = 0;
    for (size_t offset = 0;;) {
        size_t count = GuestByteWindow(source, offset, SIZE_MAX);
        if (!GuestByteRead(vm, source, offset, bytes, count)) return;
        for (size_t i = 0; i < count; i++) {
            if (!bytes[i]) { GuestSetRet(vm, 0); return; }
            while (matched && bytes[i] != needle[matched]) matched = prefix[matched - 1];
            if (bytes[i] == needle[matched]) matched++;
            if (matched == length) {
                GuestSetRet(vm, source + (uint32_t)(offset + i + 1 - length)); return;
            }
        }
        offset += count;
    }
}
HLE_BIND("_strstr", hle_strstr)

HLE_DEFINE(hle_strcpy) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    size_t length;
    if (GuestByteLength(vm, src, SIZE_MAX, &length) && CopyGuest(vm, dst, src, length + 1))
        GuestSetRet(vm, dst);
}
HLE_BIND("_strcpy", hle_strcpy)

HLE_DEFINE(hle_strncpy) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    size_t count = GuestArg(vm, 2), length;
    if (!GuestByteLength(vm, src, count, &length)) return;
    if (!CopyGuest(vm, dst, src, length)) return;
    if (length < count && !GuestByteFill(vm, dst + (uint32_t)length, 0, count - length)) return;
    GuestSetRet(vm, dst);
}
HLE_BIND("_strncpy", hle_strncpy)

HLE_DEFINE(hle_strcat) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    size_t end, length;
    if (GuestByteLength(vm, dst, SIZE_MAX, &end) &&
        GuestByteLength(vm, src, SIZE_MAX, &length) &&
        CopyGuest(vm, dst + (uint32_t)end, src, length + 1)) GuestSetRet(vm, dst);
}
HLE_BIND("_strcat", hle_strcat)
HLE_DEFINE(hle_strncat) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    size_t count = GuestArg(vm, 2), end, length;
    if (!GuestByteLength(vm, dst, SIZE_MAX, &end) || !GuestByteLength(vm, src, count, &length)) return;
    gva_t append = dst + (uint32_t)end;
    uint8_t nul = 0;
    if (CopyGuest(vm, append, src, length) && GuestByteWrite(vm, append, length, &nul, 1)) GuestSetRet(vm, dst);
}
HLE_BIND("_strncat", hle_strncat)

HLE_DEFINE(hle_strdup) {
    gva_t src = GuestArg(vm, 0);
    size_t length;
    if (!GuestByteLength(vm, src, SIZE_MAX, &length)) return;
    gva_t dst = ArenaAlloc(vm, length + 1);
    if (dst && CopyGuest(vm, dst, src, length + 1)) GuestSetRet(vm, dst);
    else {
        if (dst) ArenaFree(vm, dst);
        GuestSetRet(vm, 0);
    }
}
HLE_BIND("_strdup", hle_strdup)

HLE_DEFINE(hle_strlcpy) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    size_t capacity = GuestArg(vm, 2), length;
    if (!GuestByteLength(vm, src, SIZE_MAX, &length)) return;
    if (capacity) {
        size_t count = std::min(length, capacity - 1);
        uint8_t nul = 0;
        if (!CopyGuest(vm, dst, src, count) || !GuestByteWrite(vm, dst, count, &nul, 1)) return;
    }
    GuestSetRet(vm, (uint32_t)length);
}
HLE_BIND("_strlcpy", hle_strlcpy)

HLE_DEFINE(hle_strcasecmp) {
    int32_t result;
    if (GuestByteCompare(vm, GuestArg(vm, 0), GuestArg(vm, 1), SIZE_MAX, true, true, &result))
        GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_strcasecmp", hle_strcasecmp)

HLE_DEFINE(hle_strerror_r) {
    int err = (int)GuestArg(vm, 0);
    char tmp[256];
    strerror_r(err, tmp, sizeof(tmp));
    gva_t at = GuestWriteCString(vm, [NSString stringWithUTF8String:tmp]);
    GuestSetRet(vm, at);
}
HLE_BIND("_strerror_r", hle_strerror_r)

// Numeric parsers consume original C bytes and translate the native end
// pointer back into the original guest byte range. Darwin armv7 long is32
// bits even though the host's long is64 bits.
static bool GuestNumberSource(GuestVM *vm, gva_t source, std::vector<char> &bytes) {
    size_t length = 0;
    if (!GuestByteLength(vm, source, SIZE_MAX, &length)) return false;
    bytes.resize(length + 1);
    if (!GuestByteRead(vm, source, 0, bytes.data(), length)) return false;
    bytes[length] = 0;
    return true;
}
static bool GuestNumberEnd(GuestVM *vm, gva_t output, gva_t source, size_t consumed) {
    if (!output) return true;
    gva_t end = 0;
    if (!GuestByteAddress(vm, source, consumed, 0, &end)) return false;
    return GuestByteWrite(vm, output, 0, &end, sizeof(end));
}
static uint32_t GuestNumberLong32(const char *bytes, char **end, int base, int *error) {
    errno = 0;
    int64_t value = strtoll(bytes, end, base);
    *error = errno;
    if (value < INT32_MIN) { value = INT32_MIN; *error = ERANGE; }
    if (value > INT32_MAX) { value = INT32_MAX; *error = ERANGE; }
    return (uint32_t)(int32_t)value;
}
static uint32_t GuestNumberULong32(const char *bytes, char **end, int base, int *error) {
    const unsigned char *sign = (const unsigned char *)bytes;
    while (isspace(*sign)) ++sign;
    bool negative = *sign == '-';
    errno = 0;
    uint64_t value = strtoull(bytes, end, base);
    *error = errno;
    // strtoull applies the sign modulo64 bits. Recover the magnitude before
    // checking the32-bit range, then apply unsigned negation at guest width.
    uint64_t magnitude = negative ? uint64_t(0) - value : value;
    if (*error == ERANGE || magnitude > UINT32_MAX) {
        *error = ERANGE;
        return UINT32_MAX;
    }
    uint32_t result = (uint32_t)magnitude;
    return negative ? uint32_t(0) - result : result;
}
static void GuestNumberInteger(GuestVM *vm, bool isUnsigned, bool hasEnd) {
    gva_t source = GuestArg(vm, 0), output = hasEnd ? GuestArg(vm, 1) : 0;
    int base = hasEnd ? (int32_t)GuestArg(vm, 2) : 10;
    std::vector<char> bytes;
    if (!GuestNumberSource(vm, source, bytes)) return;
    char *end = bytes.data();
    int error = 0;
    uint32_t value = isUnsigned ? GuestNumberULong32(bytes.data(), &end, base, &error)
                                : GuestNumberLong32(bytes.data(), &end, base, &error);
    if (!GuestNumberEnd(vm, output, source, (size_t)(end - bytes.data()))) return;
    if (error) HLESetGuestErrno(vm, error);
    GuestSetRet(vm, value);
}
static void GuestNumberDouble(GuestVM *vm, bool hasEnd) {
    gva_t source = GuestArg(vm, 0), output = hasEnd ? GuestArg(vm, 1) : 0;
    std::vector<char> bytes;
    if (!GuestNumberSource(vm, source, bytes)) return;
    char *end = bytes.data();
    errno = 0;
    double value = strtod(bytes.data(), &end);
    int error = errno;
    if (!GuestNumberEnd(vm, output, source, (size_t)(end - bytes.data()))) return;
    if (error) HLESetGuestErrno(vm, error);
    GuestSetRetD(vm, value);
}
HLE_DEFINE(hle_strtol) { GuestNumberInteger(vm, false, true); }
HLE_BIND("_strtol", hle_strtol)
HLE_DEFINE(hle_strtoul) { GuestNumberInteger(vm, true, true); }
HLE_BIND("_strtoul", hle_strtoul)
HLE_DEFINE(hle_strtod) { GuestNumberDouble(vm, true); }
HLE_BIND("_strtod", hle_strtod)
HLE_DEFINE(hle_atoi) { GuestNumberInteger(vm, false, false); }
HLE_BIND("_atoi", hle_atoi)
HLE_DEFINE(hle_atol) { GuestNumberInteger(vm, false, false); }
HLE_BIND("_atol", hle_atol)
HLE_DEFINE(hle_atof) { GuestNumberDouble(vm, false); }
HLE_BIND("_atof", hle_atof)

// Every direct original scanf format is numeric: %02x four times, %ld%c,
// 0x%x, %u.%u, %d, and eight %d fields. Parse each conversion with host
// scratch; guest output pointers never enter a host variadic call.
HLE_DEFINE(hle_sscanf) {
    NSString *sourceString = GStr(vm, GuestArg(vm, 0));
    NSString *formatString = GStr(vm, GuestArg(vm, 1));
    if (!sourceString || !formatString) {
        HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, (uint32_t)EOF); return;
    }
    std::string input(sourceString.UTF8String ?: ""), format(formatString.UTF8String ?: "");
    size_t pos = 0, fi = 0;
    int argument = 2, assignments = 0;
    bool inputFailure = false;
    while (fi < format.size()) {
        unsigned char next = (unsigned char)format[fi++];
        if (std::isspace(next)) {
            while (pos < input.size() && std::isspace((unsigned char)input[pos])) pos++;
            continue;
        }
        if (next != '%') {
            if (pos >= input.size()) { inputFailure = true; break; }
            if ((unsigned char)input[pos] != next) break;
            pos++; continue;
        }
        if (fi < format.size() && format[fi] == '%') {
            fi++;
            if (pos >= input.size()) { inputFailure = true; break; }
            if (input[pos] != '%') break;
            pos++; continue;
        }
        bool suppress = fi < format.size() && format[fi] == '*';
        if (suppress) fi++;
        std::string width;
        while (fi < format.size() && std::isdigit((unsigned char)format[fi])) width += format[fi++];
        std::string length;
        if (fi < format.size() && strchr("hljztqL", format[fi])) {
            length += format[fi++];
            if (fi < format.size() && format[fi] == length[0] &&
                (length[0] == 'l' || length[0] == 'h')) length += format[fi++];
        }
        if (fi >= format.size()) break;
        char conversion = format[fi++];
        size_t targetSize = length == "hh" ? 1 : (length == "h" ? 2 :
                            (length == "ll" || length == "j" || length == "q" ? 8 : 4));
        if (conversion == 'n') {
            if (!suppress) {
                gva_t destination = GuestArg(vm, argument++);
                uint64_t consumed = pos;
                if (!destination || !GuestWrite(vm, destination, &consumed, targetSize)) {
                    HLESetGuestErrno(vm, EFAULT); break;
                }
            }
            continue;
        }
        if (conversion != 'c')
            while (pos < input.size() && std::isspace((unsigned char)input[pos])) pos++;
        if (pos >= input.size()) { inputFailure = true; break; }
        int consumed = 0, matched = 0;
        uint64_t integer = 0;
        std::vector<char> characters;
        if (strchr("diuoxX", conversion)) {
            std::string spec = "%" + width + "ll" + conversion + "%n";
            if (conversion == 'd' || conversion == 'i') {
                long long value = 0;
                matched = sscanf(input.c_str() + pos, spec.c_str(), &value, &consumed);
                integer = (uint64_t)value;
            } else {
                unsigned long long value = 0;
                matched = sscanf(input.c_str() + pos, spec.c_str(), &value, &consumed);
                integer = (uint64_t)value;
            }
        } else if (conversion == 'c' && length.empty()) {
            size_t count = width.empty() ? 1 : (size_t)strtoul(width.c_str(), nullptr, 10);
            if (!count || count > UINT32_MAX) { HLESetGuestErrno(vm, EINVAL); break; }
            characters.resize(count);
            std::string spec = "%" + width + "c%n";
            matched = sscanf(input.c_str() + pos, spec.c_str(), characters.data(), &consumed);
        } else {
            GuestTrace(vm, @"[libc] unsupported original scanf conversion %c", conversion);
            HLESetGuestErrno(vm, ENOSYS);
            GuestSetRet(vm, assignments ? (uint32_t)assignments : (uint32_t)EOF);
            return;
        }
        if (matched != 1 || consumed <= 0) { inputFailure = matched == EOF; break; }
        pos += (size_t)consumed;
        if (!suppress) {
            gva_t destination = GuestArg(vm, argument++);
            const void *bytes = conversion == 'c' ? (const void *)characters.data() : &integer;
            size_t size = conversion == 'c' ? (size_t)consumed : targetSize;
            if (!destination || !GuestWrite(vm, destination, bytes, size)) {
                HLESetGuestErrno(vm, EFAULT); break;
            }
            assignments++;
        }
    }
    GuestSetRet(vm, assignments == 0 && inputFailure ? (uint32_t)EOF : (uint32_t)assignments);
}
HLE_BIND("_sscanf", hle_sscanf)

// Replace only the four allocator bindings after landing guest_allocator.inc.
HLE_DEFINE(hle_malloc) { GuestSetRet(vm, ArenaAlloc(vm, GuestArg(vm, 0))); }
HLE_BIND("_malloc", hle_malloc)
HLE_DEFINE(hle_calloc) { GuestSetRet(vm, ArenaCalloc(vm, GuestArg(vm, 0), GuestArg(vm, 1))); }
HLE_BIND("_calloc", hle_calloc)
HLE_DEFINE(hle_realloc) { GuestSetRet(vm, ArenaRealloc(vm, GuestArg(vm, 0), GuestArg(vm, 1))); }
HLE_BIND("_realloc", hle_realloc)
HLE_DEFINE(hle_free) { ArenaFree(vm, GuestArg(vm, 0)); }
HLE_BIND("_free", hle_free)


// --- math ------------------------------------------------------------------

#define HLE_MATH1(name, host, conv)                                            \
    HLE_DEFINE(hle_##name) { GuestSetRet##conv(vm, host(conv##Of(GuestArg(vm, 0)))); } \
    HLE_BIND("_" #name, hle_##name)

#define HLE_FLOAT1(name, host)                                                  \
    HLE_DEFINE(hle_##name) { GuestSetRetF(vm, (float)host(GuestArgF(vm, 0))); } \
    HLE_BIND("_" #name, hle_##name)

#define HLE_DOUBLE1(name, host)                                                 \
    HLE_DEFINE(hle_##name) { GuestSetRetD(vm, host(GuestArgD(vm, 0))); }        \
    HLE_BIND("_" #name, hle_##name)

HLE_DOUBLE1(acos, acos) HLE_DOUBLE1(asin, asin) HLE_DOUBLE1(atan, atan)
HLE_DOUBLE1(ceil, ceil) HLE_DOUBLE1(cos, cos) HLE_DOUBLE1(exp, exp)
HLE_DOUBLE1(floor, floor) HLE_DOUBLE1(log, log) HLE_DOUBLE1(log10, log10)
HLE_DOUBLE1(log2, log2) HLE_DOUBLE1(sin, sin) HLE_DOUBLE1(tan, tan)
HLE_DOUBLE1(sqrt, sqrt) HLE_DOUBLE1(fabs, fabs)
HLE_FLOAT1(acosf, acosf) HLE_FLOAT1(asinf, asinf) HLE_FLOAT1(atanf, atanf)
HLE_FLOAT1(ceilf, ceilf) HLE_FLOAT1(cosf, cosf) HLE_FLOAT1(expf, expf)
HLE_FLOAT1(floorf, floorf) HLE_FLOAT1(logf, logf) HLE_FLOAT1(log10f, log10f)
HLE_FLOAT1(sinf, sinf) HLE_FLOAT1(tanf, tanf) HLE_FLOAT1(sqrtf, sqrtf)
HLE_FLOAT1(fabsf, fabsf)

HLE_DEFINE(hle_atan2) { GuestSetRetD(vm, atan2(GuestArgD(vm, 0), GuestArgD(vm, 1))); }
HLE_BIND("_atan2", hle_atan2)
HLE_DEFINE(hle_atan2f) { GuestSetRetF(vm, atan2f(GuestArgF(vm, 0), GuestArgF(vm, 1))); }
HLE_BIND("_atan2f", hle_atan2f)
HLE_DEFINE(hle_pow) { GuestSetRetD(vm, pow(GuestArgD(vm, 0), GuestArgD(vm, 1))); }
HLE_BIND("_pow", hle_pow)
HLE_DEFINE(hle_fmod) { GuestSetRetD(vm, fmod(GuestArgD(vm, 0), GuestArgD(vm, 1))); }
HLE_BIND("_fmod", hle_fmod)
HLE_DEFINE(hle_fmodf) { GuestSetRetF(vm, fmodf(GuestArgF(vm, 0), GuestArgF(vm, 1))); }
HLE_BIND("_fmodf", hle_fmodf)
HLE_DEFINE(hle_fmin) { GuestSetRetD(vm, fmin(GuestArgD(vm, 0), GuestArgD(vm, 1))); }
HLE_BIND("_fmin", hle_fmin)
HLE_DEFINE(hle_fmax) { GuestSetRetD(vm, fmax(GuestArgD(vm, 0), GuestArgD(vm, 1))); }
HLE_BIND("_fmax", hle_fmax)
HLE_DEFINE(hle_ldexp) { GuestSetRetD(vm, ldexp(GuestArgD(vm, 0), (int)GuestArg(vm, 2))); }
HLE_BIND("_ldexp", hle_ldexp)
HLE_DEFINE(hle_nan) { GuestSetRetD(vm, nan(GStr(vm, GuestArg(vm, 0)).UTF8String ?: "")); }
HLE_BIND("_nan", hle_nan)

HLE_DEFINE(hle_div) {
    // Original Darwin ARM callers pass an 8-byte div_t result in r0,
    // followed by the signed numerator/denominator in r1/r2.
    const gva_t out = GuestArg(vm, 0);
    const int32_t a = (int32_t)GuestArg(vm, 1), b = (int32_t)GuestArg(vm, 2);
    if (!b || (a == INT32_MIN && b == -1)) {
        HLESetGuestErrno(vm, EDOM);
        GuestTrace(vm, @"[libc] div rejected undefined signed division %d / %d", a, b);
        GuestRequestFault(vm);
        return;
    }
    const int32_t result[2] = {(int32_t)((int64_t)a / b), (int32_t)((int64_t)a % b)};
    if (!GuestByteWrite(vm, out, 0, result, sizeof(result))) return;
    GuestSetRet(vm, out);
}
HLE_BIND("_div", hle_div)

// --- time ------------------------------------------------------------------

HLE_DEFINE(hle_time) {
    gva_t out = GuestArg(vm, 0);
    uint32_t now = (uint32_t)time(NULL);
    if (out) GuestWriteU32(vm, out, now);
    GuestSetRet(vm, now);
}
HLE_BIND("_time", hle_time)

HLE_DEFINE(hle_gettimeofday) {
    static std::unordered_map<uint32_t, int> callers;
    int &hits = callers[GuestLR(vm)];
    hits++;
    if (hits == 3) {
        // The frame walker cannot follow this function's frame chain, so the
        // return addresses are lifted straight out of the guest stack.
        uint32_t sp = GuestSP(vm);
        char line[512];
        int n = snprintf(line, sizeof(line), "[time] lr=%#x sp=%#x stack:", GuestLR(vm), sp);
        for (int i = 0; i < 160 && n < (int)sizeof(line) - 16; i++) {
            uint32_t w = 0;
            if (!GuestRead(vm, sp + (uint32_t)i * 4, &w, 4)) break;
            if (w > 0x278c && w < 0x6a0000 && (w & 3) == 0)
                n += snprintf(line + n, sizeof(line) - n, " %#x", w);
        }
        GuestRawLog(line);
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    GuestWriteU32(vm, GuestArg(vm, 0), (uint32_t)tv.tv_sec);
    GuestWriteU32(vm, GuestArg(vm, 0) + 4, (uint32_t)tv.tv_usec);
    GuestSetRet(vm, 0);
}
HLE_BIND("_gettimeofday", hle_gettimeofday)

HLE_DEFINE(hle_clock) { GuestSetRet(vm, (uint32_t)clock()); }
HLE_BIND("_clock", hle_clock)

HLE_DEFINE(hle_mach_absolute_time) {
    // A 64-bit integer result uses r0:r1 in the original armv7 ABI. There is
    // no hidden result pointer: writing the value at SP corrupts the caller's
    // own frame. Keep the host's tick units paired with mach_timebase_info.
    uint64_t now = mach_absolute_time();
    GuestSetRet(vm, (uint32_t)now);
    GuestSetReg(vm, 1, (uint32_t)(now >> 32));
}
HLE_BIND("_mach_absolute_time", hle_mach_absolute_time)

HLE_DEFINE(hle_mach_timebase_info) {
    mach_timebase_info_data_t info = {};
    kern_return_t result = mach_timebase_info(&info);
    gva_t out = GuestArg(vm, 0);
    if (result == KERN_SUCCESS && out) {
        GuestWriteU32(vm, out, info.numer);
        GuestWriteU32(vm, out + 4, info.denom);
    }
    GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_mach_timebase_info", hle_mach_timebase_info)

struct GuestSleepWait {
    uint32_t amount = 0;
    unsigned remainingSeconds = 0;
    int error = 0;
    struct timespec requested = {}, remaining = {};
    bool wantsRemaining = false;
};
// The blocking callback has only native scratch. All guest arguments are
// captured before yielding CPU ownership and all guest writes follow restore.
static int GuestNanosleepOperation(void *context) {
    auto *wait = static_cast<GuestSleepWait *>(context);
    int result = nanosleep(&wait->requested, wait->wantsRemaining ? &wait->remaining : nullptr);
    wait->error = errno;
    return result;
}
static int GuestUsleepOperation(void *context) {
    auto *wait = static_cast<GuestSleepWait *>(context);
    int result = usleep(wait->amount);
    wait->error = errno;
    return result;
}
static int GuestSleepOperation(void *context) {
    auto *wait = static_cast<GuestSleepWait *>(context);
    wait->remainingSeconds = sleep(wait->amount);
    wait->error = errno;
    return 0;
}
HLE_DEFINE(hle_nanosleep) {
    gva_t req = GuestArg(vm, 0), rem = GuestArg(vm, 1);
    int32_t words[2] = {};
    if (!req || !GuestRead(vm, req, words, sizeof(words))) {
        HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, (uint32_t)-1); return;
    }
    GuestSleepWait wait;
    // Guest time_t and long are32 bits; native timespec fields are64 bits.
    wait.requested = {(time_t)words[0], (long)words[1]};
    wait.wantsRemaining = rem != 0;
    int result = HLEPthreadBlockingCall(vm, GuestNanosleepOperation, &wait);
    if (result != 0) {wait.error=errno;HLESetGuestErrno(vm,wait.error);}
    if (result != 0 && wait.error == EINTR && rem) {
        int32_t remaining[2] = {(int32_t)wait.remaining.tv_sec, (int32_t)wait.remaining.tv_nsec};
        if (!GuestByteWrite(vm, rem, 0, remaining, sizeof(remaining))) return;
    }
    GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_nanosleep", hle_nanosleep)
HLE_DEFINE(hle_usleep) {
    GuestSleepWait wait; wait.amount = GuestArg(vm, 0);
    int result = HLEPthreadBlockingCall(vm, GuestUsleepOperation, &wait);
    if (result < 0) HLESetGuestErrno(vm,errno);
    GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_usleep", hle_usleep)
HLE_DEFINE(hle_sleep) {
    GuestSleepWait wait; wait.amount = GuestArg(vm, 0);
    if(HLEPthreadBlockingCall(vm,GuestSleepOperation,&wait)<0){HLESetGuestErrno(vm,errno);GuestSetRet(vm,wait.amount);return;}
    if (wait.remainingSeconds && wait.error) HLESetGuestErrno(vm, wait.error);
    GuestSetRet(vm, wait.remainingSeconds);
}
HLE_BIND("_sleep", hle_sleep)
HLE_DEFINE(hle_sched_yield) { sched_yield(); GuestSetRet(vm, 0); }
HLE_BIND("_sched_yield", hle_sched_yield)

static uint32_t WriteHostTime(GuestVM *vm, const struct tm *t) {
    gva_t at = GuestAlloc(vm, 36);
    const int32_t fields[11] = {(int32_t)t->tm_sec, (int32_t)t->tm_min, (int32_t)t->tm_hour,
                                (int32_t)t->tm_mday, (int32_t)t->tm_mon, (int32_t)t->tm_year,
                                (int32_t)t->tm_wday, (int32_t)t->tm_yday, (int32_t)t->tm_isdst,
                                (int32_t)t->tm_gmtoff, (int32_t)0};
    GuestWrite(vm, at, fields, sizeof(fields));
    return at;
}

HLE_DEFINE(hle_localtime) {
    time_t tv = (time_t)GuestArg(vm, 0);
    struct tm t;
    localtime_r(&tv, &t);
    GuestSetRet(vm, WriteHostTime(vm, &t));
}
HLE_BIND("_localtime", hle_localtime)
HLE_BIND("_gmtime", hle_localtime)

HLE_DEFINE(hle_localtime_r) {
    time_t tv = (time_t)GuestReadU32(vm, GuestArg(vm, 0));
    struct tm t;
    localtime_r(&tv, &t);
    const int32_t fields[11] = {(int32_t)t.tm_sec, (int32_t)t.tm_min, (int32_t)t.tm_hour,
                                (int32_t)t.tm_mday, (int32_t)t.tm_mon, (int32_t)t.tm_year,
                                (int32_t)t.tm_wday, (int32_t)t.tm_yday, (int32_t)t.tm_isdst,
                                (int32_t)t.tm_gmtoff, (int32_t)0};
    GuestWrite(vm, GuestArg(vm, 1), fields, sizeof(fields));
    GuestSetRet(vm, GuestArg(vm, 1));
}
HLE_BIND("_localtime_r", hle_localtime_r)

// --- filesystem / process --------------------------------------------------

HLE_DEFINE(hle_open) {
    NSString *p = GStr(vm, GuestArg(vm, 0));
    int flags = (int)GuestArg(vm, 1);
    int routeError=0;NSString *mapped=AS6ResourceOpenReadPath(p,flags,&routeError);
    if(routeError){errno=routeError;GuestSetSystemRet(vm,-1);return;}
    NSString *readPath = BackgroundOpenReadPath(vm, mapped, flags);
    int fd = readPath ? open(readPath.UTF8String, flags,
                      (flags & O_CREAT) ? (mode_t)GuestArg(vm, 2) : 0) : -1;
    GuestSetSystemRet(vm, fd);
}
HLE_BIND("_open", hle_open)
HLE_DEFINE(hle_close) { GuestSetSystemRet(vm, close((int)GuestArg(vm, 0))); }
HLE_BIND("_close", hle_close)
HLE_DEFINE(hle_read) {
    std::vector<uint8_t> buf(GuestArg(vm, 2) ?: 1);
    ssize_t r = read((int)GuestArg(vm, 0), buf.data(), GuestArg(vm, 2));
    if (r < 0) HLESetGuestErrno(vm, errno);
    if (r > 0) GuestWrite(vm, GuestArg(vm, 1), buf.data(), (size_t)r);
    GuestSetRet(vm, (uint32_t)(int32_t)r);
}
HLE_BIND("_read", hle_read)
HLE_DEFINE(hle_write) {
    std::vector<uint8_t> buf(GuestArg(vm, 2) ?: 1);
    GuestRead(vm, GuestArg(vm, 1), buf.data(), GuestArg(vm, 2));
    GuestSetSystemRet(vm, write((int)GuestArg(vm, 0), buf.data(), GuestArg(vm, 2)));
}
HLE_BIND("_write", hle_write)
HLE_DEFINE(hle_lseek) {
    // Darwin armv7 aligns 64-bit arguments to four bytes: fd=r0,
    // offset=r1:r2, whence=r3. The off_t result also occupies r0:r1.
    uint64_t bits = GuestArg(vm, 1) | ((uint64_t)GuestArg(vm, 2) << 32);
    int64_t offset;
    memcpy(&offset, &bits, sizeof(offset));
    int64_t result = lseek((int)GuestArg(vm, 0), (off_t)offset, (int)GuestArg(vm, 3));
    if (result < 0) HLESetGuestErrno(vm, errno);
    GuestSetRet(vm, (uint32_t)result);
    GuestSetReg(vm, 1, (uint32_t)((uint64_t)result >> 32));
}
HLE_BIND("_lseek", hle_lseek)
HLE_DEFINE(hle_fcntl) { GuestSetSystemRet(vm, fcntl((int)GuestArg(vm, 0), (int)GuestArg(vm, 1), (int)GuestArg(vm, 2))); }
HLE_BIND("_fcntl", hle_fcntl)
HLE_DEFINE(hle_ioctl) { GuestSetSystemRet(vm, ioctl((int)GuestArg(vm, 0), (unsigned long)GuestArg(vm, 1))); }
HLE_BIND("_ioctl", hle_ioctl)
HLE_DEFINE(hle_remove) { NSString *p=GStr(vm,GuestArg(vm,0));if(AS6ResourceWriteProtectedPath(p)){errno=EROFS;GuestSetSystemRet(vm,-1);return;}GuestSetSystemRet(vm,remove(p.UTF8String?:"")); }
HLE_BIND("_remove", hle_remove)
HLE_DEFINE(hle_mkdir) { NSString *p=GStr(vm,GuestArg(vm,0));if(AS6ResourceWriteProtectedPath(p)){errno=EROFS;GuestSetSystemRet(vm,-1);return;}GuestSetSystemRet(vm,mkdir(p.UTF8String?:"",(mode_t)GuestArg(vm,1))); }
HLE_BIND("_mkdir", hle_mkdir)
HLE_DEFINE(hle_rmdir) { NSString *p=GStr(vm,GuestArg(vm,0));if(AS6ResourceWriteProtectedPath(p)){errno=EROFS;GuestSetSystemRet(vm,-1);return;}GuestSetSystemRet(vm,rmdir(p.UTF8String?:"")); }
HLE_BIND("_rmdir", hle_rmdir)
HLE_DEFINE(hle_chdir) { BOOL matched=NO;NSString *p=AS6ResolveResourceReadPath(GStr(vm,GuestArg(vm,0)),&matched);if(matched&&!p){errno=ENOENT;GuestSetSystemRet(vm,-1);return;}GuestSetSystemRet(vm,chdir(p.UTF8String?:".")); }
HLE_BIND("_chdir", hle_chdir)

HLE_DEFINE(hle_getcwd) {
    gva_t dst = GuestArg(vm, 0);
    uint32_t size = GuestArg(vm, 1);
    char *cwd = getcwd(NULL, 0);
    if (!cwd) { HLESetGuestErrno(vm, errno); GuestSetRet(vm, 0); return; }
    size_t len = strlen(cwd) + 1;
    if (size && len > size) {
        free(cwd);
        errno = ERANGE;
        HLESetGuestErrno(vm, errno);
        GuestSetRet(vm, 0);
        return;
    }
    bool allocated = !dst;
    if (allocated) dst = ArenaAlloc(vm, size ? size : len);
    if (!dst) { free(cwd); GuestSetRet(vm, 0); return; }
    bool copied = GuestByteWrite(vm, dst, 0, cwd, len);
    free(cwd);
    if (!copied) {
        if (allocated) ArenaFree(vm, dst);
        GuestSetRet(vm, 0);
        return;
    }
    GuestSetRet(vm, dst);
}
HLE_BIND("_getcwd", hle_getcwd)

// The original imports _stat without the $INODE64 suffix, so its caller uses
// Darwin's legacy 96-byte armv7 layout (32-bit ino_t, 32-bit timespec fields).
// Copying the 144-byte arm64 struct would overwrite the caller's stack.
static void WriteGuestStat(GuestVM *vm, gva_t dst, const struct stat &st, bool inode64) {
    uint8_t bytes[108] = {};
    auto Put16 = [&](size_t off, uint16_t value) { memcpy(bytes + off, &value, 2); };
    auto Put32 = [&](size_t off, uint32_t value) { memcpy(bytes + off, &value, 4); };
    auto Put64 = [&](size_t off, uint64_t value) { memcpy(bytes + off, &value, 8); };
    Put32(0, (uint32_t)st.st_dev);
    if (inode64) {
        Put16(4, st.st_mode); Put16(6, st.st_nlink); Put64(8, st.st_ino);
        Put32(16, st.st_uid); Put32(20, st.st_gid); Put32(24, (uint32_t)st.st_rdev);
    } else {
        Put32(4, (uint32_t)st.st_ino); Put16(8, st.st_mode); Put16(10, st.st_nlink);
        Put32(12, st.st_uid); Put32(16, st.st_gid); Put32(20, (uint32_t)st.st_rdev);
    }
    size_t timeOff = inode64 ? 28 : 24;
    const struct timespec times[] = {st.st_atimespec, st.st_mtimespec,
                                    st.st_ctimespec, st.st_birthtimespec};
    for (size_t i = 0; i < (inode64 ? 4u : 3u); i++) {
        Put32(timeOff + i * 8, (uint32_t)times[i].tv_sec);
        Put32(timeOff + i * 8 + 4, (uint32_t)times[i].tv_nsec);
    }
    size_t sizeOff = inode64 ? 60 : 48;
    Put64(sizeOff, (uint64_t)st.st_size);
    Put64(sizeOff + 8, (uint64_t)st.st_blocks);
    Put32(sizeOff + 16, (uint32_t)st.st_blksize);
    Put32(sizeOff + 20, st.st_flags); Put32(sizeOff + 24, st.st_gen);
    GuestWrite(vm, dst, bytes, inode64 ? 108 : 96);
}

static void GuestStatPath(GuestVM *vm, bool followLinks, bool inode64) {
    NSString *p = GStr(vm, GuestArg(vm, 0));
    gva_t dst = GuestArg(vm, 1);
    if (!p || !dst) { HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, (uint32_t)-1); return; }
    BOOL matched=NO;p=AS6ResolveResourceReadPath(p,&matched);if(matched&&!p){errno=ENOENT;GuestSetSystemRet(vm,-1);return;}
    struct stat st = {};
    int r = followLinks ? stat(p.UTF8String, &st) : lstat(p.UTF8String, &st);
    if (r == 0) WriteGuestStat(vm, dst, st, inode64);
    GuestSetSystemRet(vm, r);
}
HLE_DEFINE(hle_stat) { GuestStatPath(vm, true, false); }
HLE_BIND("_stat", hle_stat)
HLE_DEFINE(hle_lstat) { GuestStatPath(vm, false, false); }
HLE_BIND("_lstat", hle_lstat)
HLE_DEFINE(hle_stat64) { GuestStatPath(vm, true, true); }
HLE_BIND("_stat64", hle_stat64)
HLE_BIND("_stat$INODE64", hle_stat64)
HLE_DEFINE(hle_lstat64) { GuestStatPath(vm, false, true); }
HLE_BIND("_lstat64", hle_lstat64)
HLE_BIND("_lstat$INODE64", hle_lstat64)
static void GuestFstat(GuestVM *vm, bool inode64) {
    int fd = (int)GuestArg(vm, 0);
    gva_t dst = GuestArg(vm, 1);
    if (!dst) { HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, (uint32_t)-1); return; }
    struct stat st = {};
    int r = fstat(fd, &st);
    if (r == 0) WriteGuestStat(vm, dst, st, inode64);
    GuestSetSystemRet(vm, r);
}
HLE_DEFINE(hle_fstat) { GuestFstat(vm, false); }
HLE_BIND("_fstat", hle_fstat)
HLE_DEFINE(hle_fstat64) { GuestFstat(vm, true); }
HLE_BIND("_fstat64", hle_fstat64)
HLE_BIND("_fstat$INODE64", hle_fstat64)

HLE_DEFINE(hle_opendir) {
    BOOL matched=NO;NSString *p=AS6ResolveResourceReadPath(GStr(vm,GuestArg(vm,0)),&matched);if(matched&&!p){errno=ENOENT;HLESetGuestErrno(vm,ENOENT);GuestSetRet(vm,0);return;}
    DIR *d = opendir(p.UTF8String ?: ".");
    if (!d) HLESetGuestErrno(vm, errno);
    GuestSetRet(vm, d ? DirHandle(d) : 0);
}
HLE_BIND("_opendir", hle_opendir)
HLE_DEFINE(hle_closedir) {
    DIR *d = DirOf(GuestArg(vm, 0));
    if (!d) { HLESetGuestErrno(vm, EBADF); GuestSetRet(vm, (uint32_t)-1); return; }
    GuestSetSystemRet(vm, closedir(d));
}
HLE_BIND("_closedir", hle_closedir)
HLE_DEFINE(hle_readdir) {
    DIR *d = DirOf(GuestArg(vm, 0));
    if (!d) { HLESetGuestErrno(vm, EBADF); GuestSetRet(vm, 0); return; }
    errno = 0;
    struct dirent *e = readdir(d);
    if (!e && errno) HLESetGuestErrno(vm, errno);
    if (!e) { GuestSetRet(vm, 0); return; }
    // 32-bit struct dirent: ino(8) off(8) reclen(2) type(1) name[256]
    gva_t at = GuestAlloc(vm, 275);
    std::vector<uint8_t> buf(275, 0);
    memcpy(buf.data(), &e->d_ino, 8);
    buf[16] = (uint8_t)e->d_namlen;
    buf[17] = (uint8_t)e->d_type;
    memcpy(buf.data() + 18, e->d_name, strlen(e->d_name));
    GuestWrite(vm, at, buf.data(), buf.size());
    GuestSetRet(vm, at);
}
HLE_BIND("_readdir", hle_readdir)

HLE_DEFINE(hle_getenv) {
    NSString *name = GStr(vm, GuestArg(vm, 0));
    const char *v = name ? getenv(name.UTF8String) : NULL;
    GuestSetRet(vm, v ? GuestWriteCString(vm, [NSString stringWithUTF8String:v]) : 0);
}
HLE_BIND("_getenv", hle_getenv)

HLE_DEFINE(hle_dlsym) {
    NSString *sym = GStr(vm, GuestArg(vm, 1));
    void *p = sym ? dlsym(RTLD_DEFAULT, sym.UTF8String) : NULL;
    if (!p) { GuestTrace(vm, @"[libc] dlsym(%@) -> NULL", sym); }
    GuestSetRet(vm, 0);  // host pointers do not fit the 32-bit guest
}
HLE_BIND("_dlsym", hle_dlsym)

HLE_DEFINE(hle_exit) {
    GuestTrace(vm, @"[libc] exit(%d) after %lu guest HLE calls", (int)GuestArg(vm, 0),
               (unsigned long)GuestCallCount(vm));
    GuestSetRet(vm, 0);
}
HLE_BIND("_exit", hle_exit)
HLE_DEFINE(hle_abort) { GuestTrace(vm, @"[libc] abort()"); GuestRequestFault(vm); }
HLE_BIND("_abort", hle_abort)

HLE_DEFINE(hle_assert) {
    GuestTrace(vm, @"[libc] __assert_rtn(%@:%u, %@)", GStr(vm, GuestArg(vm, 1)),
               GuestArg(vm, 2), GStr(vm, GuestArg(vm, 3)));
    GuestRequestFault(vm);
}
HLE_BIND("___assert_rtn", hle_assert)

HLE_DEFINE(hle_qsort) {
    gva_t base = GuestArg(vm, 0), comparator = GuestArg(vm, 3);
    size_t count = GuestArg(vm, 1), size = GuestArg(vm, 2);
    if (count < 2 || !size) return;
    if (!base || !comparator || count > UINT32_MAX / size) {
        HLESetGuestErrno(vm, EINVAL); GuestRequestHalt(vm); return;
    }
    std::string symbol = HLECurrentSymbol() ?: "_qsort";
    try {
        std::vector<uint8_t> original(count * size), sorted(count * size);
        if (!GuestRead(vm, base, original.data(), original.size())) {
            HLESetGuestErrno(vm, EFAULT); GuestRequestHalt(vm); return;
        }
        // Sort an index array so every comparator argument remains a genuine
        // guest element address. Copy the resulting permutation back once.
        std::vector<uint32_t> order(count);
        for (size_t i = 0; i < count; i++) order[i] = (uint32_t)i;
        std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
            uint32_t args[2] = {base + (uint32_t)(a * size), base + (uint32_t)(b * size)};
            int32_t compared = (int32_t)GuestCall(vm, comparator, args, 2, 10000000);
            HLESetCurrentSymbol(symbol.c_str());
            return compared < 0;
        });
        for (size_t i = 0; i < count; i++)
            memcpy(sorted.data() + i * size, original.data() + order[i] * size, size);
        if (!GuestWrite(vm, base, sorted.data(), sorted.size())) {
            HLESetGuestErrno(vm, EFAULT); GuestRequestHalt(vm);
        }
    } catch (const std::bad_alloc &) {
        HLESetGuestErrno(vm, ENOMEM); GuestRequestHalt(vm);
    }
    HLESetCurrentSymbol(symbol.c_str());
}
HLE_BIND("_qsort", hle_qsort)
HLE_DEFINE(hle_rand) { GuestSetRet(vm, (uint32_t)rand()); }
HLE_BIND("_rand", hle_rand)
HLE_DEFINE(hle_srand) { srand(GuestArg(vm, 0)); GuestSetRet(vm, 0); }
HLE_BIND("_srand", hle_srand)
HLE_DEFINE(hle_tolower) { GuestSetRet(vm, (uint32_t)tolower((int)GuestArg(vm, 0))); }
HLE_BIND("_tolower", hle_tolower)
HLE_DEFINE(hle_toupper) { GuestSetRet(vm, (uint32_t)toupper((int)GuestArg(vm, 0))); }
HLE_BIND("_toupper", hle_toupper)
HLE_DEFINE(hle_putchar) { GuestSetRet(vm, (uint32_t)putchar((int)GuestArg(vm, 0))); }
HLE_BIND("_putchar", hle_putchar)
HLE_DEFINE(hle_system) { GuestTrace(vm, @"[libc] system(%@)", GStr(vm, GuestArg(vm, 0))); GuestSetRet(vm, 0); }
HLE_BIND("_system", hle_system)
HLE_DEFINE(hle_memchr) {
    gva_t result;
    if (GuestByteFind(vm, GuestArg(vm, 0), (uint8_t)GuestArg(vm, 1), GuestArg(vm, 2), false, false, &result))
        GuestSetRet(vm, result);
}
HLE_BIND("_memchr", hle_memchr)

HLE_DEFINE(hle_setjmp) { GuestSetRet(vm, 0); }
HLE_BIND("_setjmp", hle_setjmp)
HLE_BIND("__setjmp", hle_setjmp)
HLE_DEFINE(hle_longjmp) {
    GuestTrace(vm, @"[libc] longjmp(%#x,%d) requires an original nonlocal context; stopping",
               GuestArg(vm, 0), (int)GuestArg(vm, 1));
    GuestRequestFault(vm);
}
HLE_BIND("_longjmp", hle_longjmp)
HLE_BIND("__longjmp", hle_longjmp)
