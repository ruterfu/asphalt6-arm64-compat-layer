#pragma once
#include "NativeMusicAction.hpp"
#include <cstdint>
#include <future>
#include <string>
#include <vector>

namespace as6::audio {
struct NativeMusicOptions {
    bool offline=false;
    std::uint32_t maximumRenderFrames=4096;
    unsigned cachedClips=2;
};
struct NativeMusicDiagnostics {
    std::uint64_t generation=0,acceptedBatches=0,acceptedActions=0;
    std::uint64_t decodedClips=0,cacheHits=0,playedVoices=0,failedVoices=0;
    std::uint64_t renderedFrames=0;
    std::int32_t observedTrack=-1,observedEmitter=-1;
    std::uint64_t observedOutputEpoch=0,observedPositionFrames=0;
    unsigned pendingVoices=0,playingVoices=0,cachedClips=0;
    bool ready=false,paused=false,applicationActive=true;
    std::string lastError;
};

// Configure before entering game callbacks, preferably on the resource-loader
// queue. Archive indexing is synchronous; no platform audio objects are created
// here. All decoding/output controls run on the service's own worker.
bool configureNativeMusic(const std::string &archivePath,NativeMusicOptions options={}) noexcept;
void setNativeMusicApplicationActive(bool active) noexcept;
void shutdownNativeMusic() noexcept;
NativeMusicDiagnostics nativeMusicDiagnostics() noexcept;

// Test/diagnostic fences only. Production game control never waits on these.
std::future<void> drainNativeMusicCommands();
std::future<std::vector<float>> renderNativeMusicOffline(std::uint32_t frames);
}
