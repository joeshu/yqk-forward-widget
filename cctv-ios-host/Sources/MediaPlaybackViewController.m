#import "MediaPlaybackViewController.h"
#import "MediaAPIClient.h"
#import "MediaWebViewController.h"
#import "MediaEpisodeSelectionViewController.h"
#import "MediaPlaybackHeaders.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import "MediaPlaybackStateStore.h"
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static void *CCTVPlayerItemStatusContext = &CCTVPlayerItemStatusContext;
static void *CCTVPlayerTimeControlContext = &CCTVPlayerTimeControlContext;
static void *CCTVPlayerLayerReadyContext = &CCTVPlayerLayerReadyContext;
static MediaAPIClient *MediaPlaybackClientForSource(NSDictionary *source) {
    if(MediaSourceUsesNativeCatalogAPI(source))return [[MediaAPIClient alloc] initWithTVBoxSource:source?:@{}];
    return [[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];
}
static NSDictionary *MediaPlaybackDiagnosticSourceFields(NSURL *url) {
    if(!RuntimeDiagnostics.shared.enabled||!url)return @{};
    NSString *host=url.host.lowercaseString?:@"";
    BOOL loopback=[host isEqualToString:@"127.0.0.1"]||[host isEqualToString:@"localhost"]||[host isEqualToString:@"::1"];
    return @{@"source_scheme":url.scheme.lowercaseString?:@"",@"source_host":host,@"source_port":url.port?:@0,@"source_extension":url.pathExtension.lowercaseString?:@"",@"source_is_loopback":@(loopback)};
}

@interface MediaPlaybackViewController ()
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerViewController *playerController;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIView *controlPanel;
@property(nonatomic,strong) UIScrollView *lineScroll;
@property(nonatomic,strong) UIStackView *lineButtons;
@property(nonatomic,strong) UIStackView *qualityGroup;
@property(nonatomic,strong) UILabel *qualityLabel;
@property(nonatomic,strong) UIScrollView *qualityScroll;
@property(nonatomic,strong) UIStackView *qualityButtons;
@property(nonatomic,strong) UILabel *episodeTitle;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UIButton *episodeButton;
@property(nonatomic,strong) UIStackView *playbackActionRow;
@property(nonatomic,strong) UIButton *skipButton;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger lineIndex;
@property(nonatomic) NSInteger episodeIndex;
@property(nonatomic) BOOL resolving;
@property(nonatomic) BOOL observingPlayer;
@property(nonatomic,strong) AVPlayerItem *observedItem;
@property(nonatomic) BOOL landscapeLayout;
@property(nonatomic) BOOL playbackLayoutInitialized;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *portraitConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint *> *landscapeConstraints;
@property(nonatomic,copy) NSDictionary *pendingEpisodeResult;
@property(nonatomic,strong) AVPlayerLayer *videoLayer;
@property(nonatomic) BOOL observingVideoLayer;
@property(nonatomic) CFTimeInterval playbackStartedAt;
@property(nonatomic) NSUInteger playerGeneration;
@property(nonatomic) BOOL hasVideoTrack;
@property(nonatomic) BOOL videoFrameReady;
@property(nonatomic) NSInteger lastDiagnosticTimeControlStatus;
@property(nonatomic) BOOL hasDiagnosticTimeControlStatus;
@property(nonatomic) NSInteger selectedAlternateIndex;
@property(nonatomic) BOOL awaitingWebPlaybackReturn;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,strong) UIBarButtonItem *playbackOptionsItem;
@property(nonatomic,strong) UIBarButtonItem *retryItem;
@property(nonatomic,strong) id progressTimeObserver;
@property(nonatomic,copy) NSDictionary *resumeEntry;
@property(nonatomic,copy) NSDictionary *pendingPlaybackResumeEntry;
@property(nonatomic,strong) NSNumber *pendingPlaybackSeekTime;
@property(nonatomic,strong) NSNumber *pendingQualitySeekTime;
@property(nonatomic) BOOL pendingQualityRestorePlaybackState;
@property(nonatomic) BOOL pendingQualityWasPlaying;
@property(nonatomic) NSUInteger stallRecoveryAttempts;
@property(nonatomic) NSTimeInterval lastPersistedPosition;
@property(nonatomic) BOOL resumePromptPending;
@property(nonatomic) BOOL resumePromptShown;
@property(nonatomic,copy) NSString *skipButtonAction;
@property(nonatomic) BOOL previousIdleTimerDisabled;
@property(nonatomic) BOOL idleTimerOverrideActive;
- (void)stopObservingCurrentPlayback;
- (void)observePlayerLayerIfAvailable;
- (AVPlayerLayer *)playerLayerInLayerTree:(CALayer *)root;
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item;
- (void)buildQualityButtons;
- (void)selectAlternate:(UIButton *)sender;
- (void)setRetryAvailable:(BOOL)available;
- (void)configurePlaybackOptions;
- (void)persistPlaybackProgress;
- (void)updateSkipButtonForCurrentPosition;
- (void)offerResumeForItem:(AVPlayerItem *)item;
@end

@implementation MediaPlaybackViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAllButUpsideDown;}
- (NSArray *)lines {return [self.context[@"detail"][@"lines"] isKindOfClass:NSArray.class]?self.context[@"detail"][@"lines"]:@[];}
- (NSArray *)episodes {NSArray *lines=self.lines;return self.lineIndex>=0&&self.lineIndex<lines.count&&[lines[self.lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[self.lineIndex][@"episodes"]:@[];}
- (instancetype)init {if((self=[super init])){_lineIndex=0;_episodeIndex=0;_selectedAlternateIndex=-1;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=HostBackground();
    self.diagnosticTraceID=[self.context[@"correlationID"] isKindOfClass:NSString.class]&&[self.context[@"correlationID"] length]?self.context[@"correlationID"]:NSUUID.UUID.UUIDString.lowercaseString;
    self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];
    if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;
    if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;
    self.title=self.context[@"detail"][@"name"]?:self.context[@"item"][@"name"]?:@"影视播放";
    NSDictionary *source=self.context[@"source"]?:@{};self.client=MediaPlaybackClientForSource(source);
    [self configurePlaybackOptions];

    self.videoView=[UIView new];self.videoView.translatesAutoresizingMaskIntoConstraints=NO;self.videoView.backgroundColor=UIColor.blackColor;self.videoView.layer.cornerRadius=10;self.videoView.clipsToBounds=YES;[self.view addSubview:self.videoView];
    self.playerController=[AVPlayerViewController new];self.playerController.allowsPictureInPicturePlayback=YES;[self addChildViewController:self.playerController];self.playerController.view.translatesAutoresizingMaskIntoConstraints=NO;[self.videoView addSubview:self.playerController.view];[self.playerController didMoveToParentViewController:self];
    [NSLayoutConstraint activateConstraints:@[[self.playerController.view.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[self.playerController.view.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[self.playerController.view.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[self.playerController.view.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];

    self.controlPanel=[UIView new];self.controlPanel.translatesAutoresizingMaskIntoConstraints=NO;self.controlPanel.backgroundColor=HostCard();self.controlPanel.layer.cornerRadius=18;self.controlPanel.clipsToBounds=YES;[self.view addSubview:self.controlPanel];
    self.lineScroll=[UIScrollView new];self.lineScroll.translatesAutoresizingMaskIntoConstraints=NO;self.lineScroll.showsHorizontalScrollIndicator=NO;[self.controlPanel addSubview:self.lineScroll];
    self.lineButtons=[UIStackView new];self.lineButtons.axis=UILayoutConstraintAxisHorizontal;self.lineButtons.spacing=8;self.lineButtons.translatesAutoresizingMaskIntoConstraints=NO;[self.lineScroll addSubview:self.lineButtons];
    self.qualityGroup=[UIStackView new];self.qualityGroup.translatesAutoresizingMaskIntoConstraints=NO;self.qualityGroup.axis=UILayoutConstraintAxisVertical;self.qualityGroup.spacing=3;[self.controlPanel addSubview:self.qualityGroup];
    self.qualityLabel=[UILabel new];self.qualityLabel.text=@"清晰度";self.qualityLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.qualityLabel.textColor=HostSecondaryText();[self.qualityGroup addArrangedSubview:self.qualityLabel];
    self.qualityScroll=[UIScrollView new];self.qualityScroll.translatesAutoresizingMaskIntoConstraints=NO;self.qualityScroll.showsHorizontalScrollIndicator=NO;[self.qualityGroup addArrangedSubview:self.qualityScroll];
    self.qualityButtons=[UIStackView new];self.qualityButtons.translatesAutoresizingMaskIntoConstraints=NO;self.qualityButtons.axis=UILayoutConstraintAxisHorizontal;self.qualityButtons.spacing=8;[self.qualityScroll addSubview:self.qualityButtons];
    [NSLayoutConstraint activateConstraints:@[[self.qualityScroll.heightAnchor constraintEqualToConstant:36],[self.qualityButtons.leadingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.leadingAnchor],[self.qualityButtons.trailingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.trailingAnchor],[self.qualityButtons.topAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.topAnchor],[self.qualityButtons.bottomAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.bottomAnchor],[self.qualityButtons.heightAnchor constraintEqualToAnchor:self.qualityScroll.frameLayoutGuide.heightAnchor]]];
    self.episodeTitle=[UILabel new];self.episodeTitle.translatesAutoresizingMaskIntoConstraints=NO;self.episodeTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];self.episodeTitle.adjustsFontForContentSizeCategory=YES;self.episodeTitle.textColor=UIColor.labelColor;self.episodeTitle.numberOfLines=2;[self.controlPanel addSubview:self.episodeTitle];
    self.status=[UILabel new];self.status.translatesAutoresizingMaskIntoConstraints=NO;self.status.textColor=UIColor.secondaryLabelColor;self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.status.numberOfLines=2;self.status.adjustsFontForContentSizeCategory=YES;[self.controlPanel addSubview:self.status];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.controlPanel addSubview:self.spinner];
    self.episodeButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeButton.translatesAutoresizingMaskIntoConstraints=NO;[self.episodeButton setTitle:@"选择分集" forState:UIControlStateNormal];HostStylePillButton(self.episodeButton,YES);[self.episodeButton addTarget:self action:@selector(openEpisodeSelection) forControlEvents:UIControlEventTouchUpInside];
    self.playbackActionRow=[UIStackView new];self.playbackActionRow.translatesAutoresizingMaskIntoConstraints=NO;self.playbackActionRow.axis=UILayoutConstraintAxisHorizontal;self.playbackActionRow.alignment=UIStackViewAlignmentFill;self.playbackActionRow.spacing=8;[self.controlPanel addSubview:self.playbackActionRow];
    self.skipButton=[UIButton buttonWithType:UIButtonTypeSystem];self.skipButton.translatesAutoresizingMaskIntoConstraints=NO;self.skipButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.skipButton.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(self.skipButton,YES);[self.skipButton addTarget:self action:@selector(performSkipAction) forControlEvents:UIControlEventTouchUpInside];self.skipButton.hidden=YES;
    [self.playbackActionRow addArrangedSubview:self.skipButton];[self.playbackActionRow addArrangedSubview:self.episodeButton];

    NSLayoutConstraint *videoAspect=[self.videoView.heightAnchor constraintEqualToAnchor:self.videoView.widthAnchor multiplier:0.5625];
    videoAspect.priority=UILayoutPriorityRequired;
    self.portraitConstraints=@[
        [self.lineScroll.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:10],
        [self.lineScroll.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
        [self.lineScroll.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.lineScroll.heightAnchor constraintEqualToConstant:44],
        [self.lineButtons.leadingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.leadingAnchor],
        [self.lineButtons.trailingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.trailingAnchor],
        [self.lineButtons.topAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.topAnchor],
        [self.lineButtons.bottomAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.bottomAnchor],
        [self.lineButtons.heightAnchor constraintEqualToAnchor:self.lineScroll.frameLayoutGuide.heightAnchor],
        [self.qualityGroup.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:4],
        [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.videoView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        videoAspect,
        [self.videoView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.49],
        [self.controlPanel.topAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:12],
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.controlPanel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.qualityGroup.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.playbackActionRow.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:12],
        [self.playbackActionRow.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.playbackActionRow.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.playbackActionRow.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-14],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.skipButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ];
    NSLayoutConstraint *landscapeWidth=[self.videoView.widthAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:0.62];
    self.landscapeConstraints=@[
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.videoView.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        landscapeWidth,
        videoAspect,
        [self.videoView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.88],
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor constant:12],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.controlPanel.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [self.lineScroll.topAnchor constraintEqualToAnchor:self.controlPanel.topAnchor constant:10],
        [self.lineScroll.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:10],
        [self.lineScroll.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-10],
        [self.lineScroll.heightAnchor constraintEqualToConstant:44],
        [self.lineButtons.leadingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.leadingAnchor],
        [self.lineButtons.trailingAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.trailingAnchor],
        [self.lineButtons.topAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.topAnchor],
        [self.lineButtons.bottomAnchor constraintEqualToAnchor:self.lineScroll.contentLayoutGuide.bottomAnchor],
        [self.lineButtons.heightAnchor constraintEqualToAnchor:self.lineScroll.frameLayoutGuide.heightAnchor],
        [self.qualityGroup.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:4],
        [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.qualityGroup.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.playbackActionRow.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
        [self.playbackActionRow.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
        [self.playbackActionRow.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.playbackActionRow.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-12],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.skipButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ];
    [self updatePlaybackLayoutForSize:self.view.bounds.size];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [self buildLines];[self buildQualityButtons];[self updateEpisodeTitle];self.pendingEpisodeResult=self.result;
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updatePlaybackLayoutForSize:self.view.bounds.size];[self observePlayerLayerIfAvailable];}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];NSDictionary *pending=self.pendingEpisodeResult;self.pendingEpisodeResult=nil;
    if(!self.idleTimerOverrideActive){self.previousIdleTimerDisabled=UIApplication.sharedApplication.idleTimerDisabled;self.idleTimerOverrideActive=YES;}
    BOOL keepAwake=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaKeepScreenAwake"]?[NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaKeepScreenAwake"]:YES;UIApplication.sharedApplication.idleTimerDisabled=keepAwake;
    if(pending){[self playResult:pending];return;}
    if(self.awaitingWebPlaybackReturn){self.awaitingWebPlaybackReturn=NO;[self.spinner stopAnimating];self.status.text=@"网页播放已关闭 · 可重新选择线路或分集";self.status.accessibilityLabel=self.status.text;}
}
- (void)viewWillDisappear:(BOOL)animated {
    [self persistPlaybackProgress];
    if(self.idleTimerOverrideActive){UIApplication.sharedApplication.idleTimerDisabled=self.previousIdleTimerDisabled;self.idleTimerOverrideActive=NO;}
    [super viewWillDisappear:animated];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];if(@available(iOS 16.0,*))[self setNeedsUpdateOfSupportedInterfaceOrientations];else [UIViewController attemptRotationToDeviceOrientation];}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];[coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){[self updatePlaybackLayoutForSize:size];} completion:nil];}
- (void)updatePlaybackLayoutForSize:(CGSize)size {
    if(size.width<=0||size.height<=0)return;BOOL landscape=size.width>size.height;
    if(self.playbackLayoutInitialized&&self.landscapeLayout==landscape)return;
    self.playbackLayoutInitialized=YES;self.landscapeLayout=landscape;
    [NSLayoutConstraint deactivateConstraints:self.portraitConstraints];[NSLayoutConstraint deactivateConstraints:self.landscapeConstraints];
    [NSLayoutConstraint activateConstraints:landscape?self.landscapeConstraints:self.portraitConstraints];
}
- (void)dealloc {
    self.generation++;
    self.playerGeneration++;
    [self persistPlaybackProgress];
    if(self.progressTimeObserver&&self.player){@try{[self.player removeTimeObserver:self.progressTimeObserver];}@catch(NSException *exception){}self.progressTimeObserver=nil;}
    if(self.idleTimerOverrideActive)UIApplication.sharedApplication.idleTimerDisabled=self.previousIdleTimerDisabled;
    if(self.observingPlayer){@try{[self.player removeObserver:self forKeyPath:@"timeControlStatus" context:CCTVPlayerTimeControlContext];}@catch(NSException *exception){}}
    [self stopObservingCurrentPlayback];
    [NSNotificationCenter.defaultCenter removeObserver:self];[self.client cancel];[self.player pause];
}
- (void)stopObservingCurrentPlayback {
    AVPlayerItem *item=self.observedItem;
    if(self.observingVideoLayer&&self.videoLayer){@try{[self.videoLayer removeObserver:self forKeyPath:@"readyForDisplay" context:CCTVPlayerLayerReadyContext];}@catch(NSException *exception){}self.observingVideoLayer=NO;}
    self.videoLayer=nil;
    if(item){@try{[item removeObserver:self forKeyPath:@"status" context:CCTVPlayerItemStatusContext];}@catch(NSException *exception){}[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:item];[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:item];self.observedItem=nil;}
}
- (void)installProgressObserverIfNeeded {
    if(!self.player||self.progressTimeObserver)return;__weak typeof(self) weakSelf=self;
    self.progressTimeObserver=[self.player addPeriodicTimeObserverForInterval:CMTimeMake(1,1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time){
        MediaPlaybackViewController *owner=weakSelf;if(!owner||!owner.observedItem||owner.observedItem!=owner.player.currentItem)return;
        NSTimeInterval position=time.seconds;if(!isfinite(position)||position<0)return;
        if(position-owner.lastPersistedPosition>=10.0){[owner persistPlaybackProgress];owner.lastPersistedPosition=position;}
        [owner updateSkipButtonForCurrentPosition];
    }];
}
- (void)persistPlaybackProgress {
    AVPlayerItem *item=self.observedItem;if(!item||item!=self.player.currentItem||!self.context)return;
    NSTimeInterval position=self.player.currentTime.seconds,duration=item.duration.seconds;if(!isfinite(position)||position<0)return;if(!isfinite(duration)||duration<0)duration=0;
    [MediaPlaybackStateStore recordContext:self.context lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:NO];
    self.lastPersistedPosition=position;
}
- (void)applicationDidEnterBackground:(NSNotification *)notification {[self persistPlaybackProgress];}
- (void)offerResumeForItem:(AVPlayerItem *)item {
    NSDictionary *entry=self.pendingPlaybackResumeEntry;if(!entry||self.resumePromptShown||item!=self.observedItem||item!=self.player.currentItem)return;
    self.resumePromptShown=YES;self.resumePromptPending=YES;[self.player pause];
    NSTimeInterval position=[entry[@"position"] doubleValue];NSString *episode=entry[@"episodeName"]?:@"上次分集";NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"继续上次播放？" message:[NSString stringWithFormat:@"%@ · %@",episode,[self formatMediaTime:position]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"从头播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;[owner.player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){owner.player.defaultRate=(float)[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"];[owner.player play];[RuntimeDiagnostics.shared recordEvent:@"media_resume_declined" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续观看" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.resumePromptPending=NO;owner.pendingPlaybackResumeEntry=nil;CMTime target=CMTimeMakeWithSeconds(MAX(0,position),600);[owner.player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{if(generation==owner.playerGeneration&&item==owner.player.currentItem){owner.player.defaultRate=(float)[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"];[owner.player play];[owner.status setText:@"已从上次进度继续播放"];[RuntimeDiagnostics.shared recordEvent:@"media_resume_accepted" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex)}];}});}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)applyPendingPlaybackSeekForItem:(AVPlayerItem *)item {
    NSNumber *pending=self.pendingPlaybackSeekTime;if(!pending||item!=self.observedItem||item!=self.player.currentItem)return;
    self.pendingPlaybackSeekTime=nil;NSTimeInterval position=MAX(0,pending.doubleValue);NSUInteger generation=self.playerGeneration;__weak typeof(self) weakSelf=self;
    [self.player seekToTime:CMTimeMakeWithSeconds(position,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.player.currentItem)return;owner.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);BOOL shouldResume=!owner.pendingQualityRestorePlaybackState||owner.pendingQualityWasPlaying;owner.pendingQualityRestorePlaybackState=NO;if(shouldResume)[owner.player play];else[owner.player pause];[owner updateSkipButtonForCurrentPosition];});}];
}
- (AVPlayerLayer *)playerLayerInLayerTree:(CALayer *)root {
    if([root isKindOfClass:AVPlayerLayer.class]&&((AVPlayerLayer *)root).player==self.player)return (AVPlayerLayer *)root;
    for(CALayer *child in root.sublayers){AVPlayerLayer *found=[self playerLayerInLayerTree:child];if(found)return found;}
    return nil;
}
- (void)observePlayerLayerIfAvailable {
    AVPlayerLayer *layer=self.playerController.isViewLoaded?[self playerLayerInLayerTree:self.playerController.view.layer]:nil;
    if(layer&&layer!=self.videoLayer){
        if(self.observingVideoLayer){@try{[self.videoLayer removeObserver:self forKeyPath:@"readyForDisplay" context:CCTVPlayerLayerReadyContext];}@catch(NSException *exception){}}
        self.videoLayer=layer;self.observingVideoLayer=YES;
        [layer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerLayerReadyContext];
    }
    if(layer.readyForDisplay)[self markFirstVideoFrameReadyForItem:self.observedItem];
}
- (void)markFirstVideoFrameReadyForItem:(AVPlayerItem *)item {
    if(!item||item!=self.observedItem||item!=self.player.currentItem||self.videoFrameReady)return;
    self.videoFrameReady=YES;[self.spinner stopAnimating];[self setRetryAvailable:NO];
    self.status.text=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying?@"视频首帧已就绪 · AVPlayer 正在播放":@"视频首帧已就绪 · 等待播放";self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_ready" category:@"playback" fields:fields];
}
- (void)buildLines {
    for(UIView *view in self.lineButtons.arrangedSubviews.copy){[self.lineButtons removeArrangedSubview:view];[view removeFromSuperview];}
    NSArray *lines=self.lines;
    for(NSUInteger idx=0;idx<lines.count;idx++){NSDictionary *line=lines[idx];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:line[@"name"]?:[NSString stringWithFormat:@"线路 %lu",(unsigned long)idx+1] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];HostStylePillButton(button,idx==self.lineIndex);button.tag=idx;[button addTarget:self action:@selector(selectLine:) forControlEvents:UIControlEventTouchUpInside];[self.lineButtons addArrangedSubview:button];}
}
- (void)buildQualityButtons {
    NSArray *alternates=[self.result[@"alternates"] isKindOfClass:NSArray.class]?self.result[@"alternates"]:@[];
    for(UIView *view in self.qualityButtons.arrangedSubviews.copy){[self.qualityButtons removeArrangedSubview:view];[view removeFromSuperview];}
    BOOL available=alternates.count>1;self.qualityLabel.hidden=!available;self.qualityScroll.hidden=!available;
    if(!available){self.selectedAlternateIndex=-1;return;}
    NSString *currentURL=[self.result[@"originalURL"] isKindOfClass:NSString.class]?self.result[@"originalURL"]:([self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@"");
    if(self.selectedAlternateIndex<0||self.selectedAlternateIndex>=alternates.count){self.selectedAlternateIndex=-1;for(NSUInteger index=0;index<alternates.count;index++)if([alternates[index][@"url"] isEqual:currentURL]){self.selectedAlternateIndex=index;break;}}
    for(NSUInteger index=0;index<alternates.count;index++){
        NSDictionary *alternate=alternates[index];NSString *name=[alternate[@"name"] isKindOfClass:NSString.class]?alternate[@"name"]:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-quality-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];HostStylePillButton(button,(NSInteger)index==self.selectedAlternateIndex);[button addTarget:self action:@selector(selectAlternate:) forControlEvents:UIControlEventTouchUpInside];[self.qualityButtons addArrangedSubview:button];
    }
}
- (void)selectAlternate:(UIButton *)sender {
    NSArray *alternates=[self.result[@"alternates"] isKindOfClass:NSArray.class]?self.result[@"alternates"]:@[];if(sender.tag>=alternates.count)return;
    NSDictionary *alternate=alternates[sender.tag];NSString *url=[alternate[@"url"] isKindOfClass:NSString.class]?alternate[@"url"]:@"";if(!url.length)return;
    self.selectedAlternateIndex=sender.tag;NSMutableDictionary *selected=[self.result mutableCopy];selected[@"url"]=url;selected[@"originalURL"]=url;self.result=selected;[self buildQualityButtons];
    [self persistPlaybackProgress];NSTimeInterval current=self.player.currentTime.seconds;self.pendingQualitySeekTime=(isfinite(current)&&current>=0)?@(MAX(0,current)):nil;self.pendingQualityWasPlaying=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;self.pendingQualityRestorePlaybackState=YES;
    [RuntimeDiagnostics.shared recordEvent:@"playback_quality_selected" category:@"playback" fields:@{@"alternate_index":@(sender.tag),@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"correlation_id":self.diagnosticTraceID?:@""}];[self playResult:selected];
}
- (void)configurePlaybackOptions {
    UIImage *image=[UIImage systemImageNamed:@"ellipsis.circle"];
    self.playbackOptionsItem=[[UIBarButtonItem alloc] initWithTitle:nil image:image primaryAction:nil menu:[self playbackOptionsMenu]];
    self.playbackOptionsItem.accessibilityLabel=@"播放设置";
    self.navigationItem.rightBarButtonItems=@[self.playbackOptionsItem];
}
- (UIMenu *)playbackOptionsMenu {
    __weak typeof(self) weakSelf=self;NSMutableArray *rateActions=[NSMutableArray array];
    NSArray<NSNumber *> *rates=@[@0.5,@0.75,@1.0,@1.25,@1.5,@1.75,@2.0];double currentRate=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"] doubleValue]:1.0;
    for(NSNumber *candidate in rates){double rate=candidate.doubleValue;NSString *title=rate==1.0?@"正常速度": [NSString stringWithFormat:@"%.2gx",rate];UIImage *mark=fabs(currentRate-rate)<0.01?[UIImage systemImageNamed:@"checkmark"]:nil;[rateActions addObject:[UIAction actionWithTitle:title image:mark identifier:nil handler:^(UIAction *action){[weakSelf setPlaybackRate:rate];}]];}
    NSArray *gravityValues=@[@{ @"title":@"画面适应", @"value":AVLayerVideoGravityResizeAspect },@{ @"title":@"铺满裁切", @"value":AVLayerVideoGravityResizeAspectFill },@{ @"title":@"拉伸填满", @"value":AVLayerVideoGravityResize }];
    NSMutableArray *gravityActions=[NSMutableArray array];NSString *currentGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    for(NSDictionary *option in gravityValues){NSString *value=option[@"value"];UIImage *mark=[currentGravity isEqual:value]?[UIImage systemImageNamed:@"checkmark"]:nil;[gravityActions addObject:[UIAction actionWithTitle:option[@"title"] image:mark identifier:nil handler:^(UIAction *action){[weakSelf setVideoGravity:value];}]];}
    UIAction *intro=[UIAction actionWithTitle:@"将当前时间记为片头结束" image:[UIImage systemImageNamed:@"forward.end"] identifier:nil handler:^(UIAction *action){[weakSelf rememberIntroEnd];}];
    UIAction *outro=[UIAction actionWithTitle:@"将剩余时间记为片尾" image:[UIImage systemImageNamed:@"forward.end.fill"] identifier:nil handler:^(UIAction *action){[weakSelf rememberOutroSkip];}];
    BOOL keepAwake=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaKeepScreenAwake"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaKeepScreenAwake"]:YES;
    UIAction *awake=[UIAction actionWithTitle:keepAwake?@"关闭屏幕常亮":@"保持屏幕常亮" image:[UIImage systemImageNamed:keepAwake?@"moon":@"sun.max"] identifier:nil handler:^(UIAction *action){[weakSelf setKeepScreenAwake:!keepAwake];}];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    UIAction *autoNextAction=[UIAction actionWithTitle:autoNext?@"关闭自动连播下一集":@"开启自动连播下一集" image:[UIImage systemImageNamed:autoNext?@"forward.end":@"forward.end.fill"] identifier:nil handler:^(UIAction *action){[NSUserDefaults.standardUserDefaults setBool:!autoNext forKey:@"cctv.mediaAutoPlayNext"];weakSelf.playbackOptionsItem.menu=[weakSelf playbackOptionsMenu];weakSelf.status.text=!autoNext?@"已开启自动连播下一集":@"已关闭自动连播下一集";}];
    UIAction *clear=[UIAction actionWithTitle:@"清除本片跳过位置" image:[UIImage systemImageNamed:@"eraser"] identifier:nil handler:^(UIAction *action){[MediaPlaybackStateStore clearSkipPointsForContext:weakSelf.context?:@{}];[weakSelf updateSkipButtonForCurrentPosition];weakSelf.status.text=@"已清除本片的片头片尾位置";}];
    return [UIMenu menuWithChildren:@[[UIMenu menuWithTitle:@"播放速度" children:rateActions],[UIMenu menuWithTitle:@"画面比例" children:gravityActions],autoNextAction,intro,outro,clear,awake]];
}
- (void)setPlaybackRate:(double)rate {
    rate=MIN(2.0,MAX(0.5,rate));[NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];self.player.defaultRate=(float)rate;
    if(self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying)self.player.rate=(float)rate;
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)setVideoGravity:(NSString *)gravity {
    if(![@[AVLayerVideoGravityResizeAspect,AVLayerVideoGravityResizeAspectFill,AVLayerVideoGravityResize] containsObject:gravity])return;
    [NSUserDefaults.standardUserDefaults setObject:gravity forKey:@"cctv.mediaVideoGravity"];self.playerController.videoGravity=gravity;self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)setKeepScreenAwake:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"cctv.mediaKeepScreenAwake"];
    if(self.view.window){if(!self.idleTimerOverrideActive){self.previousIdleTimerDisabled=UIApplication.sharedApplication.idleTimerDisabled;self.idleTimerOverrideActive=YES;}UIApplication.sharedApplication.idleTimerDisabled=enabled;}
    self.playbackOptionsItem.menu=[self playbackOptionsMenu];
}
- (void)rememberIntroEnd {
    NSTimeInterval position=self.player.currentTime.seconds;if(!isfinite(position)||position<5||position>600){self.status.text=@"片头结束位置需在 5 秒到 10 分钟之间";return;}
    [MediaPlaybackStateStore setIntroEnd:position forContext:self.context?:@{}];self.status.text=[NSString stringWithFormat:@"已记住片头结束位置 %.0f 秒",position];[self.playbackOptionsItem setMenu:[self playbackOptionsMenu]];
}
- (void)rememberOutroSkip {
    NSTimeInterval position=self.player.currentTime.seconds,duration=self.player.currentItem.duration.seconds,remaining=duration-position;if(!isfinite(remaining)||remaining<5||remaining>600){self.status.text=@"片尾位置需在结束前 5 秒到 10 分钟之间";return;}
    [MediaPlaybackStateStore setOutroSkip:remaining forContext:self.context?:@{}];self.status.text=[NSString stringWithFormat:@"已记住片尾约 %.0f 秒，可点按跳过按钮切换下一集",remaining];[self.playbackOptionsItem setMenu:[self playbackOptionsMenu]];
}
- (void)updateSkipButtonForCurrentPosition {
    if(!self.skipButton||!self.observedItem||self.observedItem!=self.player.currentItem){self.skipButton.hidden=YES;return;}
    NSTimeInterval position=self.player.currentTime.seconds,duration=self.player.currentItem.duration.seconds;if(!isfinite(position)||position<0){self.skipButton.hidden=YES;return;}
    NSTimeInterval intro=[MediaPlaybackStateStore introEndForContext:self.context?:@{}];if(intro>5&&position<intro-2){self.skipButtonAction=@"intro";[self.skipButton setTitle:[NSString stringWithFormat:@"跳过片头 · %@",[self formatMediaTime:intro-position]] forState:UIControlStateNormal];self.skipButton.hidden=NO;return;}
    NSTimeInterval outro=[MediaPlaybackStateStore outroSkipForContext:self.context?:@{}];BOOL hasNext=self.episodeIndex+1<self.episodes.count;NSTimeInterval remaining=duration-position;
    if(outro>0&&isfinite(remaining)&&remaining>0&&remaining<=outro&&hasNext){self.skipButtonAction=@"outro";[self.skipButton setTitle:@"跳过片尾 · 下一集" forState:UIControlStateNormal];self.skipButton.hidden=NO;return;}
    self.skipButtonAction=nil;self.skipButton.hidden=YES;
}
- (NSString *)formatMediaTime:(NSTimeInterval)time {NSUInteger value=(NSUInteger)MAX(0,time);return value>=3600?[NSString stringWithFormat:@"%lu:%02lu:%02lu",(unsigned long)(value/3600),(unsigned long)((value%3600)/60),(unsigned long)(value%60)]:[NSString stringWithFormat:@"%02lu:%02lu",(unsigned long)(value/60),(unsigned long)(value%60)];}
- (void)performSkipAction {
    NSString *action=self.skipButtonAction;if([action isEqual:@"intro"]){NSTimeInterval target=[MediaPlaybackStateStore introEndForContext:self.context?:@{}];if(target>0)[self.player seekToTime:CMTimeMakeWithSeconds(target,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];self.skipButton.hidden=YES;return;}
    if([action isEqual:@"outro"]&&self.episodeIndex+1<self.episodes.count){[self persistPlaybackProgress];self.episodeIndex++;[self updateEpisodeTitle];[self resolveAndPlay];}
}
- (void)setRetryAvailable:(BOOL)available {
    if(available){BOOL nativeFallback=self.awaitingWebPlaybackReturn&&[self.result[@"url"] isKindOfClass:NSString.class];if(!self.retryItem)self.retryItem=[[UIBarButtonItem alloc] initWithTitle:nativeFallback?@"尝试原生":@"重试" style:UIBarButtonItemStylePlain target:self action:nativeFallback?@selector(tryNativePlayback):@selector(retryCurrentEpisode)];self.retryItem.title=nativeFallback?@"尝试原生":@"重试";self.retryItem.target=self;self.retryItem.action=nativeFallback?@selector(tryNativePlayback):@selector(retryCurrentEpisode);self.navigationItem.rightBarButtonItems=@[self.retryItem,self.playbackOptionsItem];}
    else self.navigationItem.rightBarButtonItems=self.playbackOptionsItem?@[self.playbackOptionsItem]:@[];
}
- (void)clearCurrentPlayerItem {
    self.playerGeneration++;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];self.hasVideoTrack=NO;self.videoFrameReady=NO;
}
- (void)updateEpisodeTitle {
    NSArray *episodes=self.episodes;NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:nil;
    NSString *name=episode[@"name"]?:self.context[@"item"][@"name"]?:@"当前分集";self.episodeTitle.text=name;
    NSString *line=self.lineIndex>=0&&self.lineIndex<self.lines.count?self.lines[self.lineIndex][@"name"]:@"";
    NSString *label=line.length?[NSString stringWithFormat:@"选集 · %@ · %lu 集",line,(unsigned long)episodes.count]:@"选集";
    [self.episodeButton setTitle:label forState:UIControlStateNormal];self.episodeButton.enabled=episodes.count>0;self.episodeButton.alpha=episodes.count?1.0:0.55;[self updateSkipButtonForCurrentPosition];
}
- (void)openEpisodeSelection {
    if(!self.lines.count)return;
    self.generation++;[self.client cancel];if(self.resolving){self.resolving=NO;[self.spinner stopAnimating];self.status.text=@"解析已取消 · 请选择分集";self.status.accessibilityLabel=self.status.text;}
    MediaEpisodeSelectionViewController *page=[MediaEpisodeSelectionViewController new];page.item=self.context[@"item"]?:@{};page.source=self.context[@"source"]?:@{};page.provider=self.context[@"provider"]?:@"";page.detail=self.context[@"detail"]?:@{};page.correlationID=self.diagnosticTraceID;page.selectedLineIndex=self.lineIndex;page.selectedEpisodeIndex=self.episodeIndex;page.selectionUpdatesPlayer=YES;page.client=MediaPlaybackClientForSource(page.source);
    __weak typeof(self) weakSelf=self;page.onSelectEpisode=^(NSDictionary *result,NSDictionary *context){MediaPlaybackViewController *owner=weakSelf;if(!owner)return;[owner persistPlaybackProgress];owner.stallRecoveryAttempts=0;owner.context=context;owner.lineIndex=[context[@"lineIndex"] integerValue];owner.episodeIndex=[context[@"episodeIndex"] integerValue];owner.pendingEpisodeResult=result;[owner buildLines];[owner updateEpisodeTitle];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)playResult:(NSDictionary *)result {
    self.resolving=NO;self.awaitingWebPlaybackReturn=NO;NSUInteger playerGeneration=++self.playerGeneration;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];self.hasVideoTrack=NO;self.videoFrameReady=NO;self.lastPersistedPosition=0;
    NSString *raw=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";NSURL *url=[NSURL URLWithString:raw];
    if(!url||raw.length>8192||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length||url.user.length||url.password.length||[raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[self.spinner stopAnimating];NSMutableDictionary *fields=[@{@"reason":@"invalid_media_url", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(url)];[RuntimeDiagnostics.shared recordEvent:@"episode_playback_rejected" category:@"playback" fields:fields];self.status.text=@"资源未返回有效的 HTTP/HTTPS 播放地址";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];return;}
    self.result=result;self.selectedAlternateIndex=-1;[self buildQualityButtons];self.resumeEntry=[MediaPlaybackStateStore historyEntryForContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex];self.pendingPlaybackResumeEntry=nil;self.resumePromptPending=NO;self.resumePromptShown=NO;
    NSNumber *qualityPosition=self.pendingQualitySeekTime;self.pendingQualitySeekTime=nil;self.pendingPlaybackSeekTime=qualityPosition;if(!qualityPosition)self.pendingQualityRestorePlaybackState=NO;
    NSTimeInterval savedPosition=[self.resumeEntry[@"position"] doubleValue],savedDuration=[self.resumeEntry[@"duration"] doubleValue];BOOL hasResume=self.resumeEntry&&![self.resumeEntry[@"completed"] boolValue]&&savedPosition>=15&&(!isfinite(savedDuration)||savedDuration<=0||savedPosition<savedDuration-10);
    if(!qualityPosition&&hasResume){self.pendingPlaybackResumeEntry=self.resumeEntry;self.resumePromptPending=YES;self.pendingPlaybackSeekTime=nil;}
    NSURL *sourceURL=[NSURL URLWithString:[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:raw];NSString *extension=sourceURL.pathExtension.lowercaseString?:@"";NSString *resolvedExtension=url.pathExtension.lowercaseString?:@"";NSSet *direct=[NSSet setWithArray:@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3"]];BOOL directMedia=[direct containsObject:extension]||[direct containsObject:resolvedExtension];
    BOOL requiresWebPlayback=[result[@"requiresWebPlayback"] boolValue]||[result[@"parse"] integerValue]>0||[result[@"jx"] integerValue]>0;
    if(requiresWebPlayback && !directMedia){[self.spinner stopAnimating];self.status.text=@"正在打开来源网页播放器…";self.status.accessibilityLabel=self.status.text;self.awaitingWebPlaybackReturn=YES;[self setRetryAvailable:YES];NSMutableDictionary *fields=[@{@"player":@"webview", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(url)];[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:fields];MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:result title:self.title];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:web];[self presentViewController:nav animated:YES completion:nil];return;}
    NSMutableDictionary *handoffFields=[@{@"player":@"avplayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(url)];[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();self.status.text=@"正在载入媒体…";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];[self setRetryAvailable:NO];
    NSDictionary *requestHeaders=MediaPlaybackHeadersFromResult(result);NSString *host=url.host.lowercaseString?:@"";BOOL localRelay=![sourceURL.absoluteString isEqualToString:raw]&&[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:host];if(localRelay)requestHeaders=@{};
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:requestHeaders.count?@{@"AVURLAssetHTTPHeaderFieldsKey":requestHeaders}:nil];AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    if(!self.player){self.player=[AVPlayer playerWithPlayerItem:item];[self.player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerTimeControlContext];self.observingPlayer=YES;}else[self.player replaceCurrentItemWithPlayerItem:item];
    self.observedItem=item;[item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerItemStatusContext];self.player.automaticallyWaitsToMinimizeStalling=YES;self.player.defaultRate=(float)([NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]:1.0);self.playerController.videoGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;self.playerController.player=self.player;[self installProgressObserverIfNeeded];[self updateEpisodeTitle];
    __weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(owner&&playerGeneration==owner.playerGeneration)[owner observePlayerLayerIfAvailable];});
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime)[self.player play];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||playerGeneration!=owner.playerGeneration||item!=owner.player.currentItem||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.videoFrameReady||item.status==AVPlayerItemStatusFailed||(!owner.hasVideoTrack&&item.status==AVPlayerItemStatusReadyToPlay))return;[owner.spinner stopAnimating];owner.status.text=@"等待视频帧超时 · 可重试或切换线路";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-owner.playbackStartedAt)*1000))), @"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"correlation_id":owner.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:owner.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_video_frame_timeout" category:@"playback" fields:fields];});
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if(context==CCTVPlayerItemStatusContext){AVPlayerItem *item=(AVPlayerItem *)object;if(item.status==AVPlayerItemStatusFailed){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.resumePromptPending=NO;self.pendingPlaybackSeekTime=nil;[self.spinner stopAnimating];NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"stage":@"item_status_failed", @"error_domain":item.error.domain?:@"", @"error_code":@(item.error.code), @"error_message":item.error.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];self.status.text=[NSString stringWithFormat:@"媒体载入失败 · %@",item.error.localizedDescription?:@"来源无法读取，请尝试其他线路"];self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];});}else if(item.status==AVPlayerItemStatusReadyToPlay){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.observedItem||item!=self.player.currentItem)return;self.hasVideoTrack=NO;for(AVPlayerItemTrack *track in item.tracks)if(track.assetTrack.mediaType==AVMediaTypeVideo){self.hasVideoTrack=YES;break;}NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"video_track":@(self.hasVideoTrack), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"media_item_ready" category:@"playback" fields:fields];if(self.pendingPlaybackSeekTime)[self applyPendingPlaybackSeekForItem:item];else if(self.resumePromptPending)[self offerResumeForItem:item];if(self.hasVideoTrack){if(!self.videoFrameReady){self.status.text=@"媒体已准备 · 等待视频首帧显示";self.status.accessibilityLabel=self.status.text;if(self.player.timeControlStatus==AVPlayerTimeControlStatusPaused)[self.spinner stopAnimating];else[self.spinner startAnimating];[self observePlayerLayerIfAvailable];}}else{[self.spinner stopAnimating];self.status.text=@"媒体已准备 · 未检测到视频轨道";self.status.accessibilityLabel=self.status.text;}});}return;}
    if(context==CCTVPlayerLayerReadyContext){AVPlayerLayer *layer=(AVPlayerLayer *)object;if(layer==self.videoLayer&&layer.readyForDisplay){dispatch_async(dispatch_get_main_queue(),^{if(layer==self.videoLayer&&layer.readyForDisplay)[self markFirstVideoFrameReadyForItem:self.observedItem];});}return;}
    if(context==CCTVPlayerTimeControlContext){AVPlayerTimeControlStatus state=self.player.timeControlStatus;dispatch_async(dispatch_get_main_queue(),^{if(!self.observedItem)return;if(!self.hasDiagnosticTimeControlStatus||self.lastDiagnosticTimeControlStatus!=(NSInteger)state){self.hasDiagnosticTimeControlStatus=YES;self.lastDiagnosticTimeControlStatus=(NSInteger)state;NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"video_track":@(self.hasVideoTrack)} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];if(state==AVPlayerTimeControlStatusPlaying)[RuntimeDiagnostics.shared recordEvent:@"player_reports_playing" category:@"playback" fields:fields];else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){fields[@"wait_reason"]=self.player.reasonForWaitingToPlay?:@"unknown";[RuntimeDiagnostics.shared recordEvent:@"player_waiting_to_play" category:@"playback" fields:fields];}}if(self.resolving)return;if(state==AVPlayerTimeControlStatusPlaying){if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · AVPlayer 正在播放";[self.spinner stopAnimating];}else if(self.hasVideoTrack){self.status.text=@"AVPlayer 正在播放 · 等待视频首帧";[self.spinner startAnimating];}else{self.status.text=@"AVPlayer 报告播放中";[self.spinner stopAnimating];}}else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate){self.status.text=@"正在缓冲 · 等待 AVPlayer";[self.spinner startAnimating];}else if(self.player.currentItem.status==AVPlayerItemStatusReadyToPlay){self.status.text=self.videoFrameReady?@"视频首帧已就绪 · 当前已暂停":(self.hasVideoTrack?@"媒体已准备 · 当前已暂停，等待视频首帧":@"媒体已准备 · 当前暂停");if(!self.videoFrameReady)[self.spinner stopAnimating];}self.status.accessibilityLabel=self.status.text;});return;}
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)playerItemStalled:(NSNotification *)notification {
    AVPlayerItem *item=notification.object;if(item!=self.observedItem||item!=self.player.currentItem)return;
    self.status.text=@"媒体缓冲中 · 等待网络数据";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];
    NSUInteger generation=self.playerGeneration;NSTimeInterval stalledAt=self.player.currentTime.seconds;if(!isfinite(stalledAt)||stalledAt<0)stalledAt=0;
    NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"video_track":@(self.hasVideoTrack)} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_stalled" category:@"playback" fields:fields];
    __weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.playerGeneration||item!=owner.observedItem||item!=owner.player.currentItem||owner.resolving||owner.stallRecoveryAttempts>=1||owner.player.timeControlStatus!=AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate)return;NSTimeInterval now=owner.player.currentTime.seconds;if(!isfinite(now)||fabs(now-stalledAt)>0.5)return;owner.stallRecoveryAttempts++;owner.pendingQualitySeekTime=@(stalledAt);owner.pendingQualityWasPlaying=YES;owner.pendingQualityRestorePlaybackState=YES;owner.status.text=@"网络长时间未推进 · 正在重新获取当前分集";[RuntimeDiagnostics.shared recordEvent:@"playback_stall_recovery_started" category:@"playback" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"line_index":@(owner.lineIndex),@"episode_index":@(owner.episodeIndex),@"attempt":@(owner.stallRecoveryAttempts)}];[owner resolveAndPlay];});
}
- (void)playerItemEnded:(NSNotification *)notification {
    if(notification.object!=self.observedItem||notification.object!=self.player.currentItem)return;
    NSTimeInterval position=self.player.currentTime.seconds,duration=self.observedItem.duration.seconds;if(!isfinite(position)||position<0)position=0;if(!isfinite(duration)||duration<0)duration=0;
    [MediaPlaybackStateStore recordContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:YES];[self.spinner stopAnimating];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]? [NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    if(autoNext&&self.episodeIndex+1<self.episodes.count){NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;
}
- (void)playerItemFailed:(NSNotification *)notification {if(notification.object!=self.observedItem||notification.object!=self.player.currentItem)return;[self.spinner stopAnimating];NSError *error=notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];NSMutableDictionary *fields=[@{@"player":@"AVPlayer", @"stage":@"failed_to_play_to_end", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];[fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields([NSURL URLWithString:self.result[@"url"]?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];self.status.text=[NSString stringWithFormat:@"播放失败 · %@",error.localizedDescription?:@"播放器未能打开此媒体"];self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];}
- (void)retryCurrentEpisode {[self persistPlaybackProgress];self.stallRecoveryAttempts=0;[self resolveAndPlay];}
- (void)tryNativePlayback {
    if(!self.awaitingWebPlaybackReturn||![self.result[@"url"] isKindOfClass:NSString.class])return;
    NSMutableDictionary *candidate=[self.result mutableCopy];candidate[@"parse"]=@0;candidate[@"jx"]=@0;candidate[@"requiresWebPlayback"]=@NO;candidate[@"playbackMethodOverride"]=@"avplayer";
    [RuntimeDiagnostics.shared recordEvent:@"playback_method_fallback_selected" category:@"playback" fields:@{@"method":@"avplayer",@"line_index":@(self.lineIndex),@"episode_index":@(self.episodeIndex),@"correlation_id":self.diagnosticTraceID?:@""}];
    self.awaitingWebPlaybackReturn=NO;[self playResult:candidate];
}
- (void)selectLine:(UIButton *)sender {
    if(sender.tag>=self.lines.count||sender.tag==self.lineIndex)return;
    NSArray *oldEpisodes=self.episodes;NSDictionary *oldEpisode=self.episodeIndex>=0&&self.episodeIndex<oldEpisodes.count?oldEpisodes[self.episodeIndex]:nil;NSString *oldID=[oldEpisode[@"id"] description]?:@"",*oldName=[[oldEpisode[@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";NSInteger oldIndex=self.episodeIndex;
    [self persistPlaybackProgress];self.lineIndex=sender.tag;NSArray *newEpisodes=self.episodes;NSInteger matched=-1;
    for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *candidate=newEpisodes[index];if(oldID.length&&[[candidate[@"id"] description] isEqual:oldID]){matched=index;break;}}
    if(matched<0&&oldName.length)for(NSUInteger index=0;index<newEpisodes.count;index++){NSString *name=[[newEpisodes[index][@"name"] description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if([name localizedCaseInsensitiveCompare:oldName]==NSOrderedSame){matched=index;break;}}
    BOOL exactMatch=matched>=0;NSTimeInterval current=self.player.currentTime.seconds;BOOL wasPlaying=self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying;if(exactMatch&&isfinite(current)&&current>=0){self.pendingQualitySeekTime=@(MAX(0,current));self.pendingQualityWasPlaying=wasPlaying;self.pendingQualityRestorePlaybackState=YES;}else{self.pendingQualitySeekTime=nil;self.pendingQualityRestorePlaybackState=NO;}if(!exactMatch)matched=newEpisodes.count?MIN(oldIndex,(NSInteger)newEpisodes.count-1):0;self.episodeIndex=matched;
    self.stallRecoveryAttempts=0;[self buildLines];[self updateEpisodeTitle];if(!exactMatch&&newEpisodes.count)self.status.text=@"线路已切换 · 未能按名称确认分集，已按集数位置选择";[self resolveAndPlay];
}
- (void)resolveAndPlay {
    NSArray *lines=self.lines,*episodes=self.episodes;if(self.lineIndex>=lines.count||self.episodeIndex>=episodes.count)return;
    NSDictionary *line=lines[self.lineIndex],*episode=episodes[self.episodeIndex];self.resolving=YES;NSUInteger generation=++self.generation;[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"request_generation":@(generation)}];self.result=nil;self.selectedAlternateIndex=-1;[self buildQualityButtons];[self setRetryAvailable:NO];[self clearCurrentPlayerItem];[self.spinner startAnimating];self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];NSString *provider=self.context[@"provider"];if(provider.length)args[@"provider"]=provider;
    __weak typeof(self) weakSelf=self;[self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.generation)return;owner.resolving=NO;[owner.spinner stopAnimating];if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"request_generation":@(generation), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.status.text=error.localizedDescription?:@"来源没有返回可播放结果";owner.status.accessibilityLabel=owner.status.text;[owner setRetryAvailable:YES];return;}[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"request_generation":@(generation)}];owner.status.text=@"";[owner playResult:result];}];
}
@end
