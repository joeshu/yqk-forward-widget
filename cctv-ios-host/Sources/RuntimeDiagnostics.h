#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RuntimeDiagnostics : NSObject

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
+ (instancetype)shared;
- (void)setEnabled:(BOOL)enabled;
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)prepareExportWithCompletion:(void (^)(NSURL * _Nullable url, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
