#import <Foundation/Foundation.h>

@interface NodePluginRuntime : NSObject
+ (instancetype)shared;
@property(atomic, readonly) BOOL hasActivePlugin;
@property(nonatomic, copy) void (^logHandler)(NSString *message);
- (NSString *)callOperation:(NSString *)operation json:(NSString *)json error:(NSError **)error;
- (BOOL)stopWithError:(NSError **)error;
@end
