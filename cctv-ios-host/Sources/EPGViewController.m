#import "EPGViewController.h"

@interface EPGViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation EPGViewController

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
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];

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
    self.table.rowHeight = 68;
    self.table.backgroundColor = UIColor.blackColor;
    self.table.separatorColor = [UIColor colorWithWhite:0.2 alpha:1];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(fetch) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
    [self.view addSubview:self.table];

    [self fetch];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(fetch) userInfo:nil repeats:YES];
}

- (void)dealloc {
    [self.refreshTimer invalidate];
    [self.task cancel];
}

- (void)fetch {
    NSString *encoded = [self.channelID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __weak typeof(self) weakSelf = self;
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
            [weakSelf.spinner stopAnimating];
            [weakSelf.table.refreshControl endRefreshing];
            if (rows.count) {
                weakSelf.rows = rows;
                [weakSelf.table reloadData];
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
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
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
    NSString *range = [NSString stringWithFormat:@"%@ - %@",
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]],
                       [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = range;

    BOOL live = (now >= start && now < end);
    if (live) {
        cell.textLabel.textColor = [UIColor colorWithRed:0.35 green:0.8 blue:0.5 alpha:1];
        cell.detailTextLabel.text = [range stringByAppendingString:@"  ● 正在播出"];
    } else if (end <= now) {
        cell.textLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1];
    } else {
        cell.textLabel.textColor = UIColor.whiteColor;
    }
    return cell;
}

@end
