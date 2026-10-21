#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>
using gva_t=uint32_t;
constexpr gva_t GUEST_HOST_SEL_BASE=0xf0000000,HOST=0xe0000001,SELECTOR_BASE=0xf0000100;
struct GuestVM {std::array<uint32_t,16>regs{};std::array<uint8_t,4096>memory{};bool stopped=false;};
static GuestVM *activeVM;static id activeTarget;
static bool superControl;
@interface NSObject (FrameControl)
@property(nonatomic) NSRect frame;
@end
#define CGRectMake NSMakeRect
static std::vector<SEL> selectors;
static uint32_t GuestReg(GuestVM*v,unsigned r){return v->regs[r];}
static void GuestSetReg(GuestVM*v,unsigned r,uint32_t w){v->regs[r]=w;}
static uint32_t GuestSP(GuestVM*v){return v->regs[13];}
static bool GuestRead(GuestVM*v,uint32_t a,void*p,size_t n){if(a<0x1000||n>v->memory.size()||a-0x1000>v->memory.size()-n){v->stopped=true;return false;}memcpy(p,v->memory.data()+a-0x1000,n);return true;}
static bool GuestWrite(GuestVM*v,uint32_t a,const void*p,size_t n){if(a<0x1000||n>v->memory.size()||a-0x1000>v->memory.size()-n){v->stopped=true;return false;}memcpy(v->memory.data()+a-0x1000,p,n);return true;}
static uint32_t GuestReadU32(GuestVM*v,uint32_t a){uint32_t w=0;GuestRead(v,a,&w,4);return w;}
static uint32_t GuestArg(GuestVM*v,unsigned n){return n<4?v->regs[n]:GuestReadU32(v,v->regs[13]+4*(n-4));}
static float GuestArgF(GuestVM*v,unsigned n){uint32_t w=GuestArg(v,n);float f;memcpy(&f,&w,4);return f;}
static uint32_t GuestLR(GuestVM*v){return v->regs[14];}
static void GuestSetRet(GuestVM*v,uint32_t w){v->regs[0]=w;}
static bool GuestHasStopRequest(GuestVM*v){return v->stopped;}
static void GuestRequestFault(GuestVM*v){v->stopped=true;}
static bool GuestObjCMetadataWord(uint32_t){return false;}
static bool HostSendTracingEnabled(){return false;}
static bool GuestIsHostObject(uint32_t w){return w==HOST;}
static bool GuestIsHostClass(uint32_t){return false;}
static id GuestObjCUnwrap(GuestVM*,uint32_t){return activeTarget;}
static Class GuestObjCUnwrapClass(GuestVM*,uint32_t){return Nil;}
static SEL GuestObjCSelFromGuest(GuestVM*,uint32_t w){return w>=SELECTOR_BASE&&w-SELECTOR_BASE<selectors.size()?selectors[w-SELECTOR_BASE]:nullptr;}
static uint32_t selWord(SEL s){for(size_t i=0;i<selectors.size();++i)if(selectors[i]==s)return SELECTOR_BASE+uint32_t(i);selectors.push_back(s);return SELECTOR_BASE+uint32_t(selectors.size()-1);}
static NSString *GuestSymbolAt(uint32_t){return @"control";}
static void GuestRawLog(const char*){}
static void GuestTrace(GuestVM*,NSString*,...){}
static NSString *GuestObjCCFString(GuestVM*,uint32_t){return nil;}
static NSObject *GuestObjCShadow(GuestVM*,uint32_t){return superControl?activeTarget:nil;}
static NSString *GuestObjCNameForClass(GuestVM*,uint32_t){return nil;}
static NSString *GuestObjCNameForMetaclass(GuestVM*,uint32_t){return nil;}
struct Registry {std::unordered_map<uint32_t,std::string>classNames;};
static Registry registry;
static Registry &LocalRegistry(GuestVM*){return registry;}
static uint32_t FindGuestMethodImp(GuestVM*,uint32_t,SEL){return 0;}
static uint32_t GuestCall(GuestVM*,uint32_t,const uint32_t*,int,uint64_t){assert(false);return 0;}
static BOOL GuestDeviceOverride(GuestVM*,id,SEL sel){if(sel==@selector(raiseAtDispatch))[NSException raise:@"DispatchControl" format:@"intentional native control"];return NO;}
static BOOL GuestScreenOverride(GuestVM*,id,SEL){return NO;}
static BOOL GuestTimerOverride(GuestVM*,id,SEL){return NO;}
static BOOL GuestMediaOverride(GuestVM*,id,SEL){return NO;}
// Device motion is absent from this Foundation-only aggregate-return fixture.
static BOOL GuestMotionOverride(GuestVM*,id,SEL){return NO;}
static BOOL HostStringBridge(GuestVM*,id,SEL,const char*){return NO;}
@interface PortAutoreleasePool:NSObject @end
@implementation PortAutoreleasePool @end
static std::unordered_map<uint32_t, __unsafe_unretained id>g_objects;
static std::unordered_map<void*,uint32_t>g_objectHandles;
#define UIView NSObject
#define HLE_DEFINE(name) static void name(GuestVM *vm)
BOOL GuestObjCSend(GuestVM*,gva_t,gva_t,BOOL);
BOOL GuestSendToSuperclass(GuestVM*,gva_t,gva_t,Class);
void GuestSetStretDestination(gva_t);
gva_t GuestStretDestination(void);
static BOOL HostSend(GuestVM*,id,SEL,BOOL);

// Foundation-only controls for the real SEND call boundaries. No graphics
// helper implementation is linked or claimed to execute on this host.
#ifndef AS6_MACOS_MOTION_ABSENCE_FIXTURE
#error "These typed graphics-boundary controls are macOS-fixture-only"
#endif
static gva_t fixtureGLView=0;
static unsigned backingCalls=0,warmCalls=0,drawCalls=0;
static bool rejectBacking=false,rejectWarm=false;
static gva_t backingReceiver=0,warmReceiver=0;
static SEL backingSelector=nullptr,warmSelector=nullptr;
static std::vector<unsigned> boundaryOrder;
static gva_t GuestGLView(){return fixtureGLView;}
namespace as6_gameplay_backing {
struct State {};
static bool beforeMessage(GuestVM*,gva_t recv,SEL sel,State&){
 ++backingCalls;backingReceiver=recv;backingSelector=sel;boundaryOrder.push_back(1);return !rejectBacking;
}
}
namespace as6_shared_menu_warm {
struct State {};
static bool beforeMessage(GuestVM*,gva_t recv,SEL sel,State&){
 ++warmCalls;warmReceiver=recv;warmSelector=sel;boundaryOrder.push_back(2);return !rejectWarm;
}
}

// AS6_STRET_STATE
// AS6_STRET_AGGREGATE_HELPERS
// AS6_STRET_SEND
// AS6_STRET_TRAMPOLINE
// AS6_STRET_SUPERCLASS

// Same aggregate-return branch as production, fed by real Foundation
// NSInvocation. Unrelated argument conversions are outside these controls.
static BOOL HostSend(GuestVM *vm,id target,SEL sel,BOOL stret){
 NSMethodSignature *sig=[target methodSignatureForSelector:sel];if(!sig)return NO;
 NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.selector=sel;
 @try{[inv invokeWithTarget:target];}@catch(NSException*){GuestSetRet(vm,0);return YES;}
 const char *retType=sig.methodReturnType;char rbase=retType[0];
 if(rbase=='v')return YES;
 alignas(16)uint8_t retBuf[64]={};NSUInteger retSize=0;NSGetSizeAndAlignment(retType,&retSize,nullptr);assert(retSize&&retSize<=sizeof(retBuf));[inv getReturnValue:retBuf];
 // AS6_STRET_AGGREGATE_RETURN
 uint32_t scalar=0;memcpy(&scalar,retBuf,MIN(retSize,sizeof(scalar)));GuestSetRet(vm,scalar);return YES;
}
HLE_DEFINE(hle_objc_msgSend_stret);
@interface StretFixture:NSObject
@property(nonatomic)unsigned mode;
@property(nonatomic)uint32_t observedBefore,observedAfter;
- (NSRange)plainRange;
- (void)drawView;
- (NSRange)outerRange;
- (uint32_t)scalar;
- (NSRange)throwingRange;
@end
@implementation StretFixture
- (NSRange)plainRange{return NSMakeRange(23,45);}
- (void)drawView{++drawCalls;}
- (uint32_t)scalar{return 71;}
- (NSRange)throwingRange{[NSException raise:@"InvocationControl" format:@"intentional"];return NSMakeRange(0,0);}
- (NSRange)outerRange{
 self.observedBefore=GuestStretDestination();const auto saved=activeVM->regs;
 if(self.mode==1)GuestObjCSend(activeVM,HOST,selWord(@selector(scalar)),NO);
 if(self.mode==2||self.mode==3){activeVM->regs[0]=0x1200;activeVM->regs[1]=HOST;activeVM->regs[2]=selWord(self.mode==2?@selector(plainRange):@selector(throwingRange));activeVM->regs[3]=0;hle_objc_msgSend_stret(activeVM);}
 activeVM->regs=saved;self.observedAfter=GuestStretDestination();return NSMakeRange(123,456);
}
@end
static void seed(GuestVM&v,uint32_t dst,SEL sel){v={};v.memory.fill(0xa5);v.regs[0]=dst;v.regs[1]=HOST;v.regs[2]=selWord(sel);v.regs[3]=0;v.regs[13]=0x1800;}
static bool atRange(const GuestVM&v,uint32_t at,uint32_t a,uint32_t b){uint32_t x=0,y=0;memcpy(&x,v.memory.data()+at-0x1000,4);memcpy(&y,v.memory.data()+at-0x1000+4,4);return x==a&&y==b;}
static bool unchanged(const GuestVM&v,uint32_t at){for(unsigned n=0;n<8;++n)if(v.memory[at-0x1000+n]!=0xa5)return false;return true;}
int main(){@autoreleasepool{
 GuestVM vm;activeVM=&vm;StretFixture *fixture=[StretFixture new];activeTarget=fixture;
 unsigned checks=0,defects=0;
 auto check=[&](bool okay,const char *label){++checks;if(!okay){++defects;std::printf("DEFECT %s\n",label);}};
 for(unsigned mode=0;mode<4;++mode){
  seed(vm,0x1100,mode?@selector(outerRange):@selector(plainRange));fixture.mode=mode;GuestSetStretDestination(0);hle_objc_msgSend_stret(&vm);
  check(GuestStretDestination()==0,"completed_stret_restores_prior_destination");check(vm.regs[13]==0x1800,"completed_stret_restores_stack");
  check(atRange(vm,0x1100,mode?123:23,mode?456:45),"outer_result_written_to_original_buffer");
  if(mode){check(fixture.observedBefore==0x1100,"outer_sees_its_destination");check(fixture.observedAfter==0x1100,"nested_send_restores_outer_destination");}
  if(mode==1)check(unchanged(vm,0x1200),"ordinary_nested_send_has_no_struct_buffer");
  if(mode==2)check(atRange(vm,0x1200,23,45),"nested_stret_result_not_overwritten_by_outer");
  if(mode==3)check(unchanged(vm,0x1200),"throwing_nested_invocation_writes_no_struct_result");
  // Production GuestSendToSuperclass forwards this exact destination predicate.
  check((GuestStretDestination()!=0)==false,"subsequent_plain_super_send_does_not_inherit_stret");
 }
 seed(vm,0x1100,@selector(raiseAtDispatch));GuestSetStretDestination(0x1300);bool threw=false;@try{hle_objc_msgSend_stret(&vm);}@catch(NSException*){threw=true;}
 check(threw,"native_exception_control_executed");check(GuestStretDestination()==0x1300,"exception_restores_outer_destination");check(vm.regs[13]==0x1800,"exception_restores_stack");check(unchanged(vm,0x1100),"exception_does_not_write_result");
 seed(vm,0x1100,@selector(plainRange));GuestSetStretDestination(0x1300);GuestObjCSend(&vm,HOST,selWord(@selector(scalar)),NO);check(GuestStretDestination()==0x1300,"ordinary_send_restores_callers_destination");
 GuestSetStretDestination(0x1300);threw=false;@try{GuestObjCSend(&vm,HOST,selWord(@selector(raiseAtDispatch)),NO);}@catch(NSException*){threw=true;}
 check(threw&&GuestStretDestination()==0x1300,"ordinary_send_exception_restores_callers_destination");
 GuestSetStretDestination(0x1300);vm.stopped=true;check(!GuestObjCSend(&vm,HOST,selWord(@selector(scalar)),NO)&&GuestStretDestination()==0x1300,"controlled_fault_preserves_callers_destination");
 // The sole production caller is _objc_msgSendSuper2 (no stret argument).
 // An outer active stret destination must not change this independent ABI.
 seed(vm,0x1100,@selector(plainRange));GuestSetStretDestination(0x1300);superControl=true;
 check(GuestSendToSuperclass(&vm,0x2222,selWord(@selector(plainRange)),[NSObject class]),"real_super_shadow_method_was_handled");
 check(unchanged(vm,0x1300)&&GuestReg(&vm,0)==23,"plain_super_send_does_not_write_outer_struct_buffer");
 check(GuestStretDestination()==0x1300,"plain_super_send_preserves_outer_destination");superControl=false;
 // The exact production SEND body must call both graphics boundaries in
 // order, before original dispatch, for this explicit render receiver.
 fixtureGLView=HOST;rejectBacking=rejectWarm=false;boundaryOrder.clear();
 seed(vm,0x1100,@selector(drawView));GuestSetStretDestination(0x1300);
 check(GuestObjCSend(&vm,HOST,selWord(@selector(drawView)),NO),"render_send_continues_after_both_boundaries");
 check(backingCalls==1&&warmCalls==1&&drawCalls==1,"both_boundaries_then_original_draw_execute");
 check(boundaryOrder==std::vector<unsigned>({1,2}),"backing_precedes_warm");
 check(backingReceiver==HOST&&warmReceiver==HOST&&backingSelector==@selector(drawView)&&warmSelector==@selector(drawView),"actual_render_selector_and_receiver_forwarded");
 check(GuestStretDestination()==0x1300,"accepted_render_send_restores_stret");
 rejectBacking=true;boundaryOrder.clear();seed(vm,0x1100,@selector(drawView));GuestSetStretDestination(0x1300);
 check(!GuestObjCSend(&vm,HOST,selWord(@selector(drawView)),NO)&&vm.stopped,"backing_rejection_stops_original_dispatch");
 check(backingCalls==2&&warmCalls==1&&drawCalls==1&&GuestReg(&vm,0)==0,"backing_rejection_does_not_call_warm_or_draw");
 check(boundaryOrder==std::vector<unsigned>({1})&&GuestStretDestination()==0x1300,"backing_rejection_keeps_order_and_restores_stret");
 rejectBacking=false;rejectWarm=true;boundaryOrder.clear();seed(vm,0x1100,@selector(drawView));GuestSetStretDestination(0x1300);
 check(!GuestObjCSend(&vm,HOST,selWord(@selector(drawView)),NO)&&vm.stopped,"warm_rejection_stops_original_dispatch");
 check(backingCalls==3&&warmCalls==2&&drawCalls==1&&GuestReg(&vm,0)==0,"warm_rejection_does_not_call_draw");
 check(boundaryOrder==std::vector<unsigned>({1,2})&&GuestStretDestination()==0x1300,"warm_rejection_keeps_order_and_restores_stret");
 fixtureGLView=0;rejectBacking=rejectWarm=true;boundaryOrder.clear();seed(vm,0x1100,@selector(drawView));
 check(GuestObjCSend(&vm,HOST,selWord(@selector(drawView)),NO)&&drawCalls==2,"ordinary_receiver_bypasses_graphics_boundaries");
 check(backingCalls==3&&warmCalls==2&&boundaryOrder.empty(),"ordinary_receiver_does_not_call_graphics_boundaries");
 fixtureGLView=HOST;seed(vm,0x1100,@selector(drawView));vm.stopped=true;
 check(!GuestObjCSend(&vm,HOST,selWord(@selector(drawView)),NO)&&backingCalls==3&&warmCalls==2&&drawCalls==2,"stopped_vm_rejected_before_graphics_boundaries");
 rejectBacking=rejectWarm=false;fixtureGLView=0;
 std::printf("{\"passed\":%s,\"checks\":%u,\"defects\":%u,\"production_dispatch_fragments\":true,\"real_Foundation_NSInvocation\":true,\"ASan_UBSan\":true,\"game_executed\":false}\n",defects?"false":"true",checks,defects);return defects?1:0;
}}
