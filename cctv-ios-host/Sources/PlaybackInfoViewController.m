#import "PlaybackInfoViewController.h"
#import "HostTheme.h"

@interface PlaybackInfoViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation PlaybackInfoViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"播放信息";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorColor = HostSeparator();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"暂无播放信息\n请先播放一个频道，再打开本页查看。";
    self.emptyLabel.textColor = HostSecondaryText();
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.tableView.backgroundView = self.emptyLabel;
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refreshSnapshot) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self refreshSnapshot];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self refreshSnapshot]; }
- (void)refreshSnapshot { NSArray *rows=@[];if(self.rowsProvider){@try{rows=self.rowsProvider()?:@[];}@catch(NSException *e){rows=@[];}}self.snapshotRows=[rows isKindOfClass:NSArray.class]?rows:@[];self.emptyLabel.hidden=self.snapshotRows.count>0;[self.refreshControl endRefreshing];if(self.isViewLoaded)[self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.snapshotRows.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row>=self.snapshotRows.count)return [UITableViewCell new];NSDictionary *row = [self.snapshotRows[ip.row] isKindOfClass:NSDictionary.class]?self.snapshotRows[ip.row]:@{};
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"playback.info.row"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"playback.info.row"];
    c.backgroundColor = HostCard();
    c.textLabel.text = [(row[@"title"]?:@"") description];
    c.detailTextLabel.text = [(row[@"value"]?:@"") description];
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = HostSecondaryText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.textLabel.adjustsFontForContentSizeCategory=YES;c.textLabel.numberOfLines=0;
    c.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]];
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
@end
