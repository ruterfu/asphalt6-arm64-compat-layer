#import "GuestVM.h"
#import "GuestNativeCPUPrivate.hpp"
#include "GuestSchedulerPrivate.h"
#import "GuestNativeCore.hpp"
#import "HLE.h"
#import "GuestObjC.h"
#include "GuestLocalClassRegistry.hpp"
#include "NativeNavAdapter.hpp"
#include "NavProvider.hpp"
#include <optional>
#include "NativeNavBoundary.hpp"
#include "NativeCopyBoundary.hpp"
#include "NativeCopyUnit.hpp"
#include "NativeUIWorkBoundary.hpp"
#include "NativeSceneBoundary.hpp"
#include "NativeCollisionInverseBoundary.hpp"
#include "UIAppendAdapter.hpp"
#if !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
#import "GLReal.h"
#endif
#include "NavTelemetry.hpp"
#include "OriginalUIBoundary.hpp"
#include "NativeMusicBoundary.hpp"
#if defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
#include <TargetConditionals.h>
#if !TARGET_OS_OSX || !defined(AS6_MACOS_MOTION_ABSENCE_FIXTURE) || !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
#error Native kernel integration fixtures require the explicit Foundation-only macOS test mode
#endif
#endif
#if !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE) || defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
#include "NativeCollisionBoundary.hpp"
#include "NativeCollisionQuery.hpp"
#include "NativeCollisionBoundary36.hpp"
#include "NativeCollisionQuery36.hpp"
#include "NativeVertexBoundary.hpp"
#include "NativeVertexAdapter.hpp"
#include "NativeTrailBoundary.hpp"
#include "NativeTrailAdapter.hpp"
#if defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
// Test observers only mark preallocated spans; they must not call Guest/Host
// APIs, allocate or wait while the source storage lease is held.
extern "C" void AS6NativeTrailObserveWritesForFixture(void *,const as6hostdata::DataMemory::WriteSpan *,std::size_t) noexcept;
#endif
#endif
#if !defined(AS6_NATIVE_MUSIC_ABSENCE_FIXTURE)
#include "NativeMusicAdapter.h"
#endif
#if defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
static inline bool AS6OriginalUIBeforeAdvance(GuestVM *,std::uint32_t) { return true; }
static inline bool AS6OriginalUIApply(GuestVM *,std::uint32_t) { return true; }
static inline bool AS6OriginalUIBeforeUnload(GuestVM *) { return true; }
static inline bool AS6OriginalUIMenuSceneLoaded(GuestVM *,std::uint32_t) { return true; }
static inline void AS6OriginalUIForgetVM(GuestVM *) {}
#else
#include "OriginalUIAdapter.hpp"
#endif

#include <array>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <limits>
#include <mutex>
#include <unordered_map>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <chrono>
#include <algorithm>
#include <sched.h>

#if defined(AS6_COPY_VM_FIXTURE)
#if !defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
#error Copy VM fixture requires the explicit native-kernel macOS fixture mode
#endif
extern "C" void AS6CopyVMObserveBoundaryForFixture(GuestVM *,unsigned);
#endif
#if defined(AS6_UI_WORK_VM_FIXTURE)
#if !defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
#error UI work VM fixture requires the explicit native-kernel macOS fixture mode
#endif
extern "C" void AS6UIWorkVMObserveBoundaryForFixture(GuestVM *,unsigned);
#endif
#if defined(AS6_NAV_VM_FIXTURE)
extern "C" void AS6NavVMObserveBoundaryForFixture(GuestVM *,unsigned);
#endif
extern "C" BOOL GuestAudioProducerNeedsService(void);
extern "C" int GuestAudioWaitForProducerTurn(void);
extern "C" BOOL GuestAudioProducerWasCancelled(GuestVM *);
extern "C" void AS6SystemZlibForgetVM(GuestVM *);

using as6native::Core;
static thread_local std::unordered_map<std::uintptr_t,NSUInteger> lockDepth;
static thread_local std::array<std::uint32_t,64> recentSP{};
static thread_local unsigned recentSPCount;
static std::mutex symbolsLock;
struct Symbol { std::uint32_t at,size; std::string name; };
static std::vector<Symbol> symbols;

// A bounded observer for the actual Game-vptr fault. It borrows the original
// DataAccess, preserving its storage, monitor and every architectural result.
// No original instruction or data is changed by this observer.
struct GameWriteEvent {
    const char *kind=nullptr;
    uint32_t address=0,object=0,before=0,after=0,pc=0,lr=0;
    uint64_t length=0,sequence=0;
    unsigned nativeDepth=0,executionDepth=0;
    bool beforeReadable=false,afterReadable=false,native=false;
    char hle[112]{};
};
struct GameWriteBefore {
    uint32_t game=0,global=0,header=0,constructor=0;
    bool globalHit=false,headerHit=false,constructorHit=false;
    bool globalReadable=false,headerReadable=false,constructorReadable=false;
};
struct TitleInputEvent {
    const char *kind=nullptr;
    uint32_t state=0,pc=0,address=0,value=0,swfObject=0;
    uint64_t swfUpdates=0;
};
struct GameWriteWatch {
    static constexpr uint32_t Global=0x70b230,ConstructorStore=0x1bb9c;
    __unsafe_unretained GuestVM *owner=nil;
    as6aot::DataAccess original{},observed{};
    std::array<GameWriteEvent,32> events{};
    GameWriteEvent firstZero{},firstCleared{};
    uint32_t game=0,lastHeader=0;
    uint64_t sequence=0;
    unsigned count=0;
    bool enabled=false,hasFirstZero=false,hasFirstCleared=false,lastHeaderReadable=false;
    std::array<TitleInputEvent,24> titleEvents{};
    unsigned titleCount=0;
    uint32_t titleState=0,titleLoading=0,titleStage=0,lastSWFObject=0;
    uint64_t swfUpdates=0;
    bool titleLoadingKnown=false,titleStageKnown=false;
    int pngFD=-1;
    bool pngIOFailed=false;
    uint64_t pngRows=0,pngIterations=0;
    uint32_t pngRowBytes=0,pngRowInfo=0,pngRecords=0;
    ~GameWriteWatch(){if(pngFD>=0)::close(pngFD);}
    static bool overlaps(uint32_t at,size_t length,uint32_t word) {
        return length && uint64_t(at)<uint64_t(word)+4 && (at>=word || length>word-at);
    }
    GameWriteBefore before(uint32_t,size_t,bool,bool cached=false);
    void after(const GameWriteBefore &,uint32_t,size_t,bool);
    void record(const char *,uint32_t,size_t,uint32_t,uint32_t,bool,uint32_t,bool,bool);
    void install(GuestVM *);
    void title_record(const char *,uint32_t,uint32_t);
    void observe_read(uint32_t,const void *,size_t);
    void observe_write(uint32_t,const void *,size_t);
    void png_record(const char *,uint32_t);
};

@interface GuestVM () {
@public
    std::unique_ptr<Core> _core;
    GameWriteWatch _gameWriteWatch;
    std::unique_ptr<as6native::ObjCEmptyVtableIdentity> _objcMetadata;
    NSRecursiveLock *_lock;
    // The thread whose lockDepth entry for this VM is non-zero, else null.
    // Only the lock holder writes it, so a thread reads its own id here
    // exactly while it holds the lock.
    std::atomic<pthread_t> _lockOwner;
    NSMutableArray<NSString *> *_trace;
    std::atomic<bool> _fault, _halt;
    GuestExecutionResult _lastResult;
    std::uint32_t _heapCursor;
    std::vector<std::pair<std::uint32_t,std::uint64_t>> _stacks;
    std::unordered_map<std::string,NSUInteger> _missing;
    std::array<std::uint32_t,64> _recentPC;
    unsigned _recentCount;
    NSUInteger _calls, _autoCalls;
    BOOL _traceEnabled, _loaded;
    BOOL _initializersRan;
    NSUInteger _completedInitializers;
    NSDictionary<NSString *, id> *_firstNativeFailure;
    BOOL _objcRegistryCommitted;
    NSUInteger _bindApplied;
    unsigned _nativeDepth;
    unsigned _executionDepth;
    std::uint64_t _schedulerOwner;
    std::size_t _blockingDepth;
    as6_nav_vm::Telemetry _nav;
    std::optional<as6_large_nav::Workspace> _navWorkspace;
    std::uint64_t _navWorkspaceOwner;
    uint64_t _nativeSlices;
    uint64_t _schedulerYields;
    uint64_t _mainThreadYields;
    uint64_t _collisionAttempts,_collisionHandled,_collisionNodes,_collisionTriangleBytes;
    std::array<uint64_t,10> _collisionReasons;
    std::array<uint64_t,8> _collisionKernelStatuses;
    uint64_t _collision36Attempts,_collision36Handled,_collision36Nodes,_collision36TriangleBytes;
    std::array<uint64_t,10> _collision36Reasons;
    std::array<uint64_t,8> _collision36KernelStatuses;
    uint64_t _uiWorkAttempts,_uiWorkHandled,_uiWorkDeclined,_uiWorkInstructions;
    uint64_t _sceneAttempts,_sceneHandled,_sceneDeclined,_sceneInstructions;
    uint64_t _collisionInverseAttempts,_collisionInverseHandled,_collisionInverseDeclined,_collisionInverseInstructions;
    uint64_t _copyAttempts,_copyHandled,_copyRecords,_copyInstructions,_copyDeclined;
    uint64_t _vertexAttempts,_vertexHandled,_vertexVertices,_vertexSourceBytes,_vertexOutputBytes;
    uint64_t _vertexVectorized,_vertexExtended,_vertexParallel,_vertexBackgroundTasks,_vertexParallelReplays;
    std::array<uint64_t,11> _vertexReasons;
    std::array<uint64_t,5> _vertexKernelStatuses;
    uint64_t _trailAttempts,_trailHandled,_trailEmpty,_trailIndexReadBytes;
    uint64_t _trailVertexWriteBytes,_trailIndexWriteBytes,_trailStateWriteBytes;
    std::array<uint64_t,9> _trailReasons;
    std::array<uint64_t,7> _trailKernelStatuses;
}
@end

// Private diagnostics borrow the current owner; they never select a CPU.
static bool DiagnosticLockHeld(__unsafe_unretained GuestVM *vm) {
    return vm && vm->_lockOwner.load(std::memory_order_relaxed)==pthread_self();
}
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *vm) { return DiagnosticLockHeld(vm) && !vm->_nativeDepth; }

struct PNGDiagnosticErrnoScope {
    const int saved=errno;
    ~PNGDiagnosticErrnoScope(){errno=saved;}
};
void GameWriteWatch::png_record(const char *kind,uint32_t filter) {
    const PNGDiagnosticErrnoScope errnoScope;
    if(pngFD<0||pngRecords>=256)return;
    const auto &ctx=owner->_core->state().context();uint32_t regs[8]{};
    const unsigned indices[]={0,1,2,3,4,6,12,14};
    for(unsigned i=0;i<8;++i)owner->_core->state().get_register(indices[i],regs[i]);
    char line[768];const int length=std::snprintf(line,sizeof(line),
        "{\"kind\":\"%s\",\"ticks\":%llu,\"pc\":%u,\"filter\":%u,\"rows\":%llu,\"rowinfo\":%u,\"rowbytes\":%u,\"filter_iterations\":%llu,\"swf_updates\":%llu,\"remaining_budget\":%llu,\"r0_r1_r2_r3_r4_r6_r12_lr\":[%u,%u,%u,%u,%u,%u,%u,%u]}\n",
        kind,(unsigned long long)mach_absolute_time(),ctx.next_pc,filter,(unsigned long long)pngRows,pngRowInfo,pngRowBytes,
        (unsigned long long)pngIterations,(unsigned long long)swfUpdates,(unsigned long long)ctx.budget,regs[0],regs[1],regs[2],regs[3],regs[4],regs[5],regs[6],regs[7]);
    if(length<=0||size_t(length)>=sizeof(line)||::write(pngFD,line,size_t(length))!=length){
        pngIOFailed=true;::close(pngFD);pngFD=-1;return;
    }
    ++pngRecords;
}
extern "C" BOOL GuestConfigurePNGProgressFile(GuestVM *vm,const char *path) {
    const PNGDiagnosticErrnoScope errnoScope;
    if(!vm||!vm->_core||!path)return NO;
    GuestLock(vm);
    @try {
        auto &watch=vm->_gameWriteWatch;
        if(!watch.enabled)return NO;
        if(watch.pngFD>=0)return NO;
        watch.pngFD=::open(path,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0600);
        if(watch.pngFD<0){watch.pngIOFailed=true;return NO;}
        watch.png_record("opened",0);return watch.pngFD>=0;
    } @finally {GuestUnlock(vm);}
}

void GameWriteWatch::title_record(const char *kind,uint32_t address,uint32_t value) {
    if(titleCount>=titleEvents.size())return;
    auto &event=titleEvents[titleCount++];
    event={kind,titleState,owner->_core->state().context().next_pc,address,value,lastSWFObject,swfUpdates};
    char line[288];std::snprintf(line,sizeof(line),
        "[title-input] kind=%s state=%#x pc=%#x address=%#x value=%u swf_object=%#x swf_updates=%llu",
        kind,event.state,event.pc,address,value,event.swfObject,(unsigned long long)swfUpdates);
    GuestRawLog(line);
}
void GameWriteWatch::observe_read(uint32_t address,const void *out,size_t size) {
    if(!enabled)return;
    const auto pc=owner->_core->state().context().next_pc;
    if(pngFD>=0&&pc>=0x37f2f0&&pc<=0x37f450){
        if(size==4&&(pc==0x37f2f0||pc==0x37f330||pc==0x37f368||pc==0x37f3f0)){
            std::memcpy(&pngRowBytes,out,4);pngRowInfo=address-4;++pngRows;
            const uint32_t filter=pc==0x37f2f0?1:pc==0x37f330?2:pc==0x37f368?3:4;
            if(pngRows<=16||!(pngRows&255))png_record("row",filter);
        }else if(size==1&&(pc==0x37f310||pc==0x37f344||pc==0x37f390||pc==0x37f3c4||pc==0x37f418||pc==0x37f450)){
            ++pngIterations;
            if(pngIterations>=4096&&!(pngIterations&(pngIterations-1)))png_record("filter-progress",0);
        }
    }
    if(pc==0x10c2b4&&size==1&&address>=0x12f+4096){
        const auto state=address-0x12f;const uint32_t value=*static_cast<const uint8_t *>(out);
        if(state!=titleState){titleState=state;titleLoadingKnown=false;titleStageKnown=false;}
        if(!titleLoadingKnown||titleLoading!=value){titleLoading=value;titleLoadingKnown=true;title_record("loading-read",address,value);}
    }else if(pc==0x10612c&&size==4&&address>=0x130+4096){
        uint32_t value=0;std::memcpy(&value,out,4);const auto state=address-0x130;
        if(state!=titleState){titleState=state;titleLoadingKnown=false;titleStageKnown=false;}
        if(!titleStageKnown||titleStage!=value){titleStage=value;titleStageKnown=true;title_record("stage-read",address,value);}
    }else if(pc==0x5727c&&address==0x5794c&&size==4){
        // This actual literal LDR is reached once per original SWFUpdate,
        // before any branch. The frozen code and the read remain unchanged.
        ++swfUpdates;owner->_core->state().get_register(0,lastSWFObject);
        if(swfUpdates<=16||!(swfUpdates&(swfUpdates-1)))png_record("swf-update",0);
        if(swfUpdates==1){uint32_t value=0;std::memcpy(&value,out,4);title_record("swf-update-read",address,value);}
    }
}
void GameWriteWatch::observe_write(uint32_t address,const void *in,size_t size) {
    if(!enabled)return;
    const auto pc=owner->_core->state().context().next_pc;
    if(pc==0x10658c&&size==1&&address>=0x12f+4096){
        if(titleState!=address-0x12f){titleLoadingKnown=false;titleStageKnown=false;}
        titleState=address-0x12f;titleLoading=*static_cast<const uint8_t *>(in);titleLoadingKnown=true;
        title_record("loading-clear-write",address,titleLoading);
    }else if(pc==0x106590&&size==4&&address>=0x130+4096){
        if(titleState!=address-0x130){titleLoadingKnown=false;titleStageKnown=false;}
        titleState=address-0x130;std::memcpy(&titleStage,in,4);titleStageKnown=true;
        title_record("stage-clear-write",address,titleStage);
    }
}

GameWriteBefore GameWriteWatch::before(uint32_t at,size_t length,bool native,bool cached) {
    GameWriteBefore value;
    if (!enabled) return value;
    value.game=game;
    value.globalHit=overlaps(at,length,Global);
    value.headerHit=game&&overlaps(at,length,game);
    value.constructorHit=native&&!cached&&owner->_core->state().context().next_pc==ConstructorStore&&length==4;
    // Atomic attempts use the last observed words. Do not pre-read an address
    // before the backend has decided STREX/SWP failure and reservation rules.
    if (value.globalHit) {
        if(cached){value.global=game;value.globalReadable=true;}
        else value.globalReadable=owner->_core->read(Global,&value.global,4);
    }
    if (value.headerHit) {
        if(cached){value.header=lastHeader;value.headerReadable=lastHeaderReadable;}
        else value.headerReadable=owner->_core->read(game,&value.header,4);
    }
    if (value.constructorHit) value.constructorReadable=owner->_core->read(at,&value.constructor,4);
    return value;
}
void GameWriteWatch::record(const char *kind,uint32_t at,size_t length,uint32_t object,
                            uint32_t oldWord,bool oldOK,uint32_t newWord,bool newOK,bool native) {
    GameWriteEvent event;
    event.kind=kind;event.address=at;event.length=length;event.object=object;
    event.before=oldWord;event.after=newWord;event.beforeReadable=oldOK;event.afterReadable=newOK;
    event.pc=owner->_core->state().context().next_pc;
    owner->_core->state().get_register(14,event.lr);
    event.sequence=++sequence;event.native=native;
    event.nativeDepth=owner->_nativeDepth;event.executionDepth=owner->_executionDepth;
    const char *hle=HLECurrentSymbol();
    if(hle)std::snprintf(event.hle,sizeof(event.hle),"%s",hle);
    const bool firstBad=!hasFirstZero&&object&&newOK&&!newWord&&std::strcmp(kind,"global");
    if(firstBad){firstZero=event;hasFirstZero=true;}
    const bool firstClear=!hasFirstCleared&&object&&oldOK&&oldWord&&newOK&&!newWord&&std::strcmp(kind,"global");
    if(firstClear){firstCleared=event;hasFirstCleared=true;}
    const bool retained=count<events.size();
    if(retained)events[count++]=event;
    if(retained||firstBad||firstClear){
        char line[512];
        std::snprintf(line,sizeof(line),"[game-vptr-write] seq=%llu kind=%s source=%s pc=%#x lr=%#x hle=%s "
            "address=%#x length=%llu object=%#x before_ok=%u old=%#x after_ok=%u new=%#x native_depth=%u execution_depth=%u first_zero=%u first_clear=%u",
            (unsigned long long)event.sequence,kind,native?"native":"host",event.pc,event.lr,event.hle,
            at,(unsigned long long)length,object,unsigned(oldOK),oldWord,unsigned(newOK),newWord,
            event.nativeDepth,event.executionDepth,unsigned(firstBad),unsigned(firstClear));
        GuestRawLog(line);
    }
}
void GameWriteWatch::after(const GameWriteBefore &value,uint32_t at,size_t length,bool native) {
    if(!enabled)return;
    if(value.constructorHit){
        uint32_t current=0;const bool ok=owner->_core->read(at,&current,4);
        record("constructor",at,length,at,value.constructor,value.constructorReadable,current,ok,native);
    }
    if(value.headerHit){
        uint32_t current=0;const bool ok=owner->_core->read(value.game,&current,4);
        lastHeader=current;lastHeaderReadable=ok;
        if(ok!=value.headerReadable||current!=value.header)
            record("header",at,length,value.game,value.header,value.headerReadable,current,ok,native);
    }
    if(value.globalHit){
        uint32_t current=0;const bool ok=owner->_core->read(Global,&current,4);
        if(ok){
            if(!value.globalReadable||current!=value.global){
                record("global",at,length,current,value.global,value.globalReadable,current,true,native);
                game=current;
                lastHeaderReadable=false;
                if(game){uint32_t header=0;const bool readable=owner->_core->read(game,&header,4);
                    lastHeader=header;lastHeaderReadable=readable;
                    record("published-header",game,4,game,0,false,header,readable,native);}
            }else game=current;
        }
    }
}
void GameWriteWatch::install(GuestVM *vm) {
    owner=vm;
    if(!vm->_core->read(Global,&game,4))return;
    if(game)lastHeaderReadable=vm->_core->read(game,&lastHeader,4);
    auto &context=vm->_core->state().context();
    if(!context.data_access)return;
    original=*context.data_access;
    observed={this,
        [](void *raw,uint32_t at,void *out,size_t size){auto &w=*static_cast<GameWriteWatch *>(raw);
            const bool ok=w.original.read(w.original.state,at,out,size);if(ok)w.observe_read(at,out,size);return ok;},
        [](void *raw,uint32_t at,const void *in,size_t size){auto &w=*static_cast<GameWriteWatch *>(raw);
            const auto before=w.before(at,size,true);const bool ok=w.original.write(w.original.state,at,in,size);
            if(ok){w.after(before,at,size,true);w.observe_write(at,in,size);}return ok;},
        [](void *raw,uint32_t at,unsigned width,uint64_t *out){auto &w=*static_cast<GameWriteWatch *>(raw);return w.original.load_exclusive(w.original.state,at,width,out);},
        [](void *raw,uint32_t at,unsigned width,uint64_t value,uint32_t *out){auto &w=*static_cast<GameWriteWatch *>(raw);
            const auto before=w.before(at,width,true,true);const auto result=w.original.store_exclusive(w.original.state,at,width,value,out);
            if(result==as6aot::Returned&&out&&!*out)w.after(before,at,width,true);return result;},
        [](void *raw){auto &w=*static_cast<GameWriteWatch *>(raw);return w.original.clear_exclusive(w.original.state);},
        [](void *raw,unsigned option){auto &w=*static_cast<GameWriteWatch *>(raw);return w.original.barrier(w.original.state,option);},
        [](void *raw,uint32_t at,unsigned width,uint64_t value,uint64_t *out){auto &w=*static_cast<GameWriteWatch *>(raw);
            const auto before=w.before(at,width,true,true);const auto result=w.original.swap(w.original.state,at,width,value,out);
            if(result==as6aot::Returned)w.after(before,at,width,true);return result;}};
    if(!original.load_exclusive)observed.load_exclusive=nullptr;
    if(!original.store_exclusive)observed.store_exclusive=nullptr;
    if(!original.clear_exclusive)observed.clear_exclusive=nullptr;
    if(!original.barrier)observed.barrier=nullptr;
    if(!original.swap)observed.swap=nullptr;
    enabled=true;context.data_access=&observed;
}

struct HostExecutionFrame;
static thread_local HostExecutionFrame *activeHostFrame;
struct HostExecutionFrame {
    __strong GuestVM *vm;
    as6aot::Context *navContext=nullptr;
    HostExecutionFrame *previous;
    bool yielded = false,finished = false;
    explicit HostExecutionFrame(GuestVM *owner):vm(owner),previous(activeHostFrame) {
        ++owner->_executionDepth;
        navContext=owner->_core?&owner->_core->state().context():nullptr;
        activeHostFrame=this;
    }
    ~HostExecutionFrame() {
        // Captured Context remains alive through the existing execution-depth
        // destruction deferral; cancelling TLS does not dereference Core.
        if(navContext){
            const bool armed=as6_nav_boundary::pending(*navContext);
            as6_nav_boundary::cancel(*navContext);
            as6_copy_boundary::cancel(*navContext);
            
            if(armed&&DiagnosticLockHeld(vm))as6_nav_vm::add(vm->_nav.clearsFrame);
        }
        // Every supported ordinary return passed Finish. Escaping C++/ObjC
        // exceptions cannot leave a replayable success/half-restored CPU.
        if(!finished){vm->_fault=true;if(DiagnosticLockHeld(vm))vm->_lastResult=GuestExecutionInvalidState;}
        // Do not reset Core here: outer GuestCall still borrows NativeState
        // for its post-emulation restore, and render wrappers restore again.
        activeHostFrame=previous;
        --vm->_executionDepth;
    }
};

@implementation GuestVM
- (void)dealloc {
    // Host frames, GuestCall and GuestBlock retain this object until every
    // borrower drains. Snapshot destruction never dereferences the VM.
    HLEPthreadForgetCPUOwner(_schedulerOwner);
}
- (instancetype)init {
    if ((self=[super init])) {
        _lock=[NSRecursiveLock new]; _trace=[NSMutableArray new];
        _traceEnabled=YES; _heapCursor=GUEST_HEAP_BASE;
        _fault=false; _halt=false; _lastResult=GuestExecutionSuccess;
    }
    return self;
}
- (BOOL)loaded { return _loaded; }
- (gva_t)entryPoint { return _core ? _core->provider().entry : 0; }
- (gva_t)textBase { return 0; }
- (gva_t)textSize { return 0; }
@end

static bool SetError(NSError **out,GuestExecutionResult code,NSString *description) {
    if (out) *out=[NSError errorWithDomain:@"AS6NativeVM" code:code
        userInfo:@{NSLocalizedDescriptionKey:description}];
    return false;
}
extern "C" __attribute__((objc_externally_retained)) as6aot::NativeState *GuestNativeCPUState(GuestVM *vm) {
    // Existing private seam contract: only return live state under this VM lock.
    return DiagnosticLockHeld(vm) && vm->_core ? &vm->_core->state() : nullptr;
}

static std::atomic<std::uint32_t> nextObjCMetadataWord{as6native::ObjCMetadataBase};
static std::uint32_t NewObjCMetadataWord() {
    auto next=nextObjCMetadataWord.load(std::memory_order_relaxed);
    while(next<as6native::ObjCMetadataEnd) {
        if(nextObjCMetadataWord.compare_exchange_weak(next,next+4,std::memory_order_relaxed))return next;
    }
    return 0; // Saturated forever; never reuse a destroyed VM's identity.
}
static const as6native::DataBinding *ObjCMetadataBinding(GuestVM *vm,gva_t slot) {
    if(!vm||!vm->_core)return nullptr;
    const auto *data=vm->_core->provider().data;
    if(!data->binding_count)return nullptr;
    std::size_t lo=0,hi=data->binding_count;
    while(lo<hi){const auto mid=lo+(hi-lo)/2;if(data->bindings[mid].address<slot)lo=mid+1;else hi=mid;}
    if(lo==data->binding_count||data->bindings[lo].address!=slot)return nullptr;
    const auto &binding=data->bindings[lo];
    return !std::strcmp(binding.symbol,"__objc_empty_vtable")?&binding:nullptr;
}
BOOL GuestObjCMetadataWord(uint32_t word){return as6native::ObjCMetadataWord(word);}
gva_t GuestObjCMetadataIdentity(GuestVM *vm){return vm&&vm->_objcMetadata?vm->_objcMetadata->word:0;}
BOOL GuestObjCMetadataUsesExport(GuestVM *vm){return vm&&vm->_objcMetadata&&vm->_objcMetadata->exported_identity;}
BOOL GuestObjCMetadataDataValue(GuestVM *vm,const char *symbol,gva_t slot,const void *nativeExport,GuestObjCSlowDispatchImpl dispatcher,uint32_t *out) {
    if(!symbol||std::strcmp(symbol,"__objc_empty_vtable"))return NO;
    if(!vm||!vm->_core||!out)return NO;
    GuestLock(vm);
    @try {
        auto reject=[&](const char *why) {GuestTrace(vm,@"[objc-metadata] %s at %#x",why,slot);GuestRequestFault(vm);return NO;};
        if(vm->_fault||vm->_halt)return NO;
        if(!vm->_objcRegistryCommitted||!dispatcher)return reject("class registry or typed native dispatcher is unavailable");
        if(!ObjCMetadataBinding(vm,slot))return reject("undeclared empty-vtable data request");
        if(!vm->_objcMetadata) {
            // Binding runs before loaded/Section availability. Use exactly the
            // existing declared-section authority and already-built registry.
            const auto *data=vm->_core->provider().data;
            const auto *section=vm->_core->declared_section("__objc_classlist");
            if(!section)return reject("empty-vtable import lacks a declared original class list");
            std::vector<as6native::LocalClassRecord> classes;std::string why;
            const bool collected=as6native::CollectLocalClasses(section->address,section->size,
                [&](uint32_t at,void *bytes,size_t length){return bool(GuestRead(vm,at,bytes,length));},
                [&](uint32_t at,size_t cap,std::string &text){NSString *value=GuestReadCString(vm,at,cap);if(!value||!value.UTF8String)return false;text=value.UTF8String;return true;},classes,why);
            if(!collected||classes.size()!=43)return reject("empty-vtable import lacks the 43 checked original classes");
            std::vector<uint32_t> permitted;
            for(const auto &record:classes) {
                NSString *name=[NSString stringWithUTF8String:record.name.c_str()];
                uint32_t metaRo=0,metaName=0;
                if(!GuestRead(vm,record.isa+16,&metaRo,4)||metaRo<4096||(metaRo&3)||!GuestRead(vm,metaRo+16,&metaName,4)||![GuestReadCString(vm,metaName,128) isEqualToString:name])return reject("metaclass metadata is unavailable or differs");
                permitted.push_back(record.address+12);permitted.push_back(record.isa+12);
            }
            std::sort(permitted.begin(),permitted.end());
            if(permitted.size()!=86||std::adjacent_find(permitted.begin(),permitted.end())!=permitted.end())return reject("class/metaclass vtable slots are not unique");
            std::vector<uint32_t> declared;
            for(std::size_t i=0;i<data->binding_count;++i) {
                const auto &binding=data->bindings[i];
                if(std::strcmp(binding.symbol,"__objc_empty_vtable"))continue;
                if(binding.kind!=as6native::BindingKind::SystemData||binding.original_word||binding.addend||binding.source_count!=1||binding.source_begin>=data->binding_source_count||!std::binary_search(permitted.begin(),permitted.end(),binding.address))return reject("empty-vtable binding is outside its exact original metadata role");
                const auto &source=data->binding_sources[binding.source_begin];
                if(source.address!=binding.address||std::strcmp(source.symbol,binding.symbol)||source.addend||source.ordinal!=19||source.flags||source.stream_kind!=1)return reject("empty-vtable binding lacks original libobjc data authority");
                declared.push_back(binding.address);
            }
            std::sort(declared.begin(),declared.end());
            if(declared!=permitted)return reject("empty-vtable bindings do not exactly cover original class and metaclass fields");
            const auto word=NewObjCMetadataWord();if(!word)return reject("typed ObjC metadata identity capacity exhausted");
            // dlsym's exported address is an identity, even for a zero-sized
            // historical array. Never read its first word or infer a table ABI.
            vm->_objcMetadata=std::make_unique<as6native::ObjCEmptyVtableIdentity>(word,nativeExport,dispatcher,std::move(declared));
            GuestTrace(vm,@"[objc-metadata] bound 86 class/meta vtable fields to typed %s identity %#x",nativeExport?"native-export":"native-slow-dispatch",word);
        }
        if(vm->_objcMetadata->slow_dispatch!=dispatcher||vm->_objcMetadata->exported_identity!=nativeExport)return reject("native metadata identity/dispatcher changed during binding");
        if(!vm->_objcMetadata->owns(slot))return reject("foreign empty-vtable slot");
        *out=vm->_objcMetadata->word;return YES;
    } @finally {GuestUnlock(vm);}
}
BOOL GuestObjCMetadataDataValid(GuestVM *vm,const char *symbol,gva_t slot,uint32_t word) {
    return vm&&vm->_core&&!vm->_fault&&!vm->_halt&&symbol&&!std::strcmp(symbol,"__objc_empty_vtable")&&
        vm->_objcMetadata&&vm->_objcMetadata->word==word&&vm->_objcMetadata->owns(slot)&&ObjCMetadataBinding(vm,slot)&&
        vm->_objcMetadata->slow_dispatch&&vm->_objcMetadata->native_identity();
}
BOOL GuestObjCMetadataDispatchReady(GuestVM *vm,gva_t originalClass,GuestObjCSlowDispatchImpl dispatcher) {
    if(!vm||!vm->_core||vm->_fault||vm->_halt){GuestRequestFault(vm);return NO;}
    // Existing fixtures/classes without this declared import keep their normal
    // method-list lookup. A new metadata tag is required only for its own role.
    if(!ObjCMetadataBinding(vm,originalClass+12))return YES;
    uint32_t word=0;
    if(!vm||!vm->_core||!vm->_loaded||!vm->_objcMetadata||vm->_objcMetadata->slow_dispatch!=dispatcher||!GuestRead(vm,originalClass+12,&word,4)||!GuestObjCMetadataDataValid(vm,"__objc_empty_vtable",originalClass+12,word)) {
        GuestRequestFault(vm);return NO;
    }
    return YES;
}
static BOOL BindDeclaredData(GuestVM *vm,NSString **failure) {
    const auto *manifest=vm->_core->provider().data;
    auto writer=vm->_core->binding_writer();
    std::vector<std::string> missing;std::string why;
    auto apply=[&](size_t index,uint32_t value) {
        if(!writer.set(index,value,why)) {
            missing.push_back(std::string(manifest->bindings[index].symbol)+": "+why);return false;
        }
        ++vm->_bindApplied;return true;
    };
    for(size_t i=0;i<manifest->binding_count;++i)
        if(manifest->bindings[i].kind==as6native::BindingKind::StaticValue)apply(i,manifest->bindings[i].static_value);
    auto resolve=[&](size_t i) {
        const auto &b=manifest->bindings[i];uint32_t value=0;BOOL resolved=NO;
        switch(b.kind) {
            case as6native::BindingKind::ObjectConstant:
                resolved=HLEObjectConstantAddress(vm,b.symbol,&value);break;
            case as6native::BindingKind::DataAddress:
                resolved=HLEDataAddress(vm,b.symbol,&value);break;
            case as6native::BindingKind::ObjCClass:
            case as6native::BindingKind::ObjCMetaclass:
            case as6native::BindingKind::SystemData:
                value=HLEDataValue(vm,b.symbol,b.address);resolved=value!=0;break;
            case as6native::BindingKind::Unavailable:
                missing.push_back(std::string(b.symbol)+": requires a typed native function adapter, cannot bind as opaque data");return;
            default:return;
        }
        if(resolved&&value) {
            uint8_t byte=0;
            if(b.kind==as6native::BindingKind::ObjectConstant||b.kind==as6native::BindingKind::DataAddress)
                resolved=GuestRead(vm,value,&byte,1);
            else resolved=GuestObjCMetadataDataValid(vm,b.symbol,b.address,value)||GuestRead(vm,value,&byte,1)||HLEUnwrapOpaque(vm,value)||
                (GuestIsHostClass(value)&&GuestObjCUnwrapClass(vm,value))||
                (GuestIsHostObject(value)&&GuestObjCUnwrap(vm,value));
        }
        if(!resolved||!value) {char text[256];std::snprintf(text,sizeof(text),"%s at %#x has no typed native data value",b.symbol,b.address);missing.emplace_back(text);return;}
        value=std::uint32_t(std::uint64_t(value)+std::uint64_t(b.addend));
        apply(i,value);
    };
    // Guest C++/constant cells need no class registry. Their native function
    // identities are already fixed in the offline bridge table.
    for(size_t i=0;i<manifest->binding_count;++i)
        if(manifest->bindings[i].kind==as6native::BindingKind::ObjectConstant||manifest->bindings[i].kind==as6native::BindingKind::DataAddress)resolve(i);
    NSString *registryFailure=nil;
    if(!GuestObjCBuildRegistryForBinding(vm,&registryFailure)) {
        if(failure)*failure=[@"Local class registry is incomplete: " stringByAppendingString:registryFailure?:@"unknown metadata error"];return NO;
    }
    vm->_objcRegistryCommitted=YES;
    for(size_t i=0;i<manifest->binding_count;++i)
        if(manifest->bindings[i].kind==as6native::BindingKind::ObjCClass||manifest->bindings[i].kind==as6native::BindingKind::ObjCMetaclass||manifest->bindings[i].kind==as6native::BindingKind::SystemData||manifest->bindings[i].kind==as6native::BindingKind::Unavailable)resolve(i);
    if(!missing.empty()) {
        NSMutableArray *names=[NSMutableArray new];
        for(size_t i=0;i<std::min<size_t>(missing.size(),24);++i)[names addObject:[NSString stringWithUTF8String:missing[i].c_str()]];
        if(failure)*failure=[NSString stringWithFormat:@"%zu unresolved data bindings: %@",missing.size(),[names componentsJoinedByString:@"; "]];return NO;
    }
    if(vm->_fault.load()||!writer.finish(why)) {
        if(failure)*failure=vm->_fault.load()?@"A data helper reported a native binding fault":[NSString stringWithUTF8String:why.c_str()];return NO;
    }
    return YES;
}
GuestVM *GuestVMCreateNative(const as6native::Provider *provider,NSError **error) {
    if (!provider) { SetError(error,GuestExecutionUnavailable,@"No linked native program provider"); return nil; }
    GuestVM *vm=[GuestVM new];
    try {
        auto core=std::make_unique<Core>(*provider);
        std::string why;
        if (!core->initialize(why)) {
            SetError(error,GuestExecutionInvalidState,[NSString stringWithUTF8String:why.c_str()]); return nil;
        }
        vm->_core=std::move(core);
        vm->_schedulerOwner=vm->_core->state().save().owner;
        if(as6_nav_vm::isLinkedProvider(provider)){
            vm->_navWorkspace.emplace();vm->_navWorkspaceOwner=vm->_schedulerOwner;
        }
        NSString *bindingFailure=nil;
        if(!BindDeclaredData(vm,&bindingFailure)) {
            SetError(error,GuestExecutionUnavailable,bindingFailure?:@"Native data binding is incomplete");return nil;
        }
        vm->_loaded=YES;
        // Normal execution keeps the checked AtomicAccess backend directly.
        const char *memoryDiagnostics=getenv("AS6_NATIVE_MEMORY_DIAGNOSTICS");
        if(memoryDiagnostics && !std::strcmp(memoryDiagnostics,"1"))
            vm->_gameWriteWatch.install(vm);
        return vm;
    } catch (const std::bad_alloc &) {
        SetError(error,GuestExecutionResourceLimit,@"Native data storage allocation failed"); return nil;
    }
}
GuestVM *GuestVMCreate(NSError **error) { return GuestVMCreateNative(AS6LinkedNativeProvider(),error); }
BOOL GuestVMLoadMachO(GuestVM *,NSString *,NSError **error) {
    return SetError(error,GuestExecutionUnsupportedSemantics,@"Native builds require a linked ARM64 program and a data-only manifest; loading the old executable is disabled");
}
// Optional native input bridge; Mac-only core test links do not load UIKit.
extern void GuestMotionForgetVM(GuestVM *) __attribute__((weak_import));
void GuestVMDestroy(GuestVM *vm) {
    if (!vm) return;
    GuestLock(vm);
    @try {
        if(vm->_core){auto &c=vm->_core->state().context();if(as6_nav_boundary::pending(c))as6_nav_vm::add(vm->_nav.clearsDestroy);as6_nav_boundary::cancel(c);as6_copy_boundary::cancel(c);}
        vm->_fault=true; vm->_loaded=NO; vm->_objcRegistryCommitted=NO; vm->_lastResult=GuestExecutionUnavailable;
        if(GuestMotionForgetVM)GuestMotionForgetVM(vm);
        if(AS6OriginalUIForgetVM)AS6OriginalUIForgetVM(vm);
        if(!vm->_nativeDepth)AS6SystemZlibForgetVM(vm);
#if !defined(AS6_NATIVE_MUSIC_ABSENCE_FIXTURE)
        AS6NativeMusicForgetVM(vm);
#endif
        // A blocking bridge may temporarily release the VM lock while its
        // execution frame still borrows Core. Invalidate immediately and defer
        // storage release until all such callers have drained.
        if (!vm->_executionDepth&&!vm->_blockingDepth) {
            HLEPthreadForgetCPUOwner(vm->_schedulerOwner);
            vm->_navWorkspace.reset();vm->_navWorkspaceOwner=0;
            vm->_core.reset();vm->_schedulerOwner=0;
        }
        if (GuestVMShared()==vm) GuestVMSetShared(nil);
    } @finally { GuestUnlock(vm); }
}
extern "C" GuestExecutionResult GuestLastExecutionResultLocked(GuestVM *vm) {
    if (!vm) return GuestExecutionInvalidArgument;
    if (!DiagnosticLockHeld(vm)) return GuestExecutionInvalidState;
    GuestExecutionResult result;
        result=vm->_lastResult;
        // Native callbacks can latch failure outside an execution frame.
        // Expose that failure immediately without racing an unlocked write to
        // _lastResult or replacing a precise execution error with a generic one.
        if(result==GuestExecutionSuccess||result==GuestExecutionYielded) {
            if(vm->_fault.load(std::memory_order_acquire))result=GuestExecutionInvalidState;
            else if(vm->_halt.load(std::memory_order_acquire))result=GuestExecutionHalted;
        }
    return result;
}
GuestExecutionResult GuestLastExecutionResult(GuestVM *vm) {
    if (!vm) return GuestExecutionInvalidArgument;
    GuestLock(vm);
    @try { return GuestLastExecutionResultLocked(vm); }
    @finally { GuestUnlock(vm); }
}
BOOL GuestHasStopRequest(GuestVM *vm) {
    return !vm||vm->_fault.load(std::memory_order_acquire)||vm->_halt.load(std::memory_order_acquire);
}

static BOOL RejectObjCMetadataMemory(GuestVM *vm) {
    if(vm){GuestLock(vm);@try{vm->_fault=true;vm->_lastResult=GuestExecutionMemoryFault;}@finally{GuestUnlock(vm);}}
    return NO;
}
// Hot accessors: every caller passes a VM it keeps alive, so the parameter
// needs no retain/release of its own.
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to=function)
BOOL GuestRead(GuestVM *vm,gva_t at,void *out,size_t size) {
    if(as6native::ObjCMetadataOverlap(at,size))return RejectObjCMetadataMemory(vm);
    return vm && vm->_core && out && size && Core::range(at,size) && vm->_core->read(at,out,size);
}
BOOL GuestWrite(GuestVM *vm,gva_t at,const void *in,size_t size) {
    if(as6native::ObjCMetadataOverlap(at,size))return RejectObjCMetadataMemory(vm);
    if(!vm||!vm->_core||!in||!size||!Core::range(at,size))return NO;
    const auto before=vm->_gameWriteWatch.before(at,size,false);
    const bool ok=vm->_core->write(at,in,size);
    if(ok)vm->_gameWriteWatch.after(before,at,size,false);
    return ok;
}
BOOL GuestFill(GuestVM *vm,gva_t at,size_t size) {
    if(as6native::ObjCMetadataOverlap(at,size))return RejectObjCMetadataMemory(vm);
    if (!vm || !vm->_core || !vm->_core->ensure_dynamic(at,size)) return NO;
    const std::uint8_t zero[4096]{};
    for (size_t offset=0;offset<size;) {
        const auto count=std::min<size_t>(sizeof(zero),size-offset);
        if (!GuestWrite(vm,at+std::uint32_t(offset),zero,count)) return NO;
        offset+=count;
    }
    return YES;
}
gva_t GuestAlloc(GuestVM *vm,size_t size) {
    if (!vm || !vm->_core || !size || size>GUEST_HEAP_SIZE) return 0;
    const std::uint64_t aligned=(std::uint64_t(size)+15)&~15ULL;
    const auto at=vm->_heapCursor;
    if (std::uint64_t(at)+aligned>std::uint64_t(GUEST_HEAP_BASE)+GUEST_HEAP_SIZE ||
        !vm->_core->ensure_dynamic(at,size_t(aligned))) return 0;
    vm->_heapCursor+=std::uint32_t(aligned);
    return at;
}
gva_t GuestHLEAddress(GuestVM *vm,const char *symbol) {
    if (!vm || !vm->_core) return 0;
    const auto *bridge=vm->_core->bridge(symbol);
    return bridge ? bridge->original_address|std::uint32_t(bridge->thumb) : 0;
}
uint32_t GuestReadU32(GuestVM *vm,gva_t at) {
    uint32_t out=0;
    if (!GuestRead(vm,at,&out,4) && vm) {
        GuestTrace(vm,@"[native] bridge word read failed at %#x (original pc=%#x)",at,GuestPC(vm));
        vm->_fault=true; vm->_lastResult=GuestExecutionMemoryFault;
    }
    return out;
}
void GuestWriteU32(GuestVM *vm,gva_t at,uint32_t value) {
    if (!GuestWrite(vm,at,&value,4) && vm) {
        GuestTrace(vm,@"[native] bridge word write failed at %#x (original pc=%#x)",at,GuestPC(vm));
        vm->_fault=true; vm->_lastResult=GuestExecutionMemoryFault;
    }
}
#pragma clang attribute pop
size_t GuestStrLen(GuestVM *vm,gva_t at,size_t cap) {
    if (!vm || !at) return 0;
    cap=std::min<std::uint64_t>(cap,0x100000000ULL-at);
    uint8_t bytes[256];
    for (size_t offset=0;offset<cap;) {
        const auto count=std::min<size_t>(sizeof(bytes),cap-offset);
        if (!GuestRead(vm,at+std::uint32_t(offset),bytes,count)) {
            for (size_t i=0;i<count;++i) {
                uint8_t value;
                if (!GuestRead(vm,at+std::uint32_t(offset+i),&value,1)||!value) return offset+i;
            }
        } else for (size_t i=0;i<count;++i) if (!bytes[i]) return offset+i;
        offset+=count;
    }
    return cap;
}
NSString *GuestReadCString(GuestVM *vm,gva_t at,size_t maxLen) {
    if (!vm || !at || !maxLen) return nil;
    // Host strings are deliberately bounded independently of a guest length.
    const auto length=GuestStrLen(vm,at,std::min<size_t>(maxLen,1u<<20));
    std::vector<char> bytes(length+1,0);
    if (length&&!GuestRead(vm,at,bytes.data(),length)) return nil;
    uint8_t terminator=1;
    if (std::uint64_t(at)+length>=0x100000000ULL ||
        !GuestRead(vm,at+std::uint32_t(length),&terminator,1)||terminator) return nil;
    return [[NSString alloc] initWithBytes:bytes.data() length:length encoding:NSUTF8StringEncoding] ?:
           [[NSString alloc] initWithBytes:bytes.data() length:length encoding:NSISOLatin1StringEncoding];
}
gva_t GuestWriteCString(GuestVM *vm,NSString *s) {
    if (!s) return 0;
    const char *p=s.UTF8String;
    if (!p) return 0;
    const size_t size=std::strlen(p)+1;
    const auto at=GuestAlloc(vm,size);
    return at&&GuestWrite(vm,at,p,size)?at:0;
}
size_t GuestStrCopy(GuestVM *vm,gva_t dst,gva_t src,size_t cap) {
    const auto length=GuestStrLen(vm,src,cap);
    if (length>=cap || std::uint64_t(src)+length>=0x100000000ULL ||
        !Core::range(dst,length+1)) return size_t(-1);
    uint8_t terminator=1;
    if (!GuestRead(vm,src+uint32_t(length),&terminator,1)||terminator) return size_t(-1);
    try {
        std::vector<uint8_t> bytes(length+1);
        return GuestRead(vm,src,bytes.data(),bytes.size())&&GuestWrite(vm,dst,bytes.data(),bytes.size())?bytes.size():size_t(-1);
    } catch (const std::bad_alloc &) { return size_t(-1); }
}

#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to=function)
uint32_t GuestReg(GuestVM *vm,int index) {
    auto *state=GuestNativeCPUState(vm); uint32_t value=0;
    if (state&&index>=0) state->get_register(unsigned(index),value);
    return value;
}
void GuestSetReg(GuestVM *vm,int index,uint32_t value) {
    auto *state=GuestNativeCPUState(vm);
    if (state&&index>=0) state->set_register(unsigned(index),value);
}
uint32_t GuestPC(GuestVM *vm) { return GuestReg(vm,15); }
uint32_t GuestSP(GuestVM *vm) { return GuestReg(vm,13); }
uint32_t GuestLR(GuestVM *vm) { return GuestReg(vm,14); }
void GuestSetPC(GuestVM *vm,uint32_t encoded) {
    auto *state=GuestNativeCPUState(vm);
    if (!state) return;
    state->set_cpsr((state->cpsr()&~0x20u)|((encoded&1u)<<5));
    state->set_register(15,encoded&~1u);
}
float GuestRegS0(GuestVM *vm) {
    uint32_t bits=0; float value;
    if (auto *state=GuestNativeCPUState(vm)) state->get_s(0,bits);
    std::memcpy(&value,&bits,4); return value;
}
double GuestRegD0(GuestVM *vm) {
    uint64_t bits=0; double value;
    if (auto *state=GuestNativeCPUState(vm)) state->get_d(0,bits);
    std::memcpy(&value,&bits,8); return value;
}
void GuestSetRegS0(GuestVM *vm,float value) {
    uint32_t bits; std::memcpy(&bits,&value,4);
    if (auto *state=GuestNativeCPUState(vm)) state->set_s(0,bits);
}
void GuestSetRegD0(GuestVM *vm,double value) {
    uint64_t bits; std::memcpy(&bits,&value,8);
    if (auto *state=GuestNativeCPUState(vm)) state->set_d(0,bits);
}
uint32_t GuestArg(GuestVM *vm,int index) {
    if (index<0 || index>4095) return 0;
    if (index<4) return GuestReg(vm,index);
    const auto at=std::uint64_t(GuestSP(vm))+4u*(unsigned(index)-4u);
    return at<=UINT32_MAX?GuestReadU32(vm,uint32_t(at)):0;
}
float GuestArgF(GuestVM *vm,int index) { auto bits=GuestArg(vm,index); float value; std::memcpy(&value,&bits,4); return value; }
double GuestArgD(GuestVM *vm,int index) {
    if (index<0 || index>2047) return 0;
    uint64_t bits=GuestArg(vm,index*2)|(uint64_t(GuestArg(vm,index*2+1))<<32);
    double value; std::memcpy(&value,&bits,8); return value;
}
void GuestSetRet(GuestVM *vm,uint32_t value) { GuestSetReg(vm,0,value); }
void GuestSetRetF(GuestVM *vm,float value) { uint32_t bits; std::memcpy(&bits,&value,4); GuestSetRet(vm,bits); }
void GuestSetRetD(GuestVM *vm,double value) { uint64_t bits; std::memcpy(&bits,&value,8); GuestSetReg(vm,0,uint32_t(bits)); GuestSetReg(vm,1,uint32_t(bits>>32)); }
void GuestReturn(GuestVM *vm) { GuestSetPC(vm,GuestLR(vm)); }
#pragma clang attribute pop

static std::uintptr_t Key(GuestVM *vm) { return reinterpret_cast<std::uintptr_t>((__bridge void *)vm); }
// Guest threads keep the VM lock while they run and give it up only in
// blocking calls; NSRecursiveLock is not fair. The main thread announces that
// it is waiting so busy guest threads can hand it the lock (see
// MainThreadSchedulingBoundary), keeping frames and input inside the watchdog.
static std::atomic<unsigned> mainLockWaiters{0};
static std::atomic<uint64_t> mainLockAcquisitions{0};
void GuestLock(GuestVM *vm) {
    if (!vm) return;
    if (pthread_main_np()) {
        mainLockWaiters.fetch_add(1,std::memory_order_relaxed);
        [vm->_lock lock];
        mainLockWaiters.fetch_sub(1,std::memory_order_relaxed);
        mainLockAcquisitions.fetch_add(1,std::memory_order_release);
    } else [vm->_lock lock];
    ++lockDepth[Key(vm)]; vm->_lockOwner.store(pthread_self(),std::memory_order_relaxed); HLEPthreadTakeCPU(vm);
}
BOOL GuestTryLock(GuestVM *vm) {
    if (!vm||![vm->_lock tryLock]) return NO;
    ++lockDepth[Key(vm)]; vm->_lockOwner.store(pthread_self(),std::memory_order_relaxed); HLEPthreadTakeCPU(vm); return YES;
}
void GuestUnlock(GuestVM *vm) {
    if (!vm) return;
    auto found=lockDepth.find(Key(vm));
    if (found==lockDepth.end()||!found->second) { GuestRequestFault(vm); return; }
    if (!--found->second) { lockDepth.erase(found); vm->_lockOwner.store(nullptr,std::memory_order_relaxed); }
    [vm->_lock unlock];
}
NSUInteger GuestSuspendLocks(GuestVM *vm) {
    auto found=lockDepth.find(Key(vm));
    const auto depth=found==lockDepth.end()?0:found->second;
    // Compiled native execution must have returned before scheduling any HLE.
    if (vm&&vm->_nativeDepth) { GuestRequestFault(vm); return 0; }
    // An original-entry retry is synchronous; no token crosses a CPU snapshot
    // handoff. This point still holds the exact VM lock and has no native lease.
    if(depth&&vm&&vm->_core){auto &c=vm->_core->state().context();if(as6_nav_boundary::pending(c))as6_nav_vm::add(vm->_nav.clearsHandoff);as6_nav_boundary::cancel(c);as6_copy_boundary::cancel(c);}
    for (NSUInteger i=0;i<depth;++i) GuestUnlock(vm);
    return depth;
}
void GuestResumeLocks(GuestVM *vm,NSUInteger depth) { for (NSUInteger i=0;i<depth;++i) GuestLock(vm); }
#if defined(AS6_NAV_VM_FIXTURE)
extern "C" size_t AS6NavWorkspaceCapacityForFixtureLocked(GuestVM *vm) {
    return DiagnosticLockHeld(vm)&&vm->_navWorkspace?vm->_navWorkspace->capacity():0;
}
extern "C" uint64_t AS6NavWorkspaceOwnerForFixtureLocked(GuestVM *vm) {
    return DiagnosticLockHeld(vm)?vm->_navWorkspaceOwner:0;
}
extern "C" size_t AS6SchedulerBlockingDepthForFixtureLocked(GuestVM *vm) {
    return DiagnosticLockHeld(vm)?vm->_blockingDepth:SIZE_MAX;
}
extern "C" size_t AS6SchedulerLockDepthForFixtureLocked(GuestVM *vm) {
    if(!DiagnosticLockHeld(vm))return 0;return lockDepth[Key(vm)];
}
#endif
extern "C" uint64_t GuestSchedulerOwnerLocked(GuestVM *vm) {
    return DiagnosticLockHeld(vm)&&vm->_core?vm->_schedulerOwner:0;
}
extern "C" GuestExecutionResult GuestSchedulerCanBlockLocked(GuestVM *vm) {
    // Lock validity is checked before reading unique Core or mutable depths.
    if(!DiagnosticLockHeld(vm))return GuestExecutionInvalidState;
    if(!vm->_core||!vm->_schedulerOwner)return GuestExecutionUnavailable;
    if(vm->_nativeDepth||vm->_blockingDepth==SIZE_MAX)return GuestExecutionInvalidState;
    if(vm->_fault)return GuestExecutionInvalidState;
    if(vm->_halt)return GuestExecutionHalted;
    return GuestExecutionSuccess;
}
extern "C" int GuestSchedulerBorrowBeginLocked(GuestVM *vm,uint64_t owner) {
    if(!owner||GuestSchedulerCanBlockLocked(vm)!=GuestExecutionSuccess||GuestSchedulerOwnerLocked(vm)!=owner)return 0;
    ++vm->_blockingDepth;return 1;
}
extern "C" void GuestSchedulerBorrowEndLocked(GuestVM *vm,uint64_t owner) {
    if(!DiagnosticLockHeld(vm)){GuestRequestFault(vm);return;}
    if(!vm->_blockingDepth){GuestRequestFault(vm);return;}
    if(!owner||GuestSchedulerOwnerLocked(vm)!=owner)GuestRequestFault(vm);
    --vm->_blockingDepth;
    // Caller CPU borrowers can still exist after the activation. Like Host
    // frames, draining this counter must not eagerly reset deferred Core.
}
extern "C" void GuestSchedulerResumeLocks(GuestVM *vm,size_t depth) {
    if(!vm)return;
    // Reacquire the exact recursive lock levels before checking the captured
    // CPU owner. GuestLock would automatically switch/create a schedule first.
    for(size_t i=0;i<depth;++i){[vm->_lock lock];++lockDepth[Key(vm)];vm->_lockOwner.store(pthread_self(),std::memory_order_relaxed);}
}

void GuestRegisterStack(GuestVM *vm,gva_t base,uint32_t size) {
    if (vm&&size&&Core::range(base,size)) vm->_stacks.emplace_back(base,std::uint64_t(base)+size);
}
BOOL GuestStackContains(GuestVM *vm,gva_t sp,uint32_t headroom) {
    if (!vm) return NO;
    if (std::uint64_t(GUEST_STACK_TOP-GUEST_STACK_SIZE)+headroom<=sp&&sp<GUEST_STACK_TOP) return YES;
    for (const auto &r:vm->_stacks) if (std::uint64_t(r.first)+headroom<=sp&&sp<r.second) return YES;
    return NO;
}
static GuestVM *sharedVM;
GuestVM *GuestVMShared(void) { return sharedVM; }
void GuestVMSetShared(GuestVM *vm) { sharedVM=vm; }

static void Boundary(GuestVM *vm) {
    // Only GuestEmulate calls this, with the VM lock held and Core loaded.
    const auto &state=vm->_core->state();
    uint32_t pc=0,sp=0;state.get_register(15,pc);state.get_register(13,sp);
    vm->_recentPC[vm->_recentCount++%64]=pc;
    recentSP[recentSPCount++%64]=sp;
}
static void CaptureNativeFailure(GuestVM *vm,as6aot::Status result) {
    if (result==as6aot::BudgetExhausted || vm->_firstNativeFailure) return;
    const auto &state=vm->_core->state(); const auto &ctx=state.context();
    NSMutableArray<NSNumber *> *registers=[NSMutableArray arrayWithCapacity:16];
    for (unsigned i=0;i<16;++i) [registers addObject:@(GuestReg(vm,i))];
    vm->_firstNativeFailure=@{@"native_status":@(unsigned(result)),@"pc":@(ctx.next_pc),
        @"thumb":@(ctx.isa_thumb),@"fault_address":@(ctx.fault_address),
        @"remaining_budget":@(ctx.budget),@"cpsr":@(state.cpsr()),@"registers":registers};
}
// The VM stays alive through every caller's HostExecutionFrame (a strong
// reference), so these per-import steps take it unretained.
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to=function)
static GuestExecutionResult Finish(GuestVM *vm,GuestExecutionResult result) {
    if(activeHostFrame&&activeHostFrame->vm==vm)activeHostFrame->finished=true;
    // Invalid/unlocked API calls never dereference Core for Nav cleanup.
    if(DiagnosticLockHeld(vm)&&vm->_core){auto &c=vm->_core->state().context();if(as6_nav_boundary::pending(c))as6_nav_vm::add(vm->_nav.clearsFinish);as6_nav_boundary::cancel(c);as6_copy_boundary::cancel(c);}
    if(vm&&vm->_core) {
        as6_original_ui::cancel(vm->_core->state().context());
        as6_music_boundary::cancel(vm->_core->state().context());
#if !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE) || defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
        as6_collision_boundary::cancel(vm->_core->state().context());
        as6_collision36_boundary::cancel(vm->_core->state().context());
        as6_vertex_boundary::cancel(vm->_core->state().context());
        as6_trail_boundary::cancel(vm->_core->state().context());
#endif
    }
    vm->_lastResult=result;
    if (result!=GuestExecutionSuccess&&result!=GuestExecutionBudgetExhausted&&
        result!=GuestExecutionHalted&&result!=GuestExecutionYielded&&result!=GuestExecutionCancelled)
        vm->_fault=true;
    return result;
}
static void AudioSchedulingBoundary(GuestVM *vm) {
    // NativeProgram has returned. The existing thread scheduler saves the
    // current CPU and releases every recursive lock level during the handoff.
    if(!GuestAudioProducerNeedsService())return;
    const int savedErrno=errno;
    static thread_local std::chrono::steady_clock::time_point last{};
    const auto now=std::chrono::steady_clock::now();
    if(last.time_since_epoch().count() && now-last<std::chrono::milliseconds(2)){
        errno=savedErrno;return;
    }
    last=now;++vm->_schedulerYields;
    HLEPthreadBlockingCall(vm,[](void *){return GuestAudioWaitForProducerTurn();},nullptr);
    errno=savedErrno;
}
static void MainThreadSchedulingBoundary(GuestVM *vm) {
    // Same handoff as the audio boundary: native execution has returned and
    // the scheduler saves this CPU while every recursive lock level is free.
    if(pthread_main_np()||!mainLockWaiters.load(std::memory_order_relaxed))return;
    if(!HLEPthreadCanYieldLocked(vm))return;
    const int savedErrno=errno;
    ++vm->_mainThreadYields;
    uint64_t seen=mainLockAcquisitions.load(std::memory_order_acquire);
    HLEPthreadBlockingCall(vm,[](void *raw) {
        // Let the waiting main thread take the lock first; bounded at ~10 ms.
        const auto seen=*static_cast<uint64_t *>(raw);
        for(int i=0;i<200&&mainLockWaiters.load(std::memory_order_relaxed)&&
            mainLockAcquisitions.load(std::memory_order_acquire)==seen;++i)usleep(50);
        return 0;
    },&seen);
    errno=savedErrno;
}
#pragma clang attribute pop
// AS6_DIRECT_MEMORY=0 keeps every native load/store on the DataAccess
// callback, for comparing against the direct page view in one build.
static bool DirectMemoryEnabled() {
    static const bool enabled=[]{
        const char *value=getenv("AS6_DIRECT_MEMORY");
        return !(value&&!strcmp(value,"0"));
    }();
    return enabled;
}
__attribute__((objc_externally_retained)) GuestExecutionResult GuestEmulate(GuestVM *vm,gva_t begin,gva_t until,uint64_t maxInsns) {
    if (!vm) return GuestExecutionUnavailable;
    // Caller-must-lock API: never inspect the unique Core or invoke Finish
    // from an unlocked caller racing GuestVMDestroy.
    if(lockDepth.find(Key(vm))==lockDepth.end()){GuestRequestFault(vm);return GuestExecutionInvalidState;}
    if(!vm->_core||!vm->_loaded)return Finish(vm,GuestExecutionUnavailable);
    if(vm->_nativeDepth)return Finish(vm,GuestExecutionInvalidState);
    if (vm->_fault) return Finish(vm,GuestExecutionInvalidState);
    if (vm->_halt) return Finish(vm,GuestExecutionHalted);
    if(as6native::ObjCMetadataWord(begin&~1u))return Finish(vm,GuestExecutionUnresolvedTarget);
    HostExecutionFrame frame(vm);
    auto &core=*vm->_core;
    auto &state=core.state(); auto &ctx=state.context();
    const bool stopThumb=until&1u;
    const uint32_t stop=until&~1u;
    const uint32_t first=begin&~1u;
    // An odd begin explicitly selects Thumb; an even begin follows CPSR,
    // matching callers that set CPSR before supplying a canonical identity.
    if (begin&1u) state.set_cpsr(state.cpsr()|0x20u);
    if ((first&(ctx.isa_thumb?1u:3u))||(stop&(stopThumb?1u:3u))) return Finish(vm,GuestExecutionInvalidArgument);
    state.set_register(15,first);
    ctx.status=as6aot::Returned; ctx.fault_address=0;
    uint64_t remaining=maxInsns?maxInsns:std::numeric_limits<uint64_t>::max();
    const bool uiAuthorized=as6_nav_vm::isLinkedProvider(&core.provider())&&core.nav_context_data_is_owned();
    bool extendedVertexAllowed=true;
    for (;;) {
        if(vm->_fault)return Finish(vm,GuestExecutionInvalidState);
        if(vm->_halt)return Finish(vm,GuestExecutionHalted);
        const uint64_t sliceBudget=std::min<uint64_t>(remaining,8192);
        ctx.budget=sliceBudget; Boundary(vm);
        ++vm->_nativeSlices;
        as6aot::Status result;
        {
            // One serialized memory transaction per bounded native slice,
            // instead of re-locking for every original load/store. Release it
            // before adapters, host callbacks or audio/thread handoffs.
            auto lease=core.native_execution_lease();
            if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
            // Ordinary loads/stores bypass the callback only while this lease
            // serializes the storage, and never around an observing DataAccess.
            struct DirectView {
                as6aot::Context &ctx;
                DirectView(as6aot::Context &c,const as6aot::DirectMemory *direct):ctx(c){ctx.direct=direct;}
                ~DirectView(){ctx.direct=nullptr;}
            } directView(ctx,DirectMemoryEnabled()&&core.nav_context_data_is_owned()?core.native_direct_memory():nullptr);
            struct NativeDepth {
                __unsafe_unretained GuestVM *vm;
                explicit NativeDepth(GuestVM *owner):vm(owner){++vm->_nativeDepth;}
                ~NativeDepth(){--vm->_nativeDepth;}
            } depth(vm);
            const as6_ui_append::Storage uiStorage{
                &core,
                [](void *o,std::uint32_t a,void *out,std::size_t n){return static_cast<Core*>(o)->read(a,out,n);},
                [](void *o,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t n){return static_cast<Core*>(o)->write_batch(spans,n);}
            };
            as6_ui_work_boundary::DirectScope uiScope(ctx,uiStorage,uiAuthorized);
            as6_scene_boundary::DirectScope sceneScope(core,uiAuthorized);
            as6_collision_inverse_boundary::DirectScope inverseScope(core,uiAuthorized);
            result=core.provider().program->execute(ctx,stop,uint32_t(stopThumb));
            vm->_collisionInverseAttempts+=inverseScope.attempts;vm->_collisionInverseHandled+=inverseScope.handled;
            vm->_collisionInverseDeclined+=inverseScope.declined;vm->_collisionInverseInstructions+=inverseScope.instructions;
            vm->_sceneAttempts+=sceneScope.attempts;vm->_sceneHandled+=sceneScope.handled;
            vm->_sceneDeclined+=sceneScope.declined;vm->_sceneInstructions+=sceneScope.instructions;
            vm->_uiWorkAttempts+=uiScope.attempts;vm->_uiWorkHandled+=uiScope.handled;
            vm->_uiWorkDeclined+=uiScope.declined;vm->_uiWorkInstructions+=uiScope.instructions;
        }
#if defined(AS6_UI_WORK_VM_FIXTURE)
        AS6UIWorkVMObserveBoundaryForFixture(vm,0);
#endif
        if(ctx.budget>sliceBudget)return Finish(vm,GuestExecutionInvalidState);
        const auto sliceRemaining=ctx.budget;
        remaining-=sliceBudget-sliceRemaining;
        ctx.budget=remaining; Boundary(vm);
        if(result==as6aot::BudgetExhausted && !sliceRemaining && remaining){
            // An internal scheduling slice is resumable. The caller's total
            // budget and all architectural/data effects remain authoritative.
            ctx.status=as6aot::Returned;
            AudioSchedulingBoundary(vm);
            MainThreadSchedulingBoundary(vm);
            if(vm->_fault)return Finish(vm,GuestExecutionInvalidState);
            if(vm->_halt)return Finish(vm,GuestExecutionHalted);
            continue;
        }
        if (result==as6aot::Returned) {
            if (ctx.next_pc!=stop||ctx.isa_thumb!=stopThumb) return Finish(vm,GuestExecutionInvalidState);
            return Finish(vm,GuestExecutionSuccess);
        }
        if (result!=as6aot::UnresolvedTarget) {
            CaptureNativeFailure(vm,result);
            GuestTrace(vm,@"[native] execution stopped status=%u pc=%#x mode=%u fault=%#x budget=%llu",
                       unsigned(result),ctx.next_pc,unsigned(ctx.isa_thumb),ctx.fault_address,
                       (unsigned long long)ctx.budget);
            return Finish(vm,GuestNativeExecutionResult(result));
        }
        const bool navBoundary=as6_nav_boundary::isBoundary(ctx);
        const bool navAuthorized=as6_nav_vm::isLinkedProvider(&core.provider());
        if(navBoundary&&!navAuthorized)as6_nav_vm::add(vm->_nav.providerDeclines);
        // An unknown provider may have no original hook to consume a retry.
        // Only the immutable linked provider can enter either query or arm;
        // every other Unresolved target follows the ordinary bridge path.
        if(navBoundary&&navAuthorized) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            as6_large_nav::Result decision;
            {
                // Existing HostExecutionFrame retains this real VM/Core and
                // the caller owns its real NSRecursiveLock. No Host callback
                // runs while this real data lease or the adapter lease lives.
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                vm->_nav.observe(core,ctx);
                if(!vm->_navWorkspace||vm->_navWorkspaceOwner!=vm->_schedulerOwner){
                    as6_nav_vm::add(vm->_nav.workspaceDeclines);
                    decision.reason=as6_large_nav::Reason::WorkspaceUnavailable;
                }else{
                    // ctx.budget already holds the total after this slice's
                    // debit. The whole atomic leaf may exceed the8192 quantum.
                    decision=as6_large_nav::query(core,ctx,*vm->_navWorkspace,remaining,stop,stopThumb);
                }
            }
            vm->_nav.finish(decision);
            if(decision.decision==as6_large_nav::Decision::Handled) {
                // query already debited the exact original instruction count
                // from the total remainder. Never debit it a second time.
                remaining=ctx.budget;ctx.status=as6aot::Returned;
#if defined(AS6_NAV_VM_FIXTURE)
                AS6NavVMObserveBoundaryForFixture(vm,1);
#endif
                AudioSchedulingBoundary(vm);
            } else {
                if(!as6_nav_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
                ctx.status=as6aot::Returned;
#if defined(AS6_NAV_VM_FIXTURE)
                AS6NavVMObserveBoundaryForFixture(vm,0);
#endif
                // No production callback, CPU restore or lock handoff occurs
                // before the next original native execute consumes this latch.
            }
            continue;
        }
#if !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE) || defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
        if(as6_trail_boundary::isBoundary(ctx)) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            ++vm->_trailAttempts;
            const as6_trail::Storage storage{
                &core,
                [](void *owner,std::uint32_t at,void *out,std::size_t length) {
                    return static_cast<Core *>(owner)->read(at,out,length);
                },
                [](void *owner,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t count) {
                    const bool published=static_cast<Core *>(owner)->write_batch(spans,count);
#if defined(AS6_NATIVE_KERNEL_INTEGRATION_FIXTURE)
                    if(published)AS6NativeTrailObserveWritesForFixture(owner,spans,count);
#endif
                    return published;
                }
            };
            as6_trail::Result decision;
            {
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                decision=as6_trail::update(storage,GuestReg(vm,0),GuestSP(vm),state.fpscr());
            }
            ++vm->_trailReasons[unsigned(decision.reason)];
            ++vm->_trailKernelStatuses[unsigned(decision.kernelStatus)];
            vm->_trailIndexReadBytes+=decision.indexBytesRead;
            if(decision.decision==as6_trail::Decision::Handled) {
                ++vm->_trailHandled;
                if(!decision.publicationSpans)++vm->_trailEmpty;
                vm->_trailVertexWriteBytes+=decision.vertexBytesWritten;
                vm->_trailIndexWriteBytes+=decision.indexBytesWritten;
                vm->_trailStateWriteBytes+=decision.stateBytesWritten;
                --remaining;ctx.budget=remaining;
                auto fpscr=state.fpscr()|decision.floatingPoint.exceptionBits;
                if(decision.floatingPoint.compared)
                    fpscr=(fpscr&0x0fffffffu)|decision.floatingPoint.nzcv;
                state.set_fpscr(fpscr);
                GuestReturn(vm);ctx.status=as6aot::Returned;
                AudioSchedulingBoundary(vm);
            } else {
                if(!as6_trail_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
                ctx.status=as6aot::Returned;
            }
            continue;
        }
        // navAuthorized identifies the final immutable linked provider, whose
        // validated assembly includes withCopies. Never arm an unknown provider.
        if(as6_copy_boundary::isBoundary(ctx)&&navAuthorized) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            ++vm->_copyAttempts;
            const as6_copy_unit::Storage storage{
                &core,
                [](void *owner,std::uint32_t at,void *out,std::size_t length) {
                    return static_cast<Core *>(owner)->read(at,out,length);
                },
                [](void *owner,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t count) {
                    return static_cast<Core *>(owner)->write_batch(spans,count);
                }
            };
            as6_copy_unit::Result decision;
            {
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                decision=as6_copy_unit::copy(storage,ctx,remaining,stop,stopThumb);
            }
            if(decision.handled) {
                ++vm->_copyHandled;vm->_copyRecords+=decision.records;
                vm->_copyInstructions+=decision.instructions;
                remaining=ctx.budget;
                AudioSchedulingBoundary(vm);
            } else {
                ++vm->_copyDeclined;
                if(!as6_copy_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
                ctx.status=as6aot::Returned;
                // Immediate original replay, without callback or lock handoff.
            }
#if defined(AS6_COPY_VM_FIXTURE)
            AS6CopyVMObserveBoundaryForFixture(vm,decision.handled?1:0);
#endif
            continue;
        }
        if(as6_vertex_boundary::isBoundary(ctx)) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            ++vm->_vertexAttempts;
            const as6_vertex::Storage storage{
                &core,
                [](void *owner,std::uint32_t at,void *out,std::size_t length) {
                    return static_cast<Core *>(owner)->read(at,out,length);
                },
                [](void *owner,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t count) {
                    return static_cast<Core *>(owner)->write_batch(spans,count);
                }
            };
            as6_vertex::Result decision;
            {
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                as6hostdata::ArmAtomicMemory::Snapshot monitor;
                const bool allowExtended=extendedVertexAllowed&&navAuthorized&&core.nav_context_data_is_owned()&&
                    core.nav_monitor_snapshot(monitor)&&!monitor.active&&ctx.status==as6aot::UnresolvedTarget&&!ctx.fault_address;
                decision=as6_vertex::transform(storage,ctx,sliceRemaining,stop,stopThumb,allowExtended);
            }
            if(decision.extendedBatch&&decision.decision!=as6_vertex::Decision::Handled)extendedVertexAllowed=false;
            vm->_vertexBackgroundTasks+=decision.backgroundTasks;
            if(decision.extendedBatch)++vm->_vertexExtended;
            if(decision.parallelReplayed)++vm->_vertexParallelReplays;
            ++vm->_vertexReasons[unsigned(decision.reason)];
            ++vm->_vertexKernelStatuses[unsigned(decision.kernelStatus)];
            if(decision.decision==as6_vertex::Decision::Handled) {
                ++vm->_vertexHandled;vm->_vertexVertices+=decision.vertices;
                vm->_vertexVectorized+=decision.vectorizedVertices;
                if(decision.parallelUsed)++vm->_vertexParallel;
                vm->_vertexSourceBytes+=decision.sourceBytes;vm->_vertexOutputBytes+=decision.outputBytes;
                remaining=ctx.budget;
                ctx.status=as6aot::Returned;
                AudioSchedulingBoundary(vm);
            } else {
                if(!as6_vertex_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
                ctx.status=as6aot::Returned;
            }
            continue;
        }
        if(as6_collision36_boundary::isBoundary(ctx)) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            ++vm->_collision36Attempts;
            const as6_collision::Storage storage{
                &core,
                [](void *owner,std::uint32_t at,void *out,std::size_t length) {
                    return static_cast<Core *>(owner)->read(at,out,length);
                },
                [](void *owner,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t count) {
                    return static_cast<Core *>(owner)->write_batch(spans,count);
                }
            };
            as6_collision::Result decision;
            {
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                decision=as6_collision36::query(storage,GuestReg(vm,0),GuestReg(vm,1),state.fpscr());
            }
            vm->_collision36Nodes+=decision.nodesRead;
            vm->_collision36TriangleBytes+=decision.triangleBytesRead;
            ++vm->_collision36Reasons[unsigned(decision.reason)];
            ++vm->_collision36KernelStatuses[unsigned(decision.kernelStatus)];
            if(decision.decision==as6_collision::Decision::Handled) {
                ++vm->_collision36Handled;--remaining;ctx.budget=remaining;
                auto fpscr=state.fpscr()|decision.floatingPoint.exceptionBits;
                if(decision.floatingPoint.compared)
                    fpscr=(fpscr&0x0fffffffu)|decision.floatingPoint.nzcv;
                state.set_fpscr(fpscr);
                GuestReturn(vm);
            } else if(!as6_collision36_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
            ctx.status=as6aot::Returned;
            continue;
        }
        if(as6_collision_boundary::isBoundary(ctx)) {
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            ++vm->_collisionAttempts;
            const as6_collision::Storage storage{
                &core,
                [](void *owner,std::uint32_t at,void *out,std::size_t length) {
                    return static_cast<Core *>(owner)->read(at,out,length);
                },
                [](void *owner,const as6hostdata::DataMemory::WriteSpan *spans,std::size_t count) {
                    return static_cast<Core *>(owner)->write_batch(spans,count);
                }
            };
            as6_collision::Result decision;
            {
                // The old execute frame/lease is already gone. This bounded
                // source transaction performs data reads and one publication;
                // it never calls Host/UI/audio or waits on another owner.
                auto lease=core.native_execution_lease();
                if(!lease.valid())return Finish(vm,GuestExecutionInvalidState);
                decision=as6_collision::query(storage,GuestReg(vm,0),GuestReg(vm,1),state.fpscr());
            }
            vm->_collisionNodes+=decision.nodesRead;
            vm->_collisionTriangleBytes+=decision.triangleBytesRead;
            ++vm->_collisionReasons[unsigned(decision.reason)];
            ++vm->_collisionKernelStatuses[unsigned(decision.kernelStatus)];
            if(decision.decision==as6_collision::Decision::Handled) {
                ++vm->_collisionHandled;--remaining;ctx.budget=remaining;
                // Ordinary Darwin ARMv7 function-call semantics: all saved
                // registers and FP controls survive. Scratch values/status are
                // caller-clobbered, and the verified public epilogue reads none.
                auto fpscr=state.fpscr()|decision.floatingPoint.exceptionBits;
                if(decision.floatingPoint.compared)
                    fpscr=(fpscr&0x0fffffffu)|decision.floatingPoint.nzcv;
                state.set_fpscr(fpscr);
                GuestReturn(vm);
            } else if(!as6_collision_boundary::arm(ctx))return Finish(vm,GuestExecutionInvalidState);
            ctx.status=as6aot::Returned;
            continue;
        }
#endif
#if !defined(AS6_NATIVE_MUSIC_ABSENCE_FIXTURE)
        // The copied original shard returned before its entry instruction.
        // The adapter publishes values only after every native frame unwound.
        if(as6_music_boundary::isBoundary(ctx.next_pc,ctx.isa_thumb)) {
            const auto originalPC=ctx.next_pc;
            if(!remaining)return Finish(vm,GuestExecutionBudgetExhausted);
            const auto decision=AS6NativeMusicHandleBoundary(vm,originalPC);
            if(decision==AS6NativeMusicFailed||vm->_fault)return Finish(vm,GuestExecutionInvalidState);
            if(vm->_halt)return Finish(vm,GuestExecutionHalted);
            if(decision==AS6NativeMusicHandled) {
                --remaining;ctx.budget=remaining;
                GuestReturn(vm);
            } else if(decision==AS6NativeMusicOriginal) {
                if(!as6_music_boundary::arm(ctx,originalPC))return Finish(vm,GuestExecutionInvalidState);
            } else return Finish(vm,GuestExecutionInvalidState);
            ctx.status=as6aot::Returned;
            continue;
        }
#endif
        // Private original-UI boundary: native execution is fully unwound.
        // Nested helper calls are suppressed and save/restore the entire CPU.
        if (as6_original_ui::isBoundary(ctx.next_pc,ctx.isa_thumb) && !as6_original_ui::suppressed()) {
            const auto originalPC=ctx.next_pc;
            const auto handler=GuestReg(vm,0);
            bool ok=true;
            if (originalPC==as6_original_ui::Advance && AS6OriginalUIBeforeAdvance && AS6OriginalUIApply) {
                const auto returnPC=GuestLR(vm);
                if (!remaining) return Finish(vm,GuestExecutionBudgetExhausted);
                if (!returnPC || (returnPC&~1u)==originalPC) return Finish(vm,GuestExecutionInvalidState);
                GuestExecutionResult advanced=GuestExecutionInvalidState;
                {
                    as6_original_ui::Suppress suppress;
                    ok=AS6OriginalUIBeforeAdvance(vm,handler);
                    if(ok&&!vm->_fault&&!vm->_halt)
                        advanced=GuestEmulate(vm,originalPC,returnPC,remaining);
                    // Original game work retains its actual budget and every
                    // architectural effect, including result registers/flags.
                    if(ok && advanced==GuestExecutionSuccess) {
                        remaining=ctx.budget;
                        ok=AS6OriginalUIApply(vm,handler);
                    }
                }
                if(!ok||vm->_fault)return Finish(vm,GuestExecutionInvalidState);
                if(vm->_halt)return Finish(vm,GuestExecutionHalted);
                if(advanced!=GuestExecutionSuccess)return Finish(vm,advanced);
                ctx.status=as6aot::Returned;
                continue;
            }
            {
                as6_original_ui::Suppress suppress;
                if(originalPC==as6_original_ui::Unload) {
                    if(AS6OriginalUIBeforeUnload)ok=AS6OriginalUIBeforeUnload(vm);
                } else if(originalPC==as6_original_ui::RemoveChildNodeType) {
                    if(GuestLR(vm)==as6_original_ui::MenuSceneLoadedReturn&&AS6OriginalUIMenuSceneLoaded)
                        ok=AS6OriginalUIMenuSceneLoaded(vm,handler);
                } else if(AS6OriginalUIApply)ok=AS6OriginalUIApply(vm,handler);
            }
            if(!ok||vm->_fault)return Finish(vm,GuestExecutionInvalidState);
            if(vm->_halt)return Finish(vm,GuestExecutionHalted);
            if(!as6_original_ui::arm(ctx,originalPC))return Finish(vm,GuestExecutionInvalidState);
            ctx.status=as6aot::Returned;
            continue;
        }
        const auto *bridge=core.bridge(ctx.next_pc,ctx.isa_thumb);
        if (!bridge) {
            CaptureNativeFailure(vm,result);
            GuestTrace(vm,@"[native] no converted target pc=%#x mode=%u",ctx.next_pc,unsigned(ctx.isa_thumb));
            return Finish(vm,GuestExecutionUnresolvedTarget);
        }
        if (!remaining) return Finish(vm,GuestExecutionBudgetExhausted);
        --remaining;
        ctx.budget=remaining; ctx.status=as6aot::Returned;
        const auto importPC=ctx.next_pc; const auto importThumb=ctx.isa_thumb;
        // Original in-image weak definitions take precedence over host APIs.
        // This is only an immutable identity redirect into already compiled
        // native code; arguments, LR, flags and the remaining budget survive.
        if (const auto definition=core.bridge_definition(bridge)) {
            // GuestSetPC without re-checking the lock this frame already holds.
            state.set_cpsr((state.cpsr()&~0x20u)|((definition&1u)<<5));
            state.set_register(15,definition&~1u);
            continue;
        }
        ++vm->_calls;
        auto &slot=core.bridge_slot(bridge);
        const auto generation=HLEGeneration()+1;
        if(slot.impl_generation!=generation){
            HLEImpl found=HLELookup(bridge->symbol);bool automatic=false;
            if (!found&&!bridge->requires_registered) { found=HLEAutoImpl(bridge->symbol); automatic=found!=nullptr; }
            slot.impl=(void *)found;slot.auto_impl=automatic;slot.impl_generation=found?generation:0;
        }
        HLEImpl impl=(HLEImpl)slot.impl;
        if (impl&&slot.auto_impl) ++vm->_autoCalls;
        if (!impl) {
            ctx.status=as6aot::UnresolvedTarget;
            CaptureNativeFailure(vm,ctx.status);
            ++vm->_missing[bridge->symbol];
            HLERecordNeeded([NSString stringWithUTF8String:bridge->symbol]);
            GuestTrace(vm,@"[native] unresolved bridge #%u %s at %#x",bridge->native_bridge_id,bridge->symbol,importPC);
            return Finish(vm,GuestExecutionUnresolvedTarget);
        }
        if(!vm->_fault)MainThreadSchedulingBoundary(vm);
        if(vm->_fault)return Finish(vm,GuestExecutionInvalidState);
        if(vm->_halt)return Finish(vm,GuestExecutionHalted);
        // HLE calls happen only after the C++ NativeProgram frame is gone.
        // Preserve nesting/current import identity around callbacks.
        // The names are static (the bridge table): save the pointer, no copy.
        const char *const savedSymbol=HLECurrentSymbol();
        HLESetCurrentSymbol(bridge->symbol);
        @try { HLEPosixPoll(vm); if (!vm->_fault) impl(vm); }
        @catch (NSException *exception) {
            GuestTrace(vm,@"[native] bridge %s raised %@",bridge->symbol,exception.name);
            vm->_fault=true;
        } @finally { HLESetCurrentSymbol(savedSymbol); }
        if (vm->_fault) return Finish(vm,GuestExecutionInvalidState);
        if (vm->_halt) return Finish(vm,GuestExecutionHalted);
        if (GuestAudioProducerWasCancelled(vm)) return Finish(vm,GuestExecutionCancelled);
        if (frame.yielded) return Finish(vm,GuestExecutionYielded);
        if (ctx.next_pc==importPC&&ctx.isa_thumb==importThumb) GuestReturn(vm);
        ctx.status=as6aot::Returned;
        AudioSchedulingBoundary(vm);
    }
}
uint32_t GuestCall(GuestVM *vm,gva_t fn,const uint32_t *args,int nargs,uint64_t maxInsns) {
    if(!vm)return 0;
    __strong GuestVM *callOwner __attribute__((objc_precise_lifetime))=vm;
    (void)callOwner;
    GuestLock(vm);
    uint32_t value=0;
    @try {
        if(!vm->_core||!fn||nargs<0||nargs>260||(nargs&&!args)){vm->_lastResult=GuestExecutionInvalidArgument;return 0;}
        if (vm->_fault||vm->_halt) { vm->_lastResult=vm->_fault?GuestExecutionInvalidState:GuestExecutionHalted; return 0; }
        // A new ordinary child may reuse this exact shared Context. It must
        // never consume an outer source-entry retry permission.
        {auto &c=vm->_core->state().context();if(as6_nav_boundary::pending(c))as6_nav_vm::add(vm->_nav.clearsCall);as6_nav_boundary::cancel(c);as6_copy_boundary::cancel(c);}
        auto &state=vm->_core->state();
        const auto saved=state.save();
        uint32_t sp=GuestSP(vm);
        if (!GuestStackContains(vm,sp,0x8000u)) sp=vm->_core->provider().data->initial_sp;
        const auto child=(sp-0x2000u)&~7u;
        std::array<uint8_t,1024> stackArgs{};
        // Forward the existing outgoing argument area only when valid.
        GuestRead(vm,sp,stackArgs.data(),stackArgs.size());
        if (!GuestStackContains(vm,child,0)||!GuestWrite(vm,child,stackArgs.data(),stackArgs.size())) {
            Finish(vm,GuestExecutionMemoryFault); return 0;
        }
        for (int i=0;i<nargs&&i<4;++i) GuestSetReg(vm,i,args[i]);
        for (int i=4;i<nargs;++i) GuestWriteU32(vm,child+4u*uint32_t(i-4),args[i]);
        GuestSetReg(vm,13,child); GuestSetReg(vm,14,as6native::StopAddress);
        state.set_cpsr((state.cpsr()&~0x20u)|((fn&1u)<<5));
        const auto result=GuestEmulate(vm,fn&~1u,as6native::StopAddress,maxInsns);
        if (result==GuestExecutionSuccess) value=GuestReg(vm,0);
        // A callback that runs out of budget has not returned to its caller.
        // Restoring that caller cannot turn a truncated callback into success.
        if (result==GuestExecutionBudgetExhausted||result==GuestExecutionYielded) vm->_fault=true;
        // CPU restore never rolls back data or permanent halt/fault latches.
        if (!state.restore(saved)) { Finish(vm,GuestExecutionInvalidState); return 0; }
        vm->_lastResult=result;
    } @finally {
        if(vm->_core){auto &c=vm->_core->state().context();if(as6_nav_boundary::pending(c))as6_nav_vm::add(vm->_nav.clearsCall);as6_nav_boundary::cancel(c);as6_copy_boundary::cancel(c);}
        GuestUnlock(vm);
    }
    return value;
}
BOOL GuestVMRun(GuestVM *vm,gva_t entry,uint32_t cpsr,uint64_t budget,NSError **error) {
    if (!vm||!vm->_core) return SetError(error,GuestExecutionUnavailable,@"No native VM");
    GuestLock(vm);
    @try {
        if (GuestSetCPSR(vm,cpsr)!=GuestExecutionSuccess) return SetError(error,GuestExecutionInvalidState,@"Unsupported original CPU flags");
        GuestSetReg(vm,14,as6native::StopAddress);
        GuestSetReg(vm,13,vm->_core->provider().data->initial_sp);
        const auto result=GuestEmulate(vm,entry,as6native::StopAddress,budget);
        return (result==GuestExecutionSuccess||result==GuestExecutionYielded)?YES:SetError(error,result,
            [NSString stringWithFormat:@"Native execution at %#x: %s",GuestPC(vm),GuestExecutionErrorText(result)]);
    } @finally { GuestUnlock(vm); }
}
void GuestRunModInitFuncs(GuestVM *vm) {
    if (!vm||!vm->_core) return;
    GuestLock(vm);
    @try {
        if (vm->_initializersRan) return;
        const auto *m=vm->_core->provider().data;
        for (size_t i=0;i<m->initializer_count;++i) {
            GuestTrace(vm,@"[native] initializer %zu/%zu at %#x",i+1,m->initializer_count,m->initializers[i]);
            GuestCall(vm,m->initializers[i],nullptr,0,4000000);
            if (vm->_lastResult!=GuestExecutionSuccess) {
                GuestTrace(vm,@"[native] initializer %#x stopped: %s",m->initializers[i],GuestExecutionErrorText(vm->_lastResult));
                GuestRequestFault(vm); return;
            }
            vm->_completedInitializers=i+1;
        }
        vm->_initializersRan=YES;
    } @finally { GuestUnlock(vm); }
}
uint32_t GuestSectionAddress(GuestVM *vm,const char *name) {
    if (!vm||!vm->_core||!name) return 0;
    const auto *s=vm->_core->section(name);return s?s->address:0;
}
// Loader metadata only. Product section queries continue to require actual
// available bytes; registry construction must distinguish absent from holes.
extern "C" BOOL GuestLoaderDeclaredSection(GuestVM *vm,const char *name,uint32_t *address,uint32_t *size) {
    if(!vm||!vm->_core||!address||!size)return NO;
    const auto *section=vm->_core->declared_section(name);
    if(!section)return NO;
    *address=section->address;*size=section->size;return YES;
}
uint32_t GuestSectionSize(GuestVM *vm,const char *name) {
    if (!vm||!vm->_core||!name) return 0;
    const auto *s=vm->_core->section(name);return s?s->size:0;
}
BOOL GuestSectionContains(GuestVM *vm,const char *name,uint32_t at) {
    const auto first=GuestSectionAddress(vm,name),size=GuestSectionSize(vm,name);
    return size&&at>=first&&std::uint64_t(at)<std::uint64_t(first)+size;
}
void GuestRawLog(const char *line) { if (line) std::fprintf(stderr,"%s\n",line); }
void GuestTrace(GuestVM *vm,NSString *format,...) {
    if (!vm||!format||!vm->_traceEnabled) return;
    va_list args; va_start(args,format);
    NSString *line=[[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    @synchronized(vm->_trace) {
        [vm->_trace addObject:line];
        if (vm->_trace.count>4096) [vm->_trace removeObjectsInRange:NSMakeRange(0,1024)];
    }
}
NSArray<NSString *> *GuestTraceLog(GuestVM *vm) { if (!vm) return @[]; @synchronized(vm->_trace) { return [vm->_trace copy]; } }
extern "C" NSDictionary<NSString *,id> *GuestExecutionDiagnosticsLocked(GuestVM *vm) {
    if (!DiagnosticLockHeld(vm)) return @{};
        NSMutableDictionary *result=[@{@"initializers_completed":@(vm->_completedInitializers),
            @"initializers_total":@(vm->_core?vm->_core->provider().data->initializer_count:0),
            @"initializers_finished":@(vm->_initializersRan),
            @"memory_diagnostics_enabled":@(vm->_gameWriteWatch.enabled),
            @"native_slices":@(vm->_nativeSlices),@"audio_scheduler_handoffs":@(vm->_schedulerYields),
            @"main_thread_handoffs":@(vm->_mainThreadYields)} mutableCopy];
        NSMutableArray *collisionReasons=[NSMutableArray arrayWithCapacity:vm->_collisionReasons.size()];
        for(const auto count:vm->_collisionReasons)[collisionReasons addObject:@(count)];
        NSMutableArray *collisionStatuses=[NSMutableArray arrayWithCapacity:vm->_collisionKernelStatuses.size()];
        for(const auto count:vm->_collisionKernelStatuses)[collisionStatuses addObject:@(count)];
        result[@"native_collision"]=@{@"attempts":@(vm->_collisionAttempts),@"handled":@(vm->_collisionHandled),
            @"nodes_read":@(vm->_collisionNodes),@"triangle_bytes_read":@(vm->_collisionTriangleBytes),
            @"reason_counts":collisionReasons,@"kernel_status_counts":collisionStatuses};
        const auto counts=[](const auto &values) {
            NSMutableArray *out=[NSMutableArray arrayWithCapacity:values.size()];
            for(const auto value:values)[out addObject:@(value)];return out;
        };
        result[@"native_collision36"]=@{@"attempts":@(vm->_collision36Attempts),@"handled":@(vm->_collision36Handled),
            @"nodes_read":@(vm->_collision36Nodes),@"triangle_bytes_read":@(vm->_collision36TriangleBytes),
            @"reason_counts":counts(vm->_collision36Reasons),@"kernel_status_counts":counts(vm->_collision36KernelStatuses)};
#if !defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
        result[@"native_render_work"]=AS6GLRenderWorkDiagnostics();
#endif
        result[@"native_collision_inverse"]=@{@"attempts":@(vm->_collisionInverseAttempts),@"handled":@(vm->_collisionInverseHandled),
            @"declined":@(vm->_collisionInverseDeclined),@"instructions_replaced":@(vm->_collisionInverseInstructions)};
        result[@"native_scene_affine"]=@{@"attempts":@(vm->_sceneAttempts),@"handled":@(vm->_sceneHandled),
            @"declined":@(vm->_sceneDeclined),@"instructions_replaced":@(vm->_sceneInstructions)};
        result[@"native_ui_work"]=@{@"attempts":@(vm->_uiWorkAttempts),@"handled":@(vm->_uiWorkHandled),
            @"declined":@(vm->_uiWorkDeclined),@"instructions_replaced":@(vm->_uiWorkInstructions)};
        result[@"native_copy_unit"]=@{@"attempts":@(vm->_copyAttempts),@"handled":@(vm->_copyHandled),
            @"records":@(vm->_copyRecords),@"instructions_replaced":@(vm->_copyInstructions),@"declined":@(vm->_copyDeclined)};
        result[@"native_vertices"]=@{@"attempts":@(vm->_vertexAttempts),@"handled":@(vm->_vertexHandled),
            @"vertices":@(vm->_vertexVertices),@"vectorized_vertices":@(vm->_vertexVectorized),
            @"extended_batches":@(vm->_vertexExtended),@"parallel_batches":@(vm->_vertexParallel),
            @"background_tasks":@(vm->_vertexBackgroundTasks),@"parallel_replays":@(vm->_vertexParallelReplays),@"source_bytes_read":@(vm->_vertexSourceBytes),@"output_bytes_written":@(vm->_vertexOutputBytes),
            @"reason_counts":counts(vm->_vertexReasons),@"kernel_status_counts":counts(vm->_vertexKernelStatuses)};
        result[@"native_trails"]=@{@"attempts":@(vm->_trailAttempts),@"handled":@(vm->_trailHandled),
            @"empty_updates":@(vm->_trailEmpty),@"index_bytes_read":@(vm->_trailIndexReadBytes),
            @"vertex_bytes_written":@(vm->_trailVertexWriteBytes),@"index_bytes_written":@(vm->_trailIndexWriteBytes),
            @"state_bytes_written":@(vm->_trailStateWriteBytes),@"reason_counts":counts(vm->_trailReasons),
            @"kernel_status_counts":counts(vm->_trailKernelStatuses)};
        result[@"native_navline"]=@{@"attempts":@(vm->_nav.attempts),@"handled":@(vm->_nav.handled),
            @"declined":@(vm->_nav.declined),@"native":@(vm->_nav.native),@"exact":@(vm->_nav.exact),
            @"original_instructions":@(vm->_nav.instructions),@"publication_spans":@(vm->_nav.spans),
            @"reason_counts":counts(vm->_nav.reasons),@"point_count_buckets":counts(vm->_nav.points),@"high_lane_buckets":counts(vm->_nav.high),
            @"provider_declines":@(vm->_nav.providerDeclines),@"workspace_declines":@(vm->_nav.workspaceDeclines),
            @"leaves_over_quantum":@(vm->_nav.overQuantum),@"workspace_capacity":@(vm->_navWorkspace?vm->_navWorkspace->capacity():0),
            @"workspace_bytes":@(vm->_navWorkspace?vm->_navWorkspace->bytes():0),@"workspace_owner":@(vm->_navWorkspaceOwner),
            @"linked_provider_authorized":@(vm->_core&&as6_nav_vm::isLinkedProvider(&vm->_core->provider())),
            @"latch_clears_finish":@(vm->_nav.clearsFinish),@"latch_clears_frame":@(vm->_nav.clearsFrame),
            @"latch_clears_destroy":@(vm->_nav.clearsDestroy),@"latch_clears_call":@(vm->_nav.clearsCall),@"latch_clears_handoff":@(vm->_nav.clearsHandoff)};
        if (vm->_firstNativeFailure) result[@"first_native_failure"]=vm->_firstNativeFailure;
        if(vm->_gameWriteWatch.enabled){
            auto convert=[](const GameWriteEvent &event)->NSDictionary *{
                return @{@"kind":@(event.kind?:""),@"sequence":@(event.sequence),@"address":@(event.address),
                    @"length":@(event.length),@"object":@(event.object),@"old":@(event.before),@"new":@(event.after),
                    @"old_readable":@(event.beforeReadable),@"new_readable":@(event.afterReadable),
                    @"pc":@(event.pc),@"lr":@(event.lr),@"source":event.native?@"native":@"host",@"hle":@(event.hle),
                    @"native_depth":@(event.nativeDepth),@"execution_depth":@(event.executionDepth)};};
            NSMutableArray *events=[NSMutableArray arrayWithCapacity:vm->_gameWriteWatch.count];
            for(unsigned i=0;i<vm->_gameWriteWatch.count;++i)[events addObject:convert(vm->_gameWriteWatch.events[i])];
            NSMutableDictionary *watch=[@{@"global":@(GameWriteWatch::Global),@"current_game":@(vm->_gameWriteWatch.game),
                @"observed_events":@(vm->_gameWriteWatch.sequence),@"retained_events":events} mutableCopy];
            if(vm->_gameWriteWatch.hasFirstZero)watch[@"first_zero"]=convert(vm->_gameWriteWatch.firstZero);
            if(vm->_gameWriteWatch.hasFirstCleared)watch[@"first_nonzero_to_zero"]=convert(vm->_gameWriteWatch.firstCleared);
            result[@"game_vptr_write_watch"]=watch;
            NSMutableArray *titleEvents=[NSMutableArray arrayWithCapacity:vm->_gameWriteWatch.titleCount];
            for(unsigned i=0;i<vm->_gameWriteWatch.titleCount;++i){const auto &event=vm->_gameWriteWatch.titleEvents[i];
                [titleEvents addObject:@{@"kind":@(event.kind),@"state":@(event.state),@"pc":@(event.pc),
                    @"address":@(event.address),@"value":@(event.value),@"swf_object":@(event.swfObject),@"swf_updates":@(event.swfUpdates)}];}
            result[@"title_input_observation"]=@{@"state":@(vm->_gameWriteWatch.titleState),
                @"loading_known":@(vm->_gameWriteWatch.titleLoadingKnown),@"loading":@(vm->_gameWriteWatch.titleLoading),
                @"stage_known":@(vm->_gameWriteWatch.titleStageKnown),@"stage":@(vm->_gameWriteWatch.titleStage),
                @"swf_update_reads":@(vm->_gameWriteWatch.swfUpdates),@"last_swf_object":@(vm->_gameWriteWatch.lastSWFObject),
                @"retained_changes":titleEvents};
            result[@"png_progress_observation"]=@{@"file_open":@(vm->_gameWriteWatch.pngFD>=0),
                @"io_failed":@(vm->_gameWriteWatch.pngIOFailed),@"records":@(vm->_gameWriteWatch.pngRecords),
                @"rows":@(vm->_gameWriteWatch.pngRows),@"last_rowbytes":@(vm->_gameWriteWatch.pngRowBytes),
                @"filter_iterations":@(vm->_gameWriteWatch.pngIterations)};
        }
        return result;
}
NSDictionary<NSString *,id> *GuestExecutionDiagnostics(GuestVM *vm) {
    if (!vm) return @{};
    GuestLock(vm);
    @try { return GuestExecutionDiagnosticsLocked(vm); }
    @finally { GuestUnlock(vm); }
}
NSString *GuestTraceText(GuestVM *vm) { return [GuestTraceLog(vm) componentsJoinedByString:@"\n"]; }
void GuestSetTraceEnabled(GuestVM *vm,BOOL enabled) { if (vm) vm->_traceEnabled=enabled; }
void GuestRequestFault(GuestVM *vm) { if (vm) vm->_fault=true; }
void GuestRequestHalt(GuestVM *vm) { if (vm) vm->_halt=true; }
void GuestYieldToHostRunLoop(GuestVM *vm) {
    if (!vm) return;
    if (vm->_nativeDepth||!activeHostFrame||activeHostFrame->vm!=vm) {
        GuestRequestFault(vm);
        return;
    }
    activeHostFrame->yielded=true;
}
NSUInteger GuestUnimplementedCount(GuestVM *vm) { NSUInteger count=0; if(vm) for(const auto &v:vm->_missing) count+=v.second; return count; }
NSDictionary<NSString *,NSNumber *> *GuestUnimplementedCounts(GuestVM *vm) {
    NSMutableDictionary *out=[NSMutableDictionary new];
    if (vm) for(const auto &v:vm->_missing) out[[NSString stringWithUTF8String:v.first.c_str()]]=@(v.second);
    return out;
}
NSUInteger GuestCallCount(GuestVM *vm) { return vm?vm->_calls:0; }
NSUInteger GuestAutoBridgeCount(GuestVM *vm) { return vm?vm->_autoCalls:0; }
NSUInteger GuestBindSlotCount(GuestVM *vm) {return vm?vm->_bindApplied:0;}
void GuestLoadSymbols(NSString *path) {
    NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    std::vector<Symbol> loaded;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *columns=[line componentsSeparatedByString:@"\t"];
        if(columns.count<3) continue;
        char *tail=nullptr;
        const auto at=std::strtoull(columns[0].UTF8String,&tail,16);
        if (!tail||*tail||at>UINT32_MAX) continue;
        const auto size=std::strtoull(columns[2].UTF8String,&tail,0);
        if (!tail||*tail||size>UINT32_MAX||at+size>0x100000000ULL) continue;
        loaded.push_back({uint32_t(at),uint32_t(size),columns[1].UTF8String?:""});
    }
    std::sort(loaded.begin(),loaded.end(),[](const auto &a,const auto &b){return a.at<b.at;});
    std::lock_guard<std::mutex> lock(symbolsLock); symbols=std::move(loaded);
}
NSString *GuestSymbolAt(uint32_t pc) {
    std::lock_guard<std::mutex> lock(symbolsLock);
    auto it=std::upper_bound(symbols.begin(),symbols.end(),pc,[](auto at,const auto &s){return at<s.at;});
    if (it!=symbols.begin()) { --it; if (std::uint64_t(pc)<std::uint64_t(it->at)+it->size)
        return [NSString stringWithFormat:@"%s+%#x",it->name.c_str(),pc-it->at]; }
    return [NSString stringWithFormat:@"%#x",pc];
}
static int Recent(const std::array<uint32_t,64> &values,unsigned size,char *out,size_t capacity,int count) {
    if (!out||!capacity) return 0;
    out[0]=0; size_t used=0;
    const auto n=std::min<unsigned>(std::min<unsigned>(size,64),unsigned(std::max(count,0)));
    for(unsigned i=0;i<n;++i) {
        const int written=std::snprintf(out+used,capacity-used,"%s%#x",i?" ":"",values[(size-n+i)%64]);
        if(written<0||size_t(written)>=capacity-used) break;
        used+=size_t(written);
    }
    return int(used);
}
int GuestRecentPcsRaw(GuestVM *vm,char *out,size_t capacity,int count) {
    if (!vm) { if(out&&capacity)out[0]=0; return 0; }
    return Recent(vm->_recentPC,vm->_recentCount,out,capacity,count);
}
int GuestRecentSpsRaw(char *out,size_t capacity,int count) { return Recent(recentSP,recentSPCount,out,capacity,count); }
void GuestInstallProbe(GuestVM *vm,uint32_t lo,uint32_t hi) {
    GuestTrace(vm,@"[native] instruction probes require offline-generated instrumentation; requested [%#x,%#x)",lo,hi);
}
void GuestDumpRecentTraps(GuestVM *vm,int count) {
    char out[1024]; GuestRecentPcsRaw(vm,out,sizeof(out),count);
    GuestTrace(vm,@"[native] recent execution/bridge boundaries: %s",out);
}

#if defined(AS6_NAV_VM_FIXTURE)
// Read-only inspection of the actual locked owner; no fixture grants the lock.
extern "C" Core *AS6NavCoreForFixtureLocked(GuestVM *vm){return DiagnosticLockHeld(vm)&&!vm->_nativeDepth&&vm->_core?vm->_core.get():nullptr;}
extern "C" unsigned AS6NavExecutionDepthForFixtureLocked(GuestVM *vm){return DiagnosticLockHeld(vm)?vm->_executionDepth:0;}
extern "C" bool AS6NavPendingForFixtureLocked(GuestVM *vm){return DiagnosticLockHeld(vm)&&vm->_core&&as6_nav_boundary::pending(vm->_core->state().context());}
#endif
