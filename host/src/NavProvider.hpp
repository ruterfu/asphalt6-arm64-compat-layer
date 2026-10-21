#pragma once
#include "GuestNativeProvider.hpp"
namespace as6_nav_vm {
// Only the single pinned, linked static provider assembly may authorize this
// public-function projection. Layout validation alone grants no admission.
class ImmutableLinkedProvider {
 friend const as6native::Provider *::AS6LinkedNativeProvider();
 ImmutableLinkedProvider() {}
};
const as6native::Provider *withNavigation(const as6native::Provider *,ImmutableLinkedProvider);
bool isLinkedProvider(const as6native::Provider *) noexcept;
}
