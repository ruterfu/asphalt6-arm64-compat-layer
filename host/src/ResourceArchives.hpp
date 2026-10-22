#pragma once

#import <Foundation/Foundation.h>

// Documents/Asphalt6Data.zip: the game resource pack produced by buildGame.
typedef NS_ENUM(NSInteger, AS6ArchiveResult) {
    AS6ArchiveMissing = 0,
    AS6ArchiveInstalled,
    AS6ArchiveDamaged,
};

#ifdef __cplusplus
extern "C" {
#endif
BOOL AS6ResourceArchivePresent(void);
// Replaces Documents/Asphalt6Data with the archive's contents (entries may sit
// at the archive root or under one Asphalt6Data/ folder). Installed HD artwork
// is carried over. The archive is deleted only after a complete extraction;
// a damaged archive leaves the previous folder state untouched. `progress`
// (optional) receives the extracted fraction of bytes, each whole percent once.
AS6ArchiveResult AS6InstallResourceArchive(void (^progress)(double fraction));
#ifdef __cplusplus
}
#endif
