#import "SettingsViewController.h"

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@end

@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = UIColor.blackColor;
    self.navigationController.navigationBar.tintColor = UIColor.systemPinkColor;
    self.sections = @[
        @{ @"title": @"播放", @"footer": @"央视直播由官方 CNPlayerSDK 调度；M3U/HLS 订阅使用 AVPlayer。", @"rows": @[
            @{ @"title": @"央视直播", @"detail": @"官方 SDK · 自动选线", @"icon": @"tv" },
            @{ @"title": @"M3U 订阅", @"detail": @"AVPlayer · 系统 HLS", @"icon": @"play.rectangle" }
        ]},
        @{ @"title": @"数据与诊断", @"footer": @"清理后，节目单会在下次访问频道时重新获取。", @"rows": @[
            @{ @"title": @"清理节目单缓存", @"detail": @"释放本地缓存", @"icon": @"trash" },
            @{ @"title": @"应用数据位置", @"detail": @"Application Support / ysp", @"icon": @"folder" }
        ]},
        @{ @"title": @"关于", @"footer": @"播放稳定性受官方调度、频道版权、网络和 iOS 后台策略影响。", @"rows": @[
            @{ @"title": @"CCTVHost", @"detail": @"0.14.2", @"icon": @"info.circle" },
            @{ @"title": @"iOS 插件运行模式", @"detail": @"内嵌 CPython · 前台服务", @"icon": @"curlybraces" }
        ]}
    ];
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = UIColor.blackColor;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 58;
    self.table.tintColor = UIColor.systemPinkColor;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self.sections[section][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.sections[section][@"title"]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { return self.sections[section][@"footer"]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"settings.row"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"settings.row"];
    NSDictionary *row = self.sections[ip.section][@"rows"][ip.row];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = row[@"detail"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.imageView.image = [UIImage systemImageNamed:row[@"icon"]];
    cell.imageView.tintColor = UIColor.systemPinkColor;
    cell.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    cell.selectionStyle = (ip.section == 1 && ip.row == 0) ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = (ip.section == 1 && ip.row == 0) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1 || ip.row != 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存会在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *path = [[dirs firstObject] stringByAppendingPathComponent:@"epg-cache.json"];
        NSError *error = nil;
        BOOL removed = ![[NSFileManager defaultManager] fileExistsAtPath:path] || [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        NSString *message = removed ? @"节目单缓存已清理。" : error.localizedDescription;
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"缓存" message:message preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
