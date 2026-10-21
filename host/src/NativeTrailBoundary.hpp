#pragma once
#include "GuestNativeProvider.hpp"

namespace as6_trail_boundary {
constexpr std::uint32_t Entry=0x169fa0u,PublicReturn=0x16ab14u;
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withTrails(const as6native::Provider *,ImmutableLinkedProvider);
bool isBoundary(const as6aot::Context &) noexcept;
bool observesOriginalStop(std::uint32_t stop,bool stopThumb) noexcept;
bool arm(as6aot::Context &) noexcept;
void cancel(as6aot::Context &) noexcept;
}
