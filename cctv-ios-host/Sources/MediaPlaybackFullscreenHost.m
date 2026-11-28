#import "MediaPlaybackFullscreenHost.h"
#import "RuntimeDiagnostics.h"
#import <math.h>

// The playback controller owns the session. This host only presents its render view.
@interface MediaPlaybackFullscreenHost () <UIGestureRecognizerDelegate>
@property(nonatomic,strong,readwrite) UIButton *closeButton;
@property(nonatomic,strong) UIButton *playPauseButton;
@property(nonatomic,assign) BOOL controlsHidden;
@property(nonatomic) BOOL closing;
@property(nonatomic,weak) UIWindowScene *orientationScene;
@property(nonatomic) UIInterfaceOrientationMask orientationToRestore;
@property(nonatomic,weak) UIView *aspectFitRenderView;
@property(nonatomic) CGFloat aspectFitRenderViewRatio;
- (void)closeFullscreen;
- (void)notifyClosed;
@end

@implementation MediaPlaybackFullscreenHost
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAllButUpsideDown;}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.blackColor;
    self.view.accessibilityViewIsModal=YES;
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControlsVisibility)];
    tap.cancelsTouchesInView=NO;
    tap.delegate=self;
    [self.view addGestureRecognizer:tap];

    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints=NO;
    close.tintColor=UIColor.whiteColor;
    close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];
    close.layer.cornerRadius=22;
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.accessibilityLabel=@"退出全屏";
    close.accessibilityIdentifier=@"media-cicada-close-fullscreen";
    [close addTarget:self action:@selector(closeFullscreen) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    self.closeButton=close;

    UIButton *playPause=[UIButton buttonWithType:UIButtonTypeSystem];
    playPause.translatesAutoresizingMaskIntoConstraints=NO;
    playPause.tintColor=UIColor.whiteColor;
    playPause.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];
    playPause.layer.cornerRadius=24;
    playPause.accessibilityIdentifier=@"media-cicada-fullscreen-playpause";
    [playPause addTarget:self action:@selector(togglePlayPauseTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:playPause];
    self.playPauseButton=playPause;
    [NSLayoutConstraint activateConstraints:@[
        [close.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
        [playPause.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [playPause.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [playPause.widthAnchor constraintEqualToConstant:48],
        [playPause.heightAnchor constraintEqualToConstant:48]
    ]];
}
- (void)toggleControlsVisibility {
    if(UIAccessibilityIsVoiceOverRunning())return;
    self.controlsHidden=!self.controlsHidden;
    CGFloat alpha=self.controlsHidden?0.0:1.0;
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled()?0:0.2 animations:^{
        self.closeButton.alpha=alpha;
        self.playPauseButton.alpha=alpha;
    }];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    for(UIView *view=touch.view;view&&view!=self.view;view=view.superview){
        if([view isKindOfClass:UIControl.class])return NO;
    }
    return YES;
}
- (void)togglePlayPauseTapped {if(self.onTogglePlayPause)self.onTogglePlayPause();}
- (void)updatePlayingState:(BOOL)playing enabled:(BOOL)enabled {
    [self.playPauseButton setImage:[UIImage systemImageNamed:playing?@"pause.fill":@"play.fill"] forState:UIControlStateNormal];
    self.playPauseButton.accessibilityLabel=playing?@"暂停":@"播放";
    self.playPauseButton.enabled=enabled;
}
- (void)attachAspectFitRenderView:(UIView *)renderView aspectRatio:(CGFloat)aspectRatio {
    if(!renderView)return;
    self.aspectFitRenderView=renderView;
    [self updateAspectFitRenderViewAspectRatio:aspectRatio];
    renderView.translatesAutoresizingMaskIntoConstraints=YES;
    renderView.autoresizingMask=UIViewAutoresizingNone;
    [self.view insertSubview:renderView atIndex:0];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}
- (void)attachAspectFitRenderView:(UIView *)renderView aspectRatio:(CGFloat)aspectRatio discardingConstraints:(NSArray<NSLayoutConstraint *> * _Nullable)constraints {
    [NSLayoutConstraint deactivateConstraints:constraints?:@[]];
    [self attachAspectFitRenderView:renderView aspectRatio:aspectRatio];
}
- (void)updateAspectFitRenderViewAspectRatio:(CGFloat)aspectRatio {
    self.aspectFitRenderViewRatio=isfinite(aspectRatio)&&aspectRatio>0.1&&aspectRatio<10.0?aspectRatio:(16.0/9.0);
    [self.view setNeedsLayout];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *renderView=self.aspectFitRenderView;
    CGRect bounds=self.view.bounds;
    if(!renderView||bounds.size.width<=1||bounds.size.height<=1)return;
    CGFloat ratio=self.aspectFitRenderViewRatio>0?self.aspectFitRenderViewRatio:(16.0/9.0);
    CGFloat width=bounds.size.width,height=bounds.size.height;
    if(width/height>ratio)width=height*ratio;
    else height=width/ratio;
    CGRect frame=CGRectMake(bounds.origin.x+(bounds.size.width-width)/2.0,bounds.origin.y+(bounds.size.height-height)/2.0,width,height);
    CGRect previous=renderView.frame;
    if(fabs(previous.origin.x-frame.origin.x)>0.5||fabs(previous.origin.y-frame.origin.y)>0.5||fabs(previous.size.width-frame.size.width)>0.5||fabs(previous.size.height-frame.size.height)>0.5)renderView.frame=frame;
    [renderView setNeedsLayout];
}
- (void)requestLandscapeIfPortrait {
    UIWindowScene *scene=self.view.window.windowScene;
    UIInterfaceOrientation orientation=scene.interfaceOrientation;
    if(!scene||!UIInterfaceOrientationIsPortrait(orientation))return;
    self.orientationScene=scene;
    self.orientationToRestore=(UIInterfaceOrientationMask)(1UL<<orientation);
    [self setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowSceneGeometryPreferencesIOS *preferences=[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
    [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error){
        [RuntimeDiagnostics.shared recordEvent:@"playback_fullscreen_rotation_denied" category:@"playback" fields:@{@"error_code":@(error.code)}];
    }];
}
- (void)restoreOrientationForPresenter:(UIViewController *)presenter {
    UIWindowScene *scene=self.orientationScene;
    if(!self.orientationToRestore||!scene||presenter.viewIfLoaded.window.windowScene!=scene)return;
    // The landscape request can still be pending when Close is tapped.
    [presenter setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowSceneGeometryPreferencesIOS *preferences=[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:self.orientationToRestore];
    self.orientationToRestore=0;
    [scene requestGeometryUpdateWithPreferences:preferences errorHandler:nil];
}
- (void)closeFullscreen {
    if(self.isBeingPresented||self.isBeingDismissed||!self.presentingViewController)return;
    [self notifyClosed];
}
- (BOOL)accessibilityPerformEscape {
    [self closeFullscreen];
    return self.closing;
}
- (void)notifyClosed {
    if(self.closing)return;
    self.closing=YES;
    dispatch_block_t close=self.onClose;
    self.onClose=nil;
    if(close)close();
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(self.isBeingDismissed)[self notifyClosed];
}
@end
