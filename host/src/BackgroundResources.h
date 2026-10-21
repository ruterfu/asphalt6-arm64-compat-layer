#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSString *AS6BackgroundFopenPath(NSString *path, NSString *mode);
NSString *AS6BackgroundOpenPath(NSString *path, int flags);
BOOL AS6BackgroundMayPreparePath(NSString *path);
#ifdef __cplusplus
}
#endif
