#import "LocalMediaViewController.h"
#import "LocalMediaStore.h"
#import "MediaPlaybackViewController.h"
#import "HostGlassActionSheetViewController.h"
#import "HostTheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LocalMediaViewController () <UIDocumentPickerDelegate>
@property(nonatomic,strong) LocalMediaStore *store;
@property(nonatomic,copy) NSArray<NSURL *> *allFiles;
@property(nonatomic,copy) NSArray<NSURL *> *files;
@property(nonatomic,strong) NSMutableDictionary<NSURL *, NSNumber *> *fileSizesByURL;
@property(nonatomic,assign) NSInteger filterKind; // 0=all, 1=video, 2=audio
@property(nonatomic,assign) NSInteger sortMode;   // 0=name, 1=size desc
@property(nonatomic,strong) UIView *progressHeader;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UIView *summaryHeaderContainer;
@property(nonatomic,strong) UIView *summaryCard;
@property(nonatomic,strong) UILabel *summaryTitleLabel;
@property(nonatomic,strong) UILabel *summaryDetailLabel;
@property(nonatomic,strong) UIButton *summaryImportButton;
@property(nonatomic,strong) UIBarButtonItem *sortBarButton;
@property(nonatomic,strong) UILabel *emptyLabel;
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)s forRowAtIndexPath:(NSIndexPath *)ip;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path;
- (UIMenuElement *)deleteMenuForIndexPath:(NSIndexPath *)path;
- (void)confirmDeleteFileAtIndexPath:(NSIndexPath *)path;
- (void)updateFromStore;
- (void)updateProgressHeaderSize;
- (void)buildSummaryHeaderView;
- (void)applyFilterAndSort;
- (UIMenu *)buildSortFilterMenu;
- (NSString *)displayNameForURL:(NSURL *)url;
@property(nonatomic,assign) BOOL nextImportUsesZeroCopyBookmark;
- (void)presentDocumentPickerForBookmark:(BOOL)useBookmark;
- (void)importMedia;
- (void)stopImport;
- (void)refreshLocalMedia;
@end

@implementation LocalMediaViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (BOOL)isAudioURL:(NSURL *)url {
    NSString *ext=url.pathExtension.lowercaseString;
    return [ext isEqualToString:@"mp3"]||[ext isEqualToString:@"m4a"]||[ext isEqualToString:@"aac"]||[ext isEqualToString:@"flac"]||[ext isEqualToString:@"wav"];
}
- (void)buildSummaryHeaderView {
    CGFloat width=MAX(320.0,self.view.bounds.size.width>0?self.view.bounds.size.width:375.0);
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,80)];
    container.backgroundColor=UIColor.clearColor;
    UIView *card=[UIView new];
    card.translatesAutoresizingMaskIntoConstraints=NO;
    card.backgroundColor=HostCard();
    card.layer.cornerRadius=15;
    card.layer.cornerCurve=kCACornerCurveContinuous;
    card.layer.borderWidth=0.7;
    HostSetLayerBorderColor(card,HostBorder());
    card.accessibilityIdentifier=@"local.media.summary-card";
    [container addSubview:card];

    UILabel *title=[UILabel new];
    title.translatesAutoresizingMaskIntoConstraints=NO;
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    title.adjustsFontForContentSizeCategory=YES;
    title.textColor=HostText();
    [card addSubview:title];

    UILabel *detail=[UILabel new];
    detail.translatesAutoresizingMaskIntoConstraints=NO;
    detail.font=HostMonospacedDigitFont(12,UIFontWeightRegular,UIFontTextStyleCaption1);
    detail.adjustsFontForContentSizeCategory=YES;
    detail.textColor=HostSecondaryText();
    [card addSubview:detail];

    UIButton *btn=[UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints=NO;
    [btn setTitle:@"导入" forState:UIControlStateNormal];
    [btn setImage:[UIImage systemImageNamed:@"plus.circle.fill"] forState:UIControlStateNormal];
    btn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    btn.tintColor=HostAccent();
    btn.backgroundColor=HostSelectedSurface();
    btn.layer.cornerRadius=10;
    btn.layer.cornerCurve=kCACornerCurveContinuous;
    btn.contentEdgeInsets=UIEdgeInsetsMake(6,10,6,10);
    btn.accessibilityIdentifier=@"local.media.summary-import";
    btn.accessibilityLabel=@"导入本地媒体";
    btn.accessibilityHint=@"选择零拷贝外部挂载或复制到本机沙盒";
    btn.accessibilityTraits=UIAccessibilityTraitButton;
    HostInstallPressFeedback(btn);
    [btn addTarget:self action:@selector(importMedia) forControlEvents:UIControlEventTouchUpInside];
    [btn setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [card addSubview:btn];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:btn.leadingAnchor constant:-10],
        [detail.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],
        [detail.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [detail.trailingAnchor constraintLessThanOrEqualToAnchor:btn.leadingAnchor constant:-10],
        [detail.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11],
        [btn.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [btn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [btn.heightAnchor constraintGreaterThanOrEqualToConstant:32]
    ]];
    self.summaryHeaderContainer=container;
    self.summaryCard=card;
    self.summaryTitleLabel=title;
    self.summaryDetailLabel=detail;
    self.summaryImportButton=btn;
}
- (UIMenu *)buildSortFilterMenu {
    __weak typeof(self) w=self;
    UIAction *allF=[UIAction actionWithTitle:@"全部文件" image:[UIImage systemImageNamed:@"tray.full"] identifier:nil handler:^(__unused UIAction *a){w.filterKind=0;[w applyFilterAndSort];}];
    allF.state=(self.filterKind==0)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *vidF=[UIAction actionWithTitle:@"仅视频" image:[UIImage systemImageNamed:@"film.fill"] identifier:nil handler:^(__unused UIAction *a){w.filterKind=1;[w applyFilterAndSort];}];
    vidF.state=(self.filterKind==1)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *audF=[UIAction actionWithTitle:@"仅音频" image:[UIImage systemImageNamed:@"waveform.circle.fill"] identifier:nil handler:^(__unused UIAction *a){w.filterKind=2;[w applyFilterAndSort];}];
    audF.state=(self.filterKind==2)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIMenu *filterSection=[UIMenu menuWithTitle:@"" image:nil identifier:@"local.media.filter" options:UIMenuOptionsDisplayInline children:@[allF,vidF,audF]];
    UIAction *byName=[UIAction actionWithTitle:@"按名称排序" image:[UIImage systemImageNamed:@"textformat.abc"] identifier:nil handler:^(__unused UIAction *a){w.sortMode=0;[w applyFilterAndSort];}];
    byName.state=(self.sortMode==0)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *bySize=[UIAction actionWithTitle:@"按文件大小排序" image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(__unused UIAction *a){w.sortMode=1;[w applyFilterAndSort];}];
    bySize.state=(self.sortMode==1)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIMenu *sortSection=[UIMenu menuWithTitle:@"" image:nil identifier:@"local.media.sort.section" options:UIMenuOptionsDisplayInline children:@[byName,bySize]];
    return [UIMenu menuWithTitle:@"筛选与排序" children:@[filterSection,sortSection]];
}
- (void)applyFilterAndSort {
    NSMutableArray<NSURL *> *filtered=[NSMutableArray array];
    for(NSURL *url in self.allFiles?:@[]){
        BOOL audio=[self isAudioURL:url];
        if(self.filterKind==1&&audio)continue;
        if(self.filterKind==2&&!audio)continue;
        [filtered addObject:url];
    }
    if(self.sortMode==1){
        NSDictionary<NSURL *, NSNumber *> *sizes=self.fileSizesByURL?:@{};
        [filtered sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
            NSNumber *sa=sizes[a]?:@0,*sb=sizes[b]?:@0;
            return [sb compare:sa];
        }];
    }else{
        [filtered sortUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){
            return [[self displayNameForURL:a] localizedStandardCompare:[self displayNameForURL:b]];
        }];
    }
    self.files=filtered.copy;
    self.sortBarButton.menu=[self buildSortFilterMenu];
    [self.tableView reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.store=LocalMediaStore.shared;self.fileSizesByURL=[NSMutableDictionary dictionary];self.title=@"本地媒体";self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=72;self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;UIRefreshControl *localRefresh=[UIRefreshControl new];localRefresh.tintColor=HostAccent();localRefresh.accessibilityIdentifier=@"local.media.refreshControl";[localRefresh addTarget:self action:@selector(refreshLocalMedia) forControlEvents:UIControlEventValueChanged];self.refreshControl=localRefresh;
    UIBarButtonItem *addItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importMedia)];addItem.accessibilityLabel=@"导入本地媒体";addItem.accessibilityHint=@"选择并导入视频或音频文件";
    self.sortBarButton=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] menu:[self buildSortFilterMenu]];
    self.sortBarButton.accessibilityIdentifier=@"local.media.sort";
    self.sortBarButton.accessibilityLabel=@"筛选与排序本地媒体";
    self.navigationItem.rightBarButtonItems=@[addItem,self.sortBarButton];
    [self buildSummaryHeaderView];
    self.progressHeader=[UIView new];self.progressHeader.backgroundColor=HostCard();self.progressHeader.layer.cornerRadius=14;self.progressHeader.layer.cornerCurve=kCACornerCurveContinuous;self.progressHeader.layer.borderWidth=0.6;HostSetLayerBorderColor(self.progressHeader,HostBorder());self.progressLabel=[UILabel new];self.progressLabel.translatesAutoresizingMaskIntoConstraints=NO;self.progressLabel.numberOfLines=0;self.progressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.progressLabel.adjustsFontForContentSizeCategory=YES;self.progressLabel.textColor=HostText();
    self.stopButton=[UIButton buttonWithType:UIButtonTypeSystem];self.stopButton.translatesAutoresizingMaskIntoConstraints=NO;[self.stopButton setTitle:@"停止" forState:UIControlStateNormal];self.stopButton.accessibilityLabel=@"停止后续导入";self.stopButton.accessibilityHint=@"当前文件完成后结束导入任务";self.stopButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.stopButton.titleLabel.adjustsFontForContentSizeCategory=YES;[self.stopButton addTarget:self action:@selector(stopImport) forControlEvents:UIControlEventTouchUpInside];[self.progressHeader addSubview:self.progressLabel];[self.progressHeader addSubview:self.stopButton];[NSLayoutConstraint activateConstraints:@[[self.progressLabel.leadingAnchor constraintEqualToAnchor:self.progressHeader.leadingAnchor constant:14],[self.progressLabel.topAnchor constraintEqualToAnchor:self.progressHeader.topAnchor constant:10],[self.progressLabel.bottomAnchor constraintEqualToAnchor:self.progressHeader.bottomAnchor constant:-10],[self.progressLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.stopButton.leadingAnchor constant:-8],[self.stopButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],[self.stopButton.trailingAnchor constraintEqualToAnchor:self.progressHeader.trailingAnchor constant:-10],[self.stopButton.centerYAnchor constraintEqualToAnchor:self.progressHeader.centerYAnchor],[self.stopButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    self.emptyLabel=[UILabel new];self.emptyLabel.text=@"暂无本地媒体文件\n点右上角「+」导入视频或音频到本机播放";self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.emptyLabel.adjustsFontForContentSizeCategory=YES;self.tableView.backgroundView=self.emptyLabel;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange:) name:LocalMediaStoreDidChangeNotification object:self.store];[self updateFromStore];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self updateFromStore];}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if(self.tableView.tableHeaderView==self.progressHeader)[self updateProgressHeaderSize];
    else if(self.tableView.tableHeaderView==self.summaryHeaderContainer){
        HostSizeTableHeaderToFit(self.tableView, 80.0);
    }
}
- (void)updateProgressHeaderSize {CGFloat width=self.tableView.bounds.size.width;if(width<=0)return;CGRect frame=self.progressHeader.frame;frame.size.width=width;self.progressHeader.frame=frame;[self.progressHeader setNeedsLayout];[self.progressHeader layoutIfNeeded];CGSize fitting=[self.progressHeader systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];CGFloat height=MAX(62,fitting.height);if(fabs(self.progressHeader.frame.size.height-height)>0.5){frame.size.height=height;self.progressHeader.frame=frame;self.tableView.tableHeaderView=self.progressHeader;}}
- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.overrideUserInterfaceStyle=self.overrideUserInterfaceStyle;
    self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.refreshControl.tintColor=HostAccent();
    self.progressHeader.backgroundColor=HostCard();HostSetLayerBorderColor(self.progressHeader,HostBorder());self.progressLabel.textColor=HostText();
    self.summaryCard.backgroundColor=HostCard();HostSetLayerBorderColor(self.summaryCard,HostBorder());
    self.summaryTitleLabel.textColor=HostText();self.summaryDetailLabel.textColor=HostSecondaryText();
    self.summaryImportButton.tintColor=HostAccent();self.summaryImportButton.backgroundColor=HostSelectedSurface();
    self.emptyLabel.textColor=HostSecondaryText();[self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])[self reloadThemeAppearance];
}
- (void)refreshLocalMedia {
    [self updateFromStore];
    [self.refreshControl endRefreshing];
}
- (NSString *)displayNameForURL:(NSURL *)url {return [LocalMediaStore displayNameForFileURL:url];}
- (void)updateFromStore {
    NSMutableArray<NSURL *> *merged=[NSMutableArray arrayWithArray:[self.store filesSnapshot]?:@[]];
    for(NSURL *bm in [self.store mountedBookmarkURLsSnapshot]?:@[])if(![merged containsObject:bm])[merged addObject:bm];
    self.allFiles=merged.copy;NSDictionary *state=[self.store stateSnapshot];BOOL importing=[state[@"importing"] boolValue],stopping=[state[@"stopRequested"] boolValue];self.navigationItem.rightBarButtonItem.enabled=!importing;
    NSMutableDictionary<NSURL *, NSNumber *> *sizes=[NSMutableDictionary dictionaryWithCapacity:self.allFiles.count];
    long long totalBytes=0;NSUInteger videoCount=0,audioCount=0;
    for(NSURL *u in self.allFiles){
        NSNumber *sz=nil;[u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        NSNumber *safeSize=sz?:@0;sizes[u]=safeSize;totalBytes+=safeSize.longLongValue;
        if([self isAudioURL:u])audioCount++;else videoCount++;
    }
    self.fileSizesByURL=sizes;
    self.summaryTitleLabel.text=[NSString stringWithFormat:@"本机媒体库 · 共 %lu 项",(unsigned long)self.allFiles.count];
    self.summaryDetailLabel.text=[NSString stringWithFormat:@"视频 %lu · 音频 %lu · 占用 %@",(unsigned long)videoCount,(unsigned long)audioCount,[NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleFile]];
    if(importing){NSString *name=[state[@"currentFileName"] isKindOfClass:NSString.class]?state[@"currentFileName"]:@"";NSString *line=[NSString stringWithFormat:@"正在保存：%@\n已完成 %lu/%lu 个文件",name,(unsigned long)[state[@"completed"] unsignedIntegerValue],(unsigned long)[state[@"total"] unsignedIntegerValue]];self.progressLabel.text=line;self.stopButton.hidden=stopping;self.stopButton.enabled=!stopping;self.tableView.tableHeaderView=self.progressHeader;[self updateProgressHeaderSize];self.navigationItem.prompt=stopping?@"停止请求已收到 · 当前文件完成后结束":@"导入过程中仍可播放已完成文件";
    }else{
        self.tableView.tableHeaderView=self.allFiles.count?self.summaryHeaderContainer:nil;
        NSUInteger failed=[state[@"failureCount"] unsignedIntegerValue];
        NSUInteger duplicates=[state[@"duplicateCount"] unsignedIntegerValue];
        if(failed)self.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件未能保存；请重新选择",(unsigned long)failed];
        else if(duplicates)self.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个重复文件已跳过，未重复导入",(unsigned long)duplicates];
        else if(stopping)self.navigationItem.prompt=[NSString stringWithFormat:@"已停止后续导入 · 已完成 %lu/%lu 个文件",(unsigned long)[state[@"completed"] unsignedIntegerValue],(unsigned long)[state[@"total"] unsignedIntegerValue]];
        else self.navigationItem.prompt=self.allFiles.count?@"点击播放 · 长按分享 · 左滑删除":@"添加视频或音频；支持零拷贝挂载或本机副本";
    }
    [self applyFilterAndSort];
    self.emptyLabel.hidden=self.files.count>0||importing;self.tableView.backgroundView.hidden=self.emptyLabel.hidden;
}
- (void)storeDidChange:(NSNotification *)notification {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf storeDidChange:notification];});return;}[self updateFromStore];}
- (void)presentDocumentPickerForBookmark:(BOOL)useBookmark {
    self.nextImportUsesZeroCopyBookmark=useBookmark;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie,UTTypeAudio,UTTypeAudiovisualContent] asCopy:NO];picker.delegate=self;picker.allowsMultipleSelection=YES;[self presentViewController:picker animated:YES completion:nil];
}
- (void)importMedia {
    if([[self.store stateSnapshot][@"importing"] boolValue]){self.navigationItem.prompt=@"已有导入任务进行中";return;}
    __weak typeof(self) weakSelf=self;
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"添加本地媒体"
                                         subtitle:@"4K/大体积视频推荐选择零拷贝外部挂载，不占用双倍存储空间"
                                        badgeText:nil
                                       badgeColor:nil
                                         sections:@[[HostGlassSheetSection sectionWithTitle:nil actions:@[
                                             [HostGlassSheetAction actionWithTitle:@"零拷贝外部挂载（推荐）" subtitle:nil value:nil icon:@"externaldrive" tint:HostAccent() destructive:NO selected:NO handler:^{LocalMediaViewController *owner=weakSelf;if(!owner)return;[owner presentDocumentPickerForBookmark:YES];}],
                                             [HostGlassSheetAction actionWithTitle:@"复制到本机沙盒" subtitle:nil value:nil icon:@"square.and.arrow.down" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{LocalMediaViewController *owner=weakSelf;if(!owner)return;[owner presentDocumentPickerForBookmark:NO];}]
                                         ]]]
                                       sourceView:self.view];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count)return;__weak typeof(self) weakSelf=self;
    if(self.nextImportUsesZeroCopyBookmark){
        [self.store mountExternalURLs:urls completion:^(NSArray<NSURL *> *mounted,NSArray<NSDictionary<NSString *,NSString *> *> *failures){LocalMediaViewController *owner=weakSelf;if(!owner)return;[owner updateFromStore];if(failures.count)owner.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件挂载失败",(unsigned long)failures.count];else if(mounted.count)owner.navigationItem.prompt=[NSString stringWithFormat:@"已零拷贝挂载 %lu 个外部媒体",(unsigned long)mounted.count];}];
        return;
    }
    [self.store importURLs:urls completion:^(NSArray<NSURL *> *imported,NSArray<NSDictionary<NSString *,NSString *> *> *failures){LocalMediaViewController *owner=weakSelf;if(!owner)return;[owner updateFromStore];NSUInteger duplicates=[[owner.store stateSnapshot][@"duplicateCount"] unsignedIntegerValue];if(failures.count)owner.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件未能保存，请检查访问权限或可用空间",(unsigned long)failures.count];else if(duplicates)owner.navigationItem.prompt=[NSString stringWithFormat:@"已跳过 %lu 个重复文件 · 已保存 %lu 个本机副本",(unsigned long)duplicates,(unsigned long)imported.count];else if(imported.count)owner.navigationItem.prompt=[NSString stringWithFormat:@"已保存 %lu 个本机副本",(unsigned long)imported.count];}];[self updateFromStore];
}
- (void)stopImport {[self.store stopAfterCurrentFile];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.files.count;}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { (void)tableView;(void)section;HostStyleSectionHeaderView(view); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"local"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"local"];cell.transform=CGAffineTransformIdentity;if(path.row<0||path.row>=self.files.count)return cell;NSURL *url=self.files[path.row];NSString *name=[self displayNameForURL:url];NSNumber *size=self.fileSizesByURL[url];if(!size){[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];if(size)self.fileSizesByURL[url]=size;}BOOL isAudio=[self isAudioURL:url];NSString *kind=isAudio?@"音频文件":@"视频文件";NSString *ext=url.pathExtension.uppercaseString;if(!ext.length)ext=isAudio?@"AUDIO":@"VIDEO";
    cell.textLabel.text=name;cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",kind,[NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];cell.imageView.image=[UIImage systemImageNamed:isAudio?@"waveform.circle.fill":@"film.fill"];cell.imageView.tintColor=isAudio?UIColor.systemPurpleColor:HostAccent();cell.textLabel.numberOfLines=2;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.font=HostMonospacedDigitFont(12,UIFontWeightRegular,UIFontTextStyleCaption1);cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();
    UIView *accentBar=[cell.contentView viewWithTag:8801];
    if(!accentBar){accentBar=[[UIView alloc] initWithFrame:CGRectMake(2,10,3,MAX(0,CGRectGetHeight(cell.contentView.bounds)-20))];accentBar.tag=8801;accentBar.autoresizingMask=UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleRightMargin;accentBar.layer.cornerRadius=1.5;accentBar.userInteractionEnabled=NO;accentBar.accessibilityElementsHidden=YES;[cell.contentView addSubview:accentBar];}
    accentBar.frame=CGRectMake(2,10,3,MAX(0,CGRectGetHeight(cell.contentView.bounds)-20));
    accentBar.backgroundColor=isAudio?UIColor.systemPurpleColor:HostAccent();
    UILabel *extBadge=(UILabel *)cell.accessoryView;
    if(![extBadge isKindOfClass:UILabel.class]||extBadge.tag!=8802){extBadge=[UILabel new];extBadge.tag=8802;extBadge.font=HostMonospacedDigitFont(10,UIFontWeightBold,UIFontTextStyleCaption2);extBadge.textAlignment=NSTextAlignmentCenter;extBadge.layer.cornerRadius=7;extBadge.layer.cornerCurve=kCACornerCurveContinuous;extBadge.clipsToBounds=YES;extBadge.accessibilityElementsHidden=YES;extBadge.accessibilityIdentifier=@"local.media.ext-badge";cell.accessoryView=extBadge;}
    extBadge.text=[NSString stringWithFormat:@" %@ ",ext];
    extBadge.textColor=isAudio?UIColor.systemPurpleColor:HostAccent();
    extBadge.backgroundColor=isAudio?[UIColor.systemPurpleColor colorWithAlphaComponent:0.14]:HostSelectedSurface();
    [extBadge sizeToFit];
    CGRect bf=extBadge.frame;bf.size.width=MAX(42,bf.size.width+8);bf.size.height=MAX(22,bf.size.height+4);extBadge.frame=bf;
    cell.accessibilityTraits=UIAccessibilityTraitButton;cell.accessibilityHint=@"点按播放 · 长按分享、复制或删除";cell.accessibilityIdentifier=[@"local-media:" stringByAppendingString:url.lastPathComponent];return cell;
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell||UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformMakeScale(0.985,0.985);} completion:nil];
}
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell)return;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformIdentity;} completion:nil];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    (void)point;if(path.row<0||path.row>=(NSInteger)self.files.count)return nil;
    NSURL *url=self.files[(NSUInteger)path.row];NSString *name=[self displayNameForURL:url];__weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:path previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        UIAction *playAct=[UIAction actionWithTitle:@"播放此文件" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(__unused UIAction *a){[weakSelf tableView:tableView didSelectRowAtIndexPath:path];}];
        UIAction *shareAct=[UIAction actionWithTitle:@"分享或导出文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *a){
            LocalMediaViewController *owner=weakSelf;if(!owner)return;
            UIActivityViewController *av=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
            UITableViewCell *c=[tableView cellForRowAtIndexPath:path];av.popoverPresentationController.sourceView=c?:owner.view;av.popoverPresentationController.sourceRect=c?c.bounds:CGRectMake(CGRectGetMidX(owner.view.bounds),CGRectGetMidY(owner.view.bounds),1,1);
            [owner presentViewController:av animated:YES completion:nil];
        }];
        UIAction *copyName=[UIAction actionWithTitle:@"复制文件名称" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=name;}];
        UIMenu *primary=[UIMenu menuWithTitle:@"" image:nil identifier:@"local.media.ctx.primary" options:UIMenuOptionsDisplayInline children:@[playAct,shareAct,copyName]];
        UIMenuElement *delElement=[weakSelf deleteMenuForIndexPath:path];
        UIMenu *danger=[UIMenu menuWithTitle:@"" image:nil identifier:@"local.media.ctx.destructive" options:UIMenuOptionsDisplayInline children:delElement?@[delElement]:@[]];
        return [UIMenu menuWithTitle:name children:@[primary,danger]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.row<0||path.row>=self.files.count)return;NSURL *url=self.files[path.row];
    // T17：挂载文件被移动/删除后不进播放器，提示后由用户左滑移除挂载。
    NSNumber *regular=nil;[url.URLByStandardizingPath getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    if(!regular.boolValue){self.navigationItem.prompt=[self.store isCopiedFileURL:url]?@"该文件已不存在":@"该文件已移动或删除，可左滑移除挂载";return;}
    NSString *name=[self displayNameForURL:url];MediaPlaybackViewController *page=[MediaPlaybackViewController new];page.title=name;page.context=@{@"localMedia":@YES,@"source":@{@"id":@"local-media",@"name":@"本地媒体"},@"item":@{@"name":name,@"id":url.absoluteString},@"detail":@{@"name":name,@"id":url.absoluteString}};page.result=@{@"url":url.absoluteString,@"directMedia":@YES};[self.navigationController pushViewController:page animated:YES];
}
- (UIMenuElement *)deleteMenuForIndexPath:(NSIndexPath *)path {
    NSURL *url=(path.row>=0&&path.row<self.files.count)?self.files[(NSUInteger)path.row]:nil;
    BOOL copied=url?[self.store isCopiedFileURL:url]:YES;
    __weak typeof(self) weakSelf=self;
    UIAction *delAct=[UIAction actionWithTitle:copied?@"删除本机副本":@"移除挂载" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *a){[weakSelf confirmDeleteFileAtIndexPath:path];}];
    delAct.attributes=UIMenuElementAttributesDestructive;
    return delAct;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {if(style!=UITableViewCellEditingStyleDelete||path.row<0||path.row>=self.files.count)return;[self confirmDeleteFileAtIndexPath:path];}
/// T17：删除前确认并说明范围——副本只删沙盒内文件（Files 原文件不受影响），挂载只删书签。
- (void)confirmDeleteFileAtIndexPath:(NSIndexPath *)path {
    if(path.row<0||path.row>=self.files.count)return;NSURL *url=self.files[(NSUInteger)path.row];BOOL copied=[self.store isCopiedFileURL:url];__weak typeof(self) weakSelf=self;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:copied?@"删除本机副本？":@"移除挂载？" message:copied?@"仅删除 App 沙盒内的副本，Files 中的原文件不受影响。":@"仅移除本页的挂载记录，原文件不受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:copied?@"删除副本":@"移除挂载" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){
        LocalMediaViewController *owner=weakSelf;if(!owner)return;
        if(copied){[owner.store deleteFileAtURL:url completion:^(BOOL removed,NSError *error){LocalMediaViewController *o2=weakSelf;if(!o2)return;[o2 updateFromStore];if(!removed)o2.navigationItem.prompt=error.localizedDescription?:@"无法删除本机副本";}];}
        else{[owner.store removeBookmarkForURL:url completion:^(BOOL removed){LocalMediaViewController *o2=weakSelf;if(!o2)return;[o2 updateFromStore];if(!removed)o2.navigationItem.prompt=@"移除挂载失败";}];}
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
