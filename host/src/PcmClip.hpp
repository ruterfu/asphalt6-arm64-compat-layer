#pragma once
#include <cstdint>
#include <memory>
#include <vector>

namespace as6::audio {

// Decoded resource data shared immutably between a clip cache and its output.
// Sample storage is signed 16-bit PCM, interleaved by frame.
struct PcmClip {
    std::uint32_t sampleRate;
    unsigned channels;
    std::uint64_t frames;
    std::vector<std::int16_t> interleaved;
};
using SharedPcmClip = std::shared_ptr<const PcmClip>;

} // namespace as6::audio
