#pragma once

// Owned data-memory primitives only. No instruction fetch, decoder, CPU engine,
// guest executable image, or executable allocation is present.
#include "data_memory.hpp"
#include <algorithm>
#include <atomic>
#include <limits>
#include <mutex>

#if !defined(__aarch64__)
#error "This candidate requires native AArch64."
#endif

namespace as6aot {
class ArmAtomicMemory {
public:
    enum class Error : std::uint32_t {
        None = 0, InvalidWidth = 1, Alignment = 2, AccessFault = 3,
        MappingRejected = 4, ForeignMonitor = 5, ResourceLimit = 6,
        EpochExhausted = 7, UnsupportedBarrier = 8, UnsupportedMemory = 9,
    };
    enum class MemoryKind : std::uint32_t { Normal = 0, Device = 1, Unknown = 2 };
    static constexpr std::uint32_t GranuleBytes = 64;
    static constexpr std::size_t MaximumMonitors = 256;
    struct LoadResult { Error error; std::uint64_t value; };
    struct StorageUsage {
        std::size_t mapped_pages;
        std::uint64_t mapped_bytes, validity_bytes, allocated_bytes;
    };
    // status is architectural 0/1 only when error == None.
    struct StoreResult { Error error; std::uint32_t status; };
    struct Snapshot {
        std::uint32_t address = 0, width = 0, granule = 0;
        std::uint64_t reservation_version = 0, granule_version = 0;
        bool active = false;
    };

private:
    struct Identity {};
    struct State : Snapshot {};

public:
    // Each noncopyable handle represents one CPU's local monitor. Its private
    // state never escapes; the memory owns only weak registry entries. A handle
    // may outlive the memory safely and will be foreign to any replacement.
    class Monitor {
        friend class ArmAtomicMemory;
        std::shared_ptr<const Identity> identity_;
        std::shared_ptr<State> state_;
        Monitor(std::shared_ptr<const Identity> identity, std::shared_ptr<State> state)
            : identity_(std::move(identity)), state_(std::move(state)) {}
    public:
        Monitor(const Monitor &) = delete;
        Monitor &operator=(const Monitor &) = delete;
        ~Monitor() = default;
    };

private:
    mutable std::mutex mutex_;
    DataMemory data_;
    std::shared_ptr<const Identity> identity_ = std::make_shared<Identity>();
    std::vector<std::weak_ptr<State>> monitors_;
    std::uint64_t epoch_ = 0;

    State *owned(const Monitor &monitor) const {
        return monitor.identity_.get() == identity_.get() ? monitor.state_.get() : nullptr;
    }
    static bool width_valid(std::uint32_t width) {
        return width == 1 || width == 2 || width == 4 || width == 8;
    }
    static Error exclusive_address(std::uint32_t address, std::uint32_t width) {
        if (!width_valid(width)) return Error::InvalidWidth;
        if (address % width) return Error::Alignment;
        if (address < DataMemory::PageSize || std::uint64_t(address) + width > 0x100000000ULL)
            return Error::AccessFault;
        return Error::None;
    }
    static bool permissions_valid(std::uint32_t permissions) {
        return permissions && !(permissions & ~(std::uint32_t(DataMemory::Read | DataMemory::Write)));
    }
    bool can_mutate() const { return epoch_ != std::numeric_limits<std::uint64_t>::max(); }
    // All mutation paths call this under the same lock after a successful,
    // all-or-nothing DataMemory mutation. No allocation or throwing work here.
    void mutation(std::uint32_t address, std::uint64_t length) noexcept {
        const std::uint64_t version = ++epoch_;
        const std::uint64_t end = std::uint64_t(address) + length;
        for (auto &weak : monitors_) if (auto state = weak.lock()) {
            if (state->width && std::uint64_t(state->granule) < end &&
                std::uint64_t(state->granule) + GranuleBytes > address) {
                state->granule_version = version;
                state->active = false;
            }
        }
    }
    static std::uint64_t decode(const std::uint8_t *bytes, std::uint32_t width) {
        std::uint64_t value = 0;
        for (std::uint32_t i = 0; i < width; ++i) value |= std::uint64_t(bytes[i]) << (i * 8);
        return value;
    }
    static void encode(std::uint8_t *bytes, std::uint32_t width, std::uint64_t value) {
        for (std::uint32_t i = 0; i < width; ++i) bytes[i] = std::uint8_t(value >> (i * 8));
    }

public:
    explicit ArmAtomicMemory(std::uint64_t maximum_bytes = 64ULL * 1024 * 1024)
        : data_(maximum_bytes) {}
    ArmAtomicMemory(const ArmAtomicMemory &) = delete;
    ArmAtomicMemory &operator=(const ArmAtomicMemory &) = delete;

    StorageUsage storage_usage() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return {data_.mapped_pages(), data_.mapped_bytes(), data_.validity_bytes(), data_.allocated_bytes()};
    }

    Error make_monitor(std::unique_ptr<Monitor> &output) {
        std::lock_guard<std::mutex> lock(mutex_);
        monitors_.erase(std::remove_if(monitors_.begin(), monitors_.end(),
            [](const auto &weak) { return weak.expired(); }), monitors_.end());
        if (monitors_.size() >= MaximumMonitors) return Error::ResourceLimit;
        try {
            auto state = std::make_shared<State>();
            auto handle = std::unique_ptr<Monitor>(new Monitor(identity_, state));
            monitors_.push_back(state);
            output = std::move(handle);
            return Error::None;
        } catch (const std::bad_alloc &) { return Error::ResourceLimit; }
    }
    Error snapshot(const Monitor &monitor, Snapshot &output) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const State *state = owned(monitor);
        if (!state) return Error::ForeignMonitor;
        output = *state;
        return Error::None;
    }
    Error clrex(Monitor &monitor) {
        std::lock_guard<std::mutex> lock(mutex_);
        State *state = owned(monitor);
        if (!state) return Error::ForeignMonitor;
        state->active = false;
        return Error::None;
    }
    Error map(std::uint32_t address, std::uint64_t length, std::uint32_t permissions,
              MemoryKind kind = MemoryKind::Normal) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (kind != MemoryKind::Normal) return Error::UnsupportedMemory;
        if (!permissions_valid(permissions)) return Error::MappingRejected;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.map(address, length, std::uint8_t(permissions))) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error protect(std::uint32_t address, std::uint64_t length, std::uint32_t permissions) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!permissions_valid(permissions)) return Error::MappingRejected;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.protect(address, length, std::uint8_t(permissions))) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error map_partial_data(std::uint32_t address, std::uint64_t length, std::uint32_t permissions,
                           MemoryKind kind = MemoryKind::Normal) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (kind != MemoryKind::Normal) return Error::UnsupportedMemory;
        if (!permissions_valid(permissions)) return Error::MappingRejected;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.map_partial_data(address, length, std::uint8_t(permissions))) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    // Explicit trusted-loader authority, including read-only partial data.
    // Validity/data commit and all monitor invalidation use the shared lock.
    Error initialize_data(std::uint32_t address, const void *source, std::size_t length) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.initialize_data(address, source, length)) return Error::AccessFault;
        mutation(address, length);
        return Error::None;
    }
    Error unmap(std::uint32_t address, std::uint64_t length) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.unmap(address, length)) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error read(std::uint32_t address, void *destination, std::size_t length) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return data_.read(address, destination, length) ? Error::None : Error::AccessFault;
    }
    Error write(std::uint32_t address, const void *source, std::size_t length) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (length && !can_mutate()) return Error::EpochExhausted;
        if (!data_.write(address, source, length)) return Error::AccessFault;
        if (length) mutation(address, length);
        return Error::None;
    }
    LoadResult ldrex(Monitor &monitor, std::uint32_t address, std::uint32_t width) {
        std::lock_guard<std::mutex> lock(mutex_);
        State *state = owned(monitor);
        if (!state) return {Error::ForeignMonitor, 0};
        state->active = false;
        const Error error = exclusive_address(address, width);
        if (error != Error::None) return {error, 0};
        std::uint8_t bytes[8]{};
        if (!data_.read(address, bytes, width)) return {Error::AccessFault, 0};
        state->address = address; state->width = width;
        state->granule = address & ~(GranuleBytes - 1);
        state->reservation_version = state->granule_version = epoch_;
        state->active = true;
        return {Error::None, decode(bytes, width)};
    }
    StoreResult strex(Monitor &monitor, std::uint32_t address, std::uint32_t width, std::uint64_t value) {
        std::lock_guard<std::mutex> lock(mutex_);
        State *state = owned(monitor);
        if (!state) return {Error::ForeignMonitor, 1};
        const Snapshot reserved = *state;
        state->active = false; // Every owned attempt consumes the local monitor.
        if (!width_valid(width)) return {Error::InvalidWidth, 1};
        // A failed local reservation performs no address translation or data
        // access. In particular, NULL/unaligned addresses must still return 1
        // here when no matching reservation exists (ARM STREX order).
        if (!reserved.active || reserved.address != address || reserved.width != width ||
            reserved.reservation_version != reserved.granule_version) return {Error::None, 1};
        const Error error = exclusive_address(address, width);
        if (error != Error::None) return {error, 1};
        if (!can_mutate()) return {Error::EpochExhausted, 1};
        std::uint8_t bytes[8]{}; encode(bytes, width, value);
        if (!data_.write(address, bytes, width)) return {Error::AccessFault, 1};
        mutation(address, width);
        return {Error::None, 0};
    }
    LoadResult swap(std::uint32_t address, std::uint32_t width, std::uint64_t value) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (width != 1 && width != 4) return {Error::InvalidWidth, 0};
        const Error error = exclusive_address(address, width);
        if (error != Error::None) return {error, 0};
        if (!can_mutate()) return {Error::EpochExhausted, 0};
        std::uint8_t old_bytes[4]{}, new_bytes[4]{};
        if (!data_.read(address, old_bytes, width)) return {Error::AccessFault, 0};
        encode(new_bytes, width, value);
        // Both permission checks and the exchange are under the same lock.
        // DataMemory prevalidates the entire write before changing any byte.
        if (!data_.write(address, new_bytes, width)) return {Error::AccessFault, 0};
        mutation(address, width);
        return {Error::None, decode(old_bytes, width)};
    }
    Error dmb(std::uint32_t option) {
        std::lock_guard<std::mutex> lock(mutex_);
        switch (option) {
            case 0xf: case 0xe: case 0xb: case 0xa:
            case 0x7: case 0x6: case 0x3: case 0x2: break;
            default: return Error::UnsupportedBarrier;
        }
        // All supported scopes are conservatively strengthened for this
        // process's Normal data storage. Device/I/O memory is unsupported.
        std::atomic_thread_fence(std::memory_order_seq_cst);
        __asm__ __volatile__("dmb sy" ::: "memory");
        return Error::None;
    }
};
} // namespace as6aot
