#import <UIKit/UIKit.h>
#import "GuestVM.h"
#import "HLE_motion.h"
extern "C" BOOL GuestConfigurePNGProgressFile(GuestVM *,const char *);
#import "HLE.h"
#import "ResourcePaths.h"
#import "HDArtworkPack.hpp"
#import "ResourceArchives.hpp"
#include "NativeBuildConfig.hpp"
#include "ProcessArguments.hpp"
#include "NativeMusicService.hpp"
#include <cerrno>
#include <cstdio>
#include <chrono>
#include <cstring>

extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *);
extern "C" GuestExecutionResult GuestLastExecutionResultLocked(GuestVM *);
extern "C" NSDictionary<NSString *,id> *GuestExecutionDiagnosticsLocked(GuestVM *);
extern void HLEInstallCxxAbi(void);
static GuestVM *gameVM;
static NSString *runStage = @"launch";
static NSString *runFailure;
extern "C" NSDictionary *GuestAudioPerformanceSnapshot(void);
extern "C" NSDictionary *GuestFramePerformanceSnapshot(void);

static bool RuntimeDiagnosticsRequested(void) {
    static const bool enabled=[] {
        const char *run=getenv("AS6_NATIVE_RUN_ID");
        const char *diagnostics=getenv("AS6_RUNTIME_DIAGNOSTICS");
        return (run && *run && std::strcmp(run,"manual")) ||
               (diagnostics && !std::strcmp(diagnostics,"1"));
    }();
    return enabled;
}

static NSDictionary *NativeMusicSnapshot(void) {
    const auto s=as6::audio::nativeMusicDiagnostics();
    return @{@"ready":@(s.ready),@"generation":@(s.generation),
        @"accepted_batches":@(s.acceptedBatches),@"accepted_actions":@(s.acceptedActions),
        @"decoded_clips":@(s.decodedClips),@"cache_hits":@(s.cacheHits),
        @"played_voices":@(s.playedVoices),@"failed_voices":@(s.failedVoices),
        @"pending_voices":@(s.pendingVoices),@"playing_voices":@(s.playingVoices),
        @"paused":@(s.paused),@"application_active":@(s.applicationActive),
        @"track":@(s.observedTrack),@"emitter":@(s.observedEmitter),
        @"output_epoch":@(s.observedOutputEpoch),@"position_frames":@(s.observedPositionFrames),
        @"last_error":[NSString stringWithUTF8String:s.lastError.c_str()]?:@""};
}

static void SaveRunStateLocked(void) {
    NSMutableDictionary *result = [@{
        @"schema_version": @1,
        @"run_id": @(getenv("AS6_NATIVE_RUN_ID") ?: "manual"),
        @"build_id": @AS6_HOST_BUILD_ID,
        @"stage": runStage,
        @"whole_game_complete": @NO,
        @"jit": @NO,
        @"original_executable_packaged": @NO,
        @"architecture": @"arm64",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } mutableCopy];
    if (gameVM) {
        result[@"execution_status"] = @(GuestLastExecutionResultLocked(gameVM));
        result[@"pc"] = @(GuestPC(gameVM));
        result[@"hle_calls"] = @(GuestCallCount(gameVM));
        result[@"guest_view"] = @(GuestGLView());
        result[@"guest_app_delegate"] = @(GuestAppDelegate());
        result[@"guest_exit_requested"] = @(GuestExitRequested());
        result[@"unimplemented"] = GuestUnimplementedCounts(gameVM) ?: @{};
        result[@"execution_diagnostics"] = GuestExecutionDiagnosticsLocked(gameVM);
        result[@"audio_performance"] = GuestAudioPerformanceSnapshot();
        result[@"native_music_source"] = NativeMusicSnapshot();
        result[@"motion_performance"] = GuestMotionPerformanceSnapshot();
        result[@"frame_performance"] = GuestFramePerformanceSnapshot();
        NSArray *trace = GuestTraceLog(gameVM);
        result[@"trace"] = trace ?: @[];
    }
    if (runFailure) result[@"error"] = runFailure;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"native-run-result.json"] atomically:YES];
}
static void SaveRunState(void) {
    GuestVM *snapshotVM=gameVM;
    if (snapshotVM && !GuestTryLock(snapshotVM)) return;
    @try { SaveRunStateLocked(); }
    @finally { if (snapshotVM) GuestUnlock(snapshotVM); }
}
static void MaybeSaveRunStateLocked(void) {
    const auto status=GuestLastExecutionResultLocked(gameVM);
    const bool exited=GuestExitRequested();
    const bool failed=exited || (status!=GuestExecutionSuccess && status!=GuestExecutionYielded);
    // Side-loaded play should not serialize thousands of trace lines and
    // atomically write JSON on the rendering thread every two seconds.
    // Keep the lightweight failure poll and all explicit boot/lifecycle saves.
    if(!RuntimeDiagnosticsRequested() && (!failed || [runStage isEqualToString:@"failed"])) return;
    static std::chrono::steady_clock::time_point lastAttempt{};
    const auto now=std::chrono::steady_clock::now();
    const bool firstFailure=failed && ![runStage isEqualToString:@"failed"];
    if (!firstFailure && lastAttempt.time_since_epoch().count() && now-lastAttempt<std::chrono::seconds(2)) return;
    lastAttempt=now;
    if (exited) {
        runStage=@"failed";
        runFailure=@"Original program requested exit after startup";
    } else if (status!=GuestExecutionSuccess && status!=GuestExecutionYielded) {
        runStage=@"failed";
        runFailure=[NSString stringWithUTF8String:GuestExecutionErrorText(status)];
    }
    SaveRunStateLocked();
}
extern "C" void GuestHostFrameDidComplete(GuestVM *vm) {
    const int savedErrno=errno;
    @try {
        if (vm!=gameVM || !NSThread.isMainThread || !GuestDiagnosticSnapshotLockHeld(vm)) return;
        MaybeSaveRunStateLocked();
    } @catch (NSException *) {
        static unsigned failures=0;
        if (failures++<8) std::fprintf(stderr,"[native-heartbeat] frame snapshot exception\n");
    } @finally { errno=savedErrno; }
}

// The original's offline event queue (Documents/events.dat) is never uploaded
// and duplicates itself on every save. Once it reaches tens of megabytes,
// loading it exhausts guest memory and startup dereferences a null pointer.
// It holds no progress (that is profile1.sav), so an oversized queue is set
// aside before boot and the original recreates an empty one.
static void SetAsideOversizedEventQueue(void) {
    static const unsigned long long limit = 1024 * 1024;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents) return;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *queue = [documents stringByAppendingPathComponent:@"events.dat"];
    NSDictionary *attributes = [files attributesOfItemAtPath:queue error:nil];
    if (![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize <= limit) return;
    NSString *aside = [documents stringByAppendingPathComponent:@"events.dat.oversize"];
    [files removeItemAtPath:aside error:nil];
    NSError *error = nil;
    const BOOL moved = [files moveItemAtPath:queue toPath:aside error:&error];
    NSLog(@"[native-host] events.dat %llu bytes set aside=%d error=%@",
          attributes.fileSize, moved, error.localizedDescription ?: @"none");
}

static BOOL BootNativeGame(void) {
    runStage = @"native-data"; SaveRunState();
    SetAsideOversizedEventQueue();
    if(!as6::audio::nativeMusicReady()) {
        runFailure=@"原生音乐服务初始化失败，请关闭应用后重试。";
        runStage=@"failed";SaveRunState();return NO;
    }
    HLEInstallCxxAbi();
    HLELoadGuestFrameworks();
    NSError *error = nil;
    gameVM = GuestVMCreate(&error);
    if (!gameVM) {
        runFailure = error.localizedDescription ?: @"Native provider creation failed";
        runStage = @"failed"; SaveRunState(); return NO;
    }
    GuestSetTraceEnabled(gameVM, YES);
    // Open this bounded diagnostic before entering a potentially long native
    // frame. It never allocates or writes any original game data.
    const char *memoryDiagnostics=getenv("AS6_NATIVE_MEMORY_DIAGNOSTICS");
    if(memoryDiagnostics && !std::strcmp(memoryDiagnostics,"1") &&
       !GuestConfigurePNGProgressFile(gameVM,[NSTemporaryDirectory() stringByAppendingPathComponent:@"native-png-progress.jsonl"].fileSystemRepresentation))
        GuestRawLog("[png] could not open native-png-progress.jsonl");
    GuestVMSetShared(gameVM);
    GuestLock(gameVM);
    const uint32_t argv0=GuestWriteCString(gameVM,NSBundle.mainBundle.executablePath ?: @"/Applications/Asphalt6Native.app/AS6NativeGame");
    const bool prepared=as6native::WriteProcessArguments(GuestSP(gameVM),argv0,
        [](uint32_t address,const void *bytes,size_t length) {return bool(GuestWrite(gameVM,address,bytes,length));});
    GuestUnlock(gameVM);
    if (!prepared) {
        runFailure=@"Original process argument frame could not be initialized";
        runStage=@"failed"; SaveRunState(); return NO;
    }
    runStage = @"initializers"; SaveRunState();
    GuestExecutionResult initializerResult;
    GuestLock(gameVM);
    @try {
        GuestRunModInitFuncs(gameVM);
        initializerResult = GuestLastExecutionResult(gameVM);
    } @finally { GuestUnlock(gameVM); }
    if (initializerResult != GuestExecutionSuccess) {
        runFailure = [NSString stringWithFormat:@"Original initializer stopped: %s", GuestExecutionErrorText(initializerResult)];
        runStage = @"failed"; SaveRunState(); return NO;
    }
    runStage = @"entry"; SaveRunState();
    BOOL entered, exited;
    GuestExecutionResult entryResult;
    gva_t originalView, originalDelegate;
    GuestLock(gameVM);
    @try {
        entered = GuestVMRun(gameVM, gameVM.entryPoint, 0x60000010u, 40000000, &error);
        entryResult = GuestLastExecutionResult(gameVM);
        exited = GuestExitRequested();
        originalView = GuestGLView();
        originalDelegate = GuestAppDelegate();
    } @finally { GuestUnlock(gameVM); }
    if (!entered) {
        runFailure = error.localizedDescription ?: @"Original entry stopped";
        runStage = @"failed"; SaveRunState(); return NO;
    }
    if (exited || !originalView || !originalDelegate) {
        runFailure=@"Original program exited or did not create its application view";
        runStage=@"failed"; SaveRunState(); return NO;
    }
    runStage = entryResult == GuestExecutionYielded ? @"host-run-loop" : @"entry-returned";
    SaveRunState();
    // The original game owns its windows, drawing and touch callbacks.
    __block uint64_t diagnosticTimerFires = 0;
    NSTimer *diagnosticTimer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *) {
        const int savedErrno = errno;
        @try {
        const auto fire = ++diagnosticTimerFires;
        const BOOL locked = GuestTryLock(gameVM);
        @try {
        if (RuntimeDiagnosticsRequested() && (fire <= 8 || !(fire & (fire - 1)))) {
            const char *mode = NSRunLoop.currentRunLoop.currentMode.UTF8String;
            std::fprintf(stderr,"[native-heartbeat] fire=%llu locked=%d mode=%s\n",
                (unsigned long long)fire,locked,mode ?: "none");
        }
        if (!locked) return;
        MaybeSaveRunStateLocked();
        } @finally { if (locked) GuestUnlock(gameVM); }
        } @finally { errno = savedErrno; }
    }];
    [NSRunLoop.mainRunLoop addTimer:diagnosticTimer forMode:NSRunLoopCommonModes];
    return YES;
}

@interface AS6NativeBootController : UIViewController
@property(nonatomic,strong)UILabel *status;
@property(nonatomic,strong)UIButton *retry;
@property(nonatomic)BOOL checking,bootAttempted;
@end
@implementation AS6NativeBootController
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;
    self.status=[UILabel new];self.status.textColor=UIColor.whiteColor;self.status.textAlignment=NSTextAlignmentCenter;self.status.numberOfLines=0;self.status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.status];
    self.retry=[UIButton buttonWithType:UIButtonTypeSystem];[self.retry setTitle:@"重新检测" forState:UIControlStateNormal];self.retry.translatesAutoresizingMaskIntoConstraints=NO;[self.retry addTarget:self action:@selector(retryResources) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.retry];
    [NSLayoutConstraint activateConstraints:@[[self.status.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],[self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],[self.retry.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:20],[self.retry.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]]];
    AS6PrepareResourceImportHelp();
    [self checkResources:NO];
}
- (void)retryResources {[self checkResources:YES];}
- (void)checkResources:(BOOL)force {
    if(self.checking||self.bootAttempted)return;self.checking=YES;self.retry.hidden=YES;self.retry.enabled=NO;self.status.text=@"正在验证游戏资源";runStage=@"checking-resources";SaveRunState();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        void (^show)(NSString *)=^(NSString *text){dispatch_async(dispatch_get_main_queue(),^{self.status.text=text;});};
        NSError *error=nil;BOOL ready=NO,fullHash=force,installedData=NO,damagedData=NO,triedArtwork=NO;NSString *artworkNotice=nil;
        // Verify Documents/Asphalt6Data. A failed check may be repaired once
        // from Asphalt6Data.zip; a passing one may then install missing HD
        // artwork once from NativeArtwork.zip. Every install is re-verified.
        for(;;) {
            show(@"正在验证游戏资源");
            error=nil;NSDictionary *details=nil;
            @try {ready=AS6ValidateDocumentResources(fullHash,&details,&error,^(double fraction){show([NSString stringWithFormat:@"正在验证游戏资源 %d%%",(int)(fraction*100)]);});}
            @catch(NSException *){ready=NO;error=nil;}
            if(!ready) {
                if(!installedData&&AS6ResourceArchivePresent()) {
                    show(@"正在解压资源包");
                    if(AS6InstallResourceArchive(^(double fraction){show([NSString stringWithFormat:@"正在解压资源包 %d%%",(int)(fraction*100)]);})==AS6ArchiveInstalled){installedData=YES;fullHash=YES;continue;}
                    damagedData=YES;
                }
                break;
            }
            // The scan result is kept for the rest of the run (AS6HDArtworkAvailable).
            const BOOL artworkComplete=AS6HDArtworkScan();
            if(!triedArtwork&&!artworkComplete&&AS6HDArtworkArchivePresent()) {
                triedArtwork=YES;
                show(@"正在解压高清背景包");
                if(AS6InstallHDArtwork())continue;
                artworkNotice=@"高清背景包 NativeArtwork.zip 解压失败";
            }
            break;
        }
        if(ready) {
            NSString *archive=[AS6ResourceRootPath() stringByAppendingPathComponent:@"data/file00a.bin"];
            ready=archive && as6::audio::configureNativeMusic(archive.fileSystemRepresentation);
            if(!ready)error=[NSError errorWithDomain:@"AS6Resources" code:3 userInfo:
                @{NSLocalizedDescriptionKey:@"音乐资源暂时无法读取，请确认资源包完整后重试。"}];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            self.checking=NO;
            if(!ready){
                runStage=@"waiting-for-resources";runFailure=error.localizedDescription;SaveRunState();
                // Without a resource folder the cause is simply "not imported";
                // otherwise show what the check actually found.
                const BOOL imported=[NSFileManager.defaultManager fileExistsAtPath:AS6ExpectedResourceRootPath()];
                NSString *reason=damagedData?@"资源包 Asphalt6Data.zip 损坏，请先导入新资源包。":
                    installedData?@"资源包 Asphalt6Data.zip 内容不完整或版本不符，请先导入新资源包。":
                    imported&&error.localizedDescription?error.localizedDescription:@"请先导入游戏资源。";
                NSString *app=NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"]?:@"本应用";
                self.status.text=[NSString stringWithFormat:@"%@\n\n把 Asphalt6Data.zip 放入：文件 App → 我的 iPhone → %@\n返回后点击“重新检测”。",reason,app];
                self.retry.hidden=NO;self.retry.enabled=YES;return;
            }
            self.bootAttempted=YES;runFailure=nil;AS6ResourceMarkGameStarted();
            self.status.text=artworkNotice?[artworkNotice stringByAppendingString:@"\n正在启动游戏"]:@"正在启动游戏";
            // Let UIKit paint the single startup message before original boot
            // synchronously enters its potentially long initialization.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                const BOOL started=BootNativeGame();self.status.text=started?@"":@"游戏启动中止，请关闭应用后重试。";
                NSLog(@"[native-host] stage=%@ error=%@",runStage,runFailure?:@"none");
            });
        });
    }});
}
@end

extern "C" BOOL GuestNativeApplicationLifecycle(GuestVM *,const char *);
static void ForwardOriginalSceneLifecycle(const char *selector) {
    const bool inactive=!std::strcmp(selector,"applicationWillResignActive:")||
        !std::strcmp(selector,"applicationDidEnterBackground:");
    const bool active=!std::strcmp(selector,"applicationDidBecomeActive:");
    if(inactive)as6::audio::setNativeMusicApplicationActive(false);
    if(!gameVM) {
        if(active)as6::audio::setNativeMusicApplicationActive(true);
        return;
    }
    @try {GuestNativeApplicationLifecycle(gameVM,selector);}
    @finally {if(active)as6::audio::setNativeMusicApplicationActive(true);SaveRunState();}
}

@interface AS6NativeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AS6NativeSceneDelegate
- (void)sceneWillResignActive:(UIScene *)scene {ForwardOriginalSceneLifecycle("applicationWillResignActive:");}
- (void)sceneDidEnterBackground:(UIScene *)scene {ForwardOriginalSceneLifecycle("applicationDidEnterBackground:");}
- (void)sceneWillEnterForeground:(UIScene *)scene {ForwardOriginalSceneLifecycle("applicationWillEnterForeground:");}
- (void)sceneDidBecomeActive:(UIScene *)scene {ForwardOriginalSceneLifecycle("applicationDidBecomeActive:");}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [AS6NativeBootController new];
    [self.window makeKeyAndVisible];
}
@end

@interface AS6NativeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AS6NativeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    SaveRunState(); return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [UISceneConfiguration configurationWithName:@"Game" sessionRole:session.role];
    configuration.delegateClass = AS6NativeSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AS6NativeAppDelegate.class)); }
}
