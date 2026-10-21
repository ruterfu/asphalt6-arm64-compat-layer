#import <Foundation/Foundation.h>

// Default production validation uses the compiled manifest digest, the trusted
// small copy in the real App bundle, and Documents/Asphalt6Data. Call off-main.
FOUNDATION_EXPORT BOOL AS6ValidateDocumentResources(BOOL forceFullHash,
    NSDictionary **details, NSError **error);
FOUNDATION_EXPORT NSString *AS6ExpectedResourceRootPath(void);
FOUNDATION_EXPORT void AS6PrepareResourceImportHelp(void);
FOUNDATION_EXPORT NSString *AS6ResourceRootPath(void); // nil until validated
FOUNDATION_EXPORT void AS6ResourceMarkGameStarted(void);

// matched=NO: original non-resource path is returned unchanged. matched=YES
// and nil: recognized resource namespace is unavailable/unlisted (ENOENT).
// These helpers preserve host errno; callers capture their own syscall errno.
FOUNDATION_EXPORT NSString *AS6ResolveResourceReadPath(NSString *path, BOOL *matched);
FOUNDATION_EXPORT NSURL *AS6ResolveResourceReadURL(NSURL *url, BOOL *matched);
FOUNDATION_EXPORT BOOL AS6ResourceWriteProtectedPath(NSString *path);
FOUNDATION_EXPORT NSString *AS6ResourceFopenReadPath(NSString *path, NSString *mode, int *errorCode);
FOUNDATION_EXPORT NSString *AS6ResourceOpenReadPath(NSString *path, int flags, int *errorCode);
FOUNDATION_EXPORT NSString *AS6ResourceDeniedReadPath(void);
FOUNDATION_EXPORT NSString *AS6ResourceBundlePath(NSString *name, NSString *extension,
    NSString *subdirectory, NSString *localization, BOOL *handled);

// Only native object arguments already decoded by GuestObjC are supplied.
// No Guest register/memory access, no global NSString/NSBundle substitution.
FOUNDATION_EXPORT id AS6ResourceReadObjectArgument(id target, SEL selector,
    NSUInteger nativeArgumentIndex, id argument);
FOUNDATION_EXPORT id AS6ResourceReadReceiver(id target, SEL selector);

#if defined(AS6_RESOURCE_PATH_TESTING)
FOUNDATION_EXPORT BOOL AS6TestValidateResourceRoot(NSString *root, NSString *bundleRoot,
    NSData *trustedManifest, NSString *expectedSHA, NSString *cacheFile, BOOL force,
    NSDictionary **details, NSError **error);
FOUNDATION_EXPORT void AS6TestResetResourcePaths(void);
FOUNDATION_EXPORT void AS6TestPrepareResourceImportHelp(NSString *documents);
FOUNDATION_EXPORT void AS6TestResourceValidationHook(void (^hook)(NSString *phase, NSString *member));
#endif
