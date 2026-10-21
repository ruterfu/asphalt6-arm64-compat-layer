// HLE_pthread.m -- the original binary's pthread imports.
//
// The generic dlsym bridge cannot serve these: every argument is a *guest*
// pointer, and handing 0x00749e88 to the host pthread_mutex_init() segfaults
// the process.  Each guest synchronisation object therefore gets a real host
// object allocated on demand and keyed by its guest address.
//
// Guest threads are host threads, but the single native CPU state is shared, so a
// scheduler hands full native CPU snapshots over between them. GuestEmulate
// dispatches blocking bridges only after native emulation has returned; the
// recursive VM lock is then suspended/restored around real POSIX waits.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <sched.h>
#import <time.h>
#import <unordered_map>
#import <mutex>
#import <memory>
#import <errno.h>
#import <string>

#import "GuestVM.h"
#import "GuestObjC.h"
#import "HLE.h"
#import "GuestSchedulerPrivate.h"
#import "GuestTypes.h"
#import "AudioProducerPrivate.h"

// --- CPU state hand-off -----------------------------------------------------

struct GuestCpuState { std::shared_ptr<GuestCpuSnapshot> context; };
struct GuestCpuSchedule {
    std::unordered_map<uintptr_t, GuestCpuState> states;
    uintptr_t owner = 0;
};
static std::recursive_mutex g_schedLock;
// A VM allocation address can be reused. Snapshot owner ids bind the actual
// immutable NativeState lifetime and are retired when that Core really dies.
static std::unordered_map<uint64_t, GuestCpuSchedule> g_cpuSchedules;
extern "C" void HLEPthreadForgetCPUOwner(uint64_t owner) {
    if(!owner)return;
    std::lock_guard<std::recursive_mutex> lock(g_schedLock);
    g_cpuSchedules.erase(owner);
}
#if defined(AS6_NAV_VM_FIXTURE)
extern "C" size_t AS6PthreadScheduleCountForFixture() {
    std::lock_guard<std::recursive_mutex> lock(g_schedLock);return g_cpuSchedules.size();
}
extern "C" bool AS6PthreadHasOwnerForFixture(uint64_t owner) {
    std::lock_guard<std::recursive_mutex> lock(g_schedLock);return g_cpuSchedules.count(owner)!=0;
}
#endif

static bool SaveCpu(GuestVM *vm, GuestCpuState &state) {
    GuestExecutionResult error = GuestExecutionSuccess;
    if (!state.context) {
        GuestCpuSnapshot *context = nullptr;
        error = GuestCPUAllocate(vm, &context);
        if (error == GuestExecutionSuccess)
            state.context = std::shared_ptr<GuestCpuSnapshot>(context, [](GuestCpuSnapshot *c) { GuestCPUFree(c); });
    }
    if (error == GuestExecutionSuccess) error = GuestCPUSave(vm, state.context.get());
    if (error != GuestExecutionSuccess) {
        GuestTrace(vm, @"[pthread] cannot save CPU context: %s", GuestExecutionErrorText(error));
        GuestRequestHalt(vm);
        return false;
    }
    return true;
}
static bool LoadCpu(GuestVM *vm, const GuestCpuState &state) {
    if (!state.context) return true;
    GuestExecutionResult error = GuestCPURestore(vm, state.context.get());
    if (error == GuestExecutionSuccess) return true;
    GuestTrace(vm, @"[pthread] cannot restore CPU context: %s", GuestExecutionErrorText(error));
    GuestRequestHalt(vm);
    return false;
}
static bool SchedTake(GuestVM *vm) {
    const uint64_t identity=GuestSchedulerOwnerLocked(vm);
    if(!identity)return false;
    const uintptr_t self=(uintptr_t)pthread_self();
    std::lock_guard<std::recursive_mutex> lock(g_schedLock);
    auto foundSchedule=g_cpuSchedules.find(identity);
    // Cleanup of a stopped/dead VM must never invent another schedule.
    if(foundSchedule==g_cpuSchedules.end()) {
        if(GuestHasStopRequest(vm))return false;
        foundSchedule=g_cpuSchedules.try_emplace(identity).first;
    }
    auto &schedule=foundSchedule->second;
    if(schedule.owner==self)return true;
    if(schedule.owner&&!SaveCpu(vm,schedule.states[schedule.owner]))return false;
    auto found=schedule.states.find(self);
    if(found!=schedule.states.end()&&!LoadCpu(vm,found->second))return false;
    schedule.owner=self;return true;
}
void HLEPthreadTakeCPU(GuestVM *vm) { if(vm)SchedTake(vm); }

// Every activation retains both its VM and exact saved snapshot. A successful
// Begin acquires a Core lifetime borrow before suspending any lock level.
struct GuestBlock {
    __strong GuestVM *vm;NSUInteger depth;std::string symbol;
    uint64_t identity=0;GuestCpuState saved;bool borrowed=false;
};
static bool GuestBlockBegin(GuestVM *vm,GuestBlock &block) {
    block.vm=vm;block.depth=0;block.symbol=HLECurrentSymbol()?:"";
    const auto ready=GuestSchedulerCanBlockLocked(vm);
    if(ready!=GuestExecutionSuccess){const bool stopped=GuestHasStopRequest(vm);if(!stopped)GuestRequestFault(vm);errno=stopped?ECANCELED:EIO;return false;}
    block.identity=GuestSchedulerOwnerLocked(vm);
    {
        std::lock_guard<std::recursive_mutex> lock(g_schedLock);
        auto found=g_cpuSchedules.find(block.identity);
        if(found==g_cpuSchedules.end()||found->second.owner!=(uintptr_t)pthread_self()) {
            GuestRequestFault(vm);errno=EIO;return false;
        }
        auto &schedule=found->second;
        if(!SaveCpu(vm,schedule.states[schedule.owner])){errno=EIO;return false;}
        block.saved=schedule.states[schedule.owner];
        if(!GuestSchedulerBorrowBeginLocked(vm,block.identity)){GuestRequestFault(vm);errno=EIO;return false;}
        block.borrowed=true;schedule.owner=0;
    }
    block.depth=GuestSuspendLocks(vm);
    if(!block.depth) {
        // Suspend refused before releasing locks. Restore scheduler ownership;
        // no operation or native wait is permitted after this failed Begin.
        std::lock_guard<std::recursive_mutex> lock(g_schedLock);
        auto found=g_cpuSchedules.find(block.identity);
        if(found!=g_cpuSchedules.end())found->second.owner=(uintptr_t)pthread_self();
        GuestSchedulerBorrowEndLocked(vm,block.identity);block.borrowed=false;
        GuestRequestFault(vm);errno=EIO;return false;
    }
    return true;
}
static bool GuestBlockEnd(GuestVM *vm,GuestBlock &block) {
    if(!block.depth||!block.borrowed){GuestRequestFault(vm);return false;}
    const NSUInteger depth=block.depth;block.depth=0;bool restored=false;
    const BOOL audioResume=GuestAudioProducerBeginResumeWait(vm);
    @try {
        GuestSchedulerResumeLocks(vm,depth);
        @try {
            // Check the captured Core before touching CPU/scheduler data. End
            // never creates a missing schedule or switches to another Core.
            if(GuestSchedulerOwnerLocked(vm)==block.identity) {
                std::lock_guard<std::recursive_mutex> lock(g_schedLock);
                auto found=g_cpuSchedules.find(block.identity);
                if(found!=g_cpuSchedules.end()) {
                    auto &schedule=found->second;
                    const auto self=(uintptr_t)pthread_self();
                    const bool savedOther=!schedule.owner||schedule.owner==self||SaveCpu(vm,schedule.states[schedule.owner]);
                    if(savedOther&&LoadCpu(vm,block.saved)) {
                        schedule.owner=self;restored=true;
                    }
                }
            }
            if(!restored)GuestRequestFault(vm);
            HLESetCurrentSymbol(block.symbol.c_str());
        } @finally {
            GuestSchedulerBorrowEndLocked(vm,block.identity);block.borrowed=false;
        }
    } @finally {GuestAudioProducerEndResumeWait(vm,audioResume);}
    return restored;
}
// Non-faulting form of GuestBlockBegin's preconditions, for optional yields:
// this thread owns the current CPU schedule and the scheduler may block now.
bool HLEPthreadCanYieldLocked(GuestVM *vm) {
    if(!vm||GuestSchedulerCanBlockLocked(vm)!=GuestExecutionSuccess)return false;
    const auto identity=GuestSchedulerOwnerLocked(vm);
    std::lock_guard<std::recursive_mutex> lock(g_schedLock);
    auto found=g_cpuSchedules.find(identity);
    return found!=g_cpuSchedules.end()&&found->second.owner==(uintptr_t)pthread_self();
}
int HLEPthreadBlockingCall(GuestVM *vm,int (*operation)(void *),void *context) {
    if(!vm||!operation){errno=EINVAL;return -1;}
    const int previousErrno=errno;GuestBlock block{vm,0,{}};
    if(!GuestBlockBegin(vm,block))return -1;
    errno=previousErrno;int result=-1;bool restored=false;
    @try {result=operation(context);}
    @finally {
        const int operationErrno=errno;
        restored=GuestBlockEnd(vm,block);
        errno=operationErrno;
    }
    if(!restored){errno=EIO;return -1;}
    if(GuestHasStopRequest(vm)){errno=ECANCELED;return -1;}
    return result;
}

// --- synchronisation objects -------------------------------------------------

static std::mutex g_mapLock;
static std::unordered_map<uint32_t, pthread_mutex_t *> g_mutexes;
static std::unordered_map<uint32_t, pthread_cond_t *> g_conds;
static std::unordered_map<uint32_t, pthread_attr_t *> g_attrs;
static std::unordered_map<uint32_t, pthread_mutexattr_t *> g_mattrs;
static std::unordered_map<uint32_t, pthread_key_t> g_keys;
static std::unordered_map<uint64_t, void *> g_keyValues;   // (tid<<32 | key) -> value

static pthread_mutex_t *HostMutex(GuestVM *vm, uint32_t gva,
                                  const pthread_mutexattr_t *provided = nullptr) {
    if (!gva) return nullptr;
    std::lock_guard<std::mutex> lock(g_mapLock);
    auto found = g_mutexes.find(gva);
    if (found != g_mutexes.end()) return found->second;
    pthread_mutex_t *mutex = (pthread_mutex_t *)calloc(1, sizeof(*mutex));
    if (!mutex) return nullptr;
    pthread_mutexattr_t local;
    pthread_mutexattr_init(&local);
    // Darwin's static initializer signatures distinguish these mutex types.
    uint32_t signature = GuestReadU32(vm, gva);
    if (signature == 0x32AAABA1u) pthread_mutexattr_settype(&local, PTHREAD_MUTEX_ERRORCHECK);
    if (signature == 0x32AAABA2u) pthread_mutexattr_settype(&local, PTHREAD_MUTEX_RECURSIVE);
    int result = pthread_mutex_init(mutex, provided ? provided : &local);
    pthread_mutexattr_destroy(&local);
    if (result) { free(mutex); return nullptr; }
    g_mutexes[gva] = mutex;
    return mutex;
}

static pthread_cond_t *HostCond(uint32_t gva, bool *created = nullptr) {
    std::lock_guard<std::mutex> lk(g_mapLock);
    auto it = g_conds.find(gva);
    if (it != g_conds.end()) { if (created) *created = false; return it->second; }
    pthread_cond_t *c = (pthread_cond_t *)calloc(1, sizeof *c);
    pthread_cond_init(c, nullptr);
    g_conds[gva] = c;
    if (created) *created = true;
    return c;
}

static pthread_attr_t *HostAttr(uint32_t gva) {
    std::lock_guard<std::mutex> lk(g_mapLock);
    auto it = g_attrs.find(gva);
    if (it != g_attrs.end()) return it->second;
    pthread_attr_t *a = (pthread_attr_t *)calloc(1, sizeof *a);
    pthread_attr_init(a);
    g_attrs[gva] = a;
    return a;
}

static pthread_mutexattr_t *HostMAttr(uint32_t gva) {
    std::lock_guard<std::mutex> lk(g_mapLock);
    auto it = g_mattrs.find(gva);
    if (it != g_mattrs.end()) return it->second;
    pthread_mutexattr_t *a = (pthread_mutexattr_t *)calloc(1, sizeof *a);
    pthread_mutexattr_init(a);
    g_mattrs[gva] = a;
    return a;
}

// --- mutex ------------------------------------------------------------------

HLE_DEFINE(hle_mutex_init) {
    uint32_t address = GuestArg(vm, 0), attr = GuestArg(vm, 1);
    pthread_mutexattr_t *attribute = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_mapLock);
        if (g_mutexes.count(address)) { GuestSetRet(vm, EBUSY); return; }
        if (attr) {
            auto found = g_mattrs.find(attr);
            if (found == g_mattrs.end()) { GuestSetRet(vm, EINVAL); return; }
            attribute = found->second;
        }
    }
    GuestSetRet(vm, HostMutex(vm, address, attribute) ? 0 : EINVAL);
}
HLE_BIND("_pthread_mutex_init", hle_mutex_init)

HLE_DEFINE(hle_mutex_lock) {
    const uint32_t address = GuestArg(vm, 0);
    pthread_mutex_t *mutex = HostMutex(vm, address);
    if (!mutex) { GuestSetRet(vm, EINVAL); return; }
    // Preserve the original uncontended, recursive and real-error fast path.
    int result = pthread_mutex_trylock(mutex);
    if (result != EBUSY) { GuestSetRet(vm, result); return; }
    if (GuestAudioProducerIsMutexWait(vm, address)) {
        struct AudioMutexWait { GuestVM *vm; uint32_t address; pthread_mutex_t *mutex; };
        AudioMutexWait wait{vm, address, mutex};
        result = HLEPthreadBlockingCall(vm, [](void *opaque) {
            auto &wait = *static_cast<AudioMutexWait *>(opaque);
            const int savedErrno = errno;
            for (;;) {
                if (GuestAudioProducerCancelMutexWait(wait.vm, wait.address)) {
                    // The trylock path has not acquired this original mutex.
                    GuestAudioProducerMarkCancelled();
                    errno = savedErrno; return ECANCELED;
                }
                const int acquired = pthread_mutex_trylock(wait.mutex);
                if (acquired != EBUSY) { errno = savedErrno; return acquired; }
                // Producer-only non-real-time wait. Every pass rechecks the
                // captured callback's active/epoch/retire cancellation state.
                timespec pause{0, 100000};
                while (nanosleep(&pause, &pause) < 0 && errno == EINTR) {}
            }
        }, &wait);
        GuestSetRet(vm,result<0?errno:result);return;
    }
    // Every other guest mutex retains its exact original blocking behavior.
    result=HLEPthreadBlockingCall(vm,[](void *raw){return pthread_mutex_lock(static_cast<pthread_mutex_t *>(raw));},mutex);
    GuestSetRet(vm,result<0?errno:result);
}
HLE_BIND("_pthread_mutex_lock", hle_mutex_lock)
HLE_DEFINE(hle_mutex_trylock) {
    pthread_mutex_t *mutex = HostMutex(vm, GuestArg(vm, 0));
    GuestSetRet(vm, mutex ? pthread_mutex_trylock(mutex) : EINVAL);
}
HLE_BIND("_pthread_mutex_trylock", hle_mutex_trylock)
HLE_DEFINE(hle_mutex_unlock) {
    pthread_mutex_t *mutex = HostMutex(vm, GuestArg(vm, 0));
    // One guest unlock releases one recursive acquisition, exactly once.
    GuestSetRet(vm, mutex ? pthread_mutex_unlock(mutex) : EINVAL);
}
HLE_BIND("_pthread_mutex_unlock", hle_mutex_unlock)
HLE_DEFINE(hle_mutex_destroy) {
    std::lock_guard<std::mutex> lock(g_mapLock);
    auto found = g_mutexes.find(GuestArg(vm, 0));
    int result = found == g_mutexes.end() ? EINVAL : pthread_mutex_destroy(found->second);
    if (!result) { free(found->second); g_mutexes.erase(found); }
    GuestSetRet(vm, result);
}
HLE_BIND("_pthread_mutex_destroy", hle_mutex_destroy)

HLE_DEFINE(hle_cond_init) {
    GuestSetRet(vm, GuestArg(vm, 0) && HostCond(GuestArg(vm, 0)) ? 0 : EINVAL);
}
HLE_BIND("_pthread_cond_init", hle_cond_init)
HLE_DEFINE(hle_cond_signal) {
    uint32_t address = GuestArg(vm, 0);
    GuestSetRet(vm, address ? pthread_cond_signal(HostCond(address)) : EINVAL);
}
HLE_BIND("_pthread_cond_signal", hle_cond_signal)
HLE_DEFINE(hle_cond_broadcast) {
    uint32_t address = GuestArg(vm, 0);
    GuestSetRet(vm, address ? pthread_cond_broadcast(HostCond(address)) : EINVAL);
}
HLE_BIND("_pthread_cond_broadcast", hle_cond_broadcast)
HLE_DEFINE(hle_cond_wait) {
    uint32_t condition = GuestArg(vm, 0);
    pthread_mutex_t *mutex = HostMutex(vm, GuestArg(vm, 1));
    if (!condition || !mutex) { GuestSetRet(vm, EINVAL); return; }
    pthread_cond_t *cond = HostCond(condition);
    struct Wait{pthread_cond_t *condition;pthread_mutex_t *mutex;}wait{cond,mutex};
    const int result=HLEPthreadBlockingCall(vm,[](void *raw){auto &w=*static_cast<Wait *>(raw);return pthread_cond_wait(w.condition,w.mutex);},&wait);
    GuestSetRet(vm,result<0?errno:result);
}
HLE_BIND("_pthread_cond_wait", hle_cond_wait)
struct GuestTimespec32 { int32_t seconds, nanoseconds; };
static_assert(sizeof(GuestTimespec32) == 8, "Darwin armv7 timespec");
HLE_DEFINE(hle_cond_timedwait) {
    uint32_t condition = GuestArg(vm, 0), mutexAddress = GuestArg(vm, 1);
    GuestTimespec32 guest = {};
    if (!GuestRead(vm, GuestArg(vm, 2), &guest, sizeof(guest))) { GuestSetRet(vm, EFAULT); return; }
    if (guest.nanoseconds < 0 || guest.nanoseconds >= 1000000000) { GuestSetRet(vm, EINVAL); return; }
    pthread_mutex_t *mutex = HostMutex(vm, mutexAddress);
    if (!condition || !mutex) { GuestSetRet(vm, EINVAL); return; }
    struct timespec deadline = {(time_t)guest.seconds, (long)guest.nanoseconds};
    pthread_cond_t *cond = HostCond(condition);
    struct Wait{pthread_cond_t *condition;pthread_mutex_t *mutex;const timespec *deadline;}wait{cond,mutex,&deadline};
    const int result=HLEPthreadBlockingCall(vm,[](void *raw){auto &w=*static_cast<Wait *>(raw);return pthread_cond_timedwait(w.condition,w.mutex,w.deadline);},&wait);
    GuestSetRet(vm,result<0?errno:result);
}
HLE_BIND("_pthread_cond_timedwait", hle_cond_timedwait)
HLE_DEFINE(hle_cond_destroy) {
    std::lock_guard<std::mutex> lock(g_mapLock);
    auto found = g_conds.find(GuestArg(vm, 0));
    int result = found == g_conds.end() ? EINVAL : pthread_cond_destroy(found->second);
    if (!result) { free(found->second); g_conds.erase(found); }
    GuestSetRet(vm, result);
}
HLE_BIND("_pthread_cond_destroy", hle_cond_destroy)

// --- attributes -------------------------------------------------------------

HLE_DEFINE(hle_attr_init) { HostAttr(GuestArg(vm, 0)); GuestSetRet(vm, 0); }
HLE_BIND("_pthread_attr_init", hle_attr_init)

HLE_DEFINE(hle_attr_destroy) {
    uint32_t gva = GuestArg(vm, 0);
    std::lock_guard<std::mutex> lk(g_mapLock);
    auto it = g_attrs.find(gva);
    if (it != g_attrs.end()) { pthread_attr_destroy(it->second); free(it->second); g_attrs.erase(it); }
    GuestSetRet(vm, 0);
}
HLE_BIND("_pthread_attr_destroy", hle_attr_destroy)

HLE_DEFINE(hle_attr_setdetachstate) {
    pthread_attr_t *a = HostAttr(GuestArg(vm, 0));
    int st = (int)GuestArg(vm, 1);
    GuestSetRet(vm, pthread_attr_setdetachstate(a, st == 2 ? PTHREAD_CREATE_DETACHED : (st == 1 ? PTHREAD_CREATE_JOINABLE : -1)));
}
HLE_BIND("_pthread_attr_setdetachstate", hle_attr_setdetachstate)

HLE_DEFINE(hle_attr_setstacksize) {
    pthread_attr_t *a = HostAttr(GuestArg(vm, 0));
    size_t sz = GuestArg(vm, 1);
    if (sz < 512 * 1024) sz = 512 * 1024;
    GuestSetRet(vm, pthread_attr_setstacksize(a, sz));
}
HLE_BIND("_pthread_attr_setstacksize", hle_attr_setstacksize)

HLE_DEFINE(hle_mattr_init) { HostMAttr(GuestArg(vm, 0)); GuestSetRet(vm, 0); }
HLE_BIND("_pthread_mutexattr_init", hle_mattr_init)
HLE_DEFINE(hle_mattr_destroy) {
    uint32_t gva = GuestArg(vm, 0);
    std::lock_guard<std::mutex> lk(g_mapLock);
    auto it = g_mattrs.find(gva);
    if (it != g_mattrs.end()) { pthread_mutexattr_destroy(it->second); free(it->second); g_mattrs.erase(it); }
    GuestSetRet(vm, 0);
}
HLE_BIND("_pthread_mutexattr_destroy", hle_mattr_destroy)
HLE_DEFINE(hle_mattr_settype) {
    pthread_mutexattr_t *a = HostMAttr(GuestArg(vm, 0));
    int t = (int)GuestArg(vm, 1);
    int type = (t == 1) ? PTHREAD_MUTEX_ERRORCHECK : (t == 2) ? PTHREAD_MUTEX_RECURSIVE : PTHREAD_MUTEX_NORMAL;
    GuestSetRet(vm, pthread_mutexattr_settype(a, type));
}
HLE_BIND("_pthread_mutexattr_settype", hle_mattr_settype)

// --- thread-local keys ------------------------------------------------------

HLE_DEFINE(hle_key_create) {
    pthread_key_t key = 0;
    int r = pthread_key_create(&key, nullptr);
    if (r == 0) g_keys[GuestArg(vm, 0)] = key;
    GuestSetRet(vm, r);
}
HLE_BIND("_pthread_key_create", hle_key_create)

HLE_DEFINE(hle_key_getspecific) {
    auto it = g_keys.find(GuestArg(vm, 0));
    GuestSetRet(vm, it == g_keys.end() ? 0 : (uint32_t)(uintptr_t)pthread_getspecific(it->second));
}
HLE_BIND("_pthread_key_getspecific", hle_key_getspecific)

HLE_DEFINE(hle_key_setspecific) {
    auto it = g_keys.find(GuestArg(vm, 0));
    if (it != g_keys.end()) pthread_setspecific(it->second, (const void *)(uintptr_t)GuestArg(vm, 1));
    GuestSetRet(vm, 0);
}
HLE_BIND("_pthread_key_setspecific", hle_key_setspecific)

// --- threads ----------------------------------------------------------------

struct GuestThread {
    GuestVM *vm = nil;
    uint32_t id = 0, entry = 0, arg = 0, stackTop = 0, stopAddr = 0, result = 0;
    pthread_t host = {};
    bool detached = false, joining = false, finished = false, exitRequested = false;
};
static std::unordered_map<uint32_t, std::shared_ptr<GuestThread>> g_threads;
static thread_local uint32_t g_selfGuestTid;
static thread_local GuestThread *g_currentGuestThread;
static uint32_t g_threadStackCursor = 0x30000000u;
// Sentinels must not overlap the main guest stack (old0x3ff00000 did).
static uint32_t g_threadStopCursor = 0x3e000000u;
static uint32_t g_nextGuestTid = 1;
static uint32_t CurrentGuestTid(void) {
    if (!g_selfGuestTid) {
        std::lock_guard<std::mutex> lock(g_mapLock);
        g_selfGuestTid = g_nextGuestTid++ * 0x1000u;
    }
    return g_selfGuestTid;
}
static void *GuestThreadMain(void *raw) {
    std::unique_ptr<std::shared_ptr<GuestThread>> carrier((std::shared_ptr<GuestThread> *)raw);
    auto thread = *carrier;
    GuestVM *vm = thread->vm;
    g_selfGuestTid = thread->id;
    g_currentGuestThread = thread.get();
    @autoreleasepool {
        GuestLock(vm);
        uint32_t cpsr = 0;
        GuestGetCPSR(vm, &cpsr);
        cpsr = (cpsr & ~0x3fu) | 0x10u | ((thread->entry & 1u) ? 0x20u : 0u);
        // Select the user register bank before writing its SP/LR.
        GuestSetCPSR(vm, cpsr);
        GuestSetReg(vm, 0, thread->arg);
        GuestSetReg(vm, 13, thread->stackTop);
        GuestSetReg(vm, 14, thread->stopAddr);
        GuestSetPC(vm, thread->entry & ~1u);
        GuestSetCPSR(vm, cpsr); // PC writes may clear Thumb mode
        // Every import is dispatched after the fixed native execution frame
        // returns; blocking bridges may then safely hand CPU ownership over.
        GuestExecutionResult error = GuestEmulate(vm, thread->entry & ~1u, thread->stopAddr, 0);
        bool returned = error == GuestExecutionSuccess && (GuestPC(vm) & ~1u) == thread->stopAddr;
        if (!thread->exitRequested) thread->result = GuestReg(vm, 0);
        if (!returned) {
            GuestTrace(vm, @"[pthread] guest worker %#x stopped: %s pc=%#x", thread->entry,
                       GuestExecutionErrorText(error), GuestPC(vm));
            GuestRequestHalt(vm);
        } else GuestTrace(vm, @"[pthread] guest worker %#x returned %#x", thread->entry, thread->result);
        {
            std::lock_guard<std::recursive_mutex> lock(g_schedLock);
            const auto identity=GuestSchedulerOwnerLocked(vm);auto found=g_cpuSchedules.find(identity);
            if(found!=g_cpuSchedules.end()){auto &schedule=found->second;
                if(schedule.owner==(uintptr_t)pthread_self())schedule.owner=0;
                schedule.states.erase((uintptr_t)pthread_self());}
        }
        {
            std::lock_guard<std::mutex> lock(g_mapLock);
            thread->finished = true;
            if (thread->detached) g_threads.erase(thread->id);
        }
        GuestUnlock(vm);
    }
    g_currentGuestThread = nullptr;
    return (void *)(uintptr_t)thread->result;
}
HLE_DEFINE(hle_pthread_create) {
    uint32_t output = GuestArg(vm, 0), attr = GuestArg(vm, 1);
    uint32_t entry = GuestArg(vm, 2), arg = GuestArg(vm, 3);
    if (!output || !entry) { GuestSetRet(vm, EINVAL); return; }
    int detachState = PTHREAD_CREATE_JOINABLE;
    {
        std::lock_guard<std::mutex> lock(g_mapLock);
        if (attr) {
            auto found = g_attrs.find(attr);
            if (found == g_attrs.end()) { GuestSetRet(vm, EINVAL); return; }
            int result = pthread_attr_getdetachstate(found->second, &detachState);
            if (result) { GuestSetRet(vm, result); return; }
        }
    }
    const uint32_t stackSize = 1024 * 1024;
    if ((uint64_t)g_threadStackCursor + stackSize > 0x38000000u ||
        !GuestFill(vm, g_threadStackCursor, stackSize) || !GuestFill(vm, g_threadStopCursor, 0x1000)) {
        GuestSetRet(vm, EAGAIN); return;
    }
    auto thread = std::make_shared<GuestThread>();
    thread->vm = vm; thread->entry = entry; thread->arg = arg;
    thread->stackTop = g_threadStackCursor + stackSize - 16;
    thread->stopAddr = g_threadStopCursor;
    thread->detached = detachState == PTHREAD_CREATE_DETACHED;
    GuestRegisterStack(vm, g_threadStackCursor, stackSize);
    g_threadStackCursor += stackSize; g_threadStopCursor += 0x1000;
    {
        std::lock_guard<std::mutex> lock(g_mapLock);
        thread->id = g_nextGuestTid++ * 0x1000u;
        g_threads[thread->id] = thread;
    }
    pthread_attr_t nativeAttr;
    pthread_attr_init(&nativeAttr);
    pthread_attr_setstacksize(&nativeAttr, 4 * 1024 * 1024);
    pthread_attr_setdetachstate(&nativeAttr, detachState);
    auto *carrier = new std::shared_ptr<GuestThread>(thread);
    int result = pthread_create(&thread->host, &nativeAttr, GuestThreadMain, carrier);
    pthread_attr_destroy(&nativeAttr);
    if (result) {
        delete carrier;
        std::lock_guard<std::mutex> lock(g_mapLock);
        g_threads.erase(thread->id);
    } else GuestWriteU32(vm, output, thread->id);
    GuestTrace(vm, @"[pthread] create entry=%#x arg=%#x id=%#x -> %s", entry, arg,
               thread->id, result ? "FAILED" : "ok");
    GuestSetRet(vm, result);
}
HLE_BIND("_pthread_create", hle_pthread_create)
HLE_DEFINE(hle_pthread_self) { GuestSetRet(vm, CurrentGuestTid()); }
HLE_BIND("_pthread_self", hle_pthread_self)
HLE_DEFINE(hle_pthread_equal) { GuestSetRet(vm, GuestArg(vm, 0) == GuestArg(vm, 1)); }
HLE_BIND("_pthread_equal", hle_pthread_equal)
HLE_DEFINE(hle_pthread_exit) {
    if (!g_currentGuestThread) {
        GuestTrace(vm, @"[pthread] exit on main guest thread is unsupported; halting");
        GuestRequestHalt(vm); return;
    }
    g_currentGuestThread->exitRequested = true;
    g_currentGuestThread->result = GuestArg(vm, 0);
    // Return through the worker's own sentinel after the bridge dispatcher,
    // never call native pthread_exit while holding the VM lock.
    GuestSetReg(vm, 14, g_currentGuestThread->stopAddr);
    GuestSetPC(vm, g_currentGuestThread->stopAddr);
}
HLE_BIND("_pthread_exit", hle_pthread_exit)
HLE_DEFINE(hle_pthread_join) {
    uint32_t id = GuestArg(vm, 0), output = GuestArg(vm, 1);
    if (id == CurrentGuestTid()) { GuestSetRet(vm, EDEADLK); return; }
    std::shared_ptr<GuestThread> thread;
    {
        std::lock_guard<std::mutex> lock(g_mapLock);
        auto found = g_threads.find(id);
        if (found == g_threads.end()) { GuestSetRet(vm, ESRCH); return; }
        thread = found->second;
        if (thread->detached || thread->joining) { GuestSetRet(vm, EINVAL); return; }
        thread->joining = true;
    }
    struct Wait{pthread_t thread;}wait{thread->host};
    int result=HLEPthreadBlockingCall(vm,[](void *raw){return pthread_join(static_cast<Wait *>(raw)->thread,nullptr);},&wait);
    if(result<0)result=errno;
    {
        std::lock_guard<std::mutex> lock(g_mapLock);
        if (!result) g_threads.erase(id); else thread->joining = false;
    }
    if (!result && output) GuestWriteU32(vm, output, thread->result);
    GuestSetRet(vm, result);
}
HLE_BIND("_pthread_join", hle_pthread_join)
HLE_DEFINE(hle_pthread_detach) {
    std::lock_guard<std::mutex> lock(g_mapLock);
    auto found = g_threads.find(GuestArg(vm, 0));
    if (found == g_threads.end()) { GuestSetRet(vm, ESRCH); return; }
    auto thread = found->second;
    int result = thread->joining ? EINVAL : pthread_detach(thread->host);
    if (!result) { thread->detached = true; if (thread->finished) g_threads.erase(found); }
    GuestSetRet(vm, result);
}
HLE_BIND("_pthread_detach", hle_pthread_detach)
// Asynchronous host cancellation could tear down Unicorn/locks in mid-call.
// Until guest cancellation cleanup is implemented, report it as unsupported.
HLE_DEFINE(hle_pthread_cancel) { GuestSetRet(vm, ENOTSUP); }
HLE_BIND("_pthread_cancel", hle_pthread_cancel)
HLE_DEFINE(hle_pthread_testcancel) {}
HLE_BIND("_pthread_testcancel", hle_pthread_testcancel)
HLE_DEFINE(hle_pthread_kill) { GuestSetRet(vm, ENOTSUP); }
HLE_BIND("_pthread_kill", hle_pthread_kill)
HLE_DEFINE(hle_pthread_setcanceltype) { GuestSetRet(vm, 0); }
HLE_BIND("_pthread_setcanceltype", hle_pthread_setcanceltype)
HLE_DEFINE(hle_pthread_getschedparam) {
    if (GuestArg(vm, 1)) GuestWriteU32(vm, GuestArg(vm, 1), 31);
    if (GuestArg(vm, 2)) GuestWriteU32(vm, GuestArg(vm, 2), 0);
    GuestSetRet(vm, 0);
}
HLE_BIND("_pthread_getschedparam", hle_pthread_getschedparam)
HLE_DEFINE(hle_pthread_setschedparam) { GuestSetRet(vm, 0); }
HLE_BIND("_pthread_setschedparam", hle_pthread_setschedparam)

