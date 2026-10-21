#pragma once
#include "GuestNativeProvider.hpp"

namespace as6_native_dispatch {
namespace detail {
// One instance belongs to one thread and one immutable resolver. The complete
// 33-bit identity is retained; null results and table holes remain exact.
class LookupCache {
    struct Entry {
        std::uint64_t tag = 0;
        as6aot::NativeFunction function = nullptr;
    };
    static constexpr std::size_t SlotCount = 4096;
    Entry entries_[SlotCount]{};
public:
    template<class Resolver>
    as6aot::NativeFunction lookup(std::uint32_t pc, bool thumb, Resolver resolve) {
        const auto key = (std::uint64_t(pc) << 1) | std::uint64_t(thumb);
        const auto tag = key + 1; // zero is empty, including the valid key zero.
        auto &entry = entries_[(key ^ (key >> 3) ^ (key >> 15)) & (SlotCount - 1)];
        if (entry.tag == tag) return entry.function;
        const auto function = resolve(pc, thumb);
        entry.function = function;
        entry.tag = tag;
        return function;
    }
};
static_assert(sizeof(LookupCache) == 64 * 1024, "bounded per-thread dispatch cache");
} // namespace detail
} // namespace as6_native_dispatch
