#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "ResourcePaths.h"
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <stdexcept>
#include <string>
static unsigned checks=0;
static void Check(bool ok,int line){++checks;if(!ok)throw std::runtime_error(std::to_string(line));}
#define T(...) Check((__VA_ARGS__),__LINE__)
static NSString *SHA(NSData *d){unsigned char b[32];CC_SHA256(d.bytes,(CC_LONG)d.length,b);char s[65];for(int i=0;i<32;++i)snprintf(s+2*i,3,"%02x",b[i]);return @(s);}
static void Put(NSString *path,NSData *data){[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];T([data writeToFile:path atomically:YES]);}
int main(){@autoreleasepool{
 NSString *base=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"AS6DocsTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];NSString *root=[base stringByAppendingPathComponent:@"Documents/Asphalt6Data"],*bundle=[base stringByAppendingPathComponent:@"Fake App.app"],*cache=[base stringByAppendingPathComponent:@"Library/cache.json"];
 NSString *realBundle=NSBundle.mainBundle.bundlePath;int oldcwd=open(".",O_RDONLY|O_DIRECTORY);int result=0;
 @try {try {
    NSData *data=[@"native resource fixture\n" dataUsingEncoding:NSUTF8StringEncoding];NSMutableData *movie=[NSMutableData dataWithLength:131073];for(NSUInteger i=0;i<movie.length;++i)((uint8_t *)movie.mutableBytes)[i]=(uint8_t)(i*17);
    NSDictionary *content=@{@"data/file000001.dat":data,@"data/A6_480x320.m4v":movie,@"GLIVE_RES/gamelogo.png":data,@"NativeArtwork/example.bgra":data,@"texte.txt":data};NSMutableDictionary *files=[NSMutableDictionary new];NSUInteger bytes=0;
    for(NSString *name in content){NSData *d=content[name];Put([root stringByAppendingPathComponent:name],d);files[name]=@{@"bytes":@(d.length),@"sha256":SHA(d)};bytes+=d.length;}
    NSDictionary *manifest=@{@"format":@"as6-documents-resource-pack-v1",@"schema_version":@1,@"files":files,@"total_files":@(files.count),@"total_bytes":@(bytes)};NSData *trusted=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:nil];NSString *expected=SHA(trusted);Put([root stringByAppendingPathComponent:@"resource-manifest.json"],trusted);Put([bundle stringByAppendingPathComponent:@"Icon.png"],data);Put([bundle stringByAppendingPathComponent:@"data/glsl.config"],data);
    auto validate=[&](BOOL force,NSDictionary **out)->BOOL {NSError *e=nil;BOOL ok=AS6TestValidateResourceRoot(root,bundle,trusted,expected,cache,force,out,&e);if(!ok)T(e&&![(e.localizedDescription?:@"")containsString:base]);return ok;};
    AS6TestPrepareResourceImportHelp([base stringByAppendingPathComponent:@"Documents"]);NSString *help=[base stringByAppendingPathComponent:@"Documents/资源导入说明.txt"];T([NSData dataWithContentsOfFile:help].length>0);Put(help,data);AS6TestPrepareResourceImportHelp([base stringByAppendingPathComponent:@"Documents"]);T([[NSData dataWithContentsOfFile:help]isEqual:data]);
    AS6TestResetResourcePaths();NSDictionary *details=nil;errno=EDOM;T(validate(NO,&details));T(errno==EDOM);T([details[@"hashed_files"]unsignedIntegerValue]==files.count);T([details[@"stat_cache_files"]unsignedIntegerValue]==0);T(AS6ResourceRootPath()!=nil);
    T(validate(NO,&details));T([details[@"hashed_files"]unsignedIntegerValue]==0);T([details[@"stat_cache_files"]unsignedIntegerValue]==files.count);T(validate(YES,&details));T([details[@"hashed_files"]unsignedIntegerValue]==files.count);
    BOOL matched=NO;NSString *old=[bundle stringByAppendingPathComponent:@"data/file000001.dat"];NSString *mapped=AS6ResolveResourceReadPath(old,&matched);T(matched);T([[NSData dataWithContentsOfFile:mapped]isEqual:data]);T(errno==EDOM);
    NSString *save=[base stringByAppendingPathComponent:@"Documents/profile.dat"];T(AS6ResolveResourceReadPath(save,&matched)==save&&!matched);T(!AS6ResourceWriteProtectedPath(save));Put(save,data);T([[NSData dataWithContentsOfFile:save]isEqual:data]);
    T(AS6ResolveResourceReadPath([bundle stringByAppendingPathComponent:@"Icon.png"],&matched)!=nil&&!matched);T(!AS6ResourceWriteProtectedPath(save));T(!AS6ResourceBundlePath(@"Icon",@"png",nil,nil,&matched)&&!matched);
    T(AS6ResolveResourceReadPath([bundle stringByAppendingPathComponent:@"data/glsl.config"],&matched)==nil&&matched);int routeError=0;T(!AS6ResourceFopenReadPath(@"data/glsl.config",@"rb",&routeError)&&routeError==ENOENT);
    NSString *p=AS6ResourceFopenReadPath(old,@"rb",&routeError);T(p&&routeError==0);FILE *f=fopen(p.fileSystemRepresentation,"rb");T(f!=nullptr);T(!fseek(f,0,SEEK_END));T(ftell(f)==(long)data.length);fclose(f);
    T(!AS6ResourceFopenReadPath(old,@"r+",&routeError)&&routeError==EROFS);T(!AS6ResourceOpenReadPath(old,O_WRONLY|O_TRUNC,&routeError)&&routeError==EROFS);T(AS6ResourceOpenReadPath(save,O_WRONLY|O_CREAT,&routeError)==save&&routeError==0);
    T(chdir(AS6ResourceRootPath().fileSystemRepresentation)==0);T(!AS6ResourceFopenReadPath(@"profile.dat",@"wb",&routeError)&&routeError==EROFS);T(!AS6ResourceOpenReadPath(@"profile.dat",O_WRONLY|O_CREAT,&routeError)&&routeError==EROFS);T(AS6ResourceOpenReadPath(save,O_WRONLY,&routeError)==save&&routeError==0);
    NSString *video=AS6ResourceBundlePath(@"A6_480x320",@"m4v",nil,nil,&matched);T(matched&&[[NSData dataWithContentsOfFile:video]isEqual:movie]);T(chdir([[AS6ResourceRootPath()stringByAppendingPathComponent:@"data"]fileSystemRepresentation])==0);T([AS6ResourceBundlePath(@"A6_480x320",@"m4v",nil,nil,&matched)isEqual:video]&&matched);T([[NSBundle mainBundle].bundlePath isEqual:realBundle]);
    T([AS6ResourceBundlePath(@"GLIVE_RES/gamelogo",@"png",nil,nil,&matched)hasSuffix:@"GLIVE_RES/gamelogo.png"]&&matched);
    id argument=AS6ResourceReadObjectArgument(NSData.class,@selector(dataWithContentsOfFile:),2,old);T([argument isEqual:mapped]);T([AS6ResourceReadObjectArgument(NSString.class,@selector(stringWithContentsOfFile:encoding:error:),2,old)isEqual:mapped]);
    id notRead=AS6ResourceReadObjectArgument(NSData.class,@selector(writeToFile:atomically:),2,save);T(notRead==save);T(AS6ResourceReadObjectArgument(NSData.class,@selector(dataWithContentsOfFile:),3,old)==old);
    NSURL *oldURL=[NSURL fileURLWithPath:old];NSURL *newURL=AS6ResourceReadObjectArgument(NSData.class,@selector(dataWithContentsOfURL:),2,oldURL);T(newURL.isFileURL&&[newURL.path isEqual:mapped]);T([AS6ResourceReadReceiver(oldURL,@selector(path))isEqual:newURL]);
    // NSURL alloc is an uninitialized class-cluster placeholder. A read-only
    // receiver adapter must not send isFileURL before an initializer selector.
    NSURL *placeholder=[NSURL alloc];id initReceiver=nil;BOOL initThrew=NO;
    @try {initReceiver=AS6ResourceReadReceiver(placeholder,@selector(initFileURLWithPath:));}
    @catch(NSException *e){initThrew=YES;fprintf(stderr,"placeholder initializer receiver threw: %s\n",e.reason.UTF8String);}
    T(!initThrew);T(initReceiver==placeholder);
    NSString *initPath=AS6ResourceReadObjectArgument(placeholder,@selector(initFileURLWithPath:),2,old);T([initPath isEqual:mapped]);
    NSURL *initialized=[placeholder initFileURLWithPath:initPath];T(initialized.isFileURL&&[initialized.path isEqual:mapped]);
    NSString *fileString=oldURL.absoluteString;NSString *mappedString=AS6ResourceReadObjectArgument(NSURL.class,@selector(URLWithString:),2,fileString);T([[NSURL URLWithString:mappedString].path isEqual:mapped]);NSString *web=@"https://example.invalid/data/file000001.dat";T(AS6ResourceReadObjectArgument(NSURL.class,@selector(URLWithString:),2,web)==web);T(AS6ResourceReadObjectArgument(NSData.class,@selector(dataWithContentsOfURL:),2,[NSURL URLWithString:web])!=nil);
    id denied=AS6ResourceReadObjectArgument(NSData.class,@selector(dataWithContentsOfFile:),2,[bundle stringByAppendingPathComponent:@"data/glsl.config"]);T(![denied isEqual:[bundle stringByAppendingPathComponent:@"data/glsl.config"]]);T(![NSData dataWithContentsOfFile:denied]);
    __attribute__((objc_precise_lifetime)) NSMutableArray *owners=[NSMutableArray new];NSInvocation *inv=[NSInvocation invocationWithMethodSignature:[(id)NSData.class methodSignatureForSelector:@selector(dataWithContentsOfFile:)]];inv.selector=@selector(dataWithContentsOfFile:);
    @autoreleasepool {id arg=AS6ResourceReadObjectArgument(NSData.class,inv.selector,2,old);[owners addObject:arg];void *raw=(__bridge void *)arg;[inv setArgument:&raw atIndex:2];} [inv invokeWithTarget:NSData.class];__unsafe_unretained NSData *received=nil;[inv getReturnValue:&received];T([received isEqual:data]);T(owners.count==1);
    char *canonical=realpath(root.fileSystemRepresentation,nullptr);T(canonical!=nullptr);NSString *realRoot=@(canonical);free(canonical);T(AS6ResourceWriteProtectedPath([realRoot stringByAppendingPathComponent:@"new-profile"]));NSString *realKnown=AS6ResolveResourceReadPath([realRoot stringByAppendingPathComponent:@"data/file000001.dat"],&matched);T(matched&&[[NSData dataWithContentsOfFile:realKnown]isEqual:data]);T(!AS6ResolveResourceReadPath([realRoot stringByAppendingPathComponent:@"data/unknown"],&matched)&&matched);
    T(fchdir(oldcwd)==0);
    NSString *member=[root stringByAppendingPathComponent:@"data/file000001.dat"];NSData *replacement=[@"NATIVE resource fixture\n" dataUsingEncoding:NSUTF8StringEncoding];T(replacement.length==data.length);Put(member,replacement);T(!validate(NO,&details));T(AS6ResourceRootPath()==nil);Put(member,data);T(validate(NO,&details));
    NSError *error=nil;T(!AS6TestValidateResourceRoot(root,bundle,trusted,@"0000000000000000000000000000000000000000000000000000000000000000",cache,NO,&details,&error));T(error!=nil);T(validate(YES,&details));
    Put([root stringByAppendingPathComponent:@"resource-manifest.json"],[NSData data]);T(!validate(NO,&details));Put([root stringByAppendingPathComponent:@"resource-manifest.json"],trusted);T(validate(YES,&details));
    [NSFileManager.defaultManager removeItemAtPath:member error:nil];T(symlink(save.fileSystemRepresentation,member.fileSystemRepresentation)==0);T(!validate(NO,&details));T(unlink(member.fileSystemRepresentation)==0);Put(member,data);T(validate(YES,&details));
    __block BOOL swapped=NO;AS6TestResourceValidationHook(^(NSString *phase,NSString *name){if(!swapped&&[phase isEqual:@"after-file-read"]&&[name isEqual:@"data/file000001.dat"]){swapped=YES;Put(member,data);}});T(!validate(YES,&details));T(swapped);AS6TestResourceValidationHook(nil);T(validate(YES,&details));
    NSString *oldRoot=[base stringByAppendingPathComponent:@"OldData"];__block BOOL rootSwap=NO;AS6TestResourceValidationHook(^(NSString *phase,NSString *){if(!rootSwap&&[phase isEqual:@"before-root-reopen"]){rootSwap=YES;T([NSFileManager.defaultManager moveItemAtPath:root toPath:oldRoot error:nil]);T([NSFileManager.defaultManager copyItemAtPath:oldRoot toPath:root error:nil]);}});T(!validate(YES,&details));T(rootSwap);AS6TestResourceValidationHook(nil);[NSFileManager.defaultManager removeItemAtPath:root error:nil];T([NSFileManager.defaultManager moveItemAtPath:oldRoot toPath:root error:nil]);T(validate(YES,&details));
    T([NSFileManager.defaultManager moveItemAtPath:root toPath:oldRoot error:nil]);T(symlink(oldRoot.fileSystemRepresentation,root.fileSystemRepresentation)==0);T(!validate(NO,&details));T(unlink(root.fileSystemRepresentation)==0);T([NSFileManager.defaultManager moveItemAtPath:oldRoot toPath:root error:nil]);T(validate(YES,&details));
    AS6ResourceMarkGameStarted();T(!validate(YES,&details));T(AS6ResourceRootPath()!=nil);AS6TestResetResourcePaths();
 }catch(const std::exception &e){fprintf(stderr,"ResourcePathsTests failed near line %s\n",e.what());result=1;}}
 @catch(NSException *e){fprintf(stderr,"ResourcePathsTests exception %s\n",e.name.UTF8String);result=1;}
 @finally {fchdir(oldcwd);close(oldcwd);AS6TestResetResourcePaths();[NSFileManager.defaultManager removeItemAtPath:base error:nil];}
 printf("{\"passed\":%s,\"checks\":%u,\"guest_executed\":false,\"device_action\":false}\n",result?"false":"true",checks);return result;
}}
