#pragma once
#include "GuestNativeProvider.hpp"

namespace as6_collision36_boundary {
constexpr std::uint32_t Entry=0x490eb4u,PublicReturn=0x493264u;
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withCollision(const as6native::Provider *,ImmutableLinkedProvider);
bool isBoundary(const as6aot::Context &) noexcept;
bool arm(as6aot::Context &) noexcept;
void cancel(as6aot::Context &) noexcept;
}
