#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface HostLogRedactor : NSObject
+ (NSString *)redactText:(NSString *)text;
@end

NS_ASSUME_NONNULL_END
