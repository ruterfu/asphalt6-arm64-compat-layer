// UIKit pieces the original armv7 binary cannot get from the arm64 system.
// The important one is -[UIApplicationMain]: the 2011 app had UIKit load
// MainWindow.nib, whose File's Owner is Asphalt6AppDelegate and whose root view
// is EAGLView. iOS 27 cannot load that nib, so the host replays exactly the
// object graph and message sequence the nib archived -- the delegate, the
// window and the GL view are all the *original* guest classes.

#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"

// No direct GL API is used here; original view setup remains in its own bridge.
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <atomic>
#import <errno.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#include <chrono>
#include "SafeAreaCanvasGeometry.hpp"
#include "OriginalUIHostMetrics.hpp"
#include "ScreenProfile.h"
#include <cmath>

static gva_t g_guestAppDelegate = 0;
static UIWindow *g_hostWindow = nil;
static gva_t g_glView = 0;
static BOOL g_guestTimerActive = NO;
static NSHashTable<NSTimer *> *g_renderTimers;

// Both original render entry paths run on the main thread. Measure completed
// original draw callbacks; loading callbacks count too, so this is not FPS.
static uint64_t g_renderCallbacks=0,g_renderNanoseconds=0,g_renderMaxNanoseconds=0;
static uint64_t g_renderOver16ms=0,g_renderOver100ms=0;
struct OriginalRenderTiming {
    bool enabled;
    std::chrono::steady_clock::time_point start;
    explicit OriginalRenderTiming(bool value):enabled(value){
        const int savedErrno=errno;start=std::chrono::steady_clock::now();errno=savedErrno;
    }
    void finish(){
        if(!enabled)return;
        enabled=false;
        const int savedErrno=errno;
        const uint64_t elapsed=std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now()-start).count();
        ++g_renderCallbacks;g_renderNanoseconds+=elapsed;
        if(elapsed>g_renderMaxNanoseconds)g_renderMaxNanoseconds=elapsed;
        if(elapsed>16666667)++g_renderOver16ms;
        if(elapsed>100000000)++g_renderOver100ms;
        errno=savedErrno;
    }
    ~OriginalRenderTiming(){finish();}
};
extern "C" NSDictionary *GuestFramePerformanceSnapshot(void) {
    return @{@"completed_draw_callbacks":@(g_renderCallbacks),
        @"draw_nanoseconds":@(g_renderNanoseconds),@"max_draw_nanoseconds":@(g_renderMaxNanoseconds),
        @"draws_over_16ms":@(g_renderOver16ms),@"draws_over_100ms":@(g_renderOver100ms)};
}

gva_t GuestAppDelegate(void) { return g_guestAppDelegate; }
gva_t GuestGLView(void) { return g_glView; }

// Private, bounded observation of real Skip touches. Keep this out of the
// shared headers so a diagnostic does not invalidate unrelated native objects.
extern "C" uint32_t GuestTraceNativeSkipTouches(UIWindow *, UIEvent *, uint32_t, BOOL);
@interface PortGameWindow : UIWindow
@end
@implementation PortGameWindow
- (void)sendEvent:(UIEvent *)event {
    const uint32_t phases = GuestTraceNativeSkipTouches(self, event, 0, NO);
    [super sendEvent:event];
    if (phases) GuestTraceNativeSkipTouches(self, event, phases, YES);
}
@end

// Private native controls already reparented by GuestPlaceOriginalSkipControls.
// Reading this native getter does not enter the guest VM or take its lock.
@protocol AS6PresentationControlsOwner <NSObject>
@property(nonatomic, readonly) NSArray<UIView *> *presentationControls;
@end

static as6canvas::Rect CanvasRect(CGRect value) {
    return {value.origin.x, value.origin.y, value.size.width, value.size.height};
}
static CGRect UIKitCanvasRect(as6canvas::Rect value) {
    return CGRectMake(value.x, value.y, value.width, value.height);
}
static AS6OriginalUIHostMetrics g_uiHostMetrics;
static BOOL g_uiHostMetricsValid = NO;
static __weak UIView *g_uiHostMetricsView;
static void LogOriginalUIHostMetricsFailure(const char *reason, UIView *view, UIWindow *window) {
    static unsigned logs;
    if (logs >= 8) return;
    ++logs;
    char line[256];
    snprintf(line,sizeof(line),"[original-ui-metrics] unavailable reason=%s main=%d view=%d attached=%d scene=%d orientation=%ld",
        reason,int(NSThread.isMainThread),int(view!=nil),int(view && view.window==window),
        int(window.windowScene!=nil),(long)window.windowScene.interfaceOrientation);
    GuestRawLog(line);
}
static bool SameOriginalUIHostGeometry(const AS6OriginalUIHostMetrics &a,
                                      const AS6OriginalUIHostMetrics &b) {
    if (a.interfaceOrientation != b.interfaceOrientation ||
        std::fabs(a.windowScreenScale-b.windowScreenScale)>1e-9) return false;
    const auto same = [](const double *left, const double *right, unsigned count) {
        for (unsigned i=0; i<count; ++i)
            if (std::fabs(left[i]-right[i]) > 1e-9) return false;
        return true;
    };
    return same(a.windowBoundsPoints,b.windowBoundsPoints,4) &&
           same(a.safeNormalizedRect,b.safeNormalizedRect,4) &&
           same(a.originalViewBoundsPoints,b.originalViewBoundsPoints,4) &&
           same(a.windowToOriginalView,b.windowToOriginalView,6);
}
static void PublishOriginalUIHostMetrics(UIView *view, UIWindow *window, as6canvas::Rect safe) {
    const int savedErrno = errno;
    // ReplayMainWindowNib alone binds this to the original EAGL surface.
    // Subsequent native Skip/overlay views must never replace the source.
    if (view != g_uiHostMetricsView) { errno=savedErrno; return; }
    if (!NSThread.isMainThread || !window.windowScene || view.window != window ||
        !UIInterfaceOrientationIsLandscape(window.windowScene.interfaceOrientation) ||
        !as6canvas::positive(safe) || !as6canvas::positive(CanvasRect(window.bounds))) {
        g_uiHostMetricsValid=NO; LogOriginalUIHostMetricsFailure("view-window-scene",view,window); errno=savedErrno; return;
    }
    AS6OriginalUIHostMetrics next{};
    next.interfaceOrientation=(std::int32_t)window.windowScene.interfaceOrientation;
    next.windowScreenScale=window.screen.scale;
    if(!std::isfinite(next.windowScreenScale)||next.windowScreenScale<=0) {
        g_uiHostMetricsValid=NO; LogOriginalUIHostMetricsFailure("screen-scale",view,window); errno=savedErrno; return;
    }
    const CGRect bounds=window.bounds, original=view.bounds;
    const double full[4]={bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height};
    const double source[4]={original.origin.x,original.origin.y,original.size.width,original.size.height};
    for(unsigned i=0;i<4;++i){next.windowBoundsPoints[i]=full[i];next.originalViewBoundsPoints[i]=source[i];}
    next.safeNormalizedRect[0]=(safe.x-bounds.origin.x)/bounds.size.width;
    next.safeNormalizedRect[1]=(safe.y-bounds.origin.y)/bounds.size.height;
    next.safeNormalizedRect[2]=safe.width/bounds.size.width;
    next.safeNormalizedRect[3]=safe.height/bounds.size.height;
    // Full-window baselines avoid subtracting nearly equal, float-rounded
    // UIKit points one point apart. Use the live UIKit inverse unchanged.
    const CGPoint zero=[view convertPoint:bounds.origin fromView:window];
    const CGPoint edgeX=[view convertPoint:CGPointMake(CGRectGetMaxX(bounds),CGRectGetMinY(bounds)) fromView:window];
    const CGPoint edgeY=[view convertPoint:CGPointMake(CGRectGetMinX(bounds),CGRectGetMaxY(bounds)) fromView:window];
    const CGPoint edgeXY=[view convertPoint:CGPointMake(CGRectGetMaxX(bounds),CGRectGetMaxY(bounds)) fromView:window];
    const double a=(edgeX.x-zero.x)/bounds.size.width, b=(edgeX.y-zero.y)/bounds.size.width;
    const double c=(edgeY.x-zero.x)/bounds.size.height, d=(edgeY.y-zero.y)/bounds.size.height;
    const double inverse[6]={a,b,c,d,zero.x-a*bounds.origin.x-c*bounds.origin.y,
        zero.y-b*bounds.origin.x-d*bounds.origin.y};
    const double error=std::hypot(edgeXY.x-(edgeX.x+edgeY.x-zero.x),edgeXY.y-(edgeX.y+edgeY.y-zero.y));
    if (!std::isfinite(error) || error>0.001 || !std::isfinite(a*d-b*c) || std::fabs(a*d-b*c)<1e-12) {
        g_uiHostMetricsValid=NO; LogOriginalUIHostMetricsFailure("non-affine-or-singular",view,window); errno=savedErrno; return;
    }
    for(unsigned i=0;i<6;++i){
        if(!std::isfinite(inverse[i])){g_uiHostMetricsValid=NO;LogOriginalUIHostMetricsFailure("non-finite-inverse",view,window);errno=savedErrno;return;}
        next.windowToOriginalView[i]=inverse[i];
    }
    const bool same=g_uiHostMetricsValid && g_uiHostMetricsView==view && SameOriginalUIHostGeometry(g_uiHostMetrics,next);
    next.revision=same?g_uiHostMetrics.revision:g_uiHostMetrics.revision+1;
    if(!next.revision)next.revision=1;
    g_uiHostMetrics=next;g_uiHostMetricsView=view;g_uiHostMetricsValid=YES;
    static unsigned readyLogs;
    if(!same && readyLogs<16){
        ++readyLogs;
        char line[256];
        snprintf(line,sizeof(line),"[original-ui-metrics] ready revision=%llu orientation=%d inverse-error=%.6f safe=(%.3f %.3f %.3f %.3f)",
            (unsigned long long)next.revision,next.interfaceOrientation,error,next.safeNormalizedRect[0],
            next.safeNormalizedRect[1],next.safeNormalizedRect[2],next.safeNormalizedRect[3]);
        GuestRawLog(line);
    }
    errno=savedErrno;
}
extern "C" bool GuestCopyOriginalUIHostMetrics(AS6OriginalUIHostMetrics *out) {
    const int savedErrno=errno;
    if (out && NSThread.isMainThread && g_uiHostMetricsView && g_hostWindow) {
        const CGRect bounds=g_hostWindow.bounds;
        const UIEdgeInsets insets=g_hostWindow.safeAreaInsets;
        const auto safe=as6canvas::safeFrame(CanvasRect(bounds),CanvasRect(g_hostWindow.safeAreaLayoutGuide.layoutFrame),
            {insets.top,insets.left,insets.bottom,insets.right});
        // Observe current ancestor transforms as well as bounds/insets. Four
        // native point conversions never enter GuestVM; identical geometry
        // keeps the revision and the engine mapping cache unchanged.
        PublishOriginalUIHostMetrics(g_uiHostMetricsView,g_hostWindow,safe);
    }
    const bool ready=out && NSThread.isMainThread && g_uiHostMetricsValid &&
        g_hostWindow.windowScene && g_uiHostMetricsView.window==g_hostWindow &&
        std::isfinite(g_uiHostMetrics.windowScreenScale) && g_uiHostMetrics.windowScreenScale>0 &&
        std::fabs(g_hostWindow.screen.scale-g_uiHostMetrics.windowScreenScale)<=1e-9 &&
        (std::int32_t)g_hostWindow.windowScene.interfaceOrientation==g_uiHostMetrics.interfaceOrientation &&
        CGRectEqualToRect(g_hostWindow.bounds,CGRectMake(g_uiHostMetrics.windowBoundsPoints[0],
            g_uiHostMetrics.windowBoundsPoints[1],g_uiHostMetrics.windowBoundsPoints[2],g_uiHostMetrics.windowBoundsPoints[3])) &&
        CGRectEqualToRect(g_uiHostMetricsView.bounds,CGRectMake(g_uiHostMetrics.originalViewBoundsPoints[0],
            g_uiHostMetrics.originalViewBoundsPoints[1],g_uiHostMetrics.originalViewBoundsPoints[2],g_uiHostMetrics.originalViewBoundsPoints[3]));
    if(ready)*out=g_uiHostMetrics;
    errno=savedErrno;return ready;
}

// Width stretch of the original landscape canvas (portrait bounds w x h shown
// as h x w) to the full window; read by the perspective policy each frame.
static std::atomic<double> g_canvasHorizontalStretch{1.0};
// A Plain screen is only scaled: no consumer of the stretch adapts anything.
extern "C" double AS6CanvasHorizontalStretch(void) {
    return AS6ScreenProfile() == AS6ScreenPlain ? 1.0 : g_canvasHorizontalStretch.load(std::memory_order_relaxed);
}
static std::atomic<int> g_screenProfile{-1};
extern "C" int AS6ScreenProfileDetect(void) {
    int profile = g_screenProfile.load(std::memory_order_relaxed);
    if (profile >= 0) return profile;
    const CGSize size = UIScreen.mainScreen.bounds.size;
    const CGFloat longSide = MAX(size.width, size.height), shortSide = MIN(size.width, size.height);
    const double ratio = shortSide > 0 ? longSide / shortSide : 0;
    profile = ratio >= 1.9 ? AS6ScreenWide : ratio >= 1.7 ? AS6ScreenSixteenNine : AS6ScreenPlain;
    g_screenProfile.store(profile, std::memory_order_relaxed);
    fprintf(stderr, "[screen] %.0fx%.0f ratio %.3f profile %s\n", longSide, shortSide, ratio,
            profile == AS6ScreenWide ? "wide (2.2:1)" : profile == AS6ScreenSixteenNine ? "16:9" : "plain (scaled only)");
    return profile;
}
extern "C" int AS6ScreenProfile(void) { const int p = g_screenProfile.load(std::memory_order_relaxed); return p < 0 ? AS6ScreenPlain : p; }
extern "C" BOOL AS6HDArtworkAvailable(void);
extern "C" int AS6ScreenShowsWideView(void) { return AS6ScreenProfile() != AS6ScreenPlain && AS6HDArtworkAvailable(); }
// The info page's Twitter entry: Gameloft's page on X, in the browser/X app.
extern "C" void AS6OpenGameloftX(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://x.com/gameloft"] options:@{} completionHandler:nil];
    });
}

static void LayoutOriginalView(UIView *view, UIWindow *window) {
    UIView *container = view.superview;
    if (!view || !window || !container || (container != window && container.window != window)) return;
    const UIEdgeInsets insets = window.safeAreaInsets;
    const auto safe = as6canvas::safeFrame(CanvasRect(window.bounds),
        CanvasRect(window.safeAreaLayoutGuide.layoutFrame),
        {insets.top, insets.left, insets.bottom, insets.right});
    // Keep the entire render surface full-window. Safe geometry is only for
    // selected native controls and the original-engine UI anchor adapter.
    if (!as6canvas::positive(CanvasRect(window.bounds))) return;
    const CGRect parentFull = [container convertRect:window.bounds fromView:window];
    const auto layout = as6canvas::layout(CanvasRect(view.bounds), CanvasRect(parentFull));
    if (!layout.valid) return;
    const CGSize source = view.bounds.size, full = window.bounds.size;
    if (source.width > 0 && source.height > 0 && full.width > full.height && full.height > 0)
        g_canvasHorizontalStretch.store((full.width / full.height) / (source.height / source.width),
                                        std::memory_order_relaxed);
    // Retain the established original quarter-turn and width/height scaling.
    // Bounds stay unchanged; UITouch locationInView: applies this exact inverse.
    const CGAffineTransform transform = CGAffineTransformMake(0, layout.b, layout.c, 0, 0, 0);
    const CGPoint center = CGPointMake(layout.center.x, layout.center.y);
    const BOOL changed = !CGAffineTransformEqualToTransform(view.transform, transform) ||
                         !CGPointEqualToPoint(view.center, center);
    if (!CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
    if (!CGPointEqualToPoint(view.center, center)) view.center = center;
    PublishOriginalUIHostMetrics(view,window,safe);
    const int savedErrno = errno;
    const char *trace = getenv("AS6_SAFE_AREA_LAYOUT_TRACE");
    static unsigned traces;
    static UIInterfaceOrientation lastOrientation = UIInterfaceOrientationUnknown;
    const UIInterfaceOrientation orientation = window.windowScene.interfaceOrientation;
    if (trace && !strcmp(trace, "1") && traces < 16 && (changed || orientation != lastOrientation)) {
        ++traces;
        lastOrientation = orientation;
        char line[768];
        snprintf(line, sizeof(line),
            "[full-window-canvas] orientation=%ld window=(%.2f,%.2f,%.2f,%.2f) "
            "insets=(%.2f,%.2f,%.2f,%.2f) safe=(%.2f,%.2f,%.2f,%.2f) "
            "source=(%.2f,%.2f,%.2f,%.2f) b=%.6f c=%.6f center=(%.2f,%.2f)",
            (long)orientation,window.bounds.origin.x,window.bounds.origin.y,
            window.bounds.size.width,window.bounds.size.height,
            insets.top,insets.left,insets.bottom,insets.right,safe.x,safe.y,safe.width,safe.height,
            view.bounds.origin.x,view.bounds.origin.y,view.bounds.size.width,view.bounds.size.height,
            layout.b,layout.c,layout.center.x,layout.center.y);
        GuestRawLog(line);
    }
    errno = savedErrno;
    if ([view respondsToSelector:@selector(presentationControls)]) {
        for (UIView *control in [(id<AS6PresentationControlsOwner>)view presentationControls]) {
            if (control.superview != window || !CGAffineTransformIsIdentity(control.transform)) continue;
            const auto placed = as6canvas::topTrailingControl(safe,
                {control.bounds.size.width, control.bounds.size.height});
            if (as6canvas::positive(placed) && !CGRectEqualToRect(control.frame, UIKitCanvasRect(placed)))
                control.frame = UIKitCanvasRect(placed);
        }
    }
}

@interface PortGameCanvas : UIViewController
@property(nonatomic, weak) UIView *originalView;
@end

@implementation PortGameCanvas
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (void)layoutOriginalCanvas {
    UIWindow *window = self.view.window;
    if (window && self.originalView) LayoutOriginalView(self.originalView, window);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutOriginalCanvas];
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self.view setNeedsLayout];
    [self layoutOriginalCanvas];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        [self layoutOriginalCanvas];
    }];
}
@end

BOOL GuestWindowAddSubview(GuestVM *vm, id window, gva_t guestSubview) {
    if (window != g_hostWindow) return NO;
    UIView *view = GuestObjCShadow(vm, guestSubview);
    if (!view) return NO;
    [g_hostWindow addSubview:view];
    LayoutOriginalView(view, g_hostWindow);
    GuestPlaceOriginalSkipControls(vm, guestSubview, g_hostWindow);
    GuestTrace(vm, @"[uikit] original root view %#x presented at %@", guestSubview,
               NSStringFromCGRect(view.bounds));
    return YES;
}

// BEGIN AS6_NATIVE_CADENCE_LIFECYCLE
@class PortFrameDriver;
static __weak GuestVM *g_uikitOwnerVM;
static PortFrameDriver *g_frameDriver;
static BOOL g_renderPaused=NO,g_renderRunning=NO,g_lifecycleRunning=NO,g_lifecycleReady=NO;
enum NativeApplicationPhase { NativeBooting,NativeActive,NativeInactive,NativeBackground,NativeForeground };
static NativeApplicationPhase g_applicationPhase=NativeBooting;

static BOOL NativeCallbackCandidate(GuestVM *vm) {
    return NSThread.isMainThread&&vm&&vm==g_uikitOwnerVM&&!GuestHasStopRequest(vm);
}
// Shared/loaded belong to the VM lifecycle lock, not a lock-free preflight.
static BOOL NativeCallbackOwner(GuestVM *vm) {
    return NativeCallbackCandidate(vm)&&vm==GuestVMShared()&&vm.loaded;
}
static BOOL NativeCallbackResult(GuestVM *vm) {
    if(!NativeCallbackOwner(vm))return NO;
    const auto result=GuestLastExecutionResult(vm);
    return result==GuestExecutionSuccess||result==GuestExecutionYielded;
}
// Caller holds the exact VM lock. CPU restore never clears permanent fault/halt.
static BOOL PreservedOriginalMessage(GuestVM *vm,gva_t receiver,gva_t selector,gva_t argument) {
    if(!NativeCallbackOwner(vm)||!receiver||!selector)return NO;
    GuestCpuSnapshot *snapshot=nullptr;BOOL saved=NO,ok=NO;
    const gva_t stret=GuestStretDestination();
    @try {
        auto result=GuestCPUAllocate(vm,&snapshot);
        if(result==GuestExecutionSuccess)result=GuestCPUSave(vm,snapshot);
        if(result!=GuestExecutionSuccess){GuestRequestFault(vm);return NO;}
        saved=YES;
        GuestSetReg(vm,0,receiver);GuestSetReg(vm,1,selector);GuestSetReg(vm,2,argument);GuestSetReg(vm,3,0);
        ok=GuestObjCSend(vm,receiver,selector,NO)&&NativeCallbackResult(vm);
    } @catch(NSException *error) {
        GuestTrace(vm,@"[uikit] native callback exception: %@ %@",error.name,error.reason);
        GuestRequestFault(vm);ok=NO;
    } @finally {
        if(saved&&GuestCPURestore(vm,snapshot)!=GuestExecutionSuccess){GuestRequestFault(vm);ok=NO;}
        GuestSetStretDestination(stret);
        if(snapshot)GuestCPUFree(snapshot);
    }
    return ok&&NativeCallbackOwner(vm);
}

@interface PortFrameDriver : NSObject {
@public
    __weak GuestVM *_vm;
    gva_t _view;
    BOOL _stop;
    CADisplayLink *_link;
}
- (void)tick;
- (void)invalidate;
- (void)setPaused:(BOOL)value;
@end
@implementation PortFrameDriver
- (void)invalidate {_stop=YES;[_link invalidate];_link=nil;}
- (void)setPaused:(BOOL)value {_link.paused=value;}
- (void)tick {
    GuestVM *vm=_vm;
    if(_stop||!NativeCallbackCandidate(vm)){[self invalidate];return;}
    if(g_renderPaused||g_renderRunning||!_view)return;
    g_guestTimerActive=NO;
    for(NSTimer *timer in g_renderTimers)if(timer.valid){g_guestTimerActive=YES;break;}
    if(g_guestTimerActive)return; // Preserve original render timers/selectors.
    g_renderRunning=YES;
    GuestLock(vm);
    @try {
        if(!NativeCallbackOwner(vm)){[self invalidate];return;}
        if(g_renderPaused)return;
        OriginalRenderTiming timing(true);
        const auto selector=GuestObjCGuestSelNamed(vm,"drawView");
        if(PreservedOriginalMessage(vm,_view,selector,0)){
            timing.finish();GuestNativeFrameDidComplete(vm,_view);
        } else timing.enabled=false;
    } @finally {GuestUnlock(vm);g_renderRunning=NO;}
}
@end

// BEGIN AS6_ORIGINAL_RENDER_TIMER_LINK
@class PortRenderTimerLink;
// The display link owns this proxy. Its weak owner avoids a target/link cycle.
@interface PortRenderTimerTickProxy : NSObject {
@public
    __weak PortRenderTimerLink *_owner;
}
- (void)tick;
@end
@interface PortRenderTimerLink : NSObject {
@public
    __weak GuestVM *_vm;
    __weak NSTimer *_timer;
    CADisplayLink *_link;
    BOOL _stop;
}
- (void)tick;
- (void)invalidate;
- (void)setPaused:(BOOL)value;
@end
static char g_renderTimerLinkKey;
@implementation PortRenderTimerTickProxy
- (void)tick {[_owner tick];}
@end
@implementation PortRenderTimerLink
- (void)dealloc {[_link invalidate];}
- (void)invalidate {
    if(_stop)return;
    _stop=YES;
    NSTimer *timer=_timer;_timer=nil;
    [_link invalidate];_link=nil;
    [timer invalidate];
    if(timer&&objc_getAssociatedObject(timer,&g_renderTimerLinkKey)==self)
        objc_setAssociatedObject(timer,&g_renderTimerLinkKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)setPaused:(BOOL)value {
    if(_stop||!_timer.valid){[self invalidate];return;}
    _link.paused=value;
}
- (void)tick {
    NSTimer *timer=_timer;
    GuestVM *vm=_vm;
    if(_stop||!timer.valid||!NativeCallbackCandidate(vm)){[self invalidate];return;}
    if(g_renderPaused||g_renderRunning)return;
    // The original selector, CPU preservation, VM lock and lifecycle guards
    // remain in this real timer's existing block. Never call drawView twice.
    [timer fire];
    if(!timer.valid||!NativeCallbackCandidate(vm))[self invalidate];
}
@end
static PortRenderTimerLink *NativeRenderTimerLink(NSTimer *timer) {
    return objc_getAssociatedObject(timer,&g_renderTimerLinkKey);
}
static void InvalidateNativeRenderTimer(NSTimer *timer) {
    PortRenderTimerLink *driver=NativeRenderTimerLink(timer);
    if(driver)[driver invalidate];else [timer invalidate];
}
static NSTimer *CreateNativeGuestTimer(GuestVM *vm,NSTimeInterval interval,BOOL repeats,
                                      BOOL renderTimer,void (^block)(NSTimer *)) {
    const NSTimeInterval seconds=interval>0.0005?interval:1.0/60.0;
    if(!renderTimer||!repeats||!NSThread.isMainThread)
        return [NSTimer scheduledTimerWithTimeInterval:seconds repeats:repeats block:block];
    // Keep an actual NSTimer as the guest-visible invalidate/valid/fire token.
    // It is unscheduled: only the display link fires its unchanged callback.
    NSTimer *timer=[NSTimer timerWithTimeInterval:seconds repeats:YES block:block];
    PortRenderTimerLink *driver=[PortRenderTimerLink new];
    driver->_vm=vm;driver->_timer=timer;
    PortRenderTimerTickProxy *proxy=[PortRenderTimerTickProxy new];proxy->_owner=driver;
    CADisplayLink *link=[CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick)];
    link.preferredFrameRateRange=CAFrameRateRangeMake(60,60,60);
    link.paused=g_renderPaused;driver->_link=link;
    // GuestObjCWrap retains the timer. The association owns the driver, whose
    // timer reference is weak; releasing the timer invalidates its link too.
    objc_setAssociatedObject(timer,&g_renderTimerLinkKey,driver,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return timer;
}
// END AS6_ORIGINAL_RENDER_TIMER_LINK

static void PauseNativeRender(BOOL paused) {
    g_renderPaused=paused;[g_frameDriver setPaused:paused];
    for(NSTimer *timer in g_renderTimers)[NativeRenderTimerLink(timer) setPaused:paused];
}
static void BindNativeRenderOwner(GuestVM *vm) {
    if(g_uikitOwnerVM==vm)return;
    [g_frameDriver invalidate];g_frameDriver=nil;
    for(NSTimer *timer in g_renderTimers)InvalidateNativeRenderTimer(timer);
    g_renderTimers=nil;g_guestTimerActive=NO;
    g_uiHostMetricsValid=NO;g_uiHostMetricsView=nil;
    g_uikitOwnerVM=vm;g_renderPaused=NO;g_renderRunning=NO;g_lifecycleRunning=NO;
    g_lifecycleReady=NO;g_applicationPhase=NativeBooting;
}

// Private C seam for SceneDelegate. It admits only the four original methods.
extern "C" BOOL GuestNativeApplicationLifecycle(GuestVM *vm,const char *selector) {
    if(!selector||!NativeCallbackCandidate(vm)||!g_lifecycleReady||!g_guestAppDelegate||g_lifecycleRunning)return NO;
    GuestLock(vm);BOOL ok=NO,ownsLifecycle=NO;
    @try {
        if(!NativeCallbackOwner(vm))return NO;
        const bool resign=!strcmp(selector,"applicationWillResignActive:");
        const bool background=!strcmp(selector,"applicationDidEnterBackground:");
        const bool foreground=!strcmp(selector,"applicationWillEnterForeground:");
        const bool active=!strcmp(selector,"applicationDidBecomeActive:");
        if(!resign&&!background&&!foreground&&!active)return NO;
        if((active&&g_applicationPhase==NativeActive)||(resign&&g_applicationPhase!=NativeActive)||
           (background&&g_applicationPhase==NativeBackground)||
           (foreground&&g_applicationPhase!=NativeBackground))return YES;
        if(resign||background)PauseNativeRender(YES);
        g_lifecycleRunning=YES;ownsLifecycle=YES;
        const auto sel=GuestObjCGuestSelNamed(vm,selector);
        const auto app=GuestObjCWrap(vm,UIApplication.sharedApplication);
        ok=app&&PreservedOriginalMessage(vm,g_guestAppDelegate,sel,app);
        if(ok){
            g_applicationPhase=resign?NativeInactive:background?NativeBackground:foreground?NativeForeground:NativeActive;
            if(active)PauseNativeRender(NO);
        }
    } @finally {if(ownsLifecycle)g_lifecycleRunning=NO;GuestUnlock(vm);}
    return ok;
}

static void SynchronizeNativeLifecycleAfterBoot(GuestVM *vm) {
    if(!NativeCallbackOwner(vm)||!g_lifecycleReady)return;
    // Initial Scene events can precede the asynchronous resource/boot work.
    // Preserve the one original bootstrap active callback, then bring the
    // original app to the real current physical state before enabling frames.
    const auto state=UIApplication.sharedApplication.applicationState;
    if(state!=UIApplicationStateActive)GuestNativeApplicationLifecycle(vm,"applicationWillResignActive:");
    if(state==UIApplicationStateBackground)GuestNativeApplicationLifecycle(vm,"applicationDidEnterBackground:");
}

void GuestStartFrameDriver(void) {
    GuestVM *vm=g_uikitOwnerVM;
    if(!NativeCallbackCandidate(vm)||!g_glView)return;
    GuestLock(vm);
    @try {
        if(!NativeCallbackOwner(vm))return;
        if(g_frameDriver&&!g_frameDriver->_stop&&g_frameDriver->_vm==vm)return;
        [g_frameDriver invalidate];
        g_frameDriver=[PortFrameDriver new];g_frameDriver->_vm=vm;g_frameDriver->_view=g_glView;
        CADisplayLink *link=[CADisplayLink displayLinkWithTarget:g_frameDriver selector:@selector(tick)];
        link.preferredFrameRateRange=CAFrameRateRangeMake(60,60,60);
        link.paused=g_renderPaused;g_frameDriver->_link=link;
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        GuestTrace(vm,@"[uikit] native fallback drawView driver requested 60Hz");
    } @finally {GuestUnlock(vm);}
}
// END AS6_NATIVE_CADENCE_LIFECYCLE

// The original drives itself from -[EAGLView startAnimation], which builds an
// NSTimer whose target is a *guest* object.  A host NSTimer cannot hold that,
// so the timer is rebuilt around a block that calls back into guest code.
BOOL GuestTimerOverride(GuestVM *vm, id target, SEL sel) {
    if (target != (id)[NSTimer class]) return NO;
    if (strcmp(sel_getName(sel),
               "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:") != 0)
        return NO;
    // softfp again: the double occupies r2:r3, which pushes the remaining
    // arguments onto the stack.
    uint32_t lo = GuestArg(vm, 2), hi = GuestArg(vm, 3);
    uint64_t bits = ((uint64_t)hi << 32) | lo;
    double interval;
    memcpy(&interval, &bits, sizeof(interval));
    gva_t target0 = GuestArg(vm, 4);
    gva_t selGuest = GuestArg(vm, 5);
    BOOL repeats = GuestArg(vm, 7) != 0;
    if (GuestIsHostObject(target0) || GuestIsHostClass(target0) || !target0) {
        GuestSetRet(vm, 0);
        return YES;
    }
    SEL guestSel = GuestObjCSelFromGuest(vm, selGuest);
    NSString *name = guestSel ? [NSString stringWithUTF8String:sel_getName(guestSel)] : nil;
    GuestTrace(vm, @"[uikit] guest NSTimer %#x -> -[%@] every %.4fs", target0,
               name ?: @"?", interval);
    BOOL renderTimer = target0 == g_glView &&
        ([name isEqualToString:@"drawView"] || [name isEqualToString:@"drawViewEventPump"]);
    gva_t recv = target0;
    __weak GuestVM *timerVM=vm;
    NSTimer *timer =
        CreateNativeGuestTimer(vm,interval,repeats,renderTimer,^(NSTimer *t) {
                                              GuestVM *v=timerVM;
                                              if(!NativeCallbackCandidate(v)){[t invalidate];return;}
                                              if(renderTimer&&(g_renderPaused||g_renderRunning))return;
                                              GuestLock(v);BOOL ownsRender=NO;
                                              @try {
                                                  if(!NativeCallbackOwner(v)){[t invalidate];return;}
                                                  if(renderTimer&&(g_renderPaused||g_renderRunning))return;
                                                  if(renderTimer){ownsRender=YES;g_renderRunning=YES;}
                                                  OriginalRenderTiming timing(renderTimer);
                                                  if(!repeats)[t invalidate];
                                                  const auto argument=GuestObjCWrap(v,t);
                                                  if(PreservedOriginalMessage(v,recv,selGuest,argument)){
                                                      timing.finish();if(renderTimer)GuestNativeFrameDidComplete(v,recv);
                                                  } else timing.enabled=false;
                                              } @finally {
                                                  if(ownsRender)g_renderRunning=NO;
                                                  GuestUnlock(v);
                                              }
                                          });
    if (renderTimer) {
        if (!g_renderTimers) g_renderTimers = [NSHashTable weakObjectsHashTable];
        [g_renderTimers addObject:timer];
        g_guestTimerActive = YES;
        if(NativeRenderTimerLink(timer))
            GuestTrace(vm,@"[uikit] original render NSTimer %#x -> -[%@] display-link=60Hz modes=common requested=%.6fs",
                       target0,name,interval);
    }
    GuestSetRet(vm, GuestObjCWrap(vm, timer));
    return YES;
}

// BEGIN AS6_SCREEN_SCALE_OBSERVATION
// Read-only startup observation after the original initWithCoder: has returned.
static void LogOriginalScreenScaleAfterInit(GuestVM *vm, gva_t guestView, UIView *shadow) {
    const int savedErrno = errno;
    const char *enabled = getenv("AS6_PASSIVE_TIMING");
    if (!enabled || strcmp(enabled, "1")) { errno = savedErrno; return; }
    static BOOL logged = NO;
    if (logged) { errno = savedErrno; return; }
    logged = YES;

    float guestScale = 0;
    int32_t backingWidth = 0, backingHeight = 0;
    const BOOL scaleOK = guestView && GuestRead(vm, guestView + 0x54, &guestScale, sizeof(guestScale));
    const BOOL widthOK = guestView && GuestRead(vm, guestView + 0x2c, &backingWidth, sizeof(backingWidth));
    const BOOL heightOK = guestView && GuestRead(vm, guestView + 0x30, &backingHeight, sizeof(backingHeight));
    char guestScaleText[48] = "read-failed", widthText[32] = "read-failed", heightText[32] = "read-failed";
    char viewScaleText[32] = "no-shadow", layerScaleText[32] = "no-layer";
    if (scaleOK) snprintf(guestScaleText, sizeof(guestScaleText), "%.9g", (double)guestScale);
    if (widthOK) snprintf(widthText, sizeof(widthText), "%d", (int)backingWidth);
    if (heightOK) snprintf(heightText, sizeof(heightText), "%d", (int)backingHeight);
    CALayer *layer = shadow ? shadow.layer : nil;
    if (shadow) snprintf(viewScaleText, sizeof(viewScaleText), "%.9g", (double)shadow.contentScaleFactor);
    if (layer) snprintf(layerScaleText, sizeof(layerScaleText), "%.9g", (double)layer.contentsScale);
    char line[512];
    snprintf(line, sizeof(line),
             "[screen-scale] after-original-init guest=%#x requested=%.1f shadow=%p view_scale=%s "
             "layer=%p layer_scale=%s guest_scale_ok=%d guest_scale=%s "
             "backing_width_ok=%d backing_width=%s backing_height_ok=%d backing_height=%s",
             guestView, GuestScreenBackingScale(), (__bridge void *)shadow, viewScaleText,
             (__bridge void *)layer, layerScaleText, (int)scaleOK, guestScaleText,
             (int)widthOK, widthText, (int)heightOK, heightText);
    GuestRawLog(line);
    errno = savedErrno;
}
// END AS6_SCREEN_SCALE_OBSERVATION

// Replayed from MainWindow.nib: the visible UIWindow holds one EAGLView whose
// frame is {{0,0},{320,480}} in the archived landscape layout.
static void ReplayMainWindowNib(GuestVM *vm, UIApplication *app) {
    gva_t eaglCls = GuestObjCClassNamed(vm, @"EAGLView");

    if (!g_hostWindow) {
        g_hostWindow = [[PortGameWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        g_hostWindow.backgroundColor = [UIColor blackColor];
    }

    if (eaglCls) {
        // alloc only: -initWithCoder: is the original's own initialiser and it is
        // the code that chooses GLES2 over GLES1, makes the context current and
        // builds the framebuffer.  Nothing here may stand in for it.
        gva_t glView = GuestObjCAllocInstance(vm, eaglCls);
        g_glView = glView;
        UIView *shadow = GuestObjCShadow(vm, glView);
        GuestTrace(vm, @"[nib] EAGLView guest instance at %#x, shadow %@", glView,
                   shadow ? NSStringFromClass([shadow class]) : @"<none>");
        if (shadow) {
            g_uiHostMetricsView=shadow;
            g_uiHostMetricsValid=NO;
            // Keep the original nib's portrait surface and let UIKit invert
            // this presentation transform for real UITouch coordinates.
            shadow.bounds = CGRectMake(0, 0, 320, 480);
            shadow.contentScaleFactor = GuestScreenBackingScale();
            shadow.autoresizingMask = UIViewAutoresizingNone;
            PortGameCanvas *canvas = [PortGameCanvas new];
            canvas.view.backgroundColor = [UIColor blackColor];
            canvas.originalView = shadow;
            g_hostWindow.rootViewController = canvas;
            [canvas.view addSubview:shadow];
            LayoutOriginalView(shadow, g_hostWindow);
            GuestTrace(vm, @"[nib] shadow layer is %@, scale %.1f",
                       NSStringFromClass([shadow.layer class]), shadow.contentScaleFactor);
        }
        gva_t sel = GuestObjCGuestSelNamed(vm, "initWithCoder:");
        GuestSetReg(vm, 0, glView);
        GuestSetReg(vm, 1, sel);
        GuestSetReg(vm, 2, 0);
        GuestObjCSend(vm, glView, sel, NO);
        GuestTrace(vm, @"[nib] guest -initWithCoder: returned %#x", GuestReg(vm, 0));
        LogOriginalScreenScaleAfterInit(vm, glView, shadow);
        GuestObjCSendName(vm, glView, "layoutSubviews");
    } else {
        GuestTrace(vm, @"[nib] EAGLView class not found in the original image");
    }

    [g_hostWindow makeKeyAndVisible];
}

HLE_DEFINE(hle_UIApplicationMain) {
    uint32_t argc = GuestArg(vm, 0);
    gva_t argv = GuestArg(vm, 1);
    gva_t principalGva = GuestArg(vm, 2);
    gva_t delegateGva = GuestArg(vm, 3);
    GuestTrace(vm, @"[uikit] UIApplicationMain(argc=%u, argv=%#x, principal=%#x, delegate=%#x)",
               argc, argv, principalGva, delegateGva);
    {
        char line[192];
        snprintf(line, sizeof(line), "== UIApplicationMain called from %#x (%s)",
                 GuestLR(vm) & ~1u, GuestSymbolAt(GuestLR(vm) & ~1u).UTF8String ?: "?");
        GuestRawLog(line);
    }
    (void)argc; (void)argv;

    // main() in the original loops around UIApplicationMain, so any guest call
    // that is cut short and lands back on main's link register re-enters here.
    // Booting twice only nests native execution() dozens of deep until the execution backend's
    // own jmp_buf gives out, so the second entry parks instead.
    static int uamDepth = 0;
    if (++uamDepth > 1) {
        GuestTrace(vm, @"!! UIApplicationMain re-entered (depth %d) from %#x (%@) -- parking",
                   uamDepth, GuestLR(vm) & ~1u,
                   GuestSymbolAt(GuestLR(vm) & ~1u));
        GuestDumpRecentTraps(vm, 40);
        GuestSetRet(vm, 0);
        GuestYieldToHostRunLoop(vm);
        return;
    }

    UIApplication *app = [UIApplication sharedApplication];

    // The original passes nil for both classes, so UIKit takes the delegate from
    // MainWindow.nib's File's Owner: Asphalt6AppDelegate.
    gva_t delegateCls = delegateGva ? delegateGva : GuestObjCClassNamed(vm, @"Asphalt6AppDelegate");
    if (!delegateCls) {
        GuestTrace(vm, @"[uikit] Asphalt6AppDelegate missing from the image; cannot boot");
        GuestSetRet(vm, 1);
        return;
    }
    BindNativeRenderOwner(vm);
    g_guestAppDelegate = GuestObjCNew(vm, delegateCls);
    GuestTrace(vm, @"[uikit] guest Asphalt6AppDelegate instance at %#x (size %u bytes)",
               g_guestAppDelegate, GuestObjCInstanceSize(vm, delegateCls));

    // The nib connects File's Owner's `window` outlet to the archived UIWindow.
    if (!g_hostWindow) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                g_hostWindow = [[PortGameWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
                break;
            }
        }
        if (!g_hostWindow) g_hostWindow = [[PortGameWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        g_hostWindow.backgroundColor = [UIColor blackColor];
    }
    gva_t winHandle = GuestObjCWrap(vm, g_hostWindow);
    if (winHandle) {
        // -setWindow: is a real guest setter (objc_setProperty with an ivar
        // offset in r3).  Sending it without r2/r3 made it store garbage over
        // the instance, which is what used to clobber the delegate's isa.
        GuestSetReg(vm, 0, g_guestAppDelegate);
        GuestSetReg(vm, 1, GuestObjCGuestSelNamed(vm, "setWindow:"));
        GuestSetReg(vm, 2, winHandle);
        GuestSetReg(vm, 3, 0);
        GuestObjCSend(vm, g_guestAppDelegate, GuestReg(vm, 1), NO);
        GuestTrace(vm, @"[uikit] guest -setWindow: %@ -> recv isa=%#x",
                   g_hostWindow ? @"host UIWindow" : @"NSNull",
                   GuestReadU32(vm, g_guestAppDelegate));
    }

    ReplayMainWindowNib(vm, app);

    // Now drive the real UIApplicationDelegate lifecycle through *guest* code.
    gva_t appHandle = GuestObjCWrap(vm, app);
    GuestSetReg(vm, 0, g_guestAppDelegate);
    GuestSetReg(vm, 1, GuestObjCGuestSelNamed(vm, "application:didFinishLaunchingWithOptions:"));
    GuestSetReg(vm, 2, appHandle);
    GuestSetReg(vm, 3, 0);
    BOOL ok = GuestObjCSend(vm, g_guestAppDelegate,
                            GuestObjCGuestSelNamed(vm, "application:didFinishLaunchingWithOptions:"),
                            NO);
    GuestTrace(vm, @"[uikit] guest application:didFinishLaunchingWithOptions: -> r0=%#x (%@)",
               GuestReg(vm, 0), ok ? @"guest code ran" : @"no guest implementation");

    GuestSetReg(vm, 2, appHandle);
    const BOOL initiallyActive=GuestObjCSend(vm, g_guestAppDelegate,
                  GuestObjCGuestSelNamed(vm, "applicationDidBecomeActive:"), NO);
    g_lifecycleReady=initiallyActive&&NativeCallbackResult(vm);
    if(g_lifecycleReady)g_applicationPhase=NativeActive;
    SynchronizeNativeLifecycleAfterBoot(vm);
    GuestTrace(vm, @"[uikit] guest applicationDidBecomeActive: returned to host");

    // The original main() would now return through the entry stub and re-enter
    // itself; park the CPU so the host run loop keeps the app alive instead.
    GuestSetRet(vm, 0);
    GuestYieldToHostRunLoop(vm);
    GuestStartFrameDriver();
}
HLE_BIND("_UIApplicationMain", hle_UIApplicationMain)

// --- UIApplication accessors the guest reads directly ----------------------
HLE_DEFINE(hle_sharedApplication) {
    GuestSetRet(vm, GuestObjCWrap(vm, [UIApplication sharedApplication]));
}
HLE_BIND("_objc_msgSend_sharedApplication_placeholder", hle_sharedApplication)

HLE_DEFINE(hle_sharedWorkspace) {
    GuestSetRet(vm, GuestObjCWrap(vm, [NSProcessInfo processInfo]));
}

// --- process termination ----------------------------------------------------
// The guest's main() calls exit() the moment UIApplicationMain returns. Parking
// the guest instead keeps the original process alive without faking a game loop.
static BOOL g_guestExited = NO;
BOOL GuestExitRequested(void) { return g_guestExited; }

HLE_DEFINE(hle_exit) {
    GuestTrace(vm, @"[libc] exit(%u) from guest code -- ignored, host keeps the app alive",
               GuestArg(vm, 0));
    g_guestExited = YES;
    GuestSetRet(vm, 0);
    GuestYieldToHostRunLoop(vm);
}
HLE_BIND("_exit", hle_exit)
HLE_BIND("___exit", hle_exit)

HLE_DEFINE(hle_abort) {
    GuestTrace(vm, @"!! abort() from guest code at pc=%#x", GuestPC(vm));
    GuestRequestFault(vm);
}
HLE_BIND("_abort", hle_abort)

// Final physical canvas dimensions used only for background art sampling.
extern "C" bool GuestBackgroundPhysicalSize(double *width, double *height) {
    if (!width || !height || !NSThread.isMainThread || !g_hostWindow) return false;
    const auto full = CanvasRect(g_hostWindow.bounds);
    if (!(as6canvas::positive(full) && full.width > full.height)) return false;
    *width = full.width; *height = full.height; return true;
}
