#import "PlaybackInfoViewController.h"
#import "HostTheme.h"
@implementation PlaybackInfoViewController
- (instancetype)init{return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {[super viewDidLoad];self.title=@"播放信息";self.tableView.backgroundColor=UIColor.blackColor;self.tableView.rowHeight=54;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.rowsProvider?self.rowsProvider().count:0;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {NSDictionary *row=self.rowsProvider()[ip.row];UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];c.backgroundColor=HostCard();c.textLabel.text=row[@"title"];c.detailTextLabel.text=row[@"value"];c.textLabel.textColor=UIColor.whiteColor;c.detailTextLabel.textColor=UIColor.secondaryLabelColor;c.textLabel.font=[UIFont systemFontOfSize:13];c.detailTextLabel.font=[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];c.detailTextLabel.numberOfLines=2;c.selectionStyle=UITableViewCellSelectionStyleNone;return c;}
@end
