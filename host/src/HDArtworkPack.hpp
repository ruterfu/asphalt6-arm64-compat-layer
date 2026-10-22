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
// Every pack file is installed in Asphalt6Data/NativeArtwork and verified.
// Missing files simply fall back to the original backgrounds.
BOOL AS6HDArtworkComplete(void);
// Hashes every pack file (AS6HDArtworkComplete) and keeps the result; called
// only by the startup resource check. AS6HDArtworkAvailable returns the last
// scan without touching files (NO before any scan).
BOOL AS6HDArtworkScan(void);
BOOL AS6HDArtworkAvailable(void);
BOOL AS6HDArtworkArchivePresent(void);
// Installs the missing pack files from Documents/NativeArtwork.zip, each
// verified against HDArtworkPins.hpp. Returns YES (and deletes the archive)
// only when the pack is complete afterwards; otherwise the archive is kept.
BOOL AS6InstallHDArtwork(void);
}
#endif
