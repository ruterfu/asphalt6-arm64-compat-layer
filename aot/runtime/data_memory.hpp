#pragma once

// Native storage for the original game's data layouts. This object never
// allocates executable memory and contains no code fetch/decode operation.
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace as6aot {
class DataMemory {
public:
    static constexpr std::uint32_t PageSize = 4096;
    static constexpr std::uint32_t ValiditySize = PageSize / 8;
    enum Permission : std::uint8_t { Read = 1, Write = 2 };

private:
    struct Page {
        using Validity = std::array<std::uint8_t, ValiditySize>;
        std::array<std::uint8_t, PageSize> bytes{};
        std::uint8_t permissions;
        // nullptr preserves the ordinary heap/BSS all-valid fast path.
        std::unique_ptr<Validity> validity;
        Page(std::uint8_t value, bool partial)
            : permissions(value), validity(partial ? new Validity{} : nullptr) {}

        bool valid(std::size_t offset, std::size_t length) const {
            if (!validity) return true;
            for (std::size_t i = offset; i < offset + length; ++i) {
                if (((*validity)[i / 8] & (1u << (i % 8))) == 0) return false;
            }
            return true;
        }

        void confirm(std::size_t offset, std::size_t length) {
            for (std::size_t i = offset; i < offset + length; ++i) {
                (*validity)[i / 8] |= std::uint8_t(1u << (i % 8));
            }
        }
    };
    std::vector<std::unique_ptr<Page>> pages_;
    std::size_t mapped_pages_ = 0;
    std::size_t maximum_pages_;
    std::size_t partial_pages_ = 0;
    std::uint64_t maximum_storage_bytes_;

    static bool interval(std::uint32_t address, std::uint64_t length) {
        return address >= PageSize && length <= 0x100000000ULL - address;
    }

    bool accessible(std::uint32_t address, std::uint64_t length, std::uint8_t permission) const {
        if (!interval(address, length)) return false;
        std::uint64_t cursor = address;
        const std::uint64_t end = cursor + length;
        while (cursor < end) {
            const auto &page = pages_[cursor / PageSize];
            if (!page || (page->permissions & permission) != permission) return false;
            const auto offset = std::size_t(cursor % PageSize);
            const auto amount = std::size_t(end - cursor < PageSize - offset
                ? end - cursor : PageSize - offset);
            if (!page->valid(offset, amount)) return false;
            cursor += amount;
        }
        return true;
    }

    bool partial_range(std::uint32_t address, std::uint64_t length) const {
        if (!interval(address, length)) return false;
        const std::uint64_t end = std::uint64_t(address) + length;
        std::uint64_t cursor = address;
        while (cursor < end) {
            const auto &page = pages_[cursor / PageSize];
            if (!page || !page->validity) return false;
            cursor = (cursor / PageSize + 1) * PageSize;
        }
        return true;
    }

    bool map_pages(std::uint32_t address, std::uint64_t length,
                   std::uint8_t permissions, bool partial) {
        if (!length || !interval(address, length) || address % PageSize || length % PageSize ||
            !permissions || (permissions & ~(Read | Write))) return false;
        const auto first = std::size_t(address / PageSize);
        const auto count = std::size_t(length / PageSize);
        const std::uint64_t cost = std::uint64_t(count) * (PageSize + (partial ? ValiditySize : 0));
        if (count > maximum_pages_ - mapped_pages_ || cost > maximum_storage_bytes_ - allocated_bytes()) return false;
        for (std::size_t i = 0; i < count; ++i) if (pages_[first + i]) return false;
        std::vector<std::unique_ptr<Page>> prepared;
        try {
            prepared.reserve(count);
            for (std::size_t i = 0; i < count; ++i) prepared.emplace_back(new Page(permissions, partial));
        } catch (const std::bad_alloc &) {
            return false;
        }
        for (std::size_t i = 0; i < count; ++i) pages_[first + i] = std::move(prepared[i]);
        mapped_pages_ += count;
        if (partial) partial_pages_ += count;
        return true;
    }

public:
    // Callers serialize shared access with the native execution/bridge lock.
    // A sparse address range must never authorize an unbounded physical heap.
    explicit DataMemory(std::uint64_t maximum_bytes = 512ULL * 1024 * 1024)
        : pages_(0x100000000ULL / PageSize),
          maximum_pages_(std::size_t((maximum_bytes < 0x100000000ULL - PageSize
              ? maximum_bytes : 0x100000000ULL - PageSize) / PageSize)),
          maximum_storage_bytes_(maximum_bytes) {}
    DataMemory(const DataMemory &) = delete;
    DataMemory &operator=(const DataMemory &) = delete;

    std::size_t mapped_pages() const { return mapped_pages_; }
    std::uint64_t mapped_bytes() const { return std::uint64_t(mapped_pages_) * PageSize; }
    std::uint64_t validity_bytes() const { return std::uint64_t(partial_pages_) * ValiditySize; }
    // Payload accounting, not process RSS: as before, the fixed sparse page
    // table and small Page/allocator metadata are not charged to this cap.
    std::uint64_t allocated_bytes() const { return mapped_bytes() + validity_bytes(); }

    bool map(std::uint32_t address, std::uint64_t length, std::uint8_t permissions) {
        return map_pages(address, length, permissions, false);
    }

    // Holes remain unreadable/unwritable until the trusted loader confirms
    // the exact allowlisted data bytes. This class does not verify provenance.
    bool map_partial_data(std::uint32_t address, std::uint64_t length, std::uint8_t permissions) {
        return map_pages(address, length, permissions, true);
    }

    // Loader-only authority: may initialize read-only partial-data pages.
    // It cannot alter ordinary mappings or certify bytes outside this range.
    // Source is an external readable buffer, with the same nonaliasing contract
    // as write(). There is no mutable span exposing private storage.
    bool initialize_data(std::uint32_t address, const void *source, std::size_t length) {
        if (!source || !length || !partial_range(address, length)) return false;
        const auto *input = static_cast<const std::uint8_t *>(source);
        std::uint64_t cursor = address;
        std::size_t copied = 0;
        while (copied < length) {
            const auto offset = std::size_t(cursor % PageSize);
            const auto amount = (length - copied < PageSize - offset) ? length - copied : PageSize - offset;
            auto &page = *pages_[cursor / PageSize];
            std::memcpy(page.bytes.data() + offset, input + copied, amount);
            page.confirm(offset, amount);
            copied += amount;
            cursor += amount;
        }
        return true;
    }

    bool protect(std::uint32_t address, std::uint64_t length, std::uint8_t permissions) {
        if (!length || !interval(address, length) || address % PageSize || length % PageSize ||
            !permissions || (permissions & ~(Read | Write))) return false;
        const auto first = std::size_t(address / PageSize);
        const auto count = std::size_t(length / PageSize);
        for (std::size_t i = 0; i < count; ++i) if (!pages_[first + i]) return false;
        for (std::size_t i = 0; i < count; ++i) pages_[first + i]->permissions = permissions;
        return true;
    }

    bool unmap(std::uint32_t address, std::uint64_t length) {
        if (!length || !interval(address, length) || address % PageSize || length % PageSize) return false;
        const auto first = std::size_t(address / PageSize);
        const auto count = std::size_t(length / PageSize);
        for (std::size_t i = 0; i < count; ++i) if (!pages_[first + i]) return false;
        for (std::size_t i = 0; i < count; ++i) {
            if (pages_[first + i]->validity) --partial_pages_;
            pages_[first + i].reset();
        }
        mapped_pages_ -= count;
        return true;
    }

    bool read(std::uint32_t address, void *destination, std::size_t length) const {
        if ((!destination && length) || !accessible(address, length, Read)) return false;
        auto *out = static_cast<std::uint8_t *>(destination);
        std::uint64_t cursor = address;
        std::size_t copied = 0;
        while (copied < length) {
            const auto offset = std::size_t(cursor % PageSize);
            const auto amount = (length - copied < PageSize - offset) ? length - copied : PageSize - offset;
            std::memcpy(out + copied, pages_[cursor / PageSize]->bytes.data() + offset, amount);
            copied += amount;
            cursor += amount;
        }
        return true;
    }

    // Source is an external readable buffer, not an alias obtained from this
    // object's read_span. No partial page can gain validity through write().
    bool write(std::uint32_t address, const void *source, std::size_t length) {
        if ((!source && length) || !accessible(address, length, Write)) return false;
        const auto *input = static_cast<const std::uint8_t *>(source);
        std::uint64_t cursor = address;
        std::size_t copied = 0;
        while (copied < length) {
            const auto offset = std::size_t(cursor % PageSize);
            const auto amount = (length - copied < PageSize - offset) ? length - copied : PageSize - offset;
            std::memcpy(pages_[cursor / PageSize]->bytes.data() + offset, input + copied, amount);
            copied += amount;
            cursor += amount;
        }
        return true;
    }

    // Borrow only the checked range, under the caller's serialization lock.
    // Do not retain/use across protect, unmap, or concurrent mutation.
    const std::uint8_t *read_span(std::uint32_t address, std::size_t length) const {
        if (!length || length > PageSize - address % PageSize || !accessible(address, length, Read)) return nullptr;
        return pages_[address / PageSize]->bytes.data() + address % PageSize;
    }
};
} // namespace as6aot
