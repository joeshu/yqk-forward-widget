#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Contains an uncaught UIKit assertion in CNPlayerSDK's frame-thumbnail path.
@interface CNPlayerCrashGuard : NSObject
+ (BOOL)install;
@end

NS_ASSUME_NONNULL_END
