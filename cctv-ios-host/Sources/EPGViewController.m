#import "EPGViewController.h"
#import "HostTheme.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"

@interface EPGViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *channelID;
@property(nonatomic,strong) NSDictionary *channel;
@property(nonatomic,copy) NSString *xmlSource;
@property(nonatomic,assign) NSUInteger requestGeneration;
@property(nonatomic,copy) NSString *sourceName;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSArray<NSDictionary *> *allRows;
@property (nonatomic, strong) UISegmentedControl *dates;
@property (nonatomic, strong) NSArray<NSString *> *dateKeys;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic,assign) BOOL pageVisible;
@property(nonatomic,assign) BOOL needsRefreshOnAppear;
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
    self.view.backgroundColor = UIColor.blackColor;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showSourceInfo)];

    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 20)];
    self.hint.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    self.hint.font = [UIFont systemFontOfSize:12];
    self.hint.text = @"正在获取节目单…";
    [self.view addSubview:self.hint];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2, 120);
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, self.view.bounds.size.width, self.view.bounds.size.height - 40)
                                              style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 68;
    self.table.backgroundColor = UIColor.blackColor;
    self.table.separatorColor = [UIColor colorWithWhite:0.2 alpha:1];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(fetch) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
    [self.view addSubview:self.table];

    self.dates=[[UISegmentedControl alloc] initWithItems:@[]];self.dates.selectedSegmentTintColor=HostAccent();[self.dates addTarget:self action:@selector(filterDate) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.dates];
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
            else if(error.code==NSURLErrorCancelled){w.hint.text=@"正在优先加载视频，稍后下拉刷新节目单";}
            else if(w.channelID.length){[w fetchOfficial];}
            else w.hint.text=error.localizedDescription?:@"暂无匹配节目；请在频道菜单中设置 EPG ID";
        }];return;}
    [self fetchOfficial];
}
- (void)fetchOfficial {
    if(!self.channelID.length){self.hint.text=@"暂无匹配的官方节目单";[self.spinner stopAnimating];[self.table.refreshControl endRefreshing];return;}
    NSString *encoded = [self.channelID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __weak typeof(self) weakSelf = self;NSUInteger generation=++self.requestGeneration;
    [self.task cancel];
    self.task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *rows = nil;
        if (data.length) {
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
            } else {
                weakSelf.hint.text = err ? [NSString stringWithFormat:@"获取失败：%@", err.localizedDescription]
                                         : @"官方暂无有效节目单";
            }
        });
    }];
    [self.task resume];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGFloat top=self.view.safeAreaInsets.top;CGFloat width=self.view.bounds.size.width;
    self.dates.frame=CGRectMake(16,top+8,width-32,40);self.hint.frame=CGRectMake(16,top+56,width-32,20);self.table.frame=CGRectMake(0,top+84,width,MAX(0,self.view.bounds.size.height-top-84));self.spinner.center=CGPointMake(width/2,top+150);
}
- (NSDateFormatter *)dayFormatter {NSDateFormatter *f=[NSDateFormatter new];f.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];f.dateFormat=@"yyyy-MM-dd";return f;}
- (void)rebuildDates {
    NSDateFormatter *f=[self dayFormatter];NSString *previous=(self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count)?self.dateKeys[self.dates.selectedSegmentIndex]:nil;NSMutableOrderedSet *days=[NSMutableOrderedSet orderedSet];for(NSDictionary *row in self.allRows)[days addObject:[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"start"] doubleValue]]]];self.dateKeys=days.array;
    [self.dates removeAllSegments];NSString *today=[f stringFromDate:NSDate.date];NSInteger selected=NSNotFound;for(NSUInteger i=0;i<self.dateKeys.count;i++){NSString *key=self.dateKeys[i];NSString *title=[key isEqualToString:today]?@"今天":[key substringFromIndex:5];[self.dates insertSegmentWithTitle:title atIndex:i animated:NO];if([key isEqualToString:previous])selected=i;}
    if(selected==NSNotFound)for(NSUInteger i=0;i<self.dateKeys.count;i++)if([self.dateKeys[i] isEqualToString:today]){selected=i;break;}
    self.dates.selectedSegmentIndex=self.dateKeys.count?(selected==NSNotFound?(NSInteger)self.dateKeys.count-1:selected):UISegmentedControlNoSegment;[self filterDate];
}
- (void)filterDate {
    NSInteger idx=self.dates.selectedSegmentIndex;if(idx<0||idx>=self.dateKeys.count)return;NSString *key=self.dateKeys[idx];NSDateFormatter *f=[self dayFormatter];self.rows=[self.allRows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [[f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"start"] doubleValue]]] isEqualToString:key];}]];[self.table reloadData];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;for(NSUInteger i=0;i<self.rows.count;i++){NSDictionary *row=self.rows[i];if(now>=[row[@"start"] doubleValue]&&now<[row[@"end"] doubleValue]){[self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];break;}}
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
        cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.textLabel.adjustsFontForContentSizeCategory=YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *row = self.rows[indexPath.row];
    double start = [row[@"start"] doubleValue];
    double end = [row[@"end"] doubleValue];
    double now = NSDate.date.timeIntervalSince1970;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm";
    fmt.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    NSString *range = [NSString stringWithFormat:@"%@ - %@",
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]],
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = range;

    BOOL replayable=self.onReplay && end<=now;
    cell.accessoryType=replayable?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    cell.selectionStyle=replayable?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    BOOL live = (now >= start && now < end);
    if (live) {
        cell.textLabel.textColor = HostAccent();
        cell.detailTextLabel.text = [range stringByAppendingString:@"  ● 正在播出"];
    } else if (end <= now) {
        cell.textLabel.textColor = replayable?UIColor.whiteColor:[UIColor colorWithWhite:0.45 alpha:1];
        if(replayable)cell.detailTextLabel.text=[range stringByAppendingString:@"  点按回看"];
    } else {
        cell.textLabel.textColor = UIColor.whiteColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(indexPath.row>=self.rows.count)return;
    NSDictionary *program=self.rows[indexPath.row];NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(!self.onReplay || [program[@"end"] doubleValue]>now)return;
    self.onReplay(program);
}

@end
