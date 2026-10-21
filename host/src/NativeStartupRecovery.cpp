#include "NativeStartupRecovery.hpp"
#include "register_layout.hpp"

extern "C" const as6aot::NativeProgram *AS6NativeProgram();
extern "C" as6aot::NativeFunction as6_aot_lookup_startup_recovery_10000(std::uint32_t, bool);

namespace {
constexpr std::uint32_t First = 0x10000u;
constexpr std::uint32_t End = 0x10194u;
constexpr std::size_t RecoveredRecords = 101;
static_assert((End - First) / 4 == RecoveredRecords);

as6aot::NativeFunction Lookup(std::uint32_t pc, bool thumb) {
    const auto *base = AS6NativeProgram();
    if (const auto original = base->lookup(pc, thumb)) return original;
    return as6_aot_lookup_startup_recovery_10000(pc, thumb);
}

bool Validate() {
    const auto *base = AS6NativeProgram();
    if (!base || !base->valid() || base->register_size() != as6aot::layout::Size) return false;
    for (std::uint32_t pc = First; pc < End; pc += 4) {
        if (base->lookup(pc, false) || base->lookup(pc, true) ||
            !as6_aot_lookup_startup_recovery_10000(pc, false) ||
            as6_aot_lookup_startup_recovery_10000(pc, true)) return false;
    }
    // The supplement cannot accept a preceding/following or misaligned PC.
    for (std::uint32_t pc = First - 4; pc <= End + 4; ++pc) {
        const bool expected = pc >= First && pc < End && !(pc & 3u);
        if (bool(as6_aot_lookup_startup_recovery_10000(pc, false)) != expected ||
            as6_aot_lookup_startup_recovery_10000(pc, true)) return false;
    }
    return true;
}

// One static dispatch descriptor composes two already compiled lookup tables.
// Missing targets remain missing; there is no decoding or executable mapping.
const as6aot::NativeModule Modules[] = {{0, 0x1ffffffffULL, Lookup}};
const as6aot::NativeProgram Program(Modules, 1, as6aot::layout::Size, as6aot::layout::pc);
}

extern "C" const as6aot::NativeProgram *AS6NativeProgramWithStartupRecovery() {
    static const bool valid = Validate();
    return valid && Program.valid() ? &Program : nullptr;
}
