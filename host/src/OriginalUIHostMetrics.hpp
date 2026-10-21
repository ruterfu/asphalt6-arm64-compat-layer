#pragma once
#include <cstdint>

// Private Host-only layout snapshot; not part of the frozen game/runtime ABI.
// All rectangles are x,y,width,height. Affine order is a,b,c,d,tx,ty.
struct AS6OriginalUIHostMetrics {
    std::uint64_t revision = 0;
    std::int32_t interfaceOrientation = 0;
    double windowScreenScale = 0;
    double windowBoundsPoints[4] = {};
    double safeNormalizedRect[4] = {};
    double originalViewBoundsPoints[4] = {};
    double windowToOriginalView[6] = {};
};
extern "C" bool GuestCopyOriginalUIHostMetrics(AS6OriginalUIHostMetrics *out);
