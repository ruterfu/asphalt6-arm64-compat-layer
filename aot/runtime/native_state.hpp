#pragma once

#include "aot_support.hpp"
#include "register_layout.hpp"
#include <array>
#include <atomic>

namespace as6aot {
class NativeState {
public:
    struct Snapshot {
        std::array<std::uint8_t, layout::Size> registers{};
        std::uint64_t owner = 0;
        std::uint64_t budget = 0;
        std::uint32_t pc = 0;
        std::uint32_t fault_address = 0;
        Status status = Returned;
        bool thumb = false;
    };

private:
    inline static std::atomic<std::uint64_t> next_owner_{1};
    std::array<std::uint8_t, layout::Size> registers_{};
    const std::uint64_t owner_ = next_owner_.fetch_add(1, std::memory_order_relaxed);
    Context context_{};

public:
    explicit NativeState(const DataAccess &access) {
        context_.registers = registers_.data();
        context_.register_size = registers_.size();
        context_.data_access = &access;
        // Original iOS application routines execute in little-endian User mode.
        set_cpsr(0x10);
    }
    NativeState(const NativeState &) = delete;
    NativeState &operator=(const NativeState &) = delete;

    Context &context() { return context_; }
    const Context &context() const { return context_; }

    bool get_register(unsigned index, std::uint32_t &result) const {
        if (index >= 16) return false;
        result = std::uint32_t(read_bytes(registers_.data(), layout::r0 + 4 * index, 4));
        return true;
    }
    bool set_register(unsigned index, std::uint32_t value) {
        if (index >= 16) return false;
        write_bytes(registers_.data(), layout::r0 + 4 * index, 4, value);
        if (index == 15) context_.next_pc = value;
        return true;
    }
    bool get_s(unsigned index, std::uint32_t &bits) const {
        if (index >= 32) return false;
        bits = std::uint32_t(read_bytes(registers_.data(), layout::s0 + 4 * index, 4));
        return true;
    }
    bool set_s(unsigned index, std::uint32_t bits) {
        if (index >= 32) return false;
        write_bytes(registers_.data(), layout::s0 + 4 * index, 4, bits);
        return true;
    }
    bool get_d(unsigned index, std::uint64_t &bits) const {
        if (index >= 32) return false;
        bits = std::uint64_t(read_bytes(registers_.data(), layout::d0 + 8 * index, 8));
        return true;
    }
    bool set_d(unsigned index, std::uint64_t bits) {
        if (index >= 32) return false;
        write_bytes(registers_.data(), layout::d0 + 8 * index, 8, bits);
        return true;
    }
    std::uint32_t fpscr() const {
        return std::uint32_t(read_bytes(registers_.data(), layout::fpscr, 4));
    }
    void set_fpscr(std::uint32_t value) {
        write_bytes(registers_.data(), layout::fpscr, 4, value);
    }

    std::uint32_t cpsr() const {
        auto value = std::uint32_t(read_bytes(registers_.data(), layout::cpsr, 4));
        value &= ~(0xf8000000u | 0x000f0000u | 0x20u);
        const std::size_t offsets[] = {layout::NG, layout::ZR, layout::CY, layout::OV, layout::Q};
        for (unsigned i = 0; i < 5; ++i) value |= std::uint32_t(bool(registers_[offsets[i]])) << (31 - i);
        for (unsigned i = 0; i < 4; ++i) value |= std::uint32_t(bool(registers_[layout::GE1 + i])) << (16 + i);
        return value | (std::uint32_t(context_.isa_thumb) << 5);
    }

    bool set_cpsr(std::uint32_t value) {
        // Switching privileged banks, endianness or Jazelle needs separate
        // semantics. Refuse it before committing any register state.
        if ((value & 0x1fu) != 0x10u || (value & ((1u << 24) | (1u << 9)))) return false;
        write_bytes(registers_.data(), layout::cpsr, 4, value);
        const std::size_t offsets[] = {layout::NG, layout::ZR, layout::CY, layout::OV, layout::Q};
        for (unsigned i = 0; i < 5; ++i) registers_[offsets[i]] = (value >> (31 - i)) & 1u;
        for (unsigned i = 0; i < 4; ++i) registers_[layout::GE1 + i] = (value >> (16 + i)) & 1u;
        context_.isa_thumb = (value >> 5) & 1u;
        registers_[layout::TB] = context_.isa_thumb;
        return true;
    }

    Snapshot save() const {
        Snapshot snapshot;
        snapshot.registers = registers_;
        snapshot.owner = owner_;
        snapshot.budget = context_.budget;
        snapshot.pc = context_.next_pc;
        snapshot.fault_address = context_.fault_address;
        snapshot.status = context_.status;
        snapshot.thumb = context_.isa_thumb;
        return snapshot;
    }

    bool restore(const Snapshot &snapshot) {
        if (!owner_ || snapshot.owner != owner_ ||
            std::uint32_t(read_bytes(snapshot.registers.data(), layout::pc, 4)) != snapshot.pc ||
            (snapshot.pc & (snapshot.thumb ? 1u : 3u)) ||
            snapshot.status > OriginalTrap || snapshot.status == Dispatch) return false;
        // A host scheduler/context restore never resurrects an exclusive
        // reservation. Shared memory and monitors are outside CPU snapshots.
        if (context_.data_access && context_.data_access->clear_exclusive &&
            context_.data_access->clear_exclusive(context_.data_access->state) != Returned) return false;
        registers_ = snapshot.registers;
        context_.budget = snapshot.budget;
        context_.next_pc = snapshot.pc;
        context_.fault_address = snapshot.fault_address;
        context_.status = snapshot.status;
        context_.isa_thumb = snapshot.thumb;
        return true;
    }
};
} // namespace as6aot
