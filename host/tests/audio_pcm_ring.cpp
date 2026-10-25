// clang++ -std=c++17 -O2 -pthread -Ihost/src host/tests/audio_pcm_ring.cpp -o /tmp/as6-audio-pcm-ring
#include "AudioPcmRing.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <thread>

using as6audio::PcmRing;
using as6audio::Stereo16;

#define CHECK(condition) do { if (!(condition)) { \
    std::fprintf(stderr,"%s:%d: %s\n",__FILE__,__LINE__,#condition);std::abort(); \
} } while (false)

static Stereo16 sample(std::size_t frame) {
    const auto value=std::int16_t(frame%30000+1);
    return {value,std::int16_t(-value)};
}
static void fill(std::array<Stereo16,PcmRing::BlockFrames> &block,std::size_t first) {
    for(std::size_t i=0;i<block.size();++i)block[i]=sample(first+i);
}
static void expect(const Stereo16 *pcm,std::size_t count,std::size_t first) {
    for(std::size_t i=0;i<count;++i) {
        const auto value=sample(first+i);
        CHECK(pcm[i].left==value.left&&pcm[i].right==value.right);
    }
}
static void expectSilence(const Stereo16 *pcm,std::size_t count) {
    for(std::size_t i=0;i<count;++i)CHECK(pcm[i].left==0&&pcm[i].right==0);
}

static void largeCallback() {
    PcmRing ring;
    std::array<Stereo16,PcmRing::BlockFrames> block{};
    std::array<Stereo16,4096> output{};
    // A 4096-frame hardware request requires all eight original mixer blocks.
    for(std::size_t i=0;i<PcmRing::Capacity;++i) {
        fill(block,i*block.size());CHECK(ring.push(block.data(),1));
    }
    CHECK(ring.queuedBlocks()==PcmRing::Capacity);
    CHECK(!ring.push(block.data(),1));
    CHECK(ring.consume(output.data(),output.size(),1)==output.size());
    expect(output.data(),output.size(),0);CHECK(ring.queuedBlocks()==0);
    CHECK(ring.consume(output.data(),output.size(),1)==0);
    expectSilence(output.data(),output.size());
}

static void partialAndWrappedBlocks() {
    PcmRing ring;
    std::array<Stereo16,PcmRing::BlockFrames> block{};
    std::array<Stereo16,1000> output{};
    std::size_t produced=0,consumed=0;
    for(unsigned iteration=0;iteration<40;++iteration) {
        while(ring.queuedBlocks()<PcmRing::Capacity) {
            fill(block,produced);CHECK(ring.push(block.data(),7));produced+=block.size();
        }
        const auto count=std::size_t(1+(iteration*137)%output.size());
        CHECK(ring.consume(output.data(),count,7)==count);
        expect(output.data(),count,consumed);consumed+=count;
    }
    while(consumed<produced) {
        const auto wanted=std::min(output.size(),produced-consumed);
        CHECK(ring.consume(output.data(),wanted,7)==wanted);
        expect(output.data(),wanted,consumed);consumed+=wanted;
    }
    CHECK(ring.queuedBlocks()==0);
}

static void epochRetirement() {
    PcmRing ring;
    std::array<Stereo16,PcmRing::BlockFrames> block{};
    std::array<Stereo16,1024> output{};
    fill(block,0);CHECK(ring.push(block.data(),1));
    CHECK(ring.consume(output.data(),37,1)==37);expect(output.data(),37,0);
    fill(block,1000);CHECK(ring.push(block.data(),2));
    // Retire the partially consumed old epoch and start the next at frame zero.
    CHECK(ring.consume(output.data(),output.size(),2)==block.size());
    expect(output.data(),block.size(),1000);
    expectSilence(output.data()+block.size(),output.size()-block.size());
    fill(block,2000);CHECK(ring.push(block.data(),3));
    // An older in-flight callback must preserve a future epoch's audio.
    CHECK(ring.consume(output.data(),100,2)==0);expectSilence(output.data(),100);
    CHECK(ring.queuedBlocks()==1);
    CHECK(ring.consume(output.data(),100,3)==100);expect(output.data(),100,2000);
    CHECK(ring.consume(output.data(),output.size(),3)==block.size()-100);
    expect(output.data(),block.size()-100,2100);
    expectSilence(output.data()+block.size()-100,output.size()-block.size()+100);
}

static void concurrentProducerConsumer() {
    PcmRing ring;
    constexpr std::size_t blocks=2000,total=blocks*PcmRing::BlockFrames;
    std::thread producer([&] {
        std::array<Stereo16,PcmRing::BlockFrames> block{};
        for(std::size_t i=0;i<blocks;++i) {
            fill(block,i*block.size());
            while(!ring.push(block.data(),5))std::this_thread::yield();
        }
    });
    std::array<Stereo16,4096> output{};
    std::size_t consumed=0,iteration=0;
    while(consumed<total) {
        const auto count=std::min(std::size_t(1+(iteration++*311)%output.size()),total-consumed);
        const auto copied=ring.consume(output.data(),count,5);
        expect(output.data(),copied,consumed);
        expectSilence(output.data()+copied,count-copied);
        consumed+=copied;
        if(!copied)std::this_thread::yield();
    }
    producer.join();CHECK(ring.queuedBlocks()==0);
}

int main() {
    largeCallback();partialAndWrappedBlocks();epochRetirement();concurrentProducerConsumer();
    std::puts("Audio PCM ring: large callbacks, wrap, epochs and concurrent ordering passed");
}
