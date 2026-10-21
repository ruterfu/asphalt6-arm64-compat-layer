#pragma once

// Build-time translated code uses these bounded data accesses. There is no
// instruction decoder, execution engine, executable allocation, or JIT here.
#include <cstddef>
#include <cstdint>

namespace as6aot {
using Word = unsigned __int128;

enum Status : std::uint32_t {
    Returned = 0,
    UnresolvedTarget = 1,
    MemoryFault = 2,
    BudgetExhausted = 3,
    InvalidState = 4,
    ArithmeticFault = 5,
    Dispatch = 6, // Internal transfer between fixed, build-time native targets.
    UnsupportedSemantics = 7,
    OriginalTrap = 8, // Original undefined-instruction exception, no host signal.
};

// Data services only: these callbacks cannot fetch/execute an instruction.
// A backend must validate the complete interval before touching either side,
// and the caller holds its execution/bridge lock for the whole native call.
struct DataAccess {
    void *state;
    bool (*read)(void *, std::uint32_t, void *, std::size_t);
    bool (*write)(void *, std::uint32_t, const void *, std::size_t);
    Status (*load_exclusive)(void *, std::uint32_t, unsigned, std::uint64_t *) = nullptr;
    Status (*store_exclusive)(void *, std::uint32_t, unsigned, std::uint64_t, std::uint32_t *) = nullptr;
    Status (*clear_exclusive)(void *) = nullptr;
    Status (*barrier)(void *, unsigned) = nullptr;
    Status (*swap)(void *, std::uint32_t, unsigned, std::uint64_t, std::uint64_t *) = nullptr;
};

struct Context {
    std::uint8_t *registers;
    std::size_t register_size;
    std::uint8_t *memory;
    std::uint32_t memory_base;
    std::uint64_t memory_size;
    std::uint64_t budget;
    std::uint32_t next_pc;
    std::uint32_t fault_address;
    Status status;
    bool isa_thumb;
    const DataAccess *data_access = nullptr;
};

// Condition is fixed by the original instruction at build time. Encoding 15
// is admitted only for explicitly validated unconditional NEON forms.
inline bool arm_condition_passed(unsigned condition, bool n, bool z, bool c, bool v) {
    switch (condition) {
        case 0: return z;
        case 1: return !z;
        case 2: return c;
        case 3: return !c;
        case 4: return n;
        case 5: return !n;
        case 6: return v;
        case 7: return !v;
        case 8: return c && !z;
        case 9: return !c || z;
        case 10: return n == v;
        case 11: return n != v;
        case 12: return !z && n == v;
        case 13: return z || n != v;
        case 14: return true;
        case 15: return true;
        default: return false;
    }
}

inline Word mask(unsigned bytes) {
    return bytes == 16 ? ~Word(0) : ((Word(1) << (bytes * 8)) - 1);
}

inline Word narrow(Word value, unsigned bytes) { return value & mask(bytes); }

inline bool range(std::uint64_t offset, unsigned bytes, std::uint64_t size) {
    return offset <= size && bytes <= size - offset;
}

inline Word read_bytes(const std::uint8_t *data, std::uint64_t offset, unsigned bytes) {
    Word value = 0;
    for (unsigned i = 0; i < bytes; ++i) value |= Word(data[offset + i]) << (8 * i);
    return value;
}

inline void write_bytes(std::uint8_t *data, std::uint64_t offset, unsigned bytes, Word value) {
    for (unsigned i = 0; i < bytes; ++i) data[offset + i] = std::uint8_t(value >> (8 * i));
}

inline Word load(Context &ctx, Word raw_address, unsigned bytes) {
    if (bytes == 0 || bytes > sizeof(Word) || raw_address > UINT32_MAX ||
        bytes > Word(0x100000000ULL) - raw_address) {
        ctx.status = MemoryFault;
        ctx.fault_address = std::uint32_t(raw_address);
        return 0;
    }
    if (ctx.data_access) {
        std::uint8_t buffer[sizeof(Word)]{};
        if (!ctx.data_access->read || !ctx.data_access->state ||
            !ctx.data_access->read(ctx.data_access->state, std::uint32_t(raw_address), buffer, bytes)) {
            ctx.status = MemoryFault;
            ctx.fault_address = std::uint32_t(raw_address);
            return 0;
        }
        return read_bytes(buffer, 0, bytes);
    }
    if (!ctx.memory ||
        raw_address < ctx.memory_base ||
        !range(std::uint64_t(raw_address) - ctx.memory_base, bytes, ctx.memory_size)) {
        ctx.status = MemoryFault;
        ctx.fault_address = std::uint32_t(raw_address);
        return 0;
    }
    return read_bytes(ctx.memory, std::uint64_t(raw_address) - ctx.memory_base, bytes);
}

inline void store(Context &ctx, Word raw_address, unsigned bytes, Word value) {
    if (bytes == 0 || bytes > sizeof(Word) || raw_address > UINT32_MAX ||
        bytes > Word(0x100000000ULL) - raw_address) {
        ctx.status = MemoryFault;
        ctx.fault_address = std::uint32_t(raw_address);
        return;
    }
    if (ctx.data_access) {
        std::uint8_t buffer[sizeof(Word)];
        write_bytes(buffer, 0, bytes, value);
        if (!ctx.data_access->write || !ctx.data_access->state ||
            !ctx.data_access->write(ctx.data_access->state, std::uint32_t(raw_address), buffer, bytes)) {
            ctx.status = MemoryFault;
            ctx.fault_address = std::uint32_t(raw_address);
        }
        return;
    }
    if (!ctx.memory ||
        raw_address < ctx.memory_base ||
        !range(std::uint64_t(raw_address) - ctx.memory_base, bytes, ctx.memory_size)) {
        ctx.status = MemoryFault;
        ctx.fault_address = std::uint32_t(raw_address);
        return;
    }
    write_bytes(ctx.memory, std::uint64_t(raw_address) - ctx.memory_base, bytes, value);
}

inline Word load_exclusive(Context &ctx, std::uint32_t address, unsigned bytes) {
    if (!ctx.data_access || !ctx.data_access->state || !ctx.data_access->load_exclusive) {
        ctx.status = UnsupportedSemantics;
        return 0;
    }
    std::uint64_t value = 0;
    const auto result = ctx.data_access->load_exclusive(ctx.data_access->state, address, bytes, &value);
    if (result != Returned) {
        ctx.status = result;
        if (result == MemoryFault) ctx.fault_address = address;
        return 0;
    }
    return value;
}

inline std::uint32_t store_exclusive(Context &ctx, std::uint32_t address, unsigned bytes, std::uint64_t value) {
    if (!ctx.data_access || !ctx.data_access->state || !ctx.data_access->store_exclusive) {
        ctx.status = UnsupportedSemantics;
        return 1;
    }
    std::uint32_t status = 1;
    const auto result = ctx.data_access->store_exclusive(ctx.data_access->state, address, bytes, value, &status);
    if (result != Returned || status > 1) {
        ctx.status = result == Returned ? InvalidState : result;
        if (result == MemoryFault) ctx.fault_address = address;
        return 1;
    }
    return status;
}

inline void clear_exclusive(Context &ctx) {
    if (!ctx.data_access || !ctx.data_access->state || !ctx.data_access->clear_exclusive)
        ctx.status = UnsupportedSemantics;
    else ctx.status = ctx.data_access->clear_exclusive(ctx.data_access->state);
}

inline void memory_barrier(Context &ctx, unsigned option) {
    if (!ctx.data_access || !ctx.data_access->state || !ctx.data_access->barrier)
        ctx.status = UnsupportedSemantics;
    else ctx.status = ctx.data_access->barrier(ctx.data_access->state, option);
}

inline Word atomic_swap(Context &ctx, std::uint32_t address, unsigned bytes, std::uint64_t value) {
    if (!ctx.data_access || !ctx.data_access->state || !ctx.data_access->swap) {
        ctx.status = UnsupportedSemantics;
        return 0;
    }
    std::uint64_t old_value = 0;
    const auto result = ctx.data_access->swap(ctx.data_access->state, address, bytes, value, &old_value);
    if (result != Returned) {
        ctx.status = result;
        if (result == MemoryFault) ctx.fault_address = address;
        return 0;
    }
    return old_value;
}

inline Word sign_extend(Word value, unsigned source_bytes, unsigned result_bytes) {
    const Word source_mask = mask(source_bytes);
    value &= source_mask;
    if (value & (Word(1) << (source_bytes * 8 - 1))) value |= ~source_mask;
    return narrow(value, result_bytes);
}

inline bool signed_less(Word left, Word right, unsigned bytes) {
    left = narrow(left, bytes);
    right = narrow(right, bytes);
    const Word sign = Word(1) << (bytes * 8 - 1);
    return ((left ^ right) & sign) ? (left & sign) != 0 : left < right;
}

inline Word shift_left(Word value, Word shift, unsigned bytes) {
    return shift >= bytes * 8 ? 0 : narrow(value << unsigned(shift), bytes);
}

inline Word shift_right(Word value, Word shift, unsigned bytes) {
    return shift >= bytes * 8 ? 0 : narrow(value, bytes) >> unsigned(shift);
}

inline Word shift_signed_right(Word value, Word shift, unsigned bytes) {
    value = narrow(value, bytes);
    const bool negative = (value & (Word(1) << (bytes * 8 - 1))) != 0;
    if (shift >= bytes * 8) return negative ? mask(bytes) : 0;
    if (shift == 0) return value;
    Word result = value >> unsigned(shift);
    if (negative) result |= mask(bytes) ^ (mask(bytes) >> unsigned(shift));
    return result;
}

inline bool carry(Word left, Word right, unsigned bytes) {
    const Word limit = mask(bytes);
    left &= limit;
    right &= limit;
    return right > limit - left;
}

inline bool signed_carry(Word left, Word right, unsigned bytes) {
    const Word sign = Word(1) << (bytes * 8 - 1);
    const Word result = narrow(left + right, bytes);
    return ((~(left ^ right) & (left ^ result)) & sign) != 0;
}

inline bool signed_borrow(Word left, Word right, unsigned bytes) {
    const Word sign = Word(1) << (bytes * 8 - 1);
    const Word result = narrow(left - right, bytes);
    return (((left ^ right) & (left ^ result)) & sign) != 0;
}

inline Word signed_divide(Context &ctx, Word left, Word right, unsigned bytes, bool remainder) {
    left = narrow(left, bytes);
    right = narrow(right, bytes);
    if (right == 0) { ctx.status = ArithmeticFault; return 0; }
    const Word sign = Word(1) << (bytes * 8 - 1);
    const bool left_negative = (left & sign) != 0;
    const bool right_negative = (right & sign) != 0;
    const Word magnitude_left = left_negative ? narrow(-left, bytes) : left;
    const Word magnitude_right = right_negative ? narrow(-right, bytes) : right;
    Word result = remainder ? magnitude_left % magnitude_right : magnitude_left / magnitude_right;
    if (remainder ? left_negative : left_negative != right_negative) result = -result;
    return narrow(result, bytes);
}

inline Word population_count(Word value, unsigned bytes) {
    value = narrow(value, bytes);
    unsigned result = 0;
    while (value) { result += unsigned(value & 1); value >>= 1; }
    return result;
}

inline Word leading_zero_count(Word value, unsigned bytes) {
    value = narrow(value, bytes);
    unsigned result = 0;
    const Word top = Word(1) << (bytes * 8 - 1);
    while (result < bytes * 8 && (value & top) == 0) { ++result; value <<= 1; }
    return result;
}
} // namespace as6aot

// Context layout is unchanged. Budget exhaustion is resumable at next_pc;
// add budget and call again with the same explicit stop (PC, ISA mode) tuple.
extern "C" std::uint32_t as6_aot_context_size();
extern "C" std::uint32_t as6_aot_execute(as6aot::Context *ctx, std::uint32_t stop_pc,
                                         std::uint32_t stop_thumb);
extern "C" std::uint32_t as6_aot_run_context(as6aot::Context *ctx, std::uint32_t stop_pc,
                                             std::uint32_t stop_thumb);
