#import "ResourcePaths.h"
// Video and notification substitution for the 2011 intro sequence.
//
// Asphalt 6 opens with two .m4v clips driven by MPMoviePlayerController.  The
// iOS 27 simulator still exports the class, but it is a husk: it never loads,
// never plays and never posts the finish notification the guest polls for, and
// the MPMoviePlayer*Notification constants it observes through no longer exist
// in the runtime, so every one of its name pointers binds to zero.  The guest
// therefore waits forever in drawView state 1 and never reaches the renderer.
//
// Rather than patch guest code, this file answers the same messages with an
// AVPlayer-backed stand-in that behaves the way iOS 3 did: it autoplays, shows
// itself, and posts MPMoviePlayerPlaybackDidFinishNotification when the clip is
// over. Loading failures are reported as playback errors, never as a fabricated
// successful end-of-playback event.

#import "HLE_media.h"

#import "GuestObjC.h"
#import "GuestVM.h"
#import "HLE.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *const kFinishNote = @"MPMoviePlayerPlaybackDidFinishNotification";
static NSString *const kPreloadNote = @"MPMoviePlayerContentPreloadDidFinishNotification";
static NSString *const kFinishReasonKey = @"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey";
static char kMovieStatusContext;
static char kMovieDisplayContext;

// --- missing string constants -----------------------------------------------
static NSString *const kStringConstants[] = {
    @"MPMoviePlayerPlaybackDidFinishNotification",
    @"MPMoviePlayerPlaybackDidFinishReasonUserInfoKey",
    @"MPMoviePlayerContentPreloadDidFinishNotification",
    @"MPMoviePlayerPlaybackStateDidChangeNotification",
    @"MPMoviePlayerScalingModeDidChangeNotification",
    @"MPMoviePlayerLoadStateDidChangeNotification",
    @"MPMoviePlayerNowPlayingMovieDidChangeNotification",
    @"MPMoviePlayerWillPlayNotification",
    @"MPMoviePlayerWillEnterFullscreenNotification",
    @"MPMoviePlayerDidEnterFullscreenNotification",
    @"MPMoviePlayerWillExitFullscreenNotification",
    @"MPMoviePlayerDidExitFullscreenNotification",
    @"MPMediaPlaybackIsPreparedToPlayDidChangeNotification",
    @"AVPlayerItemDidPlayToEndTimeNotification",
};

NSString *GuestMediaStringConstant(const char *symbol) {
    if (!symbol || symbol[0] != '_') return nil;
    const char *name = symbol + 1;
    for (NSString *s : kStringConstants) {
        if (strcmp(s.UTF8String, name) == 0) return s;
    }
    return nil;
}

// --- the movie player stand-in ----------------------------------------------
@interface PortMovieView : UIView {
    CGRect _lastLayoutBounds;
    BOOL _loggedLayout;
}
@end
@implementation PortMovieView
+ (Class)layerClass { return [AVPlayerLayer class]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    // AVPlayerLayer is the view's backing layer, so UIKit owns its frame and
    // bounds. Its videoRect is computed from these actual on-screen bounds.
    if (!_loggedLayout || !CGRectEqualToRect(_lastLayoutBounds, self.bounds)) {
        _loggedLayout = YES;
        _lastLayoutBounds = self.bounds;
        char line[224];
        snprintf(line, sizeof(line), "[media] layer layout view=%p window=%p bounds=%.1f,%.1f %.1fx%.1f ready=%d",
                 (__bridge void *)self, (__bridge void *)self.window,
                 self.bounds.origin.x, self.bounds.origin.y,
                 self.bounds.size.width, self.bounds.size.height,
                 ((AVPlayerLayer *)self.layer).readyForDisplay);
        GuestRawLog(line);
    }
}
@end

static UIWindow *MoviePresentationWindow(void) {
    UIWindow *best = nil;
    NSInteger bestSceneRank = -1;
    // UIApplication.windows can list the earlier boot window before the game
    // window. Choose within the foreground scene, then respect window stacking
    // and the real key window instead of relying on that legacy list order.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        NSInteger rank = scene.activationState == UISceneActivationStateForegroundActive ? 2 :
                         (scene.activationState == UISceneActivationStateForegroundInactive ? 1 : 0);
        if (!rank) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || w.alpha <= 0 || CGRectIsEmpty(w.bounds)) continue;
            if (!best || rank > bestSceneRank ||
                (rank == bestSceneRank && (w.windowLevel > best.windowLevel ||
                 (w.windowLevel == best.windowLevel && (w.isKeyWindow || !best.isKeyWindow))))) {
                best = w;
                bestSceneRank = rank;
            }
        }
    }
    if (best) return best;
    // Older single-window lifecycle, before a UIWindowScene is connected.
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.hidden || w.alpha <= 0 || CGRectIsEmpty(w.bounds)) continue;
        if (!best || w.windowLevel > best.windowLevel ||
            (w.windowLevel == best.windowLevel && (w.isKeyWindow || !best.isKeyWindow))) best = w;
    }
    return best;
}

@interface PortMoviePlayer : NSObject {
    NSURL *_url;
    PortMovieView *_view;
    AVPlayer *_player;
    AVPlayerItem *_item;
    id _endToken;
    id _errorToken;
    NSMutableArray *_windowTokens;
    BOOL _observingStatus;
    BOOL _observingDisplay;
    BOOL _preloaded;
    BOOL _shouldAutoplay;
    BOOL _playRequested;
    BOOL _started;
    BOOL _finished;
    BOOL _attached;
    NSTimeInterval _seconds;
}
- (instancetype)initWithContentURL:(NSURL *)url;
- (void)startIfNeeded;
- (void)finishWithReason:(NSInteger)reason;
- (void)itemStatusChanged;
- (void)attachToWindow;
- (void)logDisplayState:(const char *)reason;
@end

@implementation PortMoviePlayer

- (instancetype)initWithContentURL:(NSURL *)url {
    self = [super init];
    if (!self) return nil;
    BOOL resourceURL=NO;url=AS6ResolveResourceReadURL(url,&resourceURL);if(resourceURL&&!url)url=[NSURL fileURLWithPath:AS6ResourceDeniedReadPath()];
    _url = url;
    _view = [[PortMovieView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    _view.userInteractionEnabled = NO;
    _view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _view.backgroundColor = [UIColor blackColor];
    _seconds = 4.0;
    _shouldAutoplay = YES;
    if (url) {
        AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        _item = [AVPlayerItem playerItemWithAsset:asset];
        _player = [AVPlayer playerWithPlayerItem:_item];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        ((AVPlayerLayer *)_view.layer).player = _player;
        // Intro clips retain their native presentation aspect and orientation.
        // Their AVPlayerLayer is independent of the original game's canvas;
        // the black full-window view supplies any required letterboxing.
        ((AVPlayerLayer *)_view.layer).videoGravity = AVLayerVideoGravityResizeAspect;
        for (AVAssetTrack *t in [asset tracksWithMediaType:AVMediaTypeVideo]) {
            CMTime d = t.timeRange.duration;
            if (CMTIME_IS_NUMERIC(d) && CMTimeGetSeconds(d) > 0.05) _seconds = CMTimeGetSeconds(d);
            break;
        }
        __weak PortMoviePlayer *weakSelf = self;
        _endToken = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:_item
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
                        [weakSelf finishWithReason:0];  // MPMovieFinishReasonPlaybackEnded
                    }];
        _errorToken = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                        object:_item
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
                        [weakSelf finishWithReason:1];  // MPMovieFinishReasonPlaybackError
                    }];
        _observingStatus = YES;
        [_item addObserver:self forKeyPath:@"status"
                   options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                   context:&kMovieStatusContext];
        _observingDisplay = YES;
        [_view.layer addObserver:self forKeyPath:@"readyForDisplay"
                        options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                        context:&kMovieDisplayContext];
    }
    _windowTokens = [NSMutableArray array];
    __weak PortMoviePlayer *weakSelf = self;
    for (NSString *name in @[UIWindowDidBecomeKeyNotification, UIWindowDidBecomeVisibleNotification,
                             UISceneDidActivateNotification]) {
        id token = [[NSNotificationCenter defaultCenter]
            addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            PortMoviePlayer *owner = weakSelf;
                            if (owner && owner->_started && !owner->_finished) [owner attachToWindow];
                        });
                    }];
        if (token) [_windowTokens addObject:token];
    }
    GuestRawLog("[media] PortMoviePlayer created for a clip");
    if (!url) dispatch_async(dispatch_get_main_queue(), ^{ [self finishWithReason:1]; });
    return self;
}

- (UIView *)view { return _view; }
- (NSURL *)contentURL { return _url; }
- (NSTimeInterval)duration { return _seconds; }
- (NSTimeInterval)initialPlaybackTime { return 0; }
- (NSTimeInterval)currentPlaybackTime { return _player ? CMTimeGetSeconds(_player.currentTime) : 0; }
- (CGSize)naturalSize { return CGSizeMake(320, 480); }
- (BOOL)isMovieNaturalSizeAvailable { return YES; }
- (BOOL)isReadyForPlay { return _item.status == AVPlayerItemStatusReadyToPlay; }
- (BOOL)shouldAutoplay { return _shouldAutoplay; }
- (NSInteger)playbackState { return _finished ? 0 : (_player.rate > 0 ? 1 : (_started ? 2 : 0)); }
- (NSInteger)loadState { return _item.status == AVPlayerItemStatusReadyToPlay ? 3 : 0; }
- (NSInteger)scalingMode { return 1; }
- (void)setShouldAutoplay:(BOOL)v { _shouldAutoplay = v; }
- (void)setMovieControlMode:(NSInteger)v { (void)v; }
- (void)setControlStyle:(NSInteger)v { (void)v; }
- (void)setScalingMode:(NSInteger)v { (void)v; }
- (void)setContentScaleFactor:(CGFloat)v { (void)v; }
- (void)setNotificationTimes:(NSArray *)t { (void)t; }
- (void)setShouldUseApplicationTrustStore:(BOOL)v { (void)v; }
- (void)setFullscreen:(BOOL)v { (void)v; }
- (void)setFullscreen:(BOOL)v animated:(BOOL)a { (void)v; (void)a; }
- (void)setCurrentPlaybackTime:(NSTimeInterval)t { (void)t; }
- (void)setInitialPlaybackTime:(NSTimeInterval)t { (void)t; }
- (void)setRepeatMode:(NSInteger)v { (void)v; }
- (void)setBackgroundPlaybackEnabled:(BOOL)v { (void)v; }
- (void)initializeMedia { }
- (void)prepareToPlay { [self startIfNeeded]; }
- (void)load { [self startIfNeeded]; }
- (void)setDelegate:(id)d { (void)d; }
- (id)delegate { return nil; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {
    if (context == &kMovieDisplayContext) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self logDisplayState:"readyForDisplay changed"]; });
        return;
    }
    if (context != &kMovieStatusContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    // Never reenter the guest while it is still constructing the movie player.
    dispatch_async(dispatch_get_main_queue(), ^{ [self itemStatusChanged]; });
}

- (void)itemStatusChanged {
    if (_finished) return;
    if (_item.status == AVPlayerItemStatusFailed) {
        char line[384];
        snprintf(line, sizeof(line), "[media] clip failed: %s",
                 _item.error.localizedDescription.UTF8String ?: "unknown decoder error");
        GuestRawLog(line);
        [self finishWithReason:1];
    } else if (_item.status == AVPlayerItemStatusReadyToPlay) {
        if (!_preloaded) {
            _preloaded = YES;
            [[NSNotificationCenter defaultCenter] postNotificationName:kPreloadNote object:self];
        }
        if (_shouldAutoplay || _playRequested) [self startIfNeeded];
    }
}

// The clip has to be on screen for the intro to read as an intro, and the 2011
// caller never inserts -view itself: MPMoviePlayerController used to present it.
- (void)attachToWindow {
    UIWindow *w = MoviePresentationWindow();
    if (!w) { GuestRawLog("[media] clip waiting for a visible foreground window"); return; }
    BOOL moved = _view.superview != w;
    if (moved) {
        [_view removeFromSuperview];
        _view.frame = w.bounds;
        [w addSubview:_view];
        [w bringSubviewToFront:_view];
    } else _view.frame = w.bounds;
    _attached = _view.window != nil;
    [_view setNeedsLayout];
    [_view layoutIfNeeded];
    if (moved) [self logDisplayState:"attached to presentation window"];
}

- (void)logDisplayState:(const char *)reason {
    AVPlayerLayer *layer = (AVPlayerLayer *)_view.layer;
    UIWindow *w = _view.window;
    CGRect b = layer.bounds, video = layer.videoRect;
    char line[512];
    snprintf(line, sizeof(line),
             "[media] display %s ready=%d window=%p key=%d level=%.1f hidden=%d "
             "layer=%.1fx%.1f videoRect=%.1f,%.1f %.1fx%.1f time=%.3f rate=%.1f status=%ld",
             reason, layer.readyForDisplay, (__bridge void *)w, w.isKeyWindow,
             w.windowLevel, w.hidden, b.size.width, b.size.height,
             video.origin.x, video.origin.y, video.size.width, video.size.height,
             _player ? CMTimeGetSeconds(_player.currentTime) : 0.0,
             _player.rate, (long)_item.status);
    GuestRawLog(line);
}

- (void)startIfNeeded {
    if (_finished) return;
    _playRequested = YES;
    if (!_item || _item.status != AVPlayerItemStatusReadyToPlay) return;
    _started = YES;
    [self attachToWindow];
    if (_player) [_player play];
    char line[160];
    snprintf(line, sizeof(line), "[media] clip playing (%.2fs, url=%d)", _seconds, _url != nil);
    GuestRawLog(line);
}

- (void)play { [self startIfNeeded]; }
- (void)pause { if (_player) [_player pause]; }
- (void)stop {
    if (_player) { [_player pause]; [_player seekToTime:kCMTimeZero]; }
    [self finishWithReason:2];  // MPMovieFinishReasonUserExited
}

- (void)finishWithReason:(NSInteger)reason {
    if (_finished) return;
    _finished = YES;
    if (_player) [_player pause];
    [self logDisplayState:"playback finished"];
    for (id token in _windowTokens) [[NSNotificationCenter defaultCenter] removeObserver:token];
    [_windowTokens removeAllObjects];
    // End the movie presentation before entering the guest finish callback.
    // That callback can start the next clip or reveal the game immediately.
    [_view removeFromSuperview];
    _attached = NO;
    char line[160];
    snprintf(line, sizeof(line), "[media] clip finished (reason=%ld) -> posting playback notification",
             (long)reason);
    GuestRawLog(line);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kFinishNote
                      object:self
                    userInfo:@{kFinishReasonKey: @(reason)}];
}

- (void)dealloc {
    if (_observingStatus) [_item removeObserver:self forKeyPath:@"status" context:&kMovieStatusContext];
    if (_observingDisplay) [_view.layer removeObserver:self forKeyPath:@"readyForDisplay" context:&kMovieDisplayContext];
    if (_endToken) [[NSNotificationCenter defaultCenter] removeObserver:_endToken];
    if (_errorToken) [[NSNotificationCenter defaultCenter] removeObserver:_errorToken];
    for (id token in _windowTokens) [[NSNotificationCenter defaultCenter] removeObserver:token];
}
@end

@interface PortMoviePlayerViewController : UIViewController {
    PortMoviePlayer *_player;
}
- (instancetype)initWithContentURL:(NSURL *)url;
@end

@implementation PortMoviePlayerViewController
- (instancetype)initWithContentURL:(NSURL *)url {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _player = [[PortMoviePlayer alloc] initWithContentURL:url];
    return self;
}
- (void)loadView {
    // The player already owns the AVPlayerLayer-backed root view. Returning
    // it from -view and then adding it to self.view would add it to itself.
    self.view = _player ? _player.view : [[UIView alloc] initWithFrame:CGRectZero];
}
- (PortMoviePlayer *)moviePlayer { return _player; }
- (void)play { [_player play]; }
- (void)pause { [_player pause]; }
@end

// Stand-in for the removed MediaPlayer music-library classes: any class or
// instance message answers nil/0, which the game reads as "no system music".
@interface AS6RemovedMusicLibrary : NSObject
@end
@implementation AS6RemovedMusicLibrary
static id RemovedMusicLibraryNil(id self, SEL _cmd, ...) { return nil; }
+ (BOOL)resolveClassMethod:(SEL)sel {
    return class_addMethod(object_getClass(self), sel, (IMP)RemovedMusicLibraryNil, "@@:");
}
+ (BOOL)resolveInstanceMethod:(SEL)sel {
    return class_addMethod(self, sel, (IMP)RemovedMusicLibraryNil, "@@:");
}
+ (id)alloc { return nil; }
+ (id)allocWithZone:(NSZone *)zone { (void)zone; return nil; }
+ (id)new { return nil; }
@end

Class GuestMediaSubstituteClass(const char *className) {
    if (!className) return nil;
    if (GuestMediaRemovedClass(className)) return [AS6RemovedMusicLibrary class];
    if (strcmp(className, "MPMoviePlayerController") == 0) return [PortMoviePlayer class];
    if (strcmp(className, "MPMoviePlayerViewController") == 0)
        return [PortMoviePlayerViewController class];
    return nil;
}

BOOL GuestMediaRemovedClass(const char *className) {
    static const char *const removed[] = {
        "MPMusicPlayerController", "MPMediaQuery", "MPMediaLibrary", "MPMediaItem",
        "MPMediaItemCollection", "MPMediaPlaylist", "MPMediaPickerController",
        "MPMediaPropertyPredicate",
    };
    if (!className) return NO;
    for (const char *name : removed)
        if (strcmp(className, name) == 0) return YES;
    return NO;
}

// --- notification registrations made by guest code ---------------------------
@interface PortNotifReg : NSObject {
@public
    gva_t _target;
    SEL _sel;
    NSString *_name;
    id _object;
    id _token;
    BOOL _live;
}
@end
@implementation PortNotifReg
@end

static NSMutableArray<PortNotifReg *> *g_regs;

static void EnsureRegs(void) {
    if (!g_regs) g_regs = [NSMutableArray array];
}

// Deliver one host notification to a guest observer.  Notifications only ever
// arrive while the main thread is idle between emulated frames, which is the
// only moment it is safe to re-enter the CPU.
static void DeliverToGuest(PortNotifReg *reg, NSNotification *note) {
    if (!reg || !reg->_live) return;
    GuestVM *vm = GuestVMShared();
    if (!vm || !reg->_sel) return;
    gva_t sel = GuestObjCGuestSelNamed(vm, sel_getName(reg->_sel));
    if (!sel) return;
    gva_t noteHandle = note ? GuestObjCWrap(vm, note) : 0;
    GuestLock(vm);
    GuestSetReg(vm, 0, reg->_target);
    GuestSetReg(vm, 1, sel);
    GuestSetReg(vm, 2, noteHandle);
    GuestObjCSend(vm, reg->_target, sel, NO);
    GuestUnlock(vm);
    char line[192];
    snprintf(line, sizeof(line), "[notif] -[%#x %s] fired for %s", reg->_target,
             sel_getName(reg->_sel), note.name.UTF8String ? note.name.UTF8String : "?");
    GuestRawLog(line);
}

BOOL GuestMediaOverride(GuestVM *vm, id target, SEL sel) {
    const char *sn = sel ? sel_getName(sel) : NULL;
    if (!sn) return NO;
    BOOL isCenter = [target isKindOfClass:[NSNotificationCenter class]] ||
                    target == (id)[NSNotificationCenter class];
    if (!isCenter) return NO;

    if (strcmp(sn, "addObserver:selector:name:object:") == 0) {
        gva_t observer = GuestArg(vm, 2);
        gva_t selGuest = GuestArg(vm, 3);
        gva_t nameGuest = GuestArg(vm, 4);
        gva_t objectGuest = GuestArg(vm, 5);
        if (GuestIsHostObject(observer) || GuestIsHostClass(observer) || !observer) return NO;
        SEL guestSel = GuestObjCSelFromGuest(vm, selGuest);
        if (!guestSel) { GuestSetRet(vm, 0); return YES; }
        NSString *name = nil;
        if (GuestIsHostObject(nameGuest))
            name = (NSString *)GuestObjCUnwrap(vm, nameGuest);
        else if (nameGuest)
            name = GuestObjCCFString(vm, nameGuest);
        if (nameGuest && !name) {
            GuestRawLog("[notif] invalid notification name handle; refusing wildcard registration");
            GuestSetRet(vm, 0);
            return YES;
        }
        EnsureRegs();
        PortNotifReg *reg = [PortNotifReg new];
        reg->_target = observer;
        reg->_sel = guestSel;
        reg->_name = [name copy];
        reg->_object = objectGuest ? GuestObjCUnwrap(vm, objectGuest) : nil;
        reg->_live = YES;
        __weak PortNotifReg *weakReg = reg;
        reg->_token = [[NSNotificationCenter defaultCenter]
            addObserverForName:name
                        object:reg->_object
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) { DeliverToGuest(weakReg, note); }];
        [g_regs addObject:reg];
        char line[224];
        snprintf(line, sizeof(line), "[notif] guest %#x observes %s -> -%s", observer,
                 name.UTF8String ? name.UTF8String : "<all>", sel_getName(guestSel));
        GuestRawLog(line);
        GuestSetRet(vm, 0);
        return YES;
    }

    if (strcmp(sn, "removeObserver:") == 0 || strcmp(sn, "removeObserver:name:object:") == 0) {
        gva_t observer = GuestArg(vm, 2);
        if (GuestIsHostObject(observer) || GuestIsHostClass(observer) || !observer) return NO;
        EnsureRegs();
        BOOL filtered = strcmp(sn, "removeObserver:name:object:") == 0;
        gva_t nameGuest = filtered ? GuestArg(vm, 3) : 0;
        gva_t objectGuest = filtered ? GuestArg(vm, 4) : 0;
        NSString *name = GuestIsHostObject(nameGuest) ? GuestObjCUnwrap(vm, nameGuest) :
                         (nameGuest ? GuestObjCCFString(vm, nameGuest) : nil);
        id object = objectGuest ? GuestObjCUnwrap(vm, objectGuest) : nil;
        for (PortNotifReg *reg in g_regs) {
            if (reg->_target != observer || !reg->_live) continue;
            if (filtered && name && ![reg->_name isEqualToString:name]) continue;
            if (filtered && object && reg->_object != object) continue;
            reg->_live = NO;
            if (reg->_token) [[NSNotificationCenter defaultCenter] removeObserver:reg->_token];
        }
        GuestSetRet(vm, 0);
        return YES;
    }
    return NO;
}
