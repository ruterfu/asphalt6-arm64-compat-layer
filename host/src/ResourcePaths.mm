#import "ResourcePaths.h"
#include "ResourcePackConfig.hpp"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <cerrno>
#include <climits>
#include <limits.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mutex>
#include <vector>

namespace {
struct ErrnoScope { int saved=errno; ~ErrnoScope(){errno=saved;} };
static std::mutex validationMutex;
static NSDictionary *readyState;
static bool gameStarted=false;
#if defined(AS6_RESOURCE_PATH_TESTING)
static void (^testValidationHook)(NSString *,NSString *);
#endif
static NSObject *StateLock(){static NSObject *lock;static dispatch_once_t once;dispatch_once(&once,^{lock=[NSObject new];});return lock;}
static NSDictionary *Snapshot(){@synchronized(StateLock()){return readyState;}}
static NSString *Digest(NSData *data){unsigned char b[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,b);char h[65];for(int i=0;i<32;++i)snprintf(h+i*2,3,"%02x",b[i]);return @(h);}
static bool HexSHA(id value){if(![value isKindOfClass:NSString.class]||[value length]!=64)return false;return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location==NSNotFound;}
static bool SafeRelative(NSString *p){if(![p isKindOfClass:NSString.class]||!p.length||p.isAbsolutePath||[p hasSuffix:@"/"]||[p containsString:@"\\"]||[p rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)return false;for(NSString *c in [p componentsSeparatedByString:@"/"])if(!c.length||[c isEqual:@"."]||[c isEqual:@".."])return false;return true;}
static BOOL Fail(NSError **error,NSString *message){if(error)*error=[NSError errorWithDomain:@"AS6Resources" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;}
static NSDictionary *Fingerprint(const struct stat &s){return @{@"device":@((uint64_t)s.st_dev),@"inode":@((uint64_t)s.st_ino),@"size":@((int64_t)s.st_size),@"mtime_s":@((int64_t)s.st_mtimespec.tv_sec),@"mtime_ns":@(s.st_mtimespec.tv_nsec),@"ctime_s":@((int64_t)s.st_ctimespec.tv_sec),@"ctime_ns":@(s.st_ctimespec.tv_nsec)};}
static int OpenRelative(int root,NSString *path){NSArray<NSString *> *parts=[path componentsSeparatedByString:@"/"];int directory=dup(root);if(directory<0)return -1;for(NSUInteger i=0;i+1<parts.count;++i){int next=openat(directory,parts[i].fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);int saved=errno;close(directory);if(next<0){errno=saved;return -1;}directory=next;}int fd=openat(directory,parts.lastObject.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);int saved=errno;close(directory);errno=saved;return fd;}
static NSString *HashFD(int fd){CC_SHA256_CTX c;CC_SHA256_Init(&c);uint8_t bytes[65536];for(;;){ssize_t n=read(fd,bytes,sizeof(bytes));if(n<0){if(errno==EINTR)continue;return nil;}if(!n)break;CC_SHA256_Update(&c,bytes,(CC_LONG)n);}unsigned char b[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(b,&c);char h[65];for(int i=0;i<32;++i)snprintf(h+2*i,3,"%02x",b[i]);return @(h);}
static NSDictionary *ReadSmallJSON(NSString *file,NSUInteger cap){struct stat s;if(lstat(file.fileSystemRepresentation,&s)||!S_ISREG(s.st_mode)||s.st_size<0||(uint64_t)s.st_size>cap)return nil;NSData *d=[NSData dataWithContentsOfFile:file];id x=d?[NSJSONSerialization JSONObjectWithData:d options:0 error:nil]:nil;return [x isKindOfClass:NSDictionary.class]?x:nil;}
static NSString *Absolute(NSString *p){return (p.isAbsolutePath?p:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:p]).stringByStandardizingPath;}
static NSArray<NSString *> *TrustedAliases(NSString *p,NSString *verifiedCanonical=nil){NSMutableSet *out=[NSMutableSet setWithObject:Absolute(p)];char canonical[PATH_MAX];if(verifiedCanonical)[out addObject:verifiedCanonical];else if(realpath(p.fileSystemRepresentation,canonical))[out addObject:@(canonical)];for(NSString *s in [out allObjects]){if([s hasPrefix:@"/private/var/"]||[s hasPrefix:@"/private/tmp/"])[out addObject:[s substringFromIndex:8]];else if([s hasPrefix:@"/var/"]||[s hasPrefix:@"/tmp/"])[out addObject:[@"/private" stringByAppendingString:s]];}return [[out allObjects]sortedArrayUsingSelector:@selector(compare:)];}
static void PrepareImportHelp(NSString *documents){ErrnoScope e;if(!documents)return;[NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];NSString *path=[documents stringByAppendingPathComponent:@"资源导入说明.txt"];int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return;NSData *text=[@"把 Asphalt6Data.zip 放在本目录（与本说明同级），打开游戏会自动解压并验证。\n可选：把高清背景包 NativeArtwork.zip 也放在本目录。\n请保留已有存档文件。\n" dataUsingEncoding:NSUTF8StringEncoding];const uint8_t *p=(const uint8_t *)text.bytes;size_t remaining=text.length;while(remaining){ssize_t n=write(fd,p,remaining);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;remaining-=n;}close(fd);}
static BOOL Within(NSString *path,NSString *root){return [path isEqual:root]||[path hasPrefix:[root stringByAppendingString:@"/"]];}
static BOOL Validate(NSString *root,NSString *bundle,NSData *trusted,NSString *expected,NSString *cacheFile,BOOL force,NSDictionary **details,NSError **error){
    ErrnoScope preserve;std::lock_guard<std::mutex> serial(validationMutex);
    @synchronized(StateLock()){if(gameStarted)return Fail(error,@"游戏已启动，请重新打开应用后检查资源。");readyState=nil;}
    if(details)*details=nil;if(error)*error=nil;
    if(!HexSHA(expected)||trusted.length>2*1024*1024||![Digest(trusted)isEqual:expected])return Fail(error,@"应用资源清单无效，请重新安装应用。");
    id decoded=[NSJSONSerialization JSONObjectWithData:trusted options:0 error:nil];if(![decoded isKindOfClass:NSDictionary.class])return Fail(error,@"应用资源清单无效，请重新安装应用。");NSDictionary *manifest=decoded;NSDictionary *files=manifest[@"files"];
    if(![manifest isKindOfClass:NSDictionary.class]||![manifest[@"format"]isEqual:@"as6-documents-resource-pack-v1"]||[manifest[@"schema_version"]integerValue]!=1||![files isKindOfClass:NSDictionary.class]||!files.count||files.count!=[manifest[@"total_files"]unsignedIntegerValue])return Fail(error,@"应用资源清单无效，请重新安装应用。");
    NSMutableSet *dirs=[NSMutableSet setWithObject:@""];NSMutableSet *tops=[NSMutableSet new];uint64_t sum=0;
    for(NSString *name in files){NSDictionary *entry=files[name];if(![entry isKindOfClass:NSDictionary.class])return Fail(error,@"应用资源清单无效，请重新安装应用。");NSNumber *length=entry[@"bytes"];
        if(!SafeRelative(name)||![entry isKindOfClass:NSDictionary.class]||![length isKindOfClass:NSNumber.class]||length.longLongValue<0||!HexSHA(entry[@"sha256"])||ULLONG_MAX-sum<length.unsignedLongLongValue)return Fail(error,@"应用资源清单无效，请重新安装应用。");
        sum+=length.unsignedLongLongValue;[tops addObject:[name componentsSeparatedByString:@"/"].firstObject];NSString *parent=name.stringByDeletingLastPathComponent;while(parent.length){[dirs addObject:parent];NSString *next=parent.stringByDeletingLastPathComponent;if([next isEqual:parent])break;parent=next;}
    }
    if(sum!=[manifest[@"total_bytes"]unsignedLongLongValue])return Fail(error,@"应用资源清单无效，请重新安装应用。");
    NSString *requestedRoot=Absolute(root);int rootFD=open(requestedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(rootFD<0)return Fail(error,@"尚未找到资源，请将完整的 Asphalt6Data 文件夹放入本应用的文稿目录，再点击“重新检测”。");
    struct stat rootStat{};if(fstat(rootFD,&rootStat)){close(rootFD);return Fail(error,@"资源目录无法读取，请重新复制资源后再试。");}
    char canonicalBytes[PATH_MAX];if(!realpath(requestedRoot.stringByDeletingLastPathComponent.fileSystemRepresentation,canonicalBytes)){close(rootFD);return Fail(error,@"资源目录无法读取，请重新复制资源后再试。");}NSString *canonicalRoot=[@(canonicalBytes)stringByAppendingPathComponent:requestedRoot.lastPathComponent];
    int manifestFD=OpenRelative(rootFD,@"resource-manifest.json");struct stat manifestBefore{},manifestAfter{};NSMutableData *docManifest=[NSMutableData new];bool manifestOK=manifestFD>=0&&!fstat(manifestFD,&manifestBefore)&&S_ISREG(manifestBefore.st_mode)&&(uint64_t)manifestBefore.st_size==trusted.length;
    if(manifestOK){uint8_t chunk[16384];for(;;){ssize_t n=read(manifestFD,chunk,sizeof(chunk));if(n<0&&errno==EINTR)continue;if(n<0){manifestOK=false;break;}if(!n)break;[docManifest appendBytes:chunk length:(NSUInteger)n];if(docManifest.length>trusted.length){manifestOK=false;break;}}manifestOK=manifestOK&&!fstat(manifestFD,&manifestAfter)&&[Fingerprint(manifestBefore)isEqual:Fingerprint(manifestAfter)]&&[docManifest isEqual:trusted];}
    if(manifestFD>=0)close(manifestFD);if(!manifestOK){close(rootFD);return Fail(error,@"资源包版本不匹配或不完整，请重新复制完整资源包后再试。");}
    NSDictionary *cache=force?nil:ReadSmallJSON(cacheFile,4*1024*1024);NSDictionary *rootIdentity=Fingerprint(rootStat);BOOL cacheAllowed=[cache[@"manifest_sha256"]isEqual:expected]&&[cache[@"root"]isEqual:canonicalRoot]&&[cache[@"root_identity"]isEqual:rootIdentity]&&[cache[@"files"]isKindOfClass:NSDictionary.class];
    NSMutableDictionary *stats=[NSMutableDictionary new];NSUInteger hashed=0,reused=0;BOOL valid=YES;NSString *failure=nil;
    for(NSString *name in [[files allKeys]sortedArrayUsingSelector:@selector(compare:)]){@autoreleasepool{
        int fd=OpenRelative(rootFD,name);struct stat before{},after{};if(fd<0||fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_size<0||(uint64_t)before.st_size!=[files[name][@"bytes"]unsignedLongLongValue]){if(fd>=0)close(fd);valid=NO;failure=@"资源文件缺失或大小不符，请重新复制完整资源包。";break;}
        NSDictionary *identity=Fingerprint(before);BOOL hit=cacheAllowed&&[cache[@"files"][name]isEqual:identity];NSString *digest=hit?nil:HashFD(fd);
        BOOL stable=!fstat(fd,&after)&&[identity isEqual:Fingerprint(after)];close(fd);
#if defined(AS6_RESOURCE_PATH_TESTING)
        if(testValidationHook)testValidationHook(@"after-file-read",name);
#endif
        int currentFD=OpenRelative(rootFD,name);struct stat current{};stable=stable&&currentFD>=0&&!fstat(currentFD,&current)&&[identity isEqual:Fingerprint(current)];if(currentFD>=0)close(currentFD);
        if(!stable||(!hit&&![digest isEqual:files[name][@"sha256"]])){valid=NO;failure=@"资源文件校验失败，请重新复制完整资源包。";break;}
        stats[name]=identity;if(hit)++reused;else ++hashed;
    }}
    if(valid)for(NSString *name in stats){int fd=OpenRelative(rootFD,name);struct stat current{};BOOL unchanged=fd>=0&&!fstat(fd,&current)&&[stats[name]isEqual:Fingerprint(current)];if(fd>=0)close(fd);if(!unchanged){valid=NO;failure=@"检查期间资源文件发生变化，请再点击“重新检测”。";break;}}
    #if defined(AS6_RESOURCE_PATH_TESTING)
    if(valid&&testValidationHook)testValidationHook(@"before-root-reopen",@"");
    #endif
    int rootNow=open(requestedRoot.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat namedRoot{};BOOL sameNamedRoot=rootNow>=0&&!fstat(rootNow,&namedRoot)&&[rootIdentity isEqual:Fingerprint(namedRoot)];if(rootNow>=0)close(rootNow);if(!sameNamedRoot){valid=NO;failure=@"检查期间资源目录发生变化，请再点击“重新检测”。";}
    struct stat rootAfter{};if(fstat(rootFD,&rootAfter)||![rootIdentity isEqual:Fingerprint(rootAfter)]){valid=NO;failure=@"检查期间资源目录发生变化，请再点击“重新检测”。";}close(rootFD);
    if(!valid)return Fail(error,failure);
    NSDictionary *newCache=@{@"manifest_sha256":expected,@"root":canonicalRoot,@"root_identity":rootIdentity,@"files":stats};NSData *cacheBytes=[NSJSONSerialization dataWithJSONObject:newCache options:0 error:nil];
    NSString *cacheParent=cacheFile.stringByDeletingLastPathComponent;[NSFileManager.defaultManager createDirectoryAtPath:cacheParent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];[cacheBytes writeToFile:cacheFile options:NSDataWritingAtomic error:nil];
    NSDictionary *state=@{@"root":canonicalRoot,@"root_aliases":TrustedAliases(requestedRoot,canonicalRoot),@"bundle":Absolute(bundle),@"bundle_aliases":TrustedAliases(bundle),@"files":[files copy],@"dirs":[dirs copy],@"tops":[tops copy],@"manifest_sha256":expected};@synchronized(StateLock()){readyState=state;}
    if(details)*details=@{@"ready":@YES,@"manifest_sha256":expected,@"total_files":@(files.count),@"total_bytes":@(sum),@"hashed_files":@(hashed),@"stat_cache_files":@(reused),@"root":canonicalRoot};return YES;
}
static BOOL ClassOrInstance(id target,Class c){if(!target||!c)return NO;Class meta=object_getClass(target);return class_isMetaClass(meta)?[(Class)target isSubclassOfClass:c]:[target isKindOfClass:c];}
static BOOL OneOf(NSString *s,NSArray<NSString *> *values){return [values containsObject:s];}
}

NSString *AS6ExpectedResourceRootPath(void){ErrnoScope e;NSString *docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;return [docs stringByAppendingPathComponent:@(as6_resource_pack::kRootName)];}
NSString *AS6ResourceRootPath(void){ErrnoScope e;return Snapshot()[@"root"];}
void AS6PrepareResourceImportHelp(void){PrepareImportHelp(NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject);}
void AS6ResourceMarkGameStarted(void){ErrnoScope e;@synchronized(StateLock()){gameStarted=true;}}
BOOL AS6ValidateDocumentResources(BOOL force,NSDictionary **details,NSError **error){ErrnoScope e;NSBundle *bundle=NSBundle.mainBundle;NSString *expected=@(as6_resource_pack::kManifestSHA256);if(![bundle.infoDictionary[@"AS6ResourceManifestSHA256"]isEqual:expected]||![bundle.infoDictionary[@"AS6ResourceLayout"]isEqual:@(as6_resource_pack::kLayout)])return Fail(error,@"应用资源配置无效，请重新安装应用。");NSString *trustedPath=[bundle.bundlePath stringByAppendingPathComponent:@"ResourcePack/resource-manifest.json"];struct stat st;if(lstat(trustedPath.fileSystemRepresentation,&st)||!S_ISREG(st.st_mode)||st.st_size<0||st.st_size>2*1024*1024)return Fail(error,@"应用资源清单缺失，请重新安装应用。");NSData *trusted=[NSData dataWithContentsOfFile:trustedPath];NSString *library=NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,NSUserDomainMask,YES).firstObject;NSString *cache=[library stringByAppendingPathComponent:[NSString stringWithFormat:@"Application Support/AS6ResourceValidation/%@.json",expected]];return Validate(AS6ExpectedResourceRootPath(),bundle.bundlePath,trusted,expected,cache,force,details,error);}

NSString *AS6ResolveResourceReadPath(NSString *path,BOOL *matched){ErrnoScope e;if(matched)*matched=NO;if(![path isKindOfClass:NSString.class]||!path.length)return path;NSDictionary *s=Snapshot();if(!s)return path;NSString *root=s[@"root"],*absolute=Absolute(path),*relative=nil;BOOL recognized=NO;
    for(NSString *alias in s[@"root_aliases"])if(Within(absolute,alias)){recognized=YES;relative=[absolute isEqual:alias]?@"":[absolute substringFromIndex:alias.length+1];break;}
    if(!recognized)for(NSString *alias in s[@"bundle_aliases"])if(Within(absolute,alias)){NSString *r=[absolute isEqual:alias]?@"":[absolute substringFromIndex:alias.length+1];NSString *top=[r componentsSeparatedByString:@"/"].firstObject;if(!r.length||[s[@"tops"]containsObject:top]){recognized=YES;relative=r;}break;}
    if(!recognized&&!path.isAbsolutePath){NSString *r=path.stringByStandardizingPath;NSString *top=[r componentsSeparatedByString:@"/"].firstObject;if(s[@"files"][r]||[s[@"dirs"]containsObject:r]||[s[@"tops"]containsObject:top]){recognized=YES;relative=r;}}
    if(!recognized)return path;if(matched)*matched=YES;if(relative.length&&!SafeRelative(relative))return nil;if(!relative.length||s[@"files"][relative]||[s[@"dirs"]containsObject:relative])return relative.length?[root stringByAppendingPathComponent:relative]:root;return nil;
}
NSURL *AS6ResolveResourceReadURL(NSURL *url,BOOL *matched){ErrnoScope e;if(matched)*matched=NO;if(![url isKindOfClass:NSURL.class]||!url.isFileURL)return url;BOOL hit=NO;NSString *p=AS6ResolveResourceReadPath(url.path,&hit);if(matched)*matched=hit;return hit?(p?[NSURL fileURLWithPath:p]:nil):url;}
BOOL AS6ResourceWriteProtectedPath(NSString *path){ErrnoScope e;if(!path.length)return NO;NSDictionary *s=Snapshot();if(!s)return NO;NSString *a=Absolute(path);for(NSString *alias in s[@"root_aliases"])if(Within(a,alias))return YES;BOOL hit=NO;(void)AS6ResolveResourceReadPath(path,&hit);return hit;}
NSString *AS6ResourceFopenReadPath(NSString *path,NSString *mode,int *errorCode){ErrnoScope e;if(errorCode)*errorCode=0;NSString *m=mode?:@"r";BOOL writing=[m hasPrefix:@"w"]||[m hasPrefix:@"a"]||[m containsString:@"+"];if(writing){if(AS6ResourceWriteProtectedPath(path)){if(errorCode)*errorCode=EROFS;return nil;}return path;}BOOL hit=NO;NSString *p=AS6ResolveResourceReadPath(path,&hit);if(hit&&!p&&errorCode)*errorCode=ENOENT;return p;}
NSString *AS6ResourceOpenReadPath(NSString *path,int flags,int *errorCode){ErrnoScope e;if(errorCode)*errorCode=0;BOOL writing=(flags&O_ACCMODE)!=O_RDONLY||(flags&(O_CREAT|O_TRUNC|O_APPEND));if(writing){if(AS6ResourceWriteProtectedPath(path)){if(errorCode)*errorCode=EROFS;return nil;}return path;}BOOL hit=NO;NSString *p=AS6ResolveResourceReadPath(path,&hit);if(hit&&!p&&errorCode)*errorCode=ENOENT;return p;}
NSString *AS6ResourceDeniedReadPath(void){ErrnoScope e;static NSString *missing;static dispatch_once_t once;dispatch_once(&once,^{NSString *base=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;missing=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"AS6MissingResource/%@/not-found",NSUUID.UUID.UUIDString]];});return missing;}
NSString *AS6ResourceBundlePath(NSString *name,NSString *extension,NSString *subdir,NSString *localization,BOOL *handled){ErrnoScope e;(void)localization;if(handled)*handled=NO;NSDictionary *s=Snapshot();if(!s||![name isKindOfClass:NSString.class]||!name.length)return nil;NSString *file=extension.length?[name stringByAppendingPathExtension:extension]:name;NSString *r=subdir.length?[subdir stringByAppendingPathComponent:file]:file;if(s[@"files"][r]||[s[@"dirs"]containsObject:r]){if(handled)*handled=YES;return [s[@"root"]stringByAppendingPathComponent:r];}NSString *top=[r componentsSeparatedByString:@"/"].firstObject;if([s[@"tops"]containsObject:top]){if(handled)*handled=YES;return nil;}if(!subdir.length&&!name.isAbsolutePath){NSMutableArray *found=[NSMutableArray new];for(NSString *member in s[@"files"])if([member.lastPathComponent isEqual:file])[found addObject:member];if(found.count==1){if(handled)*handled=YES;return [s[@"root"]stringByAppendingPathComponent:found.firstObject];}}return nil;}

id AS6ResourceReadObjectArgument(id target,SEL selector,NSUInteger index,id argument){ErrnoScope e;if(index!=2||!argument)return argument;NSString *sel=NSStringFromSelector(selector);BOOL path=NO,url=NO,urlString=NO;
    if(ClassOrInstance(target,NSData.class)||ClassOrInstance(target,NSString.class)){path=OneOf(sel,@[@"dataWithContentsOfFile:",@"dataWithContentsOfFile:options:error:",@"initWithContentsOfFile:",@"initWithContentsOfFile:options:error:",@"stringWithContentsOfFile:",@"stringWithContentsOfFile:encoding:error:",@"stringWithContentsOfFile:usedEncoding:error:",@"initWithContentsOfFile:encoding:error:",@"initWithContentsOfFile:usedEncoding:error:"]);url=OneOf(sel,@[@"dataWithContentsOfURL:",@"dataWithContentsOfURL:options:error:",@"initWithContentsOfURL:",@"initWithContentsOfURL:options:error:",@"stringWithContentsOfURL:encoding:error:",@"initWithContentsOfURL:encoding:error:"]);}
    if(ClassOrInstance(target,NSFileManager.class)){path=OneOf(sel,@[@"fileExistsAtPath:",@"fileExistsAtPath:isDirectory:",@"attributesOfItemAtPath:error:",@"attributesOfFileSystemForPath:error:",@"contentsAtPath:",@"contentsOfDirectoryAtPath:error:",@"enumeratorAtPath:",@"subpathsAtPath:",@"subpathsOfDirectoryAtPath:error:"]);url=OneOf(sel,@[@"contentsOfDirectoryAtURL:includingPropertiesForKeys:options:error:",@"enumeratorAtURL:includingPropertiesForKeys:options:errorHandler:"]);}
    if(ClassOrInstance(target,NSURL.class)){path=OneOf(sel,@[@"fileURLWithPath:",@"fileURLWithPath:isDirectory:",@"initFileURLWithPath:",@"initFileURLWithPath:isDirectory:"]);urlString=OneOf(sel,@[@"URLWithString:",@"initWithString:"]);}
    Class image=objc_lookUpClass("UIImage");if(image&&ClassOrInstance(target,image)&&[sel isEqual:@"imageWithContentsOfFile:"])path=YES;
    if(path&&[argument isKindOfClass:NSString.class]){BOOL hit=NO;NSString *p=AS6ResolveResourceReadPath(argument,&hit);return hit?(p?:AS6ResourceDeniedReadPath()):argument;}
    if(url&&[argument isKindOfClass:NSURL.class]){BOOL hit=NO;NSURL *p=AS6ResolveResourceReadURL(argument,&hit);return hit?(p?:[NSURL fileURLWithPath:AS6ResourceDeniedReadPath()]):argument;}
    if(urlString&&[argument isKindOfClass:NSString.class]){NSURL *u=[NSURL URLWithString:argument];if(u.isFileURL){BOOL hit=NO;NSURL *p=AS6ResolveResourceReadURL(u,&hit);return hit?(p?:[NSURL fileURLWithPath:AS6ResourceDeniedReadPath()]).absoluteString:argument;}}
    return argument;
}
id AS6ResourceReadReceiver(id target,SEL selector){ErrnoScope e;NSString *sel=NSStringFromSelector(selector);if(!OneOf(sel,@[@"path",@"fileSystemRepresentation",@"checkResourceIsReachableAndReturnError:",@"resourceValuesForKeys:error:",@"getResourceValue:forKey:error:",@"getFileSystemRepresentation:maxLength:"]))return target;if(![target isKindOfClass:NSURL.class]||![(NSURL *)target isFileURL])return target;BOOL hit=NO;NSURL *u=AS6ResolveResourceReadURL(target,&hit);return hit?(u?:[NSURL fileURLWithPath:AS6ResourceDeniedReadPath()]):target;}
#if defined(AS6_RESOURCE_PATH_TESTING)
BOOL AS6TestValidateResourceRoot(NSString *root,NSString *bundle,NSData *manifest,NSString *expected,NSString *cache,BOOL force,NSDictionary **details,NSError **error){return Validate(root,bundle,manifest,expected,cache,force,details,error);}
void AS6TestResetResourcePaths(void){ErrnoScope e;@synchronized(StateLock()){readyState=nil;gameStarted=false;testValidationHook=nil;}}
void AS6TestPrepareResourceImportHelp(NSString *documents){PrepareImportHelp(documents);}
void AS6TestResourceValidationHook(void(^hook)(NSString *,NSString *)){testValidationHook=[hook copy];}
#endif
