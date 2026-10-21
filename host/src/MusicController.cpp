#include "MusicController.hpp"
#include <type_traits>

namespace as6::audio {
MusicController::MusicController(MusicBackend &backend, MusicState initial) noexcept
    : backend_(backend), state_(initial) {}

void MusicController::setPlaying(bool enabled) {
    if (state_.playing==enabled) return;
    if (enabled) {
        if (state_.randomMode) state_.track=backend_.chooseRandomSound(590);
        if (state_.track!=-1)
            state_.emitter=backend_.play2D(state_.track,!state_.randomMode,0,true);
    } else if (state_.track!=-1) {
        backend_.stop(state_.track,100,-1);
    }
    state_.playing=enabled;
}

void MusicController::setTrack(SoundId track) {
    state_.randomMode=false;
    if (!state_.playing) {
        state_.track=track;
        return;
    }
    setPlaying(false);
    state_.track=track;
    setPlaying(true);
}

void MusicController::setRandom() {
    state_.randomMode=true;
    if (!state_.playing) return;
    setPlaying(false);
    setPlaying(true);
}

void MusicController::updateRandom() {
    if (!state_.randomMode || !state_.playing || state_.track==-1) return;
    if (!backend_.isPlaying(state_.track,state_.emitter)) setRandom();
}

void MusicController::apply(const MusicCommand &command) {
    std::visit([this](const auto &value) {
        using T=std::decay_t<decltype(value)>;
        if constexpr (std::is_same_v<T,SetMusicPlaying>) setPlaying(value.enabled);
        else if constexpr (std::is_same_v<T,SetMusicTrack>) setTrack(value.track);
        else if constexpr (std::is_same_v<T,SetRandomMusic>) setRandom();
        else updateRandom();
    },command);
}
}
