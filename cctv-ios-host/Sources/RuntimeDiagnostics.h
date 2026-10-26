#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RuntimeDiagnostics : NSObject

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
+ (instancetype)shared;
- (void)setEnabled:(BOOL)enabled;
- (void)beginAppSessionWithFields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)recordLifecycleCheckpoint:(NSString *)checkpoint fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)endAppSession;
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields;
/// Writes and flushes a small critical breadcrumb before returning. Use sparingly for
/// transitions whose context would otherwise be lost if the process exits abruptly.
- (void)recordEventSynchronously:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)prepareExportWithCompletion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
