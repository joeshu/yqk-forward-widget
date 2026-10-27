#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RuntimeDiagnostics : NSObject

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// State from the persisted app marker seen at this launch: closed, unclosed, or unknown.
@property(nonatomic, copy, readonly) NSString *previousSessionTerminationState;
+ (instancetype)shared;
- (void)setEnabled:(BOOL)enabled;
- (void)beginAppSessionWithFields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)recordLifecycleCheckpoint:(NSString *)checkpoint fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)endAppSession;
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields;
/// Writes and flushes a small critical breadcrumb before returning. Use sparingly for
/// transitions whose context would otherwise be lost if the process exits abruptly.
- (void)recordEventSynchronously:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)loadSessionsWithCompletion:(void (^)(NSArray<NSDictionary *> *sessions, NSError * _Nullable error))completion;
- (void)loadEventsForSessionID:(NSString *)sessionID completion:(void (^)(NSArray<NSDictionary *> *events, NSError * _Nullable error))completion;
- (void)prepareExportForSessionID:(NSString *)sessionID completion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;
- (void)deleteSessionID:(NSString *)sessionID completion:(void (^)(NSError * _Nullable error))completion;
- (void)clearAllSessionsWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)prepareExportWithCompletion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
