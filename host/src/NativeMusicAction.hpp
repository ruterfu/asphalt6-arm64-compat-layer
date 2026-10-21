#pragma once
#include <cstddef>
#include <cstdint>

namespace as6::audio {

enum class NativeMusicActionKind : std::uint8_t {
    Play, Stop, SetVoiceGain, StopAll, SetGroupGain, SetMasterGain, SetPaused
};

// Values cross the game/audio-owner boundary; no borrowed object or buffer.
struct NativeMusicAction {
    using Kind = NativeMusicActionKind;
    Kind kind = Kind::Stop;
    std::int32_t track = -1, emitter = -1, third = 0;
    bool loop = false, fourth = true;
    std::uint32_t fadeMilliseconds = 0;
    float gain = 1.0f;
    bool paused = false;
    std::uint64_t generation = 0;
};

bool nativeMusicReady() noexcept;
std::uint64_t nativeMusicGeneration() noexcept;
// Positive high-domain identity reserved before publication; -1 means failure.
std::int32_t nativeMusicReserveEmitter() noexcept;
// FIFO transaction: accept all values or none. No half-published command group.
bool nativeMusicPostBatch(const NativeMusicAction *actions, std::size_t count) noexcept;
// Includes accepted pending Play intents; emitter -1 queries any voice of track.
bool nativeMusicIsPlaying(std::int32_t track, std::int32_t emitter) noexcept;

} // namespace as6::audio
