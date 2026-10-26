#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginLogStore : NSObject
+ (instancetype)shared;
- (NSString *)beginRunForIdentifier:(NSString *)identifier;
- (void)markRunRunningForIdentifier:(NSString *)identifier;
- (void)finishRunForIdentifier:(NSString *)identifier status:(NSString *)status;
- (void)markUnmanagedRunsInterruptedForIdentifier:(NSString *)identifier;
- (NSArray<NSDictionary *> *)runsForIdentifier:(NSString *)identifier;
- (NSString *)logForIdentifier:(NSString *)identifier runID:(NSString *)runID;
- (void)appendLine:(NSString *)line forIdentifier:(NSString *)identifier;
- (NSString *)logForIdentifier:(NSString *)identifier;
- (void)clearRunForIdentifier:(NSString *)identifier runID:(NSString *)runID completion:(nullable dispatch_block_t)completion;
- (void)clearLogForIdentifier:(NSString *)identifier completion:(nullable dispatch_block_t)completion;
- (void)prepareExportForIdentifier:(NSString *)identifier runID:(NSString *)runID displayName:(NSString *)displayName completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
- (void)prepareExportForIdentifier:(NSString *)identifier displayName:(NSString *)displayName completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
