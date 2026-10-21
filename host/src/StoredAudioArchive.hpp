#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace as6::audio {

enum class ArchiveErrorCode {
    InvalidArchive,
    UnsupportedFeature,
    DuplicateName,
    MissingMember,
    Range,
};

class ArchiveError : public std::runtime_error {
public:
    ArchiveError(ArchiveErrorCode code, const std::string &message);
    ArchiveErrorCode code() const noexcept { return code_; }
private:
    ArchiveErrorCode code_;
};

// Read-only stored members of the observed audio archive format. Both original
// local-header signatures are accepted; the directory/footer must use the
// observed custom signatures. This is deliberately not a general ZIP reader.
// Construction indexes metadata; payload CRC verification is left to the caller.
class StoredAudioArchive final {
public:
    struct Entry {
        std::string name;                 // Original bytes, no normalization.
        std::uint64_t localHeaderOffset;
        std::uint64_t dataOffset;
        std::uint64_t size;
        std::uint32_t crc32;
    };

    // Throws ArchiveError for unsupported/malformed metadata, std::system_error
    // for OS failures, or the usual allocation exceptions. Owns an O_RDONLY fd.
    explicit StoredAudioArchive(const std::string &path);
    ~StoredAudioArchive();
    StoredAudioArchive(StoredAudioArchive &&) noexcept;
    StoredAudioArchive &operator=(StoredAudioArchive &&) noexcept;
    StoredAudioArchive(const StoredAudioArchive &) = delete;
    StoredAudioArchive &operator=(const StoredAudioArchive &) = delete;

    const std::vector<Entry> &entries() const noexcept;
    const Entry *findExact(std::string_view name) const noexcept;
    std::uint64_t fileSize() const noexcept;

    // Concurrent calls on the same live object use pread and share no cursor.
    // A zero-byte read at EOF is valid and may use nullptr. Bounds/name errors
    // are rejected before touching output; an OS error/EOF can leave a partial
    // result. Moving/destroying the object concurrently with reads is invalid.
    void readRange(std::string_view name, std::uint64_t memberOffset,
                   void *output, std::size_t bytes) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace as6::audio
