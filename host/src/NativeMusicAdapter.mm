#import "NativeMusicAdapter.h"
#include "MusicController.hpp"
#include "MusicRandomSelection.hpp"
#include "NativeMusicAction.hpp"
#include "NativeMusicCatalog.hpp"
#include <array>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <unordered_map>

namespace {
using namespace as6::audio;
constexpr std::uint32_t RandomSeed=0x75b47cu;
struct Owner { bool historyImported=false; MusicRandomState random{}; };
struct Session {
    bool enabled=false;
    std::uint64_t generation=0;
    std::unordered_map<std::uint32_t,Owner> owners;
};
std::mutex sessionsMutex;
std::unordered_map<std::uintptr_t,Session> sessions;
std::uintptr_t key(GuestVM *vm) { return reinterpret_cast<std::uintptr_t>((__bridge void *)vm); }
bool wav(std::int32_t track) { return nativeMusicResource(track)!=nullptr; }
bool nativeState(std::int32_t track) { return track==-1 || wav(track); }
bool read(GuestVM *vm,std::uint32_t address,void *value,std::size_t bytes) {
    return address && bytes<=UINT32_MAX-address && GuestRead(vm,address,value,bytes);
}
bool read32(GuestVM *vm,std::uint32_t address,std::uint32_t &value) { return read(vm,address,&value,4); }
bool importHistory(GuestVM *vm,std::uint32_t self,Owner &owner) {
    if(owner.historyImported)return true;
    std::array<std::uint32_t,8> d{};
    if(!read(vm,self+0x6cu,d.data(),sizeof(d)))return false;
    const auto valid=[](std::uint32_t cur,std::uint32_t first,std::uint32_t last,std::uint32_t node) {
        return first && node && !(cur&3u) && !(first&3u) && !(node&3u) &&
            first<=UINT32_MAX-512u && last==first+512u && cur>=first && cur<last;
    };
    if(!valid(d[0],d[1],d[2],d[3])||!valid(d[4],d[5],d[6],d[7])||d[7]<d[3]||((d[7]-d[3])&3u))return false;
    const auto count=std::int64_t((d[2]-d[0])/4u)+std::int64_t((d[4]-d[5])/4u)+
        (std::int64_t((d[7]-d[3])/4u)-1)*128;
    if(count<0||count>3)return false;
    std::uint32_t startBuffer=0,endBuffer=0;
    if(!read32(vm,d[3],startBuffer)||!read32(vm,d[7],endBuffer)||startBuffer!=d[1]||endBuffer!=d[5])return false;
    if(d[3]==d[7]&&(d[1]!=d[5]||d[2]!=d[6]))return false;
    auto cur=d[0],last=d[2],node=d[3];
    MusicRandomState imported{};imported.recentCount=std::uint32_t(count);
    for(std::uint32_t i=0;i<imported.recentCount;++i) {
        if(!read(vm,cur,&imported.recent[i],4))return false;
        cur+=4;
        if(cur==last) {
            if(node>UINT32_MAX-4)return false;
            node+=4;
            if(!read32(vm,node,cur)||!cur||(cur&3u)||cur>UINT32_MAX-512u)return false;
            last=cur+512u;
        }
    }
    if(cur!=d[4]||node!=d[7])return false;
    owner.random=imported;owner.historyImported=true;return true;
}
struct RecordingBackend final:MusicBackend {
    std::uint64_t generation;
    MusicRandomState random;
    std::uint32_t filterMask,filterAllowed;
    bool randomUsed=false,originalRandomLoop=false;
    std::array<NativeMusicAction,8> actions{};
    std::size_t count=0;
    RecordingBackend(std::uint64_t gen,MusicRandomState rng,std::uint32_t mask,std::uint32_t allowed)
        :generation(gen),random(rng),filterMask(mask),filterAllowed(allowed){}
    void add(NativeMusicAction action) {
        if(count==actions.size())throw std::runtime_error("Native music batch overflow");
        action.generation=generation;actions[count++]=action;
    }
    SoundId chooseRandomSound(SoundId group) override {
        randomUsed=true;return chooseOriginalRandomMusic(group,random);
    }
    EmitterId play2D(SoundId track,bool loop,std::int32_t third,bool fourth) override {
        if(!wav(track))throw std::runtime_error("Legacy sound reached native recording backend");
        if(filterMask && !(filterMask&filterAllowed))return -1;
        const auto token=nativeMusicReserveEmitter();
        if(token<0x40000000)throw std::runtime_error("Native music emitter reservation failed");
        NativeMusicAction action;action.kind=NativeMusicActionKind::Play;
        action.track=track;action.emitter=token;action.loop=loop||originalRandomLoop;action.third=third;action.fourth=fourth;
        action.gain=1.0f;add(action);
        return loop||fourth?token:-1;
    }
    void stop(SoundId track,std::int32_t second,EmitterId emitter) override {
        if(!wav(track))throw std::runtime_error("Legacy stop reached native recording backend");
        NativeMusicAction action;action.kind=NativeMusicActionKind::Stop;
        action.track=track;action.emitter=emitter;action.fadeMilliseconds=second>0?std::uint32_t(second):0u;add(action);
    }
    bool isPlaying(SoundId track,EmitterId emitter) override { return nativeMusicIsPlaying(track,emitter); }
    bool publish() const { return !count || nativeMusicPostBatch(actions.data(),count); }
};
float floatWord(std::uint32_t word) { float value;std::memcpy(&value,&word,4);return value; }
AS6NativeMusicBoundaryResult handle(GuestVM *vm,std::uint32_t pc) {
    if(!vm||GuestHasStopRequest(vm))return AS6NativeMusicFailed;
    std::lock_guard<std::mutex> guard(sessionsMutex);
    auto [it,inserted]=sessions.try_emplace(key(vm));auto &session=it->second;
    if(inserted) { session.enabled=nativeMusicReady();session.generation=nativeMusicGeneration(); }
    if(!session.enabled)return AS6NativeMusicOriginal;
    if(!nativeMusicReady()||session.generation!=nativeMusicGeneration())return AS6NativeMusicFailed;
    const auto self=GuestReg(vm,0);
    if(!self||self>UINT32_MAX-0x1f8u)return AS6NativeMusicFailed;
    const auto track=std::int32_t(GuestReg(vm,1));
    NativeMusicAction action;action.generation=session.generation;
    const auto post=[&] { return nativeMusicPostBatch(&action,1)?AS6NativeMusicOriginal:AS6NativeMusicFailed; };
    if(pc==0xdfa68u) {
        action.kind=NativeMusicActionKind::SetGroupGain;action.track=track;action.gain=floatWord(GuestReg(vm,2));return post();
    }
    if(pc==0xdfa88u) {
        action.kind=NativeMusicActionKind::SetMasterGain;action.gain=floatWord(GuestReg(vm,1));return post();
    }
    if(pc==0xe0108u||pc==0xe00b8u) {
        std::uint32_t depth=0;if(!read32(vm,self+0x1e0u,depth))return AS6NativeMusicFailed;
        const auto resumed=std::int32_t(depth)>0?depth-1u:depth;
        if((pc==0xe0108u&&depth==0)||(pc==0xe00b8u&&resumed==0)) {
            action.kind=NativeMusicActionKind::SetPaused;action.paused=pc==0xe0108u;return post();
        }
        return AS6NativeMusicOriginal;
    }
    if(pc==0xe25a4u) {
        std::array<NativeMusicAction,2> batch{};
        batch[0].generation=batch[1].generation=session.generation;
        batch[0].kind=NativeMusicActionKind::StopAll;batch[1].kind=NativeMusicActionKind::SetPaused;batch[1].paused=false;
        return nativeMusicPostBatch(batch.data(),batch.size())?AS6NativeMusicOriginal:AS6NativeMusicFailed;
    }
    auto &owner=session.owners[self];
    if(pc==0xe0968u) {
        if(track!=590)return AS6NativeMusicOriginal;
        if(!importHistory(vm,self,owner))return AS6NativeMusicFailed;
        auto random=owner.random;
        if(!read32(vm,RandomSeed,random.seed))return AS6NativeMusicFailed;
        const auto selected=chooseOriginalRandomMusic(590,random);
        if(!GuestWrite(vm,RandomSeed,&random.seed,4))return AS6NativeMusicFailed;
        owner.random=random;GuestSetRet(vm,std::uint32_t(selected));return AS6NativeMusicHandled;
    }
    if(pc==0xdf53cu) {
        if(!wav(track))return AS6NativeMusicOriginal;
        GuestSetRet(vm,nativeMusicIsPlaying(track,std::int32_t(GuestReg(vm,2))));return AS6NativeMusicHandled;
    }
    if(pc==0xdf498u||pc==0xdfaa0u) {
        if(!wav(track))return AS6NativeMusicOriginal;
        action.track=track;
        if(pc==0xdf498u) {
            action.kind=NativeMusicActionKind::SetVoiceGain;action.emitter=std::int32_t(GuestReg(vm,2));
            action.gain=floatWord(GuestReg(vm,3));
        } else {
            action.kind=NativeMusicActionKind::Stop;action.emitter=std::int32_t(GuestReg(vm,3));
            const auto fade=std::int32_t(GuestReg(vm,2));action.fadeMilliseconds=fade>0?std::uint32_t(fade):0u;
        }
        return nativeMusicPostBatch(&action,1)?AS6NativeMusicHandled:AS6NativeMusicFailed;
    }
    std::uint32_t mask=0,allowed=0;
    if(pc==0xe20e4u) {
        if(!wav(track))return AS6NativeMusicOriginal;
        if(!read32(vm,self+0x1e8u,mask)||!read32(vm,self+0x1ecu,allowed))return AS6NativeMusicFailed;
        std::uint32_t fourth=0;if(!read32(vm,GuestSP(vm),fourth))return AS6NativeMusicFailed;
        RecordingBackend backend(session.generation,{},mask,allowed);
        const auto emitter=backend.play2D(track,bool(GuestReg(vm,2)&255u),std::int32_t(GuestReg(vm,3)),bool(fourth&255u));
        if(!backend.publish())return AS6NativeMusicFailed;
        GuestSetRet(vm,std::uint32_t(emitter));return AS6NativeMusicHandled;
    }
    if(pc!=0xe241cu&&pc!=0xe24c4u&&pc!=0xe24fcu&&pc!=0xe253cu)return AS6NativeMusicFailed;
    std::array<std::uint8_t,10> bytes{};
    if(!read(vm,self+0x58u,bytes.data(),bytes.size()))return AS6NativeMusicFailed;
    MusicState before{};std::memcpy(&before.track,bytes.data(),4);std::memcpy(&before.emitter,bytes.data()+4,4);
    before.playing=bytes[8]!=0;before.randomMode=bytes[9]!=0;
    const bool enabled=bool(GuestReg(vm,1)&255u);
    if(pc==0xe24fcu&&(!nativeState(before.track)||!nativeState(track)))return AS6NativeMusicOriginal;
    if(pc==0xe24c4u&&before.playing&&!nativeState(before.track))return AS6NativeMusicOriginal;
    if(pc==0xe241cu&&!nativeState(before.track)&&!(enabled&&!before.playing&&before.randomMode))return AS6NativeMusicOriginal;
    if(pc==0xe253cu&&before.randomMode&&before.playing&&before.track!=-1&&!wav(before.track))return AS6NativeMusicOriginal;
    const bool playingTransition=bytes[8]!=std::uint8_t(enabled);
    const bool mayChoose=(pc==0xe24c4u&&before.playing)||
        (pc==0xe241cu&&enabled&&playingTransition&&before.randomMode)||
        (pc==0xe253cu&&before.randomMode&&before.playing&&before.track!=-1);
    if(mayChoose&&!importHistory(vm,self,owner))return AS6NativeMusicFailed;
    auto random=owner.random;
    if(mayChoose&&!read32(vm,RandomSeed,random.seed))return AS6NativeMusicFailed;
    if(!read32(vm,self+0x1e8u,mask)||!read32(vm,self+0x1ecu,allowed))return AS6NativeMusicFailed;
    RecordingBackend backend(session.generation,random,mask,allowed);
    auto effective=before;
    if(pc==0xe241cu&&playingTransition)effective.playing=!enabled;
    backend.originalRandomLoop=pc==0xe241cu&&before.randomMode&&bytes[9]!=1;
    MusicController controller(backend,effective);
    if(pc==0xe241cu)controller.setPlaying(enabled);
    else if(pc==0xe24c4u)controller.setRandom();
    else if(pc==0xe24fcu)controller.setTrack(track);
    else controller.updateRandom();
    const auto after=controller.state();
    std::memcpy(bytes.data(),&after.track,4);std::memcpy(bytes.data()+4,&after.emitter,4);
    if((pc==0xe241cu&&playingTransition)||
       ((pc==0xe24c4u||pc==0xe24fcu)&&before.playing)||backend.randomUsed)bytes[8]=after.playing;
    if(pc==0xe24c4u||(pc==0xe253cu&&backend.randomUsed))bytes[9]=1;
    if(pc==0xe24fcu)bytes[9]=0;
    if(!backend.publish())return AS6NativeMusicFailed;
    if(backend.randomUsed) {
        if(!GuestWrite(vm,RandomSeed,&backend.random.seed,4))return AS6NativeMusicFailed;
        owner.random=backend.random;
    }
    if(!GuestWrite(vm,self+0x58u,bytes.data(),bytes.size()))return AS6NativeMusicFailed;
    return AS6NativeMusicHandled;
}
}
extern "C" AS6NativeMusicBoundaryResult AS6NativeMusicHandleBoundary(GuestVM *vm,std::uint32_t pc) {
    try { return handle(vm,pc); } catch(...) { return AS6NativeMusicFailed; }
}
extern "C" void AS6NativeMusicForgetVM(GuestVM *vm) {
    std::lock_guard<std::mutex> guard(sessionsMutex);sessions.erase(key(vm));
}
