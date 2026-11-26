#import "ShortDramaVerticalFeedController.h"
#import "HostGlassActionSheetViewController.h"
#import "HostTheme.h"
#import "MediaPlaybackStateStore.h"
#import "PlaybackCoordinator.h"
#import "HostMemoryBudgetCoordinator.h"
#import <AVFoundation/AVFoundation.h>

/// 短剧槽位解析状态（M01）：resolving/ready/failed/cancelled 四态显式收敛，
/// 完成与取消都必须落到终态，不再用单个 BOOL 猜测。
typedef NS_ENUM(NSInteger, ShortDramaSlotState) {
    ShortDramaSlotStateIdle = 0,
    ShortDramaSlotStateResolving,
    ShortDramaSlotStateReady,
    ShortDramaSlotStateFailed,
    ShortDramaSlotStateCancelled
};

@interface ShortDramaPlayerSlot : NSObject
@property (nonatomic, assign) NSInteger episodeIndex;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, assign) ShortDramaSlotState state;
@property (nonatomic, copy, nullable) ShortDramaResolveCancel resolveCancel;
/// T17：失败原因（解析让路/能力不支持/播放失败），失败卡片显示用。
@property (nonatomic, copy, nullable) NSString *failureReason;
/// T17：首帧/播放证据——播放中且进度>0.5s 后置位，无证据不写历史（M11 同款门禁）。
@property (nonatomic, assign) BOOL evidenceReady;
/// T17：上次已持久化位置（10s 节奏）。
@property (nonatomic, assign) NSTimeInterval lastPersistedPosition;
/// T17：进入时那一集的续播 seek 是否已做过（只做一次）。
@property (nonatomic, assign) BOOL resumeSeekDone;
/// T17：已写过 completed=YES——离场/关闭时的 completed=NO 写不再覆盖完成态。
@property (nonatomic, assign) BOOL completedPersisted;
@end

@implementation ShortDramaPlayerSlot
@end

@interface ShortDramaFeedCell : UICollectionViewCell
@property (nonatomic, strong) UIView *videoHost;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *episodeBadge;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong, nullable) AVPlayerLayer *attachedLayer;
/// T17：失败卡片——原因文案 + 卡片内重试 + 标准播放器出口。
@property (nonatomic, strong) UIView *failureView;
@property (nonatomic, strong) UILabel *failureLabel;
@property (nonatomic, strong) UIButton *failureRetryButton;
@property (nonatomic, strong) UIButton *failureStandardButton;
- (void)attachPlayerLayer:(nullable AVPlayerLayer *)layer;
- (void)showFailureWithReason:(NSString *)reason canOpenInStandardPlayer:(BOOL)canOpen;
- (void)hideFailure;
@end

@implementation ShortDramaFeedCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.blackColor;
        _videoHost = [[UIView alloc] initWithFrame:self.contentView.bounds];
        _videoHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:_videoHost];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.color = UIColor.whiteColor;
        [self.contentView addSubview:_spinner];

        _episodeBadge = [UILabel new];
        _episodeBadge.translatesAutoresizingMaskIntoConstraints = NO;
        _episodeBadge.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _episodeBadge.textColor = UIColor.whiteColor;
        _episodeBadge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _episodeBadge.layer.cornerRadius = 10;
        _episodeBadge.clipsToBounds = YES;
        [self.contentView addSubview:_episodeBadge];

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.numberOfLines = 2;
        _titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
        _titleLabel.shadowOffset = CGSizeMake(0, 1);
        [self.contentView addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_spinner.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_episodeBadge.leadingAnchor constraintEqualToAnchor:self.contentView.safeAreaLayoutGuide.leadingAnchor constant:16],
            [_episodeBadge.bottomAnchor constraintEqualToAnchor:_titleLabel.topAnchor constant:-8],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.safeAreaLayoutGuide.leadingAnchor constant:16],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.safeAreaLayoutGuide.trailingAnchor constant:-76],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.safeAreaLayoutGuide.bottomAnchor constant:-28],
        ]];

        _failureView = [UIView new];
        _failureView.translatesAutoresizingMaskIntoConstraints = NO;
        _failureView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        _failureView.layer.cornerRadius = 14;
        _failureView.clipsToBounds = YES;
        _failureView.hidden = YES;
        [self.contentView addSubview:_failureView];

        _failureLabel = [UILabel new];
        _failureLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _failureLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _failureLabel.textColor = UIColor.whiteColor;
        _failureLabel.numberOfLines = 0;
        _failureLabel.textAlignment = NSTextAlignmentCenter;
        [_failureView addSubview:_failureLabel];

        _failureRetryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _failureRetryButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_failureRetryButton setTitle:@"重试播放" forState:UIControlStateNormal];
        _failureRetryButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [_failureRetryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _failureRetryButton.backgroundColor = HostAccent();
        _failureRetryButton.layer.cornerRadius = 10;
        _failureRetryButton.layer.cornerCurve = kCACornerCurveContinuous;
        _failureRetryButton.accessibilityLabel = @"重试播放此集";
        [_failureView addSubview:_failureRetryButton];

        _failureStandardButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _failureStandardButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_failureStandardButton setTitle:@"用标准播放器打开" forState:UIControlStateNormal];
        _failureStandardButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [_failureStandardButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        _failureStandardButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        _failureStandardButton.layer.cornerRadius = 10;
        _failureStandardButton.layer.cornerCurve = kCACornerCurveContinuous;
        _failureStandardButton.accessibilityLabel = @"用标准播放器打开此集";
        [_failureView addSubview:_failureStandardButton];

        [NSLayoutConstraint activateConstraints:@[
            [_failureView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_failureView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_failureView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.leadingAnchor constant:32],
            [_failureView.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-32],
            [_failureLabel.topAnchor constraintEqualToAnchor:_failureView.topAnchor constant:16],
            [_failureLabel.leadingAnchor constraintEqualToAnchor:_failureView.leadingAnchor constant:16],
            [_failureLabel.trailingAnchor constraintEqualToAnchor:_failureView.trailingAnchor constant:-16],
            [_failureRetryButton.topAnchor constraintEqualToAnchor:_failureLabel.bottomAnchor constant:12],
            [_failureRetryButton.leadingAnchor constraintEqualToAnchor:_failureView.leadingAnchor constant:16],
            [_failureRetryButton.trailingAnchor constraintEqualToAnchor:_failureView.trailingAnchor constant:-16],
            [_failureRetryButton.heightAnchor constraintEqualToConstant:44],
            [_failureStandardButton.topAnchor constraintEqualToAnchor:_failureRetryButton.bottomAnchor constant:8],
            [_failureStandardButton.leadingAnchor constraintEqualToAnchor:_failureView.leadingAnchor constant:16],
            [_failureStandardButton.trailingAnchor constraintEqualToAnchor:_failureView.trailingAnchor constant:-16],
            [_failureStandardButton.heightAnchor constraintEqualToConstant:44],
            [_failureStandardButton.bottomAnchor constraintEqualToAnchor:_failureView.bottomAnchor constant:-16],
        ]];
    }
    return self;
}
- (void)showFailureWithReason:(NSString *)reason canOpenInStandardPlayer:(BOOL)canOpen {
    self.failureLabel.text = reason.length ? reason : @"无法播放此集";
    self.failureLabel.accessibilityLabel = self.failureLabel.text;
    self.failureStandardButton.hidden = !canOpen;
    self.failureView.hidden = NO;
}
- (void)hideFailure {
    self.failureView.hidden = YES;
}
- (void)attachPlayerLayer:(AVPlayerLayer *)layer {
    if (self.attachedLayer == layer) return;
    [self.attachedLayer removeFromSuperlayer];
    self.attachedLayer = layer;
    if (layer) {
        layer.frame = self.videoHost.bounds;
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.videoHost.layer insertSublayer:layer atIndex:0];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.attachedLayer) {
        self.attachedLayer.frame = self.videoHost.bounds;
    }
}
- (void)prepareForReuse {
    [super prepareForReuse];
    [self attachPlayerLayer:nil];
    [self.spinner stopAnimating];
    [self hideFailure];
}
@end

@interface ShortDramaVerticalFeedController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, PlaybackSession>
@property (nonatomic, copy) NSString *dramaTitle;
@property (nonatomic, copy) NSArray<NSDictionary *> *episodes;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, copy, nullable) ShortDramaEpisodeResolver episodeResolver;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ShortDramaPlayerSlot *> *playerPool;
/// 退场后为 NO：关闭后到达的异步解析回调一律丢弃，不再触发播放（M02）。
@property (nonatomic, assign) BOOL feedActive;
/// T17：进入时那一集的下标（续播 seek 只对它做一次）。
@property (nonatomic, assign) NSInteger entryIndex;
/// T17：当前集的 1s 进度观察（只跟当前集，切换/退出时移除）。
@property (nonatomic, strong, nullable) id progressObserver;
@property (nonatomic, weak, nullable) AVPlayer *observedPlayer;
- (void)closeFeed;
- (void)showEpisodeDrawer;
- (void)updateSlidingPoolAroundIndex:(NSInteger)centerIndex;
- (void)prepareSlotForIndex:(NSInteger)index autoPlay:(BOOL)autoPlay;
- (void)startResolveForSlot:(ShortDramaPlayerSlot *)slot index:(NSInteger)index;
- (void)handlePlaybackEnded:(NSNotification *)note;
- (void)handlePlaybackFailed:(NSNotification *)note;
- (void)retryFailedEpisode:(UIButton *)sender;
- (void)openFailedEpisodeInStandardPlayer:(UIButton *)sender;
- (void)persistSlotProgress:(ShortDramaPlayerSlot *)slot completed:(BOOL)completed;
- (void)installProgressObserverForSlot:(nullable ShortDramaPlayerSlot *)slot;
- (void)removeProgressObserver;
@end

@implementation ShortDramaVerticalFeedController

- (instancetype)initWithTitle:(NSString *)dramaTitle
                     episodes:(NSArray<NSDictionary *> *)episodes
                 initialIndex:(NSInteger)initialIndex
               episodeResolver:(ShortDramaEpisodeResolver)resolver {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _dramaTitle = [dramaTitle copy] ?: @"短剧";
        _episodes = [episodes copy] ?: @[];
        _activeIndex = MAX(0, MIN(initialIndex, (NSInteger)_episodes.count - 1));
        _entryIndex = _activeIndex;
        _episodeResolver = [resolver copy];
        _playerPool = [NSMutableDictionary dictionaryWithCapacity:3];
        _feedActive = YES;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    return self;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumLineSpacing = 0;
    layout.minimumInteritemSpacing = 0;

    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.blackColor;
    self.collectionView.pagingEnabled = YES;
    self.collectionView.showsVerticalScrollIndicator = NO;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.accessibilityIdentifier = @"shortdrama.vertical.feed";
    [self.collectionView registerClass:ShortDramaFeedCell.class forCellWithReuseIdentifier:@"drama.cell"];
    [self.view addSubview:self.collectionView];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.tintColor = UIColor.whiteColor;
    closeBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    closeBtn.layer.cornerRadius = 20;
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    closeBtn.accessibilityLabel = @"退出短剧沉浸模式";
    [closeBtn addTarget:self action:@selector(closeFeed) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeBtn];

    UIButton *drawerBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    drawerBtn.translatesAutoresizingMaskIntoConstraints = NO;
    drawerBtn.tintColor = UIColor.whiteColor;
    drawerBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    drawerBtn.layer.cornerRadius = 20;
    [drawerBtn setImage:[UIImage systemImageNamed:@"list.bullet"] forState:UIControlStateNormal];
    drawerBtn.accessibilityLabel = @"选集抽屉";
    [drawerBtn addTarget:self action:@selector(showEpisodeDrawer) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:drawerBtn];

    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [closeBtn.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [closeBtn.widthAnchor constraintEqualToConstant:40],
        [closeBtn.heightAnchor constraintEqualToConstant:40],
        [drawerBtn.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [drawerBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-32],
        [drawerBtn.widthAnchor constraintEqualToConstant:40],
        [drawerBtn.heightAnchor constraintEqualToConstant:40],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handlePlaybackEnded:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handlePlaybackFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // M02/S6：短剧流是前台唯一有声 owner，进场即收编到统一播放会话，
    // 遥控/耳机/中断只应落到它身上，离开时释放（见 closeFeed）。
    [[PlaybackCoordinator shared] acquireSession:(id<PlaybackSession>)self];
    if (self.episodes.count > 0 && self.activeIndex < (NSInteger)self.episodes.count) {
        [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:self.activeIndex inSection:0]
                                    atScrollPosition:UICollectionViewScrollPositionTop
                                            animated:NO];
        [self updateSlidingPoolAroundIndex:self.activeIndex];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // 被其它方式解散（如手势）时同样释放会话；正常 closeFeed 已释放，
    // releaseSession 对非当前会话是 no-op，可安全重入。
    if (!self.feedActive) [[PlaybackCoordinator shared] releaseSession:(id<PlaybackSession>)self];
}

#pragma mark - PlaybackSession（统一播放会话，M02/S6）

- (BOOL)sessionHasContent {
    ShortDramaPlayerSlot *current = self.playerPool[@(self.activeIndex)];
    return current && current.player.currentItem != nil;
}

- (BOOL)sessionIsPlaying {
    ShortDramaPlayerSlot *current = self.playerPool[@(self.activeIndex)];
    return current && current.player.rate > 0;
}

- (void)sessionPlay {
    if (!self.feedActive) return;
    [self prepareSlotForIndex:self.activeIndex autoPlay:YES];
}

- (void)sessionPause {
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) [slot.player pause];
}

- (BOOL)sessionStep:(NSInteger)direction {
    if (!self.feedActive || direction == 0) return NO;
    NSInteger target = self.activeIndex + (direction > 0 ? 1 : -1);
    if (target < 0 || target >= (NSInteger)self.episodes.count) return NO;
    [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:target inSection:0]
                                atScrollPosition:UICollectionViewScrollPositionTop
                                        animated:YES];
    [self updateSlidingPoolAroundIndex:target];
    return YES;
}

- (BOOL)sessionWantsPlayback {
    return self.feedActive;
}

- (void)sessionMediaServicesReset {
    [self sessionPause];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self removeProgressObserver];
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        if (slot.resolveCancel) { slot.resolveCancel(); slot.resolveCancel = nil; }
        slot.state = ShortDramaSlotStateCancelled;
        [slot.player pause];
        [slot.player replaceCurrentItemWithPlayerItem:nil];
    }
}

- (void)closeFeed {
    // T17：退出前先把当前集进度落库（有证据才记），再立退场 flag。
    [self persistSlotProgress:self.playerPool[@(self.activeIndex)] completed:NO];
    [self removeProgressObserver];
    // M02：退场先立 flag 再取消解析、暂停全部槽位、释放会话，最后才解散。
    // 此后到达的异步解析回调在 applyURL 里按 feedActive 丢弃，杜绝退场后出声。
    self.feedActive = NO;
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        if (slot.resolveCancel) { slot.resolveCancel(); slot.resolveCancel = nil; }
        slot.state = ShortDramaSlotStateCancelled;
        [slot.player pause];
    }
    [[PlaybackCoordinator shared] releaseSession:(id<PlaybackSession>)self];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)retryFailedEpisode:(UIButton *)sender {
    if (!self.feedActive) return;
    NSInteger index = sender.tag;
    ShortDramaPlayerSlot *slot = self.playerPool[@(index)];
    if (!slot || slot.state != ShortDramaSlotStateFailed) return;
    ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
    if (cell) { [cell hideFailure]; [cell.spinner startAnimating]; }
    [self startResolveForSlot:slot index:index];
}

- (void)openFailedEpisodeInStandardPlayer:(UIButton *)sender {
    if (!self.feedActive || !self.onOpenInStandardPlayer) return;
    self.onOpenInStandardPlayer(sender.tag);
}

/// T17：把一集进度写入观看历史（一集一条，与标准播放器同一条目）。
/// 无 historyContext 时不写；无播放证据且未完成时不写（M11 同款门禁）。
- (void)persistSlotProgress:(ShortDramaPlayerSlot *)slot completed:(BOOL)completed {
    if (!slot || !self.historyContext) return;
    if (slot.completedPersisted && !completed) return;
    if (!slot.evidenceReady && !completed) return;
    AVPlayerItem *item = slot.player.currentItem;
    if (!item) return;
    NSTimeInterval position = CMTimeGetSeconds(slot.player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(item.duration);
    if (!isfinite(position) || position < 0) return;
    if (!isfinite(duration) || duration < 0) duration = 0;
    if (!completed && position <= 0) return;
    NSInteger lineIndex = [self.historyContext[@"lineIndex"] integerValue];
    NSMutableDictionary *context = [self.historyContext mutableCopy];
    context[@"episodeIndex"] = @(slot.episodeIndex);
    [MediaPlaybackStateStore recordContext:context lineIndex:lineIndex episodeIndex:slot.episodeIndex position:position duration:duration completed:completed];
    if (completed) slot.completedPersisted = YES;
    slot.lastPersistedPosition = completed ? duration : position;
}

- (void)installProgressObserverForSlot:(ShortDramaPlayerSlot *)slot {
    [self removeProgressObserver];
    if (!slot || !self.historyContext) return;
    __weak typeof(self) weakSelf = self;
    __weak AVPlayer *weakPlayer = slot.player;
    self.observedPlayer = slot.player;
    self.progressObserver = [slot.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        ShortDramaVerticalFeedController *owner = weakSelf;
        AVPlayer *player = weakPlayer;
        if (!owner || !owner.feedActive || !player) return;
        ShortDramaPlayerSlot *current = owner.playerPool[@(owner.activeIndex)];
        if (!current || current.player != player || current.state != ShortDramaSlotStateReady) return;
        NSTimeInterval position = CMTimeGetSeconds(time);
        if (!isfinite(position) || position < 0) return;
        if (player.rate > 0 && position > 0.5) current.evidenceReady = YES;
        if (current.evidenceReady && position - current.lastPersistedPosition >= 10.0) {
            [owner persistSlotProgress:current completed:NO];
        }
    }];
}

- (void)removeProgressObserver {
    if (self.progressObserver && self.observedPlayer) [self.observedPlayer removeTimeObserver:self.progressObserver];
    self.progressObserver = nil;
    self.observedPlayer = nil;
}

- (void)showEpisodeDrawer {
    __weak typeof(self) weakSelf = self;
    NSUInteger maxShow = MIN(self.episodes.count, (NSUInteger)30);
    NSMutableArray<HostGlassSheetAction *> *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < maxShow; i++) {
        NSString *name = [self.episodes[i][@"name"] isKindOfClass:NSString.class] ? self.episodes[i][@"name"] : [NSString stringWithFormat:@"第 %lu 集", (unsigned long)i + 1];
        BOOL selected = ((NSInteger)i == self.activeIndex);
        [rows addObject:[HostGlassSheetAction actionWithTitle:name subtitle:nil value:nil icon:nil tint:(selected ? HostAccent() : UIColor.systemBlueColor) destructive:NO selected:selected handler:^{
            ShortDramaVerticalFeedController *owner = weakSelf;
            if (!owner) return;
            owner.activeIndex = (NSInteger)i;
            [owner.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:(NSInteger)i inSection:0]
                                         atScrollPosition:UICollectionViewScrollPositionTop
                                                 animated:YES];
            [owner updateSlidingPoolAroundIndex:(NSInteger)i];
        }]];
    }
    [HostGlassActionSheetViewController presentOn:self
                                            title:self.dramaTitle
                                         subtitle:@"选择分集"
                                        badgeText:nil
                                       badgeColor:nil
                                         sections:@[[HostGlassSheetSection sectionWithTitle:nil actions:rows]]
                                       sourceView:self.view];
}

- (void)updateSlidingPoolAroundIndex:(NSInteger)centerIndex {
    // T17：切集前先把离场那集进度落库（有证据才记）。
    ShortDramaPlayerSlot *outgoing = self.playerPool[@(self.activeIndex)];
    if (outgoing && outgoing.episodeIndex != centerIndex) [self persistSlotProgress:outgoing completed:NO];
    self.activeIndex = centerIndex;
    // Maintain 3-player sliding window: [centerIndex - 1, centerIndex, centerIndex + 1]
    NSSet<NSNumber *> *keepKeys = [NSSet setWithObjects:@(centerIndex - 1), @(centerIndex), @(centerIndex + 1), nil];
    for (NSNumber *key in self.playerPool.allKeys.copy) {
        if (![keepKeys containsObject:key]) {
            ShortDramaPlayerSlot *evicted = self.playerPool[key];
            // M01：逐出即取消未完成的解析，回调不再落地，槽位进入终态。
            if (evicted.resolveCancel) { evicted.resolveCancel(); evicted.resolveCancel = nil; }
            evicted.state = ShortDramaSlotStateCancelled;
            [evicted.player pause];
            [evicted.player replaceCurrentItemWithPlayerItem:nil];
            [evicted.playerLayer removeFromSuperlayer];
            [self.playerPool removeObjectForKey:key];
        } else if (key.integerValue != centerIndex) {
            [self.playerPool[key].player pause];
        }
    }
    // Centre-first：先发当前集解析，再发邻集；邻集只预热、不抢当前集的解析。
    // T21/S6：邻集预解析按剩余资源决定——正常/未知前后各一集；Warning 只预取
    // 下一集；Critical 只解当前集，邻集滑到时再解（不取消已在途的解析）。
    HostMemoryBudgetPressure pressure = [HostMemoryBudgetCoordinator.shared currentPressure];
    NSUInteger neighborBudget = pressure == HostMemoryBudgetPressureCritical ? 0 : (pressure == HostMemoryBudgetPressureWarning ? 1 : 2);
    [self prepareSlotForIndex:centerIndex autoPlay:YES];
    if (neighborBudget >= 1 && centerIndex + 1 < (NSInteger)self.episodes.count) [self prepareSlotForIndex:centerIndex + 1 autoPlay:NO];
    if (neighborBudget >= 2 && centerIndex - 1 >= 0) [self prepareSlotForIndex:centerIndex - 1 autoPlay:NO];
    // T17：进度观察只跟当前集。
    [self installProgressObserverForSlot:self.playerPool[@(centerIndex)]];
}

- (void)prepareSlotForIndex:(NSInteger)index autoPlay:(BOOL)autoPlay {
    if (index < 0 || index >= (NSInteger)self.episodes.count) return;
    ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
    ShortDramaPlayerSlot *existing = self.playerPool[@(index)];
    if (existing) {
        switch (existing.state) {
            case ShortDramaSlotStateReady:
                if (autoPlay) [existing.player play];
                if (cell) { [cell attachPlayerLayer:existing.playerLayer]; [cell.spinner stopAnimating]; }
                break;
            case ShortDramaSlotStateResolving:
                // M01：解析中重遇只挂层、不播、不停 spinner；回调到达时再由 applyURL 播放。
                // 旧行为在这里 play（无 item）并停 spinner，等于把卡住的槽判成已就绪。
                if (cell) { [cell attachPlayerLayer:existing.playerLayer]; [cell.spinner startAnimating]; }
                break;
            case ShortDramaSlotStateFailed:
            case ShortDramaSlotStateCancelled:
                // M01：失败/已取消的槽再次成为当前集时重试；邻集不后台空转重试。
                if (autoPlay) { [self startResolveForSlot:existing index:index]; if (cell) [cell.spinner startAnimating]; }
                else if (cell) { [cell attachPlayerLayer:existing.playerLayer]; [cell.spinner stopAnimating]; }
                break;
            case ShortDramaSlotStateIdle:
                if (autoPlay) { [self startResolveForSlot:existing index:index]; if (cell) [cell.spinner startAnimating]; }
                break;
        }
        return;
    }

    ShortDramaPlayerSlot *slot = [ShortDramaPlayerSlot new];
    slot.episodeIndex = index;
    slot.player = [AVPlayer new];
    slot.playerLayer = [AVPlayerLayer playerLayerWithPlayer:slot.player];
    slot.state = ShortDramaSlotStateResolving;
    self.playerPool[@(index)] = slot;
    if (cell) [cell.spinner startAnimating];
    [self startResolveForSlot:slot index:index];
}

/// 为槽位发起一次解析：直链直接落地，否则走 resolver；返回的取消令牌记在槽位上。
- (void)startResolveForSlot:(ShortDramaPlayerSlot *)slot index:(NSInteger)index {
    slot.state = ShortDramaSlotStateResolving;
    slot.resolveCancel = nil;
    slot.failureReason = nil;
    slot.completedPersisted = NO;
    ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
    if (cell) [cell hideFailure];
    __weak typeof(self) weakSelf = self;
    void (^applyURL)(NSURL *, NSDictionary<NSString *, NSString *> *, NSString *) = ^(NSURL *url, NSDictionary<NSString *, NSString *> *headers, NSString *failureReason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ShortDramaVerticalFeedController *owner = weakSelf;
            // M02：退场后到达的回调一律丢弃；已被逐出/取消的槽位同样丢弃。
            if (!owner || !owner.feedActive) return;
            if (owner.playerPool[@(index)] != slot || slot.state != ShortDramaSlotStateResolving) return;
            slot.resolveCancel = nil;
            if (!url) {
                slot.state = ShortDramaSlotStateFailed;
                slot.failureReason = failureReason.length ? failureReason : @"无法播放此集";
                ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[owner.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
                if (cell) { [cell.spinner stopAnimating]; [cell showFailureWithReason:slot.failureReason canOpenInStandardPlayer:owner.onOpenInStandardPlayer != nil]; }
                return;
            }
            AVURLAsset *asset = headers.count ? [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}] : [AVURLAsset URLAssetWithURL:url options:nil];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            // S6：邻集资源上限——当前集 10s 前向缓冲，邻集只给 4s。
            item.preferredForwardBufferDuration = (index == owner.activeIndex) ? 10.0 : 4.0;
            [slot.player replaceCurrentItemWithPlayerItem:item];
            slot.state = ShortDramaSlotStateReady;
            slot.failureReason = nil;
            ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[owner.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
            if (cell) {
                [cell attachPlayerLayer:slot.playerLayer];
                [cell.spinner stopAnimating];
                [cell hideFailure];
            }
            if (index == owner.activeIndex) {
                // T17：进入时那一集有续播位置，seek 一次再播（只做一次）。
                if (index == owner.entryIndex && owner.initialResumePosition > 0 && !slot.resumeSeekDone) {
                    slot.resumeSeekDone = YES;
                    [slot.player seekToTime:CMTimeMakeWithSeconds(owner.initialResumePosition, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                        if (finished && owner.feedActive && index == owner.activeIndex) [slot.player play];
                    }];
                } else {
                    [slot.player play];
                }
            }
        });
    };

    NSString *directURL = [self.episodes[(NSUInteger)index][@"url"] isKindOfClass:NSString.class] ? self.episodes[(NSUInteger)index][@"url"] : nil;
    if (directURL.length && [NSURL URLWithString:directURL]) {
        applyURL([NSURL URLWithString:directURL], nil, nil);
    } else if (self.episodeResolver) {
        slot.resolveCancel = self.episodeResolver(index, applyURL);
    } else {
        slot.state = ShortDramaSlotStateFailed;
        slot.failureReason = @"无法播放此集";
        if (cell) { [cell.spinner stopAnimating]; [cell showFailureWithReason:slot.failureReason canOpenInStandardPlayer:self.onOpenInStandardPlayer != nil]; }
    }
}

- (void)handlePlaybackEnded:(NSNotification *)note {
    if (!self.feedActive) return;
    ShortDramaPlayerSlot *current = self.playerPool[@(self.activeIndex)];
    if (!current || note.object != current.player.currentItem) return;
    // T17：播完记完成态，再切下一集。
    [self persistSlotProgress:current completed:YES];
    NSInteger nextIdx = self.activeIndex + 1;
    if (nextIdx < (NSInteger)self.episodes.count) {
        [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:nextIdx inSection:0]
                                    atScrollPosition:UICollectionViewScrollPositionTop
                                            animated:YES];
        [self updateSlidingPoolAroundIndex:nextIdx];
    }
}

- (void)handlePlaybackFailed:(NSNotification *)note {
    if (!self.feedActive) return;
    AVPlayerItem *item = note.object;
    if (![item isKindOfClass:AVPlayerItem.class]) return;
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        if (slot.player.currentItem != item) continue;
        slot.state = ShortDramaSlotStateFailed;
        slot.failureReason = @"播放失败，请重试或用标准播放器打开";
        ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:slot.episodeIndex inSection:0]];
        if (cell) { [cell.spinner stopAnimating]; [cell showFailureWithReason:slot.failureReason canOpenInStandardPlayer:self.onOpenInStandardPlayer != nil]; }
        break;
    }
}

#pragma mark - UICollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView; (void)section;
    return (NSInteger)self.episodes.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ShortDramaFeedCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"drama.cell" forIndexPath:indexPath];
    NSDictionary *ep = self.episodes[(NSUInteger)indexPath.item];
    NSString *epName = [ep[@"name"] isKindOfClass:NSString.class] ? ep[@"name"] : [NSString stringWithFormat:@"第 %ld 集", (long)indexPath.item + 1];
    cell.episodeBadge.text = [NSString stringWithFormat:@"  %@  ", epName];
    cell.titleLabel.text = self.dramaTitle;
    ShortDramaPlayerSlot *slot = self.playerPool[@(indexPath.item)];
    if (slot) {
        [cell attachPlayerLayer:slot.playerLayer];
        // M01：spinner 跟随槽位状态——解析中转，失败/已取消停；T17：失败槽显示失败卡片。
        if (slot.state == ShortDramaSlotStateResolving) [cell.spinner startAnimating];
        else [cell.spinner stopAnimating];
        if (slot.state == ShortDramaSlotStateFailed) [cell showFailureWithReason:slot.failureReason ?: @"无法播放此集" canOpenInStandardPlayer:self.onOpenInStandardPlayer != nil];
        else [cell hideFailure];
        [cell.failureRetryButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.failureRetryButton addTarget:self action:@selector(retryFailedEpisode:) forControlEvents:UIControlEventTouchUpInside];
        cell.failureRetryButton.tag = indexPath.item;
        [cell.failureStandardButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.failureStandardButton addTarget:self action:@selector(openFailedEpisodeInStandardPlayer:) forControlEvents:UIControlEventTouchUpInside];
        cell.failureStandardButton.tag = indexPath.item;
    } else {
        [cell.spinner startAnimating];
        [cell hideFailure];
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionViewLayout; (void)indexPath;
    return collectionView.bounds.size;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    CGFloat h = MAX(1.0, scrollView.bounds.size.height);
    NSInteger page = (NSInteger)llround(scrollView.contentOffset.y / h);
    page = MAX(0, MIN(page, (NSInteger)self.episodes.count - 1));
    if (page != self.activeIndex) {
        [self updateSlidingPoolAroundIndex:page];
    }
}

@end
