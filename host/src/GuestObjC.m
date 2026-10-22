// Objective-C bridge.
//
// The original binary uses the non-fragile (objc2) class layout even though it
// is 32-bit: class_t{isa,superclass,cache,vtable,data} with class_ro_t
// {flags,instanceStart,instanceSize,ivarLayout,name,baseMethods,...}. Guest
// selectors are pointers to their name C-string in __TEXT,__cstring, which is
// exactly what objc_msgSend receives, so a selector crosses the boundary by
// name and a host object crosses as a tagged 32-bit handle.

#import "GuestObjC.h"
#import "ResourcePaths.h"
#include "GuestLocalClassRegistry.hpp"
#include "GuestObjCMetadata.hpp"
#import "HLE_media.h"
#include "GameplayBacking25x.hpp"
#include "SharedMenuTextureWarm.hpp"

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <string.h>
#import <string>
#import <unordered_map>
#import <vector>

#import "GuestVM.h"
#import "HLE_motion.h"
#import "HLE.h"
extern "C" BOOL GuestLoaderDeclaredSection(GuestVM *,const char *,uint32_t *,uint32_t *);

extern NSString *GuestFormatCall(GuestVM *vm, NSString *fmt, int firstVarArg, gva_t vaList);

// --- registries ------------------------------------------------------------

struct LocalRegistryState {
    std::unordered_map<uint32_t,std::string> classNames,metaNames;
    std::unordered_map<std::string,uint32_t> nameToClass;
    std::vector<std::pair<uint32_t,uint32_t>> classMethodLists;
};
static std::unordered_map<std::uintptr_t,LocalRegistryState> localRegistries;
static LocalRegistryState &LocalRegistry(GuestVM *vm) {
    return localRegistries[reinterpret_cast<std::uintptr_t>((__bridge void *)vm)];
}
// The handle table deliberately holds bare pointers: ARC would retain every
// wrapped object, and Foundation throws
// "*** -[NSAutoreleasePool retain]: Cannot retain an autorelease pool" the
// moment the original main() creates its pool.  Ownership is taken explicitly
// below for the objects that are legal to retain.
static std::unordered_map<uint32_t, __unsafe_unretained id> g_objects;
static std::unordered_map<void *, uint32_t> g_objectHandles;
static BOOL GuestClassImplements(GuestVM *vm, gva_t guestClass, const char *name);

// The original main() opens an NSAutoreleasePool.  Foundation objects of that
// class abort on objc_retain, which every ARC hop in this bridge performs, so
// the guest is handed a behaviour-compatible stand-in instead.  The host main
// thread already owns a real pool, so the guest's pool only ever needs to
// tolerate retain/release/drain.
@interface PortAutoreleasePool : NSObject
- (void)drain;
@end
@implementation PortAutoreleasePool
// Reference counting stays with ARC: the bridge retains the handle once and
// the guest's single -release balances it.  Only -drain has to be absorbed.
- (void)drain {}
@end
static std::unordered_map<uint32_t, Class> g_classes;

// --- host shadows for guest UIView subclasses -------------------------------
// The original's view classes are instantiated in emulated memory, so they have
// no CALayer, no geometry and nothing for UIKit to composite.  Each one gets a
// real arm64 view of the same shape; selectors the 2011 class does not
// implement itself are answered by the shadow.  EAGLView asks for a
// CAEAGLLayer through +layerClass, and that is exactly how it is detected.
// Isolated candidate: bridge real native touch edges across original frames.
// Never calls drawView itself, writes game state, or creates a UITouch.
@interface PortNativeTouchSample : NSObject
@property(nonatomic, strong) UITouch *touch;
@property(nonatomic, weak) UIView *view;
@property(nonatomic) CGPoint location, previous, windowLocation, previousWindow;
@property(nonatomic) NSTimeInterval timestamp;
@property(nonatomic) NSUInteger tapCount;
@property(nonatomic) UITouchPhase phase;
@end
@implementation PortNativeTouchSample
@end

typedef NS_ENUM(NSUInteger, PortNativeTouchKind) { PortTouchBegin, PortTouchMove, PortTouchEnd, PortTouchCancel };
@interface PortNativeTouchBatch : NSObject
@property(nonatomic, copy) NSSet<UITouch *> *touches;
@property(nonatomic, strong) UIEvent *event;
@property(nonatomic, copy) NSArray<PortNativeTouchSample *> *samples;
@property(nonatomic) PortNativeTouchKind kind;
@property(nonatomic) CFTimeInterval arrival;
@property(nonatomic) uint64_t diagnosticSequence;
@property(nonatomic) BOOL diagnosedHold;
@end
@implementation PortNativeTouchBatch
@end
// The batch owns the objects throughout the synchronous guest call. Nested
// guest/native callbacks restore the previous snapshot scope on return.
static thread_local __unsafe_unretained NSArray<PortNativeTouchSample *> *g_nativeTouchSamples;
static const char *PortTouchSelector(PortNativeTouchKind kind) {
    switch (kind) {
        case PortTouchBegin: return "touchesBegan:withEvent:";
        case PortTouchMove: return "touchesMoved:withEvent:";
        case PortTouchEnd: return "touchesEnded:withEvent:";
        case PortTouchCancel: return "touchesCancelled:withEvent:";
    }
    return "touchesCancelled:withEvent:";
}
static NSValue *PortTouchKey(UITouch *touch) { return [NSValue valueWithPointer:(__bridge void *)touch]; }

@interface PortGuestView : UIView
@property(nonatomic) gva_t guestAddress;
@property(nonatomic, strong) NSMutableArray<UIView *> *presentationControls;
@property(nonatomic, strong) NSMutableArray<PortNativeTouchBatch *> *nativeTouchQueue;
@property(nonatomic, strong) NSMutableDictionary<NSValue *, NSNumber *> *nativeBeginEpoch;
@property(nonatomic) uint64_t nativeFrameEpoch, nativeNextBeginEpoch;
@property(nonatomic) BOOL nativeFlushing;
@property(nonatomic) NSUInteger nativeTraceCount;
@property(nonatomic) NSUInteger nativeDispatchTraceCount,nativeFrameTraceCount;
@property(nonatomic) uint64_t nativeBatchSequence;
- (void)completeNativeInputFrame;
@end
@implementation PortGuestView
- (void)resetNativeInput {
    [self.nativeTouchQueue removeAllObjects];
    // UIKit may deliver the real Cancel after removal starts. Keep only the
    // ledger of already forwarded Begins so that release is not lost. Queued
    // contacts never entered guest code and need no fabricated terminal edge.
    if (!self.nativeBeginEpoch.count) {
        self.nativeFrameEpoch = 0; self.nativeNextBeginEpoch = 0;
    }
}
- (void)removeFromSuperview {
    [self resetNativeInput];
    for (UIView *control in self.presentationControls) [control removeFromSuperview];
    self.presentationControls = nil;
    [super removeFromSuperview];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self resetNativeInput];
}
- (void)forwardTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event selector:(const char *)name {
    GuestVM *vm = GuestVMShared();
    if (!vm || !self.guestAddress) return;
    GuestLock(vm);
    @try {
        if (!GuestClassImplements(vm, GuestReadU32(vm, self.guestAddress), name)) return;
        gva_t selector = GuestObjCGuestSelNamed(vm, name);
        GuestSetReg(vm, 0, self.guestAddress); GuestSetReg(vm, 1, selector);
        GuestSetReg(vm, 2, GuestObjCWrap(vm, touches)); GuestSetReg(vm, 3, GuestObjCWrap(vm, event));
        GuestObjCSend(vm, self.guestAddress, selector, NO);
    } @finally { GuestUnlock(vm); }
}
- (PortNativeTouchBatch *)captureTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event kind:(PortNativeTouchKind)kind {
    PortNativeTouchBatch *batch = [PortNativeTouchBatch new];
    batch.touches = touches; batch.event = event; batch.kind = kind; batch.arrival = CACurrentMediaTime();
    batch.diagnosticSequence=++self.nativeBatchSequence;
    NSMutableArray *samples = [NSMutableArray arrayWithCapacity:touches.count];
    for (UITouch *touch in touches) {
        PortNativeTouchSample *sample = [PortNativeTouchSample new];
        sample.touch = touch; sample.view = self;
        sample.location = [touch locationInView:self]; sample.previous = [touch previousLocationInView:self];
        sample.windowLocation = [touch locationInView:nil]; sample.previousWindow = [touch previousLocationInView:nil];
        sample.timestamp = touch.timestamp; sample.tapCount = touch.tapCount; sample.phase = touch.phase;
        [samples addObject:sample];
    }
    batch.samples = samples;
    if (self.nativeTraceCount++ < 96) {
        PortNativeTouchSample *sample = batch.samples.firstObject;
        GuestTrace(GuestVMShared(),@"[input-native] %s batch=%llu touches=%lu touch=%p phase=%lu timestamp=%.6f arrival=%.6f frame=%llu queued=%lu local=(%.3f,%.3f) window=(%.3f,%.3f)",
                   PortTouchSelector(kind),(unsigned long long)batch.diagnosticSequence,
                   (unsigned long)touches.count,(__bridge void *)sample.touch,(unsigned long)sample.phase,
                   sample.timestamp,batch.arrival,(unsigned long long)self.nativeFrameEpoch,
                   (unsigned long)self.nativeTouchQueue.count,sample.location.x,sample.location.y,
                   sample.windowLocation.x,sample.windowLocation.y);
    }
    return batch;
}
- (BOOL)canDeliverNativeBatch:(PortNativeTouchBatch *)batch {
    if (batch.kind == PortTouchBegin) return self.nativeFrameEpoch >= self.nativeNextBeginEpoch;
    if (batch.kind == PortTouchEnd) {
        for (UITouch *touch in batch.touches) {
            NSNumber *begin = self.nativeBeginEpoch[PortTouchKey(touch)];
            if (begin && self.nativeFrameEpoch <= begin.unsignedLongLongValue) return NO;
        }
    }
    return YES;
}
- (void)deliverNativeBatch:(PortNativeTouchBatch *)batch {
    if(self.nativeDispatchTraceCount++<96){
        PortNativeTouchSample *sample=batch.samples.firstObject;
        NSNumber *begin=sample?self.nativeBeginEpoch[PortTouchKey(sample.touch)]:nil;
        GuestTrace(GuestVMShared(),@"[input-native-deliver] %s batch=%llu frame=%llu begin_known=%d begin_epoch=%llu next_begin=%llu phase=%lu timestamp=%.6f wait=%.6f window=%d queued=%lu local=(%.3f,%.3f)",
            PortTouchSelector(batch.kind),(unsigned long long)batch.diagnosticSequence,
            (unsigned long long)self.nativeFrameEpoch,begin!=nil,begin.unsignedLongLongValue,
            (unsigned long long)self.nativeNextBeginEpoch,(unsigned long)sample.phase,sample.timestamp,
            CACurrentMediaTime()-batch.arrival,self.window!=nil,(unsigned long)self.nativeTouchQueue.count,
            sample.location.x,sample.location.y);
    }
    // Update bookkeeping before guest code; removing the view during that call
    // must clear all pending state instead of having it recreated afterwards.
    if (batch.kind == PortTouchBegin) {
        for (UITouch *touch in batch.touches) self.nativeBeginEpoch[PortTouchKey(touch)] = @(self.nativeFrameEpoch);
    } else if (batch.kind == PortTouchEnd || batch.kind == PortTouchCancel) {
        for (UITouch *touch in batch.touches) [self.nativeBeginEpoch removeObjectForKey:PortTouchKey(touch)];
        self.nativeNextBeginEpoch = MAX(self.nativeNextBeginEpoch, self.nativeFrameEpoch + 1);
    }
    NSArray *previous = g_nativeTouchSamples;
    g_nativeTouchSamples = batch.samples;
    @try { [self forwardTouches:batch.touches event:batch.event selector:PortTouchSelector(batch.kind)]; }
    @finally { g_nativeTouchSamples = previous; }
}
- (void)drainNativeTouchQueue {
    if (self.nativeFlushing) return;
    self.nativeFlushing = YES;
    @try {
        while (self.nativeTouchQueue.count) {
            PortNativeTouchBatch *batch = self.nativeTouchQueue.firstObject;
            if (![self canDeliverNativeBatch:batch]) {
                if(!batch.diagnosedHold&&self.nativeDispatchTraceCount<96){
                    batch.diagnosedHold=YES;
                    PortNativeTouchSample *sample=batch.samples.firstObject;
                    NSNumber *begin=sample?self.nativeBeginEpoch[PortTouchKey(sample.touch)]:nil;
                    GuestTrace(GuestVMShared(),@"[input-native-hold] %s batch=%llu frame=%llu begin_known=%d begin_epoch=%llu next_begin=%llu window=%d queued=%lu",
                        PortTouchSelector(batch.kind),(unsigned long long)batch.diagnosticSequence,
                        (unsigned long long)self.nativeFrameEpoch,begin!=nil,begin.unsignedLongLongValue,
                        (unsigned long long)self.nativeNextBeginEpoch,self.window!=nil,(unsigned long)self.nativeTouchQueue.count);
                }
                break;
            }
            [self.nativeTouchQueue removeObjectAtIndex:0];
            [self deliverNativeBatch:batch];
        }
    } @finally { self.nativeFlushing = NO; }
}
- (void)removeQueuedNativeTouches:(NSSet<UITouch *> *)cancelled {
    NSMutableArray *remaining = [NSMutableArray array];
    for (PortNativeTouchBatch *batch in self.nativeTouchQueue) {
        NSMutableSet *touches = [batch.touches mutableCopy]; [touches minusSet:cancelled];
        if (!touches.count) continue;
        if (touches.count == batch.touches.count) { [remaining addObject:batch]; continue; }
        PortNativeTouchBatch *filtered = [PortNativeTouchBatch new];
        filtered.kind = batch.kind; filtered.event = batch.event; filtered.arrival = batch.arrival; filtered.touches = touches;
        filtered.diagnosticSequence=batch.diagnosticSequence;filtered.diagnosedHold=batch.diagnosedHold;
        NSMutableArray *samples = [NSMutableArray array];
        for (PortNativeTouchSample *sample in batch.samples) if ([touches containsObject:sample.touch]) [samples addObject:sample];
        filtered.samples = samples; [remaining addObject:filtered];
    }
    self.nativeTouchQueue = remaining;
}
- (PortNativeTouchBatch *)activeSubsetOfNativeBatch:(PortNativeTouchBatch *)batch {
    NSMutableSet *touches = [NSMutableSet set]; NSMutableArray *samples = [NSMutableArray array];
    for (PortNativeTouchSample *sample in batch.samples) {
        if (self.nativeBeginEpoch[PortTouchKey(sample.touch)]) {
            [touches addObject:sample.touch]; [samples addObject:sample];
        }
    }
    if (!touches.count) return nil;
    if (touches.count == batch.touches.count) return batch;
    PortNativeTouchBatch *filtered = [PortNativeTouchBatch new];
    filtered.kind = batch.kind; filtered.event = batch.event; filtered.arrival = batch.arrival;
    filtered.diagnosticSequence=batch.diagnosticSequence;filtered.diagnosedHold=batch.diagnosedHold;
    filtered.touches = touches; filtered.samples = samples; return filtered;
}
- (void)receiveNativeTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event kind:(PortNativeTouchKind)kind {
    if (!touches.count) return;
    // Only the original game surface needs sampled-edge pacing. Other original
    // native views and UIControl actions retain their existing UIKit path.
    if (self.guestAddress != GuestGLView()) {
        [self forwardTouches:touches event:event selector:PortTouchSelector(kind)]; return;
    }
    if (!self.nativeTouchQueue) self.nativeTouchQueue = [NSMutableArray array];
    if (!self.nativeBeginEpoch) self.nativeBeginEpoch = [NSMutableDictionary dictionary];
    PortNativeTouchBatch *batch = [self captureTouches:touches event:event kind:kind];
    if (kind == PortTouchCancel) {
        [self removeQueuedNativeTouches:touches];
        PortNativeTouchBatch *active = [self activeSubsetOfNativeBatch:batch];
        if (active) [self deliverNativeBatch:active];
        if (!self.window) [self resetNativeInput];
        return;
    }
    if (!self.window) {
        if (kind == PortTouchEnd) {
            PortNativeTouchBatch *active = [self activeSubsetOfNativeBatch:batch];
            if (active) [self deliverNativeBatch:active];
        }
        [self resetNativeInput]; return;
    }
    if (self.nativeTouchQueue.count >= 1024) {
        GuestTrace(GuestVMShared(), @"[input-native] pending input exceeded1024 batches without consumption; halting guest");
        [self resetNativeInput]; GuestRequestFault(GuestVMShared()); return;
    }
    [self.nativeTouchQueue addObject:batch]; [self drainNativeTouchQueue];
}
- (void)completeNativeInputFrame {
    if (!self.window || self.guestAddress != GuestGLView()) return;
    if((self.nativeTouchQueue.count||self.nativeBeginEpoch.count)&&self.nativeFrameTraceCount++<32)
        GuestTrace(GuestVMShared(),@"[input-native-frame] complete=%llu next=%llu queued=%lu active=%lu",
            (unsigned long long)self.nativeFrameEpoch,(unsigned long long)(self.nativeFrameEpoch+1),
            (unsigned long)self.nativeTouchQueue.count,(unsigned long)self.nativeBeginEpoch.count);
    ++self.nativeFrameEpoch; [self drainNativeTouchQueue];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self receiveNativeTouches:touches event:event kind:PortTouchBegin]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self receiveNativeTouches:touches event:event kind:PortTouchMove]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self receiveNativeTouches:touches event:event kind:PortTouchEnd]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self receiveNativeTouches:touches event:event kind:PortTouchCancel]; }
@end

extern "C" void GuestHostFrameDidComplete(GuestVM *);
void GuestNativeFrameDidComplete(GuestVM *vm, gva_t address) {
    if (!vm || address != GuestGLView() || ![NSThread isMainThread]) return;
    UIView *view = GuestObjCShadow(vm, address);
    if ([view isKindOfClass:[PortGuestView class]]) [(PortGuestView *)view completeNativeInputFrame];
    GuestHostFrameDidComplete(vm);
}

// Answer only queries on a real UITouch from the currently forwarded native
// batch. Identity stays the native UITouch handle used by the original code.
static BOOL HostNativeTouchSnapshotReturn(GuestVM *vm, id target, SEL selector, BOOL stret) {
    if (!g_nativeTouchSamples.count) return NO;
    PortNativeTouchSample *found = nil;
    for (PortNativeTouchSample *sample in g_nativeTouchSamples) if (sample.touch == target) { found = sample; break; }
    if (!found) return NO;
    const char *name = sel_getName(selector);
    BOOL current = !strcmp(name, "locationInView:"), previous = !strcmp(name, "previousLocationInView:");
    if (current || previous) {
        gva_t destination = GuestStretDestination();
        if (!stret || !destination) return NO;
        gva_t guestView = GuestArg(vm, 2);
        UIView *view = guestView ? GuestObjCShadow(vm, guestView) : nil;
        if (guestView && view != found.view) return NO; // Original EAGLView asks for itself.
        CGPoint point = view ? (previous ? found.previous : found.location)
                             : (previous ? found.previousWindow : found.windowLocation);
        float guestPoint[2] = {(float)point.x, (float)point.y};
        const BOOL written=GuestWrite(vm,destination,guestPoint,sizeof(guestPoint));
        if(!written)GuestRequestFault(vm);
        static unsigned pointTraceCount;
        if(pointTraceCount++<96)GuestTrace(vm,@"[input-native-point] selector=%s phase=%lu timestamp=%.6f view=%#x destination=%#x point=(%.6f,%.6f) wrote=%d",
            name,(unsigned long)found.phase,found.timestamp,guestView,destination,(double)guestPoint[0],(double)guestPoint[1],written);
        return YES;
    }
    if (!strcmp(name, "timestamp")) { GuestSetRetD(vm, found.timestamp); return YES; }
    if (!strcmp(name, "tapCount")) { GuestSetRet(vm, (uint32_t)found.tapCount); return YES; }
    if (!strcmp(name, "phase")) { GuestSetRet(vm, (uint32_t)found.phase); return YES; }
    return NO;
}


@interface PortGLView : PortGuestView <UITextFieldDelegate>
@end
@implementation PortGLView
+ (Class)layerClass { return objc_getClass("CAEAGLLayer") ?: [CALayer class]; }
// The original EAGLView is the delegate of the game's text field (name entry).
// The original places it in portrait 320x480 coordinates turned 90 degrees
// inside the (itself rotated) game view; on the landscape host that lands off
// screen or sideways, so while editing it is moved onto the window, upright
// and centred above the keyboard. The game reaches the field by reference. Return is passed on to the original
// textFieldShouldReturn:, which resigns the field so the game reads the text.
- (void)textFieldDidBeginEditing:(UITextField *)textField {
    UIView *superview = textField.superview;
    UIWindow *window = textField.window ?: self.window;
    NSLog(@"[uikit] text field begin hidden=%d frame=%@ superview=%@ window=%@",
          textField.hidden, NSStringFromCGRect(textField.frame), NSStringFromClass([superview class]),
          NSStringFromCGRect(window.bounds));
    if (!window) return;
    const CGRect bounds = window.bounds;
    const CGFloat width = MIN(bounds.size.width * 0.5, 420), height = 44;
    if (textField.superview != window) [window addSubview:textField];
    textField.transform = CGAffineTransformIdentity;
    textField.frame = CGRectMake((bounds.size.width - width) * 0.5, bounds.size.height * 0.12, width, height);
    textField.hidden = NO;
    [window bringSubviewToFront:textField];
    // Moving a first responder to another superview may resign it.
    if (!textField.isFirstResponder) [textField becomeFirstResponder];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    GuestVM *vm = GuestVMShared();
    if (!vm || !self.guestAddress) return YES;
    GuestLock(vm);
    BOOL result = YES;
    @try {
        const gva_t sel = GuestObjCGuestSelNamed(vm, "textFieldShouldReturn:");
        if (!sel) return YES;
        GuestSetReg(vm, 0, self.guestAddress);
        GuestSetReg(vm, 1, sel);
        GuestSetReg(vm, 2, GuestObjCWrap(vm, textField));
        GuestTrace(vm, @"[uikit] text field return -> guest %#x", self.guestAddress);
        if (GuestObjCSend(vm, self.guestAddress, sel, NO)) result = (GuestReg(vm, 0) & 0xff) != 0;
    } @finally { GuestUnlock(vm); }
    return result;
}
@end

@interface PortGuestActionTarget : NSObject
@property(nonatomic) gva_t guestTarget;
@property(nonatomic) gva_t guestSelector;
@property(nonatomic, weak) UIControl *control;
- (void)fire:(id)sender forEvent:(UIEvent *)event;
@end
@implementation PortGuestActionTarget
- (void)fire:(id)sender forEvent:(UIEvent *)event {
    GuestVM *vm = GuestVMShared();
    if (!vm) return;
    GuestLock(vm);
    @try {
        GuestSetReg(vm, 0, self.guestTarget);
        GuestSetReg(vm, 1, self.guestSelector);
        const gva_t guestSender=GuestObjCWrap(vm,sender);
        GuestSetReg(vm, 2, guestSender);
        GuestSetReg(vm, 3, GuestObjCWrap(vm, event));
        const SEL nativeAction=GuestObjCSelFromGuest(vm,self.guestSelector);
        GuestTrace(vm,@"[uikit] native action fired %@ -> guest %#x sender=%#x",
                   nativeAction?NSStringFromSelector(nativeAction):@"<unresolved>",self.guestTarget,guestSender);
        GuestObjCSend(vm, self.guestTarget, self.guestSelector, NO);
    } @finally { GuestUnlock(vm); }
}
@end
static NSMutableArray<PortGuestActionTarget *> *g_actionTargets;

void GuestPlaceOriginalSkipControls(GuestVM *vm, gva_t guestView, id windowObject) {
    if (![windowObject isKindOfClass:[UIWindow class]]) return;
    UIWindow *window = windowObject;
    PortGuestView *view = (PortGuestView *)GuestObjCShadow(vm, guestView);
    if (!view) return;
    for (PortGuestActionTarget *target in g_actionTargets) {
        if (target.guestTarget != guestView ||
            strcmp(sel_getName(GuestObjCSelFromGuest(vm, target.guestSelector)),
                   "BtnTapped_Skip:event:")) continue;
        if (![target.control isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)target.control;
        // Keep the two original orientation-specific controls and all original
        // visibility/fade/enable messages. Only adapt the requested caption and
        // physical placement; their action still enters the original IMP.
        [button setTitle:@"▶▶" forState:UIControlStateNormal];
        [button setTitle:@"▶▶" forState:UIControlStateHighlighted];
        button.transform = CGAffineTransformIdentity;
        UIEdgeInsets safe = window.safeAreaInsets;
        button.frame = CGRectMake(window.bounds.size.width - safe.right - 72,
                                   safe.top + 10, 56, 44);
        button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                  UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:button];
        if (!view.presentationControls) view.presentationControls = [NSMutableArray array];
        if (![view.presentationControls containsObject:button]) [view.presentationControls addObject:button];
        GuestTrace(vm, @"[uikit] original skip control ▶▶ adapted to top-right %@", NSStringFromCGRect(button.frame));
    }
}

// Observe only UIKit's real recipient, without another hitTest or new handles
// (wrapping a previously unseen UIKit object would change its lifetime).
static gva_t SkipTouchViewIdentity(UIView *view) {
    if ([view isKindOfClass:[PortGuestView class]]) return ((PortGuestView *)view).guestAddress;
    auto found = g_objectHandles.find((__bridge void *)view);
    return found == g_objectHandles.end() ? 0 : found->second;
}

extern "C" uint32_t GuestTraceNativeSkipTouches(UIWindow *window, UIEvent *event,
                                                uint32_t phases, BOOL after) {
    GuestVM *vm = GuestVMShared();
    if (!vm || event.type != UIEventTypeTouches || ![NSThread isMainThread]) return 0;
    static NSUInteger begins = 0, ends = 0;
    if (!after && (!g_actionTargets.count || (begins >= 8 && ends >= 8))) return 0;
    // Diagnostics must never stall touch dispatch behind a guest worker.
    if (!GuestTryLock(vm)) return 0;
    @try {
        NSMutableArray<PortGuestActionTarget *> *matches = [NSMutableArray array];
        BOOL associatedVisibleView = NO;
        for (PortGuestActionTarget *target in g_actionTargets) {
            UIControl *control = target.control;
            UIView *original = GuestObjCShadow(vm, target.guestTarget);
            if (!control || ![original isKindOfClass:[PortGuestView class]] ||
                ![((PortGuestView *)original).presentationControls containsObject:control]) continue;
            [matches addObject:target];
            if (control.window == window && original.window == window &&
                !original.hidden && original.alpha > 0.01) associatedVisibleView = YES;
        }
        if (!after) {
            if (!associatedVisibleView) return 0;
            for (UITouch *touch in event.allTouches) {
                if (touch.window != window) continue;
                if (touch.phase == UITouchPhaseBegan && !(phases & 1) && begins < 8) {
                    phases |= 1; ++begins;
                } else if (touch.phase == UITouchPhaseEnded && !(phases & 2) && ends < 8) {
                    phases |= 2; ++ends;
                }
            }
        }
        for (uint32_t bit = 1; bit <= 2; bit <<= 1) {
            if (!(phases & bit)) continue;
            UITouch *sample = nil;
            for (UITouch *touch in event.allTouches) {
                if (touch.window == window && touch.phase ==
                    (bit == 1 ? UITouchPhaseBegan : UITouchPhaseEnded)) { sample = touch; break; }
            }
            if (!sample) continue;
            UIView *recipient = sample.view;
            CGPoint point = [sample locationInView:window];
            NSMutableArray<NSString *> *ancestors = [NSMutableArray array];
            for (UIView *view = recipient; view && ancestors.count < 5; view = view.superview)
                [ancestors addObject:[NSString stringWithFormat:@"%@:%#x(h=%d a=%.3f u=%d)",
                    NSStringFromClass(view.class), SkipTouchViewIdentity(view), view.hidden,
                    (double)view.alpha, view.userInteractionEnabled]];
            GuestTrace(vm, @"[skip-touch] %s %s window=(%.2f,%.2f) recipient=%@:%#x chain=%@ controls=%lu",
                       after ? "after" : "before", bit == 1 ? "begin" : "end", point.x, point.y,
                       recipient ? NSStringFromClass(recipient.class) : @"nil", SkipTouchViewIdentity(recipient),
                       [ancestors componentsJoinedByString:@"/"], (unsigned long)matches.count);
            for (PortGuestActionTarget *target in matches) {
                UIControl *control = target.control;
                UIView *original = GuestObjCShadow(vm, target.guestTarget);
                UIView *parent = control.superview;
                NSUInteger order = parent ? [parent.subviews indexOfObjectIdenticalTo:control] : NSNotFound;
                CGPoint local = [sample locationInView:control];
                GuestTrace(vm, @"[skip-control] %s %s control=%#x target=%#x hit=%d inside_bounds=%d local=(%.2f,%.2f) "
                              "frame=%@ hidden=%d alpha=%.3f enabled=%d interaction=%d same_window=%d "
                              "parent=%@:%#x order=%lld original_hidden=%d original_alpha=%.3f original_interaction=%d",
                           after ? "after" : "before", bit == 1 ? "begin" : "end", SkipTouchViewIdentity(control),
                           target.guestTarget, recipient == control || [recipient isDescendantOfView:control],
                           CGRectContainsPoint(control.bounds, local), local.x, local.y, NSStringFromCGRect(control.frame),
                           control.hidden, (double)control.alpha, control.enabled, control.userInteractionEnabled,
                           control.window == window, parent ? NSStringFromClass(parent.class) : @"nil",
                           SkipTouchViewIdentity(parent), order == NSNotFound ? -1LL : (long long)order,
                           original.hidden, (double)original.alpha, original.userInteractionEnabled);
            }
        }
        return phases;
    } @finally { GuestUnlock(vm); }
}

static NSMutableDictionary<NSNumber *, UIView *> *g_shadows;
static gva_t g_stretDst;

void GuestSetStretDestination(gva_t dst) { g_stretDst = dst; }
gva_t GuestStretDestination(void) { return g_stretDst; }

UIView *GuestObjCShadow(GuestVM *vm, gva_t guestObject) {
    if (!g_shadows || !guestObject) return nil;
    return [g_shadows objectForKey:@(guestObject)];
}
#if defined(AS6_OBJC_METADATA_TESTS)
extern "C" void AS6TestSetShadow(GuestVM*,gva_t receiver,UIView *view) {
    if(!g_shadows)g_shadows=[NSMutableDictionary new];
    if(view)g_shadows[@(receiver)]=view;else[g_shadows removeObjectForKey:@(receiver)];
}
#endif
static uint32_t g_nextObject = GUEST_HOST_OBJECT_BASE;
static uint32_t g_nextClass = GUEST_HOST_CLASS_BASE;
static std::unordered_map<std::string, uint32_t> g_guestSels;

static const uint32_t kClassIsa = 0, kClassSuper = 4, kClassData = 16;
static const uint32_t kRoName = 16, kRoMethods = 20;

static BOOL GuestClassImplements(GuestVM *vm, gva_t guestClass, const char *name);

gva_t GuestObjCAllocInstance(GuestVM *vm, gva_t guestClass) {
    gva_t ro = GuestReadU32(vm, guestClass + 16);
    uint32_t size = ro ? GuestReadU32(vm, ro + 8) : 0;   // class_ro_t.instanceSize
    if (size < 8) size = 8;
    gva_t at = GuestAlloc(vm, size);
    if (!at) return 0;
    GuestWriteU32(vm, at, guestClass);   // isa

    // Walk to the first host class in the chain.  Only UIView subclasses need a
    // shadow: everything else is pure state that lives fine in guest memory.
    gva_t sup = GuestReadU32(vm, guestClass + kClassSuper);
    while (sup && !GuestIsHostClass(sup)) sup = GuestReadU32(vm, sup + kClassSuper);
    if (!sup) return at;
    Class hostSuper = GuestObjCUnwrapClass(vm, sup);
    if (!hostSuper || ![hostSuper isSubclassOfClass:[UIView class]]) return at;
    Class shadow = [PortGuestView class];
    gva_t meta = GuestReadU32(vm, guestClass + kClassIsa);
    if (meta && GuestClassImplements(vm, meta, "layerClass")) shadow = [PortGLView class];
    UIView *view = [[shadow alloc] initWithFrame:CGRectZero];
    ((PortGuestView *)view).guestAddress = at;
    if (!g_shadows) g_shadows = [NSMutableDictionary dictionary];
    [g_shadows setObject:view forKey:@(at)];
    return at;
}

uint32_t GuestObjCInstanceSize(GuestVM *vm, gva_t guestClass) {
    gva_t ro = GuestReadU32(vm, guestClass + 16);
    return ro ? GuestReadU32(vm, ro + 8) : 0;
}

uint32_t GuestObjCSendName(GuestVM *vm, gva_t recv, const char *name) {
    gva_t sel = GuestObjCGuestSelNamed(vm, name);
    if (!sel || !recv) return 0;
    GuestSetReg(vm, 0, recv);
    GuestSetReg(vm, 1, sel);
    if (!GuestObjCSend(vm, recv, sel, NO)) return 0;
    return GuestReg(vm, 0);
}

gva_t GuestObjCNew(GuestVM *vm, gva_t guestClass) {
    gva_t at = GuestObjCAllocInstance(vm, guestClass);
    if (!at) return 0;
    uint32_t r = GuestObjCSendName(vm, at, "init");
    return r ? r : at;
}

void GuestObjCBuildRegistry(GuestVM *vm) {
    NSString *error=nil;
    if(!GuestObjCBuildRegistryForBinding(vm,&error)) {
        GuestTrace(vm,@"[objc] registry unavailable: %@",error);GuestRequestFault(vm);
    }
}

BOOL GuestObjCBuildRegistryForBinding(GuestVM *vm,NSString **error) {
    extern uint32_t GuestSectionAddress(GuestVM *, const char *name);
    extern uint32_t GuestSectionSize(GuestVM *, const char *name);
    uint32_t list=0,size=0;
    GuestLoaderDeclaredSection(vm,"__objc_classlist",&list,&size);
    std::vector<as6native::LocalClassRecord> records;std::string why;
    const bool collected=as6native::CollectLocalClasses(list,size,
        [&](uint32_t at,void *out,size_t length){return bool(GuestRead(vm,at,out,length));},
        [&](uint32_t at,size_t cap,std::string &out){NSString *s=GuestReadCString(vm,at,cap);if(!s||!s.UTF8String)return false;out=s.UTF8String;return true;},records,why);
    if(!collected){if(error)*error=[NSString stringWithUTF8String:why.c_str()];return NO;}
    LocalRegistryState staged;
    for(const auto &record:records) {
        staged.classNames[record.address]=record.name;staged.nameToClass[record.name]=record.address;
        staged.metaNames[record.isa]=record.name;
        if(record.methods)staged.classMethodLists.emplace_back(record.address,record.methods);
    }
    LocalRegistry(vm)=std::move(staged);
    GuestTrace(vm, @"[objc] registered %zu checked in-image classes", records.size());
    return YES;
}

NSString *GuestObjCNameForClass(GuestVM *vm, gva_t guestClass) {
    const auto &map=LocalRegistry(vm).classNames;auto it=map.find(guestClass);
    return it==map.end()?nil:[NSString stringWithUTF8String:it->second.c_str()];
}

NSString *GuestObjCNameForMetaclass(GuestVM *vm, gva_t guestMeta) {
    const auto &map=LocalRegistry(vm).metaNames;auto it=map.find(guestMeta);
    return it==map.end()?nil:[NSString stringWithUTF8String:it->second.c_str()];
}

gva_t GuestObjCClassNamed(GuestVM *vm, NSString *name) {
    const auto &map=LocalRegistry(vm).nameToClass;auto it=map.find(name.UTF8String?:"");
    return it==map.end()?0:it->second;
}

// --- selectors -------------------------------------------------------------

SEL GuestObjCSelFromGuest(GuestVM *vm, gva_t guestSel) {
    if(GuestObjCMetadataWord(guestSel)){GuestRequestFault(vm);return NULL;}
    if (!guestSel) return NULL;
    // A guest SEL is the address of its NUL-terminated name, unless it is one
    // of the host selector handles handed out earlier.
    if (guestSel >= GUEST_HOST_SEL_BASE) {
        return (SEL)(uintptr_t)(guestSel - GUEST_HOST_SEL_BASE);
    }
    NSString *name = GuestReadCString(vm, guestSel, 256);
    if (name.length == 0) return NULL;
    return sel_registerName(name.UTF8String);
}

gva_t GuestObjCGuestSelNamed(GuestVM *vm, const char *name) {
    auto it = g_guestSels.find(name);
    if (it != g_guestSels.end()) return it->second;
    gva_t at = GuestWriteCString(vm, [NSString stringWithUTF8String:name]);
    g_guestSels[name] = at;
    return at;
}

// --- host object handles ---------------------------------------------------

static Class _NSAutoreleasePoolClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("NSAutoreleasePool"); });
    return cls;
}

static bool ObjcRetainSafe(id object) {
    for (Class k = object_getClass(object); k; k = class_getSuperclass(k)) {
        if (k == _NSAutoreleasePoolClass()) return false;
    }
    return true;
}

GuestUnsafeId GuestObjCUnwrap(GuestVM *vm, gva_t handle) {
    if(GuestObjCMetadataWord(handle)){GuestRequestFault(vm);return nil;}
    if (!GuestIsHostObject(handle)) return nil;
    auto it = g_objects.find(handle);
    return it == g_objects.end() ? nil : it->second;
}

gva_t GuestObjCWrap(GuestVM *vm, GuestUnsafeId object) {
    if (!object) return 0;
    gva_t delegateAddress = GuestObjCDelegateGuestAddress(object);
    if (delegateAddress) return delegateAddress;
    if (object_getClass(object) == (Class)object) {
        return GuestObjCWrapClass(vm, (Class)object);
    }
    auto existing = g_objectHandles.find((__bridge void *)object);
    if (existing != g_objectHandles.end()) return existing->second;
    uint32_t h = g_nextObject;
    g_nextObject += 4;
    if (ObjcRetainSafe(object)) { (void)(__bridge_retained void *)object; }
    g_objects[h] = object;
    g_objectHandles[(__bridge void *)object] = h;
    return h;
}

gva_t GuestObjCWrapClass(GuestVM *vm, Class cls) {
    if (!cls) return 0;
    for (const auto &kv : g_classes) {
        if (kv.second == cls) return kv.first;
    }
    uint32_t h = g_nextClass;
    g_nextClass += 4;
    g_classes[h] = cls;
    return h;
}

Class GuestObjCUnwrapClass(GuestVM *vm, gva_t handle) {
    if(GuestObjCMetadataWord(handle)){GuestRequestFault(vm);return Nil;}
    if (!GuestIsHostClass(handle)) return Nil;
    auto it = g_classes.find(handle);
    if (it == g_classes.end()) return Nil;
    static Class realPool = nil;
    static Class poolProxy = nil;
    static dispatch_once_t poolOnce;
    dispatch_once(&poolOnce, ^{
        realPool = objc_getClass("NSAutoreleasePool");
        poolProxy = objc_getClass("PortAutoreleasePool");
    });
    if (it->second == realPool && poolProxy) {
        it->second = poolProxy;   // sticky: the handle now means the stand-in
        return poolProxy;
    }
    return it->second;
}

// --- guest-side method lookup ---------------------------------------------

static gva_t FindGuestMethodImp(GuestVM *vm, gva_t classPtr, SEL sel) {
    const char *want = sel_getName(sel);
    for (gva_t cls = classPtr; cls != 0;) {
        // Native host classes have no guest class_t fields. The existing
        // shadow/superclass dispatch owns this boundary after lookup returns.
        if(GuestIsHostClass(cls))break;
        if(!GuestObjCMetadataDispatchReady(vm,cls,GuestObjCSend))return 0;
        gva_t ro = GuestReadU32(vm, cls + kClassData);
        if (!ro) break;
        gva_t ml = GuestReadU32(vm, ro + kRoMethods);
        if (ml) {
            uint32_t entsize = GuestReadU32(vm, ml);
            uint32_t count = GuestReadU32(vm, ml + 4);
            bool relative = (entsize & 0x80000000u) != 0;
            uint32_t stride = relative ? 12 : 12;
            for (uint32_t i = 0; i < count && i < 4096; i++) {
                gva_t e = ml + 8 + stride * i;
                uint32_t nameWord = GuestReadU32(vm, e);
                gva_t nameAddr = relative ? (e + nameWord) : nameWord;
                const char *got = GuestReadCString(vm, nameAddr, 256).UTF8String;
                if (got && strcmp(got, want) == 0) {
                    uint32_t imp = GuestReadU32(vm, e + 8);
                    if (relative) imp = (e + 8) + imp;
                    return imp;
                }
            }
        }
        cls = GuestReadU32(vm, cls + kClassSuper);
    }
    return 0;
}
#if defined(AS6_OBJC_METADATA_TESTS)
extern "C" gva_t AS6TestFindGuestMethodImp(GuestVM *vm,gva_t cls,const char *selector) {
    return FindGuestMethodImp(vm,cls,sel_registerName(selector));
}
#endif

// True when the guest class (or a guest superclass) implements `name` itself.
static BOOL GuestClassImplements(GuestVM *vm, gva_t guestClass, const char *name) {
    return FindGuestMethodImp(vm, guestClass, sel_registerName(name)) != 0;
}

// BEGIN AS6_PASSIVE_HELPERS
// Passive observation of existing native EAGLContext present calls only.
#include <mach/mach_time.h>
#include <pthread.h>
#include <cstdlib>
#include <cstdio>
#include <errno.h>

static bool PassivePresentEnabled() {
    static const bool enabled = [] {
        const char *value = getenv("AS6_PASSIVE_TIMING");
        return value && !strcmp(value, "1");
    }();
    return enabled;
}
static bool PassivePresentMatches(id target, SEL selector, NSMethodSignature *signature) {
    if (!PassivePresentEnabled() || strcmp(sel_getName(selector), "presentRenderbuffer:")) return false;
    Class eagl = objc_getClass("EAGLContext"), actual = object_getClass(target);
    if (!eagl || !actual || class_isMetaClass(actual)) return false;
    bool isEagl = false;
    for (Class cls = actual; cls; cls = class_getSuperclass(cls)) if (cls == eagl) { isEagl = true; break; }
    const char *type = signature.methodReturnType;
    while (*type && strchr("rnNoORV", *type)) ++type;
    return isEagl && signature.methodReturnLength == 1 && (*type == 'B' || *type == 'c' || *type == 'C');
}
static double PassivePresentSeconds(uint64_t ticks) {
    static const double scale = [] {
        mach_timebase_info_data_t base = {};
        if (mach_timebase_info(&base) != KERN_SUCCESS || !base.denom) return 0.0;
        return (double)base.numer / (double)base.denom / 1000000000.0;
    }();
    return (double)ticks * scale;
}
struct PassivePresentWindow {
    const void *context = nullptr;
    uint64_t start = 0, lastSuccess = 0;
    uint64_t returned = 0, successes = 0, intervals = 0;
    uint64_t nativeTotal = 0, nativeMaximum = 0, intervalTotal = 0, intervalMaximum = 0;
};
static pthread_mutex_t g_passivePresentLock = PTHREAD_MUTEX_INITIALIZER;
static PassivePresentWindow g_passivePresentWindow;
static void PassivePresentReturned(id context, bool success, uint64_t begin, uint64_t end) {
    int savedErrno = errno;
    char line[512]; int length = 0;
    pthread_mutex_lock(&g_passivePresentLock);
    auto &window = g_passivePresentWindow;
    if (window.context != (__bridge const void *)context || !window.start) {
        window = PassivePresentWindow{}; window.context = (__bridge const void *)context; window.start = begin;
    }
    uint64_t native = end - begin;
    ++window.returned; window.nativeTotal += native;
    if (native > window.nativeMaximum) window.nativeMaximum = native;
    if (success) {
        ++window.successes;
        if (window.lastSuccess) {
            uint64_t interval = end - window.lastSuccess;
            ++window.intervals; window.intervalTotal += interval;
            if (interval > window.intervalMaximum) window.intervalMaximum = interval;
        }
        window.lastSuccess = end;
    }
    double elapsed = PassivePresentSeconds(end - window.start);
    if (elapsed >= 2.0) {
        length = snprintf(line, sizeof(line),
            "[passive-present] ctx=%p window_s=%.6f returned=%llu success=%llu presents_per_s=%.3f "
            "interval_n=%llu interval_mean_ms=%.3f interval_max_ms=%.3f native_mean_ms=%.3f native_max_ms=%.3f\n",
            window.context, elapsed, (unsigned long long)window.returned,
            (unsigned long long)window.successes, (double)window.successes / elapsed,
            (unsigned long long)window.intervals,
            window.intervals ? 1000.0 * PassivePresentSeconds(window.intervalTotal) / window.intervals : 0.0,
            1000.0 * PassivePresentSeconds(window.intervalMaximum),
            1000.0 * PassivePresentSeconds(window.nativeTotal) / window.returned,
            1000.0 * PassivePresentSeconds(window.nativeMaximum));
        uint64_t lastSuccess = window.lastSuccess;
        window = PassivePresentWindow{}; window.context = (__bridge const void *)context;
        window.start = end; window.lastSuccess = lastSuccess;
    }
    pthread_mutex_unlock(&g_passivePresentLock);
    if (length > 0) {
        line[sizeof(line) - 1] = 0;
        GuestRawLog(line);
    }
    errno = savedErrno;
}
// END AS6_PASSIVE_HELPERS
// --- host-side dispatch via NSInvocation ----------------------------------

static size_t SizeOfEncoding(const char *type) {
    if (type[0] == '^' || type[0] == '*' || type[0] == '@' || type[0] == '#' || type[0] == ':')
        return sizeof(void *);
    switch (type[0]) {
        case 'c': case 'C': case 'B': return 1;
        case 's': case 'S': return 2;
        case 'i': case 'I': case 'f': case 'l': case 'L': return 4;
        case 'q': case 'Q': case 'd': case 'D': return 8;
        case 'b': return 4;
        default: return 0;
    }
}

static BOOL IsFloatEncoding(const char *t) { return t[0] == 'f' || t[0] == 'd'; }

// Foundation and UIKit widen these fields from 32 bits to 64 bits on arm64.
// The original code still reads exactly the armv7 aggregate layout.
static NSUInteger AggregateFields(const char *enc, BOOL *integerFields) {
    *integerFields = NO;
    if (!strncmp(enc, "{_NSRange=", 10) || !strncmp(enc, "{NSRange=", 9)) {
        *integerFields = YES;
        return 2;
    }
    if (!strncmp(enc, "{CGRect=", 8) || !strncmp(enc, "{UIEdgeInsets=", 14)) return 4;
    if (!strncmp(enc, "{CGPoint=", 9) || !strncmp(enc, "{CGSize=", 8) ||
        !strncmp(enc, "{UIOffset=", 10)) return 2;
    if (!strncmp(enc, "{CGAffineTransform=", 19)) return 6;
    return 0;
}

static void ExpandAggregate(const uint32_t *guest, void *host, NSUInteger fields, BOOL integers) {
    for (NSUInteger i = 0; i < fields; i++) {
        if (integers) {
            uint64_t value = guest[i];
            memcpy((uint8_t *)host + i * 8, &value, 8);
        } else {
            float value;
            memcpy(&value, guest + i, 4);
            double widened = value;
            memcpy((uint8_t *)host + i * 8, &widened, 8);
        }
    }
}

static void NarrowAggregate(const void *host, uint32_t *guest, NSUInteger fields, BOOL integers) {
    for (NSUInteger i = 0; i < fields; i++) {
        if (integers) {
            uint64_t value;
            memcpy(&value, (const uint8_t *)host + i * 8, 8);
            guest[i] = (uint32_t)value;
        } else {
            double value;
            memcpy(&value, (const uint8_t *)host + i * 8, 8);
            float narrowed = (float)value;
            memcpy(guest + i, &narrowed, 4);
        }
    }
}

static void *OpaqueFor(GuestVM *vm, gva_t gva) {
    if (!gva) return NULL;
    if (GuestIsHostObject(gva)) return (__bridge void *)GuestObjCUnwrap(vm, gva);
    if (GuestIsHostClass(gva)) return (__bridge void *)GuestObjCUnwrapClass(vm, gva);
    return HLEUnwrapOpaque(vm, gva);
}

// --- guest pointer arguments -----------------------------------------------
//
// A guest address is an index into emulated memory, so host code must never
// dereference one. Handing NULL to -[NSString getCString:maxLength:encoding:]
// used to be "safe" until the host wrote 0x200 bytes through it: SIGBUS.
// Out-parameters are therefore backed by host scratch that is copied in before
// the call and copied back afterwards.
struct PointerBack {
    void *host;         // scratch handed to NSInvocation
    size_t hostSize;    // bytes allocated at `host`
    gva_t guest;        // guest address to write back to
    size_t guestSize;   // bytes to copy back (0 = leave guest memory alone)
    char pointee;       // base type-encoding character of the pointee
    uint32_t initialGuestWord;
    void *initialHostPointer;
};

enum class PointerFlow { Input, Output, InOut };
static PointerFlow PointerArgumentFlow(const char *enc, SEL sel, NSUInteger index) {
    for(const char *p=enc;*p&&*p!='^';++p) {
        if(*p=='o')return PointerFlow::Output;
        if(*p=='N')return PointerFlow::InOut;
        if(*p=='n')return PointerFlow::Input;
    }
    // Foundation's NSError ** parameters are pure output even when their
    // runtime encoding omits the optional 'o' qualifier.
    NSString *name=sel?NSStringFromSelector(sel):@"";
    NSArray<NSString *> *parts=[name componentsSeparatedByString:@":"];
    if(index>=2&&index-2<parts.count) {
        NSString *part=parts[index-2];
        if([part isEqualToString:@"error"]||[part isEqualToString:@"errorDescription"]||
           [part isEqualToString:@"returningError"])return PointerFlow::Output;
    }
    if(index==2&&([name hasPrefix:@"getObjectValue:"]||[name hasPrefix:@"getResourceValue:"]))
        return PointerFlow::Output;
    return PointerFlow::InOut;
}

static bool PointerObjectArray(SEL sel) {
    const char *name=sel?sel_getName(sel):"";
    return strstr(name,"Objects:")||strstr(name,"objects:")||strstr(name,"forKeys:");
}

static id TypedPointerObject(GuestVM *vm,uint32_t word) {
    if(!word)return nil;
    if(GuestIsHostObject(word))return GuestObjCUnwrap(vm,word);
    if(GuestIsHostClass(word))return (id)GuestObjCUnwrapClass(vm,word);
    if(GuestSectionContains(vm,"__cfstring",word))return GuestObjCCFString(vm,word);
    uint32_t isa=0;
    if(!GuestObjCMetadataWord(word)&&GuestRead(vm,word,&isa,4)&&LocalRegistry(vm).classNames.count(isa)) {
        id shadow=GuestObjCShadow(vm,word);
        return shadow?:GuestObjCDelegateProxy(vm,word);
    }
    return nil;
}

// Skip objc type qualifiers to reach the pointee's base encoding.
static char PointeeBase(const char *enc) {
    const char *p = enc;
    while(*p&&strchr("rnNoORV",*p))++p;
    if(*p=='^')++p;
    for (;;) {
        switch (*p) {
            case 'r': case 'n': case 'N': case 'o':
            case 'O': case 'R': case 'V':
                p++;
                continue;
            default:
                return *p ? *p : 'v';
        }
    }
}

// Size of a scalar on the *guest* (32-bit armv7), which is what gets written
// back. The host slot may be wider -- `long` is 8 bytes on arm64 and 4 in the
// guest -- so the write-back always takes the low bytes of the host value.
static size_t GuestScalarSize(char c) {
    switch (c) {
        case 'c': case 'C': case 'B': return 1;
        case 's': case 'S': return 2;
        case 'i': case 'I': case 'l': case 'L': case 'f':
        case '^': case '@': case '#': case ':': case '*': case '%': return 4;
        case 'q': case 'Q': case 'd': return 8;
        default: return 0;
    }
}

// Reusable guest arena for C strings the host hands back to the guest. The
// bump allocator in GuestAlloc never frees, so a render loop that calls
// -UTF8String every frame would eventually walk the guest heap off the end.
static gva_t GuestTmpBuf(GuestVM *vm, size_t len) {
    static gva_t s_base = 0;
    static size_t s_off = 0;
    const size_t kArena = 1u << 20;
    if (!s_base) {
        s_base = GuestAlloc(vm, kArena);
        s_off = 0;
        if (!s_base) return 0;
    }
    size_t need = (len + 32 + 15) & ~(size_t)15;
    if (need > kArena) return 0;
    if (s_off + need > kArena) s_off = 0;
    gva_t at = s_base + (uint32_t)s_off;
    s_off += need;
    return at;
}

// Copy host bytes into guest memory as a NUL-terminated C buffer and return
// the *guest* address. This is what -UTF8String and friends must answer with.
static gva_t GuestWriteBackBytes(GuestVM *vm, const void *bytes, size_t len) {
    gva_t dst = GuestTmpBuf(vm, len + 1);
    if (!dst) return 0;
    if (!GuestWrite(vm, dst, bytes, len)) return 0;
    uint8_t nul = 0;
    GuestWrite(vm, dst + len, &nul, 1);
    return dst;
}

static void *BackGuestPointer(GuestVM *vm, gva_t gva, const char *enc, size_t hint,
                              PointerBack *back,
                              std::vector<std::vector<uint8_t>> &pool,
                              PointerFlow flow=PointerFlow::InOut,
                              NSMutableArray *retained=nil) {
    memset(back, 0, sizeof(*back));
    back->guest = gva;
    if (!gva) return NULL;
    const char pointee=PointeeBase(enc);
    back->pointee=pointee;
    if(pointee=='@'||pointee=='#'||pointee==':'||pointee=='^'||pointee=='%') {
        // An untyped pointer-to-pointer has no safe object/opaque return
        // contract here. Existing opaque handles still use the path below.
        if(pointee=='^'||pointee=='%') {
            GuestTrace(vm,@"[objc] unsupported pointer-to-pointer encoding %s",enc);
            GuestRequestFault(vm);return nullptr;
        }
        uint32_t word=0;
        if(GuestObjCMetadataWord(gva)||!GuestRead(vm,gva,&word,4)){GuestRequestFault(vm);return nullptr;}
        void *native=nullptr;
        if(flow!=PointerFlow::Output&&word) {
            if(pointee=='@') {
                id object=TypedPointerObject(vm,word);
                if(!object){GuestTrace(vm,@"[objc] invalid inout object identity %#x",word);GuestRequestFault(vm);return nullptr;}
                if(retained)[retained addObject:object];
                native=(__bridge void *)object;
            } else if(pointee=='#')native=(__bridge void *)GuestObjCUnwrapClass(vm,word);
            else native=(void *)GuestObjCSelFromGuest(vm,word);
            if(!native||GuestHasStopRequest(vm)){GuestRequestFault(vm);return nullptr;}
        }
        pool.emplace_back(sizeof(void *),0);
        auto &slot=pool.back();memcpy(slot.data(),&native,sizeof(native));
        back->host=slot.data();back->hostSize=sizeof(void *);
        back->guestSize=flow==PointerFlow::Input?0:4;
        back->initialGuestWord=word;
        back->initialHostPointer=native;
        return slot.data();
    }
    if (GuestIsHostObject(gva)) return (__bridge void *)GuestObjCUnwrap(vm, gva);
    if (GuestIsHostClass(gva)) return (__bridge void *)GuestObjCUnwrapClass(vm, gva);
    if (void *opaque = HLEUnwrapOpaque(vm, gva)) return opaque;
    if(GuestHasStopRequest(vm))return nullptr;

    size_t scalar = GuestScalarSize(pointee);
    if (scalar && pointee != '*' && pointee != 'v') {
        if(as6native::ObjCMetadataOverlap(gva,scalar)){GuestRequestFault(vm);return nullptr;}
        // Scalar out-parameter (BOOL *, int *, NSUInteger *, NSError **, ...):
        // the host slot is the host size, the guest slot the guest size.
        size_t hostSlot = scalar;
        if (pointee == 'l' || pointee == 'L' || pointee == 'q' || pointee == 'Q' ||
            pointee == 'd') hostSlot = 8;
        pool.emplace_back(hostSlot + 8, 0);
        std::vector<uint8_t> &slot = pool.back();
        // Seed with the current guest contents so an in/out parameter works.
        if(!GuestRead(vm, gva, slot.data(), MIN(scalar, slot.size()))){GuestRequestFault(vm);return nullptr;}
        back->host = slot.data();
        back->hostSize = slot.size();
        back->guestSize = scalar;
        return slot.data();
    }

    // Byte buffers: size from a neighbouring length argument when the selector
    // has one, otherwise from the string that is already sitting there.
    if(hint&&as6native::ObjCMetadataOverlap(gva,hint)){GuestRequestFault(vm);return nullptr;}
    size_t existing = GuestStrLen(vm, gva, hint ? hint : 4096);
    if(GuestHasStopRequest(vm))return nullptr;
    size_t inLen = existing;
    size_t keep = hint ? hint : (existing ? existing + 1 : 0);
    if (keep == 0 && hint == 0) keep = 0;
    size_t alloc = 0;
    if (hint) alloc = hint + 64;
    else if (existing) alloc = existing + 64;
    if (alloc == 0) alloc = 256;
    if (alloc > (1u << 20)) alloc = 1u << 20;
    const size_t checkedSpan=hint?MIN(hint,alloc):(existing?MIN(inLen,alloc):MIN(alloc,(size_t)256));
    if(as6native::ObjCMetadataOverlap(gva,checkedSpan)){GuestRequestFault(vm);return nullptr;}
    pool.emplace_back(alloc, 0);
    std::vector<uint8_t> &buf = pool.back();
    if(checkedSpan&&!GuestRead(vm,gva,buf.data(),checkedSpan)){GuestRequestFault(vm);return nullptr;}
    back->host = buf.data();
    back->hostSize = buf.size();
    // Only write back when we know how much the host is allowed to have
    // produced: an explicit length argument, or a pure out buffer we zeroed.
    if (hint) back->guestSize = MIN(hint, buf.size());
    else if (existing == 0) back->guestSize = MIN(buf.size(), (size_t)256);
    else back->guestSize = 0;
    (void)keep;
    return buf.data();
}

static void FlushPointerBacks(GuestVM *vm, const std::vector<PointerBack> &backs) {
    for (const PointerBack &b : backs) {
        if (!b.host || !b.guest || b.guestSize == 0) continue;
        if (b.pointee == '@') {
            void *raw = nullptr;
            memcpy(&raw, b.host, MIN(b.hostSize, sizeof(raw)));
            // Check before creating any ARC strong id: original addresses and
            // guest handles can never be native Objective-C object pointers.
            if(raw&&uintptr_t(raw)<=UINT32_MAX) {
                GuestTrace(vm,@"[objc] refused guest-domain object pointer return %#llx",(unsigned long long)uintptr_t(raw));
                GuestRequestFault(vm);return;
            }
            // A successful NSError API may leave its nil-seeded output
            // untouched. Never invent a guest write in that case. The same
            // rule preserves original inout identity without rewriting it.
            // A pure-out explicit nil is indistinguishable from no write;
            // it is not evidence of a new object value to commit.
            if(raw==b.initialHostPointer) continue;
            id obj = (__bridge id)raw;
            const auto word=obj?GuestObjCWrap(vm,obj):0;
            if(obj&&!word){GuestRequestFault(vm);return;}
            GuestWriteU32(vm, b.guest, word);
            continue;
        }
        if (b.pointee == ':') {
            SEL out = nullptr;
            memcpy(&out, b.host, MIN(b.hostSize, sizeof(out)));
            if(out&&(uintptr_t(out)<=UINT32_MAX||!sel_isMapped(out))){GuestRequestFault(vm);return;}
            if((void*)out==b.initialHostPointer)continue;
            gva_t gs = out ? GuestObjCGuestSelNamed(vm, sel_getName(out)) : 0;
            GuestWriteU32(vm, b.guest, gs);
            continue;
        }
        if (b.pointee == '#') {
            void *p = nullptr;
            memcpy(&p, b.host, MIN(b.hostSize, sizeof(p)));
            if(p==b.initialHostPointer)continue;
            bool found=!p;unsigned count=0;
            Class __unsafe_unretained *classes=objc_copyClassList(&count);
            for(unsigned i=0;i<count;++i)if((__bridge void *)classes[i]==p){found=true;break;}
            free(classes);
            if(!found){GuestRequestFault(vm);return;}
            GuestWriteU32(vm,b.guest,p?GuestObjCWrapClass(vm,(__bridge Class)p):0);
            continue;
        }
        GuestWrite(vm, b.guest, b.host, b.guestSize);
    }
}

// --- NSString / NSData -> guest C buffers -----------------------------------
//
// These are the selectors where a truncated host pointer is indistinguishable
// from a wild guest address, so they are answered exactly instead of through
// the generic marshaller.
static BOOL HostStringBridge(GuestVM *vm, id target, SEL sel, const char *selName) {
    if (!selName) return NO;
    // +alloc hands back a _NSPlaceholderString; messaging it raises. The guest
    // is mid-way through alloc/init here, so stay out of its way.
    const char *tname = target ? class_getName(object_getClass(target)) : nullptr;
    if (tname && (strstr(tname, "Placeholder") || strstr(tname, "_NSZero"))) return NO;
    BOOL isString = NO, isData = NO;
    @try {
        isString = [target isKindOfClass:[NSString class]];
        isData = !isString && [target isKindOfClass:[NSData class]];
    } @catch (NSException *e) {
        return NO;
    }
    if (!isString && !isData) return NO;

    if (isString) {
        NSData *utf8 = [(NSString *)target dataUsingEncoding:NSUTF8StringEncoding
                                                allowLossyConversion:YES];
        if (!utf8) return NO;
        const uint8_t *bytes = (const uint8_t *)utf8.bytes;
        NSUInteger len = utf8.length;

        if (strcmp(selName, "UTF8String") == 0 || strcmp(selName, "cString") == 0 ||
            strcmp(selName, "lossyCString") == 0 || strcmp(selName, "getCString") == 0 ||
            strcmp(selName, "cStringUsingEncoding:") == 0 ||
            strcmp(selName, "fileSystemRepresentation") == 0) {
            GuestSetRet(vm, GuestWriteBackBytes(vm, bytes, len));
            return YES;
        }
        if (strcmp(selName, "getCString:") == 0 ||
            strcmp(selName, "getCString:maxLength:") == 0 ||
            strcmp(selName, "getCString:maxLength:encoding:") == 0) {
            gva_t buf = GuestArg(vm, 2);
            uint32_t maxLen = 0;
            if (strcmp(selName, "getCString:") != 0) maxLen = GuestArg(vm, 3);
            if (maxLen == 0 || maxLen > (1u << 20)) maxLen = 4096;
            if (!buf) { GuestSetRet(vm, 0); return YES; }
            NSUInteger n = MIN((NSUInteger)(maxLen - 1), len);
            if (!GuestWrite(vm, buf, bytes, n)) { GuestSetRet(vm, 0); return YES; }
            uint8_t nul = 0;
            GuestWrite(vm, buf + n, &nul, 1);
            GuestSetRet(vm, 1);
            return YES;
        }
        return NO;
    }

    NSData *d = (NSData *)target;
    if (strcmp(selName, "bytes") == 0) {
        GuestSetRet(vm, GuestWriteBackBytes(vm, (const uint8_t *)d.bytes, d.length));
        return YES;
    }
    if (strcmp(selName, "getBytes:length:") == 0 ||
        strcmp(selName, "getBytes:length:range:") == 0) {
        gva_t dst = GuestArg(vm, 2);
        uint32_t count = GuestArg(vm, 3);
        NSUInteger loc = 0;
        if (strcmp(selName, "getBytes:length:range:") == 0) {
            loc = MIN((NSUInteger)GuestArg(vm, 4), d.length);
        }
        if (dst && count && count <= (1u << 24)) {
            NSUInteger n = MIN((NSUInteger)count, d.length - loc);
            GuestWrite(vm, dst, (const uint8_t *)d.bytes + loc, n);
        }
        GuestSetRet(vm, 0);
        return YES;
    }
    return NO;
}

static BOOL HostSendTracingEnabled(void) {
    // Bounded so a full launch trace stays readable; flip AS6_TRACE_OBJC=0 off.
    static int budget = 6000;
    static int initialised = 0;
    if (!initialised) {
        initialised = 1;
        NSDictionary *env = [NSProcessInfo processInfo].environment;
        NSString *flag = [env objectForKey:@"AS6_TRACE_OBJC"];
        if ([flag isEqualToString:@"0"]) budget = 0;
    }
    return budget-- > 0;
}

static BOOL HostSendInner(GuestVM *vm, id target, SEL sel, BOOL stret);

static NSMutableDictionary<NSNumber *, NSArray *> *g_enumerations;

static BOOL HostFastEnumeration(GuestVM *vm, id target, SEL sel) {
    if (strcmp(sel_getName(sel), "countByEnumeratingWithState:objects:count:")) return NO;
    gva_t state = GuestArg(vm, 2), buffer = GuestArg(vm, 3);
    uint32_t capacity = GuestArg(vm, 4);
    if(GuestHasStopRequest(vm))return NO;
    if(GuestObjCMetadataWord(state)||GuestObjCMetadataWord(buffer)||as6native::ObjCMetadataOverlap(state,16)||as6native::ObjCMetadataOverlap(buffer,std::uint64_t(capacity)*4)) {GuestRequestFault(vm);return NO;}
    if (!state || !buffer || !capacity || capacity > 4096) {
        GuestSetRet(vm, 0);
        return YES;
    }
    if (!g_enumerations) g_enumerations = [NSMutableDictionary dictionary];
    uint32_t offset = GuestReadU32(vm, state);
    if(GuestHasStopRequest(vm))return NO;
    NSArray *objects = g_enumerations[@(state)];
    if (!offset || !objects) {
        if ([target isKindOfClass:[NSSet class]]) objects = [(NSSet *)target allObjects];
        else if ([target isKindOfClass:[NSDictionary class]]) objects = [(NSDictionary *)target allKeys];
        else if ([target isKindOfClass:[NSArray class]]) objects = [target copy];
        if (!objects) { GuestSetRet(vm, 0); return YES; }
        g_enumerations[@(state)] = objects;
    }
    uint32_t count = offset < objects.count ?
        (uint32_t)MIN((NSUInteger)capacity, objects.count - offset) : 0;
    for (uint32_t i = 0; i < count; i++) {
        GuestWriteU32(vm, buffer + 4 * i, GuestObjCWrap(vm, objects[offset + i]));
        if(GuestHasStopRequest(vm))return NO;
    }
    GuestWriteU32(vm, state, offset + count);
    GuestWriteU32(vm, state + 4, buffer);
    // A stable guest word backs the mutation pointer, never a host address.
    GuestWriteU32(vm, state + 8, state + 12);
    GuestWriteU32(vm, state + 12, 1);
    if (!count) [g_enumerations removeObjectForKey:@(state)];
    GuestSetRet(vm, count);
    return YES;
}

static id HostObjectArgument(GuestVM *vm, uint32_t word) {
    if(GuestObjCMetadataWord(word)){GuestRequestFault(vm);return nil;}
    if (!word) return nil;
    if (GuestIsHostObject(word)) return GuestObjCUnwrap(vm, word);
    if (GuestIsHostClass(word)) return (id)GuestObjCUnwrapClass(vm, word);
    if (GuestSectionContains(vm, "__cfstring", word)) return GuestObjCCFString(vm, word);
    id shadow = GuestObjCShadow(vm, word);
    return shadow ?: GuestObjCDelegateProxy(vm, word);
}

// NSInvocation has no representation for unnamed variadic arguments. Decode
// the original armv7 argument stream before calling a nonvariadic host method.
static BOOL HostCollectionVarargs(GuestVM *vm, id target, SEL sel) {
    const char *name = sel_getName(sel);
    BOOL dictionary = !strcmp(name, "dictionaryWithObjectsAndKeys:") ||
                      !strcmp(name, "initWithObjectsAndKeys:");
    BOOL array = !strcmp(name, "arrayWithObjects:") || !strcmp(name, "initWithObjects:");
    BOOL set = !strcmp(name, "setWithObjects:");
    if (!dictionary && !array && !set) return NO;
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
    for (int i = 2; i < 258;) {
        uint32_t word = GuestArg(vm, i++);
        if(GuestHasStopRequest(vm))return NO;
        if (!word) break;
        id object = HostObjectArgument(vm, word);
        if(GuestHasStopRequest(vm))return NO;
        if (!object) {
            GuestTrace(vm, @"[objc] %@ has invalid object %#x", NSStringFromSelector(sel), word);
            GuestSetRet(vm, 0);
            return YES;
        }
        if (dictionary) {
            uint32_t keyWord = GuestArg(vm, i++);
            if(GuestHasStopRequest(vm))return NO;
            id key = HostObjectArgument(vm, keyWord);
            if(GuestHasStopRequest(vm))return NO;
            if (!key) {
                GuestTrace(vm, @"[objc] %@ has invalid key %#x", NSStringFromSelector(sel), keyWord);
                GuestSetRet(vm, 0);
                return YES;
            }
            pairs[key] = object;
        } else [objects addObject:object];
    }
    if(GuestHasStopRequest(vm))return NO;
    BOOL isClass = class_isMetaClass(object_getClass(target));
    id result;
    if (dictionary) {
        BOOL isMutable = isClass ? [(Class)target isSubclassOfClass:[NSMutableDictionary class]]
                               : [target isKindOfClass:[NSMutableDictionary class]];
        result = isMutable ? pairs : [pairs copy];
    } else if (set) result = [NSSet setWithArray:objects];
    else {
        BOOL isMutable = isClass ? [(Class)target isSubclassOfClass:[NSMutableArray class]]
                               : [target isKindOfClass:[NSMutableArray class]];
        result = isMutable ? objects : [objects copy];
    }
    if(GuestHasStopRequest(vm))return NO;
    GuestSetRet(vm, GuestObjCWrap(vm, result));
    return YES;
}

static BOOL HostStringVarargs(GuestVM *vm, id target, SEL sel) {
    const char *name = sel_getName(sel);
    BOOL append = !strcmp(name, "appendFormat:");
    if (!append && strcmp(name, "stringWithFormat:") && strcmp(name, "initWithFormat:"))
        return NO;
    NSString *format = HostObjectArgument(vm, GuestArg(vm, 2));
    if(GuestHasStopRequest(vm))return NO;
    if (![format isKindOfClass:[NSString class]]) { GuestSetRet(vm, 0); return YES; }
    NSString *value = GuestFormatCall(vm, format, 3, 0);
    if(GuestHasStopRequest(vm))return NO;
    if (append) {
        [(NSMutableString *)target appendString:value];
        return YES;
    }
    GuestSetRet(vm, GuestObjCWrap(vm, value));
    return YES;
}

static BOOL IsCGFloatSelector(SEL sel) {
    const char *name = sel_getName(sel);
    static const char *names[] = {
        "contentScaleFactor", "setContentScaleFactor:", "contentsScale", "setContentsScale:",
        "alpha", "setAlpha:", "opacity", "setOpacity:", "cornerRadius", "setCornerRadius:",
        "borderWidth", "setBorderWidth:", "pointSize", "fontWithName:size:",
        "systemFontOfSize:", "boldSystemFontOfSize:", "italicSystemFontOfSize:",
        "minimumFontSize", "setMinimumFontSize:", "minimumScaleFactor", "setMinimumScaleFactor:"
    };
    for (const char *candidate : names) if (!strcmp(name, candidate)) return YES;
    return NO;
}

static BOOL HostSend(GuestVM *vm, id target, SEL sel, BOOL stret) {
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    @try {
        return HostSendInner(vm, target, sel, stret);
    } @catch (NSException *e) {
        GuestTrace(vm, @"[objc] host message %@ failed before invoke: %@ %@",
                   NSStringFromSelector(sel) ?: @"?", e.name ?: @"?", e.reason ?: @"?");
        GuestSetRet(vm, 0);
        return YES;
    }
}
#if defined(AS6_OBJC_METADATA_TESTS)
extern "C" BOOL AS6TestHostSend(GuestVM *vm,id target,SEL sel,BOOL stret){return HostSend(vm,target,sel,stret);}
#endif

// Only resource-returning messages are intercepted; the real Bundle object,
// bundlePath/Info/executable identity and all Guest path words remain intact.
static BOOL HostResourceBundleReturn(GuestVM *vm,id target,SEL sel,BOOL stret) {
    if(stret)return NO;const char *name=sel_getName(sel);id result=nil;BOOL handled=NO;
    auto stringArg=[&](int index)->NSString *{const auto word=GuestArg(vm,index);if(GuestObjCMetadataWord(word)){GuestRequestFault(vm);return nil;}id object=HostObjectArgument(vm,word);return [object isKindOfClass:NSString.class]?object:nil;};
    if(target==(id)NSBundle.mainBundle){
        if(!strcmp(name,"resourcePath")){result=AS6ResourceRootPath();handled=YES;}
        else if(!strcmp(name,"resourceURL")){NSString *root=AS6ResourceRootPath();result=root?[NSURL fileURLWithPath:root isDirectory:YES]:nil;handled=YES;}
        else if(!strcmp(name,"pathForResource:ofType:")||!strcmp(name,"pathForResource:ofType:inDirectory:")||!strcmp(name,"pathForResource:ofType:inDirectory:forLocalization:")){
            NSString *resource=stringArg(2),*extension=stringArg(3),*directory=strstr(name,"inDirectory:")?stringArg(4):nil,*localization=strstr(name,"forLocalization:")?stringArg(5):nil;
            result=AS6ResourceBundlePath(resource,extension,directory,localization,&handled);
        } else if(!strcmp(name,"URLForResource:withExtension:")||!strcmp(name,"URLForResource:withExtension:subdirectory:")||!strcmp(name,"URLForResource:withExtension:subdirectory:localization:")){
            NSString *resource=stringArg(2),*extension=stringArg(3),*directory=strstr(name,"subdirectory:")?stringArg(4):nil,*localization=strstr(name,"localization:")?stringArg(5):nil;
            NSString *path=AS6ResourceBundlePath(resource,extension,directory,localization,&handled);result=path?[NSURL fileURLWithPath:path]:nil;
        }
    }
    Class image=objc_lookUpClass("UIImage");
    if(image&&target==(id)image&&!strcmp(name,"imageNamed:")){
        NSString *resource=stringArg(2);NSString *path=AS6ResourceBundlePath(resource,nil,nil,nil,&handled);
        if(!path&&resource.length&&!resource.pathExtension.length){BOOL pngHandled=NO;path=AS6ResourceBundlePath(resource,@"png",nil,nil,&pngHandled);handled=handled||pngHandled;}
        if(handled&&path)result=((id(*)(id,SEL,id))objc_msgSend)(target,@selector(imageWithContentsOfFile:),path);
    }
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return YES;}
    if(!handled)return NO;GuestSetRet(vm,GuestObjCWrap(vm,result));return YES;
}

static BOOL HostSendInner(GuestVM *vm, id target, SEL sel, BOOL stret) {
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    if (HostNativeTouchSnapshotReturn(vm, target, sel, stret)) return YES;
    if (HostResourceBundleReturn(vm,target,sel,stret)) return YES;
    __attribute__((objc_precise_lifetime)) id resourceReceiver=AS6ResourceReadReceiver(target,sel);
    target=resourceReceiver;
    if (!strcmp(sel_getName(sel), "addSubview:")) {
        const auto child=GuestArg(vm,2);
        if(GuestObjCMetadataWord(child)){GuestRequestFault(vm);return NO;}
        if(GuestHasStopRequest(vm))return NO;
        const BOOL handled=GuestWindowAddSubview(vm,target,child);
        if(GuestHasStopRequest(vm))return NO;
        if(handled)return YES;
    }
    if (!strcmp(sel_getName(sel), "addTarget:action:forControlEvents:") &&
        [target isKindOfClass:[UIControl class]]) {
        gva_t guestTarget = GuestArg(vm, 2);
        const gva_t guestSelector=GuestArg(vm,3);
        const uint32_t events=GuestArg(vm,4);
        if(GuestObjCMetadataWord(guestTarget)||GuestObjCMetadataWord(guestSelector)){GuestRequestFault(vm);return NO;}
        if(GuestHasStopRequest(vm))return NO;
        const SEL nativeAction=GuestObjCSelFromGuest(vm,guestSelector);
        if(GuestHasStopRequest(vm)||!nativeAction){GuestRequestFault(vm);return NO;}
        if (guestTarget && !GuestIsHostObject(guestTarget) && !GuestIsHostClass(guestTarget)) {
            PortGuestActionTarget *proxy = [PortGuestActionTarget new];
            proxy.guestTarget = guestTarget;
            proxy.guestSelector = guestSelector;
            proxy.control = target;
            if (!g_actionTargets) g_actionTargets = [NSMutableArray array];
            [g_actionTargets addObject:proxy];
            if(GuestHasStopRequest(vm))return NO;
            [(UIControl *)target addTarget:proxy action:@selector(fire:forEvent:)
                          forControlEvents:(UIControlEvents)events];
            GuestTrace(vm, @"[uikit] original control action %@ -> guest %#x",
                       NSStringFromSelector(nativeAction), guestTarget);
            return YES;
        }
    }
    BOOL handled=HostFastEnumeration(vm,target,sel);
    if(GuestHasStopRequest(vm))return NO;if(handled)return YES;
    handled=HostCollectionVarargs(vm,target,sel);
    if(GuestHasStopRequest(vm))return NO;if(handled)return YES;
    handled=HostStringVarargs(vm,target,sel);
    if(GuestHasStopRequest(vm))return NO;if(handled)return YES;
    if (HostSendTracingEnabled()) {
        // Allocation-free breadcrumb: if the process dies inside this function,
        // this is the only line that is guaranteed to have reached disk.
        const char *cname = target ? class_getName(object_getClass(target)) : "(null)";
        const char *sname = sel ? sel_getName(sel) : "(nil)";
        char line[256];
        snprintf(line, sizeof(line), "<-- %s %s", cname ? cname : "?", sname ? sname : "?");
        GuestRawLog(line);
    }
    NSMethodSignature *sig = nil;
    Class cls = object_getClass(target);
    if (cls == (Class)target || class_isMetaClass(cls)) {
        sig = [target methodSignatureForSelector:sel];
        cls = object_getClass(target);
    } else {
        sig = [cls instanceMethodSignatureForSelector:sel];
    }
    if (!sig) {
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return NO;
        sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
        if (!sig) return NO;
    }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    if (HostSendTracingEnabled()) {
        GuestTrace(vm, @"[objc] host -[%@ %@] (%lu args)",
                   NSStringFromClass(cls) ?: @"?", NSStringFromSelector(sel),
                   (unsigned long)sig.numberOfArguments);
    }

    int intIndex = 2, floatIndex = 0;
    NSMutableArray *retained = [NSMutableArray array];
    __attribute__((objc_precise_lifetime)) NSMutableArray *resourceOwners=nil;
    NSMutableData *scratch = [NSMutableData data];
    std::vector<std::vector<uint8_t>> pool;
    std::vector<PointerBack> backed;

    NSUInteger argc = sig.numberOfArguments;
    if (argc > 32) {
        // A signature this wide means the type encoding was garbage; without
        // the clamp the argument loop grows `backed` until std::vector throws.
        GuestTrace(vm, @"[objc] %@ %@ reports %lu arguments -- clamped",
                   NSStringFromClass(cls) ?: @"?", NSStringFromSelector(sel),
                   (unsigned long)argc);
        argc = 32;
    }
    // Read every plain integer argument up front: a pointer argument borrows a
    // later integer as its buffer length (getBytes:length:,
    // getCString:maxLength:encoding:), which the sequential loop cannot see.
    std::vector<uint32_t> intArg(argc, 0);
    std::vector<char> intKind(argc, 0);
    {
        int pi = 2;
        for (NSUInteger i = 2; i < argc; i++) {
            const char *enc = [sig getArgumentTypeAtIndex:i];
            if (!enc || !enc[0]) continue;
            char base = enc[0];
            if (base == 'r') base = enc[1] ? enc[1] : enc[0];
            if (base == 'n' || base == 'N' || base == 'o' || base == 'O' ||
                base == 'R' || base == 'V') base = enc[1] ? enc[1] : enc[0];
            int words = 1;
            if (base == 'd' && !IsCGFloatSelector(sel)) words = 2;
            if ((base == 'q' || base == 'Q') && strstr(sel_getName(sel), "LongLong")) words = 2;
            if (base == '{' || base == '(' || base == '[') {
                BOOL integers = NO;
                NSUInteger fields = AggregateFields(enc, &integers), size = 0;
                NSGetSizeAndAlignment(enc, &size, NULL);
                words = fields ? (int)fields : (int)((size + 3) / 4);
            } else if (!IsFloatEncoding(&base) && base != '@' && base != '#' &&
                       base != ':' && base != '^' && base != '*') {
                intArg[i] = GuestArg(vm, pi);
                intKind[i] = base;
            }
            pi += words;
        }
    }
    auto LengthHint = [&](NSUInteger i) -> size_t {
        for (NSUInteger j = i + 1; j < argc; j++) {
            if (!intKind[j]) continue;
            uint32_t v = intArg[j];
            if (v >= 1 && v <= (1u << 20)) return v;
        }
        return 0;
    };
    if(GuestHasStopRequest(vm))return NO;

    for (NSUInteger i = 2; i < argc; i++) {
        const char *enc = [sig getArgumentTypeAtIndex:i];
        if (!enc || !enc[0]) {
            uint64_t zero = 0;
            [inv setArgument:&zero atIndex:i];
            continue;
        }
        char base = enc[0];
        if (base == 'r') base = enc[1] ? enc[1] : enc[0];
        if (base == 'n' || base == 'N' || base == 'o' || base == 'O' || base == 'R' || base == 'V')
            base = enc[1] ? enc[1] : enc[0];

        if (IsFloatEncoding(&base)) {
            // The original is built -mfloat-abi=softfp: a call to glColor4f
            // starts with `vmov r0, s2 / vmov r1, s4 / vmov r2, s30 / vmov r3, s20`,
            // so floats and doubles travel in the *core* registers, in the same
            // r0-r3-then-stack stream as integers.  Reading them out of s0-s15
            // handed every host method the wrong numbers.
            if (base == 'f' || (base == 'd' && IsCGFloatSelector(sel))) {
                uint32_t w = GuestArg(vm, intIndex++);
                float f;
                memcpy(&f, &w, sizeof(f));
                if (base == 'd') {
                    double widened = f;
                    [inv setArgument:&widened atIndex:i];
                } else [inv setArgument:&f atIndex:i];
            } else {
                uint32_t lo = GuestArg(vm, intIndex), hi = GuestArg(vm, intIndex + 1);
                intIndex += 2;
                uint64_t bits = ((uint64_t)hi << 32) | lo;
                double dd;
                memcpy(&dd, &bits, sizeof(dd));
                [inv setArgument:&dd atIndex:i];
            }
            continue;
        }

        if (base == '{' || base == '(' || base == '[') {
            NSUInteger hostSize = 0;
            NSGetSizeAndAlignment(enc, &hostSize, NULL);
            BOOL integers = NO;
            NSUInteger fields = AggregateFields(enc, &integers);
            NSUInteger guestSize = fields ? fields * 4 : hostSize;
            std::vector<uint32_t> words((guestSize + 3) / 4, 0);
            for (NSUInteger w = 0; w < words.size(); w++)
                words[w] = GuestArg(vm, intIndex + (int)w);
            intIndex += (int)words.size();
            std::vector<uint8_t> host(MAX(hostSize, (NSUInteger)1), 0);
            if (fields) ExpandAggregate(words.data(), host.data(), fields, integers);
            else if (guestSize) memcpy(host.data(), words.data(), guestSize);
            [inv setArgument:host.data() atIndex:i];
            continue;
        }

        uint32_t gva = GuestArg(vm, intIndex);
        intIndex++;

        if (base == 'q' || base == 'Q' || base == 'l' || base == 'L') {
            uint64_t wide = (base == 'q' || base == 'l') ? (uint64_t)(int64_t)(int32_t)gva : gva;
            if (strstr(sel_getName(sel), "LongLong"))
                wide = (uint64_t)gva | ((uint64_t)GuestArg(vm, intIndex++) << 32);
            [inv setArgument:&wide atIndex:i];
            continue;
        }

        if (base == '@' || base == '#' || base == ':' || base == '^' || base == '*') {
            if(GuestObjCMetadataWord(gva)){GuestRequestFault(vm);GuestSetRet(vm,0);return NO;}
            void *p = NULL;
            if (base == '@') {
                id obj = HostObjectArgument(vm, gva);
                if (!obj) {
                    NSString *cf = GuestObjCCFString(vm, gva);
                    if (cf) obj = cf;
                }
                id mapped=AS6ResourceReadObjectArgument(target,sel,i,obj);
                if(mapped!=obj){if(!resourceOwners)resourceOwners=[NSMutableArray new];if(mapped)[resourceOwners addObject:mapped];obj=mapped;}
                p = (__bridge void *)obj;
                if (obj) [retained addObject:obj];
            } else if (base == '#') {
                p = (__bridge void *)GuestObjCUnwrapClass(vm, gva);
            } else if (base == ':') {
                p = (void *)GuestObjCSelFromGuest(vm, gva);
            } else if (base == '*') {
                size_t existing = gva ? GuestStrLen(vm, gva, 4096) : 0;
                if (existing) {
                    std::vector<uint8_t> buf(existing + 1, 0);
                    GuestRead(vm, gva, buf.data(), existing);
                    pool.push_back(std::move(buf));
                    p = pool.back().data();
                } else {
                    PointerBack back;
                    p = BackGuestPointer(vm, gva, "^c", LengthHint(i), &back, pool);
                    if (back.guest && back.guestSize) backed.push_back(back);
                }
            } else {
                PointerBack back;
                if(PointeeBase(enc)=='@'&&PointerObjectArray(sel)) {
                    GuestTrace(vm,@"[objc] object-array pointer needs explicit count contract: %@ argument %lu",NSStringFromSelector(sel),(unsigned long)i);
                    GuestRequestFault(vm);return NO;
                }
                p = BackGuestPointer(vm, gva, enc, LengthHint(i), &back, pool,
                                     PointerArgumentFlow(enc,sel,i),retained);
                if (back.guest && back.guestSize) backed.push_back(back);
                if (!p && gva) {
                    GuestTrace(vm, @"[objc] %@ %@ argument %lu is an unmappable guest pointer %#x",
                               NSStringFromClass(cls) ?: @"?", NSStringFromSelector(sel),
                               (unsigned long)i, gva);
                }
            }
            [inv setArgument:&p atIndex:i];
            continue;
        }

        // Remaining narrow scalars retain their guest bit pattern.
        uint8_t raw[8] = {0};
        uint32_t word = gva;
        memcpy(raw, &word, MIN(sizeof(word), sizeof(raw)));
        [inv setArgument:raw atIndex:i];
    }

    if(GuestHasStopRequest(vm))return NO;
    // A mis-marshalled argument must never take the process down: report the
    // exact host message and let the guest see a nil reply instead.
// BEGIN AS6_PASSIVE_BEFORE_INVOKE
    const bool passivePresent = PassivePresentMatches(target, sel, sig);
    const uint64_t passivePresentBegin = passivePresent ? mach_absolute_time() : 0;
// END AS6_PASSIVE_BEFORE_INVOKE
    @try {
        [inv invokeWithTarget:target];
    } @catch (NSException *e) {
        GuestTrace(vm, @"[objc] host -[%@ %@] failed: %@ %@",
                   NSStringFromClass(cls) ?: @"?", NSStringFromSelector(sel),
                   e.name ?: @"?", e.reason ?: @"?");
        GuestSetRet(vm, 0);
        return YES;
    }

// BEGIN AS6_PASSIVE_AFTER_INVOKE
    const uint64_t passivePresentEnd = passivePresent ? mach_absolute_time() : 0;
// END AS6_PASSIVE_AFTER_INVOKE
    if(GuestHasStopRequest(vm))return NO;
    FlushPointerBacks(vm, backed);

    const char *retType = sig.methodReturnType;
    char rbase = retType[0];
    if (rbase == 'r') rbase = retType[1] ? retType[1] : retType[0];
    if (rbase == 'v') return YES;

    // One oversized, always-valid destination for every return shape.  Asking
    // NSInvocation to write a 64-bit or struct result into a 4-byte slot is
    // what used to trap inside CoreFoundation.
    alignas(16) uint8_t retBuf[64] = {0};
    NSUInteger retSize = 0;
    NSGetSizeAndAlignment(retType, &retSize, nullptr);
    if (retSize == 0 || retSize > sizeof(retBuf)) retSize = sizeof(retBuf);
    @try {
        [inv getReturnValue:retBuf];
    } @catch (NSException *e) {
        GuestTrace(vm, @"[objc] host -[%@ %@] return read failed: %@",
                   NSStringFromClass(cls) ?: @"?", NSStringFromSelector(sel),
                   e.reason ?: e.name ?: @"?");
        GuestSetRet(vm, 0);
        return YES;
    }

// BEGIN AS6_PASSIVE_OBSERVE_RETURN
    if (passivePresent) PassivePresentReturned(target, retBuf[0] != 0, passivePresentBegin, passivePresentEnd);
// END AS6_PASSIVE_OBSERVE_RETURN
    if (rbase == '@') {
        void *result = nullptr;
        memcpy(&result, retBuf, MIN(retSize, sizeof(result)));
        GuestSetRet(vm, GuestObjCWrap(vm, (__bridge id)result));
        return YES;
    }
    if (rbase == '#') {
        void *result = nullptr;
        memcpy(&result, retBuf, MIN(retSize, sizeof(result)));
        GuestSetRet(vm, GuestObjCWrapClass(vm, (__bridge Class)result));
        return YES;
    }
    if (rbase == '*') {
        // A host char* is meaningless to the guest: hand back a guest copy.
        char *text = nullptr;
        memcpy(&text, retBuf, MIN(retSize, sizeof(text)));
        GuestSetRet(vm, text ? GuestWriteBackBytes(vm, text, strlen(text)) : 0);
        return YES;
    }
    if (rbase == '^') {
        void *pointer = nullptr;
        memcpy(&pointer, retBuf, MIN(retSize, sizeof(pointer)));
        GuestSetRet(vm, HLEWrapOpaque(vm, pointer));
        return YES;
    }
    if (rbase == ':') {
        SEL selector = nullptr;
        memcpy(&selector, retBuf, MIN(retSize, sizeof(selector)));
        GuestSetRet(vm, selector ? GuestObjCGuestSelNamed(vm, sel_getName(selector)) : 0);
        return YES;
    }
    if (rbase == 'f') {
        float f = 0;
        if (retSize >= sizeof(f)) memcpy(&f, retBuf, sizeof(f));
        GuestSetRetF(vm, f);
        return YES;
    }
    if (rbase == 'd') {
        double dd = 0;
        if (retSize >= sizeof(dd)) memcpy(&dd, retBuf, sizeof(dd));
        if (IsCGFloatSelector(sel)) GuestSetRetF(vm, (float)dd);
        else GuestSetRetD(vm, dd);
        return YES;
    }
    if (rbase == '{' || rbase == '(') {
        // Struct return: objc_msgSend_stret's destination.  r0 now holds the
        // receiver, so the trampoline parked the buffer pointer beforehand.
        gva_t dst = g_stretDst;
        BOOL integers = NO;
        NSUInteger fields = AggregateFields(retType, &integers);
        if (fields) {
            uint32_t guest[6] = {};
            NarrowAggregate(retBuf, guest, fields, integers);
            if (stret && dst) GuestWrite(vm, dst, guest, fields * 4);
            else GuestSetRet(vm, guest[0]);
        } else if (stret && dst) GuestWrite(vm, dst, retBuf, MIN(retSize, (NSUInteger)64));
        return YES;
    }
    uint32_t scalar = 0;
    memcpy(&scalar, retBuf, MIN(retSize, (NSUInteger)sizeof(scalar)));
    GuestSetRet(vm, scalar);
    return YES;
}


BOOL GuestSendToSuperclass(GuestVM *vm, gva_t recv, gva_t selGuest, Class hostSuper) {
    if (!hostSuper) return NO;
    SEL sel = GuestObjCSelFromGuest(vm, selGuest);
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    if (!sel) return NO;
    const char *name = sel_getName(sel);
    UIView *shadow = GuestObjCShadow(vm, recv);
    // A super-init on an already-constructed shadow succeeded as far as the
    // guest is concerned; returning nil there would abort its own -initWithCoder:.
    if (!strncmp(name, "init", 4)) {
        if (!strcmp(name, "initWithFrame:") && shadow) {
            shadow.frame = CGRectMake(GuestArgF(vm, 2), GuestArgF(vm, 3),
                                       GuestArgF(vm, 4), GuestArgF(vm, 5));
        }
        GuestSetRet(vm, recv);
        return YES;
    }
    if (!shadow) { GuestSetRet(vm, 0); return YES; }
    Method m = class_getInstanceMethod(object_getClass(shadow), sel);
    if (!m) m = class_getInstanceMethod(hostSuper, sel);
    if (!m) { GuestSetRet(vm, 0); return YES; }
    return HostSend(vm, shadow, sel, NO);
}

// --- message dispatch ------------------------------------------------------

BOOL GuestObjCSend(GuestVM *vm, gva_t recv, gva_t selGuest, BOOL stret) {
    const gva_t savedStretDestination=g_stretDst;
    if(!stret)g_stretDst=0;
    @try {
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    if(GuestObjCMetadataWord(recv)||GuestObjCMetadataWord(selGuest)){GuestRequestFault(vm);return NO;}
    if (!recv) { GuestSetRet(vm, 0); return YES; }
    if (HostSendTracingEnabled()) {
        // A guest SEL *is* the address of its name, so read the name in place.
        static char nameBuf[96];
        nameBuf[0] = 0;
        const char *nm = "?";
        if (selGuest < GUEST_HOST_SEL_BASE) {
            if (GuestRead(vm, selGuest, nameBuf, sizeof(nameBuf) - 1)) nm = nameBuf;
        } else {
            SEL hs = (SEL)(uintptr_t)(selGuest - GUEST_HOST_SEL_BASE);
            nm = hs ? sel_getName(hs) : "?";
        }
        uint32_t caller = GuestLR(vm) & ~1u;
        NSString *sym = GuestSymbolAt(caller);
        char line[256];
        snprintf(line, sizeof(line), "== send recv=%#x%s sel=%s  from %s", recv,
                 GuestIsHostClass(recv) ? "(hostclass)" :
                 GuestIsHostObject(recv) ? "(hostobj)" : "", nm,
                 sym.UTF8String ?: "?");
        GuestRawLog(line);
    }
    SEL sel = GuestObjCSelFromGuest(vm, selGuest);
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    static as6_gameplay_backing::State gameplayBackingState;
    if (recv == GuestGLView() && !as6_gameplay_backing::beforeMessage(vm, recv, sel, gameplayBackingState)) {
        GuestRequestFault(vm); GuestSetRet(vm, 0); return NO;
    }
    static as6_shared_menu_warm::State sharedMenuWarmState;
    if (recv == GuestGLView() && !as6_shared_menu_warm::beforeMessage(vm, recv, sel, sharedMenuWarmState)) {
        GuestRequestFault(vm); GuestSetRet(vm, 0); return NO;
    }
    if (!sel) {
        GuestTrace(vm, @"[objc] msgSend with unreadable selector %#x", selGuest);
        GuestSetRet(vm, 0);
        return YES;
    }

    if (GuestIsHostObject(recv) || GuestIsHostClass(recv)) {
        // The guest's reference counting is meaningless across the bridge: the
        // handle table owns the host object, so letting -release reach it frees
        // memory we are still holding.  Answer these locally.
        const char *selName = sel ? sel_getName(sel) : nullptr;
        if (selName) {
            if (strcmp(selName, "release") == 0 || strcmp(selName, "autorelease") == 0 ||
                strcmp(selName, "drain") == 0) {
                if (strcmp(selName, "autorelease") != 0 && GuestIsHostObject(recv)) {
                    id object = GuestObjCUnwrap(vm, recv);
                    if ([object isKindOfClass:[PortAutoreleasePool class]]) {
                        g_objects.erase(recv);
                        g_objectHandles.erase((__bridge void *)object);
                        CFRelease((__bridge CFTypeRef)object);
                        GuestSetRet(vm, 0);
                        return YES;
                    }
                }
                GuestSetRet(vm, recv);
                return YES;
            }
            if (strcmp(selName, "retain") == 0) { GuestSetRet(vm, recv); return YES; }
            if (strcmp(selName, "retainCount") == 0) { GuestSetRet(vm, 1); return YES; }
            if (strcmp(selName, "zone") == 0) { GuestSetRet(vm, 0); return YES; }
        }
        id target = GuestIsHostClass(recv)
                        ? (id)GuestObjCUnwrapClass(vm, recv)
                        : GuestObjCUnwrap(vm, recv);
        if (!target) { GuestSetRet(vm, 0); return YES; }
        if (GuestMotionOverride(vm, target, sel)) return YES;
        if (GuestDeviceOverride(vm, target, sel)) return YES;
        if (GuestScreenOverride(vm, target, sel)) return YES;
        if(target==(id)[NSTimer class]&&!strcmp(sel_getName(sel),"scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:")) {
            const auto timerTarget=GuestArg(vm,4),timerSelector=GuestArg(vm,5),timerInfo=GuestArg(vm,6);
            (void)GuestArg(vm,7); // Preflight the final stack word before any schedule.
            if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
            if(GuestObjCMetadataWord(timerTarget)||GuestObjCMetadataWord(timerSelector)||GuestObjCMetadataWord(timerInfo)) {GuestRequestFault(vm);GuestSetRet(vm,0);return NO;}
        }
        const BOOL timerHandled=GuestTimerOverride(vm,target,sel);
        if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
        if(timerHandled)return YES;
        if (GuestMediaOverride(vm, target, sel)) return YES;
        if (HostStringBridge(vm, target, sel, selName)) return YES;
        if (HostSend(vm, target, sel, stret)) return YES;
        GuestTrace(vm, @"[objc] no host method -[%@ %@]",
                   NSStringFromClass([target class]) ?: @"?", NSStringFromSelector(sel));
        GuestSetRet(vm, 0);
        return YES;
    }

    // A guest __cfstring literal has no usable isa until dyld binds it, so
    // message it as the NSString it actually is.
    if (!GuestIsHostObject(recv) && !GuestIsHostClass(recv)) {
        NSString *cf = GuestObjCCFString(vm, recv);
        if (cf) {
            if (HostStringBridge(vm, cf, sel, sel_getName(sel))) return YES;
            if (HostSend(vm, cf, sel, stret)) return YES;
            GuestTrace(vm, @"[objc] no host method for NSString literal %@ %@",
                       [cf length] > 48 ? [cf substringToIndex:48] : cf,
                       NSStringFromSelector(sel));
            GuestSetRet(vm, 0);
            return YES;
        }
    }

    // Guest receiver. isa tells us whether this is an instance or a class.
    gva_t isa = GuestReadU32(vm, recv);
    BOOL receiverIsClass = LocalRegistry(vm).classNames.count(recv) != 0;
    gva_t searchRoot = receiverIsClass ? isa : isa;  // instance -> class, class -> metaclass
    gva_t imp = FindGuestMethodImp(vm, searchRoot, sel);
    if(GuestHasStopRequest(vm)){GuestSetRet(vm,0);return NO;}
    if (!imp) {
        UIView *shadow = GuestObjCShadow(vm, recv);
        if (shadow && HostSend(vm, shadow, sel, stret)) return YES;
        NSString *clsName = GuestObjCNameForClass(vm, recv) ?: GuestObjCNameForMetaclass(vm, recv);
        GuestTrace(vm, @"[objc] unresolved -[%@ %@] (recv=%#x isa=%#x)",
                   clsName ?: @"?", NSStringFromSelector(sel), recv, isa);
        GuestSetRet(vm, 0);
        return YES;
    }
    uint32_t args[4] = {recv, selGuest, GuestArg(vm, 2), GuestArg(vm, 3)};
    // Game start-up runs through millions of instructions inside a single
    // message; a small budget silently truncates it (see GuestCall).
    uint32_t ret = GuestCall(vm, imp | (imp & 1), args, 4, 2000000000ull);
    GuestSetRet(vm, ret);
    return YES;
    } @finally {g_stretDst=savedStretDestination;}
}
