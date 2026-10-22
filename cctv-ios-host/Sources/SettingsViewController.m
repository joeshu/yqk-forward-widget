#import "SettingsViewController.h"

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) NSArray *sections;
@end
@implementation SettingsViewController
- (void)viewDidLoad {
 [super viewDidLoad]; self.title=@"设置"; self.view.backgroundColor=UIColor.blackColor;
 self.sections=@[@{@"title":@"通用",@"rows":@[@"界面外观",@"清理节目单缓存",@"关于 CCTVHost"]},@{@"title":@"视频",@"rows":@[@"允许后台播放",@"自动画中画",@"记住上次频道"]}];
 self.table=[[UITableView alloc]initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped]; self.table.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; self.table.backgroundColor=UIColor.blackColor; self.table.dataSource=self; self.table.delegate=self; [self.view addSubview:self.table];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self.sections[section][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.sections[section][@"title"]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
 NSString *title=self.sections[ip.section][@"rows"][ip.row]; UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting"];
 if(!cell) cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"setting"];
 cell.textLabel.text=title; cell.backgroundColor=[UIColor colorWithWhite:0.11 alpha:1]; cell.textLabel.textColor=UIColor.whiteColor;
 if(ip.section==1){ UISwitch *sw=[UISwitch new]; NSString *key=@[@"allowBackgroundPlayback",@"autoPiP",@"rememberChannel"][ip.row]; sw.on=ip.row==2?[[NSUserDefaults standardUserDefaults] boolForKey:key]:[[NSUserDefaults standardUserDefaults] boolForKey:key]; sw.onTintColor=UIColor.systemPinkColor; sw.accessibilityIdentifier=key; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw; }
 else { cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; cell.detailTextLabel.text=ip.row==2?@"0.14.0":@""; cell.detailTextLabel.textColor=UIColor.secondaryLabelColor; }
 return cell;
}
- (void)toggle:(UISwitch *)sw { [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:sw.accessibilityIdentifier]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip { [tableView deselectRowAtIndexPath:ip animated:YES]; if(ip.section==0&&ip.row==1){ UIAlertController *a=[UIAlertController alertControllerWithTitle:@"清理缓存" message:@"节目单缓存将在下次打开时重新获取。" preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]]; [a addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ NSString *p=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"cctv-epg-cache.json"]; [[NSFileManager defaultManager] removeItemAtPath:p error:nil]; }]]; [self presentViewController:a animated:YES completion:nil]; } }
@end
