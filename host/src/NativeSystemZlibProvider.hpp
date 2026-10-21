#pragma once
#include "GuestNativeProvider.hpp"
// Borrows the one immutable production provider; no generated source changes.
extern "C" const as6native::Provider *AS6ProviderWithSystemZlib(const as6native::Provider *);
