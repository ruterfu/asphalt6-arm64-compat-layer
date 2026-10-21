#pragma once

#include "aot_support.hpp"
#include "HostArmAtomicMemory.hpp"

namespace as6hostdata {
// The generated program's callback ABI remains the original runtime types.
using as6aot::DataAccess;
using as6aot::Status;
using as6aot::Returned;
using as6aot::MemoryFault;
using as6aot::InvalidState;
using as6aot::UnsupportedSemantics;

// A CPU's local monitor and ordinary accesses share one privately owned data
// store and mutex. System bridges must use this same store for writes too.
class AtomicAccess {
    ArmAtomicMemory &memory_;
    std::unique_ptr<ArmAtomicMemory::Monitor> monitor_;
    DataAccess access_;

    static Status status(ArmAtomicMemory::Error error) {
        using E = ArmAtomicMemory::Error;
        switch (error) {
            case E::None: return Returned;
            case E::Alignment: case E::AccessFault: return MemoryFault;
            case E::ForeignMonitor: case E::LeaseConflict: return InvalidState;
            default: return UnsupportedSemantics;
        }
    }

public:
    explicit AtomicAccess(ArmAtomicMemory &memory) : memory_(memory), access_{} {
        if (memory_.make_monitor(monitor_) != ArmAtomicMemory::Error::None) return;
        access_ = {this,
            [](void *raw, std::uint32_t address, void *out, std::size_t length) {
                return static_cast<AtomicAccess *>(raw)->memory_.read(address,out,length) == ArmAtomicMemory::Error::None;
            },
            [](void *raw, std::uint32_t address, const void *in, std::size_t length) {
                return static_cast<AtomicAccess *>(raw)->memory_.write(address,in,length) == ArmAtomicMemory::Error::None;
            },
            [](void *raw, std::uint32_t address, unsigned width, std::uint64_t *value) {
                auto &self = *static_cast<AtomicAccess *>(raw);
                const auto result = self.memory_.ldrex(*self.monitor_,address,width);
                if (result.error == ArmAtomicMemory::Error::None) *value = result.value;
                return status(result.error);
            },
            [](void *raw, std::uint32_t address, unsigned width, std::uint64_t value, std::uint32_t *output) {
                auto &self = *static_cast<AtomicAccess *>(raw);
                const auto result = self.memory_.strex(*self.monitor_,address,width,value);
                if (result.error == ArmAtomicMemory::Error::None) *output = result.status;
                return status(result.error);
            },
            [](void *raw) {
                auto &self = *static_cast<AtomicAccess *>(raw);
                return status(self.memory_.clrex(*self.monitor_));
            },
            [](void *raw, unsigned option) {
                return status(static_cast<AtomicAccess *>(raw)->memory_.dmb(option));
            },
            [](void *raw, std::uint32_t address, unsigned width, std::uint64_t value, std::uint64_t *output) {
                auto &self = *static_cast<AtomicAccess *>(raw);
                const auto result = self.memory_.swap(address,width,value);
                if (result.error == ArmAtomicMemory::Error::None) *output = result.value;
                return status(result.error);
            }};
    }
    AtomicAccess(const AtomicAccess &) = delete;
    AtomicAccess &operator=(const AtomicAccess &) = delete;
    bool valid() const { return bool(monitor_); }
    using ExecutionLease = ArmAtomicMemory::ExecutionLease;
    ExecutionLease execution_lease() const { return memory_.execution_lease(); }
    const as6aot::DirectMemory *direct_memory() const { return memory_.direct_memory(); }
    const DataAccess &access() const { return access_; }
    // Isolated NavLine prototype: read-only view of this real CPU monitor.
    bool nav_monitor_snapshot(ArmAtomicMemory::Snapshot &out) const {
        return monitor_ && memory_.snapshot(*monitor_,out)==ArmAtomicMemory::Error::None;
    }
    Status clear() {
        return monitor_ ? status(memory_.clrex(*monitor_)) : InvalidState;
    }
};
} // namespace as6hostdata
