#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface MediaPlaybackViewController : UIViewController
@property(nonatomic,copy,nullable) NSDictionary *result;
@property(nonatomic,copy) NSDictionary *context;
@property(nonatomic) BOOL embeddedMode;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,copy) dispatch_block_t onPlaybackWillStart;
@property(nonatomic,copy) void (^onEpisodeSelectionChanged)(NSDictionary *context);
@property(nonatomic,copy) void (^onVideoAspectRatioChanged)(CGFloat aspectRatio);
- (void)playInlineResult:(NSDictionary *)result context:(NSDictionary *)context;
- (void)installFloatingInlineSurfaceInHost:(UIView *)videoHost controlsStack:(UIStackView *)controlsStack;
- (CGFloat)preferredInlineVideoHeightForWidth:(CGFloat)width maximumHeight:(CGFloat)maximumHeight;
- (void)reloadThemeAppearance;
- (void)reloadThemeAppearance;
@end
NS_ASSUME_NONNULL_END
