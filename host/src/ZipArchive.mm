#import "ZipArchive.hpp"
#include <zlib.h>
#include <cstdio>
#include <cstring>

namespace {
std::uint32_t U16(const std::uint8_t *p) { return p[0] | p[1] << 8; }
std::uint32_t U32(const std::uint8_t *p) { return U16(p) | U16(p + 2) << 16; }
constexpr std::size_t kChunk = 256 * 1024;

// Feeds the entry's bytes to `sink` in chunks; verifies size and CRC-32.
template <class Sink>
bool Stream(const as6_zip::Entry &entry, const std::uint8_t *input, Sink &&sink) {
    uLong crc = crc32(0, nullptr, 0);
    std::uint64_t produced = 0;
    if (entry.method == 0) {
        if (entry.compressed != entry.size) return false;
        for (std::uint32_t offset = 0; offset < entry.size;) {
            const auto count = std::min<std::uint32_t>(kChunk, entry.size - offset);
            crc = crc32(crc, input + offset, count);
            if (!sink(input + offset, count)) return false;
            offset += count;
        }
        produced = entry.size;
    } else if (entry.method == 8) {
        z_stream stream{};
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
        std::vector<std::uint8_t> buffer(kChunk);
        stream.next_in = const_cast<Bytef *>(input);
        stream.avail_in = entry.compressed;
        int status = Z_OK;
        while (status != Z_STREAM_END) {
            stream.next_out = buffer.data();
            stream.avail_out = (uInt)buffer.size();
            status = inflate(&stream, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END) break;
            const auto count = buffer.size() - stream.avail_out;
            if (!count && status != Z_STREAM_END && !stream.avail_in) { status = Z_DATA_ERROR; break; }
            produced += count;
            if (produced > entry.size) { status = Z_DATA_ERROR; break; }
            crc = crc32(crc, buffer.data(), (uInt)count);
            if (count && !sink(buffer.data(), count)) { status = Z_DATA_ERROR; break; }
        }
        inflateEnd(&stream);
        if (status != Z_STREAM_END) return false;
    } else {
        return false;
    }
    return produced == entry.size && crc == entry.crc;
}
}

namespace as6_zip {
bool Archive::open(NSString *path) {
    entries_.clear();
    data_ = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data_.length < 22 || data_.length > 0xffffffffu) return false;
    const auto *zip = static_cast<const std::uint8_t *>(data_.bytes);
    const std::size_t size = data_.length;
    // End of central directory: last record, possibly followed by a comment.
    std::size_t end = size - 22;
    const std::size_t floor = size > 22 + 0xffff ? size - 22 - 0xffff : 0;
    while (U32(zip + end) != 0x06054b50) {
        if (end == floor) return false;
        --end;
    }
    const auto count = U16(zip + end + 10);
    std::size_t cursor = U32(zip + end + 16);
    for (unsigned i = 0; i < count; ++i) {
        if (cursor > size || size - cursor < 46 || U32(zip + cursor) != 0x02014b50) return false;
        const std::uint8_t *central = zip + cursor;
        const auto nameLength = U16(central + 28);
        if (size - cursor - 46 < nameLength) return false;
        Entry entry;
        entry.name.assign(reinterpret_cast<const char *>(central + 46), nameLength);
        entry.method = U16(central + 10);
        entry.crc = U32(central + 16);
        entry.compressed = U32(central + 20);
        entry.size = U32(central + 24);
        entry.local = U32(central + 42);
        if (U16(central + 8) & 1) return false;  // encrypted
        entries_.push_back(std::move(entry));
        cursor += 46 + nameLength + U16(central + 30) + U16(central + 32);
    }
    return true;
}

const std::uint8_t *Archive::payload(const Entry &entry) const {
    const auto *zip = static_cast<const std::uint8_t *>(data_.bytes);
    const std::size_t size = data_.length;
    if (entry.local > size || size - entry.local < 30 || U32(zip + entry.local) != 0x04034b50) return nullptr;
    const std::size_t start = std::size_t(entry.local) + 30 + U16(zip + entry.local + 26) + U16(zip + entry.local + 28);
    if (start > size || size - start < entry.compressed) return nullptr;
    return zip + start;
}

bool Archive::extract(const Entry &entry, NSString *destination) const {
    const auto *input = payload(entry);
    if (!input) return false;
    NSString *temporary = [destination stringByAppendingString:@".partial"];
    FILE *file = fopen(temporary.fileSystemRepresentation, "wb");
    if (!file) return false;
    const bool ok = Stream(entry, input, [&](const std::uint8_t *bytes, std::size_t count) {
        return fwrite(bytes, 1, count, file) == count;
    });
    const bool closed = fclose(file) == 0;
    if (!ok || !closed || rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation)) {
        unlink(temporary.fileSystemRepresentation);
        return false;
    }
    return true;
}

bool Archive::read(const Entry &entry, std::vector<std::uint8_t> &out, std::uint32_t limit) const {
    out.clear();
    const auto *input = payload(entry);
    if (!input || entry.size > limit) return false;
    out.reserve(entry.size);
    return Stream(entry, input, [&](const std::uint8_t *bytes, std::size_t count) {
        out.insert(out.end(), bytes, bytes + count);
        return true;
    });
}

std::string Archive::SafeRelative(const std::string &name) {
    if (name.empty() || name[0] == '/' || name.find('\\') != std::string::npos ||
        name.find('\0') != std::string::npos)
        return {};
    std::string result;
    std::size_t start = 0;
    while (start <= name.size()) {
        const auto slash = name.find('/', start);
        const auto part = name.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        if (part == ".." || part == "__MACOSX" || (!part.empty() && part[0] == '.' && part != "."))
            return {};
        if (!part.empty() && part != ".") result += (result.empty() ? "" : "/") + part;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return result;
}
}
