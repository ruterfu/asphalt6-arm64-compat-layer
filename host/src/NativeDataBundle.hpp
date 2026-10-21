#pragma once
#include "GuestNativeProvider.hpp"
extern "C" const as6native::DataManifest *AS6GeneratedDataManifest();
extern "C" const as6native::Bridge *AS6GeneratedBridges(std::size_t *count);
extern "C" std::uint32_t AS6GeneratedEntry();
extern "C" const char *AS6GeneratedDataBuildId();
