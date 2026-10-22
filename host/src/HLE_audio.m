// Native audio output for the original armv7 mixer. The guest still decodes and
// mixes its own samples; this bridge only translates Apple audio API objects,
// callback arguments and PCM buffers across the 32/64-bit boundary.
#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <atomic>
#import <algorithm>
#import <memory>
#import <unordered_map>
#import <vector>
#import <cstring>
#include <chrono>
#include <pthread.h>
#include <time.h>
#include <new>
#include <mutex>
#include <condition_variable>
#include <cerrno>
#include "AudioPcmRing.hpp"
#include "AudioProducerPrivate.h"

struct GuestAudioBuffer { uint32_t channels, byteSize, data; };
static_assert(sizeof(GuestAudioBuffer) == 12, "armv7 AudioBuffer");
static_assert(sizeof(AudioComponentDescription) == 20, "AudioComponentDescription layout");
static_assert(sizeof(AudioStreamBasicDescription) == 40, "ASBD layout");
static_assert(sizeof(AudioTimeStamp) == 64 && offsetof(AudioTimeStamp, mFlags) == 56,
              "AudioTimeStamp fields match Darwin armv7");

static constexpr size_t kAudioScratchSize = 1u << 20;
static constexpr uint32_t kAudioDataOffset = 0x200;
static std::atomic<uint64_t> g_audioCalls{0}, g_audioFrames{0}, g_audioBusy{0};
static std::atomic<uint64_t> g_audioNonzeroBuffers{0};
static std::atomic<uint64_t> g_audioErrors{0}, g_audioNanoseconds{0}, g_audioMaxNanoseconds{0}, g_audioOverruns{0};
static std::atomic<uint64_t> g_audioProducerWaiting{0},g_audioProducedBlocks{0},g_audioUnderrunFrames{0},g_audioProducerErrors{0};
static std::mutex g_audioTurnMutex;
static std::condition_variable g_audioTurnChanged;
static std::atomic<uint64_t> g_audioAcquisitionSerial{0};
static void AudioProducerAcquiredTurn(void) {
    {
        std::lock_guard<std::mutex> lock(g_audioTurnMutex);
        g_audioProducerWaiting.fetch_sub(1,std::memory_order_release);
        g_audioAcquisitionSerial.fetch_add(1,std::memory_order_release);
    }
    g_audioTurnChanged.notify_all(); // Producer only; never RemoteIO.
}
extern "C" BOOL GuestAudioProducerNeedsService(void) {
    return g_audioProducerWaiting.load(std::memory_order_acquire)!=0;
}
extern "C" int GuestAudioWaitForProducerTurn(void) {
    // Called only by a non-RT HLEPthreadBlockingCall operation after VM release.
    std::unique_lock<std::mutex> lock(g_audioTurnMutex);
    const auto serial=g_audioAcquisitionSerial.load(std::memory_order_acquire);
    g_audioTurnChanged.wait_for(lock,std::chrono::milliseconds(2),[&]{
        return !g_audioProducerWaiting.load(std::memory_order_acquire)||
            g_audioAcquisitionSerial.load(std::memory_order_acquire)!=serial;
    });
    return 0;
}

// Read counters only from the existing heartbeat; the real-time thread never
// formats output, writes logs, or waits for diagnostics.
extern "C" NSDictionary *GuestAudioPerformanceSnapshot(void) {
    return @{@"callbacks":@(g_audioCalls.load(std::memory_order_relaxed)),
        @"frames":@(g_audioFrames.load(std::memory_order_relaxed)),
        @"busy":@(g_audioBusy.load(std::memory_order_relaxed)),
        @"nonzero_buffers":@(g_audioNonzeroBuffers.load(std::memory_order_relaxed)),
        @"errors":@(g_audioErrors.load(std::memory_order_relaxed)),
        @"callback_nanoseconds":@(g_audioNanoseconds.load(std::memory_order_relaxed)),
        @"max_callback_nanoseconds":@(g_audioMaxNanoseconds.load(std::memory_order_relaxed)),
        @"deadline_overruns":@(g_audioOverruns.load(std::memory_order_relaxed)),
        @"producer_waiting":@(g_audioProducerWaiting.load(std::memory_order_relaxed)),
        @"produced_blocks":@(g_audioProducedBlocks.load(std::memory_order_relaxed)),
        @"underrun_frames":@(g_audioUnderrunFrames.load(std::memory_order_relaxed)),
        @"producer_errors":@(g_audioProducerErrors.load(std::memory_order_relaxed))};
}

template<typename Fn> static Fn AudioHost(const char *symbol) {
    return reinterpret_cast<Fn>(HLEHostSymbol(symbol));
}

struct GuestAudioUnit {
    GuestVM *__strong vm = nil; // A retiring detached producer may still own state.
    AudioUnit unit = nullptr;
    gva_t callback = 0, refcon = 0, scratch = 0;
    AudioStreamBasicDescription format = {};
    GuestCpuSnapshot *context = nullptr;
    std::vector<uint8_t> hostPCM;
    as6audio::PcmRing ring;
    std::array<as6audio::Stereo16,as6audio::PcmRing::BlockFrames> producerPCM{};
    std::array<as6audio::Stereo16,4096> realtimePCM{};
    std::atomic<bool> active{false},buffered{false},bufferedContract{false},retired{false},producerFailed{false};
    std::atomic<uint64_t> epoch{1};
    bool workerStarted=false; // Control/VM lock only.
    std::atomic<bool> inFlight{false};
    std::mutex drainMutex;
    std::condition_variable drained;
    gva_t producerStack=0;
    uint64_t producedFrames=0; // Producer only.
    ~GuestAudioUnit() { if (context) GuestCPUFree(context); }
};

// Private cancellation capability. The only permitted cancellation site is
// before acquisition of THIS callback's original outer mutex, never a native
// instruction boundary or another lock/bridge. WasCancelled is a query, not
// consumption: VM and Audio must both see it until callback restoration ends.
struct AudioCallbackTag {
    GuestAudioUnit *state=nullptr;
    GuestVM *__unsafe_unretained vm=nil;
    gva_t mutex=0;
    uint64_t epoch=0;
    bool cancelled=false;
};
static thread_local AudioCallbackTag g_audioCallbackTag;
// A producer can release the VM inside an original blocking bridge. Publish
// demand only while restoring those VM locks, after the host wait has finished.
// Keeping it set during mixer execution would make the producer yield to itself.
static thread_local GuestVM *__unsafe_unretained g_audioResumeWaitVM=nil;
extern "C" BOOL GuestAudioProducerBeginResumeWait(GuestVM *vm) {
    if(!g_audioCallbackTag.state||g_audioCallbackTag.vm!=vm||g_audioResumeWaitVM)return NO;
    g_audioResumeWaitVM=vm;
    g_audioProducerWaiting.fetch_add(1,std::memory_order_release);
    return YES;
}
extern "C" void GuestAudioProducerEndResumeWait(GuestVM *vm,BOOL registered) {
    if(!registered||g_audioResumeWaitVM!=vm)return;
    g_audioResumeWaitVM=nil;
    // Cancellation and epoch changes still need VM/CPU restoration and drain.
    AudioProducerAcquiredTurn();
}
extern "C" BOOL GuestAudioProducerIsMutexWait(GuestVM *vm,gva_t mutex) {
    return g_audioCallbackTag.state&&g_audioCallbackTag.vm==vm&&
        g_audioCallbackTag.mutex==mutex;
}
extern "C" BOOL GuestAudioProducerCancelMutexWait(GuestVM *vm,gva_t mutex) {
    if(!GuestAudioProducerIsMutexWait(vm,mutex))return NO;
    auto &tag=g_audioCallbackTag;
    return !tag.state->active.load(std::memory_order_acquire)||
        tag.state->retired.load(std::memory_order_acquire)||
        tag.state->epoch.load(std::memory_order_acquire)!=tag.epoch||GuestHasStopRequest(vm);
}
extern "C" void GuestAudioProducerMarkCancelled(void) {
    if(g_audioCallbackTag.state)g_audioCallbackTag.cancelled=true;
}
extern "C" BOOL GuestAudioProducerWasCancelled(GuestVM *vm) {
    return g_audioCallbackTag.state&&g_audioCallbackTag.vm==vm&&g_audioCallbackTag.cancelled;
}

struct AudioDrainWait {
    GuestAudioUnit *state;
    uint64_t controlToken;
};
static int WaitForAudioDrain(void *opaque) {
    auto &wait=*static_cast<AudioDrainWait *>(opaque);
    auto &state=*wait.state;
    std::unique_lock<std::mutex> lock(state.drainMutex);
    for(;;){
        // A superseded control operation must not drain a newer callback.
        // That callback may wait for the original mutex this caller holds.
        if(state.retired.load(std::memory_order_acquire)||
           state.epoch.load(std::memory_order_acquire)!=wait.controlToken)
            return ECANCELED;
        if(!state.inFlight.load(std::memory_order_acquire))return 0;
        // Permanent stop retains ownership and refuses original destruction.
        if(GuestHasStopRequest(state.vm))return ECANCELED;
        state.drained.wait_for(lock,std::chrono::milliseconds(1));
    }
}
static bool DrainAudio(GuestAudioUnit &state,uint64_t controlToken) {
    if(state.retired.load(std::memory_order_acquire)||
       state.epoch.load(std::memory_order_acquire)!=controlToken)return false;
    if(!state.inFlight.load(std::memory_order_acquire))return true;
    AudioDrainWait wait{&state,controlToken};
    return HLEPthreadBlockingCall(state.vm,WaitForAudioDrain,&wait)==0;
}
static std::unordered_map<gva_t, std::shared_ptr<GuestAudioUnit>> g_audioUnits;
static std::unordered_map<gva_t, AudioComponentDescription> g_audioComponents;

static OSStatus ConfigureOutputOnlyRemoteIO(AudioUnit unit) {
    auto set = AudioHost<OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                     AudioUnitElement, const void *, UInt32)>("_AudioUnitSetProperty");
    if (!set) return kAudioUnitErr_InvalidProperty;
    // The original only enables output bus 0 and registers an output mixer.
    // Explicitly retain that direction on modern RemoteIO: input is bus 1.
    UInt32 disabled = 0;
    return set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
               1, &disabled, sizeof(disabled));
}

static GuestAudioUnit *AudioUnitFor(gva_t handle) {
    auto found = g_audioUnits.find(handle);
    return found == g_audioUnits.end() ? nullptr : found->second.get();
}

// Narrowly admitted original output contract. Other formats retain the existing
// direct try-lock callback below; no format conversion or guest mixer rewrite.
static bool KnownBufferedFormat(const GuestAudioUnit &state) {
    const auto &f=state.format;
    const bool format=state.callback==0x6204ec && f.mSampleRate==48000 &&
        f.mFormatID==kAudioFormatLinearPCM && f.mChannelsPerFrame==2 &&
        f.mBitsPerChannel==16 && f.mBytesPerFrame==4 &&
        f.mFramesPerPacket==1 && f.mBytesPerPacket==4 &&
        (f.mFormatFlags&(kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked))==
            (kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked) &&
        !(f.mFormatFlags&(kAudioFormatFlagIsFloat|kAudioFormatFlagIsBigEndian|
                          kAudioFormatFlagIsNonInterleaved|kAudioFormatFlagIsAlignedHigh));
    uint32_t vtable=0,target=0;
    return format&&state.refcon<=UINT32_MAX-0xac&&GuestRead(state.vm,state.refcon,&vtable,4)&&
        vtable<=UINT32_MAX-0x44&&GuestRead(state.vm,vtable+0x44,&target,4)&&target==0x620aa4;
}

// Caller holds VM lock. Never join, wait for worker completion, reset a ring
// index, or invoke the original mixer from a control/main thread.
static void DisableBuffered(GuestAudioUnit &state) {
    state.buffered.store(false,std::memory_order_release);
    state.epoch.fetch_add(1,std::memory_order_acq_rel);
}

static bool AudioControlStillCurrent(const GuestAudioUnit &state,uint64_t token) {
    return !state.retired.load(std::memory_order_acquire)&&
        state.epoch.load(std::memory_order_acquire)==token;
}

static OSStatus ProduceOriginalBlock(GuestAudioUnit &state) {
    GuestVM *vm=state.vm;
    if(GuestCPUSave(vm,state.context)!=GuestExecutionSuccess)
        return kAudioUnitErr_CannotDoInCurrentContext;
    OSStatus result=kAudioUnitErr_CannotDoInCurrentContext;
    @try {
        // A dedicated registered guest stack remains valid if an original
        // guest mutex blocks and its HLE temporarily hands the VM to main.
        GuestSetReg(vm,13,state.producerStack+(1u<<18)-16);
        const gva_t list=state.scratch,flagSlot=list+0x100,timestamp=list+0x120;
        GuestAudioBuffer buffer={2,512*4,list+kAudioDataOffset};
        AudioTimeStamp stamp={};stamp.mSampleTime=double(state.producedFrames);
        stamp.mFlags=kAudioTimeStampSampleTimeValid;
        const uint32_t zero=0,one=1;
        bool valid=GuestWrite(vm,list,&one,4)&&GuestWrite(vm,list+4,&buffer,sizeof(buffer))&&
            GuestWrite(vm,flagSlot,&zero,4)&&GuestWrite(vm,timestamp,&stamp,sizeof(stamp))&&
            GuestWrite(vm,buffer.data,state.producerPCM.data(),sizeof(state.producerPCM));
        if(valid){
            const uint32_t args[6]={state.refcon,flagSlot,timestamp,0,512,list};
            result=(OSStatus)GuestCall(vm,state.callback,args,6,10000000);
            GuestAudioBuffer rendered={};
            uint32_t count=0;
            if(GuestAudioProducerWasCancelled(vm))result=kAudioUnitErr_CannotDoInCurrentContext;
            else if(GuestLastExecutionResult(vm)!=GuestExecutionSuccess ||
               !GuestRead(vm,list,&count,4)||count!=1||
               !GuestRead(vm,list+4,&rendered,sizeof(rendered))||
               rendered.channels!=2||rendered.byteSize!=sizeof(state.producerPCM)||
               rendered.data!=buffer.data||
               !GuestRead(vm,rendered.data,state.producerPCM.data(),sizeof(state.producerPCM)))
                result=kAudioUnitErr_InvalidParameter;
        }
    } @finally {
        if(GuestCPURestore(vm,state.context)!=GuestExecutionSuccess){
            GuestRequestFault(vm);result=kAudioUnitErr_CannotDoInCurrentContext;
        }
    }
    return result;
}

static void *AudioProducerThread(void *opaque) {
    std::unique_ptr<std::shared_ptr<GuestAudioUnit>> owner(
        static_cast<std::shared_ptr<GuestAudioUnit> *>(opaque));
    auto state=*owner;owner.reset();
    while(!state->retired.load(std::memory_order_acquire)){
        @autoreleasepool {
            if(GuestHasStopRequest(state->vm))break;
            if(!state->active.load(std::memory_order_acquire)||
               !state->buffered.load(std::memory_order_acquire)||
               state->producerFailed.load(std::memory_order_acquire)||state->ring.queuedBlocks()>=3){
                const timespec pause={0,1000000};nanosleep(&pause,nullptr);continue;
            }
            // Kept set while blocking, so a main quantum can hand over the VM.
            g_audioProducerWaiting.fetch_add(1,std::memory_order_release);
            GuestLock(state->vm);
            AudioProducerAcquiredTurn();
            @try {
                if(state->retired.load(std::memory_order_acquire)||
                   !state->active.load(std::memory_order_acquire)||
                   !state->buffered.load(std::memory_order_acquire)||
                   GuestHasStopRequest(state->vm))continue;
                const uint64_t epoch=state->epoch.load(std::memory_order_acquire);
                // Validate dynamic identity, not just the static default vtable.
                uint32_t vtable=0,target=0;
                if(state->refcon>UINT32_MAX-0xac||!GuestRead(state->vm,state->refcon,&vtable,4)||
                   vtable>UINT32_MAX-0x44||
                   !GuestRead(state->vm,vtable+0x44,&target,4)||target!=0x620aa4){
                    state->producerFailed.store(true,std::memory_order_release);
                    g_audioProducerErrors.fetch_add(1,std::memory_order_relaxed);continue;
                }
                state->inFlight.store(true,std::memory_order_release);
                g_audioCallbackTag={state.get(),state->vm,state->refcon+4,epoch,false};
                std::memset(state->producerPCM.data(),0,sizeof(state->producerPCM));
                OSStatus result=kAudioUnitErr_CannotDoInCurrentContext;
                bool cancelled=false;
                @try {result=ProduceOriginalBlock(*state);cancelled=g_audioCallbackTag.cancelled;}
                @finally {
                    g_audioCallbackTag={};
                    {
                        std::lock_guard<std::mutex> lock(state->drainMutex);
                        state->inFlight.store(false,std::memory_order_release);
                    }
                    state->drained.notify_all();
                }
                if(!cancelled&&result==noErr && state->active.load(std::memory_order_acquire)&&
                   state->buffered.load(std::memory_order_acquire)&&
                   epoch==state->epoch.load(std::memory_order_acquire)){
                    if(state->ring.push(state->producerPCM.data(),epoch)){
                        state->producedFrames+=512;
                        g_audioProducedBlocks.fetch_add(1,std::memory_order_relaxed);
                    }
                }else if(!cancelled&&result!=noErr){
                    g_audioProducerErrors.fetch_add(1,std::memory_order_relaxed);
                    // A failed original invocation is never replayed/retried.
                    state->producerFailed.store(true,std::memory_order_release);
                }
            } @finally {GuestUnlock(state->vm);}
        }
    }
    return nullptr;
}

static bool StartBufferedWorker(const std::shared_ptr<GuestAudioUnit> &state) {
    if(state->workerStarted)return true;
    if(!state->producerStack){
        state->producerStack=GuestAlloc(state->vm,1u<<18);
        if(!state->producerStack)return false;
        GuestRegisterStack(state->vm,state->producerStack,1u<<18);
    }
    auto *owner=new(std::nothrow) std::shared_ptr<GuestAudioUnit>(state);
    if(!owner)return false;
    pthread_attr_t attrs;
    if(pthread_attr_init(&attrs)){delete owner;return false;}
    if(pthread_attr_setdetachstate(&attrs,PTHREAD_CREATE_DETACHED)){
        pthread_attr_destroy(&attrs);delete owner;return false;
    }
    pthread_t thread;
    const int error=pthread_create(&thread,&attrs,AudioProducerThread,owner);
    pthread_attr_destroy(&attrs);
    if(error){delete owner;return false;}
    state->workerStarted=true;return true;
}

static void RefreshBuffered(const std::shared_ptr<GuestAudioUnit> &state) {
    const bool contract=KnownBufferedFormat(*state);
    state->bufferedContract.store(contract,std::memory_order_release);
    const bool enable=state->active.load(std::memory_order_acquire)&&contract&&
        !state->retired.load(std::memory_order_acquire);
    if(enable&&!StartBufferedWorker(state)){
        state->producerFailed.store(true,std::memory_order_release);
        g_audioProducerErrors.fetch_add(1,std::memory_order_relaxed);
    }
    state->buffered.store(enable,std::memory_order_release);
}

static void AudioResult(GuestVM *vm, const char *operation, OSStatus status) {
    GuestTrace(vm, @"[audio] %s -> %d", operation, (int)status);
    GuestSetRet(vm, (uint32_t)status);
}

static OSStatus AudioSilence(AudioUnitRenderActionFlags *flags, AudioBufferList *data,
                              OSStatus error) {
    if (data) {
        for (UInt32 i = 0; i < data->mNumberBuffers; i++)
            if (data->mBuffers[i].mData && data->mBuffers[i].mDataByteSize)
                memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
    }
    if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
    return error;
}

static OSStatus AudioBufferedError(AudioUnitRenderActionFlags *flags,AudioBufferList *data,OSStatus error) {
    if(data&&data->mNumberBuffers==1){
        auto &b=data->mBuffers[0];
        if(b.mData&&b.mDataByteSize<=4096*sizeof(as6audio::Stereo16))
            std::memset(b.mData,0,b.mDataByteSize);
    }
    if(flags)*flags|=kAudioUnitRenderAction_OutputIsSilence;
    return error;
}

static OSStatus AudioBufferedRender(GuestAudioUnit &state,AudioUnitRenderActionFlags *flags,
                                    UInt32 bus,UInt32 frames,AudioBufferList *data) {
    if(!data||bus!=0||data->mNumberBuffers!=1||frames>state.realtimePCM.size()||
       data->mBuffers[0].mNumberChannels!=2)
        return AudioBufferedError(flags,data,kAudioUnitErr_InvalidParameter);
    AudioBuffer &buffer=data->mBuffers[0];
    const size_t bytes=size_t(frames)*sizeof(as6audio::Stereo16);
    if(buffer.mData && buffer.mDataByteSize && buffer.mDataByteSize<bytes)
        return AudioBufferedError(flags,data,kAudioUnitErr_TooManyFramesToProcess);
    auto *out=buffer.mData?static_cast<as6audio::Stereo16 *>(buffer.mData):state.realtimePCM.data();
    const auto copied=state.ring.consume(out,frames,state.epoch.load(std::memory_order_acquire));
    buffer.mData=out;buffer.mDataByteSize=UInt32(bytes);buffer.mNumberChannels=2;
    if(copied<frames)g_audioUnderrunFrames.fetch_add(frames-copied,std::memory_order_relaxed);
    bool nonzero=false;
    for(size_t i=0;i<copied;++i)nonzero|=out[i].left!=0||out[i].right!=0;
    if(flags){if(nonzero)*flags&=~kAudioUnitRenderAction_OutputIsSilence;
              else *flags|=kAudioUnitRenderAction_OutputIsSilence;}
    g_audioCalls.fetch_add(1,std::memory_order_relaxed);
    g_audioFrames.fetch_add(copied,std::memory_order_relaxed);
    if(nonzero)g_audioNonzeroBuffers.fetch_add(1,std::memory_order_relaxed);
    // No VM lock/API, allocation, log, thread wake, clock query or wait here.
    return noErr;
}

static OSStatus AudioRender(void *opaque, AudioUnitRenderActionFlags *flags,
                             const AudioTimeStamp *time, UInt32 bus, UInt32 frames,
                             AudioBufferList *data) {
    auto *state = static_cast<GuestAudioUnit *>(opaque);
    if(state&&state->bufferedContract.load(std::memory_order_acquire))
        return AudioBufferedRender(*state,flags,bus,frames,data);
    if (!state || !state->vm || !data || data->mNumberBuffers > 16)
        return AudioSilence(flags, data, kAudioUnitErr_InvalidParameter);
    GuestVM *vm = state->vm;
    // A control call such as Stop may be waiting for this callback. Never wait
    // for the guest CPU lock or dispatch synchronously to the UI thread here.
    if (!GuestTryLock(vm)) {
        g_audioBusy.fetch_add(1, std::memory_order_relaxed);
        return AudioSilence(flags, data, kAudioUnitErr_CannotDoInCurrentContext);
    }
    if (!state->callback) {
        GuestUnlock(vm);
        return AudioSilence(flags, data, kAudioUnitErr_InvalidParameter);
    }
    const int startErrno=errno;
    const auto callbackStart=std::chrono::steady_clock::now();
    errno=startErrno;
    OSStatus result = kAudioUnitErr_CannotDoInCurrentContext;
    uint32_t nonzeroBuffers = 0;
    bool saved = GuestCPUSave(vm, state->context) == GuestExecutionSuccess;
    if (saved) {
        gva_t list = state->scratch, flagSlot = state->scratch + 0x100;
        gva_t timestamp = state->scratch + 0x120;
        GuestWriteU32(vm, flagSlot, flags ? *flags : 0);
        AudioTimeStamp stamp = time ? *time : AudioTimeStamp{};
        GuestWrite(vm, timestamp, &stamp, sizeof(stamp));
        GuestWriteU32(vm, list, data->mNumberBuffers);
        size_t used = kAudioDataOffset;
        bool fits = true;
        for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
            const AudioBuffer &buffer = data->mBuffers[i];
            size_t bytes = buffer.mDataByteSize;
            if (!bytes && state->format.mBytesPerFrame)
                bytes = (size_t)frames * state->format.mBytesPerFrame;
            used = (used + 15) & ~(size_t)15;
            if (bytes > kAudioScratchSize - used) { fits = false; break; }
            GuestAudioBuffer guest = {buffer.mNumberChannels, (uint32_t)bytes,
                                      state->scratch + (uint32_t)used};
            GuestWrite(vm, list + 4 + i * sizeof(guest), &guest, sizeof(guest));
            if (buffer.mData && bytes) GuestWrite(vm, guest.data, buffer.mData, bytes);
            else if (bytes) GuestWrite(vm, guest.data, state->hostPCM.data() + used, bytes);
            used += bytes;
        }
        if (fits) {
            uint32_t args[6] = {state->refcon, flagSlot, timestamp, bus, frames, list};
            result = (OSStatus)GuestCall(vm, state->callback, args, 6, 10000000);
            if (result == noErr && GuestReadU32(vm, list) != data->mNumberBuffers)
                result = kAudioUnitErr_InvalidParameter;
            size_t hostOffset = kAudioDataOffset;
            if (result == noErr) for (UInt32 i = 0; i < data->mNumberBuffers; i++) {
                AudioBuffer &buffer = data->mBuffers[i];
                GuestAudioBuffer guest = {};
                GuestRead(vm, list + 4 + i * sizeof(guest), &guest, sizeof(guest));
                size_t capacity = buffer.mDataByteSize;
                if (!capacity && state->format.mBytesPerFrame)
                    capacity = (size_t)frames * state->format.mBytesPerFrame;
                hostOffset = (hostOffset + 15) & ~(size_t)15;
                if (guest.byteSize > capacity || hostOffset + capacity > state->hostPCM.size()) {
                    result = kAudioUnitErr_InvalidParameter; break;
                }
                void *out = buffer.mData ?: (void *)(state->hostPCM.data() + hostOffset);
                if (guest.byteSize && !GuestRead(vm, guest.data, out, guest.byteSize)) {
                    result = kAudioUnitErr_InvalidParameter; break;
                }
                buffer.mData = out;
                buffer.mDataByteSize = guest.byteSize;
                buffer.mNumberChannels = guest.channels;
                const uint8_t *pcm = static_cast<const uint8_t *>(out);
                if (std::any_of(pcm, pcm + guest.byteSize,
                                [](uint8_t byte) { return byte != 0; })) nonzeroBuffers++;
                hostOffset += capacity;
            }
            if (flags) *flags = GuestReadU32(vm, flagSlot);
        } else result = kAudioUnitErr_TooManyFramesToProcess;
        GuestCPURestore(vm, state->context);
    }
    const double sampleRate=state->format.mSampleRate;
    GuestUnlock(vm);
    const int endErrno=errno;
    const uint64_t elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now()-callbackStart).count();
    g_audioNanoseconds.fetch_add(elapsed,std::memory_order_relaxed);
    uint64_t maximum=g_audioMaxNanoseconds.load(std::memory_order_relaxed);
    // Statistics must never spin on the real-time thread. A competing writer
    // may win this sample; the observed maximum remains monotonic.
    if(maximum<elapsed)g_audioMaxNanoseconds.compare_exchange_strong(
        maximum,elapsed,std::memory_order_relaxed);
    if(frames && sampleRate>0 &&
       double(elapsed)>double(frames)*1e9/sampleRate)
        g_audioOverruns.fetch_add(1,std::memory_order_relaxed);
    g_audioCalls.fetch_add(1, std::memory_order_relaxed);
    if (result == noErr) {
        g_audioFrames.fetch_add(frames, std::memory_order_relaxed);
        g_audioNonzeroBuffers.fetch_add(nonzeroBuffers, std::memory_order_relaxed);
    } else g_audioErrors.fetch_add(1,std::memory_order_relaxed);
    errno=endErrno;
    return result == noErr ? noErr : AudioSilence(flags, data, result);
}

HLE_DEFINE(hle_AudioComponentFindNext) {
    auto fn = AudioHost<AudioComponent (*)(AudioComponent, const AudioComponentDescription *)>(
        "_AudioComponentFindNext");
    AudioComponentDescription description = {};
    gva_t previous = GuestArg(vm, 0), desc = GuestArg(vm, 1);
    if (!fn || !desc || !GuestRead(vm, desc, &description, sizeof(description))) {
        GuestSetRet(vm, 0); return;
    }
    AudioComponent result = fn((AudioComponent)HLEUnwrapOpaque(vm, previous), &description);
    GuestTrace(vm, @"[audio] component type=%#x subtype=%#x manufacturer=%#x -> %s",
               description.componentType, description.componentSubType,
               description.componentManufacturer, result ? "found" : "missing");
    gva_t handle = HLEWrapOpaque(vm, result);
    if (handle) g_audioComponents[handle] = description;
    GuestSetRet(vm, handle);
}
HLE_BIND("_AudioComponentFindNext", hle_AudioComponentFindNext)

HLE_DEFINE(hle_AudioComponentInstanceNew) {
    auto fn = AudioHost<OSStatus (*)(AudioComponent, AudioComponentInstance *)>("_AudioComponentInstanceNew");
    gva_t componentHandle = GuestArg(vm, 0);
    AudioComponent component = (AudioComponent)HLEUnwrapOpaque(vm, componentHandle);
    gva_t out = GuestArg(vm, 1);
    if (!fn || !component || !out) { AudioResult(vm, "instanceNew", kAudioUnitErr_InvalidParameter); return; }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    GuestTrace(vm, @"[audio] before native instance category=%@ mode=%@ options=%#lx",
               session.category, session.mode, (unsigned long)session.categoryOptions);
    AudioComponentInstance instance = nullptr;
    OSStatus status = fn(component, &instance);
    auto description = g_audioComponents.find(componentHandle);
    if (status == noErr && description != g_audioComponents.end() &&
        description->second.componentType == kAudioUnitType_Output &&
        description->second.componentSubType == kAudioUnitSubType_RemoteIO) {
        status = ConfigureOutputOnlyRemoteIO(instance);
        GuestTrace(vm, @"[audio] native RemoteIO input bus 1 disabled -> %d", (int)status);
        if (status != noErr) {
            auto dispose = AudioHost<OSStatus (*)(AudioComponentInstance)>("_AudioComponentInstanceDispose");
            if (dispose) dispose(instance);
            instance = nullptr;
        }
    }
    if (status == noErr) {
        auto state = std::make_shared<GuestAudioUnit>();
        state->vm = vm; state->unit = instance;
        state->scratch = GuestAlloc(vm, kAudioScratchSize);
        state->hostPCM.resize(kAudioScratchSize, 0);
        GuestExecutionResult saved = GuestCPUAllocate(vm, &state->context);
        if (!state->scratch || saved != GuestExecutionSuccess) {
            auto dispose = AudioHost<OSStatus (*)(AudioComponentInstance)>("_AudioComponentInstanceDispose");
            if (dispose) dispose(instance);
            status = kAudioUnitErr_FailedInitialization;
        } else {
            gva_t handle = HLEWrapOpaque(vm, instance);
            g_audioUnits[handle] = std::move(state);
            GuestWriteU32(vm, out, handle);
        }
    }
    AudioResult(vm, "instanceNew", status);
}
HLE_BIND("_AudioComponentInstanceNew", hle_AudioComponentInstanceNew)

static void AudioUnitOperation(GuestVM *vm, const char *symbol, bool disposing = false) {
    gva_t handle = GuestArg(vm, 0);
    auto found=g_audioUnits.find(handle);
    auto owner=found==g_audioUnits.end()?std::shared_ptr<GuestAudioUnit>{}:found->second;
    GuestAudioUnit *state=owner.get();
    const bool starting=std::strcmp(symbol,"_AudioOutputUnitStart")==0;
    const bool stopping=disposing||std::strcmp(symbol,"_AudioOutputUnitStop")==0||
        std::strcmp(symbol,"_AudioUnitUninitialize")==0;
    const bool wasActive=state&&state->active.load(std::memory_order_acquire);
    uint64_t controlToken=state?state->epoch.load(std::memory_order_acquire):0;
    if(state&&(starting||stopping)&&!state->retired.load(std::memory_order_acquire)){
        DisableBuffered(*state);
        controlToken=state->epoch.load(std::memory_order_acquire);
        state->active.store(starting,std::memory_order_release);
        state->producerFailed.store(false,std::memory_order_release);
        if(starting)RefreshBuffered(owner);
    }
    auto fn = AudioHost<OSStatus (*)(AudioUnit)>(symbol);
    const bool drained=!state||!stopping||DrainAudio(*state,controlToken);
    // Drain may release the VM to another control operation on this unit.
    // A newer Start/Stop/property epoch owns the state and host submission.
    if(state&&(starting||stopping)&&!AudioControlStillCurrent(*state,controlToken)){
        AudioResult(vm,symbol,kAudioUnitErr_CannotDoInCurrentContext);return;
    }
    OSStatus result=!drained?kAudioUnitErr_CannotDoInCurrentContext:state&&fn&&!state->retired.load(std::memory_order_acquire)?((starting&&state->producerFailed.load(std::memory_order_acquire))?
        kAudioUnitErr_FailedInitialization:fn(state->unit)):kAudioUnitErr_InvalidParameter;
    if(state&&(starting||stopping)&&result!=noErr&&!GuestHasStopRequest(vm)&&AudioControlStillCurrent(*state,controlToken)){
        state->active.store(wasActive,std::memory_order_release);RefreshBuffered(owner);
    }
    if (disposing && result == noErr) {
        state->retired.store(true,std::memory_order_release);
        g_audioUnits.erase(handle); // Worker owns state until it wakes and retires.
    }
    GuestTrace(vm, @"[audio] %s -> %d; callbacks=%llu frames=%llu busy=%llu nonzeroBuffers=%llu", symbol,
               (int)result, (unsigned long long)g_audioCalls.load(),
               (unsigned long long)g_audioFrames.load(), (unsigned long long)g_audioBusy.load(),
               (unsigned long long)g_audioNonzeroBuffers.load());
    GuestSetRet(vm, (uint32_t)result);
}
HLE_DEFINE(hle_AudioComponentInstanceDispose) { AudioUnitOperation(vm, "_AudioComponentInstanceDispose", true); }
HLE_BIND("_AudioComponentInstanceDispose", hle_AudioComponentInstanceDispose)
HLE_DEFINE(hle_AudioOutputUnitStart) { AudioUnitOperation(vm, "_AudioOutputUnitStart"); }
HLE_BIND("_AudioOutputUnitStart", hle_AudioOutputUnitStart)
HLE_DEFINE(hle_AudioOutputUnitStop) { AudioUnitOperation(vm, "_AudioOutputUnitStop"); }
HLE_BIND("_AudioOutputUnitStop", hle_AudioOutputUnitStop)
HLE_DEFINE(hle_AudioUnitInitialize) { AudioUnitOperation(vm, "_AudioUnitInitialize"); }
HLE_BIND("_AudioUnitInitialize", hle_AudioUnitInitialize)
HLE_DEFINE(hle_AudioUnitUninitialize) { AudioUnitOperation(vm, "_AudioUnitUninitialize"); }
HLE_BIND("_AudioUnitUninitialize", hle_AudioUnitUninitialize)

HLE_DEFINE(hle_AudioUnitSetProperty) {
    const gva_t handle=GuestArg(vm,0);
    auto found=g_audioUnits.find(handle);
    auto owner=found==g_audioUnits.end()?std::shared_ptr<GuestAudioUnit>{}:found->second;
    GuestAudioUnit *state=owner.get();
    AudioUnitPropertyID property = GuestArg(vm, 1);
    AudioUnitScope scope = GuestArg(vm, 2);
    AudioUnitElement element = GuestArg(vm, 3);
    gva_t data = GuestArg(vm, 4);
    uint32_t size = GuestArg(vm, 5);
    auto fn = AudioHost<OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                    AudioUnitElement, const void *, UInt32)>("_AudioUnitSetProperty");
    if (!state || !fn || !data||state->retired.load(std::memory_order_acquire)) { AudioResult(vm, "setProperty", kAudioUnitErr_InvalidParameter); return; }
    OSStatus status;
    if (property == kAudioUnitProperty_SetRenderCallback) {
        uint32_t guest[2] = {};
        if (size != sizeof(guest) || !GuestRead(vm, data, guest, sizeof(guest))) {
            AudioResult(vm, "setRenderCallback", kAudioUnitErr_InvalidParameter); return;
        }
        DisableBuffered(*state);
        const auto controlToken=state->epoch.load(std::memory_order_acquire);
        if(!DrainAudio(*state,controlToken)||!AudioControlStillCurrent(*state,controlToken)){
            AudioResult(vm,"setRenderCallback",kAudioUnitErr_CannotDoInCurrentContext);return;
        }
        AURenderCallbackStruct callback = {guest[0] ? AudioRender : nullptr, state};
        status = fn(state->unit, property, scope, element, &callback, sizeof(callback));
        if (status == noErr) { state->callback = guest[0]; state->refcon = guest[1];state->producerFailed.store(false,std::memory_order_release); }
        RefreshBuffered(owner);
        GuestTrace(vm, @"[audio] original render callback=%#x refcon=%#x", guest[0], guest[1]);
    } else if (property == kAudioUnitProperty_StreamFormat ||
               property == kAudioOutputUnitProperty_EnableIO ||
               property == kAudioUnitProperty_MaximumFramesPerSlice ||
               property == kAudioUnitProperty_ShouldAllocateBuffer) {
        std::vector<uint8_t> bytes(size, 0);
        if (!size || !GuestRead(vm, data, bytes.data(), size)) {
            AudioResult(vm, "setProperty", kAudioUnitErr_InvalidParameter); return;
        }
        if(property==kAudioUnitProperty_StreamFormat){
            DisableBuffered(*state);
            const auto controlToken=state->epoch.load(std::memory_order_acquire);
            if(!DrainAudio(*state,controlToken)||!AudioControlStillCurrent(*state,controlToken)){
                AudioResult(vm,"setStreamFormat",kAudioUnitErr_CannotDoInCurrentContext);return;
            }
        }
        status = fn(state->unit, property, scope, element, bytes.data(), size);
        if (property == kAudioOutputUnitProperty_EnableIO && size == sizeof(UInt32)) {
            UInt32 enabled = 0;
            memcpy(&enabled, bytes.data(), sizeof(enabled));
            GuestTrace(vm, @"[audio] original EnableIO scope=%u bus=%u enabled=%u -> %d",
                       scope, element, enabled, (int)status);
        }
        if (status == noErr && property == kAudioUnitProperty_StreamFormat &&
            size == sizeof(state->format)) {
            memcpy(&state->format, bytes.data(), size);
            state->producerFailed.store(false,std::memory_order_release);
            GuestTrace(vm, @"[audio] original PCM %.0fHz channels=%u bits=%u bytes/frame=%u",
                       state->format.mSampleRate, state->format.mChannelsPerFrame,
                       state->format.mBitsPerChannel, state->format.mBytesPerFrame);
        }
        if(property==kAudioUnitProperty_StreamFormat)RefreshBuffered(owner);
    } else status = kAudioUnitErr_InvalidProperty;
    GuestTrace(vm, @"[audio] property=%u scope=%u element=%u size=%u -> %d",
               property, scope, element, size, (int)status);
    GuestSetRet(vm, (uint32_t)status);
}
HLE_BIND("_AudioUnitSetProperty", hle_AudioUnitSetProperty)

// AudioSession was superseded by AVAudioSession in iOS 7. Preserve the exact
// properties used by this image ('acat', 'chsr', 'chbd', 'roch') through the
// current system session, including real route/interruption notifications.
struct GuestAudioListener {
    GuestVM *__unsafe_unretained vm = nil;
    uint32_t property = 0;
    gva_t callback = 0, refcon = 0;
};
static std::vector<GuestAudioListener> g_audioListeners;
static GuestAudioListener g_audioInterruption;
static id g_audioRouteObserver, g_audioInterruptionObserver;
static bool g_audioSessionInitialized = false;

static void AudioSessionGuestCall(const GuestAudioListener &listener,
                                   const uint32_t *args, int count) {
    if (!listener.vm || !listener.callback) return;
    GuestLock(listener.vm);
    GuestCpuSnapshot *context = nullptr;
    if (GuestCPUAllocate(listener.vm, &context) == GuestExecutionSuccess) {
        if (GuestCPUSave(listener.vm, context) == GuestExecutionSuccess) {
            GuestCall(listener.vm, listener.callback, args, count, 10000000);
            GuestCPURestore(listener.vm, context);
        }
        GuestCPUFree(context);
    }
    GuestUnlock(listener.vm);
}

static OSStatus SessionError(BOOL success, NSError *error) {
    return success ? noErr : (error ? (OSStatus)error.code : kAudioSessionUnspecifiedError);
}

static void EnsureAudioSessionNotifications(void) {
    if (!g_audioRouteObserver) {
        g_audioRouteObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
                NSDictionary *legacy = @{@"OutputDeviceDidChange_Reason": reason ?: @0};
                GuestVM *shared = GuestVMShared();
                if (!shared) return;
                GuestLock(shared);
                auto listeners = g_audioListeners;
                for (const GuestAudioListener &listener : listeners) {
                    if (listener.property != kAudioSessionProperty_AudioRouteChange) continue;
                    GuestLock(listener.vm);
                    // The original callback at 0x386c hands r3 directly to
                    // CFDictionaryGetValue: it expects the dictionary itself.
                    gva_t value = GuestObjCWrap(listener.vm, legacy);
                    uint32_t args[4] = {listener.refcon, listener.property, 4, value};
                    AudioSessionGuestCall(listener, args, 4);
                    GuestUnlock(listener.vm);
                }
                GuestUnlock(shared);
            }];
    }
    if (!g_audioInterruptionObserver) {
        g_audioInterruptionObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                GuestVM *shared = GuestVMShared();
                if (!shared) return;
                GuestLock(shared);
                GuestAudioListener listener = g_audioInterruption;
                NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                uint32_t args[2] = {listener.refcon, type == AVAudioSessionInterruptionTypeBegan ? 1u : 0u};
                AudioSessionGuestCall(listener, args, 2);
                GuestUnlock(shared);
            }];
    }
}

HLE_DEFINE(hle_AudioSessionInitialize) {
    EnsureAudioSessionNotifications();
    if (g_audioSessionInitialized) { AudioResult(vm, "sessionInitialize", kAudioSessionAlreadyInitialized); return; }
    if (![AVAudioSession sharedInstance] || !g_audioRouteObserver || !g_audioInterruptionObserver) {
        AudioResult(vm, "sessionInitialize", kAudioSessionInitializationError); return;
    }
    // This original always passes NULL for run loop and mode; notifications are
    // delivered on the main run loop, as AudioSessionInitialize specified.
    if (GuestArg(vm, 0) || GuestArg(vm, 1)) {
        AudioResult(vm, "sessionInitialize runloop", kAudioSessionInitializationError); return;
    }
    g_audioInterruption = {vm, 0, GuestArg(vm, 2), GuestArg(vm, 3)};
    g_audioSessionInitialized = true;
    AudioResult(vm, "sessionInitialize", noErr);
}
HLE_BIND("_AudioSessionInitialize", hle_AudioSessionInitialize)

HLE_DEFINE(hle_AudioSessionSetActive) {
    NSError *error = nil;
    BOOL ok = [[AVAudioSession sharedInstance] setActive:GuestArg(vm, 0) != 0 error:&error];
    AudioResult(vm, "sessionSetActive", SessionError(ok, error));
}
HLE_BIND("_AudioSessionSetActive", hle_AudioSessionSetActive)

static NSString *SessionCategory(uint32_t value) {
    switch (value) {
        case kAudioSessionCategory_AmbientSound: return AVAudioSessionCategoryAmbient;
        case kAudioSessionCategory_SoloAmbientSound: return AVAudioSessionCategorySoloAmbient;
        case kAudioSessionCategory_MediaPlayback: return AVAudioSessionCategoryPlayback;
        case kAudioSessionCategory_RecordAudio: return AVAudioSessionCategoryRecord;
        case kAudioSessionCategory_PlayAndRecord: return AVAudioSessionCategoryPlayAndRecord;
        case kAudioSessionCategory_AudioProcessing: return AVAudioSessionCategoryAudioProcessing;
        default: return nil;
    }
}

HLE_DEFINE(hle_AudioSessionSetProperty) {
    uint32_t property = GuestArg(vm, 0), size = GuestArg(vm, 1);
    gva_t data = GuestArg(vm, 2);
    NSError *error = nil;
    BOOL success = NO;
    if (property == kAudioSessionProperty_AudioCategory) {
        if (size != 4 || !data) { AudioResult(vm, "sessionCategory", kAudioSessionBadPropertySizeError); return; }
        uint32_t originalCategory = GuestReadU32(vm, data);
        NSString *category = SessionCategory(originalCategory);
        GuestTrace(vm, @"[audio] original category=%#x requested=%@ current=%@",
                   originalCategory, category, [AVAudioSession sharedInstance].category);
        if (!category) { AudioResult(vm, "sessionCategory", kAudioSessionUnsupportedPropertyError); return; }
        success = [[AVAudioSession sharedInstance] setCategory:category error:&error];
        GuestTrace(vm, @"[audio] category applied=%@ success=%d error=%@",
                   [AVAudioSession sharedInstance].category, (int)success, error);
    } else if (property == kAudioSessionProperty_PreferredHardwareSampleRate) {
        double rate = 0;
        if (size != 8 || !GuestRead(vm, data, &rate, 8)) { AudioResult(vm, "preferredRate", kAudioSessionBadPropertySizeError); return; }
        success = [[AVAudioSession sharedInstance] setPreferredSampleRate:rate error:&error];
    } else if (property == kAudioSessionProperty_PreferredHardwareIOBufferDuration) {
        float duration = 0;
        if (size != 4 || !GuestRead(vm, data, &duration, 4)) { AudioResult(vm, "preferredBuffer", kAudioSessionBadPropertySizeError); return; }
        success = [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:duration error:&error];
    } else { AudioResult(vm, "sessionSetProperty", kAudioSessionUnsupportedPropertyError); return; }
    AudioResult(vm, "sessionSetProperty", SessionError(success, error));
}
HLE_BIND("_AudioSessionSetProperty", hle_AudioSessionSetProperty)

HLE_DEFINE(hle_AudioSessionGetProperty) {
    uint32_t property = GuestArg(vm, 0);
    gva_t sizeOut = GuestArg(vm, 1), data = GuestArg(vm, 2);
    uint32_t capacity = GuestReadU32(vm, sizeOut);
    AVAudioSession *session = [AVAudioSession sharedInstance];
    double value64 = 0;
    float value32 = 0;
    uint32_t integer = 0, size = 0;
    const void *value = nullptr;
    switch (property) {
        case kAudioSessionProperty_CurrentHardwareSampleRate:
            value64 = session.sampleRate; size = 8; value = &value64; break;
        case kAudioSessionProperty_CurrentHardwareIOBufferDuration:
            value32 = (float)session.IOBufferDuration; size = 4; value = &value32; break;
        case kAudioSessionProperty_CurrentHardwareInputNumberChannels:
            integer = (uint32_t)session.inputNumberOfChannels; size = 4; value = &integer; break;
        case kAudioSessionProperty_CurrentHardwareOutputNumberChannels:
            integer = (uint32_t)session.outputNumberOfChannels; size = 4; value = &integer; break;
        case kAudioSessionProperty_OtherAudioIsPlaying:
            integer = session.otherAudioPlaying; size = 4; value = &integer; break;
        default: AudioResult(vm, "sessionGetProperty", kAudioSessionUnsupportedPropertyError); return;
    }
    if (!sizeOut || !data || capacity < size) {
        if (sizeOut) GuestWriteU32(vm, sizeOut, size);
        AudioResult(vm, "sessionGetProperty", kAudioSessionBadPropertySizeError); return;
    }
    GuestWrite(vm, data, value, size);
    GuestWriteU32(vm, sizeOut, size);
    AudioResult(vm, "sessionGetProperty", noErr);
}
HLE_BIND("_AudioSessionGetProperty", hle_AudioSessionGetProperty)

HLE_DEFINE(hle_AudioSessionAddPropertyListener) {
    uint32_t property = GuestArg(vm, 0);
    gva_t callback = GuestArg(vm, 1), refcon = GuestArg(vm, 2);
    if (property != kAudioSessionProperty_AudioRouteChange || !callback) {
        AudioResult(vm, "sessionAddListener", kAudioSessionUnsupportedPropertyError); return;
    }
    EnsureAudioSessionNotifications();
    auto found = std::find_if(g_audioListeners.begin(), g_audioListeners.end(),
        [&](const GuestAudioListener &listener) { return listener.vm == vm &&
            listener.property == property && listener.callback == callback && listener.refcon == refcon; });
    if (found == g_audioListeners.end()) g_audioListeners.push_back({vm, property, callback, refcon});
    AudioResult(vm, "sessionAddListener", noErr);
}
HLE_BIND("_AudioSessionAddPropertyListener", hle_AudioSessionAddPropertyListener)

HLE_DEFINE(hle_AudioSessionRemovePropertyListenerWithUserData) {
    uint32_t property = GuestArg(vm, 0);
    gva_t callback = GuestArg(vm, 1), refcon = GuestArg(vm, 2);
    g_audioListeners.erase(std::remove_if(g_audioListeners.begin(), g_audioListeners.end(),
        [&](const GuestAudioListener &listener) { return listener.vm == vm &&
            listener.property == property && listener.callback == callback && listener.refcon == refcon; }),
        g_audioListeners.end());
    AudioResult(vm, "sessionRemoveListener", noErr);
}
HLE_BIND("_AudioSessionRemovePropertyListenerWithUserData", hle_AudioSessionRemovePropertyListenerWithUserData)
