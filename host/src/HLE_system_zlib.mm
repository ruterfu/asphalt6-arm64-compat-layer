#import "HLE.h"
#import "GuestVM.h"
#include "SystemZlibCore.hpp"
#include <array>
#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <new>
#include <unordered_map>

namespace {
using namespace as6port;
std::unordered_map<std::uintptr_t,std::shared_ptr<SystemZlib>> engines;
std::mutex enginesMutex;
GuestVM *VM(void *owner){return (__bridge GuestVM *)owner;}
GuestServices Services(GuestVM *vm){
    return {(__bridge void *)vm,
        [](void *p,std::uint32_t at,void *out,std::size_t n){return bool(GuestRead(VM(p),at,out,n));},
        [](void *p,std::uint32_t at,const void *in,std::size_t n){return bool(GuestWrite(VM(p),at,in,n));},
        [](void *p,std::uint32_t at,std::size_t n){
            if(n && (at<4096 || std::uint64_t(n)>0x100000000ULL-at))return false;
            std::array<std::uint8_t,4096> scratch{};
            for(std::size_t offset=0;offset<n;){
                const auto count=std::min(scratch.size(),n-offset);
                if(!GuestRead(VM(p),at+std::uint32_t(offset),scratch.data(),count))return false;
                offset+=count;
            }return true;
        },
        [](void *p,std::size_t n){return GuestHeapAlloc(VM(p),n);},
        [](void *p,std::uint32_t at){return bool(GuestHeapFree(VM(p),at));},
        [](void *p,std::uint32_t fn,const std::uint32_t *args,int count){
            // GuestCall snapshots/restores the complete architectural CPU and
            // preserves permanent fault/halt latches. This is nativeDepth 0.
            return GuestCall(VM(p),fn,args,count,10000000);
        },
        [](void *p){return bool(GuestHasStopRequest(VM(p)));},
        [](void *p,const char *message){
            return GuestWriteCString(VM(p),[NSString stringWithUTF8String:message]);
        }};
}
void Invoke(GuestVM *vm,ZOperation operation){
    const auto key=reinterpret_cast<std::uintptr_t>((__bridge void *)vm);
    std::shared_ptr<SystemZlib> engine;
    try {std::lock_guard<std::mutex> lock(enginesMutex);
         auto &entry=engines[key];if(!entry)entry=std::make_shared<SystemZlib>(Services(vm));engine=entry;}
    catch(const std::bad_alloc &){GuestSetRet(vm,std::uint32_t(-4));return;}
    const auto stream=GuestArg(vm,0);
    int argument=0;std::uint32_t version=0,size=56;
    if(operation==ZOperation::Init){version=GuestArg(vm,1);size=GuestArg(vm,2);}
    if(operation==ZOperation::Init2){argument=int(GuestArg(vm,1));version=GuestArg(vm,2);size=GuestArg(vm,3);}
    if(operation==ZOperation::Inflate)argument=int(GuestArg(vm,1));
    const auto result=engine->invoke(operation,stream,argument,version,size);
    if(result.memory_fault || (result.callback_stopped&&!GuestHasStopRequest(vm)))GuestRequestFault(vm);
    if(!GuestHasStopRequest(vm))GuestSetRet(vm,std::uint32_t(result.code));
}
}
// Integration MUST call this while the VM is alive and locked, nativeDepth 0,
// immediately before GuestVMDestroy. A stopped VM releases only host storage.
extern "C" void AS6SystemZlibForgetVM(GuestVM *vm){
    const auto key=reinterpret_cast<std::uintptr_t>((__bridge void *)vm);
    std::shared_ptr<SystemZlib> engine;
    {std::lock_guard<std::mutex> lock(enginesMutex);
     const auto found=engines.find(key);if(found!=engines.end()){engine=found->second;engines.erase(found);}}
}
HLE_DEFINE(as6_system_inflateReset){Invoke(vm,ZOperation::Reset);}
HLE_BIND("__as6_system_inflateReset",as6_system_inflateReset)
HLE_DEFINE(as6_system_inflateInit2){Invoke(vm,ZOperation::Init2);}
HLE_BIND("__as6_system_inflateInit2",as6_system_inflateInit2)
HLE_DEFINE(as6_system_inflateInit){Invoke(vm,ZOperation::Init);}
HLE_BIND("__as6_system_inflateInit",as6_system_inflateInit)
HLE_DEFINE(as6_system_inflateEnd){Invoke(vm,ZOperation::End);}
HLE_BIND("__as6_system_inflateEnd",as6_system_inflateEnd)
HLE_DEFINE(as6_system_inflate){Invoke(vm,ZOperation::Inflate);}
HLE_BIND("__as6_system_inflate",as6_system_inflate)
