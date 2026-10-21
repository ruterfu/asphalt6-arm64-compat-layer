// Core Motion compatibility for the removed UIAccelerometer API. Original game
// IMPs still own filtering, orientation handling, calibration and steering.
#import "HLE_motion.h"
#import "GuestObjC.h"
#import "MotionInputState.hpp"
#import <CoreMotion/CoreMotion.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <TargetConditionals.h>
#include <cstring>

@interface AS6LegacyAcceleration : NSObject
@property(nonatomic,readonly) double x,y,z,timestamp;
@property(nonatomic,readonly) as6motion::Sample sample;
- (instancetype)initWithSample:(as6motion::Sample)sample;
@end
@implementation AS6LegacyAcceleration {
    as6motion::Sample _sample;
}
- (instancetype)initWithSample:(as6motion::Sample)sample {if((self=[super init]))_sample=sample;return self;}
- (double)x{return _sample.x;}
- (double)y{return _sample.y;}
- (double)z{return _sample.z;}
- (double)timestamp{return _sample.timestamp;}
- (as6motion::Sample)sample{return _sample;}
@end

@interface AS6LegacyAccelerometer : NSObject
@property(nonatomic,weak) id delegate;
@property(nonatomic) double updateInterval;
+ (instancetype)sharedAccelerometer;
- (void)attachVM:(GuestVM *)vm;
- (void)forgetVM:(GuestVM *)vm;
- (BOOL)isCurrent:(AS6LegacyAcceleration *)sample vm:(GuestVM *)vm;
+ (instancetype)existingAccelerometer;
- (NSDictionary *)snapshot;
@end
static AS6LegacyAccelerometer *g_motionAccelerometer;

@implementation AS6LegacyAccelerometer {
    as6motion::InputState _state;
    __weak GuestVM *_ownerVM;
    __weak id _delegate;
    CMMotionManager *_manager;
    NSOperationQueue *_samples;
    uint64_t _runningEpoch;
    BOOL _reportedUnavailable;
    BOOL _foregroundKnown;
    uint64_t _receivedSamples,_admittedCallbacks;
    double _lastX,_lastY,_lastZ,_lastTimestamp;
}
+ (instancetype)sharedAccelerometer {
    static dispatch_once_t once;
    dispatch_once(&once,^{AS6LegacyAccelerometer *created=[self new];@synchronized(self){g_motionAccelerometer=created;}});
    return g_motionAccelerometer;
}
+ (instancetype)existingAccelerometer {@synchronized(self){return g_motionAccelerometer;}}
- (instancetype)init {
    if((self=[super init])) {
        _manager=[CMMotionManager new];
        _samples=[NSOperationQueue new];_samples.maxConcurrentOperationCount=1;
        _samples.name=@"as6.motion.sensor";_samples.qualityOfService=NSQualityOfServiceUserInteractive;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(willPause:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(didResume:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self requestReconcile];
    }return self;
}
- (void)requestReconcile {
    __weak AS6LegacyAccelerometer *weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{[weakSelf reconcile];});
}
- (void)attachVM:(GuestVM *)vm {
    @synchronized(self) {
        if(_ownerVM!=vm){_ownerVM=vm;_delegate=nil;_state.attach((uintptr_t)(__bridge void *)vm);}
    }[self requestReconcile];
}
- (void)forgetVM:(GuestVM *)vm {
    @synchronized(self) {
        if(_ownerVM!=vm)return;
        _ownerVM=nil;_delegate=nil;_state.attach(0);
    }[self requestReconcile];
}
- (id)delegate { @synchronized(self){return _delegate;} }
- (void)setDelegate:(id)value {
    @synchronized(self){_delegate=value;_state.delegateChanged(value!=nil);}
    [self requestReconcile];
}
- (double)updateInterval { @synchronized(self){return _state.interval();} }
- (void)setUpdateInterval:(double)value {
    BOOL accepted;@synchronized(self){accepted=_state.interval(value);}
    if(accepted)[self requestReconcile];
}
- (void)willPause:(NSNotification *)note {
    @synchronized(self){_foregroundKnown=YES;_state.foreground(false);}
    [self requestReconcile];
}
- (void)didResume:(NSNotification *)note {
    @synchronized(self){_foregroundKnown=YES;_state.foreground(true);}
    [self requestReconcile];
}
- (void)reconcile {
    NSAssert(NSThread.isMainThread,@"Motion control must run on the main queue");
    bool enabled;double interval;uint64_t epoch;
    @synchronized(self) {
        if(!_foregroundKnown){_foregroundKnown=YES;_state.foreground(UIApplication.sharedApplication.applicationState==UIApplicationStateActive);}
        enabled=_state.running();interval=_state.interval();epoch=_state.epoch();
    }
    if(!enabled||!_manager.accelerometerAvailable) {
        [_manager stopAccelerometerUpdates];_runningEpoch=0;
        if(enabled&&!_reportedUnavailable){_reportedUnavailable=YES;GuestRawLog("[motion] accelerometer unavailable; no synthetic hardware samples supplied");}
        return;
    }
    if(_manager.accelerometerActive&&_runningEpoch==epoch)return;
    [_manager stopAccelerometerUpdates];_runningEpoch=epoch;
    _manager.accelerometerUpdateInterval=interval;
    __weak AS6LegacyAccelerometer *weakSelf=self;
    [_manager startAccelerometerUpdatesToQueue:_samples withHandler:^(CMAccelerometerData *data,NSError *error) {
        AS6LegacyAccelerometer *meter=weakSelf;
        if(!meter||!data||error)return;
        const CMAcceleration a=data.acceleration;
        if(!std::isfinite(a.x)||!std::isfinite(a.y)||!std::isfinite(a.z)||
           !std::isfinite(data.timestamp)||data.timestamp<0)return;
        BOOL queue;@synchronized(meter){++meter->_receivedSamples;meter->_lastX=a.x;meter->_lastY=a.y;meter->_lastZ=a.z;meter->_lastTimestamp=data.timestamp;queue=meter->_state.store(epoch,a.x,a.y,a.z,data.timestamp);}
        if(queue)dispatch_async(dispatch_get_main_queue(),^{[weakSelf drain:epoch];});
    }];
    GuestRawLog("[motion] native Core Motion accelerometer active; device axes, G units, uptime timestamp");
}
- (void)drain:(uint64_t)epoch {
    NSAssert(NSThread.isMainThread,@"Motion callbacks must run on the main queue");
    as6motion::Sample sample;id target;
    @synchronized(self) {
        target=_delegate;
        if(!target){_state.delegateChanged(false);[self requestReconcile];return;}
        if(!_state.take(epoch,sample))return;
    }
    SEL callback=sel_registerName("accelerometer:didAccelerate:");
    if(![target respondsToSelector:callback])return;
    AS6LegacyAcceleration *acceleration=[[AS6LegacyAcceleration alloc]initWithSample:sample];
    // No motion lock is held across the VM lock or a reentrant game callback.
    ((void(*)(id,SEL,id,id))objc_msgSend)(target,callback,self,acceleration);
}
- (BOOL)isCurrent:(AS6LegacyAcceleration *)acceleration vm:(GuestVM *)vm {
    @synchronized(self){BOOL current=_ownerVM==vm&&_state.current(acceleration.sample);if(current)++_admittedCallbacks;return current;}
}
- (NSDictionary *)snapshot {
    @synchronized(self){return @{@"backend":@"core-motion-accelerometer",@"simulator":@(TARGET_OS_SIMULATOR),
        @"hardware_available":@(_manager.accelerometerAvailable),@"registered":@(_delegate!=nil),
        @"requested_active":@(_state.running()),@"hardware_active":@(_manager.accelerometerActive),
        @"requested_interval_seconds":@(_state.interval()),@"hardware_samples":@(_receivedSamples),
        @"last_device_x_g":@(_lastX),@"last_device_y_g":@(_lastY),@"last_device_z_g":@(_lastZ),
        @"last_uptime_timestamp":@(_lastTimestamp),@"admitted_original_callbacks":@(_admittedCallbacks)};}
}
@end

Class GuestMotionSubstituteClass(const char *name) {
    if(!name)return Nil;
    if(!strcmp(name,"UIAccelerometer"))return [AS6LegacyAccelerometer class];
    if(!strcmp(name,"UIAcceleration"))return [AS6LegacyAcceleration class];
    return Nil;
}
BOOL GuestMotionOverride(GuestVM *vm,id target,SEL selector) {
    if(strcmp(sel_getName(selector),"sharedAccelerometer"))return NO;
    // Cover both static class bindings and a still-present native legacy class
    // returned by a dynamic lookup. Presence alone does not prove live sampling.
    Class legacy=objc_lookUpClass("UIAccelerometer");
    if(target!=(id)[AS6LegacyAccelerometer class]&&(!legacy||target!=(id)legacy))return NO;
    AS6LegacyAccelerometer *meter=[AS6LegacyAccelerometer sharedAccelerometer];
    [meter attachVM:vm];GuestSetRet(vm,GuestObjCWrap(vm,meter));return YES;
}
BOOL GuestMotionCallbackIsCurrent(GuestVM *vm,id meter,id acceleration) {
    if(![meter isKindOfClass:[AS6LegacyAccelerometer class]])return YES;
    if(GuestHasStopRequest(vm)){[(AS6LegacyAccelerometer *)meter forgetVM:vm];return NO;}
    return [acceleration isKindOfClass:[AS6LegacyAcceleration class]]&&
        [(AS6LegacyAccelerometer *)meter isCurrent:acceleration vm:vm];
}
void GuestMotionForgetVM(GuestVM *vm) {[[AS6LegacyAccelerometer existingAccelerometer]forgetVM:vm];}
NSDictionary *GuestMotionPerformanceSnapshot(void) {
    return [[AS6LegacyAccelerometer existingAccelerometer]snapshot]?:@{@"backend":@"core-motion-accelerometer",@"registered":@NO,@"hardware_samples":@0,@"admitted_original_callbacks":@0};
}
