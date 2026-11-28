#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MediaPlaybackFullscreenHost : UIViewController
@property(nonatomic,copy,nullable) dispatch_block_t onClose;
@property(nonatomic,copy,nullable) dispatch_block_t onTogglePlayPause;
@property(nonatomic,strong,readonly) UIButton *closeButton;
- (void)updatePlayingState:(BOOL)playing enabled:(BOOL)enabled;
- (void)attachAspectFitRenderView:(UIView *)renderView aspectRatio:(CGFloat)aspectRatio;
- (void)updateAspectFitRenderViewAspectRatio:(CGFloat)aspectRatio;
- (void)requestLandscapeIfPortrait;
- (void)restoreOrientationForPresenter:(UIViewController *)presenter;
@end

NS_ASSUME_NONNULL_END
