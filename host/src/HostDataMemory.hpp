#pragma once

// Native storage for the original game's data layouts. This object never
// allocates executable memory and contains no code fetch/decode operation.
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace as6hostdata {
class DataMemory {
public:
    static constexpr std::uint32_t PageSize = 4096;
    static constexpr std::uint32_t ValiditySize = PageSize / 8;
    enum Permission : std::uint8_t { Read = 1, Write = 2 };
    struct WriteSpan {
        std::uint32_t address;
        const void *source;
        std::size_t length;
    };
    static constexpr std::size_t MaximumWriteSpans = 64;

private:
    struct Page {
        using Validity = std::array<std::uint8_t, ValiditySize>;
        std::array<std::uint8_t, PageSize> bytes{};
        std::uint8_t permissions;
        // nullptr preserves the ordinary heap/BSS all-valid fast path.
        std::unique_ptr<Validity> validity;
        // Loader validity only grows. Keep the bitmap for mapping/accounting,
        // but stop rescanning it once every byte has been initialized.
        bool all_valid = false;
        Page(std::uint8_t value, bool partial)
            : permissions(value), validity(partial ? new Validity{} : nullptr) {}

        bool valid(std::size_t offset, std::size_t length) const {
            if (!validity || all_valid) return true;
            if (!length) return true;
            // One bitmap test for short ranges; full bytes for the interior.
            // These masks never authorize holes adjacent to the requested range.
            const auto first = offset / 8;
            const auto last = (offset + length - 1) / 8;
            const auto head = std::uint8_t(0xffu << (offset % 8));
            const auto tail = std::uint8_t(0xffu >> (7 - ((offset + length - 1) % 8)));
            if (first == last) {
                const auto mask = std::uint8_t(head & tail);
                return ((*validity)[first] & mask) == mask;
            }
            if (((*validity)[first] & head) != head ||
                ((*validity)[last] & tail) != tail) return false;
            for (auto i = first + 1; i < last; ++i)
                if ((*validity)[i] != 0xffu) return false;
            return true;
        }

        void confirm(std::size_t offset, std::size_t length) {
            if (!length || all_valid) return;
            const auto first = offset / 8;
            const auto last = (offset + length - 1) / 8;
            const auto head = std::uint8_t(0xffu << (offset % 8));
            const auto tail = std::uint8_t(0xffu >> (7 - ((offset + length - 1) % 8)));
            if (first == last) (*validity)[first] |= std::uint8_t(head & tail);
            else {
                (*validity)[first] |= head;
                std::fill(validity->begin() + first + 1, validity->begin() + last, 0xffu);
                (*validity)[last] |= tail;
            }
            all_valid = std::all_of(validity->begin(), validity->end(),
                                    [](std::uint8_t value) { return value == 0xffu; });
        }
    };
    std::vector<std::unique_ptr<Page>> pages_;
    // Direct view for the owner's leased native execution, one entry per
    // page: bytes address | Read | Write once every byte is valid, else zero.
    std::vector<std::uintptr_t> direct_;
    static_assert(alignof(Page) >= 4, "direct entries keep permissions in the low bits");
    std::size_t mapped_pages_ = 0;
    std::size_t maximum_pages_;
    std::size_t partial_pages_ = 0;
    std::uint64_t maximum_storage_bytes_;

    // Constant copy widths let the host compiler emit unaligned-safe scalar
    // loads/stores, after the complete same-page range has been authorized.
    static void scalar_copy(void *destination, const void *source, std::size_t length) {
        switch (length) {
            case 1: std::memcpy(destination, source, 1); return;
            case 2: std::memcpy(destination, source, 2); return;
            case 4: std::memcpy(destination, source, 4); return;
            case 8: std::memcpy(destination, source, 8); return;
            case 16: std::memcpy(destination, source, 16); return;
            default: std::memcpy(destination, source, length); return;
        }
    }

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

    void refresh_direct(std::size_t index) {
        const auto *page = pages_[index].get();
        direct_[index] = page && (!page->validity || page->all_valid)
            ? reinterpret_cast<std::uintptr_t>(page->bytes.data()) | (page->permissions & (Read | Write))
            : 0;
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
        for (std::size_t i = 0; i < count; ++i) {
            pages_[first + i] = std::move(prepared[i]);
            refresh_direct(first + i);
        }
        mapped_pages_ += count;
        if (partial) partial_pages_ += count;
        return true;
    }

public:
    // Callers serialize shared access with the native execution/bridge lock.
    // A sparse address range must never authorize an unbounded physical heap.
    explicit DataMemory(std::uint64_t maximum_bytes = 512ULL * 1024 * 1024)
        : pages_(0x100000000ULL / PageSize), direct_(0x100000000ULL / PageSize),
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
    // Stable for this object's lifetime; entries change only under the
    // owner's serialization, like every other page mutation.
    const std::uintptr_t *direct_pages() const { return direct_.data(); }

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
            refresh_direct(std::size_t(cursor / PageSize));
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
        for (std::size_t i = 0; i < count; ++i) {
            pages_[first + i]->permissions = permissions;
            refresh_direct(first + i);
        }
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
            refresh_direct(first + i);
        }
        mapped_pages_ -= count;
        return true;
    }

    bool read(std::uint32_t address, void *destination, std::size_t length) const {
        if (length && length <= 16) {
            const auto offset = std::size_t(address % PageSize);
            if (address >= PageSize && length <= PageSize - offset) {
                const auto *page = pages_[address / PageSize].get();
                if (!destination || !page || (page->permissions & Read) != Read ||
                    !page->valid(offset, length)) return false;
                scalar_copy(destination, page->bytes.data() + offset, length);
                return true;
            }
        }
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
        if (length && length <= 16) {
            const auto offset = std::size_t(address % PageSize);
            if (address >= PageSize && length <= PageSize - offset) {
                auto *page = pages_[address / PageSize].get();
                if (!source || !page || (page->permissions & Write) != Write ||
                    !page->valid(offset, length)) return false;
                scalar_copy(page->bytes.data() + offset, source, length);
                return true;
            }
        }
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

    // Commit external staging buffers only after every destination passes the
    // same permission/validity checks as write(). The owner serializes this
    // entire operation; sources must not alias our private page storage.
    // Overlapping destinations commit in span order.
    bool write_batch(const WriteSpan *spans, std::size_t count) {
        if (count > MaximumWriteSpans || (!spans && count)) return false;
        for (std::size_t i = 0; i < count; ++i) {
            const auto &span = spans[i];
            if ((!span.source && span.length) ||
                !accessible(span.address, span.length, Write)) return false;
        }
        // No allocation or fallible access check remains in the commit phase.
        // A late invalid destination never publishes earlier spans.
        for (std::size_t i = 0; i < count; ++i) {
            const auto &span = spans[i];
            const auto *input = static_cast<const std::uint8_t *>(span.source);
            std::uint64_t cursor = span.address;
            std::size_t copied = 0;
            while (copied < span.length) {
                const auto offset = std::size_t(cursor % PageSize);
                const auto amount = std::min(span.length - copied, PageSize - offset);
                std::memcpy(pages_[cursor / PageSize]->bytes.data() + offset,
                            input + copied, amount);
                copied += amount;
                cursor += amount;
            }
        }
        return true;
    }

    // New source-only large Nav preflight: same permission/validity rule, no copy.
    bool nav_accessible(std::uint32_t at,std::uint64_t bytes,std::uint8_t permission) const {
        return bytes && permission && !(permission & ~(Read|Write)) && accessible(at,bytes,permission);
    }

    // Borrow only the checked range, under the caller's serialization lock.
    // Do not retain/use across protect, unmap, or concurrent mutation.
    const std::uint8_t *read_span(std::uint32_t address, std::size_t length) const {
        if (!length || length > PageSize - address % PageSize || !accessible(address, length, Read)) return nullptr;
        return pages_[address / PageSize]->bytes.data() + address % PageSize;
    }
};
} // namespace as6hostdata
