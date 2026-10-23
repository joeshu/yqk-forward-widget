#import <Foundation/Foundation.h>

// Applies only to the bundled Cicada core. Never replaces the SDK's DRM config.
@interface NativeStartupTuner : NSObject
@property(nonatomic, copy, readonly) NSString *summary;
- (BOOL)applyToPlayer:(id)player;
- (BOOL)restore;
@end
