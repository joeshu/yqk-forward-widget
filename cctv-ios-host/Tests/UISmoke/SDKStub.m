// Simulator UI tests only. Never linked into the device IPA.
#import "CNPlayerSDK.h"
@implementation CNPlayer
+ (void)startPlayerSDK_Options:(id)options {
}
+ (id)defaultOptions {
    return @{};
}
+ (void)logEnabled:(BOOL)enabled {
}
@end
