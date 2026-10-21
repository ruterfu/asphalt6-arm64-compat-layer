#import "GuestVM.h"
#import "GuestNativeProvider.hpp"
#import "GuestLocalClassRegistry.hpp"
#import "GuestObjC.h"
#import "HLE.h"
#import "HLE_media.h"
#import "NativeDataBundle.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>

using namespace as6native;using namespace as6aot;
static unsigned checks,registry_checks;
#define CHECK(x) do{++checks;assert(x);}while(0)
static Status Tiny(Context &,bool,std::uint32_t,bool){return Returned;}
static NativeFunction Lookup(std::uint32_t pc,bool thumb){return pc==0x1000&&!thumb?Tiny:nullptr;}
static const NativeModule modules[]={{0x2000,0x2000,Lookup}};
static const NativeProgram program(modules,1,layout::Size,layout::pc);
static std::map<std::string,HLEImpl> &Implementations(){static std::map<std::string,HLEImpl> value;return value;}
static std::map<std::uint32_t,void*> classes;
static NSMutableDictionary<NSNumber*,id> *objects;
static std::map<std::string,std::uint32_t> localClasses;
static std::string current;
extern "C" BOOL GuestLoaderDeclaredSection(GuestVM*,const char*,std::uint32_t*,std::uint32_t*);
extern "C" void HLERegister(const char *name,HLEImpl fn){Implementations()[name]=fn;}
extern "C" HLEImpl HLELookup(const char *name){auto at=Implementations().find(name?name:"");return at==Implementations().end()?nullptr:at->second;}
extern "C" void HLESetCurrentSymbol(const char *name){current=name?name:"";}
extern "C" const char *HLECurrentSymbol(){return current.c_str();}
extern "C" void HLEPthreadTakeCPU(GuestVM*){}
extern "C" BOOL GuestAudioProducerNeedsService(void){return NO;}
extern "C" int GuestAudioWaitForProducerTurn(void){return 0;}
extern "C" BOOL GuestAudioProducerWasCancelled(GuestVM*){return NO;}
extern "C" void AS6SystemZlibForgetVM(GuestVM*){}
extern "C" int HLEPthreadBlockingCall(GuestVM*,int (*operation)(void*),void *opaque){return operation(opaque);}
extern "C" void HLEPosixPoll(GuestVM*){}
extern "C" void HLERecordNeeded(NSString*){}
extern "C" Class GuestMediaSubstituteClass(const char*){return Nil;}
extern "C" NSString *GuestMediaStringConstant(const char*){return nil;}
extern "C" gva_t GuestObjCWrapClass(GuestVM*,Class cls){if(!cls)return 0;for(auto row:classes)if(row.second==(__bridge void*)cls)return row.first;auto at=0xe0000000u+unsigned(classes.size())*4;classes[at]=(__bridge void*)cls;return at;}
extern "C" Class GuestObjCUnwrapClass(GuestVM*,gva_t at){auto row=classes.find(at);return row==classes.end()?Nil:(__bridge Class)row->second;}
extern "C" gva_t GuestObjCWrap(GuestVM*,GuestUnsafeId object){if(!object)return 0;if(!objects)objects=[NSMutableDictionary new];gva_t at=0xe0800000u+unsigned(objects.count)*4;objects[@(at)]=object;return at;}
extern "C" GuestUnsafeId GuestObjCUnwrap(GuestVM*,gva_t at){return objects[@(at)];}
extern "C" gva_t GuestObjCClassNamed(GuestVM*,NSString *name){auto found=localClasses.find(name.UTF8String?:"");return found==localClasses.end()?0:found->second;}
extern "C" BOOL GuestObjCBuildRegistryForBinding(GuestVM *vm,NSString **failure){
    CHECK(!vm.loaded&&GuestSectionAddress(vm,"__fixture")==0);
    std::vector<LocalClassRecord> records;std::string error;
    std::uint32_t list=0,size=0;GuestLoaderDeclaredSection(vm,"__objc_classlist",&list,&size);
    const bool ok=CollectLocalClasses(list,size,
        [&](std::uint32_t at,void *out,std::size_t n){return bool(GuestRead(vm,at,out,n));},
        [&](std::uint32_t at,std::size_t n,std::string &out){NSString *s=GuestReadCString(vm,at,n);if(!s)return false;out=s.UTF8String;return true;},records,error);
    if(!ok){if(failure)*failure=[NSString stringWithUTF8String:error.c_str()];return NO;}
    localClasses.clear();for(auto row:records)localClasses[row.name]=row.address;
    ++registry_checks;return YES;
}
// These optional unrelated data helpers are absent from this macOS fixture.
// The actual HLE_auto and HLE_stdcxx implementations are linked below.
BOOL GuestCgDataValue(GuestVM*,const char*,std::uint32_t*){return NO;}
BOOL GuestCFDataValue(GuestVM*,const char*,std::uint32_t*){return NO;}
BOOL GuestCTypeDataValue(GuestVM*,const char*,std::uint32_t*){return NO;}
BOOL GuestStdioDataValue(GuestVM*,const char*,std::uint32_t*){return NO;}
BOOL GuestPlatformScalarDataValue(GuestVM*,const char*,std::uint32_t*){return NO;}
extern "C" gva_t GuestHeapAlloc(GuestVM *vm,std::size_t n){return GuestAlloc(vm,n?n:1);}
extern "C" BOOL GuestHeapFree(GuestVM*,gva_t){return NO;}
extern "C" BOOL GuestHeapOwns(GuestVM*,gva_t){return NO;}

static std::array<std::uint8_t,512> seed;
static DataRegion regions[]={{0x8000,4096,3},{0x9000,4096,1}};
static DataSpan spans[]={{0x8000,seed.size(),seed.data(),DataKind::WritableBytes}};
static Section sections[]={{"__objc_classlist",0x8000,4},{"__fixture",0x8000,0x218},{"__ro_bound",0x9000,4}};
static BindingSource sources[]={
    {0x8200,"_NSDefaultRunLoopMode",0,1,0,1},{0x8204,"__ZTVSt15basic_streambufIcSt11char_traitsIcEE",8,1,0,1},
    {0x8208,"_OBJC_CLASS_$_LocalTest",0,1,0,1},{0x820c,"_OBJC_METACLASS_$_NSObject",0,1,0,1},
    {0x8210,"__ZNSs4_Rep20_S_empty_rep_storageE",0,1,0,1},{0x8214,"_unit_static",0,0,0,2},{0x9000,"_unit_ro",0,0,0,2},
};
static DataBinding bindings[]={
    {0x8200,BindingKind::ObjectConstant,"_NSDefaultRunLoopMode",0,0,0,0,1},
    {0x8204,BindingKind::DataAddress,"__ZTVSt15basic_streambufIcSt11char_traitsIcEE",8,0,8,1,1},
    {0x8208,BindingKind::ObjCClass,"_OBJC_CLASS_$_LocalTest",0,0,0,2,1},
    {0x820c,BindingKind::ObjCMetaclass,"_OBJC_METACLASS_$_NSObject",0,0,0,3,1},
    {0x8210,BindingKind::SystemData,"__ZNSs4_Rep20_S_empty_rep_storageE",0,0,0,4,1},
    {0x8214,BindingKind::StaticValue,"_unit_static",0x1234,0x1234,0,5,1},
    {0x9000,BindingKind::StaticValue,"_unit_ro",0x10203040,0x10203040,0,6,1},
};
static DataManifest data{ProviderVersion,regions,2,spans,1,sections,3,nullptr,0,0x3ffef000,bindings,7,sources,7};
static Provider provider;
extern "C" const Provider *AS6LinkedNativeProvider(){return &provider;}
static void word(unsigned offset,std::uint32_t value){std::memcpy(seed.data()+offset,&value,4);}
int main(){@autoreleasepool{
    word(0,0x8040);word(0x40,0x8080);word(0x50,0x80a0);word(0xb0,0x8100);std::memcpy(seed.data()+0x100,"LocalTest",10);
    std::size_t n=0;const auto *bridges=AS6GeneratedBridges(&n);
    provider={ProviderVersion,&program,bridges,n,&data,0x1000,"native-binding-fixture-only"};
    NSError *error=nil;GuestVM *vm=GuestVMCreateNative(&provider,&error);
    CHECK(vm&&vm.loaded&&!error&&registry_checks==1&&GuestBindSlotCount(vm)==7);
    CHECK(GuestSectionAddress(vm,"__fixture")==0x8000&&GuestReadU32(vm,0x8214)==0x1234);
    CHECK(GuestReadU32(vm,0x9000)==0x10203040);std::uint32_t v=0;CHECK(!GuestWrite(vm,0x9000,&v,4));
    const auto cell=GuestReadU32(vm,0x8200);id string=GuestObjCUnwrap(vm,GuestReadU32(vm,cell));CHECK([string isEqual:NSDefaultRunLoopMode]);
    CHECK(GuestReadU32(vm,0x8208)==0x8040&&GuestObjCUnwrapClass(vm,GuestReadU32(vm,0x820c))==object_getClass([NSObject class]));
    const auto table=GuestReadU32(vm,0x8204);CHECK(table&&GuestReadU32(vm,table)==GuestHLEAddress(vm,"__as6_cxx_buf_dtor"));
    const auto empty=GuestReadU32(vm,0x8210);CHECK(empty&&GuestRead(vm,empty,&v,4)&&v==0);
    CHECK(GuestHLEAddress(vm,"__as6_cxx_strbuf_underflow")>=0x10000000&&GuestHLEAddress(vm,"__as6_cxx_strbuf_underflow")<0x10100000);
    GuestLock(vm);CHECK(GuestEmulate(vm,GuestHLEAddress(vm,"dyld_stub_binder"),StopAddress,16)==GuestExecutionUnresolvedTarget);GuestUnlock(vm);
    GuestVMDestroy(vm);CHECK(!vm.loaded);
    // A new missing data import fails creation rather than blessing a zero.
    auto missing=bindings[0];auto source=sources[0];missing.symbol="_NoSuchObjectConstant";source.symbol=missing.symbol;
    auto one=data;one.bindings=&missing;one.binding_count=1;one.binding_sources=&source;one.binding_source_count=1;
    Section class_only{"__objc_classlist",0x8000,4};one.sections=&class_only;one.section_count=1;one.region_count=1;
    auto bad=provider;bad.data=&one;
    CHECK(!GuestVMCreateNative(&bad,&error)&&[error.localizedDescription containsString:@"unresolved data bindings"]);
    // A declared class list containing a pending slot is unavailable, not an
    // absent/empty registry. Resolving superclass data cannot hide this cycle.
    const std::uint8_t initial[]={0,0,0,0};DataSpan initial_span{0x8000,4,initial,DataKind::WritableBytes};
    Section deferred_classlist{"__objc_classlist",0x8004,4};
    BindingSource deferred_source{0x8004,"_OBJC_CLASS_$_NSObject",0,1,0,1};
    DataBinding deferred_binding{0x8004,BindingKind::ObjCClass,"_OBJC_CLASS_$_NSObject",0,0,0,0,1};
    DataManifest deferred{ProviderVersion,regions,1,&initial_span,1,&deferred_classlist,1,nullptr,0,0x3ffef000,&deferred_binding,1,&deferred_source,1};
    bad.data=&deferred;
    CHECK(!GuestVMCreateNative(&bad,&error)&&[error.localizedDescription containsString:@"Local class registry is incomplete"]);
    std::printf("{\"passed\":true,\"checks\":%u,\"real_hle_auto_foundation_constant\":true,\"real_hle_stdcxx_vtable_and_empty_rep\":true,\"two_phase_local_class_resolution\":true,\"game_execution\":false}\n",checks);
}}

// No UIKit/original methods execute in this Foundation-only fixture.
extern "C" BOOL GuestObjCSend(GuestVM*,gva_t,gva_t,BOOL){__builtin_trap();}
