// Device identity the 2011 build branches on.
//
// Asphalt 6 asks `sysctlbyname("hw.machine")` for its platform enum and multiplies
// [UIScreen mainScreen].bounds by the view's contentScaleFactor to pick both its
// intro movie and its framebuffer size.  On an iPhone 17 Pro simulator those
// answers are "unknown device" and 1206x2622, which pushes the renderer into a
// resolution the 2011 assets have no layout for.  Reporting the machine the game
// was shipped for -- iPhone 4, 320x480 @2x -- keeps every one of its own code
// paths on the original 640x960 route by default. A Simulator-only opt-in
// keeps the original320x480 point bounds and selects1x backing consistently.

#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"

#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#import <stdlib.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <sys/sysctl.h>

// --- hw.machine -------------------------------------------------------------
HLE_DEFINE(hle_sysctlbyname) {
    gva_t nameGva = GuestArg(vm, 0), oldp = GuestArg(vm, 1), oldlenp = GuestArg(vm, 2);
    NSString *name = GuestReadCString(vm, nameGva, 256);
    const char *cname = name.UTF8String ?: "";
    char value[512];
    size_t len = 0;
    BOOL have = NO;

    if (!strcmp(cname, "hw.machine")) { strcpy(value, "iPhone3,1"); len = strlen(value) + 1; have = YES; }
    else if (!strcmp(cname, "hw.model")) { strcpy(value, "iPhone3,1"); len = strlen(value) + 1; have = YES; }

    if (!have) {
        len = sizeof(value);
        if (sysctlbyname(cname, value, &len, NULL, 0) != 0) { GuestSetRet(vm, (uint32_t)-1); return; }
    }
    if (!oldp) {
        if (oldlenp) GuestWriteU32(vm, oldlenp, (uint32_t)len);
        GuestSetRet(vm, 0);
        return;
    }
    size_t want = oldlenp ? GuestReadU32(vm, oldlenp) : 0;
    if (want > len) want = len;
    GuestWrite(vm, oldp, value, want);
    if (oldlenp) GuestWriteU32(vm, oldlenp, (uint32_t)len);
    GuestSetRet(vm, 0);
}
HLE_BIND("_sysctlbyname", hle_sysctlbyname)

// iOS removed UIDevice.uniqueIdentifier. The original profile code expects a
// stable 40-character hexadecimal NSString. Keep that API using an opaque
// installation identifier persisted with the app's own data.
BOOL GuestDeviceOverride(GuestVM *vm, id target, SEL sel) {
    if (![target isKindOfClass:[UIDevice class]] ||
        strcmp(sel_getName(sel), "uniqueIdentifier")) return NO;
    static NSString *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *key = @"as6.compatibility.legacyDeviceID";
        NSString *saved = [defaults stringForKey:key];
        NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if (saved.length == 40 && [saved rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound) {
            identifier = saved;
        } else {
            uint8_t random[20];
            arc4random_buf(random, sizeof(random));
            char text[41];
            for (size_t i = 0; i < sizeof(random); ++i) snprintf(text + 2 * i, 3, "%02x", random[i]);
            identifier = [NSString stringWithUTF8String:text];
            [defaults setObject:identifier forKey:key];
        }
        GuestTrace(vm, @"[device] legacy uniqueIdentifier uses persistent installation identifier");
    });
    GuestSetRet(vm, GuestObjCWrap(vm, identifier));
    return YES;
}

// --- the screen the game expects --------------------------------------------
static const CGFloat kScreenWidth = 320.0, kScreenHeight = 480.0;

double GuestScreenBackingScale(void) {
    static const double scale = [] {
#if TARGET_OS_SIMULATOR
        const char *value = getenv("AS6_SIM_SCREEN_SCALE");
        if (value && !strcmp(value, "1")) return 1.0;
#endif
        return 2.0;
    }();
    return scale;
}

BOOL GuestScreenOverride(GuestVM *vm, id target, SEL sel) {
    if (!target || !sel) return NO;
    Class isa = object_getClass(target);
    if (!isa) return NO;
    BOOL isScreen;
    if (class_isMetaClass(isa)) {
        Class k = (Class)target;
        isScreen = (k == [UIScreen class]) || [k isSubclassOfClass:[UIScreen class]];
    } else {
        isScreen = [target isKindOfClass:[UIScreen class]];
    }
    if (!isScreen) return NO;

    const char *n = sel_getName(sel);
    if (!strcmp(n, "scale") || !strcmp(n, "nativeScale")) {
        GuestSetRetF(vm, (float)GuestScreenBackingScale());
        return YES;
    }
    if (!strcmp(n, "maximumFramesPerSecond")) { GuestSetRet(vm, 60); return YES; }

    gva_t dst = GuestStretDestination();
    float w = 0, h = 0;
    if (!strcmp(n, "bounds") || !strcmp(n, "applicationFrame")) {
        w = kScreenWidth; h = kScreenHeight;
    } else if (!strcmp(n, "nativeBounds")) {
        const double scale = GuestScreenBackingScale();
        w = kScreenWidth * scale; h = kScreenHeight * scale;
    } else {
        return NO;
    }
    float rect[4] = {0.0f, 0.0f, w, h};
    if (dst) GuestWrite(vm, dst, rect, sizeof(rect));
    GuestSetRet(vm, dst);
    return YES;
}
