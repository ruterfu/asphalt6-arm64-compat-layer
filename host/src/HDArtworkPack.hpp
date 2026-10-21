#pragma once

#include <cstdint>

#include "HDArtworkPins.hpp"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

namespace as6_hd_artwork {
// Premultiplied BGRA 256x96 loading-screen header from the installed pack, or
// nullptr when no verified copy is installed. Loaded once.
const std::uint8_t *LoadingHeader();
}

#ifdef __OBJC__
extern "C" {
// YES when Documents/NativeArtwork.zip exists and some pack file still needs
// to be installed, so the boot screen can say what it is doing.
BOOL AS6HDArtworkNeedsInstall(void);
// Installs every pack file from Documents/NativeArtwork.zip into
// Asphalt6Data/NativeArtwork, verifying each against HDArtworkPins.hpp.
// Missing zip, unknown entries or bad files are skipped; returns the number
// of verified files now installed. Safe to call off the main thread.
NSUInteger AS6InstallHDArtwork(void);
}
#endif
