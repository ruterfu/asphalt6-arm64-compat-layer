#pragma once
#include "PcmClip.hpp"
#include "StoredAudioArchive.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace as6::audio {
struct WaveImaInfo {
    std::uint32_t sampleRate=0;
    unsigned channels=0;
    std::uint32_t blockBytes=0, framesPerBlock=0;
    std::uint64_t dataOffset=0, dataBytes=0, physicalFrames=0, validFrames=0;
    bool originalRiffLength=false;
};

// Observed WAVE IMA format: fmt20/fact/data, one or two channels and complete
// blocks. The original assets put decoded byte length in RIFF.size; accept that
// explicit form as well as a standard physical RIFF size. fact is authoritative
// for valid frames, matching the original reader's final-block clipping.
WaveImaInfo inspectWaveIma(const std::uint8_t *bytes,std::size_t size);
SharedPcmClip loadWaveImaClip(const StoredAudioArchive &archive,std::string_view name,
                            WaveImaInfo *info=nullptr);
}
