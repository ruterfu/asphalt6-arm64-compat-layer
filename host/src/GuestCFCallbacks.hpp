#pragma once

#import "GuestVM.h"
#import "HLE.h"
#import "GuestObjC.h"
#import <CoreFoundation/CoreFoundation.h>
#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <new>
#include <utility>

// Original identities established offline from the immutable original image
// and its three raw P-code records. Runtime code never fetches instructions.
namespace as6cf {
constexpr gva_t RetainIdentity = 0x69208cu;
constexpr gva_t ReleaseIdentity = 0x692094u;
constexpr std::size_t SlotCount = 64;
struct Context {
    __weak GuestVM *owner;
    const gva_t allocator;
    const std::array<std::uint32_t,5> words;
    std::atomic<bool> failed{false};
    Context(GuestVM *vm,gva_t a,const std::array<std::uint32_t,5> &w)
        :owner(vm),allocator(a),words(w){}
};
struct Registry {
    std::mutex lock;
    std::array<std::unique_ptr<Context>,SlotCount> contexts{};
    std::array<std::atomic<Context *>,SlotCount> published{};
    Registry(){for(auto &pointer:published)pointer.store(nullptr,std::memory_order_relaxed);}
};
inline Registry &registry() { static Registry value; return value; }

// Call with this VM's lock. A successful CPU restore must never clear failure.
inline void fail(Context &context,GuestVM *vm,const char *reason) {
    const bool wasFailed=context.failed.exchange(true,std::memory_order_acq_rel);
    if (vm) {
        GuestRequestFault(vm);
        if (!wasFailed) GuestTrace(vm,@"[cf] fixed native callback failed: %s; incoming pointer retained only for CF structural cleanup",reason);
    }
}
inline bool marshal(GuestVM *vm,const void *pointer,gva_t original,bool raw32,std::uint32_t &word) {
    if (!pointer) {word=0;return true;}
    const auto nativeBits=reinterpret_cast<std::uintptr_t>(pointer);
    if(nativeBits<=UINT32_MAX&&GuestObjCMetadataWord(std::uint32_t(nativeBits))) {
        GuestRequestFault(vm);return false;
    }
    if (raw32 && reinterpret_cast<std::uintptr_t>(pointer)<=UINT32_MAX) {
        word=std::uint32_t(reinterpret_cast<std::uintptr_t>(pointer));return true;
    }
    // CFArrayCreateCopy may pass a different actual allocator. Preserve the
    // original word only if it still names this exact native pointer.
    if (original && HLEUnwrapOpaque(vm,original)==pointer) {word=original;return true;}
    word=HLEWrapOpaque(vm,const_cast<void *>(pointer));
    return word && HLEUnwrapOpaque(vm,word)==pointer;
}
inline bool invoke(Context &context,CFAllocatorRef allocator,const void *value,bool retain) {
    GuestVM *vm=context.owner; // Strong for the complete nested invocation.
    if (!vm) {context.failed.store(true,std::memory_order_release);return false;}
    GuestLock(vm);
    bool ok=false;
    @try {
        if (context.failed.load(std::memory_order_acquire)) {
            GuestRequestFault(vm);return false;
        }
        if (!vm.loaded) {fail(context,vm,"VM is no longer loaded");return false;}
        std::uint32_t arguments[2];
        if (!marshal(vm,allocator,context.allocator,false,arguments[0]) ||
            !marshal(vm,value,0,true,arguments[1])) {
            fail(context,vm,"native ABI pointer cannot round-trip");return false;
        }
        const auto result=GuestCall(vm,retain?RetainIdentity:ReleaseIdentity,arguments,2,64);
        if (GuestLastExecutionResult(vm)!=GuestExecutionSuccess) {
            fail(context,vm,"original static callback did not return successfully");return false;
        }
        if (retain && result!=arguments[1]) {
            fail(context,vm,"original retain result differs from mapped incoming value");return false;
        }
        ok=true;
    } @finally {GuestUnlock(vm);}
    return ok;
}
template<std::size_t Index>
const void *retain(CFAllocatorRef allocator,const void *value) {
    Context *context=registry().published[Index].load(std::memory_order_acquire);
    if (context) invoke(*context,allocator,value,true);
    // On failure invoke() permanently faults both context and VM. CF itself
    // still needs the incoming pointer to remove/release its stored values.
    return value;
}
template<std::size_t Index>
void release(CFAllocatorRef allocator,const void *value) {
    Context *context=registry().published[Index].load(std::memory_order_acquire);
    if (context) invoke(*context,allocator,value,false);
}
template<std::size_t... Index>
constexpr auto retainFunctions(std::index_sequence<Index...>) {
    return std::array<CFArrayRetainCallBack,sizeof...(Index)>{{retain<Index>...}};
}
template<std::size_t... Index>
constexpr auto releaseFunctions(std::index_sequence<Index...>) {
    return std::array<CFArrayReleaseCallBack,sizeof...(Index)>{{release<Index>...}};
}
enum class TableResult { Unrelated, Ready, Rejected };
inline TableResult prepare(GuestVM *vm,gva_t allocator,const std::uint32_t *words,CFArrayCallBacks &out) {
    // Any fixed identity in any field claims this exact adapter family. Mixed
    // host/original callbacks and wrong positions reject before native CF use.
    bool fixed=false;
    for(std::size_t i=1;i<5;++i) fixed|=words[i]==RetainIdentity||words[i]==ReleaseIdentity;
    if (!fixed) return TableResult::Unrelated;
    const std::array<std::uint32_t,5> expected{{0,RetainIdentity,ReleaseIdentity,0,0}};
    std::array<std::uint32_t,5> actual;
    for(std::size_t i=0;i<5;++i) actual[i]=words[i];
    if (!vm||!vm.loaded||actual!=expected||GuestObjCMetadataWord(allocator)) {if(vm)GuestRequestFault(vm);return TableResult::Rejected;}
    static constexpr auto retains=retainFunctions(std::make_index_sequence<SlotCount>{});
    static constexpr auto releases=releaseFunctions(std::make_index_sequence<SlotCount>{});
    auto &state=registry();std::lock_guard<std::mutex> lock(state.lock);
    std::size_t slot=SlotCount,free=SlotCount;
    for(std::size_t i=0;i<SlotCount;++i) {
        auto *context=state.contexts[i].get();
        if (!context) {if(free==SlotCount)free=i;continue;}
        GuestVM *owner=context->owner;
        if(owner==vm&&context->allocator==allocator&&context->words==actual) {slot=i;break;}
    }
    if(slot==SlotCount) {
        if(free==SlotCount) {
            GuestTrace(vm,@"[cf] fixed callback context capacity exhausted (%zu immutable contexts)",SlotCount);
            GuestRequestFault(vm);return TableResult::Rejected;
        }
        auto context=std::unique_ptr<Context>(new(std::nothrow) Context(vm,allocator,actual));
        if(!context) {GuestRequestFault(vm);return TableResult::Rejected;}
        slot=free;state.contexts[slot]=std::move(context);
        state.published[slot].store(state.contexts[slot].get(),std::memory_order_release);
    }
    if(state.contexts[slot]->failed.load(std::memory_order_acquire)) {
        GuestRequestFault(vm);return TableResult::Rejected;
    }
    out={0,retains[slot],releases[slot],nullptr,nullptr};
    return TableResult::Ready;
}
} // namespace as6cf
