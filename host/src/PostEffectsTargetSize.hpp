#pragma once
#include <cstdint>

namespace as6_post_effects {
struct Extent { std::uint32_t width, height; };
inline bool supersampledSurface(Extent screen) {
    return (screen.width == 2400 && screen.height == 1600) ||
           (screen.width == 1600 && screen.height == 2400);
}

// Both render paths use the same physical square extent. Flash retains its
// original 1024-square logical stage; the raster boundary maps it separately.
// SetScreenRatio's original power-of-two UV denominators are adapted at its
// exact native continuation to this physical extent, including power-of-two 4096.
constexpr std::uint32_t UnifiedSquareSide = 4096;
inline Extent targetExtent(Extent screen, Extent original) {
    const bool originalTarget = (original.width == 512 && original.height == 512) ||
        ((original.width == 1024 || original.width == 2048) && original.height == 1024);
    if (!supersampledSurface(screen) || !originalTarget) return original;
    return {UnifiedSquareSide, UnifiedSquareSide};
}
}
