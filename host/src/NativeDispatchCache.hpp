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
    // Return points count as targets too, so a race touches several thousand
    // distinct keys; two ways per set keep hot pairs from evicting each other.
    static constexpr std::size_t SetCount = 8192;
    Entry entries_[SetCount][2]{};
public:
    template<class Resolver>
    as6aot::NativeFunction lookup(std::uint32_t pc, bool thumb, Resolver resolve) {
        const auto key = (std::uint64_t(pc) << 1) | std::uint64_t(thumb);
        const auto tag = key + 1; // zero is empty, including the valid key zero.
        auto *set = entries_[((key >> 2) * 0x9e3779b97f4a7c15ULL >> 51) & (SetCount - 1)];
        if (set[0].tag == tag) return set[0].function;
        if (set[1].tag == tag) {
            const Entry hit = set[1];
            set[1] = set[0];
            set[0] = hit;
            return hit.function;
        }
        const auto function = resolve(pc, thumb);
        set[1] = set[0];
        set[0] = {tag, function};
        return function;
    }
};
static_assert(sizeof(LookupCache) == 256 * 1024, "bounded per-thread dispatch cache");
} // namespace detail
} // namespace as6_native_dispatch
