#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
/// Shared visibility policy; UI remains in its owning view controller.
@interface PlaybackOverlayController : NSObject
@property(nonatomic,readonly) BOOL visible;
@property(nonatomic,copy,nullable) BOOL (^voiceOverRunningProvider)(void);
@property(nonatomic,copy) void (^onVisibilityChanged)(BOOL visible);
@property(nonatomic,copy) BOOL (^canAutoHide)(void);
- (void)show;
- (void)hide;
- (void)toggle;
- (void)rearmAutoHide;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
