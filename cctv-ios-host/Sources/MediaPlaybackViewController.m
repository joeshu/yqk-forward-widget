#import "MediaPlaybackViewController.h"
#import "MediaAPIClient.h"
#import "MediaWebViewController.h"
#import "MediaEpisodeSelectionViewController.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import <AVKit/AVKit.h>

static void *CCTVPlayerItemStatusContext = &CCTVPlayerItemStatusContext;
static void *CCTVPlayerTimeControlContext = &CCTVPlayerTimeControlContext;

@interface MediaPlaybackViewController ()
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerViewController *playerController;
@property(nonatomic,strong) UIView *videoView;
@property(nonatomic,strong) UIView *controlPanel;
@property(nonatomic,strong) UIScrollView *lineScroll;
@property(nonatomic,strong) UIStackView *lineButtons;
@property(nonatomic,strong) UILabel *episodeTitle;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UIButton *episodeButton;
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
@property(nonatomic) NSInteger lastDiagnosticTimeControlStatus;
@property(nonatomic) BOOL hasDiagnosticTimeControlStatus;
@end

@implementation MediaPlaybackViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAllButUpsideDown;}
- (NSArray *)lines {return [self.context[@"detail"][@"lines"] isKindOfClass:NSArray.class]?self.context[@"detail"][@"lines"]:@[];}
- (NSArray *)episodes {NSArray *lines=self.lines;return self.lineIndex>=0&&self.lineIndex<lines.count&&[lines[self.lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[self.lineIndex][@"episodes"]:@[];}
- (instancetype)init {if((self=[super init])){_lineIndex=0;_episodeIndex=0;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;
    self.lineIndex=[self.context[@"lineIndex"] integerValue];self.episodeIndex=[self.context[@"episodeIndex"] integerValue];
    if(self.lineIndex<0||self.lineIndex>=self.lines.count)self.lineIndex=0;
    if(self.episodeIndex<0||self.episodeIndex>=self.episodes.count)self.episodeIndex=0;
    self.title=self.context[@"detail"][@"name"]?:self.context[@"item"][@"name"]?:@"影视播放";
    NSDictionary *source=self.context[@"source"]?:@{};self.client=[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];

    self.videoView=[UIView new];self.videoView.translatesAutoresizingMaskIntoConstraints=NO;self.videoView.backgroundColor=UIColor.blackColor;self.videoView.layer.cornerRadius=10;self.videoView.clipsToBounds=YES;[self.view addSubview:self.videoView];
    self.playerController=[AVPlayerViewController new];self.playerController.allowsPictureInPicturePlayback=YES;[self addChildViewController:self.playerController];self.playerController.view.translatesAutoresizingMaskIntoConstraints=NO;[self.videoView addSubview:self.playerController.view];[self.playerController didMoveToParentViewController:self];
    [NSLayoutConstraint activateConstraints:@[[self.playerController.view.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[self.playerController.view.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[self.playerController.view.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[self.playerController.view.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];

    self.controlPanel=[UIView new];self.controlPanel.translatesAutoresizingMaskIntoConstraints=NO;self.controlPanel.backgroundColor=HostCard();self.controlPanel.layer.cornerRadius=18;self.controlPanel.clipsToBounds=YES;[self.view addSubview:self.controlPanel];
    self.lineScroll=[UIScrollView new];self.lineScroll.translatesAutoresizingMaskIntoConstraints=NO;self.lineScroll.showsHorizontalScrollIndicator=NO;[self.controlPanel addSubview:self.lineScroll];
    self.lineButtons=[UIStackView new];self.lineButtons.axis=UILayoutConstraintAxisHorizontal;self.lineButtons.spacing=8;self.lineButtons.translatesAutoresizingMaskIntoConstraints=NO;[self.lineScroll addSubview:self.lineButtons];
    self.episodeTitle=[UILabel new];self.episodeTitle.translatesAutoresizingMaskIntoConstraints=NO;self.episodeTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];self.episodeTitle.adjustsFontForContentSizeCategory=YES;self.episodeTitle.textColor=UIColor.labelColor;self.episodeTitle.numberOfLines=2;[self.controlPanel addSubview:self.episodeTitle];
    self.status=[UILabel new];self.status.translatesAutoresizingMaskIntoConstraints=NO;self.status.textColor=UIColor.secondaryLabelColor;self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.status.numberOfLines=2;self.status.adjustsFontForContentSizeCategory=YES;[self.controlPanel addSubview:self.status];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.controlPanel addSubview:self.spinner];
    self.episodeButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeButton.translatesAutoresizingMaskIntoConstraints=NO;[self.episodeButton setTitle:@"选择分集" forState:UIControlStateNormal];HostStylePillButton(self.episodeButton,YES);[self.episodeButton addTarget:self action:@selector(openEpisodeSelection) forControlEvents:UIControlEventTouchUpInside];[self.controlPanel addSubview:self.episodeButton];

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
        [self.videoView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.videoView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.videoView.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        videoAspect,
        [self.videoView.heightAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.heightAnchor multiplier:0.49],
        [self.controlPanel.topAnchor constraintEqualToAnchor:self.videoView.bottomAnchor constant:12],
        [self.controlPanel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [self.controlPanel.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [self.controlPanel.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.episodeButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:12],
        [self.episodeButton.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:16],
        [self.episodeButton.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-16],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.episodeButton.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-14]
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
        [self.episodeTitle.topAnchor constraintEqualToAnchor:self.lineScroll.bottomAnchor constant:8],
        [self.episodeTitle.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.episodeTitle.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-14],
        [self.status.topAnchor constraintEqualToAnchor:self.episodeTitle.bottomAnchor constant:6],
        [self.status.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:14],
        [self.status.trailingAnchor constraintEqualToAnchor:self.spinner.leadingAnchor constant:-8],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.status.centerYAnchor],
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.episodeButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
        [self.episodeButton.leadingAnchor constraintEqualToAnchor:self.controlPanel.leadingAnchor constant:12],
        [self.episodeButton.trailingAnchor constraintEqualToAnchor:self.controlPanel.trailingAnchor constant:-12],
        [self.episodeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.episodeButton.bottomAnchor constraintEqualToAnchor:self.controlPanel.bottomAnchor constant:-12]
    ];
    [self updatePlaybackLayoutForSize:self.view.bounds.size];
    [self buildLines];[self updateEpisodeTitle];self.pendingEpisodeResult=self.result;
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updatePlaybackLayoutForSize:self.view.bounds.size];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];NSDictionary *pending=self.pendingEpisodeResult;self.pendingEpisodeResult=nil;if(pending)[self playResult:pending];}
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
    if(self.observedItem){@try{[self.observedItem removeObserver:self forKeyPath:@"status" context:CCTVPlayerItemStatusContext];}@catch(NSException *exception){}}
    if(self.observingPlayer){@try{[self.player removeObserver:self forKeyPath:@"timeControlStatus" context:CCTVPlayerTimeControlContext];}@catch(NSException *exception){}}
    [NSNotificationCenter.defaultCenter removeObserver:self];[self.client cancel];[self.player pause];
}
- (void)buildLines {
    for(UIView *view in self.lineButtons.arrangedSubviews.copy){[self.lineButtons removeArrangedSubview:view];[view removeFromSuperview];}
    NSArray *lines=self.lines;
    for(NSUInteger idx=0;idx<lines.count;idx++){NSDictionary *line=lines[idx];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:line[@"name"]?:[NSString stringWithFormat:@"线路 %lu",(unsigned long)idx+1] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];HostStylePillButton(button,idx==self.lineIndex);button.tag=idx;[button addTarget:self action:@selector(selectLine:) forControlEvents:UIControlEventTouchUpInside];[self.lineButtons addArrangedSubview:button];}
}
- (void)updateEpisodeTitle {
    NSArray *episodes=self.episodes;NSDictionary *episode=self.episodeIndex>=0&&self.episodeIndex<episodes.count?episodes[self.episodeIndex]:nil;
    NSString *name=episode[@"name"]?:self.context[@"item"][@"name"]?:@"当前分集";self.episodeTitle.text=name;
    NSString *line=self.lineIndex>=0&&self.lineIndex<self.lines.count?self.lines[self.lineIndex][@"name"]:@"";
    NSString *label=line.length?[NSString stringWithFormat:@"选集 · %@ · %lu 集",line,(unsigned long)episodes.count]:@"选集";
    [self.episodeButton setTitle:label forState:UIControlStateNormal];self.episodeButton.enabled=episodes.count>0;self.episodeButton.alpha=episodes.count?1.0:0.55;
}
- (void)openEpisodeSelection {
    if(!self.lines.count)return;
    self.generation++;[self.client cancel];
    MediaEpisodeSelectionViewController *page=[MediaEpisodeSelectionViewController new];page.item=self.context[@"item"]?:@{};page.source=self.context[@"source"]?:@{};page.provider=self.context[@"provider"]?:@"";page.detail=self.context[@"detail"]?:@{};page.selectedLineIndex=self.lineIndex;page.selectedEpisodeIndex=self.episodeIndex;page.selectionUpdatesPlayer=YES;page.client=[[MediaAPIClient alloc] initWithPort:[page.source[@"port"] integerValue]];
    __weak typeof(self) weakSelf=self;page.onSelectEpisode=^(NSDictionary *result,NSDictionary *context){MediaPlaybackViewController *owner=weakSelf;if(!owner)return;owner.context=context;owner.lineIndex=[context[@"lineIndex"] integerValue];owner.episodeIndex=[context[@"episodeIndex"] integerValue];owner.pendingEpisodeResult=result;[owner buildLines];[owner updateEpisodeTitle];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)playResult:(NSDictionary *)result {
    NSString *raw=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";NSURL *url=[NSURL URLWithString:raw];
    if(!url||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length){[RuntimeDiagnostics.shared recordEvent:@"episode_playback_rejected" category:@"playback" fields:@{@"reason":@"invalid_media_url", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];self.status.text=@"资源未返回有效的 HTTP/HTTPS 播放地址";self.status.accessibilityLabel=self.status.text;return;}
    NSURL *sourceURL=[NSURL URLWithString:[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:raw];NSString *extension=sourceURL.pathExtension.lowercaseString?:@"";NSSet *direct=[NSSet setWithArray:@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3"]];
    if([result[@"parse"] integerValue]>0 && ![direct containsObject:extension]){[RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:@{@"player":@"webview", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];[self.player pause];MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:result title:self.title];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:web];[self presentViewController:nav animated:YES completion:nil];return;}
    [RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:@{@"player":@"avplayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];
    self.result=result;self.hasDiagnosticTimeControlStatus=NO;self.status.text=@"已提交 AVPlayer · 等待媒体状态";[self.spinner stopAnimating];AVPlayerItem *item=[AVPlayerItem playerItemWithURL:url];
    if(self.observedItem){@try{[self.observedItem removeObserver:self forKeyPath:@"status" context:CCTVPlayerItemStatusContext];}@catch(NSException *exception){}self.observedItem=nil;}
    if(self.player.currentItem)[NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.player.currentItem];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(playerItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    if(!self.player){self.player=[AVPlayer playerWithPlayerItem:item];[self.player addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerTimeControlContext];self.observingPlayer=YES;}else[self.player replaceCurrentItemWithPlayerItem:item];
    self.observedItem=item;[item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:CCTVPlayerItemStatusContext];self.player.automaticallyWaitsToMinimizeStalling=YES;self.playerController.player=self.player;[self.navigationItem setRightBarButtonItem:nil animated:YES];[self updateEpisodeTitle];[self.player play];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if(context==CCTVPlayerItemStatusContext){AVPlayerItem *item=(AVPlayerItem *)object;if(item.status==AVPlayerItemStatusFailed){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.player.currentItem)return;[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:@{@"player":@"AVPlayer", @"stage":@"item_status_failed", @"error_domain":item.error.domain?:@"", @"error_code":@(item.error.code), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];self.status.text=[NSString stringWithFormat:@"媒体载入失败 · %@",item.error.localizedDescription?:@"来源无法读取，请尝试其他线路"];self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"重试" style:UIBarButtonItemStylePlain target:self action:@selector(retryCurrentEpisode)];});}else if(item.status==AVPlayerItemStatusReadyToPlay){dispatch_async(dispatch_get_main_queue(),^{if(item!=self.player.currentItem)return;[RuntimeDiagnostics.shared recordEvent:@"media_item_ready" category:@"playback" fields:@{@"player":@"AVPlayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];if(self.player.timeControlStatus==AVPlayerTimeControlStatusPaused)self.status.text=@"媒体已准备 · 首帧渲染状态未知";});}return;}
    if(context==CCTVPlayerTimeControlContext){AVPlayerTimeControlStatus state=self.player.timeControlStatus;dispatch_async(dispatch_get_main_queue(),^{if(!self.hasDiagnosticTimeControlStatus||self.lastDiagnosticTimeControlStatus!=(NSInteger)state){self.hasDiagnosticTimeControlStatus=YES;self.lastDiagnosticTimeControlStatus=state;if(state==AVPlayerTimeControlStatusPlaying)[RuntimeDiagnostics.shared recordEvent:@"player_reports_playing" category:@"playback" fields:@{@"player":@"AVPlayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate)[RuntimeDiagnostics.shared recordEvent:@"player_waiting_to_play" category:@"playback" fields:@{@"player":@"AVPlayer", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];}if(state==AVPlayerTimeControlStatusPlaying)self.status.text=@"AVPlayer 报告播放中 · 首帧渲染状态未知";else if(state==AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate)self.status.text=@"正在缓冲 · 等待 AVPlayer 开始播放";else if(self.player.currentItem.status==AVPlayerItemStatusReadyToPlay)self.status.text=@"媒体已准备 · 当前暂停；首帧渲染未知";});return;}
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
- (void)playerItemFailed:(NSNotification *)notification {if(notification.object!=self.player.currentItem)return;NSError *error=notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:@{@"player":@"AVPlayer", @"stage":@"failed_to_play_to_end", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex)}];self.status.text=[NSString stringWithFormat:@"播放失败 · %@",error.localizedDescription?:@"播放器未能打开此媒体"];self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"重试" style:UIBarButtonItemStylePlain target:self action:@selector(retryCurrentEpisode)];}
- (void)retryCurrentEpisode {[self resolveAndPlay];}
- (void)selectLine:(UIButton *)sender {if(sender.tag>=self.lines.count||sender.tag==self.lineIndex)return;self.lineIndex=sender.tag;self.episodeIndex=0;[self buildLines];[self updateEpisodeTitle];[self resolveAndPlay];}
- (void)resolveAndPlay {
    NSArray *lines=self.lines,*episodes=self.episodes;if(self.lineIndex>=lines.count||self.episodeIndex>=episodes.count)return;
    NSDictionary *line=lines[self.lineIndex],*episode=episodes[self.episodeIndex];self.resolving=YES;NSUInteger generation=++self.generation;[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"generation":@(generation)}];[self.spinner startAnimating];self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];NSString *provider=self.context[@"provider"];if(provider.length)args[@"provider"]=provider;
    __weak typeof(self) weakSelf=self;[self.client call:@"play" arguments:args completion:^(id result,NSError *error){MediaPlaybackViewController *owner=weakSelf;if(!owner||generation!=owner.generation)return;owner.resolving=NO;[owner.spinner stopAnimating];if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex), @"error_domain":error.domain?:@"", @"error_code":@(error.code)}];owner.status.text=error.localizedDescription?:@"来源没有返回可播放结果";owner.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"重试" style:UIBarButtonItemStylePlain target:owner action:@selector(retryCurrentEpisode)];return;}[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"line_index":@(owner.lineIndex), @"episode_index":@(owner.episodeIndex)}];owner.status.text=@"";[owner playResult:result];}];
}
@end
