#import "ShortDramaVerticalFeedController.h"
#import "HostGlassActionSheetViewController.h"
#import "HostTheme.h"
#import "PlaybackCoordinator.h"
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
@end

@implementation ShortDramaPlayerSlot
@end

@interface ShortDramaFeedCell : UICollectionViewCell
@property (nonatomic, strong) UIView *videoHost;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *episodeBadge;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong, nullable) AVPlayerLayer *attachedLayer;
- (void)attachPlayerLayer:(nullable AVPlayerLayer *)layer;
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
    }
    return self;
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
- (void)closeFeed;
- (void)showEpisodeDrawer;
- (void)updateSlidingPoolAroundIndex:(NSInteger)centerIndex;
- (void)prepareSlotForIndex:(NSInteger)index autoPlay:(BOOL)autoPlay;
- (void)startResolveForSlot:(ShortDramaPlayerSlot *)slot index:(NSInteger)index;
- (void)handlePlaybackEnded:(NSNotification *)note;
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
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        if (slot.resolveCancel) { slot.resolveCancel(); slot.resolveCancel = nil; }
        slot.state = ShortDramaSlotStateCancelled;
        [slot.player pause];
        [slot.player replaceCurrentItemWithPlayerItem:nil];
    }
}

- (void)closeFeed {
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
    [self prepareSlotForIndex:centerIndex autoPlay:YES];
    if (centerIndex + 1 < (NSInteger)self.episodes.count) [self prepareSlotForIndex:centerIndex + 1 autoPlay:NO];
    if (centerIndex - 1 >= 0) [self prepareSlotForIndex:centerIndex - 1 autoPlay:NO];
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
    __weak typeof(self) weakSelf = self;
    void (^applyURL)(NSURL *, NSDictionary<NSString *, NSString *> *) = ^(NSURL *url, NSDictionary<NSString *, NSString *> *headers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ShortDramaVerticalFeedController *owner = weakSelf;
            // M02：退场后到达的回调一律丢弃；已被逐出/取消的槽位同样丢弃。
            if (!owner || !owner.feedActive) return;
            if (owner.playerPool[@(index)] != slot || slot.state != ShortDramaSlotStateResolving) return;
            slot.resolveCancel = nil;
            if (!url) {
                slot.state = ShortDramaSlotStateFailed;
                ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[owner.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
                if (cell) [cell.spinner stopAnimating];
                return;
            }
            AVURLAsset *asset = headers.count ? [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}] : [AVURLAsset URLAssetWithURL:url options:nil];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            // S6：邻集资源上限——当前集 10s 前向缓冲，邻集只给 4s。
            item.preferredForwardBufferDuration = (index == owner.activeIndex) ? 10.0 : 4.0;
            [slot.player replaceCurrentItemWithPlayerItem:item];
            slot.state = ShortDramaSlotStateReady;
            ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[owner.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
            if (cell) {
                [cell attachPlayerLayer:slot.playerLayer];
                [cell.spinner stopAnimating];
            }
            if (index == owner.activeIndex) [slot.player play];
        });
    };

    NSString *directURL = [self.episodes[(NSUInteger)index][@"url"] isKindOfClass:NSString.class] ? self.episodes[(NSUInteger)index][@"url"] : nil;
    if (directURL.length && [NSURL URLWithString:directURL]) {
        applyURL([NSURL URLWithString:directURL], nil);
    } else if (self.episodeResolver) {
        slot.resolveCancel = self.episodeResolver(index, applyURL);
    } else {
        slot.state = ShortDramaSlotStateFailed;
    }
}

- (void)handlePlaybackEnded:(NSNotification *)note {
    if (!self.feedActive) return;
    ShortDramaPlayerSlot *current = self.playerPool[@(self.activeIndex)];
    if (!current || note.object != current.player.currentItem) return;
    NSInteger nextIdx = self.activeIndex + 1;
    if (nextIdx < (NSInteger)self.episodes.count) {
        [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:nextIdx inSection:0]
                                    atScrollPosition:UICollectionViewScrollPositionTop
                                            animated:YES];
        [self updateSlidingPoolAroundIndex:nextIdx];
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
        // M01：spinner 跟随槽位状态——解析中转，失败/已取消停（T17 再补失败卡片）。
        if (slot.state == ShortDramaSlotStateResolving) [cell.spinner startAnimating];
        else [cell.spinner stopAnimating];
    } else {
        [cell.spinner startAnimating];
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
