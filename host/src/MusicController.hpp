#pragma once
#include <cstdint>
#include <variant>

namespace as6::audio {

using SoundId = std::int32_t;
using EmitterId = std::int32_t;

struct MusicState {
    SoundId track;
    EmitterId emitter;
    bool playing;
    bool randomMode;
    bool operator==(const MusicState &other) const noexcept {
        return track==other.track && emitter==other.emitter &&
            playing==other.playing && randomMode==other.randomMode;
    }
};

// Native audio implementation boundary. Numeric parameters retain the observed
// original contract; names with an unproven meaning are deliberately neutral.
class MusicBackend {
public:
    virtual ~MusicBackend() = default;
    virtual SoundId chooseRandomSound(SoundId group) = 0;
    virtual EmitterId play2D(SoundId track, bool loop,
                             std::int32_t thirdParameter, bool fourthParameter) = 0;
    virtual void stop(SoundId track, std::int32_t secondParameter,
                      EmitterId emitter) = 0;
    virtual bool isPlaying(SoundId track, EmitterId emitter) = 0;
};

struct SetMusicPlaying { bool enabled; };
struct SetMusicTrack { SoundId track; };
struct SetRandomMusic {};
struct UpdateRandomMusic {};
using MusicCommand = std::variant<SetMusicPlaying, SetMusicTrack,
                                  SetRandomMusic, UpdateRandomMusic>;

// One audio owner calls this ordinary C++ state machine. No image addresses,
// guest registers, virtual CPU or renderer lock participate in its execution.
// The initial state is explicit until constructor/default-state recovery closes.
class MusicController {
public:
    MusicController(MusicBackend &backend, MusicState initial) noexcept;
    void apply(const MusicCommand &command);
    MusicState state() const noexcept { return state_; }
    void setPlaying(bool enabled);
    void setTrack(SoundId track);
    void setRandom();
    void updateRandom();
private:
    MusicBackend &backend_;
    MusicState state_;
};
}
