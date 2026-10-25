// xcrun clang++ -std=c++17 -O2 -fobjc-arc -fblocks -Ihost/src \
//   host/src/ApplePcmOutput.mm host/tests/ApplePcmOutputTests.mm \
//   -framework Foundation -framework AVFoundation -o /tmp/as6-pcm-output-tests
#include "ApplePcmOutput.hpp"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

using namespace as6::audio;
namespace {
unsigned checks=0;
void check(bool value,int line) {
    ++checks;
    if(!value){std::fprintf(stderr,"ApplePcmOutputTests failed at line %d\n",line);std::abort();}
}
#define CHECK(...) check((__VA_ARGS__),__LINE__)

// Observe transport calls at the native output boundary. Offline rendering
// alone cannot reveal silence during a synchronous full-clip PCM rebuild.
thread_local bool observingGain=false;
thread_local unsigned gainTransportChanges=0;
using TransportMethod=void (*)(id,SEL);
TransportMethod originalPause=nullptr,originalStop=nullptr;
void observePause(id player,SEL selector) {
    if(observingGain)++gainTransportChanges;originalPause(player,selector);
}
void observeStop(id player,SEL selector) {
    if(observingGain)++gainTransportChanges;originalStop(player,selector);
}
struct TransportObservation {
    Method pause=class_getInstanceMethod(AVAudioPlayerNode.class,@selector(pause));
    Method stop=class_getInstanceMethod(AVAudioPlayerNode.class,@selector(stop));
    TransportObservation() {
        CHECK(pause&&stop);
        originalPause=reinterpret_cast<TransportMethod>(method_setImplementation(pause,reinterpret_cast<IMP>(observePause)));
        originalStop=reinterpret_cast<TransportMethod>(method_setImplementation(stop,reinterpret_cast<IMP>(observeStop)));
    }
    ~TransportObservation() {
        method_setImplementation(pause,reinterpret_cast<IMP>(originalPause));
        method_setImplementation(stop,reinterpret_cast<IMP>(originalStop));
    }
};
void voiceGain(ApplePcmOutput &output,std::uint64_t voice,float gain) {
    gainTransportChanges=0;observingGain=true;
    const bool changed=output.setVoiceVolume(voice,gain);
    observingGain=false;CHECK(changed);CHECK(gainTransportChanges==0);
}
void masterGain(ApplePcmOutput &output,float gain) {
    gainTransportChanges=0;observingGain=true;output.setVolume(gain);
    observingGain=false;CHECK(gainTransportChanges==0);
}
SharedPcmClip makeClip(std::uint64_t frames) {
    auto clip=std::make_shared<PcmClip>();
    clip->sampleRate=48000;clip->channels=2;clip->frames=frames;
    clip->interleaved.resize(frames*2);
    for(std::uint64_t i=0;i<frames;++i){
        clip->interleaved[i*2]=std::int16_t(8000+(i*53)%12000);
        clip->interleaved[i*2+1]=-std::int16_t(4000+(i*97)%8000);
    }
    return clip;
}
// AVAudioPlayerNode smooths a live gain change. Check its settled samples,
// while position checks cover the entire rendered interval, including the ramp.
constexpr unsigned GainSettledFrames=1536;
template<class Envelope> void samples(const std::vector<float> &pcm,const PcmClip &clip,
                                    std::uint64_t start,float gain,Envelope envelope,unsigned skip=0) {
    CHECK(pcm.size()%2==0);
    for(std::size_t i=skip;i<pcm.size()/2;++i)for(unsigned channel=0;channel<2;++channel){
        const auto source=(start+i)%clip.frames;
        const float expected=float(clip.interleaved[source*2+channel])/32768.f*gain*envelope(i);
        if(std::abs(pcm[i*2+channel]-expected)>0.00003f){
            std::fprintf(stderr,"PCM mismatch frame %zu channel %u: %g expected %g\n",
                         i,channel,pcm[i*2+channel],expected);CHECK(false);
        }
        ++checks;
    }
}
void silence(const std::vector<float> &pcm) {for(float value:pcm)CHECK(std::abs(value)<0.000001f);}
constexpr auto flat=[](std::size_t){return 1.f;};
void liveGain() {
    auto clip=makeClip(48000);ApplePcmOutput output({true,4096});
    masterGain(output,.5f);
    const auto voice=output.playVoice(clip,false,0,.5f);
    samples(output.renderOffline(2048),*clip,0,.25f,flat);
    std::uint64_t position=2048;
    CHECK(output.voiceState(voice).positionFrames==position);
    const float gains[]={.75f,0.f,1.f};
    for(float gain:gains){
        voiceGain(output,voice,gain);
        CHECK(output.voiceState(voice).positionFrames==position);
        samples(output.renderOffline(2048),*clip,position,.5f*gain,flat,GainSettledFrames);
        position+=2048;CHECK(output.voiceState(voice).positionFrames==position);
    }
    masterGain(output,.8f);
    CHECK(output.voiceState(voice).positionFrames==position);
    samples(output.renderOffline(2048),*clip,position,.8f,flat,GainSettledFrames);
    CHECK(output.voiceState(voice).positionFrames==position+2048);
}
void loopAttack() {
    auto clip=makeClip(3072);ApplePcmOutput output({true,4096});
    const auto voice=output.playVoice(clip,true,100,.5f);
    samples(output.renderOffline(2048),*clip,0,.5f,[](std::size_t i){return float(i)/4800.f;});
    voiceGain(output,voice,.25f);
    CHECK(output.voiceState(voice).positionFrames==2048);
    samples(output.renderOffline(2048),*clip,2048,.25f,[](std::size_t i){return float(2048+i)/4800.f;},GainSettledFrames);
    // Cross both the end of the fade-in prefix and the looping PCM boundary.
    samples(output.renderOffline(4096),*clip,4096,.25f,[](std::size_t i){return std::min(float(4096+i)/4800.f,1.f);});
    CHECK(output.voiceState(voice).positionFrames==8192%clip->frames);
    masterGain(output,.5f);
    samples(output.renderOffline(2048),*clip,8192,.125f,flat,GainSettledFrames);
    CHECK(output.voiceState(voice).positionFrames==10240%clip->frames);
}
void pausedGain() {
    auto clip=makeClip(48000);ApplePcmOutput output({true,4096});
    const auto voice=output.playVoice(clip,true);
    output.renderOffline(2048);output.pause();
    const auto position=output.voiceState(voice).positionFrames;
    CHECK(output.voiceState(voice).phase==PcmOutputPhase::Paused);
    voiceGain(output,voice,.5f);masterGain(output,.5f);
    silence(output.renderOffline(2048));
    CHECK(output.voiceState(voice).positionFrames==position);
    output.resume();
    samples(output.renderOffline(2048),*clip,position,.25f,flat,GainSettledFrames);
    CHECK(output.voiceState(voice).positionFrames==position+2048);
}
void fadingGain() {
    auto clip=makeClip(48000);ApplePcmOutput output({true,4096});
    const auto voice=output.playVoice(clip,true,100,.5f);
    output.renderOffline(2048);
    CHECK(output.stopVoice(voice,100));
    const float attackAtStop=2048.f/4800.f;
    const auto envelope=[=](std::size_t i){return attackAtStop*float(4799-i)/4799.f;};
    samples(output.renderOffline(1024),*clip,2048,.5f,envelope);
    voiceGain(output,voice,.25f);
    CHECK(output.voiceState(voice).phase==PcmOutputPhase::FadingOut);
    CHECK(output.voiceState(voice).positionFrames==3072);
    samples(output.renderOffline(2048),*clip,3072,.25f,
            [=](std::size_t i){return envelope(1024+i);},GainSettledFrames);
    masterGain(output,.5f);
    samples(output.renderOffline(1728),*clip,5120,.125f,
            [=](std::size_t i){return envelope(3072+i);},GainSettledFrames);
    silence(output.renderOffline(2048));
}
}
int main(){@autoreleasepool {
    TransportObservation observation;
    liveGain();loopAttack();pausedGain();fadingGain();
    std::printf("ApplePcmOutputTests: %u checks passed\n",checks);
}}
