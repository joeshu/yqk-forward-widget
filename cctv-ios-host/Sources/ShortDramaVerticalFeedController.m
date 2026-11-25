#import "ShortDramaVerticalFeedController.h"
#import "HostGlassActionSheetViewController.h"
#import "HostTheme.h"
#import <AVFoundation/AVFoundation.h>

@interface ShortDramaPlayerSlot : NSObject
@property (nonatomic, assign) NSInteger episodeIndex;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, assign) BOOL resolving;
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

@interface ShortDramaVerticalFeedController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, copy) NSString *dramaTitle;
@property (nonatomic, copy) NSArray<NSDictionary *> *episodes;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, copy, nullable) void (^episodeResolver)(NSInteger index, void (^completion)(NSURL * _Nullable url, NSDictionary<NSString *, NSString *> * _Nullable headers));
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ShortDramaPlayerSlot *> *playerPool;
- (void)closeFeed;
- (void)showEpisodeDrawer;
- (void)updateSlidingPoolAroundIndex:(NSInteger)centerIndex;
- (void)prepareSlotForIndex:(NSInteger)index autoPlay:(BOOL)autoPlay;
- (void)handlePlaybackEnded:(NSNotification *)note;
@end

@implementation ShortDramaVerticalFeedController

- (instancetype)initWithTitle:(NSString *)dramaTitle
                     episodes:(NSArray<NSDictionary *> *)episodes
                 initialIndex:(NSInteger)initialIndex
               episodeResolver:(void (^)(NSInteger, void (^)(NSURL * _Nullable, NSDictionary<NSString *,NSString *> * _Nullable)))resolver {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _dramaTitle = [dramaTitle copy] ?: @"短剧";
        _episodes = [episodes copy] ?: @[];
        _activeIndex = MAX(0, MIN(initialIndex, (NSInteger)_episodes.count - 1));
        _episodeResolver = [resolver copy];
        _playerPool = [NSMutableDictionary dictionaryWithCapacity:3];
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
    if (self.episodes.count > 0 && self.activeIndex < (NSInteger)self.episodes.count) {
        [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:self.activeIndex inSection:0]
                                    atScrollPosition:UICollectionViewScrollPositionTop
                                            animated:NO];
        [self updateSlidingPoolAroundIndex:self.activeIndex];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        [slot.player pause];
        [slot.player replaceCurrentItemWithPlayerItem:nil];
    }
}

- (void)closeFeed {
    for (ShortDramaPlayerSlot *slot in self.playerPool.allValues) {
        [slot.player pause];
    }
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
            [evicted.player pause];
            [evicted.player replaceCurrentItemWithPlayerItem:nil];
            [evicted.playerLayer removeFromSuperlayer];
            [self.playerPool removeObjectForKey:key];
        } else if (key.integerValue != centerIndex) {
            [self.playerPool[key].player pause];
        }
    }
    [self prepareSlotForIndex:centerIndex autoPlay:YES];
    if (centerIndex + 1 < (NSInteger)self.episodes.count) [self prepareSlotForIndex:centerIndex + 1 autoPlay:NO];
    if (centerIndex - 1 >= 0) [self prepareSlotForIndex:centerIndex - 1 autoPlay:NO];
}

- (void)prepareSlotForIndex:(NSInteger)index autoPlay:(BOOL)autoPlay {
    if (index < 0 || index >= (NSInteger)self.episodes.count) return;
    ShortDramaPlayerSlot *existing = self.playerPool[@(index)];
    if (existing) {
        if (autoPlay) [existing.player play];
        ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
        if (cell) {
            [cell attachPlayerLayer:existing.playerLayer];
            [cell.spinner stopAnimating];
        }
        return;
    }

    ShortDramaPlayerSlot *slot = [ShortDramaPlayerSlot new];
    slot.episodeIndex = index;
    slot.player = [AVPlayer new];
    slot.playerLayer = [AVPlayerLayer playerLayerWithPlayer:slot.player];
    slot.resolving = YES;
    self.playerPool[@(index)] = slot;

    void (^applyURL)(NSURL *, NSDictionary<NSString *, NSString *> *) = ^(NSURL *url, NSDictionary<NSString *, NSString *> *headers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            slot.resolving = NO;
            if (!url || self.playerPool[@(index)] != slot) return;
            AVURLAsset *asset = headers.count ? [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}] : [AVURLAsset URLAssetWithURL:url options:nil];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            item.preferredForwardBufferDuration = (index == self.activeIndex) ? 10.0 : 4.0;
            [slot.player replaceCurrentItemWithPlayerItem:item];
            ShortDramaFeedCell *cell = (ShortDramaFeedCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0]];
            if (cell) {
                [cell attachPlayerLayer:slot.playerLayer];
                [cell.spinner stopAnimating];
            }
            if (index == self.activeIndex) [slot.player play];
        });
    };

    NSString *directURL = [self.episodes[(NSUInteger)index][@"url"] isKindOfClass:NSString.class] ? self.episodes[(NSUInteger)index][@"url"] : nil;
    if (directURL.length && [NSURL URLWithString:directURL]) {
        applyURL([NSURL URLWithString:directURL], nil);
    } else if (self.episodeResolver) {
        self.episodeResolver(index, applyURL);
    }
}

- (void)handlePlaybackEnded:(NSNotification *)note {
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
        if (slot.resolving) [cell.spinner startAnimating];
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
