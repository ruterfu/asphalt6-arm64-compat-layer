#include "ApplePcmOutput.hpp"
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

namespace as6::audio {
namespace {
[[noreturn]] void fail(NSError *error, const char *operation) {
    throw std::runtime_error(std::string(operation)+": "+
        (error ? error.localizedDescription.UTF8String : "AVAudioEngine failed"));
}
template<class F> auto apple(F &&function) -> decltype(function()) {
    @autoreleasepool {
        @try { return function(); }
        @catch (NSException *exception) {
            const char *reason=(exception.reason?:exception.name).UTF8String;
            throw std::runtime_error(std::string("Apple PCM output: ")+(reason?reason:"Native audio exception"));
        }
    }
}
void connectNodes(AVAudioEngine *engine, AVAudioNode *source, AVAudioNode *target, AVAudioFormat *format,AVAudioNodeBus inputBus=0) {
    NSError *error=nil;
    if (@available(macOS 27.0,iOS 27.0,tvOS 27.0,watchOS 27.0,*)) {
        if (![engine connect:source to:target fromBus:0 toBus:inputBus format:format error:&error]) fail(error,"Connect PCM node");
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [engine connect:source to:target fromBus:0 toBus:inputBus format:format];
#pragma clang diagnostic pop
    }
}
void startPlayer(AVAudioPlayerNode *player, AVAudioTime *when) {
    if (@available(macOS 27.0,iOS 27.0,tvOS 27.0,watchOS 27.0,*)) {
        NSError *error=nil;
        if (![player playAtTime:when error:&error]) fail(error,"Start PCM player");
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [player playAtTime:when];
#pragma clang diagnostic pop
    }
}
void validate(const SharedPcmClip &clip) {
    if (!clip || !clip->frames || !clip->sampleRate || clip->sampleRate>384000 ||
        (clip->channels!=1 && clip->channels!=2)) throw std::invalid_argument("Invalid PCM clip format");
    if (clip->frames>std::numeric_limits<AVAudioFrameCount>::max() ||
        clip->frames>std::numeric_limits<std::size_t>::max()/clip->channels)
        throw std::length_error("PCM clip is too large for an AVAudioPCMBuffer");
    if (clip->interleaved.size()!=clip->frames*clip->channels)
        throw std::invalid_argument("PCM clip frame/sample counts disagree");
}
struct Completion { std::atomic<std::uint64_t> ticket{0}; };
struct Voice {
    SharedPcmClip clip;
    __strong AVAudioPlayerNode *player=nil;
    __strong AVAudioPCMBuffer *buffer=nil;
    __strong AVAudioPCMBuffer *attackBuffer=nil;
    std::shared_ptr<Completion> completion=std::make_shared<Completion>();
    std::uint64_t generation=0,epoch=0,sourceOrigin=0,scheduledFrames=0,pausedFrames=0,attackFrames=0;
    bool sourceLoops=false,scheduledLoop=false,paused=false,fading=false;
    float volume=1,bakedGain=1;
    std::uint64_t attackElapsedOrigin=0;
    float fadeStartGain=1;
    void invalidate() { generation+=2; completion->ticket.store(generation,std::memory_order_release); }
    bool completed() const { return completion->ticket.load(std::memory_order_acquire)==(generation|1); }
    std::uint64_t played() const {
        if (paused) return pausedFrames;
        AVAudioTime *renderTime=player.lastRenderTime;
        if(!renderTime || (!renderTime.sampleTimeValid && !renderTime.hostTimeValid)) return 0;
        AVAudioTime *time=[player playerTimeForNodeTime:renderTime];
        return time && time.sampleTime>0 ? std::uint64_t(time.sampleTime) : 0;
    }
    std::uint64_t positionAt(std::uint64_t frames) const {
        const auto elapsed=std::min(frames,scheduledLoop?std::numeric_limits<std::uint64_t>::max():scheduledFrames);
        return sourceLoops ? (sourceOrigin+elapsed)%clip->frames : std::min(sourceOrigin+elapsed,clip->frames);
    }
    std::uint64_t position() const {return positionAt(played());}
};
AVAudioPCMBuffer *bufferFor(const PcmClip &clip, std::uint64_t start, AVAudioFrameCount frames,
                           bool wrap, bool fade, float scale=1, std::uint64_t attackFrames=0,std::uint64_t attackOffset=0) {
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:clip.sampleRate channels:clip.channels];
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    if (!buffer) throw std::bad_alloc();
    buffer.frameLength=frames;
    for (std::uint64_t frame=0;frame<frames;++frame) {
        const auto source=wrap ? (start+frame)%clip.frames : start+frame;
        const float gain=scale*(fade ? (frames>1 ? float(frames-1-frame)/float(frames-1) : 0.f)
            : (attackFrames ? float(std::min(frame+attackOffset,attackFrames))/float(attackFrames) : 1.f));
        for (unsigned channel=0;channel<clip.channels;++channel)
            buffer.floatChannelData[channel][frame]=float(clip.interleaved[source*clip.channels+channel])/32768.f*gain;
    }
    return buffer;
}
void schedule(Voice &voice, AVAudioPCMBuffer *buffer, bool loop) {
    voice.invalidate();
    const auto ticket=voice.generation;
    const auto completion=voice.completion;
    voice.buffer=buffer;
    voice.scheduledFrames=buffer.frameLength;
    voice.scheduledLoop=loop;
    [voice.player scheduleBuffer:buffer atTime:nil options:loop?AVAudioPlayerNodeBufferLoops:0
        completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
        completionHandler:^(AVAudioPlayerNodeCompletionCallbackType) {
            // No owner/object/node reference, queue operation or user callback.
            auto expected=ticket;
            completion->ticket.compare_exchange_strong(expected,ticket|1,std::memory_order_acq_rel);
        }];
}
} // namespace

struct ApplePcmOutput::Impl {
    Options options;
    mutable bool ownerBound=false;
    mutable std::thread::id owner;
    __strong AVAudioEngine *engine=nil;
    __strong AVAudioFormat *renderFormat=nil;
    __strong NSMutableArray<AVAudioPlayerNode *> *availablePlayers=nil;
    std::map<std::uint64_t,std::unique_ptr<Voice>> voices;
    std::map<std::uint64_t,PcmOutputState> completed;
    PcmOutputState last;
    std::uint64_t nextEpoch=0,selectedEpoch=0;
    float volume=1;
    bool paused=false;
    explicit Impl(Options value):options(value) {
        if (!options.maximumRenderFrames || options.maximumRenderFrames>65536 || !options.voiceCapacity || options.voiceCapacity>64)
            throw std::invalid_argument("Invalid offline render quantum");
    }
    void requireOwner() const {
        const auto thread=std::this_thread::get_id();
        if (!ownerBound) {owner=thread;ownerBound=true;}
        else if (owner!=thread) throw std::logic_error("ApplePcmOutput belongs to one audio worker");
    }
    void ensureEngine(const PcmClip &clip) {
        // An empty graph has no voice clock to preserve. Recreate its native
        // render timeline instead of reusing detached mixer bus/player state.
        if(engine&&voices.empty()){[engine stop];engine=nil;renderFormat=nil;availablePlayers=nil;}
        if (!engine) {
            engine=[AVAudioEngine new];
            renderFormat=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:clip.sampleRate channels:clip.channels];
            if (options.offline) {
                NSError *error=nil;
                if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                    format:renderFormat maximumFrameCount:options.maximumRenderFrames error:&error])
                    fail(error,"Enable offline PCM rendering");
            }
            availablePlayers=[NSMutableArray new];
            for(unsigned i=0;i<options.voiceCapacity;++i){
                AVAudioPlayerNode *player=[AVAudioPlayerNode new];[engine attachNode:player];
                connectNodes(engine,player,engine.mainMixerNode,renderFormat,i);player.volume=1;[availablePlayers addObject:player];
            }
            if(options.offline)connectNodes(engine,engine.mainMixerNode,engine.outputNode,renderFormat);
        }
        if(clip.sampleRate!=renderFormat.sampleRate || clip.channels!=renderFormat.channelCount)
            throw std::invalid_argument("Concurrent native PCM voices must share a sample rate and channel format");
    }
    void startEngine() {
        if (!engine.running) {
            [engine prepare];
            NSError *error=nil;
            if (![engine startAndReturnError:&error]) fail(error,"Start PCM engine");
        }
    }
    void startVoice(Voice &voice) {
        AVAudioTime *when=nil;
        if(options.offline)when=[AVAudioTime timeWithSampleTime:AVAudioFramePosition(
            engine.manualRenderingSampleTime*double(voice.clip->sampleRate)/renderFormat.sampleRate) atRate:voice.clip->sampleRate];
        startPlayer(voice.player,when);
    }
    void rebuildGain(Voice &voice,float gain) {
        if(gain==voice.bakedGain)return;
        const bool wasPaused=voice.paused;
        const auto elapsed=voice.played(),start=voice.positionAt(elapsed);
        if(!wasPaused)[voice.player pause];
        const auto attackOffset=voice.attackElapsedOrigin+elapsed;
        const auto remainingAttack=voice.attackFrames>attackOffset?voice.attackFrames-attackOffset:0;
        AVAudioPCMBuffer *buffer=nil,*prefix=nil;
        float fadeStart=voice.fadeStartGain;
        try {
            if(voice.fading){
                const auto remaining=voice.scheduledFrames-std::min(elapsed,voice.scheduledFrames);
                if(!remaining){auto expected=voice.generation;voice.completion->ticket.compare_exchange_strong(expected,voice.generation|1);return;}
                fadeStart*=voice.scheduledFrames>1?float(voice.scheduledFrames-1-std::min(elapsed,voice.scheduledFrames-1))/float(voice.scheduledFrames-1):0.f;
                buffer=bufferFor(*voice.clip,start,AVAudioFrameCount(remaining),voice.sourceLoops,true,gain*fadeStart);
            }else if(voice.sourceLoops){
                buffer=bufferFor(*voice.clip,(start+remainingAttack)%voice.clip->frames,AVAudioFrameCount(voice.clip->frames),true,false,gain);
                if(remainingAttack)prefix=bufferFor(*voice.clip,start,AVAudioFrameCount(remainingAttack),true,false,gain,voice.attackFrames,attackOffset);
            }else{
                const auto remaining=voice.clip->frames-start;
                if(!remaining){auto expected=voice.generation;voice.completion->ticket.compare_exchange_strong(expected,voice.generation|1);return;}
                buffer=bufferFor(*voice.clip,start,AVAudioFrameCount(remaining),false,false,gain,voice.attackFrames,attackOffset);
            }
        }catch(...){if(!wasPaused)startVoice(voice);throw;}
        voice.invalidate();[voice.player stop];voice.player.volume=1;
        voice.sourceOrigin=start;voice.pausedFrames=0;voice.attackElapsedOrigin=attackOffset;
        voice.fadeStartGain=fadeStart;voice.bakedGain=gain;voice.attackBuffer=prefix;
        if(prefix)[voice.player scheduleBuffer:prefix atTime:nil options:0 completionHandler:nil];
        schedule(voice,buffer,!voice.fading&&voice.sourceLoops);
        voice.paused=wasPaused;if(!wasPaused)startVoice(voice);
    }
    unsigned retiringCount() const {
        return unsigned(std::count_if(voices.begin(),voices.end(),[](const auto &entry){return entry.second->fading;}));
    }
    PcmOutputState snapshot(const Voice &voice,PcmOutputPhase phase,bool current) const {
        PcmOutputState state;
        state.phase=phase;state.epoch=voice.epoch;state.frames=voice.clip->frames;
        state.positionFrames=voice.position();state.sampleRate=voice.clip->sampleRate;
        state.channels=voice.clip->channels;state.retiringVoices=retiringCount();
        state.volume=volume;state.voiceVolume=voice.volume;state.looping=voice.scheduledLoop;
        state.hasActiveVoice=current;state.knownVoice=true;return state;
    }
    void remember(const Voice &voice,PcmOutputPhase phase) {
        last=snapshot(voice,phase,false);completed[voice.epoch]=last;
        while(completed.size()>64)completed.erase(completed.begin());
    }
    void discard(std::unique_ptr<Voice> &voice) {
        voice->invalidate();[voice->player stop];voice->player.volume=1;[availablePlayers addObject:voice->player];voice.reset();
    }
    void collect() {
        for(auto it=voices.begin();it!=voices.end();) {
            if(it->second->completed()){remember(*it->second,PcmOutputPhase::Finished);discard(it->second);it=voices.erase(it);}
            else ++it;
        }
    }
    PcmOutputState voiceState(std::uint64_t epoch) {
        collect();const auto found=voices.find(epoch);
        if(found!=voices.end()) {
            const auto &voice=*found->second;
            return snapshot(voice,voice.paused?PcmOutputPhase::Paused:(voice.fading?PcmOutputPhase::FadingOut:PcmOutputPhase::Playing),!voice.fading);
        }
        auto old=completed.find(epoch);
        auto result=old!=completed.end()?old->second:PcmOutputState{};
        result.epoch=epoch;result.retiringVoices=retiringCount();result.volume=volume;return result;
    }
    PcmOutputState state() {
        auto result=voiceState(selectedEpoch);
        if(!result.knownVoice){result=last;result.volume=volume;result.retiringVoices=retiringCount();}
        return result;
    }
    void stopAll() {
        while(!voices.empty()){auto it=voices.begin();remember(*it->second,PcmOutputPhase::Stopped);discard(it->second);voices.erase(it);}
        last.phase=PcmOutputPhase::Stopped;last.retiringVoices=0;last.hasActiveVoice=false;
    }
    void shutdown() noexcept {
        @autoreleasepool {
            @try {for(auto &entry:voices)discard(entry.second);voices.clear();[engine stop];engine=nil;availablePlayers=nil;}
            @catch(NSException *) {engine=nil;availablePlayers=nil;}
        }
    }
};

ApplePcmOutput::ApplePcmOutput():ApplePcmOutput(Options{}) {}
ApplePcmOutput::ApplePcmOutput(Options options):impl_(std::make_unique<Impl>(options)) {}
ApplePcmOutput::~ApplePcmOutput() {impl_->shutdown();}

std::uint64_t ApplePcmOutput::playVoice(SharedPcmClip clip,bool loop,std::uint32_t fadeInMs,float initialGain) {
    impl_->requireOwner();validate(clip);
    if(!std::isfinite(initialGain)||initialGain<0||initialGain>1)throw std::invalid_argument("Initial PCM gain must be in0..1");
    return apple([&]()->std::uint64_t{
        impl_->collect();impl_->ensureEngine(*clip);
        auto voice=std::make_unique<Voice>();voice->clip=std::move(clip);voice->epoch=++impl_->nextEpoch;
        voice->sourceLoops=loop;voice->volume=initialGain;voice->bakedGain=impl_->volume*initialGain;
        if(!impl_->availablePlayers.count)throw std::length_error("Native PCM voice capacity exhausted");
        voice->attackFrames=(std::uint64_t(fadeInMs)*voice->clip->sampleRate+999)/1000;
        if(voice->attackFrames>std::numeric_limits<AVAudioFrameCount>::max())throw std::length_error("PCM fade-in is too long");
        AVAudioPCMBuffer *buffer=bufferFor(*voice->clip,loop&&voice->attackFrames?voice->attackFrames%voice->clip->frames:0,
            AVAudioFrameCount(voice->clip->frames),loop&&voice->attackFrames,false,voice->bakedGain,loop?0:voice->attackFrames);
        voice->player=impl_->availablePlayers.lastObject;[impl_->availablePlayers removeLastObject];
        voice->player.volume=1;
        if(loop&&voice->attackFrames){
            voice->attackBuffer=bufferFor(*voice->clip,0,AVAudioFrameCount(voice->attackFrames),true,false,voice->bakedGain,voice->attackFrames);
            [voice->player scheduleBuffer:voice->attackBuffer atTime:nil options:0 completionHandler:nil];
        }
        schedule(*voice,buffer,loop);
        impl_->startEngine();voice->paused=impl_->paused;
        if(!voice->paused)impl_->startVoice(*voice);
        const auto epoch=voice->epoch;impl_->voices.emplace(epoch,std::move(voice));impl_->selectedEpoch=epoch;return epoch;
    });
}
void ApplePcmOutput::play(SharedPcmClip clip,bool loop) {
    impl_->requireOwner();validate(clip);
    const auto found=impl_->voices.find(impl_->selectedEpoch);
    if(found!=impl_->voices.end()&&!found->second->fading)stopVoice(found->first,0);
    (void)playVoice(std::move(clip),loop);
}

bool ApplePcmOutput::stopVoice(std::uint64_t epoch,std::uint32_t fadeMs) {
    impl_->requireOwner();
    return apple([&]{
        impl_->collect();auto found=impl_->voices.find(epoch);
        if(found==impl_->voices.end())return false;
        auto &voice=*found->second;
        if(!fadeMs||voice.paused){impl_->remember(voice,PcmOutputPhase::Stopped);impl_->discard(found->second);impl_->voices.erase(found);return true;}
        const auto elapsed=voice.played();
        const auto start=voice.position();
        auto count=(std::uint64_t(fadeMs)*voice.clip->sampleRate+999)/1000;
        if(!voice.sourceLoops)count=std::min(count,voice.clip->frames-start);
        if(voice.fading&&count>=voice.scheduledFrames-std::min(elapsed,voice.scheduledFrames))return true;
        if(!count){impl_->remember(voice,PcmOutputPhase::Finished);impl_->discard(found->second);impl_->voices.erase(found);return true;}
        if(count>std::numeric_limits<AVAudioFrameCount>::max())throw std::length_error("PCM fade is too long");
        const float currentGain=voice.fading ? voice.fadeStartGain*(voice.scheduledFrames>1?
            float(voice.scheduledFrames-1-std::min(elapsed,voice.scheduledFrames-1))/float(voice.scheduledFrames-1):0.f)
            : (voice.attackFrames?float(std::min(voice.attackElapsedOrigin+elapsed,voice.attackFrames))/float(voice.attackFrames):1.f);
        AVAudioPCMBuffer *tail=bufferFor(*voice.clip,start,AVAudioFrameCount(count),voice.sourceLoops,true,currentGain*voice.bakedGain);
        voice.invalidate();[voice.player stop];voice.sourceOrigin=start;voice.fading=true;voice.pausedFrames=0;
        voice.fadeStartGain=currentGain;voice.attackFrames=0;voice.attackElapsedOrigin=0;voice.attackBuffer=nil;
        schedule(voice,tail,false);impl_->startVoice(voice);return true;
    });
}
void ApplePcmOutput::stop(std::uint32_t fadeMs) {
    impl_->requireOwner();
    if(!fadeMs)apple([&]{impl_->stopAll();});else(void)stopVoice(impl_->selectedEpoch,fadeMs);
}
bool ApplePcmOutput::setVoiceVolume(std::uint64_t epoch,float volume) {
    impl_->requireOwner();
    if(!std::isfinite(volume)||volume<0||volume>1)throw std::invalid_argument("PCM voice volume must be in0..1");
    return apple([&]{impl_->collect();auto found=impl_->voices.find(epoch);if(found==impl_->voices.end())return false;
        found->second->volume=volume;impl_->rebuildGain(*found->second,impl_->volume*volume);return true;});
}
void ApplePcmOutput::setVolume(float volume) {
    impl_->requireOwner();
    if(!std::isfinite(volume)||volume<0||volume>1)throw std::invalid_argument("PCM volume must be in0..1");
    apple([&]{impl_->collect();impl_->volume=volume;for(auto &entry:impl_->voices)impl_->rebuildGain(*entry.second,volume*entry.second->volume);});
}
void ApplePcmOutput::pause() {
    impl_->requireOwner();
    apple([&]{impl_->collect();impl_->paused=true;for(auto &entry:impl_->voices){auto &voice=*entry.second;
        if(!voice.paused){voice.pausedFrames=voice.played();[voice.player pause];voice.paused=true;}}});
}
void ApplePcmOutput::resume() {
    impl_->requireOwner();
    apple([&]{impl_->collect();impl_->paused=false;if(impl_->engine)impl_->startEngine();
        for(auto &entry:impl_->voices){auto &voice=*entry.second;if(voice.paused){impl_->startVoice(voice);voice.paused=false;}}});
}
PcmOutputState ApplePcmOutput::state() const {impl_->requireOwner();return apple([&]{return impl_->state();});}
PcmOutputState ApplePcmOutput::voiceState(std::uint64_t epoch) const {impl_->requireOwner();return apple([&]{return impl_->voiceState(epoch);});}
bool ApplePcmOutput::isPlaying() const {
    impl_->requireOwner();return apple([&]{impl_->collect();return std::any_of(impl_->voices.begin(),impl_->voices.end(),[](const auto &entry){return !entry.second->fading&&!entry.second->paused;});});
}
std::vector<float> ApplePcmOutput::renderOffline(std::uint32_t frames) {
    impl_->requireOwner();
    if(!impl_->options.offline||!impl_->engine)throw std::logic_error("Offline rendering requires an offline output and a clip");
    return apple([&]{
        const unsigned channels=impl_->renderFormat.channelCount;
        if(frames>std::numeric_limits<std::size_t>::max()/channels)throw std::length_error("Offline render is too large");
        std::vector<float> result(std::size_t(frames)*channels);
        AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc]initWithPCMFormat:impl_->renderFormat frameCapacity:impl_->options.maximumRenderFrames];
        for(std::uint32_t at=0;at<frames;){
            const auto count=std::min(frames-at,impl_->options.maximumRenderFrames);NSError *error=nil;
            const auto status=[impl_->engine renderOffline:count toBuffer:buffer error:&error];
            if(status!=AVAudioEngineManualRenderingStatusSuccess||buffer.frameLength!=count)fail(error,"Render offline PCM");
            for(unsigned channel=0;channel<channels;++channel)for(std::uint32_t i=0;i<count;++i)
                result[std::size_t(at+i)*channels+channel]=buffer.floatChannelData[channel][i];
            at+=count;
            for(auto &entry:impl_->voices){auto &voice=*entry.second;
                if(!voice.paused&&!voice.scheduledLoop&&voice.played()>=voice.scheduledFrames){auto expected=voice.generation;
                    voice.completion->ticket.compare_exchange_strong(expected,voice.generation|1,std::memory_order_acq_rel);}}
        }
        impl_->collect();return result;
    });
}
} // namespace as6::audio
