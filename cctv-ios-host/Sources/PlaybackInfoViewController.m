#import "PlaybackInfoViewController.h"
#import "HostTheme.h"
@implementation PlaybackInfoViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"播放信息";
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 54;
    [self refreshSnapshot];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self refreshSnapshot]; }
- (void)refreshSnapshot { if(self.rowsProvider)self.snapshotRows=self.rowsProvider()?:@[];else self.snapshotRows=@[];if(self.isViewLoaded)[self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.snapshotRows.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row>=self.snapshotRows.count)return [UITableViewCell new];NSDictionary *row = self.snapshotRows[ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.backgroundColor = HostCard();
    c.textLabel.text = row[@"title"];
    c.detailTextLabel.text = row[@"value"];
    c.textLabel.textColor = UIColor.whiteColor;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.textLabel.font = [UIFont systemFontOfSize:13];
    c.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    c.detailTextLabel.numberOfLines = 2;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
@end
