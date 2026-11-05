#import "EPGViewController.h"
#import <UserNotifications/UserNotifications.h>
#import "HostTheme.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"

@interface EPGViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *channelID;
@property(nonatomic,strong) NSDictionary *channel;
@property(nonatomic,copy) NSString *xmlSource;
@property(nonatomic,assign) NSUInteger requestGeneration;
@property(nonatomic,copy) NSString *sourceName;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSArray<NSDictionary *> *allRows;
@property (nonatomic, strong) UISegmentedControl *dates;
@property (nonatomic, strong) NSArray<NSString *> *dateKeys;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic,assign) BOOL pageVisible;
@property(nonatomic,assign) BOOL needsRefreshOnAppear;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *reminders;
@property(nonatomic,copy) NSString *searchQuery;
@property(nonatomic,strong) UISearchController *programSearch;
@property(nonatomic,strong) UIButton *dateMenuButton;
@property(nonatomic,strong) UIBarButtonItem *jumpToLiveItem;
@end

@implementation EPGViewController

- (instancetype)initWithChannel:(NSDictionary *)channel officialID:(NSString *)officialID {
    if(self=[self initWithChannelID:officialID name:channel[@"name"]?:@"节目单"]){self.channel=channel;self.xmlSource=[ProfileStore epgSourceForChannel:channel];}return self;
}
- (instancetype)initWithChannelID:(NSString *)channelID name:(NSString *)name {
    if (self = [super init]) {
        _channelID = [channelID copy];
        _channelName = [name copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.channelName.length ? self.channelName : self.channelID;
    self.view.backgroundColor = HostBackground();
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.jumpToLiveItem=[[UIBarButtonItem alloc] initWithTitle:@"正在播" style:UIBarButtonItemStylePlain target:self action:@selector(scrollToLiveProgram)];
    self.navigationItem.rightBarButtonItems=@[self.jumpToLiveItem, [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showSourceInfo)]];

    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 20)];
    self.hint.textColor = HostSecondaryText();
    self.hint.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]];
    self.hint.adjustsFontForContentSizeCategory = YES;
    self.hint.numberOfLines = 2;
    self.hint.text = @"正在获取节目单…";
    [self.view addSubview:self.hint];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.accessibilityLabel = @"正在加载节目单";
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2, 120);
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"暂无节目单\n下拉可重新加载";
    self.emptyLabel.textColor = HostSecondaryText();
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, self.view.bounds.size.width, self.view.bounds.size.height - 40)
                                              style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 68;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(fetch) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
    self.table.backgroundView = self.emptyLabel;
    [self.view addSubview:self.table];

    self.dates=[[UISegmentedControl alloc] initWithItems:@[]];self.dates.selectedSegmentTintColor=HostAccent();self.dates.apportionsSegmentWidthsByContent=YES;self.dates.accessibilityLabel=@"选择节目单日期";[self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]]} forState:UIControlStateNormal];[self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]]} forState:UIControlStateSelected];[self.dates addTarget:self action:@selector(filterDate) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.dates];
    self.reminders=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.epgReminders.v1"] mutableCopy]?:[NSMutableDictionary dictionary];
    self.dateMenuButton=[UIButton buttonWithType:UIButtonTypeSystem];self.dateMenuButton.hidden=YES;self.dateMenuButton.accessibilityLabel=@"选择节目单日期";self.dateMenuButton.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15]];self.dateMenuButton.titleLabel.adjustsFontForContentSizeCategory=YES;self.dateMenuButton.showsMenuAsPrimaryAction=YES;[self.view addSubview:self.dateMenuButton];
    self.programSearch=[[UISearchController alloc] initWithSearchResultsController:nil];self.programSearch.searchResultsUpdater=self;self.programSearch.obscuresBackgroundDuringPresentation=NO;self.programSearch.searchBar.placeholder=@"搜索本页节目";self.navigationItem.searchController=self.programSearch;self.definesPresentationContext=YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self fetch];

}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];self.pageVisible=YES;
    if(self.needsRefreshOnAppear){self.needsRefreshOnAppear=NO;[self fetch];}
    [self scheduleRefreshTimer];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];self.pageVisible=NO;self.needsRefreshOnAppear=YES;
    [self cancelPageRequest];[self.refreshTimer invalidate];self.refreshTimer=nil;
}
- (void)scheduleRefreshTimer {
    [self.refreshTimer invalidate];self.refreshTimer=nil;
    if(!self.pageVisible||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    __weak typeof(self) w=self;self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t){[w fetch];}];
}
- (void)cancelPageRequest {
    self.requestGeneration++;[self.task cancel];self.task=nil;
    [self.spinner stopAnimating];[self.table.refreshControl endRefreshing];
}
- (void)applicationDidEnterBackground {
    self.needsRefreshOnAppear=YES;[self.refreshTimer invalidate];self.refreshTimer=nil;[self cancelPageRequest];
}
- (void)applicationWillEnterForeground {
    if(!self.pageVisible)return;
    self.needsRefreshOnAppear=NO;[self fetch];[self scheduleRefreshTimer];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.refreshTimer invalidate];
    [self.task cancel];
}

- (void)fetch {
    if(self.xmlSource.length){NSUInteger request=++self.requestGeneration;BOOL force=self.table.refreshControl.refreshing;__weak typeof(self) w=self;
        [[XMLTVStore shared] loadSource:self.xmlSource channel:[ProfileStore epgIDForChannel:self.channel] force:force completion:^(NSArray *rows,NSError *error){if(request!=w.requestGeneration)return;[w.spinner stopAnimating];[w.table.refreshControl endRefreshing];
            if(rows.count){w.allRows=rows;w.sourceName=w.xmlSource;[w rebuildDates];w.hint.text=error?@"使用上次缓存，刷新暂不可用":[NSString stringWithFormat:@"XMLTV · %lu 个节目",(unsigned long)rows.count];}
            else if(error.code==NSURLErrorCancelled){w.hint.text=@"正在优先加载视频，稍后下拉刷新节目单";[w updateEmptyState];}
            else if(w.channelID.length){[w fetchOfficial];}
            else {w.hint.text=w.allRows.count?@"刷新失败，显示上次节目单":(error.localizedDescription?:@"暂无匹配节目；请在频道菜单中设置 EPG ID");[w updateEmptyState];}
        }];return;}
    [self fetchOfficial];
}
- (void)fetchOfficial {
    if(!self.channelID.length){self.hint.text=@"暂无匹配的官方节目单";[self.spinner stopAnimating];[self.table.refreshControl endRefreshing];[self updateEmptyState];return;}
    NSString *encoded = [self.channelID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __weak typeof(self) weakSelf = self;NSUInteger generation=++self.requestGeneration;
    [self.task cancel];
    self.task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *rows = nil;
        // 官方 EPG 响应无大小限制：超过 4 MiB 按失败处理，避免后台线程解析超大 JSON。
        if (data.length&&data.length<=4*1024*1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class]) {
                NSDictionary *dict = json;
                NSArray *epg = dict[@"EPG"] ?: dict[@"data"];
                if ([epg isKindOfClass:NSArray.class]) rows = [self normalize:epg];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=weakSelf.requestGeneration)return;weakSelf.sourceName=@"央视官方 EPG";
            [weakSelf.spinner stopAnimating];
            [weakSelf.table.refreshControl endRefreshing];
            if (rows.count) {
                weakSelf.allRows = rows;
                [weakSelf rebuildDates];
                weakSelf.hint.text = [NSString stringWithFormat:@"%lu 个节目 · 每分钟自动刷新",
                                      (unsigned long)rows.count];
            } else if (weakSelf.allRows.count) {
                // 刷新失败时保留上次节目单：提示必须说清是旧数据，
                // 不能一边展示旧节目一边写“暂无有效节目单”。
                weakSelf.hint.text = @"刷新失败，显示上次节目单";
            } else {
                weakSelf.hint.text = err ? [NSString stringWithFormat:@"获取失败：%@", err.localizedDescription]
                                         : @"官方暂无有效节目单";
            }
            [weakSelf updateEmptyState];
        });
    }];
    [self.task resume];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGFloat top=self.view.safeAreaInsets.top;CGFloat bottom=self.view.safeAreaInsets.bottom;CGFloat width=self.view.bounds.size.width;
    CGFloat hintHeight=ceil(self.hint.font.lineHeight*2);
    self.dates.frame=CGRectMake(16,top+8,width-32,40);self.dateMenuButton.frame=self.dates.frame;self.hint.frame=CGRectMake(16,top+56,width-32,hintHeight);self.table.frame=CGRectMake(0,top+56+hintHeight+8,width,MAX(0,self.view.bounds.size.height-top-56-hintHeight-8-bottom));self.spinner.center=CGPointMake(width/2,top+150);
}
- (void)updateEmptyState {
    self.emptyLabel.hidden = self.rows.count > 0 || self.spinner.isAnimating;
}
- (NSDateFormatter *)dayFormatter {NSDateFormatter *f=[NSDateFormatter new];f.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];f.dateFormat=@"yyyy-MM-dd";return f;}
- (void)rebuildDates {
    NSDateFormatter *f=[self dayFormatter];NSString *previous=(self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count)?self.dateKeys[self.dates.selectedSegmentIndex]:nil;NSMutableOrderedSet *days=[NSMutableOrderedSet orderedSet];for(NSDictionary *row in self.allRows)[days addObject:[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"start"] doubleValue]]]];self.dateKeys=days.array;
    [self.dates removeAllSegments];NSString *today=[f stringFromDate:NSDate.date];NSInteger selected=NSNotFound;for(NSUInteger i=0;i<self.dateKeys.count;i++){NSString *key=self.dateKeys[i];NSString *title=[key isEqualToString:today]?@"今天":[key substringFromIndex:5];[self.dates insertSegmentWithTitle:title atIndex:i animated:NO];if([key isEqualToString:previous])selected=i;}
    if(selected==NSNotFound)for(NSUInteger i=0;i<self.dateKeys.count;i++)if([self.dateKeys[i] isEqualToString:today]){selected=i;break;}
    self.dates.selectedSegmentIndex=self.dateKeys.count?(selected==NSNotFound?(NSInteger)self.dateKeys.count-1:selected):UISegmentedControlNoSegment;[self updateDateMenuButton];[self filterDate];
}
- (void)updateDateMenuButton {
    // 日期超过 5 天时分段控件会被挤扁：隐藏它，改用下拉菜单选日期。
    BOOL overflow=self.dateKeys.count>5;
    self.dates.hidden=overflow;self.dateMenuButton.hidden=!overflow;
    if(!overflow)return;
    NSDateFormatter *f=[self dayFormatter];NSString *today=[f stringFromDate:NSDate.date];
    NSString *selected=(self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count)?self.dateKeys[self.dates.selectedSegmentIndex]:nil;
    [self.dateMenuButton setTitle:selected?([selected isEqualToString:today]?@"今天":selected):@"选择日期" forState:UIControlStateNormal];
    NSMutableArray<UIAction *> *actions=[NSMutableArray array];
    for(NSUInteger i=0;i<self.dateKeys.count;i++){NSString *key=self.dateKeys[i];NSString *title=[key isEqualToString:today]?@"今天":key;__weak typeof(self) w=self;[actions addObject:[UIAction actionWithTitle:title image:(selected&&[key isEqualToString:selected])?[UIImage systemImageNamed:@"checkmark"]:nil identifier:nil handler:^(__unused UIAction *a){w.dates.selectedSegmentIndex=(NSInteger)i;[w updateDateMenuButton];[w filterDate];}]];}
    self.dateMenuButton.menu=[UIMenu menuWithTitle:@"选择日期" children:actions];
}
- (void)filterDate {
    NSInteger idx=self.dates.selectedSegmentIndex;if(idx<0||idx>=self.dateKeys.count){[self updateEmptyState];return;}NSString *key=self.dateKeys[idx];NSDateFormatter *f=[self dayFormatter];self.rows=[self.allRows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"start"] doubleValue]]] isEqualToString:key];}]];
    if(self.searchQuery.length){NSString *q=self.searchQuery.lowercaseString;self.rows=[self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [[(row[@"title"]?:@"") description].lowercaseString containsString:q];}]];}
    [self.table reloadData];if(!self.searchQuery.length)[self scrollToCurrentProgramAnimated:NO];
    [self updateEmptyState];
}
- (void)scrollToCurrentProgramAnimated:(BOOL)animated {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;for(NSUInteger i=0;i<self.rows.count;i++){NSDictionary *row=self.rows[i];if(now>=[row[@"start"] doubleValue]&&now<[row[@"end"] doubleValue]){[self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:animated];break;}}
}
- (void)scrollToLiveProgram {[self scrollToCurrentProgramAnimated:YES];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {self.searchQuery=searchController.searchBar.text;[self filterDate];}
- (NSString *)reminderKeyForProgram:(NSDictionary *)program {
    // 提醒以“频道 | 开播时间戳”为键，同一节目只会有一条提醒。
    return [NSString stringWithFormat:@"%@|%lld",self.channelID?:@"",(long long)[program[@"start"] doubleValue]];
}
- (BOOL)isProgramReminded:(NSDictionary *)program {return self.reminders[[self reminderKeyForProgram:program]]!=nil;}
- (void)saveReminders {[NSUserDefaults.standardUserDefaults setObject:self.reminders forKey:@"cctv.epgReminders.v1"];}
- (void)toggleReminderForProgram:(NSDictionary *)program {
    NSString *key=[self reminderKeyForProgram:program];NSString *title=[program[@"title"] isKindOfClass:NSString.class]?program[@"title"]:@"节目";
    if(self.reminders[key]){[self.reminders removeObjectForKey:key];[self saveReminders];[[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[key]];self.hint.text=[NSString stringWithFormat:@"已取消提醒：%@",title];[self.table reloadData];return;}
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSTimeInterval start=[program[@"start"] doubleValue];if(start<=now)return;
    __weak typeof(self) w=self;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{EPGViewController *owner=w;if(!owner)return;
            if(!granted){owner.hint.text=@"通知未开启，请在设置中允许通知后重试";return;}
            NSTimeInterval fire=start-300>now?start-300:start;
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];content.title=owner.channelName.length?owner.channelName:@"CCTV";content.body=[NSString stringWithFormat:@"即将播出：%@",title];content.sound=[UNNotificationSound defaultSound];
            UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:key content:content trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:MAX(1,fire-now) repeats:NO]];
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
            owner.reminders[key]=@{@"title":title,@"channelName":owner.channelName?:@"",@"start":@(start)};[owner saveReminders];
            owner.hint.text=[NSString stringWithFormat:@"已预约：%@，开播前 5 分钟提醒",title];[owner.table reloadData];
        });
    }];
}
- (NSString *)safeSourceDescription {
    NSString *raw=self.xmlSource?:@"";NSURLComponents *components=[NSURLComponents componentsWithString:raw];
    if(!components.host.length)return self.sourceName?:@"央视官方 EPG";
    BOOL hidden=components.user.length||components.password.length;
    components.user=nil;components.password=nil;components.fragment=nil;
    NSString *value=components.string?:@"XMLTV";return hidden?[value stringByAppendingString:@"（凭据已隐藏）"]:value;
}
- (void)showSourceInfo {
    NSDictionary *mappings=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{};
    NSString *manual=mappings[self.channel[@"id"]?:@""];
    NSString *tvgID=self.channel[@"epgID"]?:@"";NSString *tvgName=self.channel[@"tvgName"]?:@"";
    NSString *match=manual.length?@"手动 EPG 映射":(tvgID.length?@"M3U tvg-id":(tvgName.length?@"M3U tvg-name / 频道名称":@"频道 ID / 名称"));
    NSString *matchID=self.xmlSource.length?[ProfileStore epgIDForChannel:self.channel]:self.channelID;
    NSString *date=self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count?self.dateKeys[self.dates.selectedSegmentIndex]:@"未选择日期";
    NSString *status=self.allRows.count?[NSString stringWithFormat:@"已读取 %lu 个节目",(unsigned long)self.allRows.count]:(self.hint.text?:@"等待数据");
    NSString *message=[NSString stringWithFormat:@"频道：%@\nM3U tvg-id：%@\nM3U tvg-name：%@\n实际匹配 ID：%@\n匹配依据：%@\n数据来源：%@\n所选日期：%@\n数据状态：%@\n时区：北京时间\n\n节目仅展示数据源实际返回的内容。CCTV 原生频道可点按已播节目请求回看，范围与版权由频道服务确认。",self.channelName,self.channel[@"epgID"]?:@"—",self.channel[@"tvgName"]?:@"—",matchID?:@"—",match,[self safeSourceDescription],date,status];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EPG 频道信息" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)normalize:(NSArray *)rows {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in rows) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        double start = [row[@"startTime"] doubleValue];
        double end = [row[@"endTime"] doubleValue];
        if (start > 1e11) start /= 1000.0;
        if (end > 1e11) end /= 1000.0;
        NSString *title = row[@"title"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        if (start <= 0 || end <= start) continue;
        [out addObject:@{@"start": @(start), @"end": @(end), @"title": title}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return out;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"epg";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = HostCard();
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.textLabel.adjustsFontForContentSizeCategory=YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        cell.textLabel.numberOfLines=0;
        cell.detailTextLabel.numberOfLines=0;
        cell.textLabel.textColor = HostText();
        cell.detailTextLabel.textColor = HostSecondaryText();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *row = self.rows[indexPath.row];
    double start = [row[@"start"] doubleValue];
    double end = [row[@"end"] doubleValue];
    double now = NSDate.date.timeIntervalSince1970;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"HH:mm"; fmt.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; });
    NSString *range = [NSString stringWithFormat:@"%@ - %@",
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]],
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = range;

    BOOL replayable=self.onReplay && end<=now;
    cell.accessoryType=replayable?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    cell.selectionStyle=(replayable||start>now)?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    BOOL live = (now >= start && now < end);
    if (live) {
        cell.textLabel.textColor = HostAccent();
        cell.detailTextLabel.text = [range stringByAppendingString:@"  ● 正在播出"];
    } else if (end <= now) {
        cell.textLabel.textColor = replayable?HostText():HostSecondaryText();
        if(replayable)cell.detailTextLabel.text=[range stringByAppendingString:@"  点按回看"];
    } else {
        cell.textLabel.textColor = HostText();
        if([self isProgramReminded:row])cell.detailTextLabel.text=[range stringByAppendingString:@"  ⏰ 已预约"];
    }
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@，%@%@", row[@"title"] ?: @"", range, live ? @"，正在播出" : (end <= now ? (replayable ? @"，已播出，点按回看" : @"，已播出") : ([self isProgramReminded:row] ? @"，尚未播出，已预约" : @"，尚未播出"))];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(indexPath.row>=self.rows.count)return;
    NSDictionary *program=self.rows[indexPath.row];NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if([program[@"start"] doubleValue]>now){[self toggleReminderForProgram:program];return;}
    if(!self.onReplay || [program[@"end"] doubleValue]>now)return;
    self.onReplay(program);
}

@end
