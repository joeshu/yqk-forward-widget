#import "TVBoxCatalogViewController.h"
#import "TVBoxCatalogStore.h"
#import "HostTheme.h"
#import "HostToolbar.h"

@interface TVBoxCatalogViewController () <UISearchResultsUpdating>
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,copy) NSString *searchText;
@end

@implementation TVBoxCatalogViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSArray *)sites { return [self.catalog[@"sites"] isKindOfClass:NSArray.class]?self.catalog[@"sites"]:@[]; }
- (NSArray *)lives { return [self.catalog[@"lives"] isKindOfClass:NSArray.class]?self.catalog[@"lives"]:@[]; }
- (NSArray *)filteredRowsForSection:(NSInteger)section {
    NSArray *rows=section==0?self.sites:self.lives;NSString *query=self.searchText.lowercaseString;
    if(!query.length)return rows;
    return [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){
        NSArray *keys=section==0?@[@"name",@"status",@"api"]:@[@"name",@"url"];
        for(NSString *key in keys){id value=row[key];if([value isKindOfClass:NSString.class]&&[value.lowercaseString containsString:query])return YES;}
        return NO;
    }]];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {self.searchText=searchController.searchBar.text?:@"";[self.tableView reloadData];}
- (void)viewDidLoad {
    [super viewDidLoad];NSString *catalogName=[self.catalog[@"name"] isKindOfClass:NSString.class]?self.catalog[@"name"]:@"";self.title=(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])?@"资源合集":catalogName;self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
    self.searchController=[[UISearchController alloc] initWithSearchResultsController:nil];self.searchController.searchResultsUpdater=self;self.searchController.obscuresBackgroundDuringPresentation=NO;self.searchController.searchBar.placeholder=@"搜索合集中的站点、协议或 URL";self.searchController.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchController.searchBar.autocorrectionType=UITextAutocorrectionTypeNo;self.navigationItem.searchController=self.searchController;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"trash",@"title":@"移除资源合集",@"action":[UIAction actionWithHandler:^(UIAction *a){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除资源合集？" message:@"仅移除这份集合索引；已导入的脚本和直播订阅会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除合集" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){if(weakSelf.onRemove)weakSelf.onRemove();}]];[weakSelf presentViewController:alert animated:YES completion:nil];}]}])];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self filteredRowsForSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {NSArray *rows=[self filteredRowsForSection:section];return section==0?[NSString stringWithFormat:@"影视站点 · %lu",(unsigned long)rows.count]:[NSString stringWithFormat:@"直播列表 · %lu",(unsigned long)rows.count];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"合集仅保存索引，不会批量请求或启动站点。选择单个脚本后，可导入并浏览；已导入脚本可直接启动。TVBox type 1/4 JSON API 按需访问，Android/JAR 类型不支持。";return @"点按单个直播源后才会加入频道订阅。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"tvbox.catalog.row"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tvbox.catalog.row"];cell.backgroundColor=HostCard();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.textColor=UIColor.labelColor;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    NSDictionary *row=[self filteredRowsForSection:ip.section][ip.row];cell.textLabel.text=row[@"name"]?:@"未命名";
    BOOL supported=ip.section==1||[row[@"supported"] boolValue];NSDictionary *service=ip.section==0&&self.serviceForSite?self.serviceForSite(row):nil;NSString *status=row[@"status"]?:@"";if(service)status=[service[@"enabled"] boolValue]?@"服务运行中 · 点按打开资源":@"服务已导入 · 点按启动并打开资源";cell.detailTextLabel.text=ip.section==0?[NSString stringWithFormat:@"%@\n%@",status,row[@"api"]?:@""]:row[@"url"];cell.accessoryType=supported?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=supported?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.textLabel.textColor=supported?UIColor.labelColor:UIColor.tertiaryLabelColor;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];NSDictionary *row=[self filteredRowsForSection:ip.section][ip.row];
    if(ip.section==1){if(self.onSubscribeLive)self.onSubscribeLive(row);return;}
    if(![row[@"supported"] boolValue])return;
    BOOL nativeAPI=[row[@"apiKind"] isEqual:@"tvbox-api"]||[row[@"apiKind"] isEqual:@"maccms-api"];if(nativeAPI){if(self.onUseNativeSite)self.onUseNativeSite(row);return;}
    NSDictionary *existing=self.serviceForSite?self.serviceForSite(row):nil;UIAlertController *alert=[UIAlertController alertControllerWithTitle:row[@"name"] message:existing?@"此脚本已在资源中。打开后会启动该资源并进入影视库。":@"仅对当前选择的站点执行脚本导入。可直接导入并浏览，也可先保存到资源页。ext 会作为 Spider 初始化配置传递。" preferredStyle:UIAlertControllerStyleActionSheet];
    if(existing){[alert addAction:[UIAlertAction actionWithTitle:@"启动并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onUseImportedService)self.onUseImportedService(existing);}]];[alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onOpenImportedService)self.onOpenImportedService(existing);}]];}
    else {[alert addAction:[UIAlertAction actionWithTitle:@"导入并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,YES);}]];[alert addAction:[UIAlertAction actionWithTitle:@"仅导入到资源页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,NO);}]];}
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(alert.popoverPresentationController){UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];alert.popoverPresentationController.sourceView=cell;alert.popoverPresentationController.sourceRect=cell.bounds;}
    [self presentViewController:alert animated:YES completion:nil];
}
@end
