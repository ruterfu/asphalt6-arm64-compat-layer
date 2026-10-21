#pragma once
#include <array>
#include <cmath>

namespace as6_original_ui {
inline constexpr double CareerStarScale=.82;
// star_career owns the icon and counter. Scale its child coordinate axes
// about its authored local origin; its parent-space translation stays exact.
inline bool careerStarLocal(const std::array<float,6> &authored,
                            std::array<float,6> &result) {
    for(float f:authored)if(!std::isfinite(f))return false;
    result=authored;
    for(unsigned i:{0u,1u,3u,4u})result[i]=float(double(authored[i])*CareerStarScale);
    return true;
}
} // namespace as6_original_ui
