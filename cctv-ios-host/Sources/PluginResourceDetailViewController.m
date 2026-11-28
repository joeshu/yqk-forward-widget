#import "PluginResourceDetailViewController.h"
#import "HostTheme.h"
#import "HostLogRedactor.h"
#import "HostToolbar.h"
#import "PyHost.h"
#import "ServiceStore.h"
#import "ServiceEditorViewController.h"
#import "ProfileStore.h"
#import "M3UParser.h"
#import "RuntimeDiagnostics.h"

static NSString *PluginResourceFormattedTimestamp(NSTimeInterval ts) {
    if (ts <= 0) return @"尚无成功记录";
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    @synchronized(formatter) {
        return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]] ?: @"尚无成功记录";
    }
}

@interface PluginResourceDetailViewController () <UITableViewDataSource,UITableViewDelegate,NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,strong) UILabel *notice;
@property(nonatomic) BOOL operationPending;
@property(nonatomic) NSUInteger toggleGeneration;
@property(nonatomic) NSUInteger restartGeneration;
@property(nonatomic,copy) NSString *probeStatus;
@property(nonatomic,strong) NSURLSession *probeSession;
@property(nonatomic,strong) NSURLSessionDataTask *probeTask;
@property(nonatomic,strong) NSMutableData *probeData;
@property(nonatomic,copy) NSArray<NSString *> *playlistCandidates;
@property(nonatomic,copy) NSString *resolvedPlaylistPath;
@property(nonatomic) NSUInteger probeGeneration;
@property(nonatomic) NSInteger probeStatusCode;
@property(nonatomic,strong) NSURL *probeResponseURL;
@property(nonatomic) NSInteger probeChannelCount;
@property(nonatomic) BOOL probingPlaylist;
@property(nonatomic) BOOL probePlaylistChecked;
@property(nonatomic,copy) NSArray<NSString *> *probePaths;
@property(nonatomic) NSUInteger probePathIndex;
@property(nonatomic) NSInteger probeLastHTTPStatus;
@property(nonatomic,copy) NSString *probeLastFailure;
@property(nonatomic,strong) NSURLSession *epgProbeSession;
@property(nonatomic,strong) NSURLSessionDataTask *epgProbeTask;
@property(nonatomic,strong) UIView *heroContainer;
@property(nonatomic,strong) UIView *heroCard;
@property(nonatomic,strong) UILabel *heroTitleLabel;
@property(nonatomic,strong) UILabel *heroStatusBadge;
@property(nonatomic,strong) UILabel *heroSubtitleLabel;
@property(nonatomic,strong) NSArray<UIView *> *heroPills;
@property(nonatomic,strong) NSArray<UILabel *> *heroPillValues;
@property(nonatomic,strong) NSArray<UILabel *> *heroPillTitles;
@property(nonatomic,copy) NSString *tempOptionsPath;
- (void)buildHeroHeaderView;
- (void)updateHeroHeaderView;
- (void)handlePullRefresh;
- (NSString *)baseURL;
- (void)showNotice:(NSString *)message;
- (void)showError:(NSString *)message;
- (void)probeNextPlaylistPath;
- (void)probeLocalEPGCandidatesForSubscription:(NSString *)subscriptionURL index:(NSUInteger)index generation:(NSUInteger)generation;
- (void)probeMediaHealth;
- (void)openEntryCodeViewer;
- (void)openOptionsJSONEditor;
- (void)openCompanionConfigEditor;
- (void)confirmClearPluginStorage;
- (void)promptRestartIfRunningWithTitle:(NSString *)title message:(NSString *)message;
@end

@implementation PluginResourceDetailViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (BOOL)mediaCapable {return [ServiceStore isVODMediaService:self.service];}
- (NSArray<NSString *> *)serviceCapabilities {id caps=self.service[@"capabilities"];if(![caps isKindOfClass:NSArray.class]){NSDictionary *manifest=[self.service[@"manifest"] isKindOfClass:NSDictionary.class]?self.service[@"manifest"]:@{};caps=manifest[@"capabilities"];}return [caps isKindOfClass:NSArray.class]?caps:@[];}
- (BOOL)liveCapable {return [ServiceStore subscriptionURLForService:self.service].length>0||[[self serviceCapabilities] containsObject:@"live"];}
- (void)refreshPlaylistPathState {self.resolvedPlaylistPath=[ServiceStore playlistPathForService:self.service];self.playlistCandidates=[ServiceStore playlistPathCandidatesForService:self.service];}
- (BOOL)running {return [PyHost isRunningServiceIdentifier:self.service[@"id"]];}
- (NSString *)baseURL {NSInteger port=[self.service[@"port"] integerValue];return [NSString stringWithFormat:@"http://127.0.0.1:%ld",(long)port];}
- (NSDictionary *)serviceManifest {NSDictionary *manifest=self.service[@"manifest"];return [manifest isKindOfClass:NSDictionary.class]?manifest:@{};}
- (NSString *)serviceURLString {NSString *url=self.service[@"url"];return [url isKindOfClass:NSString.class]?url:@"";}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=self.service[@"name"]?:@"资源详情";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=58;
    self.notice=[UILabel new];self.notice.textColor=HostSecondaryText();self.notice.numberOfLines=0;self.notice.textAlignment=NSTextAlignmentCenter;self.tableView.backgroundView=self.notice;
    [self buildHeroHeaderView];
    UIRefreshControl *rc=[UIRefreshControl new];
    [rc addTarget:self action:@selector(handlePullRefresh) forControlEvents:UIControlEventValueChanged];
    self.refreshControl=rc;
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"square.and.pencil",@"title":@"编辑配置",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onEdit)w.onEdit(w.service);}]}])];
}
- (void)buildHeroHeaderView {
    CGFloat width=MAX(320.0,self.view.bounds.size.width>0?self.view.bounds.size.width:375.0);
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,136)];
    container.backgroundColor=UIColor.clearColor;
    UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=16;card.layer.cornerCurve=kCACornerCurveContinuous;card.layer.borderWidth=0.8;HostSetLayerBorderColor(card,HostBorder());card.accessibilityIdentifier=@"plugin.detail.hero-card";
    [container addSubview:card];
    UIView *spec=[UIView new];spec.translatesAutoresizingMaskIntoConstraints=NO;spec.backgroundColor=[UIColor colorWithWhite:1.0 alpha:0.12];spec.userInteractionEnabled=NO;[card addSubview:spec];
    UILabel *title=[UILabel new];title.translatesAutoresizingMaskIntoConstraints=NO;title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];title.adjustsFontForContentSizeCategory=YES;title.textColor=HostText();title.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:title];
    UILabel *badge=[UILabel new];badge.translatesAutoresizingMaskIntoConstraints=NO;badge.font=HostMonospacedDigitFont(11,UIFontWeightSemibold,UIFontTextStyleCaption2);badge.textAlignment=NSTextAlignmentCenter;badge.layer.cornerRadius=8;badge.layer.cornerCurve=kCACornerCurveContinuous;badge.layer.borderWidth=0.55;badge.clipsToBounds=YES;[badge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[badge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];[card addSubview:badge];
    UILabel *sub=[UILabel new];sub.translatesAutoresizingMaskIntoConstraints=NO;sub.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];sub.adjustsFontForContentSizeCategory=YES;sub.textColor=HostSecondaryText();sub.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:sub];
    UIStackView *grid=[UIStackView new];grid.translatesAutoresizingMaskIntoConstraints=NO;grid.axis=UILayoutConstraintAxisHorizontal;grid.distribution=UIStackViewDistributionFillEqually;grid.spacing=8;[card addSubview:grid];
    NSArray<NSString *> *titles=@[@"引擎",@"端口",@"能力"];
    NSMutableArray *pills=[NSMutableArray arrayWithCapacity:3],*vals=[NSMutableArray arrayWithCapacity:3],*caps=[NSMutableArray arrayWithCapacity:3];
    for(NSString *t in titles){
        UIView *pill=[UIView new];pill.backgroundColor=HostRaisedSurface();pill.layer.cornerRadius=11;pill.layer.cornerCurve=kCACornerCurveContinuous;pill.layer.borderWidth=0.55;HostSetLayerBorderColor(pill,HostBorder());[pills addObject:pill];
        UILabel *v=[UILabel new];v.translatesAutoresizingMaskIntoConstraints=NO;v.font=HostMonospacedDigitFont(12.5,UIFontWeightBold,UIFontTextStyleSubheadline);v.adjustsFontSizeToFitWidth=YES;v.minimumScaleFactor=0.72;v.textColor=HostText();v.textAlignment=NSTextAlignmentCenter;v.text=@"—";[pill addSubview:v];
        UILabel *c=[UILabel new];c.translatesAutoresizingMaskIntoConstraints=NO;c.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];c.textColor=HostSecondaryText();c.textAlignment=NSTextAlignmentCenter;c.text=t;[pill addSubview:c];
        [NSLayoutConstraint activateConstraints:@[[v.topAnchor constraintEqualToAnchor:pill.topAnchor constant:7],[v.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],[v.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],[c.topAnchor constraintEqualToAnchor:v.bottomAnchor constant:2],[c.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],[c.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],[c.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-6]]];
        [grid addArrangedSubview:pill];[vals addObject:v];[caps addObject:c];
    }
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],[card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],[card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],[card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
        [spec.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],[spec.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],[spec.topAnchor constraintEqualToAnchor:card.topAnchor],[spec.heightAnchor constraintEqualToConstant:0.5],
        [title.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],[title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [badge.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],[badge.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],[badge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],[badge.heightAnchor constraintEqualToConstant:22],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3],[sub.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],[sub.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [grid.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:10],[grid.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],[grid.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],[grid.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11]
    ]];
    self.heroContainer=container;self.heroCard=card;self.heroTitleLabel=title;self.heroStatusBadge=badge;self.heroSubtitleLabel=sub;self.heroPills=pills;self.heroPillValues=vals;self.heroPillTitles=caps;
    self.tableView.tableHeaderView=container;
    [self updateHeroHeaderView];
}
- (void)updateHeroHeaderView {
    if(!self.heroCard)return;
    BOOL isRun=[self running];
    self.heroTitleLabel.text=self.service[@"name"]?:@"脚本资源";
    self.heroStatusBadge.text=isRun?@"  ● 运行中  ":@"  ○ 已停止  ";
    UIColor *stColor=isRun?UIColor.systemGreenColor:HostMutedText();
    self.heroStatusBadge.textColor=stColor;
    self.heroStatusBadge.backgroundColor=isRun?HostSuccessSurface():HostNeutralSurface();
    HostSetLayerBorderColor(self.heroStatusBadge,isRun?[UIColor.systemGreenColor colorWithAlphaComponent:0.35]:HostBorder());
    self.heroSubtitleLabel.text=self.probeStatus.length?self.probeStatus:([PyHost runtimeStatusDescriptionForServiceIdentifier:self.service[@"id"]]?:@"按需启动");
    NSString *eng=[self.service[@"engine"] isEqual:@"node"]?@"Node.js":([self.service[@"engine"] isEqual:@"javascript"]?@"JS":@"Python");
    NSInteger port=[self.service[@"port"] integerValue];
    NSString *portStr=port>0?[NSString stringWithFormat:@":%ld",(long)port]:@"自动";
    NSString *capStr=([self mediaCapable]&&[self liveCapable])?@"影视+直播":([self mediaCapable]?@"影视点播":([self liveCapable]?@"直播频道":@"扩展"));
    NSArray<NSString *> *vals=@[eng,portStr,capStr];
    for(NSUInteger i=0;i<self.heroPillValues.count&&i<vals.count;i++){
        self.heroPillValues[i].text=vals[i];
        self.heroPillValues[i].textColor=(i==0?HostAccent():HostText());
    }
}
- (void)handlePullRefresh {
    for(NSDictionary *latest in [ServiceStore services])if([latest[@"id"] isEqual:self.service[@"id"]]){self.service=latest;break;}
    [self refreshPlaylistPathState];
    [self updateHeroHeaderView];
    if(self.running)[self probeMediaHealth];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    HostSizeTableHeaderToFit(self.tableView, 136.0);
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.notice.textColor=HostSecondaryText();
    self.heroCard.backgroundColor=HostCard();HostSetLayerBorderColor(self.heroCard,HostBorder());
    self.heroTitleLabel.textColor=HostText();self.heroSubtitleLabel.textColor=HostSecondaryText();
    for(UIView *pill in self.heroPills){pill.backgroundColor=HostRaisedSurface();HostSetLayerBorderColor(pill,HostBorder());}
    for(UILabel *c in self.heroPillTitles)c.textColor=HostSecondaryText();
    [self updateHeroHeaderView];
    [self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostRefreshAppearanceLayers(self.view.window);
        [self reloadThemeAppearance];
    }
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];for(NSDictionary *latest in [ServiceStore services])if([latest[@"id"] isEqual:self.service[@"id"]]){self.service=latest;break;}self.title=self.service[@"name"];[self refreshPlaylistPathState];[self updateHeroHeaderView];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged) name:PyHostRuntimeStateDidChangeNotification object:nil];[NSNotificationCenter.defaultCenter removeObserver:self name:ProfileStoreMetadataDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(metadataDidChange) name:ProfileStoreMetadataDidChangeNotification object:nil];[self.tableView reloadData];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];[NSNotificationCenter.defaultCenter removeObserver:self name:ProfileStoreMetadataDidChangeNotification object:nil];self.probeGeneration++;self.probingPlaylist=NO;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];self.probeSession=nil;[self.epgProbeTask cancel];self.epgProbeTask=nil;[self.epgProbeSession invalidateAndCancel];self.epgProbeSession=nil;}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.probeTask cancel];[self.probeSession invalidateAndCancel];[self.epgProbeTask cancel];[self.epgProbeSession invalidateAndCancel];if(self.tempOptionsPath.length)[NSFileManager.defaultManager removeItemAtPath:self.tempOptionsPath error:NULL];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {completionHandler(nil);}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {BOOL valid=task==self.probeTask&&[response isKindOfClass:NSHTTPURLResponse.class]&&response.expectedContentLength<=1024*1024;if(task==self.probeTask){self.probeStatusCode=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;self.probeResponseURL=response.URL;}completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {if(task!=self.probeTask)return;if(self.probeData.length+data.length>1024*1024){[task cancel];return;}[self.probeData appendData:data];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(task!=self.probeTask){if(session!=self.probeSession)[session finishTasksAndInvalidate];return;}
    NSUInteger generation=self.probeGeneration;
    NSData *data=[self.probeData copy];
    NSInteger status=self.probeStatusCode;
    NSURL *url=self.probeResponseURL;
    NSUInteger pathIndex=self.probePathIndex;
    NSString *attemptedPath=pathIndex<self.probePaths.count?self.probePaths[pathIndex]:@"";
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        PluginResourceDetailViewController *self=weakSelf;
        if(!self||generation!=self.probeGeneration){[session finishTasksAndInvalidate];return;}
        self.probeTask=nil;
        if(error){self.probeLastFailure=error.code==NSURLErrorCancelled?@"响应超过 1 MiB 或请求已取消":(error.localizedDescription?:@"连接失败");self.probeLastHTTPStatus=0;}
        else{
            self.probeLastHTTPStatus=status;
            if(status>=200&&status<300){
                NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSArray *channels=text?[M3UParser parse:text baseURL:url]:@[];
                BOOL playlistFormat=[text containsString:@"#EXTM3U"]||[text containsString:@"#EXTINF"]||channels.count>0;
                if(playlistFormat&&channels.count>0){
                    self.probePlaylistChecked=YES;self.probeChannelCount=(NSInteger)channels.count;self.probingPlaylist=NO;
                    NSMutableDictionary *updated=[self.service mutableCopy];updated[@"playlistPath"]=attemptedPath;
                    if(![updated[@"playlistPathSource"] isEqual:@"manual"])updated[@"playlistPathSource"]=@"detected";
                    NSString *detectedEPG=text.length?[M3UParser epgURL:text baseURL:url]:nil;
                    if(!detectedEPG.length){
                        NSString *epgPath=[ServiceStore epgPathForService:updated];
                        if(epgPath.length)detectedEPG=[NSString stringWithFormat:@"%@%@",self.baseURL,epgPath];
                    }
                    [ServiceStore save:updated];self.service=updated;[self refreshPlaylistPathState];
                    NSString *subscriptionURL=[ServiceStore subscriptionURLForService:self.service];
                    if(subscriptionURL.length&&detectedEPG.length){
                        [ProfileStore update:subscriptionURL values:@{@"managedServiceID":self.service[@"id"]?:@"",@"detectedEPGURL":detectedEPG}];
                        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:subscriptionURL];
                    }else if(subscriptionURL.length){
                        [self probeLocalEPGCandidatesForSubscription:subscriptionURL index:0 generation:generation];
                    }
                    self.probeStatus=[NSString stringWithFormat:subscriptionURL.length&&self.onPlaylistDiscovered?@"已识别 %@ · %lu 个频道 · 已加入资源列表":@"已识别 %@ · %lu 个频道 · 请检查订阅地址",attemptedPath,(unsigned long)channels.count];
                    [RuntimeDiagnostics.shared recordEvent:@"service_playlist_endpoint_discovered" category:@"service" fields:@{@"service_id":self.service[@"id"]?:@"",@"engine":self.service[@"engine"]?:@"unknown",@"protocol":self.service[@"protocol"]?:@"unknown",@"candidate_index":@(pathIndex),@"candidate_count":@(self.probePaths.count),@"channel_count":@(channels.count),@"path_length":@(attemptedPath.length)}];
                    [self.probeSession finishTasksAndInvalidate];self.probeSession=nil;
                    if(subscriptionURL.length&&self.onPlaylistDiscovered)self.onPlaylistDiscovered(self.service,subscriptionURL,channels.count);
                    [self updateHeroHeaderView];
                    [self.tableView reloadData];
                    return;
                }
                self.probeLastFailure=playlistFormat?@"列表有效但没有频道":@"响应不是 M3U 频道列表";
            }else self.probeLastFailure=[NSString stringWithFormat:@"HTTP %ld",(long)status];
        }
        if(pathIndex+1<self.probePaths.count){self.probePathIndex=pathIndex+1;[self probeNextPlaylistPath];return;}
        self.probingPlaylist=NO;self.probePlaylistChecked=NO;
        self.probeStatus=[NSString stringWithFormat:@"未发现有效节目单 · 已检查 %lu 个本机地址 · %@ · 可编辑填写路径",(unsigned long)self.probePaths.count,self.probeLastFailure.length?self.probeLastFailure:@"无有效响应"];
        [RuntimeDiagnostics.shared recordEvent:@"service_playlist_endpoint_not_found" category:@"service" fields:@{@"service_id":self.service[@"id"]?:@"",@"engine":self.service[@"engine"]?:@"unknown",@"protocol":self.service[@"protocol"]?:@"unknown",@"candidate_count":@(self.probePaths.count),@"last_http_status":@(self.probeLastHTTPStatus)}];
        [self.probeSession finishTasksAndInvalidate];self.probeSession=nil;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];
    });
}
- (void)probeLocalEPGCandidatesForSubscription:(NSString *)subscriptionURL index:(NSUInteger)index generation:(NSUInteger)generation {
    if(generation!=self.probeGeneration||!subscriptionURL.length||!self.running){[self.epgProbeSession finishTasksAndInvalidate];self.epgProbeSession=nil;self.epgProbeTask=nil;return;}
    NSArray<NSString *> *candidates=[ServiceStore epgPathCandidatesForService:self.service];
    if(index>=candidates.count){[self.epgProbeSession finishTasksAndInvalidate];self.epgProbeSession=nil;self.epgProbeTask=nil;return;}
    if(!self.epgProbeSession){
        NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest=1.5;config.timeoutIntervalForResource=2.0;config.URLCache=nil;
        self.epgProbeSession=[NSURLSession sessionWithConfiguration:config];
    }
    NSURLSession *epgSession=self.epgProbeSession;
    NSString *candidatePath=candidates[index];
    NSURL *epgURL=[NSURL URLWithString:[NSString stringWithFormat:@"%@%@",self.baseURL,candidatePath]];
    if(!epgURL||![epgURL.host isEqualToString:@"127.0.0.1"]){
        [self probeLocalEPGCandidatesForSubscription:subscriptionURL index:index+1 generation:generation];
        return;
    }
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:epgURL];
    req.HTTPMethod=@"GET";req.timeoutInterval=1.5;
    [req setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    __weak typeof(self) weakSelf=self;
    self.epgProbeTask=[epgSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(),^{
            PluginResourceDetailViewController *owner=weakSelf;
            if(!owner||generation!=owner.probeGeneration){[epgSession finishTasksAndInvalidate];return;}
            NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
            BOOL validXMLTV=NO;
            if(!error&&status>=200&&status<300&&data.length>=2){
                const uint8_t *bytes=data.bytes;
                BOOL gzip=(bytes[0]==0x1f&&bytes[1]==0x8b);
                NSString *head=[[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0,MIN(data.length,(NSUInteger)2048))] encoding:NSUTF8StringEncoding]?:@"";
                NSString *lower=head.lowercaseString;
                validXMLTV=gzip||[lower containsString:@"<tv"]||[lower containsString:@"<programme"]||([lower containsString:@"<?xml"]&&[lower containsString:@"channel"]);
            }
            if(validXMLTV){
                NSMutableDictionary *updated=[owner.service mutableCopy];
                if(![updated[@"epgPathSource"] isEqual:@"manual"]){updated[@"epgPath"]=candidatePath;updated[@"epgPathSource"]=@"detected";[ServiceStore save:updated];owner.service=updated;}
                [ProfileStore update:subscriptionURL values:@{@"managedServiceID":owner.service[@"id"]?:@"",@"detectedEPGURL":epgURL.absoluteString}];
                [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:subscriptionURL];
                [owner.epgProbeSession finishTasksAndInvalidate];owner.epgProbeSession=nil;owner.epgProbeTask=nil;
                if(owner.isViewLoaded)[owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
                return;
            }
            [owner probeLocalEPGCandidatesForSubscription:subscriptionURL index:index+1 generation:generation];
        });
    }];
    [self.epgProbeTask resume];
}
- (void)stateChanged {
    // 运行状态通知可能来自后台线程：直接 reloadData 会触发 UIKit 断言；
    // 与 metadataDidChange 一致，先切回主线程，且只在视图已加载时刷新。
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf stateChanged];});return;}
    if(!self.isViewLoaded)return;[self updateHeroHeaderView];[self.tableView reloadData];
}
- (void)metadataDidChange {if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self metadataDidChange];});return;}if(self.isViewLoaded&&self.view.window)[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 4;}
- (NSArray *)resourceRows {
    NSArray *caps=[self serviceCapabilities];
    NSString *configEntry=[[self serviceManifest][@"configEntry"] isKindOfClass:NSString.class]?[self serviceManifest][@"configEntry"]:@"";
    NSMutableArray *rows=[NSMutableArray arrayWithArray:@[@{@"title":@"运行能力",@"value":[NSString stringWithFormat:@"%@ · %@",self.service[@"engine"]?:@"未知引擎",self.service[@"protocol"]?:@"未知协议"]},@{@"title":@"能力探测",@"value":caps.count?[caps componentsJoinedByString:@"、"]:@"启动后验证实际能力"}]];
    NSString *version=[[self serviceManifest][@"pluginVersion"] isKindOfClass:NSString.class]?[self serviceManifest][@"pluginVersion"]:@"";if(version.length)[rows addObject:@{@"title":@"资源版本",@"value":version}];
    NSString *entry=[[self serviceManifest][@"entry"] isKindOfClass:NSString.class]?[self serviceManifest][@"entry"]:@"";if(entry.length)[rows addObject:@{@"title":@"入口文件",@"value":entry,@"action":@"viewCode"}];
    if(![self.service[@"builtin"] boolValue]&&[self serviceManifest][@"options"]!=nil)[rows addObject:@{@"title":@"插件参数",@"value":@"查看或编辑 JSON 运行参数",@"action":@"editOptions"}];
    if(self.mediaCapable)[rows addObject:@{@"title":@"进入媒体",@"action":@"use",@"value":@"资源 → 站点 → 详情选集 → 播放"}];
    if(self.liveCapable){
        [rows addObject:@{@"title":@"打开直播频道",@"action":@"use",@"value":@"读取下方显示的本机订阅地址后进入频道页"}];
        NSString *pluginKey=[@"plugin:" stringByAppendingString:self.service[@"id"]?:@""];
        BOOL chLogoOn=[ProfileStore isChannelLogoEnabledForSource:pluginKey];
        BOOL cornerLogoOn=[ProfileStore isPlayerCornerLogoEnabledForSource:pluginKey];
        BOOL previewOn=[ProfileStore isChannelPreviewEnabledForSource:pluginKey];
        BOOL telemetryOn=[ProfileStore isChannelTelemetryEnabledForSource:pluginKey];
        [rows addObject:@{@"title":@"频道列表与网格台标",@"action":@"toggleChannelLogo",@"value":chLogoOn?@"已开启 · 轻点切换":@"已关闭 · 轻点切换"}];
        [rows addObject:@{@"title":@"播放器右上角台标",@"action":@"toggleCornerLogo",@"value":cornerLogoOn?@"已开启 · 轻点切换":@"已关闭 · 轻点切换"}];
        [rows addObject:@{@"title":@"频道实时预览图",@"action":@"toggleChannelPreview",@"value":previewOn?@"已开启 · 轻点切换":@"已关闭 · 轻点切换"}];
        [rows addObject:@{@"title":@"频道速率与延迟",@"action":@"toggleChannelTelemetry",@"value":telemetryOn?@"已开启 · 轻点切换":@"已关闭 · 轻点切换"}];
    }
    if([self.service[@"protocol"] isEqual:@"catpaw-http"]){[rows addObject:@{@"title":@"源配置与账号",@"value":@"管理此源的站点、网盘与登录信息",@"action":@"configuration"}];
        NSDictionary *states=@{@"verified":@"已下载并通过 MD5 校验",@"downloaded_without_checksum":@"已下载 · 来源未提供配置校验",@"missing_using_defaults":@"未提供配套配置 · 启动时使用脚本默认值"};
        NSMutableDictionary *cfgRow=[@{@"title":@"配套配置",@"value":states[self.service[@"configurationState"]?:@""]?:([configEntry length]?@"包内配置":@"未知 · 可检查更新补齐")} mutableCopy];
        if(configEntry.length)cfgRow[@"action"]=@"editConfigEntry";
        [rows addObject:cfgRow];}
    else if(configEntry.length){[rows addObject:@{@"title":@"配套配置",@"value":configEntry,@"action":@"editConfigEntry"}];}
    NSArray *verifiedLocalChecksums=[[self serviceManifest][@"verifiedLocalChecksums"] isKindOfClass:NSArray.class]?[self serviceManifest][@"verifiedLocalChecksums"]:@[];
    if([[self serviceURLString] length]){NSString *checksum=[self.service[@"downloadChecksum"] isKindOfClass:NSString.class]?self.service[@"downloadChecksum"]:@"";NSString *status=checksum.length?[NSString stringWithFormat:@"下载 MD5 已通过 · %@（完整性校验，不是数字签名）",checksum]:@"未提供文件校验";if(verifiedLocalChecksums.count)status=[status stringByAppendingFormat:@"；ZIP 内 %@ 已校验",[verifiedLocalChecksums componentsJoinedByString:@"、"]];[rows addObject:@{@"title":@"文件校验",@"value":status}];[rows addObject:@{@"title":@"资源来源",@"value":[self serviceURLString],@"action":@"copySource"}];}
    else if(verifiedLocalChecksums.count)[rows addObject:@{@"title":@"文件校验",@"value":[NSString stringWithFormat:@"ZIP 内 MD5 已通过：%@",[verifiedLocalChecksums componentsJoinedByString:@"、"]]}];
    return rows;
}
- (NSArray *)managementRows {
    if([self.service[@"builtin"] boolValue])return @[];
    NSMutableArray *rows=[NSMutableArray arrayWithObject:@{@"title":@"查看此资源日志",@"value":@"独立日志 · 查看与导出",@"action":@"log"}];
    [rows addObject:@{@"title":@"检测资源接口健康",@"value":self.probeStatus.length?self.probeStatus:(self.running?@"探测本机 /health 与插件就绪状态":@"服务未运行 · 启动后可检测接口"),@"action":@"probeHealth"}];
    [rows addObject:@{@"title":@"清理此资源缓存与会话状态",@"value":@"重置插件 Cookie、缓存与存储，保留代码和端口",@"action":@"clearStorage"}];
    if(self.onRestart)[rows addObject:@{@"title":@"重启此服务",@"value":self.running?@"先停止再重新启动，端口不变":@"服务未运行 · 请先启动",@"action":@"restart"}];
    if(self.onExport)[rows addObject:@{@"title":@"导出单项资源文件",@"value":@"分享此资源代码或原始资源包",@"action":@"export"}];
    if([[self serviceURLString] length])[rows addObject:@{@"title":@"检查资源更新",@"value":@"校验新版 · 保留服务 ID、账号和配置",@"action":@"update"}];
    if([self.service[@"previousImport"] isKindOfClass:NSDictionary.class])[rows addObject:@{@"title":@"切回上一版代码",@"value":@"保留账号数据与当前端口",@"action":@"rollback"}];
    [rows addObject:@{@"title":@"移除资源",@"value":@"移除本机代码及配置",@"action":@"remove"}];return rows;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {if(section==0)return self.resourceRows.count;if(section==1)return self.liveCapable?4:3;if(section==2)return self.liveCapable?7:1;return self.managementRows.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"资源能力",@"运行状态",@"本机接口",@"管理与诊断"][section];}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"点“打开影视”或“打开直播频道”后才会按需启动服务。运行中、接口健康、列表可读和视频解码是不同状态。";if(section==1)return [[self serviceManifest][@"compatibilityNote"] isKindOfClass:NSString.class]?[self serviceManifest][@"compatibilityNote"]:@"服务可独立启停；停止失败时请查看此资源的日志。";if(section==2)return [NSString stringWithFormat:@"端口识别：%@ · 本机节目单地址会自动对齐至 127.0.0.1:%@",[ServiceStore portRecognitionSummaryForService:self.service],self.service[@"port"]?:@0];return nil;}
- (NSDictionary *)rowAt:(NSIndexPath *)ip {
    if(ip.section==0)return self.resourceRows[ip.row];
    NSString *port=[NSString stringWithFormat:@"%@",self.service[@"port"]?:@"未知"];
    if(ip.section==1){NSString *serviceStatus=[self.service[@"status"] isKindOfClass:NSString.class]&&[self.service[@"status"] length]?self.service[@"status"]:(self.running?@"本机服务运行正常 · 选集或打开频道时自动建立解码会话":@"服务当前未启动 · 打开影视或直播时按需启动");NSArray *caps=[self serviceCapabilities];NSString *runningSummary=([self.service[@"status"] isKindOfClass:NSString.class]&&[self.service[@"status"] length])?[NSString stringWithFormat:@"运行中 · %@",self.service[@"status"]]:([caps containsObject:@"play"]?@"运行中 · 接口就绪（点选节目后按需解码）":@"运行中 · 本机接口已就绪");NSArray *rows=@[@{@"title":@"服务进程",@"value":self.operationPending?@"正在启停…":(self.running?runningSummary:@"已停止")},@{@"title":self.running?@"停止服务":@"启动服务",@"value":self.running?@"仅停止此服务":@"按需启动此服务",@"action":@"toggle"},@{@"title":@"读取直播频道清单",@"value":self.probeStatus?:@"检测本机播放列表；不验证视频解码",@"action":@"probe"},@{@"title":@"运行状态说明",@"value":serviceStatus}];return rows[(!self.liveCapable&&ip.row==2)?3:ip.row];}
    if(ip.section==2){NSString *resolvedPath=self.resolvedPlaylistPath;NSString *pendingPath=self.playlistCandidates.firstObject;NSString *playlist=resolvedPath?: (pendingPath.length?[NSString stringWithFormat:@"待验证 · %@",pendingPath]:@"未发现 · 点击上方检测资源接口");NSInteger servicePort=[self.service[@"port"] integerValue];NSString *resolvedURL=[ServiceStore subscriptionURLForService:self.service];NSString *subscription=resolvedURL?: (pendingPath.length&&servicePort>0?[NSString stringWithFormat:@"待验证 · http://127.0.0.1:%ld%@",(long)servicePort,pendingPath]:@"未识别 · 点击上方检测后加入资源列表");NSString *epg=[ServiceStore epgURLForService:self.service]?:@"尚未从订阅清单中识别";NSDictionary *metadata=resolvedURL.length?[ProfileStore metadata:resolvedURL]:@{};NSArray *cached=[metadata[@"cachedChannels"] isKindOfClass:NSArray.class]?metadata[@"cachedChannels"]:@[];NSString *count=cached.count?[NSString stringWithFormat:@"%lu 个缓存频道",(unsigned long)cached.count]:(self.probePlaylistChecked?[NSString stringWithFormat:@"%ld 个 · 最近一次接口检测",(long)self.probeChannelCount]:@"未知 · 尚未读取有效清单");NSString *status=[metadata[@"status"] isKindOfClass:NSString.class]?metadata[@"status"]:(resolvedURL.length?(self.running?@"服务运行中 · 等待读取":@"服务已停止"): @"未配置已验证的播放列表");NSTimeInterval updated=[metadata[@"updatedAt"] doubleValue];NSString *last=PluginResourceFormattedTimestamp(updated);NSArray *rows=@[@{@"title":@"复制本机服务地址",@"value":[NSString stringWithFormat:@"http://127.0.0.1:%@",port],@"action":@"copy"},@{@"title":@"服务订阅地址",@"value":subscription},@{@"title":@"节目单地址",@"value":epg},@{@"title":@"播放列表路径",@"value":playlist},@{@"title":@"频道数量",@"value":count},@{@"title":@"订阅清单状态",@"value":status},@{@"title":@"最近成功刷新",@"value":last}];NSMutableDictionary *row=[rows[ip.row] mutableCopy];BOOL subscriptionURL=[subscription hasPrefix:@"http://"]||[subscription hasPrefix:@"https://"];BOOL epgURL=[epg hasPrefix:@"http://"]||[epg hasPrefix:@"https://"];if((ip.row==1&&subscriptionURL)||(ip.row==2&&epgURL))row[@"action"]=@"copy";return row;}
    return self.managementRows[ip.row];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {NSDictionary *row=[self rowAt:ip];BOOL sourceURL=[row[@"action"] isEqual:@"copySource"],copyURL=[row[@"action"] isEqual:@"copy"];BOOL address=sourceURL||copyURL;BOOL longValue=!address&&[row[@"value"] isKindOfClass:NSString.class]&&([(NSString *)row[@"value"] length]>80||ip.section==3||(ip.section==1&&(ip.row==0||ip.row==2||ip.row==3))||[(NSString *)row[@"value"] length]>28);NSString *reuse=address?@"service.resource.address":(longValue?@"service.resource.long-value":@"service.resource.value");UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:(address||longValue)?UITableViewCellStyleSubtitle:UITableViewCellStyleValue1 reuseIdentifier:reuse];cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());
    NSString *title=row[@"title"]?:@"";NSString *action=row[@"action"];
    cell.textLabel.text=title;BOOL isRemove=[action isEqual:@"remove"];BOOL isPrimary=[action isEqual:@"use"]||[action isEqual:@"toggle"];cell.textLabel.textColor=isRemove?UIColor.systemRedColor:(isPrimary?HostAccent():HostText());cell.textLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.text=address?[HostLogRedactor redactText:row[@"value"]?:@""]:row[@"value"];
    BOOL isProcessRow=(ip.section==1&&ip.row==0);
    cell.detailTextLabel.textColor=(isProcessRow&&self.running)?UIColor.systemGreenColor:HostSecondaryText();
    cell.detailTextLabel.font=HostMonospacedDigitFont(14,UIFontWeightRegular,UIFontTextStyleSubheadline);cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textAlignment=(address||longValue)?NSTextAlignmentLeft:NSTextAlignmentNatural;
    NSDictionary *icons=@{@"运行能力":@"cpu",@"能力探测":@"sparkles",@"资源版本":@"tag",@"入口文件":@"doc.text",@"进入媒体":@"play.circle.fill",@"打开直播频道":@"dot.radiowaves.left.and.right",@"频道列表与网格台标":@"photo.fill",@"播放器右上角台标":@"tv.inset.filled",@"频道实时预览图":@"photo.on.rectangle.angled",@"频道速率与延迟":@"speedometer",@"源配置与账号":@"person.badge.key",@"配套配置":@"checkmark.seal",@"文件校验":@"lock.shield",@"资源来源":@"link",@"服务进程":@"bolt.horizontal.circle",@"启动服务":@"play.fill",@"停止服务":@"stop.fill",@"读取直播频道清单":@"list.bullet.rectangle",@"运行状态说明":@"info.circle",@"复制本机服务地址":@"network",@"服务订阅地址":@"antenna.radiowaves.left.and.right",@"节目单地址":@"calendar.badge.clock",@"播放列表路径":@"point.topleft.down.curvedto.point.bottomright.up",@"频道数量":@"number.square",@"订阅清单状态":@"checkmark.shield",@"最近成功刷新":@"clock.arrow.circlepath",@"插件参数":@"slider.horizontal.3",@"查看此资源日志":@"doc.text.magnifyingglass",@"检测资源接口健康":@"stethoscope",@"清理此资源缓存与会话状态":@"paintbrush",@"重启此服务":@"arrow.triangle.2.circlepath",@"导出单项资源文件":@"square.and.arrow.up",@"检查资源更新":@"arrow.down.circle",@"切回上一版代码":@"arrow.uturn.backward.circle",@"移除资源":@"trash"};
    NSString *iconName=icons[title];
    cell.imageView.image=iconName?[UIImage systemImageNamed:iconName]:nil;
    cell.imageView.tintColor=isRemove?UIColor.systemRedColor:(isPrimary?HostAccent():(isProcessRow&&self.running?UIColor.systemGreenColor:HostSecondaryText()));
    if(isProcessRow&&self.running){cell.layer.borderWidth=1.05;HostSetLayerBorderColor(cell,HostAccent());}
    cell.accessoryType=action?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=action?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;return cell;}
- (void)probeInterface {
    if(self.probingPlaylist)return;
    if(!self.running){self.probeStatus=@"服务未运行 · 启动后可检测节目单地址";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];return;}
    NSArray<NSString *> *paths=self.playlistCandidates?:@[];
    if(!paths.count){if([ServiceStore isMediaService:self.service]){[self probeMediaHealth];return;}self.probeStatus=@"此资源未提供本机播放列表接口";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];return;}
    self.probeGeneration++;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];[self.epgProbeTask cancel];self.epgProbeTask=nil;[self.epgProbeSession invalidateAndCancel];self.epgProbeSession=nil;
    self.probePaths=paths;self.probePathIndex=0;self.probeLastHTTPStatus=0;self.probeLastFailure=@"";self.probeData=[NSMutableData data];self.probeChannelCount=0;self.probePlaylistChecked=NO;self.probingPlaylist=YES;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=1.5;config.timeoutIntervalForResource=2;config.HTTPMaximumConnectionsPerHost=2;config.URLCache=nil;config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;self.probeSession=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    self.probeStatus=[NSString stringWithFormat:@"正在检测 %lu 个本机节目单地址…",(unsigned long)paths.count];[self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];[self probeNextPlaylistPath];
}
- (void)probeNextPlaylistPath {
    if(!self.probingPlaylist)return;
    if(self.probePathIndex>=self.probePaths.count){
        self.probingPlaylist=NO;self.probePlaylistChecked=NO;self.probeTask=nil;
        self.probeStatus=[NSString stringWithFormat:@"未发现有效节目单 · 已检查 %lu 个本机地址 · %@ · 可编辑填写路径",(unsigned long)self.probePaths.count,self.probeLastFailure.length?self.probeLastFailure:@"无有效响应"];
        [self.probeSession finishTasksAndInvalidate];self.probeSession=nil;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    NSString *path=self.probePaths[self.probePathIndex];NSInteger port=[self.service[@"port"] integerValue];
    NSString *trimmed=[path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(port<1||port>65535||![trimmed isEqualToString:path]||![path hasPrefix:@"/"]||[path hasPrefix:@"//"]||[path containsString:@".."]||[path containsString:@"?"]||[path containsString:@"#"]||[path containsString:@"\\"]||[path containsString:@":"]||[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){
        self.probeLastFailure=@"候选路径无效";self.probePathIndex++;[self probeNextPlaylistPath];return;
    }
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"%@%@",self.baseURL,path]];
    if(!url||![url.host isEqual:@"127.0.0.1"]){self.probeLastFailure=@"本机接口地址无效";self.probePathIndex++;[self probeNextPlaylistPath];return;}
    self.probeData=[NSMutableData data];self.probeStatusCode=0;self.probeResponseURL=nil;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"GET";request.timeoutInterval=1.5;[request setValue:@"application/vnd.apple.mpegurl, application/x-mpegURL, text/plain" forHTTPHeaderField:@"Accept"];
    self.probeTask=[self.probeSession dataTaskWithRequest:request];[self.probeTask resume];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {[tableView deselectRowAtIndexPath:ip animated:YES];NSDictionary *row=[self rowAt:ip];NSString *action=row[@"action"];if(ip.section==0 && [row[@"title"] isEqual:@"进入媒体"]){if(self.onUse)self.onUse(self.service,@"vod");return;}if(ip.section==0 && [row[@"title"] isEqual:@"打开直播频道"]){if(self.onUse)self.onUse(self.service,@"live");return;}if([action isEqual:@"toggleChannelLogo"]){NSString *pluginKey=[@"plugin:" stringByAppendingString:self.service[@"id"]?:@""];BOOL next=![ProfileStore isChannelLogoEnabledForSource:pluginKey];[ProfileStore setChannelLogoEnabled:next forSource:pluginKey];NSString *subURL=[ServiceStore subscriptionURLForService:self.service];if(subURL.length)[ProfileStore setChannelLogoEnabled:next forSource:subURL];[self showNotice:next?@"已开启此资源的频道与播放器台标":@"已关闭此资源的台标显示"];[self.tableView reloadData];return;}if([action isEqual:@"toggleCornerLogo"]){NSString *pluginKey=[@"plugin:" stringByAppendingString:self.service[@"id"]?:@""];BOOL next=![ProfileStore isPlayerCornerLogoEnabledForSource:pluginKey];[ProfileStore setPlayerCornerLogoEnabled:next forSource:pluginKey];NSString *subURL=[ServiceStore subscriptionURLForService:self.service];if(subURL.length)[ProfileStore setPlayerCornerLogoEnabled:next forSource:subURL];[self showNotice:next?@"已开启此资源的播放器右上角台标":@"已关闭此资源的播放器右上角台标"];[self.tableView reloadData];return;}if([action isEqual:@"toggleChannelPreview"]){NSString *pluginKey=[@"plugin:" stringByAppendingString:self.service[@"id"]?:@""];BOOL next=![ProfileStore isChannelPreviewEnabledForSource:pluginKey];[ProfileStore setChannelPreviewEnabled:next forSource:pluginKey];NSString *subURL=[ServiceStore subscriptionURLForService:self.service];if(subURL.length)[ProfileStore setChannelPreviewEnabled:next forSource:subURL];[self showNotice:next?@"已开启此资源的频道实时预览图":@"已关闭此资源的频道实时预览图"];[self.tableView reloadData];return;}if([action isEqual:@"toggleChannelTelemetry"]){NSString *pluginKey=[@"plugin:" stringByAppendingString:self.service[@"id"]?:@""];BOOL next=![ProfileStore isChannelTelemetryEnabledForSource:pluginKey];[ProfileStore setChannelTelemetryEnabled:next forSource:pluginKey];NSString *subURL=[ServiceStore subscriptionURLForService:self.service];if(subURL.length)[ProfileStore setChannelTelemetryEnabled:next forSource:subURL];[self showNotice:next?@"已开启此资源的频道速率与延迟显示":@"已关闭此资源的频道速率与延迟显示"];[self.tableView reloadData];return;}if([action isEqual:@"configuration"]){if(self.onUse)self.onUse(self.service,@"configuration");return;}if([action isEqual:@"update"]){if(self.onUpdate)self.onUpdate(self.service);return;}if([action isEqual:@"rollback"]){__weak typeof(self) weakSelf=self;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"切回上一版代码？" message:@"会先停止此服务，再切换到保留的上一版代码。账号、日志和当前端口会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"切换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){PluginResourceDetailViewController *owner=weakSelf;if(owner&&owner.onRollback)owner.onRollback(owner.service);}]];[self presentViewController:alert animated:YES completion:nil];return;}if([action isEqual:@"restart"]){if(self.operationPending)return;if(!self.running){[self showNotice:@"服务未运行 · 请先启动"];return;}if(!self.onRestart){[self showNotice:@"当前版本不支持重启此服务"];return;}self.operationPending=YES;[self showNotice:@"正在重启服务…"];[self.tableView reloadData];__weak typeof(self) weakSelf=self;NSUInteger restartGen=++self.restartGeneration;self.onRestart(self.service,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(!owner||restartGen!=owner.restartGeneration)return;owner.operationPending=NO;for(NSDictionary *latest in [ServiceStore services])if([latest[@"id"] isEqual:owner.service[@"id"]]){owner.service=latest;break;}[owner refreshPlaylistPathState];if(error)[owner showError:error.localizedDescription?:@"重启服务失败，请查看此资源日志"];else[owner showNotice:@"服务已重新启动"];[owner updateHeroHeaderView];[owner.tableView reloadData];});});dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(!owner||restartGen!=owner.restartGeneration||!owner.operationPending)return;owner.operationPending=NO;[owner showError:@"重启服务超时，请查看此资源日志"];[owner updateHeroHeaderView];[owner.tableView reloadData];});return;}if([action isEqual:@"toggle"]){if(self.operationPending)return;if(!self.onToggle){[self showError:@"服务控制暂不可用"];return;}self.operationPending=YES;[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];__weak typeof(self) weakSelf=self;NSUInteger toggleGeneration=++self.toggleGeneration;self.onToggle(self.service,!self.running,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(!owner||toggleGeneration!=owner.toggleGeneration)return;owner.operationPending=NO;if(error)[owner showError:error.localizedDescription?:@"服务操作失败，请查看此资源日志"];[owner updateHeroHeaderView];[owner.tableView reloadData];});});
    // onToggle 回调若永不触发，operationPending 会永久锁死开关：30 秒看门狗兜底复位。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(!owner||toggleGeneration!=owner.toggleGeneration||!owner.operationPending)return;owner.operationPending=NO;[owner showError:@"服务操作超时，请查看此资源日志"];[owner updateHeroHeaderView];[owner.tableView reloadData];});return;}if([action isEqual:@"viewCode"]){[self openEntryCodeViewer];return;}if([action isEqual:@"editOptions"]){[self openOptionsJSONEditor];return;}if([action isEqual:@"editConfigEntry"]){[self openCompanionConfigEditor];return;}if([action isEqual:@"clearStorage"]){[self confirmClearPluginStorage];return;}if([action isEqual:@"probeHealth"]){[self probeMediaHealth];return;}if([action isEqual:@"probe"]){[self probeInterface];return;}if([action isEqual:@"copy"]||[action isEqual:@"copySource"]){UIPasteboard.generalPasteboard.string=row[@"value"];NSString *message=[action isEqual:@"copySource"]?@"资源来源地址已复制（包含原查询参数）":([row[@"title"] isEqual:@"节目单地址"]?@"节目单地址已复制":([row[@"title"] isEqual:@"服务订阅地址"]?@"服务订阅地址已复制":@"本机服务地址已复制"));[self showNotice:message];return;}if([action isEqual:@"export"]){if(self.onExport)self.onExport(self.service);return;}if([action isEqual:@"log"]){if(self.onLog)self.onLog(self.service);return;}if([action isEqual:@"remove"]){__weak typeof(self) weakSelf=self;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除此资源？" message:@"会移除本机服务代码及配置。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){PluginResourceDetailViewController *owner=weakSelf;if(owner&&owner.onRemove)owner.onRemove(owner.service);}]];[self presentViewController:alert animated:YES completion:nil];}}
- (void)showNotice:(NSString *)message {if(!message.length)return;self.navigationItem.prompt=message;UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,message);__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(owner&&[owner.navigationItem.prompt isEqual:message])owner.navigationItem.prompt=nil;});}
- (void)showError:(NSString *)message {if(!message.length)return;
    if(self.presentedViewController){__weak typeof(self) weakSelf=self;UIViewController *presented=self.presentedViewController;[presented dismissViewControllerAnimated:NO completion:^{PluginResourceDetailViewController *owner=weakSelf;if(owner)[owner showError:message];}];return;}__weak typeof(self) weakSelf=self;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"服务操作失败" message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){PluginResourceDetailViewController *owner=weakSelf;if(owner&&owner.onLog)owner.onLog(owner.service);}]];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
- (void)promptRestartIfRunningWithTitle:(NSString *)title message:(NSString *)message {
    if (!self.running || !self.onRestart || self.operationPending) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        PluginResourceDetailViewController *owner = weakSelf;
        if (!owner || !owner.view.window || owner.presentedViewController || !owner.running || !owner.onRestart) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"立即重启" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
            PluginResourceDetailViewController *strongOwner = weakSelf;
            if (!strongOwner || strongOwner.operationPending || !strongOwner.running || !strongOwner.onRestart) return;
            strongOwner.operationPending = YES;
            [strongOwner showNotice:@"正在重启服务…"];
            [strongOwner.tableView reloadData];
            NSUInteger restartGen = ++strongOwner.restartGeneration;
            strongOwner.onRestart(strongOwner.service, ^(NSError *error){
                dispatch_async(dispatch_get_main_queue(), ^{
                    PluginResourceDetailViewController *cbOwner = weakSelf;
                    if (!cbOwner || restartGen != cbOwner.restartGeneration) return;
                    cbOwner.operationPending = NO;
                    if (error) [cbOwner showError:error.localizedDescription ?: @"重启服务失败，请查看此资源日志"];
                    else [cbOwner showNotice:@"服务已重启并应用最新修改"];
                    [cbOwner updateHeroHeaderView];
                    [cbOwner.tableView reloadData];
                });
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                PluginResourceDetailViewController *toOwner = weakSelf;
                if (!toOwner || restartGen != toOwner.restartGeneration || !toOwner.operationPending) return;
                toOwner.operationPending = NO;
                [toOwner showError:@"重启服务超时，请查看此资源日志"];
                [toOwner updateHeroHeaderView];
                [toOwner.tableView reloadData];
            });
        }]];
        [owner presentViewController:alert animated:YES completion:nil];
    });
}
- (void)openEntryCodeViewer {
    NSString *codePath=[ServiceStore codePath:self.service];
    if(!codePath.length||![NSFileManager.defaultManager fileExistsAtPath:codePath]){[self showError:@"未找到此资源的入口代码文件"];return;}
    NSString *factoryPath=[ServiceStore bundledFactoryCodePathForService:self.service];
    ServiceCodeViewController *viewer=[ServiceCodeViewController new];
    viewer.path=codePath;
    viewer.bundledResourcePath=factoryPath;
    viewer.readOnly=[self.service[@"builtin"] boolValue];
    __weak typeof(self) weakSelf=self;
    viewer.onSaveCode=^{
        PluginResourceDetailViewController *owner=weakSelf;if(!owner)return;
        NSMutableDictionary *updated=[owner.service mutableCopy];
        NSData *factoryData=factoryPath.length?[NSData dataWithContentsOfFile:factoryPath]:nil;
        NSData *currentData=[NSData dataWithContentsOfFile:codePath];
        if(factoryData.length&&[currentData isEqualToData:factoryData]){[updated removeObjectForKey:@"userEditedCode"];}
        else{updated[@"userEditedCode"]=@YES;}
        updated[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        [ServiceStore save:updated];
        owner.service=updated;
        [owner showNotice:owner.running?@"代码已保存 · 重启此服务后生效":@"入口代码修改已保存"];
        [owner.tableView reloadData];
        [owner promptRestartIfRunningWithTitle:@"入口代码已保存" message:@"当前服务正在运行，是否立即重启服务使新代码生效？"];
    };
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)openOptionsJSONEditor {
    NSString *identifier=self.service[@"id"]?:@"plugin";
    NSString *optPath=[[ServiceStore directory] stringByAppendingPathComponent:[identifier stringByAppendingString:@"-detail-options.json"]];
    self.tempOptionsPath=optPath;
    id options=[self serviceManifest][@"options"]?:@{};
    if([options isKindOfClass:NSString.class]){
        [(NSString *)options writeToFile:optPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }else{
        NSData *data=[NSJSONSerialization dataWithJSONObject:options options:NSJSONWritingPrettyPrinted|NSJSONWritingFragmentsAllowed error:NULL];
        if(data.length)[data writeToFile:optPath atomically:YES];
    }
    ServiceCodeViewController *editor=[ServiceCodeViewController new];
    editor.path=optPath;
    editor.readOnly=[self.service[@"builtin"] boolValue];
    __weak typeof(self) weakSelf=self;
    editor.onWillSaveCode=^BOOL(NSString *code, NSError * __autoreleasing *error){
        NSString *trimmed=[code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
        NSData *rawData=[code dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonErr=nil;
        id parsed=rawData.length?[NSJSONSerialization JSONObjectWithData:rawData options:NSJSONReadingFragmentsAllowed error:&jsonErr]:nil;
        if(jsonErr&&[options isKindOfClass:NSString.class]&&![trimmed hasPrefix:@"{"]&&![trimmed hasPrefix:@"["]){
            parsed=trimmed;jsonErr=nil;
        }
        if(jsonErr||!([parsed isKindOfClass:NSDictionary.class]||[parsed isKindOfClass:NSString.class])){
            if(error)*error=[NSError errorWithDomain:@"CCTVHostOptions" code:1 userInfo:@{NSLocalizedDescriptionKey:jsonErr.localizedDescription?:@"插件参数须为合法的 JSON 对象或字符串"}];
            return NO;
        }
        return YES;
    };
    editor.onCloseCode=^{
        [NSFileManager.defaultManager removeItemAtPath:optPath error:NULL];
        PluginResourceDetailViewController *owner=weakSelf;
        if(owner&&[owner.tempOptionsPath isEqualToString:optPath])owner.tempOptionsPath=nil;
    };
    editor.onSaveCode=^{
        PluginResourceDetailViewController *owner=weakSelf;if(!owner)return;
        NSData *savedData=[NSData dataWithContentsOfFile:optPath];
        NSString *savedText=savedData.length?[[NSString alloc] initWithData:savedData encoding:NSUTF8StringEncoding]:@"";
        NSString *trimmed=[savedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSFileManager.defaultManager removeItemAtPath:optPath error:NULL];
        if([owner.tempOptionsPath isEqualToString:optPath])owner.tempOptionsPath=nil;
        NSError *jsonErr=nil;
        id parsed=savedData.length?[NSJSONSerialization JSONObjectWithData:savedData options:NSJSONReadingFragmentsAllowed error:&jsonErr]:nil;
        if(jsonErr&&[options isKindOfClass:NSString.class]&&![trimmed hasPrefix:@"{"]&&![trimmed hasPrefix:@"["]){
            parsed=trimmed;jsonErr=nil;
        }
        if(jsonErr||(!([parsed isKindOfClass:NSDictionary.class]||[parsed isKindOfClass:NSString.class]))){[owner showError:jsonErr.localizedDescription?:@"插件参数须为合法的 JSON 对象或字符串"];return;}
        NSMutableDictionary *updated=[owner.service mutableCopy];
        NSMutableDictionary *manifest=[[owner serviceManifest] mutableCopy];
        manifest[@"options"]=parsed;
        updated[@"manifest"]=manifest;
        updated[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        [ServiceStore save:updated];
        owner.service=updated;
        [owner showNotice:owner.running?@"插件参数已保存 · 重启此服务后生效":@"插件参数已保存"];
        [owner.tableView reloadData];
        [owner promptRestartIfRunningWithTitle:@"插件参数已保存" message:@"当前服务正在运行，是否立即重启服务使新参数生效？"];
    };
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)openCompanionConfigEditor {
    NSString *configEntry=[[self serviceManifest][@"configEntry"] isKindOfClass:NSString.class]?[self serviceManifest][@"configEntry"]:@"";
    NSString *pkgRoot=[self.service[@"packageRoot"] isKindOfClass:NSString.class]?self.service[@"packageRoot"]:@"";
    if(!configEntry.length||!pkgRoot.length){[self showError:@"此资源未声明配套配置文件路径"];return;}
    NSString *configPath=[pkgRoot stringByAppendingPathComponent:configEntry];
    if(![NSFileManager.defaultManager fileExistsAtPath:configPath]){[self showError:@"配套配置文件不存在，请检查资源更新"];return;}
    ServiceCodeViewController *viewer=[ServiceCodeViewController new];
    viewer.path=configPath;
    viewer.readOnly=[self.service[@"builtin"] boolValue];
    __weak typeof(self) weakSelf=self;
    viewer.onSaveCode=^{
        PluginResourceDetailViewController *owner=weakSelf;if(!owner)return;
        NSMutableDictionary *updated=[owner.service mutableCopy];
        updated[@"updated"]=@(NSDate.date.timeIntervalSince1970);
        [ServiceStore save:updated];
        owner.service=updated;
        [owner showNotice:owner.running?@"配套配置已保存 · 重启此服务后生效":@"配套配置修改已保存"];
        [owner.tableView reloadData];
        [owner promptRestartIfRunningWithTitle:@"配套配置已保存" message:@"当前服务正在运行，是否立即重启服务加载新配置？"];
    };
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)confirmClearPluginStorage {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理此资源缓存与会话状态？" message:@"将清除该插件保存的 Cookie、登录令牌缓存及运行期临时状态文件。插件源码、端口和参数配置不会受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a){
        PluginResourceDetailViewController *owner=weakSelf;if(!owner)return;
        NSError *err=nil;
        if([ServiceStore clearRuntimeStorageForService:owner.service error:&err]){
            [owner showNotice:@"已清理此资源的运行缓存与存储"];
            [owner promptRestartIfRunningWithTitle:@"缓存已清理" message:@"是否立即重启服务以使用全新会话状态？"];
        }else{
            [owner showError:err.localizedDescription?:@"清理资源缓存失败"];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)probeMediaHealth {
    if(self.probingPlaylist)return;
    if(!self.running){self.probeStatus=@"服务未运行 · 请先启动服务后再检测";[self showNotice:self.probeStatus];[self.tableView reloadData];return;}
    self.probingPlaylist=YES;
    self.probeStatus=@"正在检测本机 /health 接口…";
    [self.tableView reloadData];
    NSUInteger generation=++self.probeGeneration;
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"%@/health",self.baseURL]];
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3.0];
    __weak typeof(self) weakSelf=self;
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;cfg.URLCache=nil;
    NSURLSession *sess=[NSURLSession sessionWithConfiguration:cfg];
    [[sess dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
        dispatch_async(dispatch_get_main_queue(),^{
            [sess finishTasksAndInvalidate];
            PluginResourceDetailViewController *owner=weakSelf;
            if(!owner||generation!=owner.probeGeneration)return;
            owner.probingPlaylist=NO;
            NSInteger status=[resp isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)resp).statusCode:0;
            BOOL ok=NO;
            if(!err&&status>=200&&status<300&&data.length){
                id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                ok=[json isKindOfClass:NSDictionary.class]&&[json[@"ok"] respondsToSelector:@selector(boolValue)]&&[json[@"ok"] boolValue];
            }
            if(ok){
                owner.probeStatus=@"健康检查通过 · GET /health 响应正常";
                [owner showNotice:owner.probeStatus];
            }else if(err){
                owner.probeStatus=[NSString stringWithFormat:@"接口未响应：%@",err.localizedDescription?:@"连接失败"];
                [owner showNotice:owner.probeStatus];
            }else{
                owner.probeStatus=[NSString stringWithFormat:@"HTTP %ld · /health 未确认就绪",(long)status];
                [owner showNotice:owner.probeStatus];
            }
            [ServiceStore recordHealthSnapshot:@{@"status":ok?@"reachable":@"failed",@"result":owner.probeStatus,@"httpStatus":@(status),@"checkedAt":@(NSDate.date.timeIntervalSince1970),@"path":@"/health"} forServiceIdentifier:owner.service[@"id"]?:@""];
            [owner updateHeroHeaderView];
            [owner.tableView reloadData];
        });
    }] resume];
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
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    (void)tableView;(void)point;
    NSDictionary *row=[self rowAt:ip];
    NSString *title=[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:@"";
    NSString *value=[row[@"value"] isKindOfClass:NSString.class]?row[@"value"]:@"";
    if(!title.length&&!value.length)return nil;
    __weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        NSMutableArray<UIMenuElement *> *items=[NSMutableArray array];
        if(value.length){
            [items addObject:[UIAction actionWithTitle:@"复制此项内容" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=value;[weakSelf showNotice:@"已复制到剪贴板"];}]];
        }
        [items addObject:[UIAction actionWithTitle:@"复制完整键值" image:[UIImage systemImageNamed:@"list.clipboard"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=value.length?[NSString stringWithFormat:@"%@：%@",title,value]:title;[weakSelf showNotice:@"已复制到剪贴板"];}]];
        return [UIMenu menuWithTitle:title children:items];
    }];
}
@end
