#pragma once
#include "GuestTypes.h"
#include <algorithm>
#include <cstdint>
#include <vector>
#include <utility>

// These words are metadata identities, never guest memory or callable code.
// The gap is disjoint from host classes, objects, selectors and opaque handles.
namespace as6native {
constexpr std::uint32_t ObjCMetadataBase=0xe1800000u;
constexpr std::uint32_t ObjCMetadataEnd=0xe2000000u;
inline bool ObjCMetadataWord(std::uint32_t word){return word>=ObjCMetadataBase&&word<ObjCMetadataEnd;}
inline bool ObjCMetadataOverlap(std::uint32_t at,std::uint64_t length) {
    return length && at<ObjCMetadataEnd && (at>=ObjCMetadataBase || length>std::uint64_t(ObjCMetadataBase)-at);
}
#ifdef __OBJC__
using ObjCSlowDispatch=BOOL (*)(GuestVM*,gva_t,gva_t,BOOL);
struct ObjCEmptyVtableIdentity {
    const std::uint32_t word;
    const void *const exported_identity;
    const ObjCSlowDispatch slow_dispatch;
    const std::vector<std::uint32_t> slots;
    ObjCEmptyVtableIdentity(std::uint32_t w,const void *native,ObjCSlowDispatch slow,std::vector<std::uint32_t> allowed)
        :word(w),exported_identity(native),slow_dispatch(slow),slots(std::move(allowed)){}
    const void *native_identity()const{return exported_identity?exported_identity:this;}
    bool owns(std::uint32_t at)const{return std::binary_search(slots.begin(),slots.end(),at);}
};
#endif
}
