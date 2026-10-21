#pragma once
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

// Exactly one producer and one serialized RemoteIO consumer. Never reset the
// indices from the control thread: epochs retire queued data without races.
namespace as6audio {
struct Stereo16 { std::int16_t left,right; };
static_assert(sizeof(Stereo16)==4);
class PcmRing {
public:
    static constexpr std::size_t BlockFrames=512,Capacity=8;
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
private:
    struct Block {std::uint64_t epoch=0;std::array<Stereo16,BlockFrames> frames{};};
    std::array<Block,Capacity> blocks_{};
    alignas(64) std::atomic<std::uint64_t> written_{0};
    alignas(64) std::atomic<std::uint64_t> read_{0};
    std::size_t offset_=0; // Consumer only, including across Stop/Start epochs.
public:
    std::uint64_t queuedBlocks()const noexcept {
        const auto r=read_.load(std::memory_order_acquire);
        const auto w=written_.load(std::memory_order_acquire);
        return w-r;
    }
    bool push(const Stereo16 *pcm,std::uint64_t epoch) noexcept {
        const auto w=written_.load(std::memory_order_relaxed);
        if(w-read_.load(std::memory_order_acquire)>=Capacity)return false;
        auto &block=blocks_[w%Capacity];block.epoch=epoch;
        std::memcpy(block.frames.data(),pcm,BlockFrames*sizeof(Stereo16));
        written_.store(w+1,std::memory_order_release);return true;
    }
    // Bounded by the queue snapshot (at most eight blocks), never spins or
    // waits for newly produced audio. Missing frames are silence, not replay.
    std::size_t consume(Stereo16 *out,std::size_t count,std::uint64_t epoch) noexcept {
        if(count)std::memset(out,0,count*sizeof(Stereo16));
        auto r=read_.load(std::memory_order_relaxed);
        const auto limit=written_.load(std::memory_order_acquire);
        std::size_t copied=0;
        while(copied<count&&r<limit){
            auto &block=blocks_[r%Capacity];
            if(block.epoch<epoch){offset_=0;read_.store(++r,std::memory_order_release);continue;}
            if(block.epoch!=epoch)break; // Old callback cannot discard future data.
            const auto take=(count-copied<BlockFrames-offset_)?count-copied:BlockFrames-offset_;
            std::memcpy(out+copied,block.frames.data()+offset_,take*sizeof(Stereo16));
            copied+=take;offset_+=take;
            if(offset_==BlockFrames){offset_=0;read_.store(++r,std::memory_order_release);}
        }
        return copied;
    }
};
}
