#import "PlaybackInfoViewController.h"
#import "HostTheme.h"
@implementation PlaybackInfoViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"播放信息";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self refreshSnapshot];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self refreshSnapshot]; }
- (void)refreshSnapshot { if(self.rowsProvider)self.snapshotRows=self.rowsProvider()?:@[];else self.snapshotRows=@[];if(self.isViewLoaded)[self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.snapshotRows.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row>=self.snapshotRows.count)return [UITableViewCell new];NSDictionary *row = self.snapshotRows[ip.row];
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"playback.info.row"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"playback.info.row"];
    c.backgroundColor = HostCard();
    c.textLabel.text = row[@"title"];
    c.detailTextLabel.text = row[@"value"];
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.textLabel.adjustsFontForContentSizeCategory=YES;c.textLabel.numberOfLines=0;
    c.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]];
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
@end
