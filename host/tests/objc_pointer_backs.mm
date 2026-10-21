// The builder inserts the exact production pointer-back section at the marker.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
@class GuestVM;
using gva_t=uint32_t;
#include "GuestObjCMetadata.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>
@interface GuestVM:NSObject @end
@implementation GuestVM @end
static uint8_t memory[65536];
static bool fault;
static unsigned checks;
static unsigned guestWrites,lastFlushWrites;
static NSMutableDictionary<NSNumber *,id> *objects;
static std::unordered_map<uint32_t,Class> classes;
static uint32_t nextObject=0x50000000,nextClass=0x60000000;
struct Registry {std::unordered_map<uint32_t,std::string> classNames;};
static Registry registry;
static Registry &LocalRegistry(GuestVM*){return registry;}
static BOOL GuestHasStopRequest(GuestVM*){return fault;}
static void GuestRequestFault(GuestVM*){fault=true;}
static void GuestTrace(GuestVM*,NSString*,...){}
static BOOL GuestObjCMetadataWord(uint32_t word){return as6native::ObjCMetadataWord(word);}
static BOOL GuestRead(GuestVM*,uint32_t address,void *out,size_t size){if(address<0x8000||uint64_t(address)+size>sizeof(memory))return NO;memcpy(out,memory+address,size);return YES;}
static BOOL GuestWrite(GuestVM*,uint32_t address,const void *bytes,size_t size){if(address<0x8000||uint64_t(address)+size>sizeof(memory)){fault=true;return NO;}memcpy(memory+address,bytes,size);++guestWrites;return YES;}
static void GuestWriteU32(GuestVM *vm,uint32_t address,uint32_t word){GuestWrite(vm,address,&word,4);}
static uint32_t ReadWord(uint32_t address){uint32_t word=0;assert(GuestRead(nil,address,&word,4));return word;}
static size_t GuestStrLen(GuestVM*,uint32_t address,size_t cap){size_t size=0;while(size<cap&&address+size<sizeof(memory)&&memory[address+size])++size;return size;}
static uint32_t GuestAlloc(GuestVM*,size_t){return 0xa000;}
static BOOL GuestIsHostObject(uint32_t word){return objects[@(word)]!=nil;}
static BOOL GuestIsHostClass(uint32_t word){return classes.count(word);}
static id GuestObjCUnwrap(GuestVM*,uint32_t word){return objects[@(word)];}
static Class GuestObjCUnwrapClass(GuestVM*,uint32_t word){auto found=classes.find(word);return found==classes.end()?Nil:found->second;}
static uint32_t GuestObjCWrap(GuestVM*,id object){if(!object)return 0;for(NSNumber *key in objects)if(objects[key]==object)return key.unsignedIntValue;const auto key=nextObject++;objects[@(key)]=object;return key;}
static uint32_t GuestObjCWrapClass(GuestVM*,Class cls){if(!cls)return 0;for(auto pair:classes)if(pair.second==cls)return pair.first;classes[nextClass]=cls;return nextClass++;}
static BOOL GuestSectionContains(GuestVM*,const char *section,uint32_t word){return !strcmp(section,"__cfstring")&&word==0x9000;}
static NSString *GuestObjCCFString(GuestVM*,uint32_t word){return word==0x9000?[[NSMutableString alloc]initWithString:@"original literal"]:nil;}
static id GuestObjCShadow(GuestVM*,uint32_t word){return word==0x8100?objects[@(0x50000000)]:nil;}
static id GuestObjCDelegateProxy(GuestVM*,uint32_t word){return GuestObjCShadow(nil,word);}
static void *HLEUnwrapOpaque(GuestVM*,uint32_t){return nullptr;}
static SEL GuestObjCSelFromGuest(GuestVM*,uint32_t word){return word==0x70000000?@selector(description):nullptr;}
static uint32_t GuestObjCGuestSelNamed(GuestVM*,const char *name){return !strcmp(name,"description")?0x70000001:0;}

// AS6_POINTER_BACKS_PRODUCTION

@interface PointerFixture:NSObject
- (void)noWrite:(out id *)value;
- (void)keep:(inout id *)value;
- (void)replace:(inout id *)value;
- (void)clear:(inout id *)value;
- (void)bad:(out id *)value;
- (void)raiseAfterWrite:(out id *)value;
@end
@implementation PointerFixture
- (void)noWrite:(out id *)value {(void)value;}
- (void)keep:(inout id *)value {(void)value;}
- (void)replace:(inout id *)value {*value=@"replacement";}
- (void)clear:(inout id *)value {*value=nil;}
- (void)bad:(out id *)value {void *raw=(void *)uintptr_t(0x71c9d8);memcpy((void*)value,&raw,sizeof(raw));}
- (void)raiseAfterWrite:(out id *)value {*value=@"uncommitted";@throw [NSException exceptionWithName:@"fixture" reason:@"no commit" userInfo:nil];}
@end
#define CHECK(x) do{++checks;assert(x);}while(0)
static void Invoke(id target,SEL sel,uint32_t initial) {
    fault=false;lastFlushWrites=0;GuestWriteU32(nil,0x8000,initial);
    NSMethodSignature *signature=[target methodSignatureForSelector:sel];
    NSInvocation *inv=[NSInvocation invocationWithMethodSignature:signature];inv.selector=sel;
    std::vector<std::vector<uint8_t>> pool;PointerBack back;
    NSMutableArray *retained=[NSMutableArray array];
    const char *enc=[signature getArgumentTypeAtIndex:2];
    void *pointer=BackGuestPointer(nil,0x8000,enc,0,&back,pool,PointerArgumentFlow(enc,sel,2),retained);
    if(fault)return;
    CHECK(back.hostSize==sizeof(void*)&&back.guestSize==4);
    [inv setArgument:&pointer atIndex:2];
    @try{[inv invokeWithTarget:target];} @catch(NSException*){return;}
    const auto before=guestWrites;FlushPointerBacks(nil,{back});lastFlushWrites=guestWrites-before;
}
int main(){@autoreleasepool{
    objects=[NSMutableDictionary dictionary];auto *fixture=[PointerFixture new];
    const auto original=GuestObjCWrap(nil,@"original");
    Invoke(fixture,@selector(noWrite:),0x71c9d8);CHECK(!fault&&ReadWord(0x8000)==0x71c9d8&&lastFlushWrites==0);
    Invoke(fixture,@selector(noWrite:),0x717040);CHECK(!fault&&ReadWord(0x8000)==0x717040&&lastFlushWrites==0);
    Invoke(fixture,@selector(keep:),original);CHECK(!fault&&ReadWord(0x8000)==original&&lastFlushWrites==0);
    Invoke(fixture,@selector(replace:),original);CHECK(!fault&&[GuestObjCUnwrap(nil,ReadWord(0x8000)) isEqual:@"replacement"]);
    Invoke(fixture,@selector(clear:),original);CHECK(!fault&&ReadWord(0x8000)==0&&lastFlushWrites==1);
    Invoke(fixture,@selector(keep:),0x9000);CHECK(!fault&&ReadWord(0x8000)==0x9000);
    registry.classNames[0x8200]="checked fixture";GuestWriteU32(nil,0x8100,0x8200);
    Invoke(fixture,@selector(keep:),0x8100);CHECK(!fault&&ReadWord(0x8000)==0x8100);
    Invoke(fixture,@selector(keep:),0x71c9d8);CHECK(fault&&ReadWord(0x8000)==0x71c9d8);
    Invoke(fixture,@selector(bad:),0x71c9d8);CHECK(fault&&ReadWord(0x8000)==0x71c9d8);
    Invoke(fixture,@selector(raiseAfterWrite:),0x71c9d8);CHECK(!fault&&ReadWord(0x8000)==0x71c9d8);
    for(NSString *path in @[@"/",@"/as6-definitely-not-present-fixture"]){
        fault=false;GuestWriteU32(nil,0x8000,0x71c9d8);
        auto *manager=[NSFileManager defaultManager];SEL sel=@selector(attributesOfItemAtPath:error:);
        NSMethodSignature *sig=[manager methodSignatureForSelector:sel];NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.selector=sel;
        std::vector<std::vector<uint8_t>> pool;PointerBack back;NSMutableArray *retained=[NSMutableArray array];
        const char *enc=[sig getArgumentTypeAtIndex:3];CHECK(PointerArgumentFlow(enc,sel,3)==PointerFlow::Output);
        void *pointer=BackGuestPointer(nil,0x8000,enc,0,&back,pool,PointerArgumentFlow(enc,sel,3),retained);
        void *seed=(void*)1;memcpy(&seed,pointer,sizeof(seed));CHECK(seed==nullptr);
        __unsafe_unretained NSString *argumentPath=path;
        [inv setArgument:&argumentPath atIndex:2];[inv setArgument:&pointer atIndex:3];[inv invokeWithTarget:manager];
        const auto before=guestWrites;FlushPointerBacks(nil,{back});CHECK(!fault);
        if([path isEqual:@"/"])CHECK(ReadWord(0x8000)==0x71c9d8&&guestWrites==before);
        else CHECK([GuestObjCUnwrap(nil,ReadWord(0x8000)) isKindOfClass:[NSError class]]&&guestWrites==before+1);
    }
    // Reproduce the actual IGPSendGameInfo call with a Game-vptr word at the
    // supplied NSError** address. Success must not clear that unmodified word.
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"as6-nserror-output-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    CHECK([@"original config" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    for(NSString *argumentPath in @[path,[path stringByAppendingString:@"-missing"]]){
        fault=false;GuestWriteU32(nil,0x8000,0x717040);
        SEL sel=@selector(stringWithContentsOfFile:encoding:error:);id target=[NSString class];
        NSMethodSignature *sig=[target methodSignatureForSelector:sel];NSInvocation *inv=[NSInvocation invocationWithMethodSignature:sig];inv.selector=sel;
        std::vector<std::vector<uint8_t>> pool;PointerBack back;NSMutableArray *retained=[NSMutableArray array];
        const char *enc=[sig getArgumentTypeAtIndex:4];CHECK(PointerArgumentFlow(enc,sel,4)==PointerFlow::Output);
        void *pointer=BackGuestPointer(nil,0x8000,enc,0,&back,pool,PointerArgumentFlow(enc,sel,4),retained);
        void *seed=(void*)1;memcpy(&seed,pointer,sizeof(seed));CHECK(!fault&&seed==nullptr);
        __unsafe_unretained NSString *filePath=argumentPath;NSStringEncoding encoding=NSUTF8StringEncoding;
        [inv setArgument:&filePath atIndex:2];[inv setArgument:&encoding atIndex:3];[inv setArgument:&pointer atIndex:4];
        [inv invokeWithTarget:target];void *rawResult=nullptr;[inv getReturnValue:&rawResult];
        const auto before=guestWrites;FlushPointerBacks(nil,{back});CHECK(!fault);
        if([argumentPath isEqual:path]){
            CHECK(rawResult&&[(__bridge NSString*)rawResult isEqualToString:@"original config"]);
            CHECK(ReadWord(0x8000)==0x717040&&guestWrites==before);
        }else{
            CHECK(!rawResult&&[GuestObjCUnwrap(nil,ReadWord(0x8000)) isKindOfClass:[NSError class]]);
            CHECK(guestWrites==before+1);
        }
    }
    CHECK([[NSFileManager defaultManager] removeItemAtPath:path error:nil]);
    CHECK(PointerObjectArray(@selector(getObjects:range:))&&PointerObjectArray(@selector(initWithObjects:count:)));
    for(const char kind:{'#',':'}) {
        fault=false;const auto word=kind=='#'?GuestObjCWrapClass(nil,[NSObject class]):0x70000000u;
        GuestWriteU32(nil,0x8000,word);char encoding[]={'^',kind,0};
        std::vector<std::vector<uint8_t>> pool;PointerBack back;
        void *pointer=BackGuestPointer(nil,0x8000,encoding,0,&back,pool);
        CHECK(!fault&&back.hostSize==sizeof(void*)&&back.guestSize==4);
        FlushPointerBacks(nil,{back});CHECK(!fault&&ReadWord(0x8000)==word);
        void *bad=(void*)uintptr_t(0x71c9d8);memcpy(pointer,&bad,sizeof(bad));
        FlushPointerBacks(nil,{back});CHECK(fault&&ReadWord(0x8000)==word);
    }
    fault=false;std::vector<std::vector<uint8_t>> unknownPool;PointerBack unknownBack;
    CHECK(!BackGuestPointer(nil,0x8000,"^^v",0,&unknownBack,unknownPool)&&fault);
    printf("{\"passed\":true,\"checks\":%u,\"production_pointer_section\":true,\"real_Foundation_NSInvocation_and_NSError\":true,\"game_executed\":false}\n",checks);
}}
