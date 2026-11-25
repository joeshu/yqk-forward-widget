#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the Cicada playback HUD and owns its view references. Playback state
/// and control behavior remain owned by the view controller.
@interface MediaPlaybackCicadaControls : NSObject
@property(nonatomic,strong,readonly) UIView *view;
@property(nonatomic,strong,readonly) UIButton *playPauseButton;
@property(nonatomic,strong,readonly) UIButton *rewindButton;
@property(nonatomic,strong,readonly) UIButton *forwardButton;
@property(nonatomic,strong,readonly) UIButton *rateButton;
@property(nonatomic,strong,readonly) UIButton *optionsButton;
@property(nonatomic,strong,readonly) UIButton *fullscreenButton;
@property(nonatomic,strong,readonly) UISlider *seekSlider;
@property(nonatomic,strong,readonly) UILabel *elapsedLabel;
@property(nonatomic,strong,readonly) UILabel *durationLabel;

- (instancetype)initWithVideoView:(UIView *)videoView
                           target:(id)target
                 playPauseAction:(SEL)playPauseAction
                     rewindAction:(SEL)rewindAction
                    forwardAction:(SEL)forwardAction
                 fullscreenAction:(SEL)fullscreenAction
                 beginScrubAction:(SEL)beginScrubAction
                changeScrubAction:(SEL)changeScrubAction
                   endScrubAction:(SEL)endScrubAction
                cancelScrubAction:(SEL)cancelScrubAction NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
