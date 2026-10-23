#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// JavaScriptCore host for the bundled JS extractor. All JS runs on one serial queue.
@interface JSPluginRuntime : NSObject
@property(nonatomic, copy, nullable) void (^logHandler)(NSString *);
+ (instancetype)shared;
- (instancetype)initWithScriptURL:(nullable NSURL *)url configuration:(nullable NSURLSessionConfiguration *)configuration;
/// Blocking bridge for background callers only; never used from the UI thread.
- (nullable NSString *)callOperation:(NSString *)operation json:(NSString *)json timeout:(NSTimeInterval)timeout error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
