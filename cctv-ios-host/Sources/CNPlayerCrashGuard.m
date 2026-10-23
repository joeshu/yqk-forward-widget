#import "CNPlayerCrashGuard.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// CNPlayerSDK 3.23.28 calls this IJK helper while tearing down a failed live
// player. Before the decoder has produced a frame, the helper can ask UIKit to
// create a zero-sized image context. UIKit throws an NSException and the SDK
// does not catch it, terminating the host app. Catch only that optional
// thumbnail operation; a missing transition thumbnail does not affect playback.
static IMP CNPlayerOriginalThumbnailImplementation;
static BOOL CNPlayerThumbnailGuardInstalled;

static UIImage *CNPlayerGuardedThumbnail(id player, SEL selector) {
    IMP implementation = CNPlayerOriginalThumbnailImplementation;
    if (!implementation) return nil;
    @try {
        return ((UIImage *(*)(id, SEL))implementation)(player, selector);
    } @catch (NSException *exception) {
        NSLog(@"[CCTVHost] Skipped invalid CNPlayer transition thumbnail (%@)", exception.name);
        return nil;
    }
}

@implementation CNPlayerCrashGuard

+ (BOOL)install {
    @synchronized (self) {
        if (CNPlayerThumbnailGuardInstalled) return YES;

        Class playerClass = NSClassFromString(@"IJKFFMoviePlayerController");
        SEL selector = NSSelectorFromString(@"thumbnailImageAtCurrentTime");
        Method method = playerClass ? class_getInstanceMethod(playerClass, selector) : NULL;
        if (!method) return NO;

        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        if (!original || !types) return NO;

        // Add an override if inherited so we do not alter unrelated IJK users.
        CNPlayerOriginalThumbnailImplementation = original;
        if (!class_addMethod(playerClass, selector, (IMP)CNPlayerGuardedThumbnail, types)) {
            Method ownMethod = class_getInstanceMethod(playerClass, selector);
            if (!ownMethod) {
                CNPlayerOriginalThumbnailImplementation = NULL;
                return NO;
            }
            CNPlayerOriginalThumbnailImplementation = method_setImplementation(
                ownMethod, (IMP)CNPlayerGuardedThumbnail);
        }
        CNPlayerThumbnailGuardInstalled = CNPlayerOriginalThumbnailImplementation != NULL;
        return CNPlayerThumbnailGuardInstalled;
    }
}

@end
