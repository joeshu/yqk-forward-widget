#import "HostTheme.h"
#import "HostGlassActionSheetViewController.h"
#import "RootViewController_Internal.h"
#import "HostLibraryStore.h"
#import "MediaEpisodeLayout.h"
#import "MediaAdaptationMonitor.h"
#import "HostPerfMetrics.h"

void *const kAVItemStatusContext = (void *)&kAVItemStatusContext;
void *const kAVLayerFrameContext = (void *)&kAVLayerFrameContext;
NSCache<NSString *,UIImage *> *CCTVSharedChannelLogoCache(void) {
    static NSCache<NSString *,UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 100; });
    return cache;
}

@implementation CCTVPlaybackListPanelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.tableView=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.tableView.backgroundColor=HostBackground();
    self.tableView.dataSource=self;self.tableView.delegate=self;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=66;
    self.tableView.separatorColor=HostSeparator();
    self.emptyLabel=[UILabel new];self.emptyLabel.text=self.emptyMessage?:@"暂无可显示内容";self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    self.tableView.backgroundView=self.emptyLabel;
    [self.view addSubview:self.tableView];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=HostBackground();
    self.tableView.backgroundColor=HostBackground();
    self.tableView.separatorColor=HostSeparator();
    self.emptyLabel.textColor=HostSecondaryText();
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        HostRefreshAppearanceLayers(self.view.window);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse=@"cctv.playback.panel";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell){
        cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        cell.backgroundColor=HostCard();
        cell.textLabel.font=HostRoundedFont(15.5,UIFontWeightSemibold,UIFontTextStyleBody);
        cell.detailTextLabel.font=HostMonospacedDigitFont(12.0,UIFontWeightRegular,UIFontTextStyleCaption1);
        cell.textLabel.adjustsFontForContentSizeCategory=YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        cell.detailTextLabel.numberOfLines=3;
        cell.textLabel.textColor=HostText();
        cell.detailTextLabel.textColor=HostSecondaryText();
    }
    cell.transform=CGAffineTransformIdentity;
    NSDictionary *item=self.items[indexPath.row];BOOL selected=[item[@"selected"] boolValue];
    cell.backgroundColor=selected?HostSelectedSurface():HostCard();
    cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;
    cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());

    UIView *specular=[cell.contentView viewWithTag:8901];
    if(!specular){
        specular=[[UIView alloc] initWithFrame:CGRectMake(12,0,MAX(0,CGRectGetWidth(cell.contentView.bounds)-24),0.5)];specular.tag=8901;specular.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleBottomMargin;specular.userInteractionEnabled=NO;
        [cell.contentView addSubview:specular];
    }
    specular.frame=CGRectMake(12,0,MAX(0,CGRectGetWidth(cell.contentView.bounds)-24),0.5);
    specular.backgroundColor=HostIsDarkThemeSelected()?[UIColor colorWithWhite:1.0 alpha:selected?0.16:0.07]:[selected?HostAccent():HostBorder() colorWithAlphaComponent:selected?0.28:0.65];

    UIView *accentBar=[cell.contentView viewWithTag:8902];
    if(!accentBar){
        accentBar=[[UIView alloc] initWithFrame:CGRectMake(4,floor((CGRectGetHeight(cell.contentView.bounds)-24.0)*0.5),3.5,24.0)];accentBar.tag=8902;accentBar.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleRightMargin;accentBar.layer.cornerRadius=1.75;accentBar.layer.cornerCurve=kCACornerCurveContinuous;accentBar.userInteractionEnabled=NO;
        [cell.contentView addSubview:accentBar];
    }
    accentBar.frame=CGRectMake(4,floor((CGRectGetHeight(cell.contentView.bounds)-24.0)*0.5),3.5,24.0);
    accentBar.backgroundColor=selected?HostAccent():UIColor.clearColor;

    cell.textLabel.text=item[@"title"]?:@"";
    NSString *detailStr=[item[@"detail"] isKindOfClass:NSString.class]?item[@"detail"]:@"";
    cell.detailTextLabel.attributedText=nil;
    if(detailStr.length){
        NSMutableParagraphStyle *para=[NSMutableParagraphStyle new];para.lineSpacing=2.4;
        NSMutableAttributedString *attr=[[NSMutableAttributedString alloc] initWithString:detailStr attributes:@{NSFontAttributeName:cell.detailTextLabel.font,NSForegroundColorAttributeName:HostSecondaryText(),NSParagraphStyleAttributeName:para}];
        NSRange nl=[detailStr rangeOfString:@"\n"];
        if(nl.location!=NSNotFound){
            [attr addAttribute:NSForegroundColorAttributeName value:[HostText() colorWithAlphaComponent:0.84] range:NSMakeRange(0,nl.location)];
            [attr addAttribute:NSForegroundColorAttributeName value:HostMutedText() range:NSMakeRange(nl.location+1,detailStr.length-nl.location-1)];
        }
        cell.detailTextLabel.attributedText=attr;
    }else{
        cell.detailTextLabel.text=@"";
    }
    cell.textLabel.textColor=selected?HostAccent():HostText();
    cell.tintColor=HostAccent();cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    NSString *symbol=item[@"symbol"];
    cell.imageView.image=symbol.length?[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:selected?UIImageSymbolWeightSemibold:UIImageSymbolWeightRegular]]:nil;
    cell.imageView.tintColor=selected?HostAccent():[HostAccent() colorWithAlphaComponent:0.82];

    NSString *badgeText=[item[@"badge"] isKindOfClass:NSString.class]?item[@"badge"]:@"";
    if(badgeText.length){
        UILabel *badge=[UILabel new];
        badge.text=[NSString stringWithFormat:@"  %@  ",badgeText];
        badge.font=HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);
        badge.textAlignment=NSTextAlignmentCenter;
        badge.textColor=selected?HostAccent():HostSecondaryText();
        badge.backgroundColor=selected?HostSelectedSurface():HostRaisedSurface();
        badge.layer.cornerRadius=7;badge.layer.cornerCurve=kCACornerCurveContinuous;
        badge.layer.borderWidth=0.55;HostSetLayerBorderColor(badge,selected?[HostAccent() colorWithAlphaComponent:0.38]:HostBorder());
        badge.clipsToBounds=YES;
        badge.accessibilityIdentifier=@"cctv.panel.badge";
        [badge sizeToFit];
        badge.frame=CGRectMake(0,0,MAX(44,ceil(badge.bounds.size.width)+4),22);
        cell.accessoryView=badge;
        cell.accessoryType=UITableViewCellAccessoryNone;
    }else{
        cell.accessoryView=nil;
        cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath { UITableViewCell *c=[tableView cellForRowAtIndexPath:indexPath]; if(!c||UIAccessibilityIsReduceMotionEnabled())return; [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformMakeScale(0.982,0.982);} completion:nil]; }
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath { UITableViewCell *c=[tableView cellForRowAtIndexPath:indexPath]; if(!c)return; [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformIdentity;} completion:nil]; }
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if(indexPath.row<0||indexPath.row>=(NSInteger)self.items.count)return nil;
    NSDictionary *item=self.items[indexPath.row];
    NSString *title=item[@"title"]?:@"选项",*detail=item[@"detail"]?:@"";
    __weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:@"cctv.playback.panel.context" previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        UIAction *select=[UIAction actionWithTitle:@"切换至此项" image:[UIImage systemImageNamed:item[@"symbol"]?:@"checkmark.circle"] identifier:nil handler:^(__unused UIAction *a){if(weakSelf.selectionHandler)weakSelf.selectionHandler(item);}];
        UIAction *copy=[UIAction actionWithTitle:@"复制名称与详情" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=detail.length?[NSString stringWithFormat:@"%@ · %@",title,detail]:title;}];
        return [UIMenu menuWithTitle:title children:@[select,copy]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.row>=self.items.count)return;
    if(self.selectionHandler)self.selectionHandler(self.items[indexPath.row]);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.emptyLabel.frame=CGRectInset(self.tableView.bounds,32,32);self.emptyLabel.hidden=self.items.count>0;
}
@end

@implementation CCTVChannelListCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.previewThumbView = [UIImageView new];
        self.previewThumbView.tag = 4201;
        self.previewThumbView.contentMode = UIViewContentModeScaleAspectFill;
        self.previewThumbView.clipsToBounds = YES;
        self.previewThumbView.layer.cornerRadius = 6;
        self.previewThumbView.layer.cornerCurve = kCACornerCurveContinuous;
        self.previewThumbView.layer.borderWidth = 0.5;
        HostSetLayerBorderColor(self.previewThumbView, HostBorder());
        self.previewThumbView.hidden = YES;
        self.previewThumbView.accessibilityIdentifier = @"channel.list.preview";
        [self.contentView addSubview:self.previewThumbView];

        self.telemetryBadgeLabel = [UILabel new];
        self.telemetryBadgeLabel.tag = 4202;
        self.telemetryBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightSemibold];
        self.telemetryBadgeLabel.textAlignment = NSTextAlignmentCenter;
        self.telemetryBadgeLabel.layer.cornerRadius = 5;
        self.telemetryBadgeLabel.layer.cornerCurve = kCACornerCurveContinuous;
        self.telemetryBadgeLabel.clipsToBounds = YES;
        self.telemetryBadgeLabel.hidden = YES;
        self.telemetryBadgeLabel.accessibilityIdentifier = @"channel.list.telemetry";
        [self.contentView addSubview:self.telemetryBadgeLabel];
    }
    return self;
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    if(UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:highlighted?0.10:0.24 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform=highlighted?CGAffineTransformMakeScale(0.982,0.982):CGAffineTransformIdentity;
    } completion:nil];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width=CGRectGetWidth(self.contentView.bounds),height=CGRectGetHeight(self.contentView.bounds);
    self.imageView.contentMode=UIViewContentModeScaleAspectFit;
    self.imageView.frame=CGRectMake(12,MAX(4,(height-36)/2),56,36);
    CGFloat titleHeight=MIN(height,ceil(self.textLabel.font.lineHeight)),detailHeight=MIN(MAX(0,height-titleHeight-4),ceil(self.detailTextLabel.font.lineHeight*MAX(1,self.detailTextLabel.numberOfLines)));
    CGFloat blockHeight=titleHeight+3+detailHeight,top=MAX(4,floor((height-blockHeight)/2));
    CGFloat textX=self.imageView.hidden?16:80,accessorySpace=self.accessoryView?44:(self.accessoryType==UITableViewCellAccessoryDisclosureIndicator?30:12);
    CGFloat rightExtra=0;
    if(!self.previewThumbView.hidden){
        self.previewThumbView.frame=CGRectMake(MAX(textX+60,width-accessorySpace-54),MAX(4,floor((height-30)/2)),48,30);
        rightExtra+=54;
    }
    CGFloat textWidth=MAX(0,width-textX-accessorySpace-rightExtra),badgeWidth=0,badgeX=0;
    if(!self.telemetryBadgeLabel.hidden&&self.telemetryBadgeLabel.text.length){
        CGSize fit=[self.telemetryBadgeLabel sizeThatFits:CGSizeMake(130,16)];
        badgeWidth=MIN(126,MAX(44,ceil(fit.width)+8));badgeX=MAX(textX+40,width-accessorySpace-rightExtra-badgeWidth-4);
        textWidth=MIN(textWidth,MAX(0,badgeX-textX-4));self.telemetryBadgeLabel.frame=CGRectMake(badgeX,top,badgeWidth,MIN(16,titleHeight));
    }
    self.textLabel.frame=CGRectMake(textX,top,textWidth,titleHeight);
    self.detailTextLabel.frame=CGRectMake(textX,top+titleHeight+3,MAX(0,width-textX-accessorySpace-rightExtra),detailHeight);
}
@end


@implementation RootViewController
// 第三方 SDK 播放器（CNPlayer / Cicada 私有类）与 AVFoundation KVO 的统一异常边界（私有类可能不支持某 key、init 抛异常，或观察者已被 SDK 内部移除）。
- (BOOL)guardedSetValue:(id)value forKey:(NSString *)key onObject:(id)target {if(!target||!key.length)return NO;@try{[target setValue:value forKey:key];return YES;}@catch(NSException *e){[self log:@"设置播放器属性 %@ 异常 %@",key,e.reason];return NO;}}
- (id)guardedValueForKey:(NSString *)key ofObject:(id)target {if(!target||!key.length)return nil;@try{return [target valueForKey:key];}@catch(NSException *e){[self log:@"读取播放器属性 %@ 异常 %@",key,e.reason];return nil;}}
- (id)guardedNewInstanceOfClass:(Class)cls {if(!cls)return nil;@try{return [[cls alloc] init];}@catch(NSException *e){[self log:@"创建播放器异常 %@",e.reason];return nil;}}
- (void)guardedRemoveObserverFrom:(NSObject *)object keyPath:(NSString *)keyPath context:(void *)context {if(!object||!keyPath.length)return;@try{[object removeObserver:self forKeyPath:keyPath context:context];}@catch(NSException *e){[self log:@"移除观察者 %@ 异常 %@",keyPath,e.reason];}}
- (BOOL)sessionHasContent {return self.currentPlayer||self.avPlayer||self.remoteAdapter||self.moviePlayer||self.playbackReadiness||(self.channelID.length&&(self.livePlaybackSuspendedForNavigation||self.remotePlaybackFailed||self.nativePlaybackFailed));}
- (BOOL)sessionWantsPlayback {if(self.livePlaybackSuspendedForNavigation)return NO;if(self.avPlayer||self.remoteAdapter)return self.remotePlaybackWanted;return [self sessionIsPlaying]||(self.currentPlayer&&!self.firstRender&&!self.nativePlaybackFailed);}
- (BOOL)sessionIsPlaying {
    if(self.livePlaybackSuspendedForNavigation)return NO;
    if(self.remoteAdapter)return self.remoteAdapter.state==MediaPlaybackCicadaAdapterStatePlaying;
    if(self.moviePlayer)return self.moviePlayer.rate>0;
    if(self.avPlayer)return self.remotePlaybackWanted;
    return [[self guardedValueForKey:@"isPlaying" ofObject:self.currentPlayer] boolValue];
}
- (void)sessionPlay {if(self.remoteAdapter.state==MediaPlaybackCicadaAdapterStateCompleted){[self playRemote:@{@"remoteURL":self.currentRemoteURL?:@"",@"id":self.channelID?:@"",@"name":self.channelName?:@"直播",@"headers":self.currentRemoteHeaders?:@{}}];return;}if(self.remoteAdapter){self.remotePlaybackWanted=YES;[self.remoteAdapter start];}else if(![self sessionIsPlaying])[self togglePlayPause];[self updateNowPlaying];}
- (void)sessionPause {
    self.remoteProgressSampleTime=0;self.remoteProgressLastAdvanceTime=0;
    self.remotePlaybackWanted=NO;[self.remoteAdapter pause];[self.moviePlayer pause];[self.avPlayer pause];[self call:self.currentPlayer sel:@"pause"];
    [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];[self updateNowPlaying];
}
- (BOOL)sessionStep:(NSInteger)direction {if(self.livePlaybackSuspendedForNavigation||!self.channelID.length)return NO;[self playAdjacentChannel:direction];return YES;}
- (void)sessionMediaServicesReset {[self suspendLivePlaybackForReason:@"audio_services_reset"];}


- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    [MediaPackageImporter migrateLegacyRuntimeMetadata];
    self.view.backgroundColor = HostBackground();
    self.title = @"CCTV";
    self.navigationController.delegate=self;
    [self applyFontSizeOverride];
    HostStyleNavigation(self.navigationController);
    self.view.tintColor=HostAccent();
    NSUserDefaults *preferences=NSUserDefaults.standardUserDefaults;
    if(![preferences boolForKey:@"cctv.manualStartupLoadingMigration.v1"]){[preferences setBool:NO forKey:@"resumeLastChannel"];[preferences setBool:YES forKey:@"cctv.manualStartupLoadingMigration.v1"];}
    // 启动恢复可由设置页关闭：关闭后每次打开都从央视直播开始。
    BOOL restoreLastTab=CCTVBoolPreference(@"cctv.restoreLastTab.v1",YES);
    id savedTab=restoreLastTab?[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.lastBottomTab.v1"]:nil;
    if([savedTab respondsToSelector:@selector(integerValue)]&&[savedTab integerValue]>=0&&[savedTab integerValue]<=4){self.activeTab=[savedTab integerValue];self.initialTabRestorePending=self.activeTab!=0;}
    self.gridMode = [[NSUserDefaults standardUserDefaults] objectForKey:@"channelGridMode"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"channelGridMode"] : YES;
    self.channelSortMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.channelSortMode.v1"];
    id savedGridColumns=[preferences objectForKey:@"cctv.channelGridColumns.v1"];
    NSInteger gridColumns=[savedGridColumns respondsToSelector:@selector(integerValue)]?[savedGridColumns integerValue]:4;
    self.gridColumns=gridColumns==3?3:4;
    self.logBuffer = [NSMutableString string];
    self.diagnosticLogQueue = dispatch_queue_create("com.cctvhost.diagnostic-log", DISPATCH_QUEUE_SERIAL);
    self.pendingLogWrites = [[HostLogBuffer alloc] initWithMaximumCharacters:65536];
    self.pendingLogDisplay = [[HostLogBuffer alloc] initWithMaximumCharacters:16000];
    NSString *supportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    self.diagnosticLogPath = [[supportDir stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"cctvhost.log"];
    [self restoreDiagnosticLog];
    self.retryCount = 0;

    self.epgDiskQueue=dispatch_queue_create("com.cctvhost.epg-disk",DISPATCH_QUEUE_SERIAL);
    self.epgListTasks=[NSMutableDictionary dictionary];
    self.subscriptionReadiness=[NSMutableDictionary dictionary];
    self.readyLocalOrigins=[NSMutableDictionary dictionary];
    self.deferredLocalSubscriptions=[NSMutableSet set];
    self.subscriptionTasks=[NSMutableDictionary dictionary];self.subscriptionTraceIDs=[NSMutableDictionary dictionary];self.remoteAttemptedURLs=[NSMutableSet set];self.catalogStates=[NSMutableDictionary dictionary];for(NSInteger tab=0;tab<2;tab++){NSDictionary *savedState=[[NSUserDefaults standardUserDefaults] dictionaryForKey:[NSString stringWithFormat:@"cctv.catalogState.%ld",(long)tab]];if(savedState)self.catalogStates[@(tab)]=savedState;}self.tabPages=[NSMutableDictionary dictionary];
    [self loadChannels];
    [self buildPlayer];
    [self buildList];
    [self configureCatalogNavigation];
    [self applyFilter];
    [self activateAudioSession];
    [self setupRemoteCommands];
    [self registerCallbackProtocol];
    [self setupSDK];
    [self log:@"日志持久化已启用（按需批量保存）"];
    // 插件会话恢复、EPG 磁盘缓存、内置资源注册改到首屏后执行：见 RootViewController+EPG.m schedulePostFirstScreenStartupTasks。
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkVisibleMediaAfterActivation) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadThemeAppearance) name:@"HostThemeDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cctv.nativeFallbackSiteKeys.v1"];
}

- (void)installBundledMediaResourcesIfNeeded {
    NSUserDefaults *preferences=NSUserDefaults.standardUserDefaults;NSString *seedKey=@"cctv.bundledMediaResources.v5";
    if(self.bundledMediaSeedInProgress)return;
    BOOL alreadySeeded=[preferences boolForKey:seedKey];
    self.bundledMediaSeedInProgress=YES;
    NSArray *catalogSpecs=@[
        @{@"file":@"lytvs-ios",@"id":@"builtin-lytvs-ios",@"name":@"Hawk iOS 内部影视与 PY 聚合",@"kind":@"tvbox",@"url":@"https://sub.lytvs.top/get?token=__LYTVS_SUBSCRIPTION_TOKEN__&client=ios"},
        @{@"file":@"for-adm",@"id":@"builtin-for-adm",@"name":@"For-ADM CCTVHost 影视资源合集",@"kind":@"tvbox",@"url":@"https://raw.githubusercontent.com/joeshu/For-ADM/data/CCTVHost/For-ADM.json"}
    ];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        BOOL complete=YES,changed=NO;
        for(NSDictionary *service in [ServiceStore services]){if([service[@"bundledResourceID"] isEqual:@"zen.keke.rex.stream"]){[ServiceStore remove:service[@"id"]];changed=YES;}}
        NSDictionary *storedForADM=[TVBoxCatalogStore catalogForID:@"builtin-for-adm"];NSString *storedForADMURL=[storedForADM[@"url"] isKindOfClass:NSString.class]?storedForADM[@"url"]:@"";
        if([storedForADMURL isEqual:@"https://raw.githubusercontent.com/joeshu/For-ADM/master/CCTVHost/For-ADM.json"]){NSMutableDictionary *migrated=[storedForADM mutableCopy];migrated[@"url"]=@"https://raw.githubusercontent.com/joeshu/For-ADM/data/CCTVHost/For-ADM.json";[TVBoxCatalogStore saveCatalog:migrated];changed=YES;}
        if(!alreadySeeded){
            for(NSString *retiredID in @[@"builtin-haoliang-live",@"builtin-haoliang-py",@"builtin-haoliang-tvbox"]){if([TVBoxCatalogStore catalogForID:retiredID]){[TVBoxCatalogStore removeCatalog:retiredID];changed=YES;}}
            for(NSDictionary *spec in catalogSpecs){
                NSString *identifier=spec[@"id"];if([TVBoxCatalogStore catalogForID:identifier])continue;
                NSString *catalogURL=[spec[@"url"] isKindOfClass:NSString.class]?spec[@"url"]:@"";BOOL alreadyImported=NO;
                if(catalogURL.length){NSURLComponents *expected=[NSURLComponents componentsWithString:catalogURL];for(NSDictionary *existing in [TVBoxCatalogStore catalogs]){NSString *existingURL=[existing[@"url"] isKindOfClass:NSString.class]?existing[@"url"]:@"";NSURLComponents *actual=[NSURLComponents componentsWithString:existingURL];BOOL sameLocation=expected.host.length&&[actual.host.lowercaseString isEqual:expected.host.lowercaseString]&&[actual.path isEqual:expected.path];BOOL sameForADM=[identifier isEqual:@"builtin-for-adm"]&&[existing[@"name"] isEqual:spec[@"name"]];if(sameLocation||sameForADM){alreadyImported=YES;break;}}}
                if(alreadyImported)continue;
                NSString *path=[NSBundle.mainBundle pathForResource:spec[@"file"] ofType:@"json" inDirectory:@"BuiltinMedia"];NSData *data=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL]:nil;NSError *error=nil;NSDictionary *parsed=data?[TVBoxCatalogStore parseData:data sourceURL:nil error:&error]:nil;
                if(!parsed){complete=NO;[RuntimeDiagnostics.shared recordEvent:@"bundled_media_catalog_import_failed" category:@"resource_import" fields:@{@"resource_id":identifier?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@"bundle resource missing or invalid"}];continue;}
                NSMutableDictionary *catalog=[parsed mutableCopy];catalog[@"id"]=identifier;catalog[@"name"]=spec[@"name"];catalog[@"catalogKind"]=spec[@"kind"];catalog[@"bundledResourceID"]=identifier;if(catalogURL.length)catalog[@"url"]=catalogURL;[TVBoxCatalogStore saveCatalog:catalog];changed=YES;
            }

        }
        NSArray *scriptSpecs=@[
            @{@"file":@"hongguo-python",@"extension":@"py",@"runtime":@"python",@"id":@"builtin-hongguo-python",@"name":@"红果短剧 Python 版"},
            @{@"file":@"hongguo-node",@"extension":@"js",@"runtime":@"node",@"id":@"builtin-hongguo-node",@"name":@"红果短剧 JS 版"},
            @{@"file":@"dsx-python",@"extension":@"py",@"runtime":@"python",@"id":@"builtin-dsx-python",@"name":@"大师兄 Python 版"},
            @{@"file":@"dsx-drpy",@"extension":@"js",@"runtime":@"",@"id":@"builtin-dsx-drpy",@"name":@"大师兄 JS 版"}
        ];
        NSArray *capabilities=@[@"home",@"category",@"search",@"detail",@"play",@"proxy"];
        for(NSDictionary *spec in scriptSpecs){
            NSString *identifier=spec[@"id"];NSDictionary *existingService=nil;
            for(NSDictionary *service in [ServiceStore services])if([service[@"bundledResourceID"] isEqual:identifier]){existingService=service;break;}
            NSString *path=[NSBundle.mainBundle pathForResource:spec[@"file"] ofType:spec[@"extension"] inDirectory:@"BuiltinMedia"];
            if(existingService){
                NSString *installedPath=[ServiceStore codePath:existingService];
                NSData *bundleData=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL]:nil;
                NSData *installedData=installedPath.length?[NSData dataWithContentsOfFile:installedPath options:NSDataReadingMappedIfSafe error:NULL]:nil;
                BOOL codeUpdated=NO;
                if(bundleData.length&&installedPath.length&&![installedData isEqualToData:bundleData]){
                    [NSFileManager.defaultManager createDirectoryAtPath:installedPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
                    codeUpdated=[bundleData writeToFile:installedPath options:NSDataWritingAtomic error:NULL];
                }
                NSDictionary *manifest=[existingService[@"manifest"] isKindOfClass:NSDictionary.class]?existingService[@"manifest"]:@{};
                NSDictionary *opts=[manifest[@"options"] isKindOfClass:NSDictionary.class]?manifest[@"options"]:@{};
                BOOL metaNeedsUpdate=![existingService[@"capabilities"] isEqual:capabilities]||![manifest[@"capabilities"] isEqual:capabilities]||[opts[@"playTimeoutMs"] integerValue]<120000;
                if(codeUpdated||metaNeedsUpdate){
                    NSMutableDictionary *service=[existingService mutableCopy],*updatedManifest=[manifest mutableCopy]?:[NSMutableDictionary dictionary];
                    NSMutableDictionary *options=[opts mutableCopy]?:[NSMutableDictionary dictionary];options[@"playTimeoutMs"]=@120000;
                    service[@"capabilities"]=capabilities;updatedManifest[@"capabilities"]=capabilities;updatedManifest[@"options"]=options;
                    if(codeUpdated)service[@"updated"]=@(NSDate.date.timeIntervalSince1970);
                    service[@"manifest"]=updatedManifest;[ServiceStore save:service];changed=YES;
                }
                continue;
            }
            if(alreadySeeded)continue;
            NSError *error=nil;NSDictionary *imported=path?[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] companionFiles:@{} runtimeHint:spec[@"runtime"] error:&error]:nil;
            if(!imported){complete=NO;[RuntimeDiagnostics.shared recordEvent:@"bundled_media_script_import_failed" category:@"resource_import" fields:@{@"resource_id":identifier,@"error_code":@(error.code),@"error_message":error.localizedDescription?:@"bundle resource missing or invalid"}];continue;}
            NSMutableDictionary *service=[imported mutableCopy],*manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSMutableDictionary *options=[manifest[@"options"] mutableCopy]?:[NSMutableDictionary dictionary];options[@"playTimeoutMs"]=@120000;
            service[@"name"]=spec[@"name"];service[@"bundledResourceID"]=identifier;service[@"capabilities"]=capabilities;manifest[@"name"]=spec[@"name"];manifest[@"capabilities"]=capabilities;manifest[@"options"]=options;service[@"manifest"]=manifest;[ServiceStore save:service];changed=YES;
        }
        if(complete&&!alreadySeeded)[preferences setBool:YES forKey:seedKey];
        NSString *weboxSeedKey=@"cctv.bundledWeBoxResources.v1";
        BOOL weboxAlreadySeeded=[preferences boolForKey:weboxSeedKey];
        if(!weboxAlreadySeeded){
            BOOL weboxComplete=YES;
            NSString *weboxCatalogID=@"builtin-webox-index";
            NSString *weboxCatalogURL=@"https://ddgksf2013.top/webox/index.json";
            if(![TVBoxCatalogStore catalogForID:weboxCatalogID]){
                NSString *wPath=[NSBundle.mainBundle pathForResource:@"webox-index" ofType:@"json" inDirectory:@"BuiltinMedia"];
                NSData *wData=wPath?[NSData dataWithContentsOfFile:wPath options:NSDataReadingMappedIfSafe error:NULL]:nil;
                NSError *wErr=nil;NSDictionary *wParsed=wData?[TVBoxCatalogStore parseData:wData sourceURL:weboxCatalogURL error:&wErr]:nil;
                if(wParsed){
                    NSMutableDictionary *wCat=[wParsed mutableCopy];wCat[@"id"]=weboxCatalogID;wCat[@"name"]=@"WeBox 影视源合集";wCat[@"catalogKind"]=@"tvbox";wCat[@"bundledResourceID"]=weboxCatalogID;wCat[@"url"]=weboxCatalogURL;
                    [TVBoxCatalogStore saveCatalog:wCat];changed=YES;
                }else weboxComplete=NO;
            }
            NSArray *weboxSpecs=@[
                @{@"file":@"webox-4kvm",@"id":@"builtin-webox-4kvm",@"name":@"4k影视",@"url":@"https://ddgksf2013.top/webox/4k%E5%BD%B1%E8%A7%86.webox.js",@"siteKey":@"webox-4kvm"},
                @{@"file":@"webox-hstream",@"id":@"builtin-webox-hstream",@"name":@"HStream",@"url":@"https://ddgksf2013.top/webox/HStream.webox.js",@"siteKey":@"webox-hstream"},
                @{@"file":@"webox-guazi",@"id":@"builtin-webox-guazi",@"name":@"瓜子",@"url":@"https://ddgksf2013.top/webox/%E7%93%9C%E5%AD%90.webox.js",@"siteKey":@"webox-guazi"},
                @{@"file":@"webox-rou",@"id":@"builtin-webox-rou",@"name":@"肉視頻",@"url":@"https://ddgksf2013.top/webox/%E8%82%89.webox.js",@"siteKey":@"webox-rou"},
                @{@"file":@"webox-one",@"id":@"builtin-webox-one",@"name":@"ONE · 一个",@"url":@"https://ddgksf2013.top/webox/one%E4%B8%80%E4%B8%AA.webox.js",@"siteKey":@"webox-one"}
            ];
            NSArray *weboxCaps=@[@"home",@"category",@"search",@"detail",@"play"];
            for(NSDictionary *wSpec in weboxSpecs){
                NSString *wID=wSpec[@"id"];BOOL wFound=NO;
                for(NSDictionary *svc in [ServiceStore services])if([svc[@"bundledResourceID"] isEqual:wID]||[svc[@"url"] isEqual:wSpec[@"url"]]){wFound=YES;break;}
                if(wFound)continue;
                NSString *wScriptPath=[NSBundle.mainBundle pathForResource:wSpec[@"file"] ofType:@"js" inDirectory:@"BuiltinMedia"];
                NSError *wImportErr=nil;NSDictionary *wImported=wScriptPath?[MediaPackageImporter importFile:[NSURL fileURLWithPath:wScriptPath] error:&wImportErr]:nil;
                if(!wImported){weboxComplete=NO;continue;}
                NSMutableDictionary *wService=[wImported mutableCopy],*wManifest=[wService[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];
                wService[@"name"]=wSpec[@"name"];wService[@"bundledResourceID"]=wID;wService[@"url"]=wSpec[@"url"];wService[@"capabilities"]=weboxCaps;
                wService[@"tvboxSiteKey"]=wSpec[@"siteKey"];wService[@"tvboxSiteKeys"]=@[wSpec[@"siteKey"]];
                wManifest[@"name"]=wSpec[@"name"];wManifest[@"capabilities"]=weboxCaps;wManifest[@"options"]=@{@"playTimeoutMs":@45000};
                wService[@"manifest"]=wManifest;[ServiceStore save:wService];changed=YES;
            }
            if(weboxComplete)[preferences setBool:YES forKey:weboxSeedKey];
        }
        dispatch_async(dispatch_get_main_queue(),^{self.bundledMediaSeedInProgress=NO;if(changed){[self refreshConfigurationPage];MediaBrowserViewController *browser=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;[browser refreshSources];}if(!complete)[self log:@"内置影视资源注册未完成；下次启动会继续检查缺少的资源"];
        });
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(self.navigationController.delegate!=self)self.navigationController.delegate=self;
    if([HostPerfMetrics.shared markFirstScreenInteractive:NSStringFromClass(self.class)])[self schedulePostFirstScreenStartupTasks];
    if(!self.initialTabRestorePending)return;
    self.initialTabRestorePending=NO;
    NSInteger savedTab=self.activeTab;
    if(savedTab<0||savedTab>=self.bottomBar.arrangedSubviews.count)return;
    self.restoringLastTab=YES;
    [self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews[savedTab]];
    self.restoringLastTab=NO;
}

- (BOOL)shouldHideNavigationBarForVisibleController:(UIViewController *)visibleController {
    if([visibleController isKindOfClass:NSClassFromString(@"MediaEpisodeSelectionViewController")])return YES;
    if(visibleController!=self)return NO;
    return self.fullscreen||[self hasVisibleExpandedLivePlayer]||self.activeTab==2||self.activeTab==3;
}

- (BOOL)hasVisibleExpandedLivePlayer {
    if(!self.playerExpanded||self.activeTab>=2||!self.channelID.length)return NO;
    BOOL playerMatchesTab=self.favoritesOnly||(self.subscriptionCatalog==([self.currentRemoteURL length]>0));
    return playerMatchesTab;
}

// 展开直播的唯一判定：非全屏且有可见的展开直播播放器。viewDidLayoutSubviews、
// configureCatalogNavigation 与 updateLiveResourceCapsule 共用此谓词，
// 避免三处各自拼写 !fullscreen && hasVisibleExpandedLivePlayer 时漂移。
- (BOOL)isExpandedLivePlayerVisible {
    return !self.fullscreen && [self hasVisibleExpandedLivePlayer];
}

// 播放器覆盖层顶边距：展开直播时贴顶 0，全屏时留出安全区顶边，其余 0。
// 与旧内联三元（expanded 0 / fullscreen safe.top / 其余 0）的取值完全一致。
- (CGFloat)playerOverlayTopInset {
    if ([self isExpandedLivePlayerVisible]) return 0;
    if (self.fullscreen) return self.view.safeAreaInsets.top;
    return 0;
}

// 播放器覆盖层边距：展开直播时上下均为 0，全屏时取全部安全区，其余为 0。
// 底边与旧规则 self.fullscreen ? safe.bottom : 0 的取值完全一致。
- (UIEdgeInsets)playerOverlayInsets {
    if ([self isExpandedLivePlayerVisible]) return UIEdgeInsetsZero;
    if (self.fullscreen) return self.view.safeAreaInsets;
    return UIEdgeInsetsZero;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if(self.fullscreen||[self hasVisibleExpandedLivePlayer])return UIStatusBarStyleLightContent;
    if(@available(iOS 13.0,*)){
        UIUserInterfaceStyle style=self.navigationController.overrideUserInterfaceStyle;
        if(style==UIUserInterfaceStyleUnspecified)style=self.traitCollection.userInterfaceStyle;
        return style==UIUserInterfaceStyleDark?UIStatusBarStyleLightContent:UIStatusBarStyleDarkContent;
    }
    return UIStatusBarStyleDefault;
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if(navigationController!=self.navigationController)return;
    if(viewController!=self&&navigationController.topViewController==self&&self.activeTab==2){
        MediaBrowserViewController *mediaPage=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;
        [mediaPage prepareForNavigationTransition];
    }
    if(viewController!=self&&navigationController.topViewController==self&&self.activeTab==3){
        ConfigCenterViewController *resourcePage=[self.tabPages[@3] isKindOfClass:ConfigCenterViewController.class]?self.tabPages[@3]:nil;
        [resourcePage prepareForNavigationTransition];
    }
    // A push from a compact home/resource tab must reveal the navigation bar at
    // the beginning of the transition so the destination is never presented
    // with a hidden back affordance. Conversely, popping back to a compact tab
    // hides the navigation bar alongside the transition so the top safe area
    // never snaps by 44 pt after didShowViewController.
    BOOL shouldHide=[self shouldHideNavigationBarForVisibleController:viewController];
    if(navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:animated];
    if(viewController==self)return;
    [navigationController setOverrideTraitCollection:[self fontSizeOverrideTraitCollection] forChildViewController:viewController];
    if(self.activeTab<2)[self suspendLivePlaybackForReason:@"left_live_navigation_page"];
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if(navigationController!=self.navigationController||navigationController.topViewController!=viewController)return;
    // Reconcile after the transition completes. During an interactive-pop that is
    // cancelled, UIKit reports the detail/player as the shown controller here, so
    // the home page cannot leave the navigation bar hidden underneath it.
    BOOL shouldHide=[self shouldHideNavigationBarForVisibleController:viewController];
    if(navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:NO];
    if(viewController==self)HostStyleNavigation(navigationController);
    if(viewController==self&&shouldHide)navigationController.navigationBar.prefersLargeTitles=NO;
    if(viewController==self&&self.activeTab==2){
        MediaBrowserViewController *mediaPage=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;
        if(mediaPage){
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            [mediaPage refreshHeaderAfterNavigationTransition];
        }
    }
    if(viewController==self&&self.activeTab==3){
        ConfigCenterViewController *resourcePage=[self.tabPages[@3] isKindOfClass:ConfigCenterViewController.class]?self.tabPages[@3]:nil;
        if(resourcePage){
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            [resourcePage refreshHeaderAfterNavigationTransition];
        }
    }
}

- (void)dealloc {
    // 先停播放再拆通知/定时器：stopPlayback 负责拆除 AVPlayerItem 的 status /
    // playbackLikelyToKeepUp 与 avLayer.readyForDisplay 的 KVO、currentPlayer
    // delegate 置 nil、销毁 cicadaPlayer；stopPreview 负责预览播放器与定时器。
    // 若只拆通知而不停播放，悬垂 KVO 会在 item 释放时崩溃。
    [self stopPlayback];
    [self stopPreview];
    MPRemoteCommandCenter *commandCenter = MPRemoteCommandCenter.sharedCommandCenter;
    [commandCenter.playCommand removeTarget:self];
    [commandCenter.pauseCommand removeTarget:self];
    [commandCenter.nextTrackCommand removeTarget:self];
    [commandCenter.previousTrackCommand removeTarget:self];
    [self.packageDownloader cancel];
    [self.tvboxCatalogBulkImporter cancel];
    [self.nativePreloader cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.playbackReadiness cancel];
    for(LocalServiceReadiness *probe in self.subscriptionReadiness.allValues)[probe cancel];
    [self.liveControlsOverlay invalidate];
    [self.watchdog invalidate];
    [self.epgTimer invalidate];
    [self.liveSleepTimer invalidate];
    [self.liveQualityBadgeTimer invalidate];
    for (AVAssetImageGenerator *gen in self.channelPreviewGenerators.allValues) [gen cancelAllCGImageGeneration];
    [self.channelPreviewGenerators removeAllObjects];
    for (MediaChannelProbe *probe in self.channelTelemetryTasks.allValues) [probe cancel];
    [self.channelTelemetryTasks removeAllObjects];
    for (NSURLSessionTask *task in self.subscriptionEditTasks.allValues) [task cancel];
    [self.subscriptionEditTasks removeAllObjects];
    [self.epgTask cancel];
    [self flushDiagnosticLog];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    [self.channelPreviewSnapshots removeAllObjects];
    for (AVAssetImageGenerator *gen in self.channelPreviewGenerators.allValues) [gen cancelAllCGImageGeneration];
    [self.channelPreviewGenerators removeAllObjects];
    [self.channelPreviewInflight removeAllObjects];
    [self.channelPreviewRefreshPending removeAllObjects];
    if (self.channelTelemetryStore.count > 64) [self.channelTelemetryStore removeAllObjects];
    [self trimEPGCache];
    [self log:@"收到系统内存告警，已清理非活跃预览与遥测缓存"];
}

- (void)onBackground {
    [(MediaBrowserViewController *)self.tabPages[@2] pauseForBackground];
    BOOL livePageRemainsVisible=self.activeTab<2&&self.navigationController.topViewController==self&&self.presentedViewController==nil;
    [RuntimeDiagnostics.shared recordEvent:@"background_playback_policy" category:@"playback" fields:@{@"active_tab":@(self.activeTab),@"live_page_visible":@(livePageRemainsVisible),@"live_player_present":@(self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil||self.remoteAdapter!=nil),@"policy":livePageRemainsVisible?@"keep_live_playback":@"suspend_when_outside_live_page"}];
    if(!livePageRemainsVisible)[self suspendLivePlaybackForReason:@"app_background_outside_live_page"];
    [self.nativePreloader cancel];
    [[HostImageLoader shared] cancelPending];
    [self.channelPreviewSnapshots removeAllObjects];
    [CCTVSharedChannelLogoCache() removeAllObjects];
    [self stopPreview];
    [self.liveQualityBadgeTimer invalidate];self.liveQualityBadgeTimer=nil;
    for(AVAssetImageGenerator *gen in self.channelPreviewGenerators.allValues)[gen cancelAllCGImageGeneration];
    [self.channelPreviewGenerators removeAllObjects];[self.channelPreviewInflight removeAllObjects];
    for(MediaChannelProbe *probe in self.channelTelemetryTasks.allValues)[probe cancel];
    [self.channelTelemetryTasks removeAllObjects];[self.channelTelemetryInflight removeAllObjects];
    [self.epgTimer invalidate];self.epgTimer=nil;
    self.officialEPGRequestGeneration++;[self.epgTask cancel];self.epgTask=nil;
    [[XMLTVStore shared] setPaused:YES];
    // Some native player SDKs pause their stream on resignActive. Keep the
    // active live page eligible for background audio; pages covered by a
    // navigation push or modal were already suspended above.
    if(!livePageRemainsVisible)[self call:self.currentPlayer sel:@"resignActive"];
    if (CCTVBoolPreference(@"autoPiP",NO) && self.avLayer && AVPictureInPictureController.isPictureInPictureSupported && !self.pip.isPictureInPictureActive) {
        self.pip=[[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
        [self.pip startPictureInPicture];
        [self log:@"后台自动进入画中画"];
    }
    [self log:@"进入后台"];
    [self flushDiagnosticLog];
}

- (void)onForeground {
    [PyHost refreshListenersAfterForeground];
    BOOL playbackPriority=CACurrentMediaTime()<self.playbackPriorityUntil;
    [[XMLTVStore shared] setPaused:playbackPriority];
    [self call:self.currentPlayer sel:@"becomeActive"];
    if(self.firstRender)[self startLiveQualityBadgeTimer];
    if(self.epgRefreshDesired&&!playbackPriority){[self restartEPGTimer];[self refreshNowNext];}
    if(self.activeTab<2 && CACurrentMediaTime()>=self.playbackPriorityUntil){[self.channelGrid reloadData];[self.table reloadData];}
    if(self.activeTab==2)[(MediaBrowserViewController *)self.tabPages[@2] resumeAfterForeground];
    [self log:@"回到前台"];
}
- (void)checkVisibleMediaAfterActivation {
    [PyHost refreshListenersAfterForeground];
    if(self.activeTab==2)[(MediaBrowserViewController *)self.tabPages[@2] resumeAfterForeground];
}

#pragma mark - 日志

- (void)restoreDiagnosticLog {
    // 日志文件可达 4 MiB，启动时在主线程同步读 + 脱敏会卡启动；移到后台读，
    // 只保留末尾 256 KiB（就近的崩溃上下文），再回主线程追加到日志缓冲。
    NSString *path=self.diagnosticLogPath;
    if(!path.length)return;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil;
        NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if(text.length>256*1024){
            NSUInteger cut=text.length-256*1024;
            NSRange newline=[text rangeOfString:@"\n" options:0 range:NSMakeRange(cut,MIN(4096,text.length-cut))];
            text=[text substringFromIndex:newline.location!=NSNotFound?NSMaxRange(newline):cut];
        }
        text=[HostLogRedactor redactText:text?:@""];
        if(!text.length)return;
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.logBuffer appendString:@"—— 上次运行日志（崩溃/强制退出前）——\n"];
            [owner.logBuffer appendString:text];
            if (![text hasSuffix:@"\n"]) [owner.logBuffer appendString:@"\n"];
            [owner.logBuffer appendString:@"—— 本次启动 ——\n"];
            NSLog(@"[CCTVHost] 已恢复上次运行日志，%lu 字符",(unsigned long)text.length);
        });
    });
}
- (void)persistDiagnosticLine:(NSString *)line {
    [self.pendingLogWrites append:line];
    [self scheduleDiagnosticLogFlush];
}
- (void)scheduleDiagnosticLogFlush {
    if(!self.pendingLogWrites||!self.diagnosticLogPath.length)return;
    @synchronized(self.pendingLogWrites){if(self.diagnosticFlushScheduled)return;self.diagnosticFlushScheduled=YES;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{RootViewController *owner=weakSelf;if(owner)[owner flushDiagnosticLog];});
}
- (void)flushDiagnosticLog {
    NSString *batch;NSUInteger generation;
    @synchronized(self.pendingLogWrites) {
        self.diagnosticFlushScheduled=NO;
        if(self.diagnosticWriteInProgress || !self.pendingLogWrites.length || !self.diagnosticLogPath.length)return;
        self.diagnosticWriteInProgress=YES;generation=self.diagnosticLogGeneration;batch=[self.pendingLogWrites drain];
    }
    dispatch_async(self.diagnosticLogQueue, ^{@autoreleasepool {
        NSFileHandle *file=nil;
        @try {
            @synchronized(self.pendingLogWrites){if(generation!=self.diagnosticLogGeneration)return;}
            NSFileManager *fm=NSFileManager.defaultManager;
            [fm createDirectoryAtPath:self.diagnosticLogPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            if(![fm fileExistsAtPath:self.diagnosticLogPath])[fm createFileAtPath:self.diagnosticLogPath contents:nil attributes:nil];
            file=[NSFileHandle fileHandleForWritingAtPath:self.diagnosticLogPath];
            [file seekToEndOfFile];[file writeData:[batch dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];file=nil;
            unsigned long long size=[[fm attributesOfItemAtPath:self.diagnosticLogPath error:NULL] fileSize];
            if(size>512*1024){
                file=[NSFileHandle fileHandleForReadingAtPath:self.diagnosticLogPath];[file seekToFileOffset:size-256*1024];
                NSData *tail=[file readDataOfLength:256*1024];[file closeFile];file=nil;
                NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];
                NSRange boundary=[tail rangeOfData:newline options:0 range:NSMakeRange(0,tail.length)];
                if(boundary.location!=NSNotFound){NSUInteger start=NSMaxRange(boundary);[[tail subdataWithRange:NSMakeRange(start,tail.length-start)] writeToFile:self.diagnosticLogPath atomically:YES];}
            }
        } @catch(NSException *exception){NSLog(@"[CCTVHost] diagnostic log write failed: %@",exception.name);}
        @finally {
            [file closeAndReturnError:NULL];
            BOOL hasPending=NO;
            @synchronized(self.pendingLogWrites){self.diagnosticWriteInProgress=NO;hasPending=self.pendingLogWrites.length>0;}
            if(hasPending)[self scheduleDiagnosticLogFlush];
        }
    }});
}
- (void)log:(NSString *)format, ... {
    va_list ap;va_start(ap,format);NSString *msg=[[NSString alloc] initWithFormat:format arguments:ap];va_end(ap);
    msg=[HostLogRedactor redactText:msg];
    if(msg.length>4096){NSUInteger end=4096;unichar last=[msg characterAtIndex:end-1];if(last>=0xd800 && last<=0xdbff)end--;msg=[[msg substringToIndex:end] stringByAppendingString:@"… [日志已截断]"];}
    [self persistDiagnosticLine:[NSString stringWithFormat:@"[%@] %@\n",NSDate.date.description,msg]];
    // One pending UI delivery for all producers, rather than one main-queue
    // block per Python print(). The bounded tail survives a blocked UI thread.
    if(![self.pendingLogDisplay append:[msg stringByAppendingString:@"\n"]])return;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        RootViewController *owner=weakSelf;if(!owner)return;
        NSString *batch=[owner.pendingLogDisplay drain];if(!batch.length)return;
        [owner.logBuffer appendString:batch];
        if(owner.logBuffer.length>20000){NSUInteger remove=owner.logBuffer.length-16000;unichar next=[owner.logBuffer characterAtIndex:remove];if(next>=0xdc00 && next<=0xdfff)remove++;[owner.logBuffer deleteCharactersInRange:NSMakeRange(0,remove)];}
        NSString *summary=[[batch stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"].lastObject?:@"";
        NSLog(@"[CCTVHost] %@",summary);
        [[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
    });
}

- (void)togglePiP {
    if (!AVPictureInPictureController.isPictureInPictureSupported) { [self log:@"设备不支持画中画"]; [self showServiceError:@"当前设备不支持系统画中画。"]; return; }
    if (!self.avLayer) {
        [self log:@"画中画仅支持订阅源（AVPlayer）"];
        [self showServiceError:@"央视原生加密频道由专用内核（CNPlayerSDK）解密渲染，不支持系统画中画；仅「频道」页的普通 HLS 订阅源（AVPlayer）支持画中画。"];
        return;
    }
    if (self.pip && self.pip.isPictureInPictureActive) { [self.pip stopPictureInPicture]; return; }
    self.pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
    if (@available(iOS 14.2, *)) { self.pip.canStartPictureInPictureAutomaticallyFromInline = CCTVBoolPreference(@"autoPiP", NO); }
    [self.pip startPictureInPicture];
    [self log:@"进入画中画"];
}

#pragma mark - 播放区

- (void)buildPlayer {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = w * 9.0 / 16.0;
    self.playerBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    self.playerBox.backgroundColor = UIColor.blackColor;
    self.playerBox.clipsToBounds = YES;
    [self.view addSubview:self.playerBox];

    self.liveResourceCapsule=[UIButton buttonWithType:UIButtonTypeSystem];
    self.liveResourceCapsule.accessibilityIdentifier=@"live.resource.capsule";
    self.liveResourceCapsule.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    self.liveResourceCapsule.hidden=YES;
    [self.view addSubview:self.liveResourceCapsule];
    [self updateLiveResourceCapsule];

    self.playerTopScrim=[UIView new];self.playerTopScrim.userInteractionEnabled=NO;self.playerTopGradient=[CAGradientLayer layer];self.playerTopGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:.76].CGColor,(id)[UIColor colorWithWhite:0 alpha:.36].CGColor,(id)UIColor.clearColor.CGColor];self.playerTopGradient.locations=@[@0,@0.62,@1];self.playerTopGradient.startPoint=CGPointMake(.5,0);self.playerTopGradient.endPoint=CGPointMake(.5,1);[self.playerTopScrim.layer addSublayer:self.playerTopGradient];[self.playerBox addSubview:self.playerTopScrim];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 20)];
    self.titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont boldSystemFontOfSize:13]];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.text = @"选择频道开始播放";
    [self.playerBox addSubview:self.titleLabel];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 26, w - 24, 16)];
    self.infoLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    self.infoLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10]];
    self.infoLabel.adjustsFontForContentSizeCategory = YES;
    self.infoLabel.numberOfLines = 1;
    self.infoLabel.text = [NSString stringWithFormat:@"版本 %@", CCTVBuildTag()];
    [self.playerBox addSubview:self.infoLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(w / 2, h / 2);
    self.spinner.hidesWhenStopped = YES;
    [self.playerBox addSubview:self.spinner];

    self.playerChannelLogo=[UIImageView new];
    self.playerChannelLogo.contentMode=UIViewContentModeScaleAspectFit;
    self.playerChannelLogo.hidden=YES;
    self.playerChannelLogo.userInteractionEnabled=YES;
    self.playerChannelLogo.accessibilityLabel=@"当前频道台标";
    self.playerChannelLogo.accessibilityHint=@"轻点打开电视台增强面板、切换同台多源或设置台标";
    UITapGestureRecognizer *logoTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayerChannelLogoTap)];
    [self.playerChannelLogo addGestureRecognizer:logoTap];
    [self.playerBox addSubview:self.playerChannelLogo];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleProfileLogoOrMetadataChange:) name:ProfileStoreMetadataDidChangeNotification object:nil];

    self.controlBar = [[UIStackView alloc] initWithFrame:CGRectMake(8, h - 52, w - 16, 44)];
    self.controlBar.axis = UILayoutConstraintAxisHorizontal;
    self.controlBar.distribution = UIStackViewDistributionFillEqually;
    self.controlBar.spacing = 5;
    self.playPauseBtn = [self barButton:@"暂停" action:@selector(togglePlayPause)];
    self.muteBtn = [self barButton:@"静音" action:@selector(toggleMute)];
    self.routeBtn = [self barButton:@"线路" action:@selector(showRoutes)];
    self.epgBtn = [self barButton:@"节目单" action:@selector(openEPG)];
    self.castBtn = [self barButton:@"投屏" action:@selector(showCastingCenter)];
    self.castBtn.accessibilityIdentifier = @"player.control.cast";
    self.playbackQualityBadgeBtn = [self barButton:@"信息" action:@selector(showPlaybackInfo)];
    self.playbackQualityBadgeBtn.accessibilityIdentifier = @"player.control.info";
    self.moreBtn = [self barButton:@"更多" action:@selector(showMorePlaybackActions)];
    self.fullscreenBtn=[self barButton:@"全屏" action:@selector(toggleFullscreen)];self.fullscreenBtn.accessibilityIdentifier=@"player.control.fullscreen";
    for (UIButton *b in @[self.playPauseBtn, self.muteBtn, self.playbackQualityBadgeBtn, self.fullscreenBtn, self.moreBtn]) {
        [self.controlBar addArrangedSubview:b];
    }
    [self updatePlaybackControlAccessibility];
    self.hiddenRoutePicker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
    self.hiddenRoutePicker.prioritizesVideoDevices = YES;
    self.hiddenRoutePicker.alpha = 0.01;
    self.hiddenRoutePicker.userInteractionEnabled = NO;
    [self.playerBox addSubview:self.hiddenRoutePicker];
    self.playerBottomScrim=[UIView new];self.playerBottomScrim.userInteractionEnabled=NO;self.playerBottomGradient=[CAGradientLayer layer];self.playerBottomGradient.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.48].CGColor,(id)[UIColor colorWithWhite:0 alpha:.84].CGColor];self.playerBottomGradient.locations=@[@0,@0.45,@1];self.playerBottomGradient.startPoint=CGPointMake(.5,0);self.playerBottomGradient.endPoint=CGPointMake(.5,1);[self.playerBottomScrim.layer addSublayer:self.playerBottomGradient];[self.playerBox addSubview:self.playerBottomScrim];
    [self.playerBox addSubview:self.controlBar];

    self.volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 10, 10)];
    self.volumeView.showsRouteButton = NO;
    [self.view addSubview:self.volumeView];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.playerBox addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleOverlay)];
    [self.playerBox addGestureRecognizer:tap];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullscreen)];
    doubleTap.numberOfTapsRequired = 2;
    [self.playerBox addGestureRecognizer:doubleTap];
    [tap requireGestureRecognizerToFail:doubleTap];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    NSDictionary<NSString *,NSString *> *symbols=@{@"暂停":@"pause.fill",@"播放":@"play.fill",@"继续":@"play.fill",@"继续播放":@"play.circle.fill",@"重试":@"arrow.clockwise",@"重播":@"gobackward",@"重连中":@"arrow.triangle.2.circlepath",@"静音":@"speaker.wave.2.fill",@"线路":@"antenna.radiowaves.left.and.right",@"节目单":@"list.bullet.rectangle",@"投屏":@"airplayvideo",@"投屏中":@"tv.and.mediabox.fill",@"信息":@"info.circle",@"更多":@"ellipsis.circle",@"全屏":@"arrow.up.left.and.arrow.down.right",@"退出全屏":@"arrow.down.right.and.arrow.up.left"};
    NSString *symbol=symbols[title];
    if(symbol){UIImageSymbolConfiguration *sc=[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];[b setImage:[UIImage systemImageNamed:symbol withConfiguration:sc] forState:UIControlStateNormal];b.imageEdgeInsets=UIEdgeInsetsMake(0,-2,0,3);}
    b.accessibilityLabel=title;
    b.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    b.titleLabel.adjustsFontForContentSizeCategory = YES;
    // 大字体下 5 个等宽按钮放不下 12pt 放大标题：允许缩到 60% 而不是截断。
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 0.65;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    b.titleLabel.hidden=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    b.titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    b.titleLabel.layer.shadowOpacity = 0.72;
    b.titleLabel.layer.shadowRadius = 2.0;
    b.titleLabel.layer.shadowOffset = CGSizeMake(0, 1);
    HostInstallPressFeedback(b);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)syncPlayPauseButtonIcon {
    if (!self.playPauseBtn) return;
    NSString *title = [self.playPauseBtn titleForState:UIControlStateNormal] ?: @"";
    NSDictionary<NSString *,NSString *> *symbols = @{
        @"暂停":@"pause.fill",
        @"播放":@"play.fill",
        @"继续":@"play.fill",
        @"继续播放":@"play.circle.fill",
        @"重试":@"arrow.clockwise",
        @"重播":@"gobackward",
        @"重连中":@"arrow.triangle.2.circlepath"
    };
    NSString *symbol = symbols[title];
    if (symbol.length) {
        UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        [self.playPauseBtn setImage:[UIImage systemImageNamed:symbol withConfiguration:sc] forState:UIControlStateNormal];
    }
    if (title.length) self.playPauseBtn.accessibilityLabel = title;
    if (self.muteBtn) {
        NSString *muteTitle = [self.muteBtn titleForState:UIControlStateNormal] ?: @"";
        NSString *muteSymbol = [muteTitle isEqualToString:@"发声"] ? @"speaker.slash.fill" : @"speaker.wave.2.fill";
        UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        [self.muteBtn setImage:[UIImage systemImageNamed:muteSymbol withConfiguration:sc] forState:UIControlStateNormal];
        if (muteTitle.length) self.muteBtn.accessibilityLabel = muteTitle;
    }
}

- (void)updatePlaybackControlAccessibility {
    BOOL large=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    NSMutableArray<UIButton *> *buttons=[NSMutableArray array];for(UIButton *button in @[self.playPauseBtn?:NSNull.null,self.muteBtn?:NSNull.null,self.playbackQualityBadgeBtn?:NSNull.null,self.fullscreenBtn?:NSNull.null,self.moreBtn?:NSNull.null])if([button isKindOfClass:UIButton.class])[buttons addObject:button];for(UIButton *button in buttons)button.titleLabel.hidden=large;
    self.fullscreenBtn.accessibilityLabel=self.fullscreen?@"退出全屏":@"全屏";
    self.fullscreenBtn.accessibilityHint=self.fullscreen?@"返回频道播放页面":@"全屏显示当前频道";
}

- (void)setLiveOverlayHidden:(BOOL)hidden {
    self.controlBar.hidden=hidden;self.playerBottomScrim.hidden=hidden;self.playerTopScrim.hidden=hidden;self.titleLabel.hidden=hidden;self.infoLabel.hidden=hidden;
}
- (PlaybackOverlayController *)liveOverlayPolicy {
    if(!self.liveControlsOverlay){self.liveControlsOverlay=[PlaybackOverlayController new];__weak typeof(self) weakSelf=self;
        self.liveControlsOverlay.onVisibilityChanged=^(BOOL visible){[weakSelf setLiveOverlayHidden:!visible];};
        self.liveControlsOverlay.canAutoHide=^BOOL{RootViewController *owner=weakSelf;return owner&&owner.firstRender&&[owner sessionIsPlaying]&&!owner.livePanActive&&!owner.nativeTimeShiftActive&&!owner.remoteCatchupActive&&!owner.nativePlaybackFailed&&!owner.remotePlaybackFailed;};
        if(self.controlBar.hidden)[self.liveControlsOverlay hide];else[self.liveControlsOverlay show];
    }return self.liveControlsOverlay;
}
- (void)toggleOverlay {[[self liveOverlayPolicy] toggle];}

#pragma mark - 列表

- (void)buildList {
    CGFloat y = CGRectGetMaxY(self.playerBox.frame);
    self.catalogTopImmersiveScrim = [UIView new];
    self.catalogTopImmersiveScrim.userInteractionEnabled = NO;
    self.catalogTopImmersiveScrim.accessibilityIdentifier = @"catalog.top.immersive.scrim";
    self.catalogTopImmersiveGradient = [CAGradientLayer layer];
    self.catalogTopImmersiveGradient.locations = @[@0.0, @0.68, @1.0];
    [self.catalogTopImmersiveScrim.layer addSublayer:self.catalogTopImmersiveGradient];
    [self.view addSubview:self.catalogTopImmersiveScrim];
    self.catalogGroupGlassCard = [UIView new];
    self.catalogGroupGlassCard.userInteractionEnabled = NO;
    HostStyleGlassCard(self.catalogGroupGlassCard, 14);
    [self.view addSubview:self.catalogGroupGlassCard];
    self.groupControl = [[UISegmentedControl alloc] initWithItems:[self currentCatalogGroupTitles]];
    self.groupControl.frame = CGRectMake(8, y + 6, self.view.bounds.size.width - 16, 32);
    self.groupControl.selectedSegmentIndex = 0;
    self.groupControl.tintColor = HostAccent();self.groupControl.selectedSegmentTintColor=HostAccentFill();NSDictionary *segmentNormal=@{NSForegroundColorAttributeName:HostMutedText(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]]},*segmentSelected=@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]]};[self.groupControl setTitleTextAttributes:segmentNormal forState:UIControlStateNormal];[self.groupControl setTitleTextAttributes:segmentSelected forState:UIControlStateSelected];
    [self.groupControl addTarget:self action:@selector(onGroupChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.groupControl];
    self.playerTabs=[[UISegmentedControl alloc] initWithItems:@[@"分类",@"频道",@"节目",@"线路"]];self.playerTabs.selectedSegmentIndex=1;self.playerTabs.selectedSegmentTintColor=HostAccentFill();[self.playerTabs setTitleTextAttributes:segmentNormal forState:UIControlStateNormal];[self.playerTabs setTitleTextAttributes:segmentSelected forState:UIControlStateSelected];[self.playerTabs addTarget:self action:@selector(selectPlayerPanel) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.playerTabs];

    self.versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, y + 38, self.view.bounds.size.width - 16, 14)];
    self.versionLabel.textColor = HostSecondaryText();
    self.versionLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9]];
    self.versionLabel.adjustsFontForContentSizeCategory = YES;
    self.versionLabel.text = [NSString stringWithFormat:@"%@ · 点击自动播放 · 长按选线路", CCTVBuildTag()];
    [self.view addSubview:self.versionLabel];

    CGFloat ty = y + 54;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty) style:UITableViewStylePlain];self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 66;
    self.table.estimatedSectionHeaderHeight = 0;
    self.table.sectionHeaderTopPadding = 0;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;
    UILongPressGestureRecognizer *routePress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.table addGestureRecognizer:routePress];
    UICollectionViewFlowLayout *flow=[UICollectionViewFlowLayout new]; flow.minimumInteritemSpacing=6; flow.minimumLineSpacing=8; flow.sectionInset=UIEdgeInsetsMake(8,10,16,10);
    self.channelGrid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:flow]; self.channelGrid.backgroundColor=HostBackground(); self.channelGrid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag; self.channelGrid.dataSource=self; self.channelGrid.delegate=self; self.channelGrid.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.channelGrid.accessibilityIdentifier=@"channel.grid";
    [self.channelGrid registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"channel.card"]; self.channelCatalogController=[[HostChannelCatalogController alloc] initWithTable:self.table grid:self.channelGrid];[self addChildViewController:self.channelCatalogController];self.channelCatalogController.view.frame=self.view.bounds;self.channelCatalogController.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:self.channelCatalogController.view];[self.channelCatalogController didMoveToParentViewController:self];
    UIRefreshControl *gridRefresh=[UIRefreshControl new];[gridRefresh addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];self.channelGrid.refreshControl=gridRefresh;
    [self buildBottomBar];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索频道";
    self.searchController.searchBar.accessibilityLabel = @"搜索频道";
    self.searchController.searchBar.accessibilityHint = @"输入频道名称或编号以筛选列表";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

}

- (void)openDiagnosticLog {
    [self openDiagnosticLogForIdentifier:nil name:nil];
}
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name {
    if(!line.length||!identifier.length)return;
    [PluginLogStore.shared appendLine:line forIdentifier:identifier];
    NSDictionary *relayRecord=MediaRelayDiagnosticRecord(line);
    if(relayRecord){NSMutableDictionary *fields=[relayRecord mutableCopy];NSString *event=fields[@"event"];[fields removeObjectForKey:@"event"];fields[@"service_id"]=identifier;if(fields[@"request_id"])fields[@"correlation_id"]=fields[@"request_id"];[RuntimeDiagnostics.shared recordEvent:event category:[event hasPrefix:@"media_play_"]?@"media_api":@"media_relay" fields:fields];}

    dispatch_async(dispatch_get_main_queue(),^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:identifier];});
    if([relayRecord[@"event"] isEqualToString:@"media_relay_client_disconnected"])return;
    [self log:@"[%@] %@",name.length?name:@"插件",line];
}
- (void)clearServiceLogHandlers:(NSString *)identifier {
    if(!identifier.length)return;
    [PyHost setLogHandler:nil forServiceIdentifier:identifier];
    [NodePluginRuntime.shared setLogHandler:nil forServiceIdentifier:identifier];
    [JSPluginRuntime.shared setLogHandler:nil forServiceIdentifier:identifier];
}
- (void)openDiagnosticLogForIdentifier:(NSString *)identifier name:(NSString *)name {
    if(identifier.length){
        PluginRunHistoryViewController *history=[PluginRunHistoryViewController new];history.serviceName=name;__weak typeof(self) weakSelf=self;NSString *scope=[identifier copy];NSString *scopeName=[name copy];
        history.runRecordsProvider=^NSArray<NSDictionary *> *{__block BOOL operating=NO;dispatch_block_t readState=^{operating=[weakSelf.serviceOperations containsObject:scope];};if(NSThread.isMainThread)readState();else dispatch_sync(dispatch_get_main_queue(),readState);if(!operating&&![PyHost isManagedServiceIdentifier:scope])[PluginLogStore.shared markUnmanagedRunsInterruptedForIdentifier:scope];return [PluginLogStore.shared runsForIdentifier:scope];};
        history.onSelectRun=^(NSDictionary *run){[weakSelf openPluginRunLogForIdentifier:scope name:scopeName?:@"服务" run:run];};
        history.onExportAll=^{[PluginLogStore.shared prepareExportForIdentifier:scope displayName:scopeName?:@"插件" completion:^(NSURL *url,NSError *error){if(!url){[weakSelf showServiceError:error.localizedDescription?:@"该脚本还没有可导出的日志。"];return;}[weakSelf shareDiagnosticLogAtURL:url];}];};
        history.onClearAll=^{[PluginLogStore.shared clearLogForIdentifier:scope completion:^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:scope];}];};
        UIViewController *presented=self.presentedViewController;if(presented)[presented dismissViewControllerAnimated:YES completion:^{[weakSelf.navigationController pushViewController:history animated:YES];}];else[self.navigationController pushViewController:history animated:YES];return;
    }
    LogCenterViewController *page=[LogCenterViewController new];page.scopeName=name;
    __weak typeof(self) weakSelf=self;
    page.logSnapshotProvider=^{return weakSelf.logBuffer.copy?:@"";};
    page.onExportLog=^{[weakSelf exportDiagnosticLog];};
    page.onClearLog=^{[weakSelf clearDiagnosticLog];};
    UIViewController *presented=self.presentedViewController;
    if(presented){[presented dismissViewControllerAnimated:YES completion:^{[weakSelf.navigationController pushViewController:page animated:YES];}];}
    else [self.navigationController pushViewController:page animated:YES];
}
- (void)openPluginRunLogForIdentifier:(NSString *)identifier name:(NSString *)name run:(NSDictionary *)run {
    NSString *runID=[run[@"runID"] isKindOfClass:NSString.class]?run[@"runID"]:@"";if(!identifier.length||!runID.length)return;LogCenterViewController *page=[LogCenterViewController new];page.scopeName=name;NSString *runTitle=[run[@"legacy"] boolValue]?@"历史日志":[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[run[@"startedAt"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];page.titleOverride=[NSString stringWithFormat:@"%@ · %@",name.length?name:@"服务",runTitle];page.clearActionTitle=@"清空本次日志";page.clearConfirmationMessage=@"只清理这一次运行的日志，不影响其他运行记录、服务代码或配置。服务仍在运行时，后续日志会继续写入本次记录。";
    __weak typeof(self) weakSelf=self;NSString *scope=[identifier copy];NSString *selectedRun=[runID copy];NSString *scopeName=[name copy];page.logSnapshotProvider=^NSString *{return [PluginLogStore.shared logForIdentifier:scope runID:selectedRun];};page.onExportLog=^{[PluginLogStore.shared prepareExportForIdentifier:scope runID:selectedRun displayName:scopeName?:@"插件" completion:^(NSURL *url,NSError *error){if(!url){[weakSelf showServiceError:error.localizedDescription?:@"该次运行还没有可导出的日志。"];return;}[weakSelf shareDiagnosticLogAtURL:url];}];};page.onClearLog=^{[PluginLogStore.shared clearRunForIdentifier:scope runID:selectedRun completion:^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:scope];}];};[self.navigationController pushViewController:page animated:YES];
}

- (void)shareDiagnosticLogAtURL:(NSURL *)source {
    UIViewController *top=self.navigationController.topViewController?:self;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[source] applicationActivities:nil];
    UIPopoverPresentationController *pop=share.popoverPresentationController;
    if(pop){pop.barButtonItem=top.navigationItem.rightBarButtonItem;if(!pop.barButtonItem){pop.sourceView=top.view;pop.sourceRect=CGRectMake(CGRectGetMidX(top.view.bounds),CGRectGetMidY(top.view.bounds),1,1);}}
    [top presentViewController:share animated:YES completion:nil];
}
- (NSString *)safeResourceExportName:(NSString *)name {
    NSString *value=[name isKindOfClass:NSString.class]?name:@"资源";NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r"];NSMutableString *safe=[NSMutableString string];[value enumerateSubstringsInRange:NSMakeRange(0,value.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange substringRange,NSRange enclosingRange,BOOL *stop){[safe appendString:([substring rangeOfCharacterFromSet:invalid].location==NSNotFound&&[substring rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound)?substring:@"_"];if(safe.length>=64)*stop=YES;}];value=[safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!value.length)value=@"资源";return value;
}
- (NSURL *)writeResourceExportData:(NSData *)data name:(NSString *)name extension:(NSString *)extension error:(NSError **)error {
    if(!data.length){if(error)*error=[NSError errorWithDomain:@"CCTVHostExport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源文件内容为空"}];return nil;}NSString *filename=[NSString stringWithFormat:@"%@-%@.%@",[self safeResourceExportName:name],NSUUID.UUID.UUIDString.lowercaseString,extension];NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];if(![data writeToURL:url options:NSDataWritingAtomic error:error])return nil;return url;
}
- (void)exportCatalogSingleResource:(NSString *)source resource:(NSDictionary *)resource kind:(NSString *)kind index:(NSUInteger)index {
    NSString *identifier=[source hasPrefix:@"tvbox:"]?[source substringFromIndex:6]:@"";NSError *error=nil;NSData *data=[TVBoxCatalogStore exportSingleResourceForCatalogID:identifier kind:kind index:index error:&error];if(!data){[self showServiceError:error.localizedDescription?:@"单项资源导出失败"];return;}NSURL *url=[self writeResourceExportData:data name:resource[@"name"]?:@"资源" extension:@"json" error:&error];if(!url){[self showServiceError:error.localizedDescription?:@"单项资源文件写入失败"];return;}[self shareResourceFileAtURL:url];
}
- (void)exportCatalogPackage:(NSString *)identifier token:(NSString *)token {
    if(self.tvboxCatalogPackageExporter){[self showServiceError:@"另一个资源 ZIP 正在生成，请稍后再试"];return;}NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集"];return;}
    TVBoxCatalogPackageExporter *exporter=[[TVBoxCatalogPackageExporter alloc] initWithCatalogID:identifier token:token];self.tvboxCatalogPackageExporter=exporter;NSUInteger total=0;for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[]){NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";NSURL *apiURL=CCTVURLFromPossiblyUnescapedString(api);NSString *path=apiURL.path.lowercaseString?:@"";if([path hasSuffix:@".md5"])path=[path stringByDeletingPathExtension];NSString *ext=path.pathExtension;if([@[@"py",@"js",@"hjs",@"mjs",@"cjs"] containsObject:ext])total++;}
    UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在收集合集内部 PY / JS" message:[NSString stringWithFormat:@"准备 0 / %lu",(unsigned long)total] preferredStyle:UIAlertControllerStyleAlert];self.tvboxCatalogExportProgressAlert=progress;__weak typeof(self) weakSelf=self;[progress addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[weakSelf.tvboxCatalogPackageExporter cancel];}]];[self presentViewController:progress animated:YES completion:nil];
    exporter.progressHandler=^(NSUInteger completed,NSUInteger count,NSString *currentName){RootViewController *owner=weakSelf;UIAlertController *active=owner.tvboxCatalogExportProgressAlert;if(active)active.message=[NSString stringWithFormat:@"已处理 %lu / %lu · %@",(unsigned long)completed,(unsigned long)total,currentName.length?currentName:@"准备打包"] ;};
    [exporter startWithCompletion:^(NSURL *url,NSUInteger failedCount,NSError *error){RootViewController *owner=weakSelf;owner.tvboxCatalogPackageExporter=nil;UIAlertController *active=owner.tvboxCatalogExportProgressAlert;owner.tvboxCatalogExportProgressAlert=nil;if(error.code==NSURLErrorCancelled)return;if(!url){if(active.presentingViewController)[active dismissViewControllerAnimated:YES completion:^{[owner showServiceError:error.localizedDescription?:@"资源 ZIP 生成失败"];}];else[owner showServiceError:error.localizedDescription?:@"资源 ZIP 生成失败"];return;}void(^share)(void)=^{if(failedCount)owner.navigationItem.prompt=[NSString stringWithFormat:@"ZIP 已生成 · %lu 个脚本未能获取，详见 source-manifest.json",(unsigned long)failedCount];[owner shareResourceFileAtURL:url];};if(active.presentingViewController){[active dismissViewControllerAnimated:YES completion:^{if(failedCount){UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"资源 ZIP 已生成" message:[NSString stringWithFormat:@"可下载脚本已打包。%lu 项未能获取，具体原因列在 ZIP 内的 source-manifest.json。",(unsigned long)failedCount] preferredStyle:UIAlertControllerStyleAlert];[notice addAction:[UIAlertAction actionWithTitle:@"分享 ZIP" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){share();}]];[notice addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];[owner presentViewController:notice animated:YES completion:nil];}else share();}];}else share();}];
}
- (void)exportResource:(NSString *)source format:(NSString *)format {
    if([source hasPrefix:@"tvbox:"]){NSString *identifier=[source substringFromIndex:6];if([format isEqual:@"catalog-json"]){NSError *error=nil;NSData *data=[TVBoxCatalogStore exportDataForCatalogID:identifier error:&error];NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];NSURL *url=data?[self writeResourceExportData:data name:catalog[@"name"]?:@"资源合集" extension:@"json" error:&error]:nil;if(!url){[self showServiceError:error.localizedDescription?:@"资源合集 JSON 导出失败"];return;}[self shareResourceFileAtURL:url];return;}if([format isEqual:@"catalog-zip"]){NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];BOOL needsToken=NO;for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[])if([[site[@"api"] description] containsString:CCTVTVBoxTokenPlaceholder]){needsToken=YES;break;}NSString *token=CCTVTVBoxStoredSubscriptionToken();if(needsToken&&!token.length){UIAlertController *credential=[UIAlertController alertControllerWithTitle:@"导出合集 ZIP" message:@"合集中的部分 PY / JS 文件需要订阅令牌。令牌只保存在本机钥匙串，并用于本次脚本下载；下载失败项会在清单中明确列出。" preferredStyle:UIAlertControllerStyleAlert];[credential addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"token 或完整订阅链接";field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];[credential addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weakSelf=self;[credential addAction:[UIAlertAction actionWithTitle:@"保存并导出" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *entered=CCTVTVBoxTokenFromInput(credential.textFields.firstObject.text?:@"");if(!entered.length){[weakSelf showServiceError:@"请输入有效的订阅令牌或完整订阅链接"];return;}if(!CCTVTVBoxSaveSubscriptionToken(entered)){[weakSelf showServiceError:@"令牌未能保存到本机钥匙串"];return;}[weakSelf exportCatalogPackage:identifier token:entered];}]];[self presentViewController:credential animated:YES completion:nil];return;}[self exportCatalogPackage:identifier token:token];return;}
    }
    if([source hasPrefix:@"plugin:"]){NSDictionary *service=[self resourceServiceForSource:source];if(!service){[self showServiceError:@"找不到该脚本资源"];return;}NSString *path=[service[@"archivePath"] isKindOfClass:NSString.class]?service[@"archivePath"]:@"";if(!path.length||![NSFileManager.defaultManager fileExistsAtPath:path])path=[ServiceStore codePath:service];if(!path.length||![NSFileManager.defaultManager fileExistsAtPath:path]){[self showServiceError:@"此资源没有可导出的代码文件"];return;}[self shareDiagnosticLogAtURL:[NSURL fileURLWithPath:path]];return;}
    NSDictionary *metadata=source.length?[ProfileStore metadata:source]:@{};NSString *name=metadata[@"name"]?:([source hasPrefix:@"local-playlist:"]?@"本地播放列表":([NSURL URLWithString:source].host?:@"央视直播"));NSString *text=[metadata[@"text"] isKindOfClass:NSString.class]?metadata[@"text"]:@"";NSString *extension=([text containsString:@"#EXTM3U"]||[text containsString:@"#EXTINF"])?@"m3u":@"txt";
    if(!text.length){NSMutableArray *lines=[NSMutableArray arrayWithObject:@"#EXTM3U"];NSArray *channels=nil;if(source.length){NSArray *cached=[metadata[@"cachedChannels"] isKindOfClass:NSArray.class]?metadata[@"cachedChannels"]:@[];channels=cached.count?cached:[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *channel,NSDictionary *bindings){return [CCTVStringArrayValue(channel[@"subscriptionSources"]) containsObject:source];}]];}else channels=[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *channel,NSDictionary *bindings){return ![channel[@"remoteURL"] length];}]];
        for(NSDictionary *channel in channels){NSString *channelName=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"频道";NSString *(^attribute)(id)=^NSString *(id value){if(![value isKindOfClass:NSString.class])return @"";return [[(NSString *)value stringByReplacingOccurrencesOfString:@"\"" withString:@"'"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];};NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];NSArray *urls=routes.count?routes:@[@{@"url":channel[@"remoteURL"]?:channel[@"id"]?:@""}];for(NSDictionary *route in urls){NSString *url=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";if(![ProfileStore isHTTP:url])continue;NSString *group=attribute(channel[@"group"]),*logo=attribute(channel[@"logo"]),*epg=attribute(channel[@"epgID"]);NSMutableArray *attributes=[NSMutableArray array];if(epg.length)[attributes addObject:[NSString stringWithFormat:@"tvg-id=\"%@\"",epg]];if(logo.length)[attributes addObject:[NSString stringWithFormat:@"tvg-logo=\"%@\"",logo]];if(group.length)[attributes addObject:[NSString stringWithFormat:@"group-title=\"%@\"",group]];[lines addObject:[NSString stringWithFormat:@"#EXTINF:-1 %@,%@",[attributes componentsJoinedByString:@" "],attribute(channelName)]];NSDictionary *headers=[channel[@"headers"] isKindOfClass:NSDictionary.class]?channel[@"headers"]:@{};NSData *headerData=headers.count?[NSJSONSerialization dataWithJSONObject:headers options:0 error:NULL]:nil;NSString *headerJSON=headerData?[[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding]:nil;if(headerJSON.length)[lines addObject:[@"#EXTHTTP:" stringByAppendingString:headerJSON]];[lines addObject:url];}}
        if(lines.count==1&&source.length)[lines addObject:[NSString stringWithFormat:@"# Source URL: %@",source]];text=[lines componentsJoinedByString:@"\n"];extension=@"m3u";
    }
    NSError *error=nil;NSURL *url=[self writeResourceExportData:[text dataUsingEncoding:NSUTF8StringEncoding] name:name extension:extension error:&error];if(!url)[self showServiceError:error.localizedDescription?:@"资源文件导出失败"];else[self shareResourceFileAtURL:url];
}
- (void)exportDiagnosticLog {
    [self flushDiagnosticLog];
    dispatch_async(self.diagnosticLogQueue, ^{
        NSString *stored=[NSString stringWithContentsOfFile:self.diagnosticLogPath encoding:NSUTF8StringEncoding error:NULL]?:@"";
        NSString *safe=[HostLogRedactor redactText:stored];
        NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"CCTVHost-总日志-脱敏.txt"];
        [safe writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSURL *source=[NSURL fileURLWithPath:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![NSFileManager.defaultManager fileExistsAtPath:source.path]) { [self log:@"日志文件尚未生成"]; return; }
            [self shareDiagnosticLogAtURL:source];
        });
    });
}
- (void)clearDiagnosticLog {
    [self.pendingLogDisplay clear];
    [self.logBuffer setString:@""];
    @synchronized (self.pendingLogWrites) { self.diagnosticLogGeneration++; [self.pendingLogWrites clear]; }
    dispatch_async(self.diagnosticLogQueue, ^{ [@"" writeToFile:self.diagnosticLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; });
    [[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
}

- (void)buildBottomBar {
    self.bottomBarBackdrop=[UIView new];self.bottomBarBackdrop.backgroundColor=UIColor.clearColor;self.bottomBarBackdrop.opaque=NO;self.bottomBarBackdrop.userInteractionEnabled=NO;self.bottomBarBackdrop.layer.cornerRadius=0;self.bottomBarBackdrop.clipsToBounds=NO;
    self.bottomDockFadeGradient=[CAGradientLayer layer];self.bottomDockFadeGradient.colors=@[(id)[HostBackground() colorWithAlphaComponent:0.0].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.78].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.96].CGColor];self.bottomDockFadeGradient.locations=@[@0,@0.42,@1];[self.bottomBarBackdrop.layer addSublayer:self.bottomDockFadeGradient];
    self.bottomDockGlass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];HostRegisterGlassEffectView(self.bottomDockGlass);self.bottomDockGlass.userInteractionEnabled=NO;self.bottomDockGlass.layer.cornerRadius=27;self.bottomDockGlass.layer.cornerCurve=kCACornerCurveContinuous;self.bottomDockGlass.clipsToBounds=YES;self.bottomDockGlass.layer.borderWidth=0.85;HostSetLayerBorderColor(self.bottomDockGlass,HostBorder());
    UIView *dockTint=[[UIView alloc] initWithFrame:self.bottomDockGlass.contentView.bounds];dockTint.backgroundColor=HostGlassTint();dockTint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;dockTint.userInteractionEnabled=NO;[self.bottomDockGlass.contentView addSubview:dockTint];
    [self.bottomBarBackdrop addSubview:self.bottomDockGlass];
    [self.view addSubview:self.bottomBarBackdrop];
    self.liveMiniPlayerBar=[UIView new];self.liveMiniPlayerBar.hidden=YES;self.liveMiniPlayerBar.accessibilityIdentifier=@"live.mini-player.bar";HostStyleGlassCard(self.liveMiniPlayerBar,20);
    self.liveMiniPlayerLabel=[UILabel new];self.liveMiniPlayerLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];self.liveMiniPlayerLabel.adjustsFontForContentSizeCategory=YES;self.liveMiniPlayerLabel.textColor=HostText();self.liveMiniPlayerLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerLabel];
    self.liveMiniPlayerResumeButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.liveMiniPlayerResumeButton setTitle:@"继续直播" forState:UIControlStateNormal];HostStylePillButton(self.liveMiniPlayerResumeButton,YES);self.liveMiniPlayerResumeButton.layer.cornerRadius=14;self.liveMiniPlayerResumeButton.contentEdgeInsets=UIEdgeInsetsMake(5,12,5,12);self.liveMiniPlayerResumeButton.accessibilityIdentifier=@"live.mini-player.resume";[self.liveMiniPlayerResumeButton addTarget:self action:@selector(resumeSuspendedLiveFromMiniBar) forControlEvents:UIControlEventTouchUpInside];[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerResumeButton];
    self.liveMiniPlayerCloseButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.liveMiniPlayerCloseButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];self.liveMiniPlayerCloseButton.tintColor=HostSecondaryText();self.liveMiniPlayerCloseButton.accessibilityIdentifier=@"live.mini-player.close";self.liveMiniPlayerCloseButton.accessibilityLabel=@"关闭直播挂起提示";[self.liveMiniPlayerCloseButton addTarget:self action:@selector(dismissSuspendedLiveMiniBar) forControlEvents:UIControlEventTouchUpInside];[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerCloseButton];
    [self.view addSubview:self.liveMiniPlayerBar];
    self.hostTabController=[HostTabBarController new];[self addChildViewController:self.hostTabController];self.bottomBar=self.hostTabController.stackView;__weak typeof(self) weakTabOwner=self;self.hostTabController.onSelect=^(UIButton *button){[weakTabOwner bottomTabTapped:button];};
    NSArray<NSString *> *titles=@[@"央视",@"频道",@"影视",@"资源",@"设置"];
    NSArray<NSString *> *accessibilityLabels=@[@"央视直播",@"订阅频道",@"影视库",@"资源管理",@"设置"];
    NSArray<NSString *> *accessibilityHints=@[@"切换到央视直播页面",@"切换到订阅频道页面",@"切换到影视库页面",@"切换到资源管理页面",@"切换到设置页面"];
    NSArray<NSString *> *identifiers=@[@"tab.live",@"tab.channels",@"tab.vod",@"tab.resources",@"tab.settings"];
    NSArray *icons=@[@"tv.fill",@"play.rectangle.on.rectangle",@"house.fill",@"square.stack.3d.up.fill",@"gearshape.fill"];
    for (NSInteger i=0;i<titles.count;i++) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=i;HostInstallPressFeedback(b);
        UIButtonConfiguration *cfg=[UIButtonConfiguration plainButtonConfiguration]; cfg.title=titles[i]; cfg.image=[UIImage systemImageNamed:icons[i]]; cfg.imagePlacement=NSDirectionalRectEdgeTop; cfg.imagePadding=3; cfg.cornerStyle=UIButtonConfigurationCornerStyleCapsule; cfg.contentInsets=NSDirectionalEdgeInsetsMake(6,3,6,3); cfg.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium]; cfg.baseForegroundColor=(i==0?HostOnAccent():HostMutedText()); cfg.background.backgroundColor=i==0?HostAccentFill():UIColor.clearColor; cfg.titleTextAttributesTransformer=^(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];return result;}; b.configuration=cfg;
        b.accessibilityLabel=accessibilityLabels[i]; b.accessibilityIdentifier=identifiers[i];
        b.accessibilityHint=accessibilityHints[i];
        b.accessibilityTraits=UIAccessibilityTraitButton|(i==0?UIAccessibilityTraitSelected:0);b.accessibilityValue=i==0?@"已选中":@"未选中";
        [self.hostTabController addTabButton:b];
    }
    [self.view addSubview:self.hostTabController.view];[self.hostTabController didMoveToParentViewController:self];
    __weak typeof(self) weakSelf=self;
    self.resourceActionsButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceActionsButton.accessibilityIdentifier=@"resource-floating-actions";self.resourceActionsButton.accessibilityLabel=@"脚本与服务及资源操作";
    UIButtonConfiguration *resourceButtonConfig=[UIButtonConfiguration plainButtonConfiguration];resourceButtonConfig.image=[UIImage systemImageNamed:@"slider.horizontal.3"];resourceButtonConfig.baseForegroundColor=HostText();resourceButtonConfig.background.backgroundColor=HostRaisedSurface();resourceButtonConfig.background.strokeColor=HostBorder();resourceButtonConfig.background.strokeWidth=.7;resourceButtonConfig.background.cornerRadius=29;resourceButtonConfig.contentInsets=NSDirectionalEdgeInsetsMake(12,12,12,12);self.resourceActionsButton.configuration=resourceButtonConfig;self.resourceActionsButton.hidden=YES;HostInstallPressFeedback(self.resourceActionsButton);
    UIAction *services=[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){[weakSelf openServicesPage];}];
    UIAction *import=[UIAction actionWithTitle:@"添加资源" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[weakSelf addSubscription];}];
    UIAction *refresh=[UIAction actionWithTitle:@"刷新资源" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[(ConfigCenterViewController *)weakSelf.tabPages[@3] refreshProfiles];}];
    UIAction *home=[UIAction actionWithTitle:@"刷新当前媒体内容" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){ConfigCenterViewController *page=(ConfigCenterViewController *)weakSelf.tabPages[@3];if(page.onRefreshMediaHome)page.onRefreshMediaHome();}];
    self.resourceActionsButton.menu=[UIMenu menuWithChildren:@[services,import,refresh,home]];self.resourceActionsButton.showsMenuAsPrimaryAction=NO;[self.resourceActionsButton addTarget:self action:@selector(openServicesPage) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceActionsButton];

    UIVisualEffectView *catalogControls=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];
    HostRegisterGlassEffectView(catalogControls);
    catalogControls.accessibilityIdentifier=@"channel.catalog.floating-controls";catalogControls.layer.cornerRadius=27;catalogControls.clipsToBounds=YES;catalogControls.layer.borderWidth=0.7;HostSetLayerBorderColor(catalogControls,HostBorder());
    UIView *catalogTint=[[UIView alloc] initWithFrame:catalogControls.contentView.bounds];catalogTint.backgroundColor=HostGlassTint();catalogTint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;catalogTint.userInteractionEnabled=NO;[catalogControls.contentView addSubview:catalogTint];
    self.catalogFloatingControls=catalogControls;
    self.catalogLayoutButton=[UIButton buttonWithType:UIButtonTypeSystem];self.catalogLayoutButton.accessibilityIdentifier=@"channel.catalog.layout.toggle";self.catalogLayoutButton.accessibilityLabel=self.gridMode?@"切换列表布局":@"切换网格布局";
    UIButtonConfiguration *layoutConfig=[UIButtonConfiguration plainButtonConfiguration];layoutConfig.image=[UIImage systemImageNamed:self.gridMode?@"list.bullet":@"square.grid.2x2"];layoutConfig.baseForegroundColor=HostText();layoutConfig.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];layoutConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);self.catalogLayoutButton.configuration=layoutConfig;HostInstallPressFeedback(self.catalogLayoutButton);[self.catalogLayoutButton addTarget:self action:@selector(toggleCatalogLayout) forControlEvents:UIControlEventTouchUpInside];
    self.catalogFloatingAirPlayPicker=[AVRoutePickerView new];self.catalogFloatingAirPlayPicker.tintColor=HostText();self.catalogFloatingAirPlayPicker.activeTintColor=HostAccent();self.catalogFloatingAirPlayPicker.prioritizesVideoDevices=YES;self.catalogFloatingAirPlayPicker.accessibilityIdentifier=@"channel.catalog.airplay";self.catalogFloatingAirPlayPicker.accessibilityLabel=@"投屏到 AirPlay 设备";
    self.catalogMoreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.catalogMoreButton.accessibilityIdentifier=@"channel.catalog.more";self.catalogMoreButton.accessibilityLabel=@"频道页面操作";
    UIButtonConfiguration *moreConfig=[UIButtonConfiguration plainButtonConfiguration];moreConfig.image=[UIImage systemImageNamed:@"ellipsis"];moreConfig.baseForegroundColor=HostText();moreConfig.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];moreConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);self.catalogMoreButton.configuration=moreConfig;self.catalogMoreButton.menu=[self catalogMenu];self.catalogMoreButton.showsMenuAsPrimaryAction=YES;HostInstallPressFeedback(self.catalogMoreButton);
    [catalogControls.contentView addSubview:self.catalogLayoutButton];[catalogControls.contentView addSubview:self.catalogFloatingAirPlayPicker];[catalogControls.contentView addSubview:self.catalogMoreButton];
    [self.view addSubview:catalogControls];
    [self updateBottomBarSelection];
}

- (void)bottomTabTapped:(UIButton *)sender {
    self.userInitiatedTabSelection=YES;
    [self selectBottomTab:sender];
    self.userInitiatedTabSelection=NO;
}

- (void)suspendLivePlaybackForReason:(NSString *)reason {
    BOOL hasLivePlayback=self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil||self.remoteAdapter!=nil||self.playbackReadiness!=nil||self.nativeRouteProbe!=nil||self.currentRemoteURL.length>0||self.remotePlaybackWanted;
    BOOL hasActivePlayback=hasLivePlayback||self.moviePlayer!=nil;
    if(!hasActivePlayback)return;
    NSString *engine=self.avPlayer?@"avplayer":(self.cicadaPlayer?@"cicada":(self.currentPlayer?@"cnplayersdk":(self.moviePlayer?@"avplayer_controller":@"pending")));
    self.playbackGeneration++;
    self.livePlaybackSuspendedForNavigation=hasLivePlayback;
    NSString *previousOwner=hasLivePlayback?@"live":@"vod";
    [RuntimeDiagnostics.shared recordEvent:hasLivePlayback?@"live_playback_suspended":@"playback_owner_released" category:@"playback" fields:@{@"reason":reason?:@"navigation",@"previous_owner":previousOwner,@"next_owner":@"none",@"engine":engine,@"previous_tab":@(self.activeTab),@"playback_generation":@(self.playbackGeneration),@"correlation_id":self.currentPlaybackTraceID?:@"",@"background_live_exception":@NO}];
    [self log:hasLivePlayback?@"离开直播页面，已暂停直播播放（%@）":@"已停止上一段视频播放（%@）",reason?:@"navigation"];
    [self stopPlayback];
    if(!hasLivePlayback)return;
    [self.spinner stopAnimating];
    self.titleLabel.hidden=NO;
    self.titleLabel.text=@"直播已暂停 · 返回后点继续播放";
    self.infoLabel.hidden=NO;
    self.infoLabel.text=@"直播与点播不会同时播放";
    self.playPauseBtn.enabled=YES;
    [self.playPauseBtn setTitle:@"继续播放" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];
    self.liveMiniPlayerLabel.text=[NSString stringWithFormat:@"直播已挂起 · %@",self.channelName.length?self.channelName:@"当前频道"];
    self.liveMiniPlayerBar.hidden=NO;
}

- (void)resumeSuspendedLiveFromMiniBar {
    self.liveMiniPlayerBar.hidden=YES;
    NSInteger targetTab=self.currentRemoteURL.length&&!self.nativePlainRouteActive?1:0;
    if(targetTab<self.bottomBar.arrangedSubviews.count)[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews[targetTab]];
    self.playerExpanded=YES;[self configureCatalogNavigation];[self.view setNeedsLayout];
    if(self.livePlaybackSuspendedForNavigation)[self togglePlayPause];
}

- (void)dismissSuspendedLiveMiniBar {
    self.livePlaybackSuspendedForNavigation=NO;
    self.liveMiniPlayerBar.hidden=YES;
}

- (void)configureLiveSleepTimerMinutes:(NSInteger)minutes {
    [self.liveSleepTimer invalidate];self.liveSleepTimer=nil;self.liveSleepMinutes=minutes;
    if(minutes<=0){[self log:@"已关闭直播睡眠定时"];return;}
    __weak typeof(self) weakSelf=self;
    self.liveSleepTimer=[NSTimer scheduledTimerWithTimeInterval:minutes*60.0 repeats:NO block:^(__unused NSTimer *timer){
        RootViewController *owner=weakSelf;if(!owner)return;owner.liveSleepTimer=nil;owner.liveSleepMinutes=0;
        [owner suspendLivePlaybackForReason:@"sleep_timer_expired"];
        owner.titleLabel.hidden=NO;owner.titleLabel.text=@"已按睡眠定时暂停直播";
    }];
    [self log:@"已开启直播睡眠定时：%ld 分钟",(long)minutes];
}

- (void)updateBottomBarSelection {
    NSArray<NSString *> *titles=@[@"央视",@"频道",@"影视",@"资源",@"设置"];
    for (UIButton *button in self.bottomBar.arrangedSubviews) {
        UIButtonConfiguration *configuration=button.configuration;
        BOOL selected=button.tag==self.activeTab;
        if(button.tag>=0&&button.tag<titles.count){configuration.title=titles[button.tag];__weak typeof(self) weakSelf=self;configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];RootViewController *owner=weakSelf;UITraitCollection *traits=owner?owner.traitCollection:UITraitCollection.currentTraitCollection;result[NSFontAttributeName]=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:traits];return result;};}
        configuration.baseForegroundColor=selected?HostOnAccent():HostMutedText();
        configuration.background.backgroundColor=selected?HostAccentFill():UIColor.clearColor;
        configuration.background.strokeColor=selected?[HostAccent() colorWithAlphaComponent:0.35]:UIColor.clearColor;
        configuration.background.strokeWidth=selected?0.5:0;
        button.configuration=configuration;
        button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);
        button.accessibilityValue=selected?@"已选中":@"未选中";
    }
}

- (void)selectBottomTab:(UIButton *)sender {
    self.catalogSearchGeneration++;
    [self stopPreview];
    if(self.activeTab!=sender.tag&&self.activeTab<2&&sender.tag>=2)[self suspendLivePlaybackForReason:@"left_live_interface"];
    if(!self.restoringLastTab&&self.activeTab<2){NSDictionary *state=@{@"query":self.query?:@"",@"group":@(self.groupControl.selectedSegmentIndex),@"gridY":@(self.channelGrid.contentOffset.y),@"listY":@(self.table.contentOffset.y),@"source":self.activeSource?:@"",@"catchup":@(self.catchupOnlyFilter),@"groupTitle":[self.groupControl titleForSegmentAtIndex:MAX(0,self.groupControl.selectedSegmentIndex)]?:@"",@"immersiveTopVersion":@1};self.catalogStates[@(self.activeTab)]=state;[[NSUserDefaults standardUserDefaults] setObject:state forKey:[NSString stringWithFormat:@"cctv.catalogState.%ld",(long)self.activeTab]];}
    if(self.restoringLastTab)[RuntimeDiagnostics.shared recordEvent:@"ui_session_tab_restored" category:@"lifecycle" fields:@{@"tab_index":@(sender.tag),@"automatic_content_load":@NO}];
    self.activeTab=sender.tag;
    // Unify 2026 Spatial Glass theme across all 5 tabs.
    self.navigationController.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(sender.tag<2)self.liveMiniPlayerBar.hidden=YES;
    [[NSUserDefaults standardUserDefaults] setInteger:self.activeTab forKey:@"cctv.lastBottomTab.v1"];
    [self updateBottomBarSelection];
    if([self.tabPage isKindOfClass:MediaBrowserViewController.class])[(MediaBrowserViewController *)self.tabPage saveSessionState];
    if(self.tabPage){[self.tabPage willMoveToParentViewController:nil];[self.tabPage.view removeFromSuperview];[self.tabPage removeFromParentViewController];self.tabPage=nil;}
    if(sender.tag==2){ [self openMediaTab]; }
    else if(sender.tag==3){ [self openConfigurationTab]; }
    else if(sender.tag==4){ SettingsViewController *page=(SettingsViewController *)self.tabPages[@4];if(!page){page=[self makeSettingsPage];self.tabPages[@4]=page;}[self showTabPage:page title:@"设置"]; }
    else {self.favoritesOnly=NO;self.recentsOnly=NO;if(sender.tag<2)self.subscriptionCatalog=sender.tag==1;[self syncGroupControlSegments];NSString *savedSource=self.catalogStates[@(sender.tag)][@"source"];self.activeSource=([self.subscriptionURLs containsObject:savedSource?:@""]||([savedSource hasPrefix:@"catalog:"]&&[TVBoxCatalogStore catalogForID:[savedSource substringFromIndex:8]]))?savedSource:nil;[self syncGroupControlSegments];self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];NSDictionary *state=self.catalogStates[@(sender.tag)];self.query=state[@"query"]?:@"";self.searchController.searchBar.text=self.query;NSInteger savedGroup=[state[@"group"] integerValue];
        self.catchupOnlyFilter=[state[@"catchup"] boolValue];
        NSArray *groupTitles=[self currentCatalogGroupTitles];
        if([state[@"groupTitle"] length]){NSUInteger match=[groupTitles indexOfObject:state[@"groupTitle"]];savedGroup=match==NSNotFound?0:(NSInteger)match;}self.groupControl.selectedSegmentIndex=(savedGroup>=0&&savedGroup<self.groupControl.numberOfSegments)?savedGroup:0;NSArray<NSString *> *titles=[self currentCatalogGroupTitles];NSString *segTitle=(self.groupControl.selectedSegmentIndex>=0&&self.groupControl.selectedSegmentIndex<(NSInteger)titles.count)?titles[self.groupControl.selectedSegmentIndex]:@"全部";self.favoritesOnly=[segTitle isEqualToString:@"收藏"];self.recentsOnly=[segTitle isEqualToString:@"最近"];[self configureCatalogNavigation];[self applyFilter];[self.view layoutIfNeeded];BOOL oldTopGeometry=[state[@"immersiveTopVersion"] integerValue]<1;CGFloat topInset=self.channelGrid.contentInset.top;CGFloat gridY=[state[@"gridY"] doubleValue],listY=[state[@"listY"] doubleValue];if(!state){gridY=-topInset;listY=-self.table.contentInset.top;}else if(oldTopGeometry){gridY-=topInset;listY-=self.table.contentInset.top;}self.channelGrid.contentOffset=CGPointMake(0,MAX(-topInset,gridY));self.table.contentOffset=CGPointMake(0,MAX(-self.table.contentInset.top,listY));
        if(sender.tag==1&&!self.channelID.length&&self.userInitiatedTabSelection&&!self.restoringLastTab)[self refreshSubscriptionsWhenIdle];}
    [self.view setNeedsLayout];
}
- (void)showTabPage:(UIViewController *)page title:(NSString *)title {
    BOOL media=[page isKindOfClass:MediaBrowserViewController.class];BOOL resource=[page isKindOfClass:ConfigCenterViewController.class];BOOL hideNavigation=media||resource;self.navigationItem.largeTitleDisplayMode=hideNavigation?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    if(self.navigationController.topViewController==self){
        self.navigationController.navigationBar.prefersLargeTitles=!hideNavigation;
        if(self.navigationController.navigationBarHidden!=hideNavigation)[self.navigationController setNavigationBarHidden:hideNavigation animated:NO];
    }
    CGFloat stableTop=HostStatusBarSafeTop(self.view,self.view.safeAreaInsets.top);
    if(resource)[(ConfigCenterViewController *)page setTopSafeAreaInset:stableTop];
    else if(media)[(MediaBrowserViewController *)page setTopSafeAreaInset:stableTop];
    page.view.frame=self.view.bounds;
    self.tabPage=page;if(page.parentViewController!=self){[self addChildViewController:page];[self.view addSubview:page.view];[page didMoveToParentViewController:self];}else if(page.view.superview!=self.view)[self.view addSubview:page.view];self.title=(media||resource)?@"":title;self.navigationItem.searchController=(media||resource)?nil:page.navigationItem.searchController;self.navigationItem.leftBarButtonItem=nil;
    self.navigationItem.rightBarButtonItems=(media||resource)?nil:page.navigationItem.rightBarButtonItems;self.resourceActionsButton.hidden=YES;[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];
}
- (MediaBrowserViewController *)mediaPageCreatingIfNeeded {
    MediaBrowserViewController *page=(MediaBrowserViewController *)self.tabPages[@2];
    if(!page){page=[MediaBrowserViewController new];__weak typeof(self) weakSelf=self;
        page.sourcesProvider=^{
            NSMutableArray *sources=[NSMutableArray array];
            for(NSDictionary *service in [ServiceStore services])if([ServiceStore isVODMediaService:service])[sources addObject:service];
            for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
                NSString *catalogID=catalog[@"id"]?:@"";
                NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
                for(NSDictionary *site in sites){
                    NSString *apiKind=[site[@"apiKind"] isKindOfClass:NSString.class]?site[@"apiKind"]:@"";
                    NSString *siteKey=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"";
                    if(!([apiKind isEqual:@"tvbox-api"]||[apiKind isEqual:@"maccms-api"]||[apiKind isEqual:@"douban-index"]||[apiKind isEqual:@"jar-bridge"])||![site[@"supported"] boolValue])continue;
                    NSString *protocol=apiKind,*siteID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalogID,siteKey];
                    NSString *type=site[@"type"]?:@"1";
                    NSString *effectiveAPI=site[@"api"]?:@"";
                    NSString *engine=[apiKind isEqual:@"maccms-api"]?@"MacCMS JSON/XML API":([apiKind isEqual:@"douban-index"]?@"豆瓣影视索引 · 原生适配":([apiKind isEqual:@"jar-bridge"]?@"JAR 站点 · 首次准备可能较慢":[NSString stringWithFormat:@"TVBox type %@ JSON API",type]));
                    NSArray *capabilities=[apiKind isEqual:@"douban-index"]?@[@"home",@"category",@"search"]:@[@"home",@"category",@"search",@"detail",@"play"];
                    NSMutableDictionary *source=[@{@"id":siteID,@"name":site[@"name"]?:@"影视来源",@"engine":engine,@"protocol":protocol,@"tvboxType":@([type integerValue]),@"api":effectiveAPI,@"url":effectiveAPI,@"options":site[@"ext"]?:@"",@"header":site[@"header"]?:@{},@"playUrl":site[@"playUrl"]?:@"",@"status":site[@"status"]?:@"可直接访问",@"catalogID":catalogID,@"catalogName":catalog[@"name"]?:@"资源合集",@"capabilities":capabilities,@"tvboxSiteKey":siteKey,@"tvboxSiteKeys":siteKey.length?@[siteKey]:@[]} mutableCopy];
                    MediaJARAttachSource(source,site,catalog);
                    [sources addObject:source];
                }
            }
            return sources;
        };
        page.catalogsProvider=^{return [TVBoxCatalogStore catalogs];};
        page.onOpenTVBoxCatalog=^(NSString *identifier){RootViewController *owner=weakSelf;if(owner)[owner openTVBoxCatalog:identifier];};
        page.onImportCatalogSite=^(NSDictionary *site,NSString *identifier){RootViewController *owner=weakSelf;if(!owner)return;NSMutableDictionary *scoped=[site mutableCopy];scoped[@"tvboxCatalogID"]=identifier;[owner importTVBoxSite:scoped browseAfterImport:YES];};
        page.onSubscribeCatalogLive=^(NSDictionary *live,NSString *identifier){RootViewController *owner=weakSelf;if(owner)[owner subscribeLiveFromCatalog:live catalogID:identifier];};
        __weak MediaBrowserViewController *weakPage=page;page.onDisplayModeChanged=^(BOOL homeMode){(void)homeMode;RootViewController *owner=weakSelf;MediaBrowserViewController *mediaPage=weakPage;if(!owner||!mediaPage||owner.activeTab!=2||owner.tabPage!=mediaPage)return;owner.title=@"";owner.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;owner.navigationItem.searchController=nil;owner.navigationItem.leftBarButtonItem=nil;owner.navigationItem.rightBarButtonItems=nil;if(owner.navigationController.topViewController==owner&&!owner.navigationController.navigationBarHidden)[owner.navigationController setNavigationBarHidden:YES animated:YES];};
        page.onActivateService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf changeService:service enabled:YES completion:completion];};
        page.onRestartService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf restartMediaService:service completion:completion];};
        page.onPlaybackWillStart=^{RootViewController *owner=weakSelf;if(owner)[owner suspendLivePlaybackForReason:@"vod_playback_starting"];};
        page.startupErrorProvider=^NSError *{return PyHost.startupError;};
        page.startupErrorForService=^NSError *(NSDictionary *service){return [PyHost startupErrorForServiceIdentifier:service[@"id"]];};
        page.onResources=^{RootViewController *owner=weakSelf;if(owner)[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[3]];};
        page.onPlay=^(NSDictionary *result,NSDictionary *context){RootViewController *owner=weakSelf;if(!owner)return;MediaPlaybackViewController *player=[MediaPlaybackViewController new];player.onPlaybackWillStart=^{RootViewController *strongOwner=weakSelf;if(strongOwner)[strongOwner suspendLivePlaybackForReason:@"vod_playback_starting"];};player.result=result;player.context=context;[owner.navigationController pushViewController:player animated:YES];};
        page.onSubscribeLive=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *url=[ServiceStore subscriptionURLForService:service];if(!url.length)for(NSString *candidate in owner.subscriptionURLs){NSDictionary *provider=[owner localServiceForURL:[NSURL URLWithString:candidate]];if([provider[@"id"] isEqual:service[@"id"]]){url=candidate;break;}}if(!url.length){[owner openServiceEditorForService:service];return;}NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:url][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:url values:metadata];if(![owner.subscriptionURLs containsObject:url]){[owner.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:owner.subscriptionURLs.allObjects forKey:@"subscriptions"];}[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[1]];owner.activeSource=url;owner.title=@"订阅直播";[owner fetchSubscription:url silent:NO];};
        self.tabPages[@2]=page;
    }
    return page;
}
- (void)openMediaTab {
    BOOL created=self.tabPages[@2]==nil;MediaBrowserViewController *page=[self mediaPageCreatingIfNeeded];
    [self showTabPage:page title:@""];
    if(page.onDisplayModeChanged)page.onDisplayModeChanged(page.isHomeMode);
    if(!created)[page refreshSources];
}
- (void)playerViewController:(AVPlayerViewController *)controller willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(controller==self.movieController && !self.moviePiPActive)[self.moviePlayer pause];}];
}
- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController)self.moviePiPActive=YES;}
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController){self.moviePiPActive=NO;if(!controller.presentingViewController)[self.moviePlayer pause];}}
- (void)openConfigurationTab {
    ConfigCenterViewController *page=(ConfigCenterViewController *)self.tabPages[@3];
    if(!page){page=[ConfigCenterViewController new];__weak typeof(self) w=self;
        page.profilesProvider=^{return [(id)w configurationProfiles];};page.onServices=^{[w openServicesPage];};page.onAdd=^{[w addSubscription];};page.importTaskSummaryProvider=^{return w.resourceImportWorkflow.taskSummary;};page.onRefresh=^{[w onPullRefresh];};page.onRefreshProfile=^(NSString *source){[w refreshSubscriptionForProfile:source];};page.onRecheckProfile=^(NSString *source){[w recheckProfileHealth:source];};page.onRematchEPGProfile=^(NSString *source){[w rematchEPGForProfile:source];};page.onRestartProfile=^(NSString *source){NSDictionary *service=[w resourceServiceForSource:source];if(!service)return;[w restartMediaService:service completion:^(NSError *error){if(error)[w showServiceError:error.localizedDescription];}];};page.onRefreshCatalogProfile=^(NSString *source){[w refreshTVBoxCatalogProfile:source];};
        page.onRefreshMediaHome=^{RootViewController *owner=w;if(!owner)return;[owner selectBottomTab:(UIButton *)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser returnToHomeFromNavigation];dispatch_async(dispatch_get_main_queue(),^{if(![browser refreshHomeContentFromResourcePage])[owner showServiceError:@"没有可加载的影视资源。请先导入并启用一个影视来源。"] ;});};
        page.onToggleProfile=^(NSString *source,BOOL enabled){NSDictionary *service=[w resourceServiceForSource:source];if(service){[w toggleService:service enabled:enabled];return;}if(!source.length)[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"nativeChannelsEnabled"];else{NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabled removeObject:source];if(!enabled)[disabled addObject:source];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}[w applyFilter];[w updateLiveResourceCapsule];};
        page.onToggleChannelLogo=^(NSString *source,BOOL enabled){[w applyResourceChannelLogoToggleForSource:source enabled:enabled cornerOnly:NO];};
        page.onTogglePlayerCornerLogo=^(NSString *source,BOOL enabled){[w applyResourceChannelLogoToggleForSource:source enabled:enabled cornerOnly:YES];};
        page.onToggleChannelPreview=^(NSString *source,BOOL enabled){[w applyResourcePreviewOrTelemetryToggleForSource:source enabled:enabled isPreview:YES];};
        page.onToggleChannelTelemetry=^(NSString *source,BOOL enabled){[w applyResourcePreviewOrTelemetryToggleForSource:source enabled:enabled isPreview:NO];};
        page.onMatchStationLogos=^(NSString *source){[w matchOfficialStationLogosAndEPGForSource:source];};
        page.onOpenResource=^(NSString *source){[w openPluginResource:source];};page.onOpenSubscription=^(NSString *source){[w openSubscriptionProfile:source editing:NO];};
        page.onUseResource=^(NSString *source,NSString *kind){NSDictionary *service=[w resourceServiceForSource:source];if(!service)return;if([kind isEqual:@"choose"]){NSArray<HostGlassSheetAction *> *acts=@[[HostGlassSheetAction actionWithTitle:@"进入影视" subtitle:@"启动脚本服务并进入点播影视库" value:nil icon:@"film.stack" tint:HostAccent() destructive:NO selected:NO handler:^{[w usePluginService:service kind:@"vod"];}],[HostGlassSheetAction actionWithTitle:@"添加直播频道" subtitle:@"拉取该资源提供的直播频道列表" value:nil icon:@"tv" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{[w usePluginService:service kind:@"live"];}],[HostGlassSheetAction actionWithTitle:@"资源详情与设置" subtitle:@"查看接口、端口、健康状态与日志" value:nil icon:@"slider.horizontal.3" tint:HostSecondaryText() destructive:NO selected:NO handler:^{[w openPluginResource:source];}]];[HostGlassActionSheetViewController presentOn:w title:(service[@"name"]?:@"选择资源用途") subtitle:@"这个资源同时提供影视与直播能力。" badgeText:@"复合资源" badgeColor:HostAccent() sections:@[[HostGlassSheetSection sectionWithTitle:@"打开方式" actions:acts]] sourceView:w.view];return;}[w usePluginService:service kind:kind];};
        page.onOpenTVBoxCatalog=^(NSString *identifier){[w openTVBoxCatalog:identifier];};
        page.onExportResource=^(NSString *source,NSString *format){[w exportResource:source format:format];};
        page.onSelectProfile=^(NSString *source){UIButton *b=(UIButton *)w.bottomBar.arrangedSubviews[source.length?1:0];[w selectBottomTab:b];w.activeSource=source;w.title=source.length?@"订阅直播":@"央视直播";[w applyFilter];[w updateLiveResourceCapsule];};
        page.onEditProfile=^(NSString *source){NSDictionary *service=[w resourceServiceForSource:source];if(service)[w openServiceEditorForService:service];else[w editProfile:source];};
        page.onDeleteProfile=^(NSString *source){if([source hasPrefix:@"tvbox:"]){[TVBoxCatalogStore removeCatalog:[source substringFromIndex:6]];[w refreshConfigurationPage];return;}NSDictionary *service=[w resourceServiceForSource:source];if(service){if([PyHost isManagedServiceIdentifier:service[@"id"]]){[w showServiceError:@"该资源仍有运行或待清理会话，请先停止"];return;}[ServiceStore remove:service[@"id"]];}else[w deleteSubscription:source];};
        self.tabPages[@3]=page;
    }
    [self showTabPage:page title:@"资源"];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGFloat top = safe.top;
    BOOL expandedLive=[self isExpandedLivePlayerVisible];
    if (self.fullscreen) {
        self.playerBox.frame = self.view.bounds;
        self.liveResourceCapsule.hidden=YES;
        self.bottomBar.hidden = YES;
        self.bottomBarBackdrop.hidden = YES;
        self.resourceActionsButton.hidden=YES;
        self.catalogFloatingControls.hidden=YES;
        self.table.hidden=YES;
        self.channelGrid.hidden=YES;
        self.groupControl.hidden=YES;
        self.catalogGroupGlassCard.hidden=YES;
        self.catalogTopImmersiveScrim.hidden=YES;
        self.liveMiniPlayerBar.hidden=YES;
        self.playerTabs.hidden=YES;
        self.playbackPanel.view.hidden=YES;
        self.tabPage.view.hidden=YES;
    } else {
        BOOL catalog=self.activeTab<2;
        CGFloat capsuleRowHeight=expandedLive?44:0;
        CGFloat playerTop=expandedLive?top+capsuleRowHeight:0;
        CGFloat ph=expandedLive?MIN(w*9.0/16.0,MAX(120,(height-safe.bottom-playerTop)*0.50)):0;
        self.playerBox.frame=CGRectMake(0,playerTop,w,ph);self.playerBox.hidden=!catalog||!expandedLive;
        self.liveResourceCapsule.hidden=!catalog||!expandedLive;
        if(!self.liveResourceCapsule.hidden){CGFloat maximumWidth=MAX(0,w-safe.left-safe.right-28);CGFloat naturalWidth=[self.liveResourceCapsule sizeThatFits:CGSizeMake(maximumWidth,36)].width;CGFloat capsuleWidth=MIN(maximumWidth,MIN(270,MAX(150,naturalWidth)));self.liveResourceCapsule.frame=CGRectMake(safe.left+14,top+4,capsuleWidth,36);}
        CGFloat playerBottom=expandedLive?playerTop+ph:top;
        CGFloat y=playerBottom;
        // 大字体下分段标题行高会超过 32pt 固定高度而被裁：按缩放后行高给高度。
        UIFont *segmentFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
        CGFloat segmentHeight=MAX(32,ceil(segmentFont.lineHeight)+14);
        self.groupControl.frame=CGRectMake(12,y+6,w-24,segmentHeight);self.groupControl.hidden=!catalog||expandedLive;self.playerTabs.frame=CGRectMake(12,y+6,w-24,segmentHeight);self.playerTabs.hidden=!catalog||!expandedLive;
        self.versionLabel.hidden=YES;
        UIFont *tabLabelFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];CGFloat tabHeight=MAX(58,ceil(20+3+tabLabelFont.lineHeight+16)),dockWidth=MIN(MAX(0,w-20),540),dockX=MAX(10,(w-dockWidth)/2),tabY=MAX(0,height-safe.bottom-tabHeight),tabContentInset=MAX(8,height-tabY+8);self.bottomBarBackdrop.frame=CGRectMake(0,tabY,w,MAX(tabHeight,height-tabY));self.bottomDockFadeGradient.frame=self.bottomBarBackdrop.bounds;self.bottomDockGlass.frame=CGRectMake(dockX,2,dockWidth,tabHeight-4);self.bottomDockGlass.layer.cornerRadius=(tabHeight-4)/2;self.bottomBar.frame=CGRectMake(dockX+4,tabY+2,MAX(0,dockWidth-8),tabHeight-4);self.bottomBar.layer.cornerRadius=(tabHeight-4)/2;self.bottomBar.hidden=NO;self.bottomBarBackdrop.hidden=NO;
        BOOL showMiniBar=self.livePlaybackSuspendedForNavigation&&self.channelID.length&&self.activeTab>=2;self.liveMiniPlayerBar.hidden=!showMiniBar;if(showMiniBar){CGFloat miniW=MIN(w-28,520),miniH=42;self.liveMiniPlayerBar.frame=CGRectMake((w-miniW)/2,MAX(top+8,tabY-miniH-8),miniW,miniH);self.liveMiniPlayerCloseButton.frame=CGRectMake(miniW-38,5,32,32);self.liveMiniPlayerResumeButton.frame=CGRectMake(miniW-130,5,88,32);self.liveMiniPlayerLabel.frame=CGRectMake(14,0,MAX(0,miniW-150),miniH);}
        CGFloat contentY=y+6+segmentHeight+4;CGFloat contentBottom=height;CGFloat catalogBottomInset=tabContentInset+62;
        CGFloat floatingPillExtra=catalog?18:0;
        CGRect frame=CGRectMake(0,0,w,MAX(0,contentBottom));UIEdgeInsets catalogInsets=UIEdgeInsetsMake(contentY,0,catalogBottomInset+floatingPillExtra,0);CCTVApplyImmersiveScrollGeometry(self.table,frame,catalogInsets);CCTVApplyImmersiveScrollGeometry(self.channelGrid,frame,catalogInsets);
        self.table.hidden=!catalog||self.gridMode||self.playbackPanel!=nil;self.channelGrid.hidden=!catalog||!self.gridMode||self.playbackPanel!=nil;self.playbackPanel.view.frame=[self.playbackPanel isKindOfClass:CCTVPlaybackListPanelController.class]?frame:CGRectMake(0,contentY,w,MAX(0,contentBottom-contentY));self.playbackPanel.view.hidden=!catalog;if([self.playbackPanel isKindOfClass:CCTVPlaybackListPanelController.class]){UITableView *panelTable=((CCTVPlaybackListPanelController *)self.playbackPanel).tableView;CCTVApplyImmersiveScrollGeometry(panelTable,panelTable.frame,catalogInsets);}else if([self.playbackPanel isKindOfClass:EPGViewController.class]){UITableView *epgTable=[self.playbackPanel valueForKey:@"table"];if([epgTable isKindOfClass:UITableView.class])epgTable.contentInset=UIEdgeInsetsMake(0,0,catalogBottomInset,0);}
        // Every tab page owns the full root bounds. Child controls use their
        // safe-area guides, while their backgrounds and scroll views can pass
        // behind the status and navigation bars.
        BOOL resourcePage=[self.tabPage isKindOfClass:ConfigCenterViewController.class];CGFloat pageTop=0;CGFloat pageBottomInset=tabContentInset+(showMiniBar?50:0);self.tabPage.view.frame=CGRectMake(0,pageTop,w,MAX(0,contentBottom-pageTop));if(resourcePage){[(ConfigCenterViewController *)self.tabPage setTopSafeAreaInset:top];[(ConfigCenterViewController *)self.tabPage setBottomOverlayInset:pageBottomInset];}else if([self.tabPage isKindOfClass:MediaBrowserViewController.class]){[(MediaBrowserViewController *)self.tabPage setTopSafeAreaInset:top];[(MediaBrowserViewController *)self.tabPage setBottomOverlayInset:pageBottomInset];}else if([self.tabPage isKindOfClass:SettingsViewController.class])[(SettingsViewController *)self.tabPage setBottomOverlayInset:pageBottomInset];
        self.catalogTopImmersiveScrim.hidden=!catalog||expandedLive;
        self.catalogGroupGlassCard.hidden=!catalog||expandedLive;
        if(!self.catalogTopImmersiveScrim.hidden){
            UIScrollView *activeScroll=self.gridMode?(UIScrollView *)self.channelGrid:(UIScrollView *)self.table;
            CGFloat scrollProgress=MIN(1.0,MAX(0.0,(activeScroll.contentOffset.y+contentY)/96.0));
            HostUpdateImmersiveTopScrim(self.catalogTopImmersiveScrim,self.catalogTopImmersiveGradient,CGRectMake(0,0,w,contentY+14),scrollProgress,NO);
            self.catalogGroupGlassCard.frame=CGRectInset(self.groupControl.frame,-2,-2);
        }
        self.playerTopScrim.frame=CGRectMake(0,0,w,MIN(CGRectGetHeight(self.playerBox.bounds),expandedLive?48:top+24));self.playerTopGradient.frame=self.playerTopScrim.bounds;
        [self.view bringSubviewToFront:self.catalogTopImmersiveScrim];[self.view bringSubviewToFront:self.catalogGroupGlassCard];[self.view bringSubviewToFront:self.playerBox];[self.view bringSubviewToFront:self.liveResourceCapsule];[self.view bringSubviewToFront:self.groupControl];[self.view bringSubviewToFront:self.playerTabs];[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];if(showMiniBar)[self.view bringSubviewToFront:self.liveMiniPlayerBar];
        self.resourceActionsButton.hidden=YES;self.resourceActionsButton.frame=CGRectMake(w-safe.right-18-58,CGRectGetMinY(self.bottomBar.frame)-12-58,58,58);
        self.catalogFloatingControls.hidden=!catalog;CGFloat controlsWidth=164,controlsHeight=54;self.catalogFloatingControls.frame=CGRectMake(MAX(12,w-safe.right-controlsWidth-14),MAX(top+8,tabY-controlsHeight-12),controlsWidth,controlsHeight);self.catalogLayoutButton.frame=CGRectMake(4,3,48,48);self.catalogFloatingAirPlayPicker.frame=CGRectMake(58,3,48,48);self.catalogMoreButton.frame=CGRectMake(112,3,48,48);[self.view bringSubviewToFront:self.catalogFloatingControls];
    }
    UIEdgeInsets overlayInsets=[self playerOverlayInsets];
    CGFloat overlayTop=overlayInsets.top;
    CGFloat playerTitleHeight = ceil(self.titleLabel.font.lineHeight);
    CGFloat playerInfoHeight = ceil(self.infoLabel.font.lineHeight);
    self.titleLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8, MAX(0, w - safe.left - safe.right - 80), playerTitleHeight);
    self.infoLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8 + playerTitleHeight + 2, MAX(0, w - safe.left - safe.right - 24), playerInfoHeight);
    self.playerChannelLogo.frame=CGRectMake(MAX(safe.left+12,w-safe.right-60),overlayTop+8,48,27);
    CGFloat bottom = overlayInsets.bottom;
    CGFloat bottomScrimH = MIN(CGRectGetHeight(self.playerBox.bounds), bottom + 68);
    self.playerBottomScrim.frame = CGRectMake(0, MAX(0, CGRectGetHeight(self.playerBox.bounds) - bottomScrimH), w, bottomScrimH);
    self.playerBottomGradient.frame = self.playerBottomScrim.bounds;
    self.controlBar.frame = CGRectMake(8 + safe.left, CGRectGetHeight(self.playerBox.bounds) - bottom - 52,
                                      MAX(0, w - safe.left - safe.right - 16), 44);
    self.spinner.center=CGPointMake(CGRectGetMidX(self.playerBox.bounds),CGRectGetMidY(self.playerBox.bounds));
    self.avLayer.frame = self.playerBox.bounds;
    [self attachVideoView];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostStyleNavigation(self.navigationController);
        HostRefreshAppearanceLayers(self.view.window);
    }
    if(previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self applyFontSizeOverride];
        [self updatePlaybackControlAccessibility];
        [self updateBottomBarSelection];
        [self.channelGrid.collectionViewLayout invalidateLayout];
        [self.channelGrid reloadData];
        [self.table reloadData];
        [self.view setNeedsLayout];
    }
}

- (void)toggleFullscreen {
    self.fullscreen = !self.fullscreen;
    NSString *title=self.fullscreen?@"退出全屏":@"全屏";[self.fullscreenBtn setTitle:title forState:UIControlStateNormal];NSString *symbol=self.fullscreen?@"arrow.down.right.and.arrow.up.left":@"arrow.up.left.and.arrow.down.right";[self.fullscreenBtn setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];self.fullscreenBtn.accessibilityLabel=title;self.fullscreenBtn.accessibilityHint=self.fullscreen?@"返回频道播放页面":@"全屏显示当前频道";
    if (self.fullscreen) {
        // 防御：播放器可能在非展开态被隐藏，全屏时必须可见；具体布局由
        // viewDidLayoutSubviews 接管（全屏分支给 playerBox 全屏 frame）。
        self.playerBox.hidden=NO;
    } else {
        self.tabPage.view.hidden=NO;
    }
    [self configureCatalogNavigation];
    [self updatePlaybackControlAccessibility];
    [self setNeedsStatusBarAppearanceUpdate];
    [self.view setNeedsLayout];
    [self relayoutPlayer];
    [self attachVideoView];
    self.avLayer.frame = self.playerBox.bounds;
}

- (void)relayoutPlayer {
    // 标题/信息/controlBar 的 frame 由 viewDidLayoutSubviews 在 overlayTop/
    // overlayInsets 算出后统一写，这里只保留 spinner 居中（toggleFullscreen
    // 路径下 setNeedsLayout 尚未执行时也需要它）。
    CGRect b = self.playerBox.bounds;
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height / 2);
}

#pragma mark - 内置插件

- (void)openServicesPage {
    ServicesViewController *page=[ServicesViewController new];
    __weak typeof(self) weakSelf=self;
    page.onOpenYSP=^{ [weakSelf openPluginPage]; };
    page.onOpenResource=^(NSDictionary *service){[weakSelf openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]?:@""]];};
    page.onToggleService=^(NSDictionary *service,BOOL enabled){[weakSelf toggleService:service enabled:enabled];};
    page.onChangeService=^(NSDictionary *service,BOOL enabled,void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner changeService:service enabled:enabled completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{NSLocalizedDescriptionKey:@"页面已关闭"}]);};
    page.onRestartService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf restartMediaService:service completion:completion];};
    page.onApplyService=^(NSDictionary *previousService,NSDictionary *updatedService,void (^completion)(NSError * _Nullable)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previousService to:updatedService completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    page.onBrowseService=^(NSDictionary *service){[NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"selectedMediaSource"];[weakSelf.navigationController popToViewController:weakSelf animated:NO];[weakSelf selectBottomTab:(id)weakSelf.bottomBar.arrangedSubviews[2]];};
    page.onImportResource=^{[weakSelf addSubscription];};
    page.onOpenLog=^(NSDictionary *service){if(service)[weakSelf openDiagnosticLogForIdentifier:service[@"id"] name:service[@"name"]];else[weakSelf openDiagnosticLog];};
    page.onSubscribe=^(NSString *url){RootViewController *owner=weakSelf;NSString *key=[owner stableURLKey:url];if(!owner||!key.length)return;NSDictionary *service=[owner localServiceForURL:[NSURL URLWithString:key]];if(service){NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:key][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:key values:metadata];}if(![owner.subscriptionURLs containsObject:key]){[owner.subscriptionURLs addObject:key];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:owner.subscriptionURLs.allObjects] forKey:@"subscriptions"];}if(service&&![PyHost isRunningServiceIdentifier:service[@"id"]]){[owner changeService:service enabled:YES completion:^(NSError *error){if(error){[owner showServiceError:error.localizedDescription];return;}[owner fetchSubscription:key silent:NO];}];}else[owner fetchSubscription:key silent:NO];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)openPluginPage {
    PluginViewController *page = [PluginViewController new];
    self.pluginPage = page;
    __weak typeof(self) weakSelf = self;
    page.onStart = ^{ [weakSelf startBuiltinPlugin]; };
    page.onStop = ^{ [weakSelf stopBuiltinPlugin]; };
    page.onAddSubscription = ^{ [weakSelf addSubscription]; };
    page.onManageSubscriptions = ^{ [weakSelf manageSubscriptions]; };
    NSDictionary *builtinService=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){builtinService=service;break;}
    NSString *builtinID=[builtinService[@"id"] copy],*builtinName=[builtinService[@"name"] copy];
    page.onOpenLog = ^{[weakSelf openDiagnosticLogForIdentifier:builtinID name:builtinName];};
    page.onRestart=^(void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(!owner){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{NSLocalizedDescriptionKey:@"服务页面已关闭，重启未完成。"}]);return;}NSDictionary *current=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:builtinID]){current=service;break;}if(!current){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:1 userInfo:@{NSLocalizedDescriptionKey:@"找不到 YSP Live 服务，请从资源页重新导入。"}]);return;}[owner restartMediaService:current completion:completion];};
    page.subscriptionCountProvider=^{return weakSelf.subscriptionURLs.count;};
    [page updateRunning:(builtinID.length&&[PyHost isRunningServiceIdentifier:builtinID]) subscriptionCount:self.subscriptionURLs.count];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)openSettingsPage {
    [self.navigationController pushViewController:[self makeSettingsPage] animated:YES];
}

// 应用内字号：以系统字号为基准上调 0/1/2 档。覆盖写在 RootViewController 上后，
// 以系统字号为基准上调 0/1/2 档。基准必须取自未被覆盖的字号：
// window 自身的 trait 不受本控制器上写的覆盖影响；viewDidLoad 时
// view 尚未进 window，取启动时快照的系统档位。切忌用 self.traitCollection
// 作基准——它已被上次覆盖改写，每次重算都在已上调的档位上再上调，
// “大”和“特大”都会顶到最大档。超出范围时按最大档截断。
- (UITraitCollection *)fontSizeOverrideTraitCollection {
    NSInteger offset=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.appFontSize.v1"]?[[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.appFontSize.v1"]:0;
    NSArray<NSString *> *ordered=@[UIContentSizeCategoryExtraSmall,UIContentSizeCategorySmall,UIContentSizeCategoryMedium,UIContentSizeCategoryLarge,UIContentSizeCategoryExtraLarge,UIContentSizeCategoryExtraExtraLarge,UIContentSizeCategoryExtraExtraExtraLarge];
    // 基准取 iOS 系统字号（屏幕 trait，不受本控制器覆盖影响，且 view 未进
    // window 时也能取到）；不能取 self.traitCollection（已被覆盖）或
    // self.view.window（view 未进 window 时为 nil）。默认标准档（0）比系统基准精致收紧一档；
    // 无障碍大字号（index == NSNotFound）保持系统原样不干预。
    NSString *baseCategory=[UIScreen mainScreen].traitCollection.preferredContentSizeCategory;
    if(!baseCategory.length)return nil;
    NSInteger index=[ordered indexOfObject:baseCategory];
    if(index==NSNotFound)return nil;
    NSInteger stepped=(offset<=0)?MAX(0,index-1):MIN((NSInteger)ordered.count-1,index+offset);
    return [UITraitCollection traitCollectionWithPreferredContentSizeCategory:ordered[stepped]];
}
- (void)applyFontSizeOverride {
    UITraitCollection *override=[self fontSizeOverrideTraitCollection];
    if(self.navigationController)[self.navigationController setOverrideTraitCollection:override forChildViewController:self];
    UIViewController *top=self.navigationController.topViewController;
    if(top&&top!=self)[self.navigationController setOverrideTraitCollection:override forChildViewController:top];
    for(UIViewController *child in self.childViewControllers){[self setOverrideTraitCollection:override forChildViewController:child];}
    for(UIViewController *page in self.tabPages.allValues){if(page.parentViewController==self)[self setOverrideTraitCollection:override forChildViewController:page];}
    [self.table reloadData];[self.channelGrid reloadData];
}
- (void)updateLiveScreenAwakeState {
    BOOL isPlaying=self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil||self.remoteAdapter!=nil;
    BOOL keepAwake=isPlaying && CCTVBoolPreference(@"cctv.mediaKeepScreenAwake",YES);
    if(self.activeTab<2){
        UIApplication.sharedApplication.idleTimerDisabled=keepAwake;
    }
}
- (void)reloadThemeAppearance {
    UIUserInterfaceStyle targetStyle=HostSelectedInterfaceStyle();
    self.overrideUserInterfaceStyle=targetStyle;
    self.view.overrideUserInterfaceStyle=targetStyle;
    self.navigationController.overrideUserInterfaceStyle=targetStyle;
    self.navigationController.navigationBar.overrideUserInterfaceStyle=targetStyle;
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    self.bottomBar.tintColor=HostAccent();
    self.bottomBarBackdrop.backgroundColor=UIColor.clearColor;
    UIColor *resolvedBg=[HostBackground() resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:targetStyle]];
    self.bottomDockFadeGradient.colors=@[(id)[resolvedBg colorWithAlphaComponent:0.0].CGColor,(id)[resolvedBg colorWithAlphaComponent:0.78].CGColor,(id)[resolvedBg colorWithAlphaComponent:0.96].CGColor];
    self.bottomDockGlass.effect=HostGlassBlur();
    self.bottomDockGlass.contentView.backgroundColor=UIAccessibilityIsReduceTransparencyEnabled()?HostCard():UIColor.clearColor;
    HostSetLayerBorderColor(self.bottomDockGlass,HostBorder());
    self.catalogFloatingAirPlayPicker.activeTintColor=HostAccent();
    self.groupControl.tintColor=HostAccent();
    self.groupControl.selectedSegmentTintColor=HostAccentFill();
    self.playerTabs.selectedSegmentTintColor=HostAccentFill();
    [self updateLiveResourceCapsule];
    for(NSInteger i=0;i<self.bottomBar.arrangedSubviews.count;i++){
        UIButton *b=(UIButton *)self.bottomBar.arrangedSubviews[i];
        BOOL selected=i==self.activeTab;
        b.selected=selected;
        UIButtonConfiguration *cfg=b.configuration;
        cfg.baseForegroundColor=selected?HostOnAccent():HostMutedText();
        cfg.background.backgroundColor=selected?HostAccentFill():UIColor.clearColor;
        cfg.background.strokeColor=selected?[HostAccent() colorWithAlphaComponent:0.35]:UIColor.clearColor;
        b.configuration=cfg;
    }
    HostStyleNavigation(self.navigationController);
    [self setNeedsStatusBarAppearanceUpdate];
    [self.table reloadData];
    [self.channelGrid reloadData];
    [self.view setNeedsLayout];
    UIWindow *window=self.view.window;
    if(window)HostRefreshAppearanceLayers(window);
    for(UIViewController *child in self.childViewControllers){
        if([child respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[child methodForSelector:@selector(reloadThemeAppearance)])(child, @selector(reloadThemeAppearance));
        }
    }
    for(UIViewController *page in self.tabPages.allValues){
        if((page.parentViewController==self || page.isViewLoaded) && [page respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[page methodForSelector:@selector(reloadThemeAppearance)])(page, @selector(reloadThemeAppearance));
        }
    }
    for(UIViewController *vc in self.navigationController.viewControllers){
        if(vc!=self && vc.isViewLoaded && [vc respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[vc methodForSelector:@selector(reloadThemeAppearance)])(vc, @selector(reloadThemeAppearance));
        }
    }
    if(self.resourceImportWorkflow && self.resourceImportWorkflow.isViewLoaded && [self.resourceImportWorkflow respondsToSelector:@selector(reloadThemeAppearance)]){
        [self.resourceImportWorkflow reloadThemeAppearance];
    }
}
- (SettingsViewController *)makeSettingsPage {
    SettingsViewController *page=[SettingsViewController new];
    __weak typeof(self) weakSelf=self;
    page.onExportData=^{[weakSelf exportLocalConfiguration];};page.onImportData=^{[weakSelf importLocalConfiguration];};page.onOpenLog=^{[weakSelf openDiagnosticLog];};
    page.onOpenDiagnostics=^{[weakSelf.navigationController pushViewController:[[RuntimeDiagnosticsViewController alloc] initWithSessionID:nil] animated:YES];};
    page.onMediaDisplaySettings=^{RootViewController *owner=weakSelf;if(!owner)return;MediaBrowserViewController *browser=[owner mediaPageCreatingIfNeeded];UIViewController *configuration=[browser mediaDisplaySettingsViewController];if(configuration)[owner.navigationController pushViewController:configuration animated:YES];};
    page.onClearEPG=^{ [[XMLTVStore shared] clear];[weakSelf.epgCache removeAllObjects]; [weakSelf saveEPGCache]; [weakSelf.table reloadData]; };
    page.onClearWatchHistory=^{[weakSelf.recents removeAllObjects];[HostLibraryStore.shared clearRecents];[weakSelf applyFilter];};
    page.onClearFavorites=^{[weakSelf.favorites removeAllObjects];[HostLibraryStore.shared replaceFavorites:@[]];[weakSelf configureCatalogNavigation];[weakSelf applyFilter];};
    page.onOpenTab=^(NSInteger tab){if(tab<0||tab>=weakSelf.bottomBar.arrangedSubviews.count)return;[weakSelf selectBottomTab:(UIButton *)weakSelf.bottomBar.arrangedSubviews[tab]];};
    page.onOpenServices=^{[weakSelf openServicesPage];};
    page.onIntegerPreferenceChanged=^(NSString *key, NSInteger value){
        if([key isEqualToString:@"cctv.channelGridColumns.v1"]){weakSelf.gridColumns=value==3?3:4;[weakSelf configureCatalogNavigation];[weakSelf.channelGrid.collectionViewLayout invalidateLayout];[weakSelf.channelGrid reloadData];[weakSelf.view setNeedsLayout];}
        if([key isEqualToString:@"cctv.channelSortMode.v1"]){weakSelf.channelSortMode=MIN(2,MAX(0,value));[weakSelf configureCatalogNavigation];[weakSelf applyFilter];}
        if([key isEqualToString:@"cctv.mediaGridColumns.v1"]||[key isEqualToString:@"cctv.mediaEpisodeLayoutStyle.v1"]){MediaBrowserViewController *browser=(MediaBrowserViewController *)weakSelf.tabPages[@2];if(browser)[browser reloadMediaDisplayConfigurationIfLoaded];[NSNotificationCenter.defaultCenter postNotificationName:@"MediaDisplayConfigurationDidChangeNotification" object:nil];[NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];}
        if([key isEqualToString:@"cctv.appFontSize.v1"]){[weakSelf applyFontSizeOverride];}
    };
    page.onPreferenceChanged=^(NSString *key, BOOL value){
        if([key isEqualToString:HostDarkThemePreferenceKey]||[key isEqualToString:HostThemeModePreferenceKey]||[key isEqualToString:HostThemePaletteIdentifierPreferenceKey]){
            UIWindow *window=weakSelf.view.window;
            HostApplyThemeToWindow(window);
            [weakSelf reloadThemeAppearance];
            dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostStyleNavigation(weakSelf.navigationController);HostRefreshAppearanceLayers(window);});
        }
        if ([key isEqualToString:@"runtimeDiagnosticsEnabled"]) [RuntimeDiagnostics.shared setEnabled:value];
        if ([key isEqualToString:@"nativeSDKVerboseLogs"]) [weakSelf configureSDKLogging];
        if ([key isEqualToString:@"preloadNativeChannel"]) { if (!value) [weakSelf.nativePreloader cancel]; else [weakSelf prepareNextNativeChannelForGeneration:weakSelf.playbackGeneration]; }
        if ([key isEqualToString:@"legacyNativePlayback"] && !value && weakSelf.sdkPlayer && weakSelf.sdkPlayer != weakSelf.currentPlayer) { [weakSelf call:weakSelf.sdkPlayer sel:@"reset"]; weakSelf.sdkPlayer = nil; weakSelf.sdkPlayerUsed = NO; }
        if (([key isEqualToString:@"rememberLastChannel"] || [key isEqualToString:@"resumeLastChannel"]) && value && weakSelf.channelID.length) { NSDictionary *ch = [weakSelf channelWithID:weakSelf.channelID]; if (ch) [NSUserDefaults.standardUserDefaults setObject:ch forKey:@"lastChannel"]; }
        if ([key isEqualToString:@"cctv.mediaPreferredQuality.v1"] && weakSelf.avPlayer.currentItem) {
            NSString *pref = [[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"] ?: @"auto";
            double peak = [pref isEqualToString:@"smooth"] ? 1500000 : ([pref isEqualToString:@"hd"] ? 4000000 : ([pref isEqualToString:@"uhd"] ? 8000000 : 0));
            weakSelf.avPlayer.currentItem.preferredPeakBitRate = peak;
        }
        if ([key isEqualToString:@"allowBackgroundAudio"]) [weakSelf activateAudioSession];
        if ([key isEqualToString:@"autoLoadEPG"]) { [weakSelf.epgTimer invalidate]; weakSelf.epgTimer=nil; weakSelf.epgRefreshDesired=value;if(value) [weakSelf restartEPGTimer]; else weakSelf.infoLabel.text=@"节目单自动获取已关闭"; }
        if ([key isEqualToString:@"nativeChannelsEnabled"]) { [weakSelf configureCatalogNavigation]; [weakSelf applyFilter]; [weakSelf updateLiveResourceCapsule]; }
        if ([key isEqualToString:@"nativeChannelLogoEnabled"]) { [weakSelf applyResourceChannelLogoToggleForSource:@"builtin:cctv" enabled:value cornerOnly:NO]; }
        if ([key isEqualToString:@"nativePlayerCornerLogoEnabled"]) { [weakSelf applyResourceChannelLogoToggleForSource:@"builtin:cctv" enabled:value cornerOnly:YES]; }
        if ([key isEqualToString:@"nativeChannelPreviewEnabled"]) { [weakSelf applyResourcePreviewOrTelemetryToggleForSource:@"builtin:cctv" enabled:value isPreview:YES]; }
        if ([key isEqualToString:@"nativeChannelTelemetryEnabled"]) { [weakSelf applyResourcePreviewOrTelemetryToggleForSource:@"builtin:cctv" enabled:value isPreview:NO]; }
        if ([key isEqualToString:@"cctv.mediaEpisodeShowBadge.v1"] || [key isEqualToString:@"cctv.mediaEpisodeAutoExpand.v1"]) { [NSNotificationCenter.defaultCenter postNotificationName:@"MediaDisplayConfigurationDidChangeNotification" object:nil]; [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil]; }
        if ([key isEqualToString:@"channelGridMode"]) { weakSelf.gridMode=value; [weakSelf configureCatalogNavigation]; }
        if ([key isEqualToString:@"channelGridMode"]) { [weakSelf.channelGrid.collectionViewLayout invalidateLayout]; [weakSelf.channelGrid reloadData]; [weakSelf.view setNeedsLayout]; }
        if ([key isEqualToString:@"cctv.mediaKeepScreenAwake"]) { [weakSelf updateLiveScreenAwakeState]; }
        if ([key isEqualToString:@"autoPiP"]) { if (@available(iOS 14.2, *)) { weakSelf.pip.canStartPictureInPictureAutomaticallyFromInline = value; } }
        if ([key isEqualToString:@"cctv.mediaVideoGravity"]) {
            NSString *gravity=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
            if(weakSelf.avLayer)weakSelf.avLayer.videoGravity=gravity;
        }
        if ([key isEqualToString:@"resetDefaultPreferences"]) {
            weakSelf.gridMode=CCTVBoolPreference(@"channelGridMode",YES);
            weakSelf.gridColumns=4;
            weakSelf.channelSortMode=0;
            [RuntimeDiagnostics.shared setEnabled:NO];
            [weakSelf configureSDKLogging];
            [weakSelf activateAudioSession];
            [weakSelf applyFontSizeOverride];
            [weakSelf reloadThemeAppearance];
            [weakSelf configureCatalogNavigation];
            [weakSelf applyFilter];
            [weakSelf updateLiveScreenAwakeState];
            [weakSelf updateLiveResourceCapsule];
            MediaBrowserViewController *browser=(MediaBrowserViewController *)weakSelf.tabPages[@2];
            if(browser)[browser reloadMediaDisplayConfigurationIfLoaded];
            [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:@0];
        }
    };
    return page;
}

@end
