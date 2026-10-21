// Remaining pointer-bearing POSIX imports used by the original armv7 image.
// Async reads perform real pread calls on a host queue. Their guest buffers and
// completion handlers are committed only while holding the guest CPU lock.
#import "HLE.h"
#import "GuestVM.h"
#import "ResourcePaths.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/utsname.h>
#import <sys/signal.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <atomic>
#import <memory>
#import <unordered_map>
#import <vector>
#import <string>
#import <cstring>

extern void HLESetGuestErrno(GuestVM *, int);
static void PosixResult(GuestVM *vm, int64_t result, int saved) {
    if (result < 0) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, (uint32_t)result);
}
static bool PosixCString(GuestVM *vm, gva_t at, std::vector<char> &bytes) {
    if (!at) { errno = EFAULT; return false; }
    size_t size = GuestStrLen(vm, at, SIZE_MAX);
    bytes.resize(size + 1, 0);
    if (size && !GuestRead(vm, at, bytes.data(), size)) { errno = EFAULT; return false; }
    return true;
}

HLE_DEFINE(hle_uname) {
    gva_t out = GuestArg(vm, 0);
    if (!out) { PosixResult(vm, -1, EFAULT); return; }
    struct utsname native = {};
    int result = uname(&native), saved = errno;
    if (result == 0) {
        // Darwin has five 256-byte C arrays on both armv7 and arm64.
        static_assert(sizeof(native) == 5 * 256, "Darwin utsname layout");
        if (!GuestWrite(vm, out, &native, sizeof(native))) { result = -1; saved = EFAULT; }
    }
    PosixResult(vm, result, saved);
}
HLE_BIND("_uname", hle_uname)

HLE_DEFINE(hle_realpath) {
    gva_t out = GuestArg(vm, 1);
    std::vector<char> path;
    if (!PosixCString(vm, GuestArg(vm, 0), path)) {
        int saved = errno; HLESetGuestErrno(vm, saved); GuestSetRet(vm, 0); return;
    }
    NSString *original=[NSString stringWithUTF8String:path.data()];BOOL matched=NO;NSString *mapped=original?AS6ResolveResourceReadPath(original,&matched):nil;
    if(matched&&!mapped){HLESetGuestErrno(vm,ENOENT);GuestSetRet(vm,0);return;}
    char *resolved = realpath(mapped?mapped.fileSystemRepresentation:path.data(), nullptr);
    int saved = errno;
    if (!resolved) { HLESetGuestErrno(vm, saved); GuestSetRet(vm, 0); return; }
    size_t size = strlen(resolved) + 1;
    if (!out) out = GuestAlloc(vm, size);
    bool written = out && GuestWrite(vm, out, resolved, size);
    free(resolved);
    if (!written) { HLESetGuestErrno(vm, EFAULT); out = 0; }
    GuestSetRet(vm, out);
}
HLE_BIND("_realpath$DARWIN_EXTSN", hle_realpath)

HLE_DEFINE(hle_CC_MD5) {
    gva_t source = GuestArg(vm, 0), out = GuestArg(vm, 2);
    uint32_t size = GuestArg(vm, 1);
    std::vector<uint8_t> bytes(size ? size : 1, 0);
    if (size && (!source || !GuestRead(vm, source, bytes.data(), size))) {
        HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, 0); return;
    }
    typedef unsigned char *(*MD5Fn)(const void *, CC_LONG, unsigned char *);
    auto fn = reinterpret_cast<MD5Fn>(HLEHostSymbol("_CC_MD5"));
    if (!fn) { HLESetGuestErrno(vm, ENOSYS); GuestSetRet(vm, 0); return; }
    uint8_t digest[CC_MD5_DIGEST_LENGTH] = {};
    if (!fn(bytes.data(), size, digest)) { GuestSetRet(vm, 0); return; }
    if (!out) out = GuestAlloc(vm, sizeof(digest));
    if (!out || !GuestWrite(vm, out, digest, sizeof(digest))) {
        HLESetGuestErrno(vm, EFAULT); GuestSetRet(vm, 0); return;
    }
    GuestSetRet(vm, out);
}
HLE_BIND("_CC_MD5", hle_CC_MD5)

static thread_local gva_t g_strtokNext = 0;
HLE_DEFINE(hle_strtok) {
    gva_t source = GuestArg(vm, 0), delimiters = GuestArg(vm, 1);
    std::vector<char> delimiterBytes;
    if (!PosixCString(vm, delimiters, delimiterBytes)) {
        HLESetGuestErrno(vm, errno); GuestSetRet(vm, 0); return;
    }
    if (!source) source = g_strtokNext;
    if (!source) { GuestSetRet(vm, 0); return; }
    bool delimiter[256] = {};
    for (size_t i = 0; i + 1 < delimiterBytes.size(); i++) delimiter[(uint8_t)delimiterBytes[i]] = true;
    uint8_t byte = 0;
    bool readable = GuestRead(vm, source, &byte, 1);
    while (readable && byte && delimiter[byte]) readable = GuestRead(vm, ++source, &byte, 1);
    if (!readable) { HLESetGuestErrno(vm, EFAULT); g_strtokNext = 0; GuestSetRet(vm, 0); return; }
    if (!byte) { g_strtokNext = 0; GuestSetRet(vm, 0); return; }
    gva_t token = source;
    while (readable && byte && !delimiter[byte]) readable = GuestRead(vm, ++source, &byte, 1);
    if (!readable) { HLESetGuestErrno(vm, EFAULT); g_strtokNext = 0; GuestSetRet(vm, 0); return; }
    if (byte) {
        uint8_t nul = 0;
        GuestWrite(vm, source, &nul, 1);
        g_strtokNext = source + 1;
    } else g_strtokNext = 0;
    GuestSetRet(vm, token);
}
HLE_BIND("_strtok", hle_strtok)

#pragma pack(push, 4)
struct GuestSigEvent {
    int32_t notify, signo;
    uint32_t value, notifyFunction, attributes;
};
struct GuestAioCB {
    int32_t fd;
    int64_t offset;
    uint32_t buffer, count;
    int32_t priority;
    GuestSigEvent event;
    int32_t opcode;
};
struct GuestSigAction { uint32_t handler, mask, flags; };
struct GuestSigInfo {
    int32_t signo, error, code, pid;
    uint32_t uid;
    int32_t status;
    uint32_t address, value;
    int32_t band;
    uint32_t reserved[7];
};
#pragma pack(pop)
static_assert(sizeof(GuestAioCB) == 48 && offsetof(GuestAioCB, offset) == 4 &&
              offsetof(GuestAioCB, event) == 24, "original armv7 aiocb");
static_assert(sizeof(GuestSigAction) == 12 && sizeof(GuestSigInfo) == 64, "armv7 signal ABI");

struct GuestAioRequest {
    GuestAioCB control = {};
    gva_t controlAddress = 0;
    std::vector<uint8_t> bytes;
    ssize_t result = -1;
    int error = EINPROGRESS;
    std::atomic<bool> hostDone{false};
    bool committed = false, notified = false, returned = false;
};
struct GuestPosixState {
    std::unordered_map<gva_t, std::shared_ptr<GuestAioRequest>> requests;
    std::unordered_map<int, GuestSigAction> actions;
    gva_t signalInfo = 0;
    GuestCpuSnapshot *context = nullptr;
    ~GuestPosixState() { if (context) GuestCPUFree(context); }
};
static std::unordered_map<uintptr_t, std::unique_ptr<GuestPosixState>> g_posixStates;
static std::atomic<bool> g_posixReady{false};
static thread_local bool g_deliveringPosixSignal = false;
static thread_local uint32_t g_guestSignalMask = 0;

static GuestPosixState &PosixState(GuestVM *vm) {
    auto &state = g_posixStates[(uintptr_t)(__bridge void *)vm];
    if (!state) state = std::make_unique<GuestPosixState>();
    return *state;
}

// Public import-boundary hook. A pending completion can interrupt a guest
// startup loop even while the host main run loop has not regained control.
extern "C" void HLEPosixPoll(GuestVM *vm) {
    if (!vm || g_deliveringPosixSignal || ![NSThread isMainThread]) return;
    if (!g_posixReady.exchange(false, std::memory_order_acquire)) return;
    GuestLock(vm);
    auto &state = PosixState(vm);
    std::vector<std::shared_ptr<GuestAioRequest>> ready;
    for (const auto &entry : state.requests)
        if (entry.second->hostDone.load(std::memory_order_acquire)) ready.push_back(entry.second);
    g_deliveringPosixSignal = true;
    for (const auto &request : ready) {
        if (!request->committed) {
            if (request->result > 0 && !GuestWrite(vm, request->control.buffer,
                                                  request->bytes.data(), (size_t)request->result)) {
                request->result = -1; request->error = EFAULT;
            }
            request->committed = true;
            std::vector<uint8_t>().swap(request->bytes);
            GuestTrace(vm, @"[posix] real async read cb=%#x offset=%lld requested=%u -> %lld errno=%d",
                       request->controlAddress, (long long)request->control.offset,
                       request->control.count, (long long)request->result, request->error);
        }
        if (request->notified || request->control.event.notify != SIGEV_SIGNAL) continue;
        int signal = request->control.event.signo;
        uint32_t bit = 1u << (signal - 1);
        if (g_guestSignalMask & bit) continue;
        GuestSigAction action = state.actions[signal];
        request->notified = true;
        if (action.handler == 1) continue; // SIG_IGN
        if (action.handler == 0) {
            GuestTrace(vm, @"[posix] guest default action for async signal %d; halting guest", signal);
            GuestRequestHalt(vm);
            continue;
        }
        if (!state.context && GuestCPUAllocate(vm, &state.context) != GuestExecutionSuccess) {
            request->notified = false; g_posixReady.store(true); continue;
        }
        if (GuestCPUSave(vm, state.context) != GuestExecutionSuccess) {
            request->notified = false; g_posixReady.store(true); continue;
        }
        std::string current = HLECurrentSymbol() ?: "";
        uint32_t maskBefore = g_guestSignalMask;
        g_guestSignalMask |= action.mask;
        if (!(action.flags & SA_NODEFER)) g_guestSignalMask |= bit;
        if (action.flags & SA_RESETHAND) state.actions[signal].handler = 0;
        uint32_t args[3] = {(uint32_t)signal, 0, 0};
        int count = 1;
        if (action.flags & SA_SIGINFO) {
            if (!state.signalInfo) state.signalInfo = GuestAlloc(vm, sizeof(GuestSigInfo));
            GuestSigInfo info = {};
            info.signo = signal; info.code = SI_ASYNCIO; info.error = request->error;
            info.pid = getpid(); info.uid = getuid(); info.value = request->control.event.value;
            GuestWrite(vm, state.signalInfo, &info, sizeof(info));
            args[1] = state.signalInfo; count = 3;
        }
        GuestTrace(vm, @"[posix] guest async signal %d -> handler=%#x", signal, action.handler);
        GuestCall(vm, action.handler, args, count, 100000000);
        g_guestSignalMask = maskBefore;
        GuestCPURestore(vm, state.context);
        HLESetCurrentSymbol(current.c_str());
    }
    g_deliveringPosixSignal = false;
    GuestUnlock(vm);
}

static dispatch_queue_t PosixReadQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("as6.original.posix-file-read", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

HLE_DEFINE(hle_aio_read) {
    gva_t address = GuestArg(vm, 0);
    GuestAioCB control = {};
    if (!address || !GuestRead(vm, address, &control, sizeof(control))) {
        PosixResult(vm, -1, EFAULT); return;
    }
    if (control.offset < 0 || (control.count && !control.buffer) ||
        (control.event.notify != SIGEV_NONE && control.event.notify != SIGEV_SIGNAL) ||
        (control.event.notify == SIGEV_SIGNAL && (control.event.signo < 1 || control.event.signo >= NSIG))) {
        PosixResult(vm, -1, EINVAL); return;
    }
    auto &state = PosixState(vm);
    auto existing = state.requests.find(address);
    if (existing != state.requests.end() && !existing->second->returned) {
        PosixResult(vm, -1, EAGAIN); return;
    }
    int descriptor = dup(control.fd), saved = errno;
    if (descriptor < 0) { PosixResult(vm, -1, saved); return; }
    std::shared_ptr<GuestAioRequest> request;
    try {
        request = std::make_shared<GuestAioRequest>();
        request->control = control; request->controlAddress = address;
        request->bytes.resize(control.count ? control.count : 1);
    } catch (const std::bad_alloc &) {
        close(descriptor); PosixResult(vm, -1, ENOMEM); return;
    }
    state.requests[address] = request;
    dispatch_async(PosixReadQueue(), ^{
        ssize_t result;
        do { result = pread(descriptor, request->bytes.data(), control.count, control.offset); }
        while (result < 0 && errno == EINTR);
        int error = result < 0 ? errno : 0;
        close(descriptor);
        request->result = result; request->error = error;
        request->hostDone.store(true, std::memory_order_release);
        g_posixReady.store(true, std::memory_order_release);
        dispatch_async(dispatch_get_main_queue(), ^{ HLEPosixPoll(vm); });
    });
    GuestSetRet(vm, 0); // An actual pread operation has now been enqueued.
}
HLE_BIND("_aio_read", hle_aio_read)

HLE_DEFINE(hle_aio_error) {
    gva_t address = GuestArg(vm, 0);
    HLEPosixPoll(vm);
    auto &requests = PosixState(vm).requests;
    auto found = requests.find(address);
    if (found == requests.end()) { GuestSetRet(vm, EINVAL); return; }
    auto request = found->second;
    GuestSetRet(vm, request->committed ? request->error : EINPROGRESS);
}
HLE_BIND("_aio_error", hle_aio_error)
HLE_DEFINE(hle_aio_return) {
    gva_t address = GuestArg(vm, 0);
    HLEPosixPoll(vm);
    auto &requests = PosixState(vm).requests;
    auto found = requests.find(address);
    if (found == requests.end() || !found->second->committed || found->second->returned) {
        PosixResult(vm, -1, EINVAL); return;
    }
    found->second->returned = true;
    PosixResult(vm, found->second->result, found->second->error);
}
HLE_BIND("_aio_return", hle_aio_return)

HLE_DEFINE(hle_sigaction) {
    int signal = (int)GuestArg(vm, 0);
    gva_t input = GuestArg(vm, 1), output = GuestArg(vm, 2);
    if (signal <= 0 || signal >= NSIG || signal == SIGKILL || signal == SIGSTOP) {
        PosixResult(vm, -1, EINVAL); return;
    }
    auto &actions = PosixState(vm).actions;
    GuestSigAction previous = actions[signal], action = {};
    if (input && !GuestRead(vm, input, &action, sizeof(action))) {
        PosixResult(vm, -1, EFAULT); return;
    }
    if (output && !GuestWrite(vm, output, &previous, sizeof(previous))) {
        PosixResult(vm, -1, EFAULT); return;
    }
    if (input) {
        // The original explicitly ignores SIGPIPE at 0x69cfdc. This native
        // sentinel is safe; guest executable addresses are never registered.
        if (signal == SIGPIPE && action.handler == 1) {
            struct sigaction ignore = {};
            ignore.sa_handler = SIG_IGN;
            int result = sigaction(SIGPIPE, &ignore, nullptr), saved = errno;
            if (result < 0) { PosixResult(vm, -1, saved); return; }
        }
        actions[signal] = action;
    }
    GuestSetRet(vm, 0);
}
HLE_BIND("_sigaction", hle_sigaction)

HLE_DEFINE(hle_sigprocmask) {
    int how = (int)GuestArg(vm, 0);
    gva_t input = GuestArg(vm, 1), output = GuestArg(vm, 2);
    uint32_t mask = 0, previous = g_guestSignalMask;
    if (input && !GuestRead(vm, input, &mask, sizeof(mask))) {
        PosixResult(vm, -1, EFAULT); return;
    }
    if (output && !GuestWrite(vm, output, &previous, sizeof(previous))) {
        PosixResult(vm, -1, EFAULT); return;
    }
    if (input) {
        mask &= ~((1u << (SIGKILL - 1)) | (1u << (SIGSTOP - 1)));
        if (how == SIG_BLOCK) g_guestSignalMask |= mask;
        else if (how == SIG_UNBLOCK) g_guestSignalMask &= ~mask;
        else if (how == SIG_SETMASK) g_guestSignalMask = mask;
        else { PosixResult(vm, -1, EINVAL); return; }
        // Completed reads whose guest notification was masked remain pending.
        g_posixReady.store(true, std::memory_order_release);
        HLEPosixPoll(vm);
    }
    GuestSetRet(vm, 0);
}
HLE_BIND("_sigprocmask", hle_sigprocmask)
