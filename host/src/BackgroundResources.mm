#import <Foundation/Foundation.h>
#import "ResourcePaths.h"
#import <errno.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <fcntl.h>
#include <cstdlib>
#include "BackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include <array>
#include <unordered_map>
#include <vector>
#include "LoadingBackgroundAspect.hpp"
#include "RetinaBackgroundAspect.hpp"
#include "UIBackgroundAspect.hpp"

// Uses native canvas dimensions; no guest memory, GL call or screen override.
extern "C" bool GuestBackgroundPhysicalSize(double *width, double *height);

namespace {
struct ErrnoScope { int value = errno; ~ErrnoScope() { errno = value; } };
static bool Enabled() {
    const char *value = getenv("AS6_AI_BACKGROUNDS");
    return !value || strcmp(value, "0");
}
static NSString *Resolved(NSString *path) {
    if (!path.isAbsolutePath)
        path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}
static bool RegularFile(NSString *path, size_t expectedSize) {
    struct stat info;
    return !lstat(path.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
           info.st_size >= 0 && (uint64_t)info.st_size == expectedSize;
}
struct BackgroundSpec { const char *source; const char *art; int loading; bool blue = false; unsigned retina = 0, nominal_w = 0, nominal_h = 0; as6_background::Profile profile = as6_background::Profile::Title269Phone45; };
static constexpr BackgroundSpec kBackgrounds[] = {
    {"file000269.dat", "title-cover-16x9-v1.jpg", 0},
    {"file000786.dat", "title-cover-zh-cn-16x9-v1.jpg", 0, false, 0, 0, 0, as6_background::Profile::Title786ChinesePhone45},
    {"file000670.dat", "blue-menu-16x9-v1.jpg", 0, true},
    {"file000032.dat", "loading-000032-16x9-v1.jpg", 32},
    {"file000120.dat", "loading-000120-16x9-v1.jpg", 120},
    {"file000235.dat", "loading-000235-16x9-v1.jpg", 235},
    {"file000298.dat", "loading-000298-16x9-v1.jpg", 298},
    {"file000307.dat", "loading-000307-16x9-v1.jpg", 307},
    {"file000334.dat", "loading-000334-16x9-v1.jpg", 334},
    {"file000472.dat", "loading-000472-16x9-v1.jpg", 472},
    {"file000523.dat", "loading-000523-16x9-v1.jpg", 523},
    {"file000663.dat", "loading-000663-16x9-v1.jpg", 663},
    {"file000671.dat", "loading-000671-16x9-v1.jpg", 671},
    {"file000771.dat", "loading-000771-16x9-v1.jpg", 771},
    {"file000807.dat", "loading-000807-16x9-v1.jpg", 807},
    {"file000719.dat", "title-cover-16x9-v1.jpg", 0, false, 719, 512, 512},
    {"file000494.dat", "title-cover-zh-cn-16x9-v1.jpg", 0, false, 494, 512, 512},
    {"file000629.dat", "blue-menu-16x9-v1.jpg", 0, false, 629, 1024, 512},
    {"file000272.dat", "loading-000032-16x9-v1.jpg", 0, false, 272, 512, 512},
    {"file000765.dat", "loading-000120-16x9-v1.jpg", 0, false, 765, 512, 512},
    {"file000847.dat", "loading-000235-16x9-v1.jpg", 0, false, 847, 512, 512},
    {"file000695.dat", "loading-000298-16x9-v1.jpg", 0, false, 695, 512, 512},
    {"file000285.dat", "loading-000307-16x9-v1.jpg", 0, false, 285, 512, 512},
    {"file000676.dat", "loading-000334-16x9-v1.jpg", 0, false, 676, 512, 512},
    {"file000754.dat", "loading-000472-16x9-v1.jpg", 0, false, 754, 512, 512},
    {"file000883.dat", "loading-000523-16x9-v1.jpg", 0, false, 883, 512, 512},
    {"file000620.dat", "loading-000663-16x9-v1.jpg", 0, false, 620, 512, 512},
    {"file000641.dat", "loading-000671-16x9-v1.jpg", 0, false, 641, 512, 512},
    {"file000464.dat", "loading-000771-16x9-v1.jpg", 0, false, 464, 512, 512},
    {"file000234.dat", "loading-000807-16x9-v1.jpg", 0, false, 234, 512, 512},
};
struct UIBackgroundSpec { const char *source; as6_ui_background::Profile profile; bool variable_rle; };
static constexpr UIBackgroundSpec kUIBackgrounds[] = {
    {"file000019.dat", static_cast<as6_ui_background::Profile>(19), false},
    {"file000082.dat", static_cast<as6_ui_background::Profile>(82), false},
    {"file000117.dat", static_cast<as6_ui_background::Profile>(117), false},
    {"file000423.dat", static_cast<as6_ui_background::Profile>(423), false},
    {"file000534.dat", static_cast<as6_ui_background::Profile>(534), false},
    {"file000630.dat", static_cast<as6_ui_background::Profile>(630), false},
    {"file000683.dat", static_cast<as6_ui_background::Profile>(683), false},
    {"file000745.dat", static_cast<as6_ui_background::Profile>(745), false},
    {"file000871.dat", static_cast<as6_ui_background::Profile>(871), false},
    {"file000296.dat", static_cast<as6_ui_background::Profile>(296), false},
    {"file000063.dat", static_cast<as6_ui_background::Profile>(63), true},
    {"file000273.dat", static_cast<as6_ui_background::Profile>(273), false},
    {"file000859.dat", static_cast<as6_ui_background::Profile>(859), false},
    {"file000316.dat", static_cast<as6_ui_background::Profile>(316), false},
    {"file000184.dat", static_cast<as6_ui_background::Profile>(184), false},
    {"file000804.dat", static_cast<as6_ui_background::Profile>(804), false},
};
static const char *UIArtName(as6_ui_background::ArtKind kind) {
    switch(kind) {
    case as6_ui_background::ArtKind::Info: return "info-background-16x9-v1.jpg";
    case as6_ui_background::ArtKind::Unlocks: return "unlocks-background-16x9-v1.jpg";
    case as6_ui_background::ArtKind::Multiplayer: return "multiplayer-background-16x9-v1.jpg";
    case as6_ui_background::ArtKind::Map: return "quickrace-map-16x9-v1.jpg";
    case as6_ui_background::ArtKind::Options: return "options-grid-16x9-v1.jpg";
    }
    return nullptr;
}

// Main-thread metadata only. Cache hits retain no decoded pixels or atlas copy.
// An entry is admitted only after the existing source pins and full generated
// file SHA have passed. Any source/art/output replacement or edit invalidates
// it, including same-length writes and timestamps restored with utimensat.
struct FileVersion {
    std::string path;
    dev_t device=0; ino_t inode=0; off_t size=0;
    mode_t mode=0; uid_t uid=0; gid_t gid=0;
    timespec modified{}, changed{};
    bool operator==(const FileVersion &other) const {
        return path==other.path && device==other.device && inode==other.inode &&
            size==other.size && mode==other.mode && uid==other.uid && gid==other.gid &&
            modified.tv_sec==other.modified.tv_sec && modified.tv_nsec==other.modified.tv_nsec &&
            changed.tv_sec==other.changed.tv_sec && changed.tv_nsec==other.changed.tv_nsec;
    }
};
static bool Version(NSString *path, FileVersion &out) {
    struct stat info{};
    if (!path || lstat(path.fileSystemRepresentation,&info) ||
        !S_ISREG(info.st_mode) || info.st_size<0) return false;
    out={path.fileSystemRepresentation,info.st_dev,info.st_ino,info.st_size,
         info.st_mode,info.st_uid,info.st_gid,info.st_mtimespec,info.st_ctimespec};
    return true;
}
static bool Versions(NSArray<NSString *> *paths, std::vector<FileVersion> &out) {
    out.clear();
    for (NSString *path in paths) {
        FileVersion value;
        if (!Version(path,value)) { out.clear(); return false; }
        out.push_back(std::move(value));
    }
    return true;
}
struct PreparedBackground {
    NSString *__strong path=nil;
    std::vector<FileVersion> inputs;
    FileVersion output;
};
static std::unordered_map<std::string,PreparedBackground> g_preparedBackgrounds;

static bool MayPrepare(NSString *path) {
    if (!path || !Enabled() || !NSThread.isMainThread) return false;
    const char *name=path.lastPathComponent.UTF8String;
    if (!name) return false;
    for (const auto &item:kBackgrounds) if (!strcmp(name,item.source)) return true;
    for (const auto &item:kUIBackgrounds) if (!strcmp(name,item.source)) return true;
    return false;
}
static NSString *Candidate(NSString *path) {
    if (!path || !Enabled() || !NSThread.isMainThread) return path;
    const char *basename = path.lastPathComponent.UTF8String;
    const BackgroundSpec *spec = nullptr;
    for (const auto &item : kBackgrounds) if (basename && !strcmp(basename, item.source)) { spec = &item; break; }
    const UIBackgroundSpec *uiSpec = nullptr;
    if (!spec) for (const auto &item : kUIBackgrounds) if (basename && !strcmp(basename, item.source)) { uiSpec = &item; break; }
    if (!spec && !uiSpec) return path;
    const char *sourceName = spec ? spec->source : uiSpec->source;
    NSString *bundle = AS6ResourceRootPath();
    if(!bundle)return path;
    NSString *originalPath = [bundle stringByAppendingPathComponent:[@"data" stringByAppendingPathComponent:[NSString stringWithUTF8String:sourceName]]];
    if (![Resolved(path) isEqualToString:Resolved(originalPath)]) return path;
    double width = 0, height = 0;
    if (!GuestBackgroundPhysicalSize(&width, &height)) return path;

    NSMutableArray<NSString *> *dependencies=[NSMutableArray arrayWithObject:originalPath];
    if (uiSpec) {
        as6_ui_background::ArtKind required[2];
        const size_t count=as6_ui_background::RequiredArts(uiSpec->profile,required);
        if (!count || count>2) return path;
        for (size_t i=0;i<count;++i) {
            const char *name=UIArtName(required[i]);
            if (!name) return path;
            [dependencies addObject:[bundle stringByAppendingPathComponent:
                [@"NativeArtwork" stringByAppendingPathComponent:[NSString stringWithUTF8String:name]]]];
        }
    } else {
        [dependencies addObject:[bundle stringByAppendingPathComponent:
            [@"NativeArtwork" stringByAppendingPathComponent:[NSString stringWithUTF8String:spec->art]]]];
    }
    char dimensions[128];
    snprintf(dimensions,sizeof(dimensions),"%.17g/%.17g",width,height);
    const std::string memoKey=std::string(originalPath.fileSystemRepresentation)+":"+dimensions;
    std::vector<FileVersion> inputVersions;
    const bool versioned=Versions(dependencies,inputVersions);
    const auto prior=g_preparedBackgrounds.find(memoKey);
    if (prior!=g_preparedBackgrounds.end()) {
        FileVersion actual;
        if (versioned && prior->second.inputs==inputVersions &&
            Version(prior->second.path,actual) && actual==prior->second.output)
            return prior->second.path;
        g_preparedBackgrounds.erase(prior);
    }

    // Keep actual FILE/fd semantics (including seek/stat/mmap) on a derived
    // private cache file. Original bundle data and coordinates stay untouched.
    NSData *original = [NSData dataWithContentsOfFile:originalPath options:0 error:nil];
    if (!original) return path;
    as6_background::Result output;
    std::string error;
    bool materialized = false;
    if (uiSpec) {
        as6_ui_background::ArtKind required[2];
        const size_t count = as6_ui_background::RequiredArts(uiSpec->profile, required);
        if (!count || count > 2) return path;
        // Views borrow bytes: retain exactly the required1/2 NSData owners
        // through Materialize, including optimized ARC early-release points.
        __attribute__((objc_precise_lifetime)) NSMutableArray<NSData *> *owners = [NSMutableArray new];
        if (!owners) return path;
        std::array<as6_background::DecodedArtwork,2> decodedArts;
        as6_ui_background::ArtView views[2]{};
        for (size_t i = 0; i < count; ++i) {
            const char *name = UIArtName(required[i]);
            if (!name) return path;
            NSString *artPath = [bundle stringByAppendingPathComponent:[@"NativeArtwork" stringByAppendingPathComponent:[NSString stringWithUTF8String:name]]];
            NSData *art = [NSData dataWithContentsOfFile:artPath options:0 error:nil];
            if (!art) return path;
            [owners addObject:art];
            if (!as6_background::DecodeArtworkJpeg(name,(const uint8_t*)art.bytes,art.length,decodedArts[i],error)) return path;
            views[i] = {required[i], decodedArts[i].data(), decodedArts[i].size(), &decodedArts[i]};
        }
        materialized = as6_ui_background::Materialize(uiSpec->profile,
            (const uint8_t *)original.bytes, original.length, views, count,
            width, height, output, error);
    } else {
        NSString *artPath = [bundle stringByAppendingPathComponent:[@"NativeArtwork" stringByAppendingPathComponent:[NSString stringWithUTF8String:spec->art]]];
        __attribute__((objc_precise_lifetime)) NSData *art = [NSData dataWithContentsOfFile:artPath options:0 error:nil];
        if (!art) return path;
        as6_background::DecodedArtwork decodedArt;
        if (!as6_background::DecodeArtworkJpeg(spec->art,(const uint8_t*)art.bytes,art.length,decodedArt,error)) return path;
        if (spec->retina) {
            materialized = as6_retina_background::MaterializeDecoded(static_cast<as6_retina_background::Profile>(spec->retina),
                (const uint8_t *)original.bytes, original.length, decodedArt,
                {spec->nominal_w, spec->nominal_h}, width, height, output, error);
        } else {
        materialized = spec->loading
            ? as6_loading_background::MaterializeDecoded(static_cast<as6_loading_background::Profile>(spec->loading),
                (const uint8_t *)original.bytes, original.length, decodedArt,
                width, height, output, error)
            : as6_background::MaterializeDecoded(spec->blue ? as6_background::Profile::Blue670Phone659Experimental : spec->profile,
                (const uint8_t *)original.bytes, original.length, decodedArt,
                width, height, spec->blue, output, error);
        }
    }
    if (!materialized) return path;
    if (output.cache_key.size() != 64 ||
        output.cache_key.find_first_not_of("0123456789abcdef") != std::string::npos ||
        (!uiSpec || !uiSpec->variable_rle
            ? output.original_layout_tga.size() != original.length
            // Only the authenticated2048x2048 type10 source63 permits a changed
            // packet length. Literal packets bound the derived encoded size.
            : output.original_layout_tga.size() < 44 ||
              output.original_layout_tga.size() > 18u + 2048u*2048u*4u + 32768u + 26u)) return path;
    NSString *base = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!base) return path;
    NSString *directory = [base stringByAppendingPathComponent:@"AS6NativeBackgrounds"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:nil]) return path;
    NSString *name = [[NSString stringWithUTF8String:output.cache_key.c_str()] stringByAppendingPathExtension:@"dat"];
    NSString *cachePath = [directory stringByAppendingPathComponent:name];
    const std::string expected = as6_background::Sha256(output.original_layout_tga.data(), output.original_layout_tga.size());
    NSData *cached = RegularFile(cachePath, output.original_layout_tga.size())
        ? [NSData dataWithContentsOfFile:cachePath options:0 error:nil] : nil;
    bool valid = cached && as6_background::Sha256((const uint8_t *)cached.bytes, cached.length) == expected;
    if (!valid) {
        NSData *data = [NSData dataWithBytes:output.original_layout_tga.data() length:output.original_layout_tga.size()];
        if (![data writeToFile:cachePath options:NSDataWritingAtomic error:nil] ||
            !RegularFile(cachePath, output.original_layout_tga.size())) return path;
        chmod(cachePath.fileSystemRepresentation, 0600);
    }
    std::vector<FileVersion> afterVersions;
    FileVersion cacheVersion;
    if (versioned && Versions(dependencies,afterVersions) && afterVersions==inputVersions &&
        Version(cachePath,cacheVersion) && cacheVersion.size==(off_t)output.original_layout_tga.size()) {
        // Bound metadata growth across unusual resizes; eviction only requires
        // reauthentication on the next open and never removes resource files.
        if (g_preparedBackgrounds.size()>=128) g_preparedBackgrounds.clear();
        g_preparedBackgrounds.emplace(memoKey,PreparedBackground{cachePath,std::move(inputVersions),std::move(cacheVersion)});
    }
    static unsigned messages = 0;
    if (messages < 16) {
        ++messages;
        fprintf(stderr, "[ai-background] %s aspect=%.9f crop=%.3f,%.3f,%.3f,%.3f original_layout=1\n",
                sourceName, output.physical_aspect, output.art_crop.x, output.art_crop.y,
                output.art_crop.width, output.art_crop.height);
    }
    return cachePath;
}
}

// A cheap hint for the libc bridge. Its optional preparation work touches only
// host-owned paths, UIKit canvas dimensions and private cache bytes, so that
// bridge may release the guest execution lock while it runs on the main thread.
extern "C" BOOL AS6BackgroundMayPreparePath(NSString *path) {
    const ErrnoScope saved;
    return MayPrepare(path);
}

// Only read-only resource opens call this. On any unsupported input or failure,
// keep the original path and errno; the original host open reports its error.
extern "C" NSString *AS6BackgroundReadPath(NSString *path) {
    const ErrnoScope saved;
    @try { try { return Candidate(path); } catch (...) { return path; } }
    @catch (NSException *exception) { (void)exception; return path; }
}

extern "C" NSString *AS6BackgroundFopenPath(NSString *path, NSString *mode) {
    const ErrnoScope saved;
    if (![mode isEqualToString:@"r"] && ![mode isEqualToString:@"rb"]) return path;
    return AS6BackgroundReadPath(path);
}
extern "C" NSString *AS6BackgroundOpenPath(NSString *path, int flags) {
    const ErrnoScope saved;
    // Preserve special path semantics, including O_NOFOLLOW/O_SYMLINK.
    if ((flags & ~O_CLOEXEC) != O_RDONLY) return path;
    return AS6BackgroundReadPath(path);
}
