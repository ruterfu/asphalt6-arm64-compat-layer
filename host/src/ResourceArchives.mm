#import "ResourceArchives.hpp"
#import "ResourcePaths.h"
#import "ZipArchive.hpp"
#include <cerrno>

namespace {
struct ErrnoScope { int value = errno; ~ErrnoScope() { errno = value; } };

NSString *Documents() {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString *ArchivePath() { return [Documents() stringByAppendingPathComponent:@"Asphalt6Data.zip"]; }

// Strips one leading "Asphalt6Data/" so both archive layouts land in the root.
std::string ResourceName(const std::string &name) {
    std::string relative = as6_zip::Archive::SafeRelative(name);
    static const std::string prefix = "Asphalt6Data/";
    if (relative.compare(0, prefix.size(), prefix) == 0) relative.erase(0, prefix.size());
    else if (relative == "Asphalt6Data") relative.clear();
    return relative;
}
}

extern "C" BOOL AS6ResourceArchivePresent(void) {
    ErrnoScope preserve;
    return [NSFileManager.defaultManager fileExistsAtPath:ArchivePath()];
}

extern "C" AS6ArchiveResult AS6InstallResourceArchive(void (^progress)(double fraction)) {
    ErrnoScope preserve;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:ArchivePath()]) return AS6ArchiveMissing;
    as6_zip::Archive archive;
    if (!archive.open(ArchivePath())) return AS6ArchiveDamaged;

    NSString *root = AS6ExpectedResourceRootPath();
    NSString *staging = [root stringByAppendingString:@".partial"];
    [files removeItemAtPath:staging error:nil];
    if (![files createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil])
        return AS6ArchiveDamaged;
    NSUInteger extracted = 0;
    unsigned long long total = 0, done = 0;
    int reported = -1;
    for (const auto &entry : archive.entries()) total += entry.size;
    for (const auto &entry : archive.entries()) {
        const std::string relative = ResourceName(entry.name);
        if (relative.empty() || entry.directory()) continue;
        NSString *target = [staging stringByAppendingPathComponent:@(relative.c_str())];
        [files createDirectoryAtPath:target.stringByDeletingLastPathComponent
         withIntermediateDirectories:YES attributes:nil error:nil];
        if (!archive.extract(entry, target)) {
            [files removeItemAtPath:staging error:nil];
            return AS6ArchiveDamaged;
        }
        ++extracted;
        done += entry.size;
        const int percent = total ? int(done * 100 / total) : 100;
        if (progress && percent != reported) progress((reported = percent) / 100.0);
    }
    if (!extracted) {
        [files removeItemAtPath:staging error:nil];
        return AS6ArchiveDamaged;
    }
    // Keep already-installed HD artwork across a resource reinstall.
    NSString *artwork = [root stringByAppendingPathComponent:@"NativeArtwork"];
    if ([files fileExistsAtPath:artwork] &&
        ![files fileExistsAtPath:[staging stringByAppendingPathComponent:@"NativeArtwork"]])
        [files moveItemAtPath:artwork toPath:[staging stringByAppendingPathComponent:@"NativeArtwork"] error:nil];
    [files removeItemAtPath:root error:nil];
    if (![files moveItemAtPath:staging toPath:root error:nil]) {
        [files removeItemAtPath:staging error:nil];
        return AS6ArchiveDamaged;
    }
    [files removeItemAtPath:ArchivePath() error:nil];
    NSLog(@"[native-host] resource archive installed files=%lu", (unsigned long)extracted);
    return AS6ArchiveInstalled;
}
