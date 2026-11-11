#import <Foundation/Foundation.h>

@class UIView;

NS_ASSUME_NONNULL_BEGIN

/// Resolves a source result without presenting a browser. Only validated media
/// is returned; webpage addresses remain resolver inputs, never decoder inputs.
@interface MediaNativePlaybackResolver : NSObject
- (instancetype)initWithHostView:(nullable UIView *)hostView;
- (void)resolveResult:(NSDictionary *)result
             identity:(NSDictionary *)identity
             progress:(nullable void (^)(NSDictionary *progress))progress
           completion:(void (^)(NSDictionary * _Nullable media, NSError * _Nullable error))completion;
/// Completes the current request once with resolutionCode=CANCELLED.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
