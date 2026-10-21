#include "StoredAudioArchive.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <fcntl.h>
#include <limits>
#include <map>
#include <sys/stat.h>
#include <system_error>
#include <unistd.h>
#include <utility>

namespace as6::audio {
namespace {

constexpr std::uint32_t LocalPk = 0x04034b50;
constexpr std::uint32_t LocalQl = 0x05044c51;
constexpr std::uint32_t Directory = 0x07050701;
constexpr std::uint32_t Footer = 0x03010701;
constexpr std::uint32_t Zip64Marker = 0xffffffff;
static_assert(sizeof(off_t) >= 8, "Audio archives require 64-bit pread offsets");
static_assert(sizeof(std::size_t) <= sizeof(std::uint64_t));

[[noreturn]] void invalid(const char *message) {
    throw ArchiveError(ArchiveErrorCode::InvalidArchive, message);
}
[[noreturn]] void unsupported(const char *message) {
    throw ArchiveError(ArchiveErrorCode::UnsupportedFeature, message);
}
std::uint16_t u16(const unsigned char *p) {
    return std::uint16_t(p[0]) | (std::uint16_t(p[1]) << 8);
}
std::uint32_t u32(const unsigned char *p) {
    return std::uint32_t(u16(p)) | (std::uint32_t(u16(p + 2)) << 16);
}
bool fits(std::uint64_t offset, std::uint64_t bytes, std::uint64_t limit) {
    return offset <= limit && bytes <= limit - offset;
}
class FileDescriptor {
public:
    explicit FileDescriptor(const std::string &path) {
        if (path.find('\0') != std::string::npos)
            throw std::invalid_argument("Archive path contains NUL");
        do { value_ = ::open(path.c_str(), O_RDONLY | O_CLOEXEC); }
        while (value_ < 0 && errno == EINTR);
        if (value_ < 0) throw std::system_error(errno, std::generic_category(), "open audio archive");
    }
    ~FileDescriptor() { if (value_ >= 0) ::close(value_); }
    FileDescriptor(const FileDescriptor &) = delete;
    FileDescriptor &operator=(const FileDescriptor &) = delete;
    int get() const noexcept { return value_; }
private:
    int value_ = -1;
};

void preadExact(int fd, std::uint64_t fileSize, std::uint64_t offset,
                void *output, std::size_t bytes) {
    if (!fits(offset, bytes, fileSize) ||
        offset > std::uint64_t(std::numeric_limits<off_t>::max()))
        invalid("Archive read exceeds file bounds");
    auto *destination = static_cast<unsigned char *>(output);
    while (bytes) {
        const auto chunk = std::min(bytes, std::size_t(std::numeric_limits<ssize_t>::max()));
        const auto got = ::pread(fd, destination, chunk, static_cast<off_t>(offset));
        if (got < 0) {
            if (errno == EINTR) continue;
            throw std::system_error(errno, std::generic_category(), "pread audio archive");
        }
        if (!got) invalid("Unexpected EOF while reading audio archive");
        const auto count = static_cast<std::size_t>(got);
        destination += count; bytes -= count; offset += count;
    }
}

std::string readName(int fd, std::uint64_t fileSize, std::uint64_t at, std::uint16_t size) {
    if (!size) invalid("Empty audio member name");
    std::string name(size, '\0');
    preadExact(fd, fileSize, at, name.data(), name.size());
    if (name.find('\0') != std::string::npos) invalid("NUL in audio member name");
    return name;
}

} // namespace

ArchiveError::ArchiveError(ArchiveErrorCode code, const std::string &message)
    : std::runtime_error(message), code_(code) {}

struct StoredAudioArchive::Impl {
    FileDescriptor fd;
    std::uint64_t fileSize = 0;
    std::vector<Entry> entries;
    std::map<std::string, std::size_t, std::less<>> names;

    explicit Impl(const std::string &path) : fd(path) {
        struct stat info{};
        if (::fstat(fd.get(), &info))
            throw std::system_error(errno, std::generic_category(), "stat audio archive");
        if (!S_ISREG(info.st_mode) || info.st_size < 22) invalid("Audio archive is not a complete regular file");
        fileSize = static_cast<std::uint64_t>(info.st_size);

        std::array<unsigned char, 22> footer{};
        preadExact(fd.get(), fileSize, fileSize - footer.size(), footer.data(), footer.size());
        if (u32(footer.data()) != Footer) unsupported("Unrecognized audio archive footer signature");
        if (u16(footer.data() + 4) || u16(footer.data() + 6)) unsupported("Multi-disk audio archive");
        const auto count = u16(footer.data() + 10);
        if (count == 0xffff || u32(footer.data() + 12) == Zip64Marker || u32(footer.data() + 16) == Zip64Marker)
            unsupported("ZIP64 audio archive");
        if (u16(footer.data() + 8) != count) invalid("Audio archive directory counts disagree");
        if (u16(footer.data() + 20)) unsupported("Audio archive footer comment");
        const std::uint64_t directorySize = u32(footer.data() + 12);
        const std::uint64_t directoryOffset = u32(footer.data() + 16);
        const auto directoryEnd = fileSize - footer.size();
        if (!fits(directoryOffset, directorySize, directoryEnd) || directoryOffset + directorySize != directoryEnd)
            invalid("Audio archive directory bounds disagree");

        entries.reserve(count);
        std::map<std::uint64_t, std::size_t> offsets;
        std::vector<std::uint16_t> versions;
        versions.reserve(count);
        std::uint64_t cursor = 0;
        while (cursor < directoryOffset) {
            if (entries.size() >= count || !fits(cursor, 30, directoryOffset)) invalid("Unexpected audio local record count/bounds");
            std::array<unsigned char, 30> local{};
            preadExact(fd.get(), fileSize, cursor, local.data(), local.size());
            const auto signature = u32(local.data());
            if (signature != LocalPk && signature != LocalQl) unsupported("Unrecognized audio local header signature");
            if (u16(local.data() + 6) || u16(local.data() + 8)) unsupported("Only flags-zero stored audio members are supported");
            const auto storedSize = u32(local.data() + 18);
            const auto originalSize = u32(local.data() + 22);
            if (storedSize == Zip64Marker || originalSize == Zip64Marker) unsupported("ZIP64 audio member");
            if (storedSize != originalSize) invalid("Stored audio member sizes disagree");
            if (u16(local.data() + 28)) unsupported("Audio local extra fields");
            const auto nameSize = u16(local.data() + 26);
            const auto nameOffset = cursor + local.size();
            if (!fits(nameOffset, nameSize, directoryOffset)) invalid("Audio local name exceeds data region");
            auto name = readName(fd.get(), fileSize, nameOffset, nameSize);
            const auto dataOffset = nameOffset + nameSize;
            if (!fits(dataOffset, storedSize, directoryOffset)) invalid("Audio member exceeds data region");
            const auto index = entries.size();
            if (!names.emplace(name, index).second)
                throw ArchiveError(ArchiveErrorCode::DuplicateName, "Duplicate exact audio member name");
            offsets.emplace(cursor, index);
            versions.push_back(u16(local.data() + 4));
            entries.push_back({std::move(name), cursor, dataOffset, storedSize, u32(local.data() + 14)});
            cursor = dataOffset + storedSize;
        }
        if (cursor != directoryOffset || entries.size() != count) invalid("Audio local records do not cover the directory count");

        std::vector<bool> seen(count, false);
        for (std::size_t record = 0; record < count; ++record) {
            if (!fits(cursor, 46, directoryEnd)) invalid("Truncated audio directory record");
            std::array<unsigned char, 46> central{};
            preadExact(fd.get(), fileSize, cursor, central.data(), central.size());
            if (u32(central.data()) != Directory) unsupported("Unrecognized audio directory signature");
            if (u16(central.data() + 8) || u16(central.data() + 10)) unsupported("Only flags-zero stored directory records are supported");
            if (u16(central.data() + 34)) unsupported("Multi-disk audio directory member");
            if (u16(central.data() + 30) || u16(central.data() + 32)) unsupported("Audio directory extra fields/comments");
            const auto nameSize = u16(central.data() + 28);
            const auto nameOffset = cursor + central.size();
            if (!fits(nameOffset, nameSize, directoryEnd)) invalid("Audio directory name exceeds directory bounds");
            const auto name = readName(fd.get(), fileSize, nameOffset, nameSize);
            const auto offset = u32(central.data() + 42);
            if (offset == Zip64Marker) unsupported("ZIP64 audio local offset");
            const auto found = offsets.find(offset);
            if (found == offsets.end() || seen[found->second]) invalid("Audio directory references a missing/repeated local record");
            const auto index = found->second;
            const auto &entry = entries[index];
            if (name != entry.name || u16(central.data() + 6) != versions[index] ||
                u32(central.data() + 16) != entry.crc32 ||
                u32(central.data() + 20) != entry.size || u32(central.data() + 24) != entry.size)
                invalid("Audio central/local metadata mismatch");
            seen[index] = true;
            cursor = nameOffset + nameSize;
        }
        if (cursor != directoryEnd) invalid("Trailing/unindexed audio directory bytes");
    }
};

StoredAudioArchive::StoredAudioArchive(const std::string &path) : impl_(std::make_unique<Impl>(path)) {}
StoredAudioArchive::~StoredAudioArchive() = default;
StoredAudioArchive::StoredAudioArchive(StoredAudioArchive &&) noexcept = default;
StoredAudioArchive &StoredAudioArchive::operator=(StoredAudioArchive &&) noexcept = default;

const std::vector<StoredAudioArchive::Entry> &StoredAudioArchive::entries() const noexcept {
    static const std::vector<Entry> empty;
    return impl_ ? impl_->entries : empty;
}
const StoredAudioArchive::Entry *StoredAudioArchive::findExact(std::string_view name) const noexcept {
    if (!impl_) return nullptr;
    const auto found = impl_->names.find(name);
    return found == impl_->names.end() ? nullptr : &impl_->entries[found->second];
}
std::uint64_t StoredAudioArchive::fileSize() const noexcept { return impl_ ? impl_->fileSize : 0; }
void StoredAudioArchive::readRange(std::string_view name, std::uint64_t memberOffset,
                                  void *output, std::size_t bytes) const {
    if (!impl_) throw std::logic_error("Read from moved-from audio archive");
    const auto *entry = findExact(name);
    if (!entry) throw ArchiveError(ArchiveErrorCode::MissingMember, "Exact audio member name not found");
    if (!fits(memberOffset, bytes, entry->size)) throw ArchiveError(ArchiveErrorCode::Range, "Read exceeds audio member bounds");
    if (bytes && !output) throw std::invalid_argument("Null audio range output");
    preadExact(impl_->fd.get(), impl_->fileSize, entry->dataOffset + memberOffset, output, bytes);
}

} // namespace as6::audio
