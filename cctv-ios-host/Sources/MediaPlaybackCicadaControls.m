#import "MediaPlaybackCicadaControls.h"

@interface MediaPlaybackCicadaControls ()
@property(nonatomic,strong,readwrite) UIView *view;
@property(nonatomic,strong,readwrite) UIButton *playPauseButton;
@property(nonatomic,strong,readwrite) UIButton *rewindButton;
@property(nonatomic,strong,readwrite) UIButton *forwardButton;
@property(nonatomic,strong,readwrite) UIButton *rateButton;
@property(nonatomic,strong,readwrite) UIButton *optionsButton;
@property(nonatomic,strong,readwrite) UIButton *fullscreenButton;
@property(nonatomic,strong,readwrite) UISlider *seekSlider;
@property(nonatomic,strong,readwrite) UILabel *elapsedLabel;
@property(nonatomic,strong,readwrite) UILabel *durationLabel;
- (UIButton *)controlButton:(NSString *)symbol label:(NSString *)label target:(nullable id)target action:(SEL)action;
@end

@implementation MediaPlaybackCicadaControls

- (instancetype)initWithVideoView:(UIView *)videoView target:(id)target playPauseAction:(SEL)playPauseAction rewindAction:(SEL)rewindAction forwardAction:(SEL)forwardAction fullscreenAction:(SEL)fullscreenAction beginScrubAction:(SEL)beginScrubAction changeScrubAction:(SEL)changeScrubAction endScrubAction:(SEL)endScrubAction cancelScrubAction:(SEL)cancelScrubAction {
    if((self=[super init])) {
        _view=[UIView new];_view.translatesAutoresizingMaskIntoConstraints=NO;_view.backgroundColor=[UIColor colorWithWhite:0 alpha:0.76];_view.layer.cornerRadius=12;_view.hidden=YES;_view.accessibilityIdentifier=@"media-cicada-controls";[videoView addSubview:_view];
        _rewindButton=[self controlButton:@"gobackward.10" label:@"后退10秒" target:target action:rewindAction];_rewindButton.accessibilityHint=@"回退 10 秒";
        _playPauseButton=[self controlButton:@"pause.fill" label:@"暂停" target:target action:playPauseAction];_playPauseButton.accessibilityIdentifier=@"media-cicada-play-pause";_playPauseButton.accessibilityHint=@"暂停或继续播放";
        _forwardButton=[self controlButton:@"goforward.10" label:@"快进10秒" target:target action:forwardAction];_forwardButton.accessibilityHint=@"快进 10 秒";
        _rateButton=[self controlButton:nil label:@"倍速" target:nil action:NULL];_rateButton.showsMenuAsPrimaryAction=YES;_rateButton.accessibilityHint=@"调整播放倍速";
        _optionsButton=[self controlButton:@"slider.horizontal.3" label:@"画面比例与播放设置" target:nil action:NULL];_optionsButton.showsMenuAsPrimaryAction=YES;_optionsButton.accessibilityHint=@"画面比例与播放设置";
        _fullscreenButton=[self controlButton:@"arrow.up.left.and.arrow.down.right" label:@"全屏" target:target action:fullscreenAction];_fullscreenButton.accessibilityIdentifier=@"media-cicada-fullscreen";_fullscreenButton.accessibilityHint=@"进入或退出全屏";
        UIStackView *buttons=[[UIStackView alloc] initWithArrangedSubviews:@[_rewindButton,_playPauseButton,_forwardButton,_rateButton,_optionsButton,_fullscreenButton]];buttons.distribution=UIStackViewDistributionFillEqually;buttons.spacing=2;
        _elapsedLabel=[UILabel new];_durationLabel=[UILabel new];
        for(UILabel *label in @[_elapsedLabel,_durationLabel]){label.textColor=UIColor.whiteColor;label.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];[label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];}
        _seekSlider=[UISlider new];_seekSlider.minimumValue=0;_seekSlider.maximumValue=1;_seekSlider.minimumTrackTintColor=UIColor.whiteColor;_seekSlider.accessibilityLabel=@"播放进度";_seekSlider.accessibilityIdentifier=@"media-cicada-progress";
        [_seekSlider addTarget:target action:beginScrubAction forControlEvents:UIControlEventTouchDown];[_seekSlider addTarget:target action:changeScrubAction forControlEvents:UIControlEventValueChanged];[_seekSlider addTarget:target action:endScrubAction forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];[_seekSlider addTarget:target action:cancelScrubAction forControlEvents:UIControlEventTouchCancel];
        UIStackView *timeline=[[UIStackView alloc] initWithArrangedSubviews:@[_elapsedLabel,_seekSlider,_durationLabel]];timeline.spacing=8;timeline.alignment=UIStackViewAlignmentCenter;[timeline.heightAnchor constraintEqualToConstant:28].active=YES;
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[buttons,timeline]];stack.translatesAutoresizingMaskIntoConstraints=NO;stack.axis=UILayoutConstraintAxisVertical;[_view addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[[_view.leadingAnchor constraintEqualToAnchor:videoView.safeAreaLayoutGuide.leadingAnchor constant:8],[_view.trailingAnchor constraintEqualToAnchor:videoView.safeAreaLayoutGuide.trailingAnchor constant:-8],[_view.bottomAnchor constraintEqualToAnchor:videoView.safeAreaLayoutGuide.bottomAnchor constant:-8],[stack.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],[stack.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],[stack.topAnchor constraintEqualToAnchor:_view.topAnchor constant:2],[stack.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-4]]];
    }
    return self;
}

- (UIButton *)controlButton:(NSString *)symbol label:(NSString *)label target:(id)target action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tintColor=UIColor.whiteColor;button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];button.accessibilityLabel=label;
    if(symbol.length)[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];else[button setTitle:label forState:UIControlStateNormal];
    if(target&&action)[button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;return button;
}
@end
