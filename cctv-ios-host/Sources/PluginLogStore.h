#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginLogStore : NSObject
+ (instancetype)shared;
- (void)appendLine:(NSString *)line forIdentifier:(NSString *)identifier;
- (NSString *)logForIdentifier:(NSString *)identifier;
- (void)clearLogForIdentifier:(NSString *)identifier completion:(nullable dispatch_block_t)completion;
- (void)prepareExportForIdentifier:(NSString *)identifier displayName:(NSString *)displayName completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
