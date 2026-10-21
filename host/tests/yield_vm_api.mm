// Test-only genuine compiled ARM64 functions. This is VM integration coverage,
// not converted game code and not a complete game provider.
#import "GuestVM.h"
#import "GuestNativeCPUPrivate.hpp"
#import "GuestNativeProvider.hpp"
#import "HLE.h"
#import "GuestObjC.h"
#include "GuestObjCMetadata.hpp"
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <cstdlib>
#include <chrono>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
extern "C" BOOL GuestConfigurePNGProgressFile(GuestVM *,const char *);
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *);
extern "C" GuestExecutionResult GuestLastExecutionResultLocked(GuestVM *);
extern "C" NSDictionary *GuestExecutionDiagnosticsLocked(GuestVM *);


using namespace as6aot;
using namespace as6native;
static unsigned checks,bridges,nested,polls;
#define CHECK(x) do { ++checks; assert(x); } while(0)
static Status Branch(Context &c,uint32_t encoded) {
    c.next_pc=encoded&~1u; c.isa_thumb=encoded&1u;
    write_bytes(c.registers,layout::pc,4,c.next_pc); return Dispatch;
}
static Status Tiny(Context &c,bool,uint32_t,bool) {
    if (!c.budget) return BudgetExhausted;
    --c.budget;
    const auto pc=c.next_pc;
    const auto lr=uint32_t(read_bytes(c.registers,layout::r0+14*4,4));
    if (pc==0x1000||pc==0x1020) {
        const auto sum=read_bytes(c.registers,layout::r0,4)+read_bytes(c.registers,layout::r0+4,4);
        write_bytes(c.registers,layout::r0,4,sum);
        store(c,0x8000,4,sum);
        return c.status==Returned?Branch(c,lr):c.status;
    }
    if (pc==0x1004) { write_bytes(c.registers,layout::r0+14*4,4,0x1008); return Branch(c,0x1800); }
    if (pc==0x1008) return Branch(c,StopAddress);
    if (pc==0x100c) return Branch(c,0x4444);
    if (pc==0x1010) { load(c,0x8010,4); return c.status; }
    if (pc==0x1014) {
        if(read_bytes(c.registers,layout::r0+4,4)==0x51554e54u){
            const auto value=uint32_t(read_bytes(c.registers,layout::r0,4));
            write_bytes(c.registers,layout::r0,4,value-1);
            return Branch(c,value>1?0x1014:lr);
        }
        return Branch(c,0x1014);
    }
    return InvalidState;
}
static NativeFunction Lookup(uint32_t pc,bool thumb) {
    if (thumb) return pc==0x1020?Tiny:nullptr;
    return pc>=0x1000&&pc<=0x1014&&!(pc&3)?Tiny:nullptr;
}
static const NativeModule modules[]={{0x2000,0x2041,Lookup}};
static const NativeProgram program(modules,1,layout::Size,layout::pc);
static const Bridge bridgeTable[]={
    {0x1800,1,"_native_add",false},{0x1804,2,"_native_missing",false},
    {0x1808,3,"_native_halt",false},{0x180c,4,"_native_nested",false},
    {0x1810,5,"_native_yield",false},
    {0x1814,6,"_native_host_runloop",false},
};
static const uint8_t seed[]={9,0,0,0};
static const DataRegion regions[]={{0x8000,4096,3}};
static const DataSpan spans[]={{0x8000,4,seed,DataKind::WritableBytes}};
static const Section sections[]={{"__data",0x8000,4}};
static const DataManifest data={ProviderVersion,regions,1,spans,1,sections,1,nullptr,0,0x3ffef000};
static const Provider provider={ProviderVersion,&program,bridgeTable,6,&data,0x1000,"vm-integration-test-only"};
extern "C" const Provider *AS6LinkedNativeProvider() { return &provider; }

// Test scheduler/poll hooks have no pending external I/O or worker CPU to take.
// Actual HLE objects are separately compiled for every shipping platform.
static unsigned snapshotCpuTakes=0;
static bool requestAudioService=false;
static unsigned schedulingHandoffs=0;
static unsigned schedulingFailure=0;
static bool schedulingCancelled=false;
extern "C" BOOL GuestAudioProducerNeedsService(void){return requestAudioService;}
extern "C" int GuestAudioWaitForProducerTurn(void){return 0;}
extern "C" BOOL GuestAudioProducerWasCancelled(GuestVM*){return schedulingCancelled;}
extern "C" void AS6SystemZlibForgetVM(GuestVM*){}
extern "C" int HLEPthreadBlockingCall(GuestVM *vm,int (*operation)(void *),void *opaque){
    ++schedulingHandoffs;
    auto &state=*GuestNativeCPUState(vm);const auto saved=state.save();
    const auto depth=GuestSuspendLocks(vm);CHECK(depth>0);
    CHECK(!GuestDiagnosticSnapshotLockHeld(vm));
    const int result=operation(opaque);
    std::thread worker([&]{
        GuestLock(vm);GuestSetReg(vm,0,0xbad);
        GuestWriteU32(vm,0x8000,0x12345678);
        if(schedulingFailure==1)GuestRequestFault(vm);
        if(schedulingFailure==2)GuestRequestHalt(vm);
        if(schedulingFailure==3)schedulingCancelled=true;
        GuestUnlock(vm);
    });worker.join();
    GuestResumeLocks(vm,depth);CHECK(state.restore(saved));
    return result;
}
extern "C" void HLEPthreadTakeCPU(GuestVM *) { ++snapshotCpuTakes; }
extern "C" void HLEPosixPoll(GuestVM *) { ++polls; }
static thread_local std::string current;
extern "C" void HLESetCurrentSymbol(const char *s) { current=s?s:""; }
extern "C" const char *HLECurrentSymbol() { return current.c_str(); }
extern "C" void HLERecordNeeded(NSString *) {}
static void Add(GuestVM *vm) {
    ++bridges;
    if(schedulingFailure==3){schedulingCancelled=true;return;}
    GuestSetRet(vm,GuestArg(vm,0)+GuestArg(vm,1));
}
static void Halt(GuestVM *vm) { GuestRequestHalt(vm); }
static void HostRunLoop(GuestVM *vm) { GuestSetRet(vm,27); GuestYieldToHostRunLoop(vm); }
static void Nested(GuestVM *vm) {
    ++nested; CHECK(current=="_native_nested");
    const auto pc=GuestPC(vm),sp=GuestSP(vm),cpsr=GuestNativeCPUState(vm)->cpsr();
    uint32_t args[]={40,2}; CHECK(GuestCall(vm,0x1021,args,2,20)==42);
    CHECK(GuestPC(vm)==pc&&GuestSP(vm)==sp&&GuestNativeCPUState(vm)->cpsr()==cpsr);
    CHECK(current=="_native_nested"); GuestSetRet(vm,42);
}
static void Yield(GuestVM *vm) {
    GuestCpuSnapshot *saved=nullptr;
    CHECK(GuestCPUAllocate(vm,&saved)==GuestExecutionSuccess);
    CHECK(GuestCPUSave(vm,saved)==GuestExecutionSuccess);
    const auto depth=GuestSuspendLocks(vm); CHECK(depth>=1);
    uint32_t workerResult=0;
    std::thread worker([&] {
        GuestLock(vm);
        const uint32_t words[]={7,8};
        workerResult=GuestCall(vm,0x1021,words,2,20);
        GuestUnlock(vm);
    });
    worker.join();CHECK(workerResult==15);
    GuestResumeLocks(vm,depth);
    CHECK(GuestCPURestore(vm,saved)==GuestExecutionSuccess); GuestCPUFree(saved);
    GuestSetRet(vm,71);
}
extern "C" HLEImpl HLELookup(const char *s) {
    if (!std::strcmp(s,"_native_add")) return Add;
    if (!std::strcmp(s,"_native_halt")) return Halt;
    if (!std::strcmp(s,"_native_nested")) return Nested;
    if (!std::strcmp(s,"_native_yield")) return Yield;
    if (!std::strcmp(s,"_native_host_runloop")) return HostRunLoop;
    return nullptr;
}
extern "C" HLEImpl HLEAutoImpl(const char *) { return nullptr; }

static GuestVM *Make() {
    NSError *error=nil; GuestVM *vm=GuestVMCreate(&error);
    CHECK(vm&&vm.loaded&&!error); return vm;
}
static void Dispose(GuestVM *vm) { GuestVMDestroy(vm); CHECK(!vm.loaded); }
static void InvalidManifests() {
    NSError *error=nil;
    CHECK(!GuestVMCreateNative(nullptr,&error)&&error.code==GuestExecutionUnavailable);
    auto bad=provider; bad.version=1;
    CHECK(!GuestVMCreateNative(&bad,&error));
    auto badData=data; badData.initial_sp=0; bad=provider;bad.data=&badData;
    CHECK(!GuestVMCreateNative(&bad,&error));
    auto badRegion=regions[0];badRegion.permissions=7;badData=data;badData.regions=&badRegion;
    CHECK(!GuestVMCreateNative(&bad,&error));
    auto badSpan=spans[0];badSpan.address=0x7fff;badData=data;badData.spans=&badSpan;
    CHECK(!GuestVMCreateNative(&bad,&error));
    auto badSection=sections[0];badSection.name="__text";badData=data;badData.sections=&badSection;
    CHECK(!GuestVMCreateNative(&bad,&error));
    badSection=sections[0];badSection.size=5;badData=data;badData.sections=&badSection;
    CHECK(!GuestVMCreateNative(&bad,&error));
    auto duplicate=bridgeTable[0];bad=provider;bad.bridges=&duplicate;bad.bridge_count=1;duplicate.original_address=0x1000;
    CHECK(!GuestVMCreateNative(&bad,&error));
    Bridge aliases[]={bridgeTable[0],{0x1814,1,"_native_add",false}};
    bad=provider;bad.bridges=aliases;bad.bridge_count=2;
    GuestVM *aliased=GuestVMCreateNative(&bad,&error);CHECK(aliased!=nil);
    CHECK(GuestHLEAddress(aliased,"_native_add")==0x1800);Dispose(aliased);
    aliases[1].symbol="_different_name";CHECK(!GuestVMCreateNative(&bad,&error));
    aliases[1].symbol="_native_add";aliases[1].native_bridge_id=99;
    CHECK(!GuestVMCreateNative(&bad,&error));
}
static void NativeDefinitions() {
    // Genuine compiled Tiny functions stand in for precompiled original
    // definitions. The binding slots themselves remain ordinary data.
    BindingSource sources[]={
        {0x8004,"_native_add",0,0,0,2},{0x8008,"_native_missing",0,0,0,2}};
    DataBinding bindings[]={
        {0x8004,BindingKind::StaticValue,"_native_add",0x1000,0x1000,0,0,1},
        {0x8008,BindingKind::StaticValue,"_native_missing",0x1021,0x1021,0,1,1}};
    auto localData=data;localData.bindings=bindings;localData.binding_count=2;
    localData.binding_sources=sources;localData.binding_source_count=2;
    auto localProvider=provider;localProvider.data=&localData;
    auto make=[&] {
        NSError *error=nil;auto *vm=GuestVMCreateNative(&localProvider,&error);
        CHECK(vm&&vm.loaded&&!error);return vm;
    };
    const uint32_t args[]={11,31};
    auto *vm=make();const auto oldBridges=bridges,oldPolls=polls;
    // A same-named registered host implementation must not replace the
    // original local definition; a Thumb local definition works as well.
    CHECK(GuestCall(vm,0x1800,args,2,20)==42);
    CHECK(GuestCall(vm,0x1804,args,2,20)==42);
    CHECK(bridges==oldBridges&&polls==oldPolls&&GuestCallCount(vm)==0);
    CHECK(GuestUnimplementedCount(vm)==0&&GuestAutoBridgeCount(vm)==0);
    // Native target identity comes from the offline descriptor, never a
    // mutable slot value supplied by running game code.
    GuestWriteU32(vm,0x8004,0x4444);
    CHECK(GuestCall(vm,0x1800,args,2,20)==42);
    GuestLock(vm);auto *state=GuestNativeCPUState(vm);
    CHECK(state->set_cpsr(0xa80f0010));
    for(unsigned reg=0;reg<15;++reg)if(reg!=13)GuestSetReg(vm,reg,0x12340000+reg);
    GuestSetReg(vm,0,11);GuestSetReg(vm,1,31);GuestSetReg(vm,14,StopAddress);
    const auto flags=state->cpsr(),sp=GuestSP(vm);
    CHECK(GuestEmulate(vm,0x1804,StopAddress,2)==GuestExecutionSuccess);
    CHECK(GuestReg(vm,0)==42&&GuestReg(vm,1)==31&&GuestReg(vm,14)==StopAddress);
    for(unsigned reg=2;reg<14;++reg)if(reg!=13)CHECK(GuestReg(vm,reg)==0x12340000+reg);
    CHECK(GuestSP(vm)==sp&&state->cpsr()==flags&&state->context().budget==0);
    GuestUnlock(vm);Dispose(vm);
    // One unit is charged for the bridge boundary. No native function may
    // run beyond the supplied budget, and a budget stop remains resumable.
    vm=make();GuestLock(vm);GuestSetReg(vm,0,11);GuestSetReg(vm,1,31);GuestSetReg(vm,14,StopAddress);
    CHECK(GuestEmulate(vm,0x1800,StopAddress,1)==GuestExecutionBudgetExhausted);
    CHECK(GuestPC(vm)==0x1000&&GuestReg(vm,0)==11&&GuestCallCount(vm)==0);
    CHECK(GuestEmulate(vm,0x1000,StopAddress,1)==GuestExecutionSuccess&&GuestReg(vm,0)==42);
    GuestUnlock(vm);Dispose(vm);
    // Nonzero addends are pointer expressions, not exact function identities.
    bindings[1].static_value=0x1000;bindings[1].addend=sources[1].addend=4;
    vm=make();CHECK(GuestCall(vm,0x1804,args,2,20)==0);
    CHECK(GuestLastExecutionResult(vm)==GuestExecutionUnresolvedTarget&&GuestUnimplementedCount(vm)==1);
    Dispose(vm);bindings[1].addend=sources[1].addend=0;
    // Unknown code, wrong ISA/alignment, another bridge, stop identities and
    // typed metadata must never become local native definitions.
    for(const uint32_t target:{0x4444u,0x1002u,0x1001u,0x1800u,StopAddress,ObjCMetadataBase}) {
        bindings[1].static_value=target;vm=make();
        CHECK(GuestCall(vm,0x1804,args,2,20)==0);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionUnresolvedTarget&&GuestUnimplementedCount(vm)==1);
        Dispose(vm);
    }
    // Conflicting same-name static values cannot select an arbitrary target.
    bindings[0].symbol=sources[0].symbol="_native_missing";
    bindings[0].static_value=0x1000;bindings[1].static_value=0x1021;
    vm=make();CHECK(GuestCall(vm,0x1804,args,2,20)==0);
    CHECK(GuestLastExecutionResult(vm)==GuestExecutionUnresolvedTarget);Dispose(vm);
    // Multiple exact slots for the same definition are legitimate.
    bindings[1].static_value=0x1000;
    vm=make();CHECK(GuestCall(vm,0x1804,args,2,20)==42&&GuestCallCount(vm)==0);Dispose(vm);
}
static void GameWriteObservation() {
    struct DiagnosticEnvironment {
        bool present=getenv("AS6_NATIVE_MEMORY_DIAGNOSTICS")!=nullptr;
        std::string previous=present?getenv("AS6_NATIVE_MEMORY_DIAGNOSTICS"):"";
        ~DiagnosticEnvironment(){
            if(present)setenv("AS6_NATIVE_MEMORY_DIAGNOSTICS",previous.c_str(),1);
            else unsetenv("AS6_NATIVE_MEMORY_DIAGNOSTICS");
        }
    } diagnosticEnvironment;
    // A fixture with the real watched global, backed only by declared data.
    // Exercise the production adapter; no App or original game is executed.
    const uint8_t zero[4]{};
    const DataRegion watchRegions[]={{0x8000,4096,3},{0x57000,4096,1},{0x70b000,4096,3}};
    const DataSpan watchSpans[]={{0x8000,4,seed,DataKind::WritableBytes},
        {0x5794c,4,zero,DataKind::ReadOnlyBytes},
        {0x70b230,4,zero,DataKind::WritableBytes}};
    const Section watchSections[]={{"__fixture",0x8000,4},{"__swf_literal",0x5794c,4},{"__watch_global",0x70b230,4}};
    auto watchData=data;watchData.regions=watchRegions;watchData.region_count=3;
    watchData.spans=watchSpans;watchData.span_count=3;watchData.sections=watchSections;watchData.section_count=3;
    auto watchProvider=provider;watchProvider.data=&watchData;
    // This fixture contains the real watched global, so OFF must skip the
    // adapter rather than merely fail to find its watched address.
    for(const char *setting:{static_cast<const char *>(nullptr),"0","true"}) {
        if(setting)setenv("AS6_NATIVE_MEMORY_DIAGNOSTICS",setting,1);
        else unsetenv("AS6_NATIVE_MEMORY_DIAGNOSTICS");
        NSError *disabledError=nil;
        auto *disabledVM=GuestVMCreateNative(&watchProvider,&disabledError);
        CHECK(disabledVM&&!disabledError);GuestLock(disabledVM);
        const auto diagnostics=GuestExecutionDiagnostics(disabledVM);
        CHECK(![diagnostics[@"memory_diagnostics_enabled"] boolValue]);
        CHECK(!diagnostics[@"game_vptr_write_watch"]&&!diagnostics[@"title_input_observation"]&&!diagnostics[@"png_progress_observation"]);
        errno=E2BIG;CHECK(!GuestConfigurePNGProgressFile(disabledVM,"/unused-diagnostic")&&errno==E2BIG);
        auto &context=GuestNativeCPUState(disabledVM)->context();auto *access=context.data_access;
        uint32_t word=0x12345678,read=0,exclusiveResult=0;
        CHECK(access->write(access->state,0x70b230,&word,4));
        CHECK(access->read(access->state,0x70b230,&read,4)&&read==word);
        uint64_t exclusive=0,old=0;
        CHECK(access->load_exclusive(access->state,0x70b230,4,&exclusive)==Returned&&exclusive==word);
        GuestWriteU32(disabledVM,0x70b230,7);
        CHECK(access->store_exclusive(access->state,0x70b230,4,9,&exclusiveResult)==Returned&&exclusiveResult==1);
        CHECK(access->swap(access->state,0x70b230,4,11,&old)==Returned&&old==7);
        CHECK(GuestReadU32(disabledVM,0x70b230)==11);
        read=0xfeedface;CHECK(!access->read(access->state,0x70bfff,&read,4)&&read==0xfeedface);
        CHECK(!access->write(access->state,0x5794c,&word,4));
        CHECK(![GuestExecutionDiagnostics(disabledVM)[@"memory_diagnostics_enabled"] boolValue]);
        GuestUnlock(disabledVM);Dispose(disabledVM);
    }
    CHECK(setenv("AS6_NATIVE_MEMORY_DIAGNOSTICS","1",1)==0);
    NSError *error=nil;auto *vm=GuestVMCreateNative(&watchProvider,&error);CHECK(vm&&!error);GuestLock(vm);
    const uint32_t game=0x28000100;
    CHECK(GuestFill(vm,0x28000000,4096));GuestWriteU32(vm,game,0x717040);
    GuestSetPC(vm,0x1bdc4);GuestWriteU32(vm,0x70b230,game);
    auto watch=[&] {return GuestExecutionDiagnostics(vm)[@"game_vptr_write_watch"];};
    auto count=[&] {return [watch()[@"observed_events"] unsignedLongLongValue];};
    CHECK([watch()[@"current_game"] unsignedIntValue]==game&&count()==2);
    CHECK([watch()[@"retained_events"][1][@"kind"] isEqual:@"published-header"]);
    CHECK([watch()[@"retained_events"][1][@"new"] unsignedIntValue]==0x717040);
    auto &state=*GuestNativeCPUState(vm);auto &c=state.context();const auto saved=state.save();
    const auto snapshotReference=GuestExecutionDiagnostics(vm);
    const auto resultReference=GuestLastExecutionResult(vm);
    const auto takesBeforeSnapshot=snapshotCpuTakes;
    const auto snapshotBefore=state.save();errno=E2BIG;
    CHECK(GuestDiagnosticSnapshotLockHeld(vm));
    CHECK([GuestExecutionDiagnosticsLocked(vm) isEqual:snapshotReference]);
    CHECK(GuestLastExecutionResultLocked(vm)==resultReference);
    CHECK(snapshotCpuTakes==takesBeforeSnapshot&&errno==E2BIG);
    const auto snapshotAfter=state.save();
    CHECK(snapshotBefore.registers==snapshotAfter.registers&&snapshotBefore.pc==snapshotAfter.pc&&
        snapshotBefore.budget==snapshotAfter.budget&&snapshotBefore.status==snapshotAfter.status&&
        snapshotBefore.fault_address==snapshotAfter.fault_address);
    GuestUnlock(vm);const auto takesWithoutLock=snapshotCpuTakes;
    CHECK(!GuestDiagnosticSnapshotLockHeld(vm));
    CHECK([GuestExecutionDiagnosticsLocked(vm) count]==0);
    CHECK(GuestLastExecutionResultLocked(vm)==GuestExecutionInvalidState&&snapshotCpuTakes==takesWithoutLock);
    GuestLock(vm);

    uint32_t word=0x71702c;
    CHECK(c.data_access->write(c.data_access->state,game,&word,4)&&GuestReadU32(vm,game)==word);
    CHECK([watch()[@"retained_events"][2][@"source"] isEqual:@"native"]);
    CHECK(!c.data_access->write(c.data_access->state,0x8010,&word,4)&&count()==3);
    uint64_t old=0;uint32_t status=99;
    CHECK(c.data_access->load_exclusive(c.data_access->state,game,4,&old)==Returned&&old==word);
    CHECK(c.data_access->store_exclusive(c.data_access->state,game,4,0x717040,&status)==Returned&&status==0);
    CHECK(GuestReadU32(vm,game)==0x717040&&count()==4);
    CHECK(c.data_access->store_exclusive(c.data_access->state,game+1,4,0,&status)==Returned&&status==1&&count()==4);
    CHECK(c.data_access->load_exclusive(c.data_access->state,game,4,&old)==Returned);
    GuestWriteU32(vm,game,0x71702c);const auto afterHost=count();
    CHECK(c.data_access->store_exclusive(c.data_access->state,game,4,0,&status)==Returned&&status==1&&count()==afterHost);
    CHECK(c.data_access->clear_exclusive(c.data_access->state)==Returned);
    CHECK(c.data_access->barrier(c.data_access->state,15)==Returned);
    CHECK(c.data_access->swap(c.data_access->state,game,4,0x717040,&old)==Returned&&old==0x71702c);
    const auto beforeFault=count();old=0xfeedface;
    CHECK(c.data_access->swap(c.data_access->state,game+1,4,0,&old)==MemoryFault&&old==0xfeedface&&count()==beforeFault);
    uint32_t bulk[3]{};current="_watch_fixture_bulk";GuestSetPC(vm,0x1800);GuestSetReg(vm,14,0x12345678);
    CHECK(GuestWrite(vm,game-4,bulk,sizeof(bulk))&&GuestReadU32(vm,game)==0);
    NSDictionary *first=watch()[@"first_zero"];
    CHECK([first[@"old"] unsignedIntValue]==0x717040&&[first[@"new"] unsignedIntValue]==0);
    CHECK([first[@"pc"] unsignedIntValue]==0x1800&&[first[@"lr"] unsignedIntValue]==0x12345678);
    CHECK([first[@"source"] isEqual:@"host"]&&[first[@"hle"] isEqual:@"_watch_fixture_bulk"]);
    CHECK([watch()[@"first_nonzero_to_zero"] isEqual:first]);
    for(unsigned i=0;i<40;++i)GuestWriteU32(vm,game,i&1?0x717040:0x71702c);
    CHECK([watch()[@"retained_events"] count]==32&&[watch()[@"first_zero"] isEqual:first]);
    // Observer callbacks themselves do not alter architectural CPU storage.
    CHECK(state.restore(saved));const auto before=state.save();word=0x717040;
    CHECK(c.data_access->write(c.data_access->state,game,&word,4));const auto after=state.save();
    CHECK(before.registers==after.registers&&before.pc==after.pc&&before.budget==after.budget&&
        before.status==after.status&&before.fault_address==after.fault_address);
    GuestSetPC(vm,0x1bb9c);CHECK(c.data_access->write(c.data_access->state,game,&word,4));
    // Title observation consumes only the original backend's successful read
    // output; failed/unrelated reads and all CPU storage remain untouched.
    const uint32_t menu=game+0x200;uint8_t loading=1,loaded=99;
    GuestWrite(vm,menu+0x12f,&loading,1);GuestWriteU32(vm,menu+0x130,2);
    auto title=[&]{return GuestExecutionDiagnostics(vm)[@"title_input_observation"];};
    GuestSetPC(vm,0x10c2b4);const auto readBefore=state.save();
    CHECK(c.data_access->read(c.data_access->state,menu+0x12f,&loaded,1)&&loaded==1);
    const auto readAfter=state.save();CHECK(readBefore.registers==readAfter.registers&&readBefore.pc==readAfter.pc&&readBefore.budget==readAfter.budget&&readBefore.status==readAfter.status);
    CHECK([title()[@"state"] unsignedIntValue]==menu&&[title()[@"loading_known"] boolValue]&&[title()[@"loading"] unsignedIntValue]==1);
    loaded=99;CHECK(!c.data_access->read(c.data_access->state,0x8010,&loaded,1)&&loaded==99);
    CHECK([title()[@"retained_changes"] count]==1);
    GuestSetPC(vm,0x10612c);uint32_t stage=0;
    CHECK(c.data_access->read(c.data_access->state,menu+0x130,&stage,4)&&stage==2);
    CHECK([title()[@"stage_known"] boolValue]&&[title()[@"stage"] unsignedIntValue]==2);
    CHECK(c.data_access->read(c.data_access->state,menu+0x130,&stage,4)&&[title()[@"retained_changes"] count]==2);
    GuestSetPC(vm,0x5727c);uint32_t literal=123;
    CHECK(c.data_access->read(c.data_access->state,0x5794c,&literal,4)&&literal==0);
    CHECK(c.data_access->read(c.data_access->state,0x5794c,&literal,4)&&[title()[@"swf_update_reads"] unsignedLongLongValue]==2);
    CHECK(c.data_access->read(c.data_access->state,0x8000,&literal,4)&&[title()[@"swf_update_reads"] unsignedLongLongValue]==2);
    GuestSetPC(vm,0x57280);CHECK(c.data_access->read(c.data_access->state,0x5794c,&literal,4)&&[title()[@"swf_update_reads"] unsignedLongLongValue]==2);
    loading=0;GuestSetPC(vm,0x10658c);CHECK(c.data_access->write(c.data_access->state,menu+0x12f,&loading,1));
    stage=0;GuestSetPC(vm,0x106590);CHECK(c.data_access->write(c.data_access->state,menu+0x130,&stage,4));
    CHECK([title()[@"loading"] unsignedIntValue]==0&&[title()[@"stage"] unsignedIntValue]==0&&[title()[@"retained_changes"] count]==5);
    // The independent PNG log advances during native memory callbacks even
    // without a main-loop JSON heartbeat, and never rewrites input bytes.
    NSString *pngPath=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"as6-png-progress-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    errno=EDOM;
    CHECK(GuestConfigurePNGProgressFile(vm,pngPath.fileSystemRepresentation));
    CHECK(errno==EDOM);
    const uint32_t rowinfo=game+0x500;GuestWriteU32(vm,rowinfo+4,1024);
    GuestSetPC(vm,0x37f330);uint32_t rowbytes=0;
    errno=ERANGE;
    CHECK(c.data_access->read(c.data_access->state,rowinfo+4,&rowbytes,4)&&rowbytes==1024);
    CHECK(errno==ERANGE);
    GuestSetPC(vm,0x37f344);uint8_t pixel=0;
    const auto pngBefore=state.save();
    bool pixelsReadable=true;
    for(unsigned i=0;i<4096;++i)if(!c.data_access->read(c.data_access->state,game,&pixel,1))pixelsReadable=false;
    CHECK(pixelsReadable);
    const auto pngAfter=state.save();
    CHECK(pngBefore.registers==pngAfter.registers&&pngBefore.pc==pngAfter.pc&&pngBefore.budget==pngAfter.budget&&pngBefore.status==pngAfter.status);
    NSString *pngLines=[NSString stringWithContentsOfFile:pngPath encoding:NSUTF8StringEncoding error:nil];
    NSArray *lines=[pngLines componentsSeparatedByString:@"\n"];CHECK(lines.count==4);
    NSDictionary *rowRecord=[NSJSONSerialization JSONObjectWithData:[lines[1] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSDictionary *iterationRecord=[NSJSONSerialization JSONObjectWithData:[lines[2] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    CHECK([rowRecord[@"kind"] isEqual:@"row"]&&[rowRecord[@"rowbytes"] unsignedIntValue]==1024&&[rowRecord[@"rows"] unsignedIntValue]==1);
    CHECK([iterationRecord[@"kind"] isEqual:@"filter-progress"]&&[iterationRecord[@"filter_iterations"] unsignedIntValue]==4096);
    // Sparse SWF progress uses the same successful original read and independent
    // descriptor, preserving both architectural storage and the caller's errno.
    GuestSetPC(vm,0x5727c);const auto swfBefore=state.save();errno=EILSEQ;
    CHECK(c.data_access->read(c.data_access->state,0x5794c,&literal,4)&&
          c.data_access->read(c.data_access->state,0x5794c,&literal,4)&&errno==EILSEQ);
    const auto swfAfter=state.save();
    CHECK(swfBefore.registers==swfAfter.registers&&swfBefore.pc==swfAfter.pc&&swfBefore.budget==swfAfter.budget&&swfBefore.status==swfAfter.status);
    NSArray *swfLines=[[NSString stringWithContentsOfFile:pngPath encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
    NSDictionary *swfRecord=[NSJSONSerialization JSONObjectWithData:[swfLines[4] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    CHECK(swfLines.count==6&&[swfRecord[@"kind"] isEqual:@"swf-update"]&&[swfRecord[@"swf_updates"] unsignedLongLongValue]==4);
    // Only the test's temporary log descriptor is invalidated. A real failed
    // record write/close must not leak EBADF into the emulated caller's errno.
    int pngDescriptor=-1;char descriptorPath[MAXPATHLEN]{};
    const NSString *resolvedPNG=pngPath.stringByResolvingSymlinksInPath;
    for(int fd=0;fd<getdtablesize();++fd){
        if(fcntl(fd,F_GETPATH,descriptorPath)==0&&
           [resolvedPNG isEqual:[NSString stringWithUTF8String:descriptorPath].stringByResolvingSymlinksInPath]){pngDescriptor=fd;break;}
    }
    CHECK(pngDescriptor>=0&&::close(pngDescriptor)==0);
    GuestSetPC(vm,0x37f330);errno=E2BIG;
    CHECK(c.data_access->read(c.data_access->state,rowinfo+4,&rowbytes,4)&&rowbytes==1024);
    CHECK(errno==E2BIG);
    NSDictionary *pngDiagnostics=GuestExecutionDiagnostics(vm)[@"png_progress_observation"];
    CHECK([pngDiagnostics[@"io_failed"] boolValue]&&![pngDiagnostics[@"file_open"] boolValue]);
    errno=EINTR;
    CHECK(!GuestConfigurePNGProgressFile(vm,"/as6-no-such-directory/png-progress"));
    CHECK(errno==EINTR);
    CHECK([[NSFileManager defaultManager] removeItemAtPath:pngPath error:nil]);
    CHECK(!GuestHasStopRequest(vm));current.clear();GuestUnlock(vm);Dispose(vm);
    // A zero header at publication is a separate snapshot; it must not hide
    // a later first nonzero-to-zero write after the ordinary log is full.
    error=nil;vm=GuestVMCreateNative(&watchProvider,&error);CHECK(vm&&!error);GuestLock(vm);
    CHECK(GuestFill(vm,0x28000000,4096));GuestWriteU32(vm,0x70b230,game);
    CHECK([watch()[@"first_zero"][@"kind"] isEqual:@"published-header"]);
    CHECK(!watch()[@"first_nonzero_to_zero"]);
    for(unsigned i=0;i<40;++i)GuestWriteU32(vm,game,i&1?0x717040:0x71702c);
    GuestWriteU32(vm,game,0);
    CHECK([watch()[@"retained_events"] count]==32);
    CHECK([watch()[@"first_nonzero_to_zero"][@"old"] unsignedIntValue]==0x717040);
    CHECK([watch()[@"first_nonzero_to_zero"][@"new"] unsignedIntValue]==0);
    CHECK([watch()[@"first_nonzero_to_zero"][@"kind"] isEqual:@"header"]);
    CHECK(!GuestHasStopRequest(vm));GuestUnlock(vm);Dispose(vm);
}
int main() {
    @autoreleasepool {
        InvalidManifests();
        NativeDefinitions();
        GameWriteObservation();
        // A long native callback resumes across scheduler slices without
        // reducing its total budget or losing caller state. Interleaved data
        // writes survive the context handoff, as on the real scheduler.
        {
            GuestVM *scheduled=Make();GuestLock(scheduled);
            GuestSetReg(scheduled,0,25000);GuestSetReg(scheduled,1,0x51554e54);
            GuestSetReg(scheduled,14,StopAddress);requestAudioService=true;
            errno=E2BIG;
            CHECK(GuestEmulate(scheduled,0x1014,StopAddress,50000)==GuestExecutionSuccess);
            requestAudioService=false;
            CHECK(errno==E2BIG&&schedulingHandoffs>0);
            CHECK(GuestReg(scheduled,0)==0&&GuestReg(scheduled,1)==0x51554e54);
            CHECK(GuestNativeCPUState(scheduled)->context().budget==25000);
            CHECK(GuestReadU32(scheduled,0x8000)==0x12345678);
            CHECK(!GuestExecutionDiagnostics(scheduled)[@"first_native_failure"]);
            GuestUnlock(scheduled);Dispose(scheduled);
        }
        for(unsigned failure:{1u,2u}){
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
            GuestVM *scheduled=Make();GuestLock(scheduled);
            GuestSetReg(scheduled,0,11);GuestSetReg(scheduled,1,31);
            GuestSetReg(scheduled,14,StopAddress);
            const auto before=schedulingHandoffs;
            schedulingFailure=failure;requestAudioService=true;
            const auto status=GuestEmulate(scheduled,0x1800,StopAddress,20);
            requestAudioService=false;schedulingFailure=0;
            CHECK(schedulingHandoffs==before+1);
            CHECK(status==(failure==1?GuestExecutionInvalidState:GuestExecutionHalted));
            GuestUnlock(scheduled);Dispose(scheduled);
        }
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(3));
            GuestVM *scheduled=Make();GuestLock(scheduled);
            const auto saved=GuestNativeCPUState(scheduled)->save();
            const uint32_t args[]={11,31};
            schedulingFailure=3;requestAudioService=false;
            CHECK(GuestCall(scheduled,0x1800,args,2,20)==0);
            CHECK(GuestLastExecutionResult(scheduled)==GuestExecutionCancelled);
            CHECK(!GuestHasStopRequest(scheduled));
            const auto after=GuestNativeCPUState(scheduled)->save();
            CHECK(saved.registers==after.registers&&saved.pc==after.pc&&saved.budget==after.budget);
            requestAudioService=false;schedulingFailure=0;schedulingCancelled=false;
            CHECK(GuestCall(scheduled,0x1000,args,2,20)==42);
            GuestUnlock(scheduled);Dispose(scheduled);
        }
        bridges=0;polls=0;
        GuestVM *vm=Make(); GuestLock(vm);
        uint32_t value=0xffffffff;CHECK(GuestRead(vm,0x8000,&value,4)&&value==9);
        value=0xfeedface;CHECK(!GuestRead(vm,0x8004,&value,4)&&value==0xfeedface);
        CHECK(!GuestRead(vm,0x1000,&value,4));
        CHECK(!GuestWrite(vm,0x8004,&value,4));
        CHECK(GuestHLEAddress(vm,"_native_add")==0x1800);
        CHECK(GuestHLEAddress(vm,"_unknown")==0);
        CHECK(!GuestRead(vm,0x1800,&value,4));
        NSError *error=nil; CHECK(!GuestVMLoadMachO(vm,@"/not-opened-original",&error));
        CHECK(error.code==GuestExecutionUnsupportedSemantics);
        CHECK(GuestSectionContains(vm,"__data",0x8003)&&!GuestSectionContains(vm,"__data",0x8004));
        CHECK(vm.textBase==0&&vm.textSize==0);
        auto at=GuestWriteCString(vm,@"arm64");CHECK(at&&[GuestReadCString(vm,at,16) isEqualToString:@"arm64"]);
        auto copy=GuestAlloc(vm,16);CHECK(GuestStrCopy(vm,copy,at,16)==6);
        CHECK([GuestReadCString(vm,copy,16) isEqualToString:@"arm64"]);
        CHECK(!GuestFill(vm,0x8004,4)&&!GuestFill(vm,0xfffffff0,32));
        CHECK(GuestFill(vm,0x28000000,4096));
        uint32_t args[]={11,31};auto saved=GuestNativeCPUState(vm)->save();
        CHECK(GuestCall(vm,0x1000,args,2,20)==42);
        auto after=GuestNativeCPUState(vm)->save();
        CHECK(saved.registers==after.registers&&saved.pc==after.pc&&saved.budget==after.budget&&saved.status==after.status);
        CHECK(GuestReadU32(vm,0x8000)==42);
        CHECK(GuestCall(vm,0x1021,args,2,20)==42);
        CHECK(GuestCall(vm,0x1004,args,2,20)==42&&bridges==1&&polls==1);
        CHECK(GuestCall(vm,0x180c,nullptr,0,20)==42&&nested==1);
        CHECK(GuestCall(vm,0x1810,nullptr,0,20)==71);
        // Host bridge writes share the exclusive-memory owner.
        auto &c=GuestNativeCPUState(vm)->context();uint64_t old=0;uint32_t status=77;
        CHECK(c.data_access->load_exclusive(c.data_access->state,0x8000,4,&old)==Returned);
        GuestWriteU32(vm,0x8000,19);
        CHECK(c.data_access->store_exclusive(c.data_access->state,0x8000,4,99,&status)==Returned&&status==1);
        CHECK(GuestReadU32(vm,0x8000)==19);
        CHECK(c.data_access->swap!=nullptr);
        old=0;CHECK(c.data_access->swap(c.data_access->state,0x8000,4,29,&old)==Returned&&old==19);
        CHECK(GuestReadU32(vm,0x8000)==29);
        GuestSetReg(vm,0,5);GuestSetReg(vm,1,7);GuestSetReg(vm,14,StopAddress);
        CHECK(GuestEmulate(vm,0x1014,StopAddress,2)==GuestExecutionBudgetExhausted);
        CHECK(!GuestExecutionDiagnostics(vm)[@"first_native_failure"]);
        CHECK(GuestEmulate(vm,0x1000,StopAddress,20)==GuestExecutionSuccess&&GuestReg(vm,0)==12);
        CHECK(GuestTryLock(vm));CHECK(GuestSuspendLocks(vm)==2);GuestResumeLocks(vm,2);GuestUnlock(vm);
        GuestUnlock(vm);Dispose(vm);
        vm=Make();GuestLock(vm);
        CHECK(GuestEmulate(vm,0x100c,StopAddress,20)==GuestExecutionUnresolvedTarget);
        CHECK(GuestEmulate(vm,0x1000,StopAddress,20)==GuestExecutionInvalidState);
        GuestUnlock(vm);Dispose(vm);
        vm=Make();GuestLock(vm);
        CHECK(GuestEmulate(vm,0x1010,StopAddress,20)==GuestExecutionMemoryFault);
        GuestUnlock(vm);Dispose(vm);
        // Persist the faulting callback state before restoring the caller.
        vm=Make();GuestLock(vm);GuestSetPC(vm,0x1814);GuestSetReg(vm,2,0x12345678);
        CHECK(GuestCall(vm,0x1010,nullptr,0,20)==0);
        CHECK(GuestPC(vm)==0x1814&&GuestLastExecutionResult(vm)==GuestExecutionMemoryFault);
        NSDictionary *failure=GuestExecutionDiagnostics(vm)[@"first_native_failure"];
        CHECK([failure[@"pc"] unsignedIntValue]==0x1010&&[failure[@"fault_address"] unsignedIntValue]==0x8010);
        CHECK([failure[@"native_status"] unsignedIntValue]==MemoryFault&&[failure[@"registers"] count]==16);
        CHECK([failure[@"registers"][2] unsignedIntValue]==0x12345678);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&[GuestExecutionDiagnostics(vm)[@"first_native_failure"] isEqual:failure]);
        GuestUnlock(vm);Dispose(vm);
        // Both an absent compiled target and an unavailable host bridge must
        // preserve their failing callback state before GuestCall restores its
        // caller's registers. Neither case may acquire a made-up target.
        for(const uint32_t callback:{0x100cu,0x1804u}) {
            vm=Make();GuestLock(vm);GuestSetPC(vm,0x1814);GuestSetReg(vm,2,0x89abcdef);GuestSetReg(vm,14,0x12345678);
            CHECK(GuestNativeCPUState(vm)->set_cpsr(0xa80f0010));
            CHECK(GuestCall(vm,callback,nullptr,0,20)==0);
            CHECK(GuestPC(vm)==0x1814&&GuestReg(vm,14)==0x12345678);
            CHECK(GuestLastExecutionResult(vm)==GuestExecutionUnresolvedTarget);
            failure=GuestExecutionDiagnostics(vm)[@"first_native_failure"];
            const uint32_t failedPC=callback==0x100c?0x4444:0x1804;
            CHECK([failure[@"native_status"] unsignedIntValue]==UnresolvedTarget);
            CHECK([failure[@"pc"] unsignedIntValue]==failedPC&&![failure[@"thumb"] boolValue]);
            CHECK([failure[@"registers"] count]==16&&[failure[@"registers"][15] unsignedIntValue]==failedPC);
            CHECK([failure[@"registers"][14] unsignedIntValue]==StopAddress&&[failure[@"registers"][2] unsignedIntValue]==0x89abcdef);
            CHECK([failure[@"cpsr"] unsignedIntValue]==0xa80f0010&&[failure[@"remaining_budget"] unsignedLongLongValue]==19);
            CHECK([failure[@"fault_address"] unsignedIntValue]==0);
            CHECK(GuestCall(vm,0x1000,args,2,20)==0&&[GuestExecutionDiagnostics(vm)[@"first_native_failure"] isEqual:failure]);
            GuestUnlock(vm);Dispose(vm);
        }
        // Count only original initializer invocations that actually return.
        const std::uint32_t diagnosticInitializers[]={0x1000,0x1000};
        auto diagnosticData=data;diagnosticData.initializers=diagnosticInitializers;diagnosticData.initializer_count=2;
        auto diagnosticProvider=provider;diagnosticProvider.data=&diagnosticData;
        error=nil;vm=GuestVMCreateNative(&diagnosticProvider,&error);CHECK(vm&&!error);
        GuestRunModInitFuncs(vm);NSDictionary *diagnostics=GuestExecutionDiagnostics(vm);
        CHECK([diagnostics[@"initializers_completed"] unsignedIntValue]==2&&[diagnostics[@"initializers_total"] unsignedIntValue]==2&&[diagnostics[@"initializers_finished"] boolValue]);
        GuestRunModInitFuncs(vm);CHECK([GuestExecutionDiagnostics(vm) isEqual:diagnostics]);Dispose(vm);
        vm=Make();GuestLock(vm);
        CHECK(GuestEmulate(vm,0x1804,StopAddress,20)==GuestExecutionUnresolvedTarget);
        CHECK(GuestUnimplementedCount(vm)==1);GuestUnlock(vm);Dispose(vm);
        vm=Make();GuestLock(vm);
        GuestCpuSnapshot *snap=nullptr;CHECK(GuestCPUAllocate(vm,&snap)==GuestExecutionSuccess&&GuestCPUSave(vm,snap)==GuestExecutionSuccess);
        CHECK(GuestEmulate(vm,0x1808,StopAddress,20)==GuestExecutionHalted);
        CHECK(GuestCPURestore(vm,snap)==GuestExecutionSuccess);
        CHECK(GuestEmulate(vm,0x1000,StopAddress,20)==GuestExecutionHalted);
        GuestCPUFree(snap);GuestUnlock(vm);Dispose(vm);
        vm=Make();CHECK(GuestCall(vm,0x1014,nullptr,0,1)==0);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionBudgetExhausted);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&GuestLastExecutionResult(vm)==GuestExecutionInvalidState);Dispose(vm);
        // UI handoff finishes the entry invocation, then timers/delegates may
        // enter compiled native game code without clearing a permanent latch.
        vm=Make();GuestLock(vm);error=nil;
        CHECK(GuestVMRun(vm,0x1814,0x10,20,&error)&&!error);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionYielded);
        CHECK(GuestPC(vm)==0x1814);
        CHECK(GuestCall(vm,0x1000,args,2,20)==42);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionSuccess);
        CHECK(GuestPC(vm)==0x1814);
        CHECK(GuestCall(vm,0x1021,args,2,20)==42);
        GuestRequestHalt(vm);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&GuestLastExecutionResult(vm)==GuestExecutionHalted);
        GuestUnlock(vm);Dispose(vm);
        // A nested callback must return normally; it cannot hide truncation
        // by requesting the entry-only UI handoff.
        vm=Make();CHECK(GuestCall(vm,0x1814,nullptr,0,20)==0);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionInvalidState);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&GuestLastExecutionResult(vm)==GuestExecutionInvalidState);
        Dispose(vm);
        // Checked byte probes can reject a hole without changing VM state.
        // The word convenience API must latch failure so no later native
        // callback can treat its zero return as an original memory value.
        vm=Make();GuestLock(vm);snap=nullptr;
        CHECK(GuestCPUAllocate(vm,&snap)==GuestExecutionSuccess&&GuestCPUSave(vm,snap)==GuestExecutionSuccess);
        value=0xabcdef01;CHECK(!GuestRead(vm,0x8004,&value,4)&&value==0xabcdef01);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionSuccess);
        CHECK(GuestReadU32(vm,0x8004)==0&&GuestLastExecutionResult(vm)==GuestExecutionMemoryFault);
        CHECK(GuestCPURestore(vm,snap)==GuestExecutionSuccess);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&GuestLastExecutionResult(vm)==GuestExecutionInvalidState);
        CHECK(GuestReadU32(vm,0x8000)==9);
        GuestCPUFree(snap);GuestUnlock(vm);Dispose(vm);
        vm=Make();GuestLock(vm);snap=nullptr;
        CHECK(GuestCPUAllocate(vm,&snap)==GuestExecutionSuccess&&GuestCPUSave(vm,snap)==GuestExecutionSuccess);
        GuestWriteU32(vm,0x8004,0xabcdef01);
        CHECK(GuestLastExecutionResult(vm)==GuestExecutionMemoryFault);
        CHECK(!GuestRead(vm,0x8004,&value,4));
        CHECK(GuestCPURestore(vm,snap)==GuestExecutionSuccess);
        CHECK(GuestCall(vm,0x1000,args,2,20)==0&&GuestLastExecutionResult(vm)==GuestExecutionInvalidState);
        CHECK(GuestReadU32(vm,0x8000)==9);
        GuestCPUFree(snap);GuestUnlock(vm);Dispose(vm);
        printf("{\"passed\":true,\"checks\":%u,\"provider\":\"genuine compiled tiny test functions only\",\"game_execution\":false}\n",checks);
    }
}

// Empty-binding fixture adapters: yield regression tests no image binding.
extern "C" BOOL HLEObjectConstantAddress(GuestVM*,const char*,uint32_t*) {return NO;}
extern "C" BOOL HLEDataAddress(GuestVM*,const char*,uint32_t*) {return NO;}
extern "C" uint32_t HLEDataValue(GuestVM*,const char*,uint32_t) {return 0;}
extern "C" void *HLEUnwrapOpaque(GuestVM*,uint32_t) {return nullptr;}
extern "C" Class GuestObjCUnwrapClass(GuestVM*,gva_t) {return Nil;}
extern "C" GuestUnsafeId GuestObjCUnwrap(GuestVM*,gva_t) {return nil;}
extern "C" BOOL GuestObjCBuildRegistryForBinding(GuestVM*,NSString**) {return YES;}
