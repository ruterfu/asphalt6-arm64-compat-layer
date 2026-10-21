#pragma once

#include "aot_support.hpp"

namespace as6aot {
using NativeFunction = Status (*)(Context &, bool, std::uint32_t, bool);
using NativeLookup = NativeFunction (*)(std::uint32_t, bool);

// Immutable descriptors generated with the native object files. Bounds are
// inclusive (original PC << 1 | Thumb), never ranges of executable memory.
struct NativeModule {
    std::uint64_t first_key;
    std::uint64_t last_key;
    NativeLookup lookup;
};

class NativeProgram {
    const NativeModule *modules_;
    std::size_t count_;
    std::size_t register_size_;
    std::size_t pc_offset_;
    bool valid_;

public:
    // Borrows a static, sorted descriptor array. No registration or executable
    // allocation takes place at runtime. All modules share one frozen layout.
    NativeProgram(const NativeModule *modules, std::size_t count,
                  std::size_t register_size, std::size_t pc_offset)
        : modules_(modules), count_(count), register_size_(register_size),
          pc_offset_(pc_offset), valid_(modules && count && register_size >= 4 &&
                                      pc_offset <= register_size - 4) {
        if (!valid_) return;
        for (std::size_t i = 0; i < count; ++i) {
            const auto &module = modules[i];
            if (!module.lookup || module.first_key > module.last_key ||
                module.last_key > 0x1ffffffffULL ||
                (i && modules[i - 1].last_key >= module.first_key)) {
                valid_ = false;
                break;
            }
        }
    }

    bool valid() const { return valid_; }
    std::size_t register_size() const { return register_size_; }

    NativeFunction lookup(std::uint32_t pc, bool thumb) const {
        if (!valid_) return nullptr;
        const std::uint64_t key = (std::uint64_t(pc) << 1) | std::uint64_t(thumb);
        std::size_t lo = 0, hi = count_;
        while (lo < hi) {
            const auto mid = lo + (hi - lo) / 2;
            if (modules_[mid].last_key < key) lo = mid + 1;
            else hi = mid;
        }
        if (lo == count_ || key < modules_[lo].first_key) return nullptr;
        return modules_[lo].lookup(pc, thumb);
    }

    Status execute(Context &ctx, std::uint32_t stop_pc, std::uint32_t stop_thumb) const {
        const bool data_ok = ctx.data_access
            ? ctx.data_access->state && ctx.data_access->read && ctx.data_access->write
            : ctx.memory && ctx.memory_size <= 0x100000000ULL - ctx.memory_base;
        if (!valid_ || !ctx.registers || ctx.register_size < register_size_ ||
            !data_ok || stop_thumb > 1 || (stop_pc & (stop_thumb ? 1u : 3u)))
            return ctx.status = InvalidState;
        if (ctx.status != Returned && ctx.status != BudgetExhausted) {
            switch (ctx.status) {
                case UnresolvedTarget: case MemoryFault: case InvalidState:
                case ArithmeticFault: case UnsupportedSemantics: case OriginalTrap: return ctx.status;
                default: return ctx.status = InvalidState;
            }
        }
        ctx.status = Returned;
        ctx.fault_address = 0;
        for (;;) {
            write_bytes(ctx.registers, pc_offset_, 4, Word(ctx.next_pc));
            if (ctx.next_pc == stop_pc && ctx.isa_thumb == bool(stop_thumb))
                return ctx.status = Returned;
            const auto target = lookup(ctx.next_pc, ctx.isa_thumb);
            if (!target) return ctx.status = UnresolvedTarget;
            const auto result = target(ctx, false, stop_pc, bool(stop_thumb));
            if (result != Dispatch) return ctx.status = result;
        }
    }
};
} // namespace as6aot
