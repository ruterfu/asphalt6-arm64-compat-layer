#pragma once

#include <cstdint>
#include <string>
#include <vector>

#ifdef __OBJC__
#import <Foundation/Foundation.h>

namespace as6_zip {
struct Entry {
    std::string name;  // as stored, '/'-separated
    std::uint16_t method = 0;
    std::uint32_t crc = 0, compressed = 0, size = 0, local = 0;
    bool directory() const { return !name.empty() && name.back() == '/'; }
};

// Read-only view of a ZIP archive (stored or deflate entries, no ZIP64 or
// encryption). Entries are inflated in bounded chunks and checked against
// their CRC-32 and size, so a damaged archive is reported, never trusted.
class Archive {
public:
    bool open(NSString *path);
    const std::vector<Entry> &entries() const { return entries_; }
    // Streams one entry to `destination` (replaced atomically on success).
    bool extract(const Entry &entry, NSString *destination) const;
    // Reads one small entry into memory.
    bool read(const Entry &entry, std::vector<std::uint8_t> &out, std::uint32_t limit) const;
    // Entry name made safe for joining under a directory, or empty when the
    // name escapes it (absolute, "..", backslashes) or is macOS metadata.
    static std::string SafeRelative(const std::string &name);

private:
    NSData *data_ = nil;
    std::vector<Entry> entries_;
    const std::uint8_t *payload(const Entry &entry) const;
};
}
#endif
