// System-library provisioning for the original armv7 image.
//
// The 2011 binary links 20 system libraries. The host only links a handful, so
// dlsym(RTLD_DEFAULT, ...) would report most of the guest's imports as missing
// even though the arm64 simulator runtime provides them. Loading every library
// the original asked for is what makes the automatic bridge able to reach the
// real implementations -- including OpenGLES1, which the arm64 simulator still
// exports in full.

#import "HLE.h"
#import "GuestVM.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <string.h>
#import <vector>

// Every LC_LOAD_DYLIB in the original, in link order. libstdc++/libgcc_s are
// deliberately absent: the guest's old GCC COW std::string is emulated in
// HLE_stdcxx.m and must never be answered by the host's libc++.
static const char *kGuestLibraries[] = {
    "/usr/lib/libiconv.2.dylib",
    "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/UIKit.framework/UIKit",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer",
    "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
    "/System/Library/Frameworks/OpenAL.framework/OpenAL",
    "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
    "/System/Library/Frameworks/GameKit.framework/GameKit",
    "/System/Library/Frameworks/AddressBook.framework/AddressBook",
    "/System/Library/Frameworks/AddressBookUI.framework/AddressBookUI",
    "/System/Library/Frameworks/CoreMotion.framework/CoreMotion",
    "/System/Library/Frameworks/CoreAudio.framework/CoreAudio",
    "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",
};

static std::vector<std::string> g_loadedLibraries;
static std::vector<std::string> g_absentLibraries;

void HLELoadGuestFrameworks(void) {
    static bool done = false;
    if (done) return;
    done = true;
    for (const char *path : kGuestLibraries) {
        void *h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        if (h) {
            g_loadedLibraries.push_back(path);
        } else {
            g_absentLibraries.push_back(path);
        }
    }
}

NSArray<NSString *> *HLELoadedLibraries(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (auto &s : g_loadedLibraries) [out addObject:[NSString stringWithUTF8String:s.c_str()]];
    return out;
}

NSArray<NSString *> *HLEAbsentLibraries(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (auto &s : g_absentLibraries) [out addObject:[NSString stringWithUTF8String:s.c_str()]];
    return out;
}

// --- import audit -----------------------------------------------------------
// Reads the extracted undefined-import list and reports, per library family,
// how many of the guest's imports the arm64 runtime can actually answer.
NSDictionary<NSString *, NSNumber *> *HLEAuditImports(NSString *listPath,
                                                      NSArray<NSString *> **firstMissing) {
    NSMutableDictionary *byFamily = [NSMutableDictionary dictionary];
    NSMutableArray *missing = [NSMutableArray array];
    NSData *raw = [NSData dataWithContentsOfFile:listPath];
    if (!raw) return nil;
    NSArray<NSString *> *lines =
        [[NSString stringWithUTF8String:(const char *)raw.bytes] componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *sym = [line stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (sym.length < 2 || ![sym hasPrefix:@"_"]) continue;
        NSString *family = @"libSystem";
        if ([sym hasPrefix:@"_OBJC_CLASS_$"] || [sym hasPrefix:@"_OBJC_METACLASS_$"]) {
            family = @"ObjC class";
        } else if ([sym hasPrefix:@"_gl"] || [sym hasPrefix:@"_egl"]) {
            family = @"OpenGLES";
        } else if ([sym hasPrefix:@"_al"] || [sym hasPrefix:@"_alc"]) {
            family = @"OpenAL";
        } else if ([sym hasPrefix:@"_AudioSession"] || [sym hasPrefix:@"_Audio"] ||
                   [sym hasPrefix:@"_ExtAudioFile"] || [sym hasPrefix:@"_SystemSound"]) {
            family = @"AudioToolbox";
        } else if ([sym hasPrefix:@"_MP"] || [sym hasPrefix:@"_AV"]) {
            family = @"Media";
        } else if ([sym hasPrefix:@"_objc_"] || [sym hasPrefix:@"_class_"] ||
                   [sym hasPrefix:@"_sel_"] || [sym hasPrefix:@"_method_"]) {
            family = @"libobjc";
        } else if ([sym hasPrefix:@"__Z"] || [sym hasPrefix:@"__ZN"] || [sym hasPrefix:@"__ZTV"]) {
            family = @"libstdc++ (C++)";
        } else if ([sym hasPrefix:@"_UI"]) {
            family = @"UIKit";
        } else if ([sym hasPrefix:@"_CF"]) {
            family = @"CoreFoundation";
        } else if ([sym hasPrefix:@"_CG"]) {
            family = @"CoreGraphics";
        }
        const char *plain = sym.UTF8String + 1;
        bool ok = dlsym(RTLD_DEFAULT, plain) != nullptr;
        if (!ok && [family isEqualToString:@"ObjC class"]) {
            ok = objc_getClass(sym.UTF8String + 14) != nullptr;
        }
        NSString *key = [NSString stringWithFormat:@"%@/%@", family, ok ? @"ok" : @"missing"];
        NSNumber *prev = byFamily[key];
        byFamily[key] = @(prev.unsignedIntegerValue + 1);
        if (!ok && missing.count < 400) [missing addObject:sym];
    }
    if (firstMissing) *firstMissing = missing;
    return byFamily;
}
