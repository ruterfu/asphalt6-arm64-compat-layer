#pragma once
#include "MusicController.hpp"
#include <array>
#include <cstdint>

namespace as6::audio {

// The generator state is supplied by the owner; the original game shares it
// with other random operations. recent[0] is newest, and only recentCount
// entries participate. Unused entries have no selection meaning.
struct MusicRandomState {
    std::uint32_t seed;
    std::array<SoundId,3> recent{};
    std::uint32_t recentCount=0;
};

// Recovered music group590 selects IDs590..601, excluding up to three recent
// selections. Unsupported groups return -1 without changing state. An invalid
// recentCount throws before any state change. No allocation or shared state.
SoundId chooseOriginalRandomMusic(SoundId group, MusicRandomState &state);

} // namespace as6::audio
