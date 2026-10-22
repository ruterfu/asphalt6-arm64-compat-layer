#import "HDArtworkPack.hpp"
#import "ResourcePaths.h"
#import "ZipArchive.hpp"
#import <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <cerrno>
#include <iterator>
#include <vector>

namespace {
constexpr std::uint32_t kMaxEntryBytes = 64u * 1024 * 1024;
constexpr std::size_t kLoadingHeaderBytes = 256u * 96 * 4;

struct ErrnoScope { int value = errno; ~ErrnoScope() { errno = value; } };

NSString *HexSHA256(const void *bytes, std::size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    char hex[65];
    for (int i = 0; i < 32; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return @(hex);
}

const as6_hd_artwork::PackFile *PackFile(NSString *name) {
    for (const auto &file : as6_hd_artwork::kPackFiles)
        if ([name isEqualToString:@(file.name)]) return &file;
    return nullptr;
}

NSString *ArtworkDirectory() {
    return [AS6ExpectedResourceRootPath() stringByAppendingPathComponent:@"NativeArtwork"];
}

NSString *ZipPath() {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"NativeArtwork.zip"];
}

bool Installed(const as6_hd_artwork::PackFile &file) {
    NSData *data = [NSData dataWithContentsOfFile:[ArtworkDirectory() stringByAppendingPathComponent:@(file.name)]
                                          options:NSDataReadingMappedIfSafe error:nil];
    return data && [HexSHA256(data.bytes, data.length) isEqualToString:@(file.sha256)];
}

NSUInteger InstalledCount() {
    NSUInteger count = 0;
    for (const auto &file : as6_hd_artwork::kPackFiles) count += Installed(file);
    return count;
}
}

const std::uint8_t *as6_hd_artwork::LoadingHeader() {
    static const std::vector<std::uint8_t> header = [] {
        ErrnoScope preserve;
        NSData *data = [NSData dataWithContentsOfFile:[ArtworkDirectory() stringByAppendingPathComponent:@(kLoadingHeaderName)]];
        if (data.length != kLoadingHeaderBytes || ![HexSHA256(data.bytes, data.length) isEqualToString:@(kLoadingHeaderSha256)])
            return std::vector<std::uint8_t>();
        const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
        return std::vector<std::uint8_t>(bytes, bytes + data.length);
    }();
    return header.empty() ? nullptr : header.data();
}

extern "C" BOOL AS6HDArtworkComplete(void) {
    ErrnoScope preserve;
    return InstalledCount() == std::size(as6_hd_artwork::kPackFiles);
}

namespace {
std::atomic<bool> scannedComplete{false};
}

extern "C" BOOL AS6HDArtworkScan(void) {
    const BOOL complete = AS6HDArtworkComplete();
    scannedComplete.store(complete, std::memory_order_release);
    return complete;
}

extern "C" BOOL AS6HDArtworkAvailable(void) {
    return scannedComplete.load(std::memory_order_acquire);
}

extern "C" BOOL AS6HDArtworkArchivePresent(void) {
    ErrnoScope preserve;
    return [NSFileManager.defaultManager fileExistsAtPath:ZipPath()];
}

extern "C" BOOL AS6InstallHDArtwork(void) {
    ErrnoScope preserve;
    as6_zip::Archive archive;
    if (!archive.open(ZipPath())) return NO;
    NSString *directory = ArtworkDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    std::vector<std::uint8_t> bytes;
    for (const auto &entry : archive.entries()) {
        const std::string relative = as6_zip::Archive::SafeRelative(entry.name);
        if (relative.empty() || entry.directory()) continue;
        // Entries may sit at the archive root or inside one folder.
        const auto *file = PackFile(@(relative.c_str()).lastPathComponent);
        if (!file || Installed(*file)) continue;
        if (!archive.read(entry, bytes, kMaxEntryBytes)) return NO;
        if (![HexSHA256(bytes.data(), bytes.size()) isEqualToString:@(file->sha256)]) return NO;
        NSData *data = [NSData dataWithBytesNoCopy:bytes.data() length:bytes.size() freeWhenDone:NO];
        if (![data writeToFile:[directory stringByAppendingPathComponent:@(file->name)] options:NSDataWritingAtomic error:nil])
            return NO;
    }
    const NSUInteger installed = InstalledCount();
    NSLog(@"[native-host] HD artwork installed=%lu of %lu", (unsigned long)installed,
          (unsigned long)std::size(as6_hd_artwork::kPackFiles));
    if (installed != std::size(as6_hd_artwork::kPackFiles)) return NO;
    [NSFileManager.defaultManager removeItemAtPath:ZipPath() error:nil];
    return YES;
}
