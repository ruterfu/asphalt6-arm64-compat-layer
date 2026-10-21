#import "HDArtworkPack.hpp"
#import "ResourcePaths.h"
#import <CommonCrypto/CommonDigest.h>
#include <zlib.h>
#include <cstring>
#include <string>
#include <vector>

namespace {
constexpr std::size_t kMaxEntryBytes = 64u * 1024 * 1024;
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

std::uint32_t U16(const std::uint8_t *p) { return p[0] | p[1] << 8; }
std::uint32_t U32(const std::uint8_t *p) { return U16(p) | U16(p + 2) << 16; }

// Stored or raw-deflate payload of one central-directory entry, bounded.
bool Inflate(const std::uint8_t *zip, std::size_t size, const std::uint8_t *central, std::vector<std::uint8_t> &out) {
    const auto method = U16(central + 10), compressed = U32(central + 20), expanded = U32(central + 24);
    const auto local = U32(central + 42);
    if (expanded > kMaxEntryBytes || local > size || size - local < 30 || U32(zip + local) != 0x04034b50) return false;
    const std::size_t data = std::size_t(local) + 30 + U16(zip + local + 26) + U16(zip + local + 28);
    if (data > size || size - data < compressed) return false;
    out.resize(expanded);
    if (method == 0) {
        if (compressed != expanded) return false;
        if (expanded) std::memcpy(out.data(), zip + data, expanded);
        return true;
    }
    if (method != 8) return false;
    z_stream stream{};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    stream.next_in = const_cast<Bytef *>(zip + data);
    stream.avail_in = compressed;
    stream.next_out = out.data();
    stream.avail_out = expanded;
    const int status = inflate(&stream, Z_FINISH);
    const bool complete = status == Z_STREAM_END && stream.total_out == expanded;
    inflateEnd(&stream);
    return complete;
}

bool WriteAtomically(NSString *directory, NSString *name, const std::vector<std::uint8_t> &bytes) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes.data() length:bytes.size() freeWhenDone:NO];
    return [data writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
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

extern "C" BOOL AS6HDArtworkNeedsInstall(void) {
    ErrnoScope preserve;
    if (![NSFileManager.defaultManager fileExistsAtPath:ZipPath()]) return NO;
    for (const auto &file : as6_hd_artwork::kPackFiles)
        if (!Installed(file)) return YES;
    return NO;
}

extern "C" NSUInteger AS6InstallHDArtwork(void) {
    ErrnoScope preserve;
    NSUInteger installed = 0;
    for (const auto &file : as6_hd_artwork::kPackFiles) installed += Installed(file);
    if (installed == std::size(as6_hd_artwork::kPackFiles)) return installed;
    NSData *archive = [NSData dataWithContentsOfFile:ZipPath() options:NSDataReadingMappedIfSafe error:nil];
    if (archive.length < 22) return installed;
    const auto *zip = static_cast<const std::uint8_t *>(archive.bytes);
    const std::size_t size = archive.length;

    // End of central directory: last record, possibly followed by a comment.
    std::size_t end = size - 22;
    const std::size_t floor = size > 22 + 0xffff ? size - 22 - 0xffff : 0;
    while (U32(zip + end) != 0x06054b50) {
        if (end == floor) return installed;
        --end;
    }
    const auto entries = U16(zip + end + 10);
    std::size_t cursor = U32(zip + end + 16);
    NSString *directory = ArtworkDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];

    std::vector<std::uint8_t> bytes;
    for (unsigned i = 0; i < entries; ++i) {
        if (cursor > size || size - cursor < 46 || U32(zip + cursor) != 0x02014b50) break;
        const std::uint8_t *central = zip + cursor;
        const auto nameLength = U16(central + 28);
        if (size - cursor - 46 < nameLength) break;
        cursor += 46 + nameLength + U16(central + 30) + U16(central + 32);
        // Entries may sit at the archive root or inside one folder.
        NSString *path = [[NSString alloc] initWithBytes:central + 46 length:nameLength encoding:NSUTF8StringEncoding];
        const auto *file = PackFile(path.lastPathComponent);
        if (!file || Installed(*file)) continue;
        if (!Inflate(zip, size, central, bytes)) continue;
        if (![HexSHA256(bytes.data(), bytes.size()) isEqualToString:@(file->sha256)]) continue;
        installed += WriteAtomically(directory, @(file->name), bytes);
    }
    NSLog(@"[native-host] HD artwork installed=%lu of %lu", (unsigned long)installed,
          (unsigned long)std::size(as6_hd_artwork::kPackFiles));
    return installed;
}
