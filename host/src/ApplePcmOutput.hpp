#pragma once
#include "PcmClip.hpp"
#include <cstdint>
#include <memory>
#include <vector>

namespace as6::audio {

enum class PcmOutputPhase { Stopped, Playing, Paused, FadingOut, Finished };
struct PcmOutputState {
    PcmOutputPhase phase = PcmOutputPhase::Stopped;
    std::uint64_t epoch = 0;
    std::uint64_t frames = 0;
    std::uint64_t positionFrames = 0;
    std::uint32_t sampleRate = 0;
    unsigned channels = 0;
    unsigned retiringVoices = 0;
    float volume = 1;
    float voiceVolume = 1;
    bool looping = false;
    bool hasActiveVoice = false;
    bool knownVoice = false;
};

// A native control-plane output. After first use, all calls and destruction
// belong to one audio worker. No AudioSession policy or UI work is performed.
// Construction is lazy: AVAudioEngine is created by the first play call.
class ApplePcmOutput final {
public:
    struct Options {
        bool offline = false;
        std::uint32_t maximumRenderFrames = 4096;
        unsigned voiceCapacity = 16;
    };
    ApplePcmOutput();
    explicit ApplePcmOutput(Options options);
    ~ApplePcmOutput();
    ApplePcmOutput(const ApplePcmOutput &) = delete;
    ApplePcmOutput &operator=(const ApplePcmOutput &) = delete;

    void play(SharedPcmClip clip, bool loop);
    // Independent voices share a prepared graph without interrupting each other.
    // Concurrent clips use one sample rate/channel format. Capacity is explicit.
    // Initial gain is installed before scheduling/start; there is no default-
    // gain playback window before the service applies group/master gain.
    std::uint64_t playVoice(SharedPcmClip clip, bool loop, std::uint32_t fadeInMs = 0,
                            float initialGain = 1);
    bool stopVoice(std::uint64_t epoch, std::uint32_t fadeMs = 0);
    bool setVoiceVolume(std::uint64_t epoch, float volume);
    PcmOutputState voiceState(std::uint64_t epoch) const;
    // Fade retires the current voice. A subsequent play begins immediately
    // while the short old tail finishes independently. Zero stops all voices.
    // A paused voice is already silent and stops immediately.
    void stop(std::uint32_t fadeMs = 0);
    void setVolume(float volume);
    void pause();
    void resume();
    PcmOutputState state() const;
    // Reports whether any logical voice is playing, excluding retiring tails.
    bool isPlaying() const;

    // Test/offline mode only: actual AVAudioEngine manual rendering to memory.
    // Returns interleaved float PCM in the engine's first clip format.
    std::vector<float> renderOffline(std::uint32_t frames);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace as6::audio
