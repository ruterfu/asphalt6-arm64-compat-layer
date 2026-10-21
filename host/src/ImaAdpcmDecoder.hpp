#pragma once

#include <cstddef>
#include <cstdint>

namespace as6::audio {

// Stateless IMA block algorithm recovered from the original WAVE decoder.
// This module does not identify containers, perform format dispatch, trim
// fact/segment lengths, or resample.
class ImaAdpcmDecoder final {
public:
    // Supports one/two channels, a four-byte header per channel, then complete
    // groups of four encoded bytes per channel. The header predictor is frame0.
    // Partial channel groups are rejected; their original handling is unknown.
    static std::size_t framesPerBlock(std::size_t blockBytes, unsigned channels);

    // Writes native signed16 PCM, interleaved by frame, and returns frame count.
    // sampleCapacity counts int16 samples, not frames or bytes. The header's
    // reserved byte is ignored as in the original routine; index must be0..88.
    // Input/output must be separate non-overlapping valid buffers. Invalid
    // shape/header/pointers or insufficient capacity throw before any output.
    // No allocation, file access, shared mutable state, or prior block state.
    static std::size_t decodeBlock(const std::uint8_t *block,
                                   std::size_t blockBytes, unsigned channels,
                                   std::int16_t *interleaved,
                                   std::size_t sampleCapacity);
};

} // namespace as6::audio
