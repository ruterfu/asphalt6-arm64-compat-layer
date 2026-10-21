#pragma once

// Owned data-memory primitives only. No instruction fetch, decoder, CPU engine,
// guest executable image, or executable allocation is present.
#include "HostDataMemory.hpp"
#include "aot_support.hpp"
#include <algorithm>
#include <atomic>
#include <limits>
#include <mutex>
#include <exception>
#include <functional>

#if !defined(__aarch64__)
#error "This candidate requires native AArch64."
#endif

namespace as6hostdata {
class ArmAtomicMemory {
public:
    enum class Error : std::uint32_t {
        None = 0, InvalidWidth = 1, Alignment = 2, AccessFault = 3,
        MappingRejected = 4, ForeignMonitor = 5, ResourceLimit = 6,
        EpochExhausted = 7, UnsupportedBarrier = 8, UnsupportedMemory = 9,
        LeaseConflict = 10,
    };
    enum class MemoryKind : std::uint32_t { Normal = 0, Device = 1, Unknown = 2 };
    static constexpr std::uint32_t GranuleBytes = 64;
    static constexpr std::size_t MaximumMonitors = 256;
    struct LoadResult { Error error; std::uint64_t value; };
    struct StorageUsage {
        std::size_t mapped_pages;
        std::uint64_t mapped_bytes, validity_bytes, allocated_bytes;
        Error error = Error::None;
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
    // state never escapes. The memory retains bounded registry ownership until
    // the next registration reclaims states whose handles have retired. A handle
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
    std::vector<std::shared_ptr<State>> monitors_;
    std::uint64_t epoch_ = 0;
    // Granules that mutation() can invalidate: every monitor with a width.
    // Rebuilt whenever a granule is armed or the registry changes.
    std::array<std::uint32_t, MaximumMonitors> reserved_granules_{};
    std::size_t reserved_count_ = 0;
    as6aot::DirectMemory direct_{};
    static_assert(as6aot::DirectMemory::PageSize == DataMemory::PageSize &&
                  as6aot::DirectMemory::GranuleBytes == GranuleBytes &&
                  as6aot::DirectMemory::Readable == DataMemory::Read &&
                  as6aot::DirectMemory::Writable == DataMemory::Write,
                  "direct view must match the owned storage");
    void refresh_reservations() noexcept {
        reserved_count_ = 0;
        for (const auto &state : monitors_)
            if (state->width) reserved_granules_[reserved_count_++] = state->granule;
    }

    struct LeaseLink {
        const ArmAtomicMemory *owner;
        LeaseLink *previous;
    };
    // TLS ownership is exact to one storage object, never a process-wide
    // unlocked flag. A live lease keeps that object's original mutex locked.
    static inline thread_local LeaseLink *active_lease_ = nullptr;
    static bool leased_here(const ArmAtomicMemory *owner) noexcept {
        for (auto *link = active_lease_; link; link = link->previous)
            if (link->owner == owner) return true;
        return false;
    }
    static bool lock_order_valid(const ArmAtomicMemory *owner) noexcept {
        const std::less<const ArmAtomicMemory *> before;
        for (auto *link = active_lease_; link; link = link->previous)
            if (link->owner != owner && before(owner, link->owner)) return false;
        return true;
    }
    class OperationLock {
        std::unique_lock<std::mutex> lock_;
        bool valid_ = true;
    public:
        explicit OperationLock(const ArmAtomicMemory &memory)
            : lock_(memory.mutex_, std::defer_lock) {
            if (leased_here(&memory)) return;
            if (!lock_order_valid(&memory)) { valid_ = false; return; }
            lock_.lock();
        }
        bool valid() const noexcept { return valid_; }
    };


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
        // Registry ownership keeps each State alive while this lock is held.
        // Ordinary writes do not acquire/release a shared reference per monitor.
        for (const auto &state : monitors_) {
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
    // Scope exactly one native execute invocation, ending before Host bridges
    // or any VM-lock handoff. The memory must outlive the scope. Leases are
    // nonmovable and strictly LIFO; same-object nesting borrows the held lock.
    // Distinct objects may nest in std::less pointer order only. Every ordinary
    // operation also checks that order, so read(B) while leased(A) cannot hide
    // an ABBA acquisition. Invalid ordering is reported without touching B.
    class ExecutionLease {
        friend class ArmAtomicMemory;
        OperationLock lock_;
        LeaseLink link_;
        bool published_;
        explicit ExecutionLease(const ArmAtomicMemory &memory)
            : lock_(memory), link_{&memory, active_lease_}, published_(lock_.valid()) {
            if (published_) active_lease_ = &link_;
        }
    public:
        ExecutionLease(const ExecutionLease &) = delete;
        ExecutionLease &operator=(const ExecutionLease &) = delete;
        ExecutionLease(ExecutionLease &&) = delete;
        ExecutionLease &operator=(ExecutionLease &&) = delete;
        ~ExecutionLease() noexcept {
            if (!published_) return;
            // Out-of-order destruction would invalidate a borrowing scope.
            if (active_lease_ != &link_) std::terminate();
            active_lease_ = link_.previous;
        }
        bool valid() const noexcept { return published_; }
    };
    ExecutionLease execution_lease() const { return ExecutionLease(*this); }

    explicit ArmAtomicMemory(std::uint64_t maximum_bytes = 64ULL * 1024 * 1024)
        : data_(maximum_bytes) {
        direct_ = {data_.direct_pages(), &epoch_, reserved_granules_.data(), &reserved_count_};
    }
    ArmAtomicMemory(const ArmAtomicMemory &) = delete;
    ArmAtomicMemory &operator=(const ArmAtomicMemory &) = delete;

    // Use only inside this thread's valid ExecutionLease of this memory: the
    // lease holds the mutex that every other access path takes.
    const as6aot::DirectMemory *direct_memory() const { return &direct_; }

    // Isolated prototype diagnostics under the same real storage lock.
    std::uint64_t nav_epoch() const {OperationLock lock(*this);return lock.valid()?epoch_:0;}
#if defined(AS6_NAV_LEAF_FIXTURE)
    // Test-only overflow injection; never present in a production build.
    void nav_force_epoch_for_fixture(std::uint64_t value) {OperationLock lock(*this);if(lock.valid())epoch_=value;}
#endif
    StorageUsage storage_usage() const {
        OperationLock lock(*this);
        if (!lock.valid()) return {0,0,0,0,Error::LeaseConflict};
        return {data_.mapped_pages(), data_.mapped_bytes(), data_.validity_bytes(), data_.allocated_bytes()};
    }

    Error make_monitor(std::unique_ptr<Monitor> &output) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        monitors_.erase(std::remove_if(monitors_.begin(), monitors_.end(),
            // No external State references escape. A registry-only reference
            // means that Monitor has retired; reclaim only on this cold path.
            [](const auto &state) { return state.use_count() == 1; }), monitors_.end());
        if (monitors_.size() >= MaximumMonitors) return Error::ResourceLimit;
        try {
            auto state = std::make_shared<State>();
            auto handle = std::unique_ptr<Monitor>(new Monitor(identity_, state));
            monitors_.push_back(state);
            refresh_reservations();
            output = std::move(handle);
            return Error::None;
        } catch (const std::bad_alloc &) { return Error::ResourceLimit; }
    }
    Error snapshot(const Monitor &monitor, Snapshot &output) const {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        const State *state = owned(monitor);
        if (!state) return Error::ForeignMonitor;
        output = *state;
        return Error::None;
    }
    Error clrex(Monitor &monitor) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        State *state = owned(monitor);
        if (!state) return Error::ForeignMonitor;
        state->active = false;
        return Error::None;
    }
    Error map(std::uint32_t address, std::uint64_t length, std::uint32_t permissions,
              MemoryKind kind = MemoryKind::Normal) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (kind != MemoryKind::Normal) return Error::UnsupportedMemory;
        if (!permissions_valid(permissions)) return Error::MappingRejected;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.map(address, length, std::uint8_t(permissions))) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error protect(std::uint32_t address, std::uint64_t length, std::uint32_t permissions) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (!permissions_valid(permissions)) return Error::MappingRejected;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.protect(address, length, std::uint8_t(permissions))) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error map_partial_data(std::uint32_t address, std::uint64_t length, std::uint32_t permissions,
                           MemoryKind kind = MemoryKind::Normal) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
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
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.initialize_data(address, source, length)) return Error::AccessFault;
        mutation(address, length);
        return Error::None;
    }
    Error unmap(std::uint32_t address, std::uint64_t length) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (!can_mutate()) return Error::EpochExhausted;
        if (!data_.unmap(address, length)) return Error::MappingRejected;
        mutation(address, length);
        return Error::None;
    }
    Error read(std::uint32_t address, void *destination, std::size_t length) const {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        return data_.read(address, destination, length) ? Error::None : Error::AccessFault;
    }
    bool nav_accessible(std::uint32_t at,std::uint64_t bytes,std::uint8_t permission) const {
        OperationLock lock(*this);
        return lock.valid() && data_.nav_accessible(at,bytes,permission);
    }
    Error write(std::uint32_t address, const void *source, std::size_t length) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (length && !can_mutate()) return Error::EpochExhausted;
        if (!data_.write(address, source, length)) return Error::AccessFault;
        if (length) mutation(address, length);
        return Error::None;
    }
    using WriteSpan = DataMemory::WriteSpan;
    // Native source modules stage all results, then atomically publish output
    // and count. Failed validation changes neither bytes nor reservations.
    Error write_batch(const WriteSpan *spans, std::size_t count) {
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
        if (count > DataMemory::MaximumWriteSpans) return Error::ResourceLimit;
        if (!spans && count) return Error::AccessFault;
        std::size_t mutations = 0;
        for (std::size_t i = 0; i < count; ++i) mutations += spans[i].length != 0;
        if (mutations > std::numeric_limits<std::uint64_t>::max() - epoch_)
            return Error::EpochExhausted;
        if (!data_.write_batch(spans, count)) return Error::AccessFault;
        for (std::size_t i = 0; i < count; ++i)
            if (spans[i].length) mutation(spans[i].address, spans[i].length);
        return Error::None;
    }
    LoadResult ldrex(Monitor &monitor, std::uint32_t address, std::uint32_t width) {
        OperationLock lock(*this);
        if (!lock.valid()) return {Error::LeaseConflict,0};
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
        refresh_reservations();
        return {Error::None, decode(bytes, width)};
    }
    StoreResult strex(Monitor &monitor, std::uint32_t address, std::uint32_t width, std::uint64_t value) {
        OperationLock lock(*this);
        if (!lock.valid()) return {Error::LeaseConflict,1};
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
        OperationLock lock(*this);
        if (!lock.valid()) return {Error::LeaseConflict,0};
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
        OperationLock lock(*this);
        if (!lock.valid()) return Error::LeaseConflict;
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
} // namespace as6hostdata
