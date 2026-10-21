#pragma once

#include "aot_support.hpp"
#include "data_memory.hpp"

namespace as6aot {
// The adapter borrows storage; it must not outlive DataMemory. Callers hold the
// same execution/bridge lock across accesses and mapping changes.
inline DataAccess data_access(DataMemory &memory) {
    return {&memory,
        [](void *state, std::uint32_t address, void *out, std::size_t length) {
            return static_cast<DataMemory *>(state)->read(address, out, length);
        },
        [](void *state, std::uint32_t address, const void *in, std::size_t length) {
            return static_cast<DataMemory *>(state)->write(address, in, length);
        }};
}
} // namespace as6aot
