#include "NativeMusicService.hpp"
#include "NativeMusicCatalog.hpp"
#include "WaveImaClip.hpp"
#include "ApplePcmOutput.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <variant>

namespace as6::audio {
namespace {
enum class VoicePhase { Pending,Playing,Paused,Fading,Stopped,Failed };
struct Voice {
    std::int32_t track=-1,emitter=-1;
    std::atomic<VoicePhase> phase{VoicePhase::Pending};
    std::atomic<bool> cancelled{false};
    std::uint64_t output=0; // Audio owner only.
    float gain=1;          // Audio owner only.
    bool introduced=false;// Audio owner only; future queued plays are not targets yet.
    bool startCommitted=false; // Protected by mutex_; linearizes start against queued stops.
    SharedPcmClip prepared;
    bool loop=false;
    std::uint32_t fadeIn=0;
};
struct Fence {std::promise<void> reply;};
struct Render {std::uint32_t frames;std::promise<std::vector<float>> reply;};
struct ApplicationActive {bool active;};
using Batch=std::vector<NativeMusicAction>;
using Message=std::variant<Batch,Fence,Render,ApplicationActive>;
thread_local const void *audioOwner=nullptr;
bool validGain(float value) {return std::isfinite(value)&&value>=0&&value<=1;}
bool live(VoicePhase phase) {return phase==VoicePhase::Pending||phase==VoicePhase::Playing||phase==VoicePhase::Paused||phase==VoicePhase::Fading;}

class Service {
public:
    Service(std::string path,NativeMusicOptions options,std::uint64_t generation)
        :archive_(std::make_unique<StoredAudioArchive>(path)),options_(options),generation_(generation) {
        if(!options.cachedClips)throw std::invalid_argument("Music cache requires a retained clip");
        if(!options.maximumRenderFrames||options.maximumRenderFrames>65536)
            throw std::invalid_argument("Invalid native music render quantum");
        diagnostics_.generation=generation;diagnostics_.ready=true;
        thread_=std::thread([this]{run();});
    }
    ~Service() {close();}
    bool ready() const {std::lock_guard<std::mutex> lock(mutex_);return !closing_;}
    std::uint64_t generation() const noexcept{return generation_;}
    bool post(const NativeMusicAction *actions,std::size_t count) {
        if(count&&!actions)return false;
        if(!count)return ready();
        Batch values;
        if(count)values.assign(actions,actions+count);
        std::map<std::int32_t,std::shared_ptr<Voice>> prepared;
        for(const auto &a:values) {
            if(a.generation!=generation_)return false;
            switch(a.kind) {
            case NativeMusicActionKind::Play:{
                if(!nativeMusicResource(a.track)||a.emitter<0x40000000||a.third<0||!validGain(a.gain))return false;
                auto voice=std::make_shared<Voice>();voice->track=a.track;voice->emitter=a.emitter;voice->gain=a.gain;
                if(!prepared.emplace(a.emitter,std::move(voice)).second)return false;
                break;
            }
            case NativeMusicActionKind::SetVoiceGain:
            case NativeMusicActionKind::SetGroupGain:
            case NativeMusicActionKind::SetMasterGain:if(!validGain(a.gain))return false;break;
            case NativeMusicActionKind::Stop:
            case NativeMusicActionKind::StopAll:
            case NativeMusicActionKind::SetPaused:break;
            default:return false;
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if(closing_)return false;
            auto next=voices_; // Publication is all-or-none, including allocation failure.
            std::vector<std::shared_ptr<Voice>> stopped;
            bool requestedPaused=requestedGamePaused_;
            // Project intent in FIFO order. A Stop before a same-track Play
            // must not cancel the voice that has not been introduced yet.
            for(const auto &a:values) {
                if(a.kind==NativeMusicActionKind::Play) {
                    if(!next.emplace(a.emitter,prepared.at(a.emitter)).second)return false;
                } else if(a.kind==NativeMusicActionKind::Stop||a.kind==NativeMusicActionKind::StopAll) {
                    for(const auto &[id,voice]:next)
                        if(matches(*voice,a,a.kind==NativeMusicActionKind::StopAll)&&
                           (a.fadeMilliseconds==0||!voice->startCommitted))stopped.push_back(voice);
                } else if(a.kind==NativeMusicActionKind::SetPaused)requestedPaused=a.paused;
            }
            messages_.emplace_back(std::move(values));
            voices_.swap(next);
            for(const auto &voice:stopped)voice->cancelled=true;
            requestedGamePaused_=requestedPaused;
            ++diagnostics_.acceptedBatches;diagnostics_.acceptedActions+=count;
        }
        changed_.notify_one();return true;
    }
    bool isPlaying(std::int32_t track,std::int32_t emitter) const {
        std::lock_guard<std::mutex> lock(mutex_);
        if(closing_)return false;
        for(const auto &[id,voice]:voices_)
            if(voice->track==track&&(emitter==-1||emitter==id)) {
                if(voice->cancelled.load())continue;
                const auto phase=voice->phase.load();
                if(phase==VoicePhase::Pending||phase==VoicePhase::Playing||phase==VoicePhase::Fading)return true;
            }
        return false;
    }
    NativeMusicDiagnostics diagnostics() const {
        std::lock_guard<std::mutex> lock(mutex_);auto result=diagnostics_;
        result.ready=!closing_;result.pendingVoices=0;result.playingVoices=0;
        for(const auto &[id,voice]:voices_) {
            const auto phase=voice->phase.load();
            result.pendingVoices+=phase==VoicePhase::Pending;
            result.playingVoices+=phase==VoicePhase::Playing||phase==VoicePhase::Fading;
        }
        return result;
    }
    void applicationActive(bool active) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if(closing_)throw std::runtime_error("Music service is closed");
            messages_.emplace_back(ApplicationActive{active});
            requestedApplicationActive_=active;
        }
        changed_.notify_one();
    }
    std::future<void> fence() {
        Fence value;auto reply=value.reply.get_future();
        if(audioOwner==this) {value.reply.set_exception(std::make_exception_ptr(std::logic_error("Music owner cannot fence itself")));return reply;}
        enqueue(std::move(value));return reply;
    }
    std::future<std::vector<float>> render(std::uint32_t frames) {
        Render value{frames,{}};auto reply=value.reply.get_future();
        if(audioOwner==this) {value.reply.set_exception(std::make_exception_ptr(std::logic_error("Music owner cannot render through its queue")));return reply;}
        enqueue(std::move(value));return reply;
    }
    void close() {
        if(audioOwner==this)throw std::logic_error("Music owner cannot join itself");
        std::lock_guard<std::mutex> join(joinMutex_);
        {std::lock_guard<std::mutex> lock(mutex_);closing_=true;diagnostics_.ready=false;}
        changed_.notify_one();if(thread_.joinable())thread_.join();
    }
private:
    static bool matches(const Voice &voice,const NativeMusicAction &a,bool all=false) {
        return all||((a.track==-1||a.track==voice.track)&&(a.emitter==-1||a.emitter==voice.emitter));
    }
    template<class T>void enqueue(T value) {
        {std::lock_guard<std::mutex> lock(mutex_);if(closing_)throw std::runtime_error("Music service is closed");messages_.emplace_back(std::move(value));}
        changed_.notify_one();
    }
    std::vector<std::shared_ptr<Voice>> select(const NativeMusicAction &a,bool all=false) const {
        std::vector<std::shared_ptr<Voice>> result;
        std::lock_guard<std::mutex> lock(mutex_);
        for(const auto &[id,voice]:voices_)if(matches(*voice,a,all))result.push_back(voice);
        return result;
    }
    void failure(const std::string &text) {
        std::lock_guard<std::mutex> lock(mutex_);diagnostics_.lastError=text;
    }
    SharedPcmClip clip(std::int32_t id) {
        for(auto it=cache_.begin();it!=cache_.end();++it)if(it->first==id) {
            auto result=it->second;cache_.erase(it);cache_.emplace_front(id,result);
            std::lock_guard<std::mutex> lock(mutex_);++diagnostics_.cacheHits;return result;
        }
        const auto *resource=nativeMusicResource(id);
        if(!resource)throw std::invalid_argument("Unsupported native music resource");
        const auto *entry=archive_->findExact(resource->name);
        if(!entry||entry->size!=resource->bytes||entry->crc32!=resource->crc32)
            throw std::runtime_error("Music resource identity differs from original catalog");
        auto result=loadWaveImaClip(*archive_,resource->name);
        cache_.emplace_front(id,result);
        while(cache_.size()>options_.cachedClips)cache_.pop_back();
        {std::lock_guard<std::mutex> lock(mutex_);++diagnostics_.decodedClips;diagnostics_.cachedClips=unsigned(cache_.size());}
        return result;
    }
    float gain(const Voice &voice) const {return voice.gain*groupGain_*masterGain_;}
    bool playbackAllowed() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return !gamePaused_&&applicationActive_&&!requestedGamePaused_&&requestedApplicationActive_;
    }
    void start(ApplePcmOutput &output,const std::shared_ptr<Voice> &voice) {
        if(!voice->prepared)return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if(voice->cancelled.load()) {voice->prepared.reset();voice->phase=VoicePhase::Stopped;return;}
            // Lifecycle/pause intent is visible even while this worker decodes
            // a clip, before the corresponding FIFO message can be consumed.
            if(gamePaused_||!applicationActive_||requestedGamePaused_||!requestedApplicationActive_) {
                voice->phase=VoicePhase::Paused;return;
            }
            // A stop accepted before this point cancels preparation, including
            // a nonzero fade. Later stops fade the voice that has committed.
            voice->startCommitted=true;
        }
        voice->output=output.playVoice(std::move(voice->prepared),voice->loop,voice->fadeIn,gain(*voice));
        voice->phase=VoicePhase::Playing;
        std::lock_guard<std::mutex> lock(mutex_);++diagnostics_.playedVoices;
    }
    void transport(ApplePcmOutput &output) {
        if(!playbackAllowed()) {output.pause();return;}
        output.resume();
        NativeMusicAction all;
        for(const auto &voice:select(all,true))if(voice->introduced&&!voice->output&&voice->prepared) {
            try {start(output,voice);}
            catch(const std::exception &error) {
                voice->prepared.reset();voice->phase=VoicePhase::Failed;
                {std::lock_guard<std::mutex> lock(mutex_);++diagnostics_.failedVoices;}
                failure(error.what());
            }
        }
    }
    void update(ApplePcmOutput &output) {
        NativeMusicAction all;
        std::int32_t track=-1,emitter=-1;
        std::uint64_t epoch=0,position=0;
        for(const auto &voice:select(all,true)) {
            if(!voice->output)continue;
            const auto state=output.voiceState(voice->output);
            if(!state.knownVoice||state.phase==PcmOutputPhase::Finished||state.phase==PcmOutputPhase::Stopped)
                voice->phase=VoicePhase::Stopped;
            else if(state.phase==PcmOutputPhase::Paused)voice->phase=VoicePhase::Paused;
            else if(state.phase==PcmOutputPhase::FadingOut)voice->phase=VoicePhase::Fading;
            else voice->phase=VoicePhase::Playing;
            if(state.knownVoice&&live(voice->phase.load())&&voice->emitter>emitter) {
                track=voice->track;emitter=voice->emitter;epoch=voice->output;position=state.positionFrames;
            }
        }
        std::lock_guard<std::mutex> lock(mutex_);
        diagnostics_.observedTrack=track;diagnostics_.observedEmitter=emitter;
        diagnostics_.observedOutputEpoch=epoch;diagnostics_.observedPositionFrames=position;
        for(auto it=voices_.begin();it!=voices_.end();) {
            if(!live(it->second->phase.load()))it=voices_.erase(it);else ++it;
        }
    }
    void apply(ApplePcmOutput &output,const NativeMusicAction &a) {
        switch(a.kind) {
        case NativeMusicActionKind::Play:{
            auto list=select(a);if(list.empty())return;
            auto voice=list.front();
            voice->introduced=true;
            if(voice->cancelled.load()) {voice->phase=VoicePhase::Stopped;return;}
            try {
                voice->prepared=clip(a.track);voice->loop=a.loop;voice->fadeIn=std::uint32_t(a.third);
                if(voice->cancelled.load()) {voice->phase=VoicePhase::Stopped;return;}
                if(gamePaused_||!applicationActive_)voice->phase=VoicePhase::Paused;
                else start(output,voice);
            } catch(const std::exception &error) {
                voice->phase=VoicePhase::Failed;
                {std::lock_guard<std::mutex> lock(mutex_);++diagnostics_.failedVoices;}
                failure(error.what());
            }
            break;
        }
        case NativeMusicActionKind::Stop:
        case NativeMusicActionKind::StopAll:
            for(const auto &voice:select(a,a.kind==NativeMusicActionKind::StopAll)) {
                if(!voice->introduced)continue;
                if(voice->output)output.stopVoice(voice->output,a.fadeMilliseconds);
                else {voice->prepared.reset();voice->phase=VoicePhase::Stopped;}
            }
            break;
        case NativeMusicActionKind::SetVoiceGain:
            for(const auto &voice:select(a)) {
                if(!voice->introduced)continue;
                voice->gain=a.gain;if(voice->output)output.setVoiceVolume(voice->output,gain(*voice));
            }
            break;
        case NativeMusicActionKind::SetGroupGain:
        case NativeMusicActionKind::SetMasterGain:{
            if(a.kind==NativeMusicActionKind::SetGroupGain) {
                if(a.track!=1)break; // Native WAVE music belongs to original group1.
                groupGain_=a.gain;
            } else masterGain_=a.gain;
            NativeMusicAction all;
            for(const auto &voice:select(all,true))if(voice->output)output.setVoiceVolume(voice->output,gain(*voice));
            break;
        }
        case NativeMusicActionKind::SetPaused:
            gamePaused_=a.paused;
            transport(output);
            {std::lock_guard<std::mutex> lock(mutex_);diagnostics_.paused=gamePaused_;}
            break;
        }
    }
    void run() noexcept {
        audioOwner=this;
        try {
            ApplePcmOutput output({options_.offline,options_.maximumRenderFrames});
            for(;;) {
                Message message=Batch{};
                bool available=false;
                {
                    std::unique_lock<std::mutex> lock(mutex_);
                    changed_.wait_for(lock,std::chrono::milliseconds(10),[this]{return closing_||!messages_.empty();});
                    if(messages_.empty()&&closing_)break;
                    if(!messages_.empty()){message=std::move(messages_.front());messages_.pop_front();available=true;}
                }
                if(available) {
                    if(auto *batch=std::get_if<Batch>(&message)) {
                        for(const auto &action:*batch)try{apply(output,action);}catch(const std::exception &error){failure(error.what());}
                    } else if(auto *fence=std::get_if<Fence>(&message)) {
                        update(output);fence->reply.set_value();
                    } else if(auto *render=std::get_if<Render>(&message)) {
                        try {
                            auto pcm=output.renderOffline(render->frames);
                            {std::lock_guard<std::mutex> lock(mutex_);diagnostics_.renderedFrames+=render->frames;}
                            update(output);render->reply.set_value(std::move(pcm));
                        }catch(...){render->reply.set_exception(std::current_exception());}
                    } else {
                        applicationActive_=std::get<ApplicationActive>(message).active;
                        transport(output);
                        std::lock_guard<std::mutex> lock(mutex_);diagnostics_.applicationActive=applicationActive_;
                    }
                }
                update(output);
            }
            output.stop();
        } catch(const std::exception &error) {failure(error.what());}
        {
            std::lock_guard<std::mutex> lock(mutex_);closing_=true;diagnostics_.ready=false;
            voices_.clear();messages_.clear(); // Pending diagnostic promises become broken promises.
        }
        audioOwner=nullptr;
    }
    std::unique_ptr<StoredAudioArchive> archive_;
    NativeMusicOptions options_;
    std::uint64_t generation_;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<Message> messages_;
    std::map<std::int32_t,std::shared_ptr<Voice>> voices_;
    std::deque<std::pair<std::int32_t,SharedPcmClip>> cache_;
    NativeMusicDiagnostics diagnostics_;
    bool closing_=false,gamePaused_=false,applicationActive_=true;
    bool requestedGamePaused_=false,requestedApplicationActive_=true; // mutex_
    float groupGain_=1,masterGain_=1;
    std::mutex joinMutex_;
    std::thread thread_;
};
std::mutex serviceMutex;
std::shared_ptr<Service> service;
bool applicationIsActive=true; // Same owner lock as service publication.
std::atomic<std::uint64_t> generation{0};
std::atomic<std::uint32_t> emitter{0x40000000u};
std::shared_ptr<Service> current() {std::lock_guard<std::mutex> lock(serviceMutex);return service;}
template<class T>std::future<T> unavailable() {
    std::promise<T> promise;auto result=promise.get_future();
    promise.set_exception(std::make_exception_ptr(std::runtime_error("Native music service unavailable")));return result;
}
}

bool configureNativeMusic(const std::string &path,NativeMusicOptions options) noexcept {
    try {
        auto created=std::make_shared<Service>(path,options,generation.fetch_add(1)+1);
        std::shared_ptr<Service> old;
        {std::lock_guard<std::mutex> lock(serviceMutex);old.swap(service);service=std::move(created);if(!applicationIsActive)service->applicationActive(false);}
        if(old)old->close();return true;
    }catch(...){return false;}
}
void shutdownNativeMusic() noexcept {
    try {std::shared_ptr<Service> old;{std::lock_guard<std::mutex> lock(serviceMutex);old.swap(service);}if(old)old->close();}catch(...){}
}
bool nativeMusicReady() noexcept {try{auto s=current();return s&&s->ready();}catch(...){return false;}}
std::uint64_t nativeMusicGeneration() noexcept {try{auto s=current();return s?s->generation():0;}catch(...){return 0;}}
std::int32_t nativeMusicReserveEmitter() noexcept {
    auto value=emitter.load();
    while(value<=0x7fffffffu)if(emitter.compare_exchange_weak(value,value+1))return std::int32_t(value);
    return -1;
}
bool nativeMusicPostBatch(const NativeMusicAction *a,std::size_t count) noexcept {try{auto s=current();return s&&s->post(a,count);}catch(...){return false;}}
bool nativeMusicIsPlaying(std::int32_t track,std::int32_t id) noexcept {try{auto s=current();return s&&s->isPlaying(track,id);}catch(...){return false;}}
void setNativeMusicApplicationActive(bool active) noexcept {
    try {std::lock_guard<std::mutex> lock(serviceMutex);applicationIsActive=active;if(service)service->applicationActive(active);}catch(...) {}
}
NativeMusicDiagnostics nativeMusicDiagnostics() noexcept {try{if(auto s=current())return s->diagnostics();}catch(...){}return {};}
std::future<void> drainNativeMusicCommands() {if(auto s=current())return s->fence();return unavailable<void>();}
std::future<std::vector<float>> renderNativeMusicOffline(std::uint32_t frames) {if(auto s=current())return s->render(frames);return unavailable<std::vector<float>>();}
}
