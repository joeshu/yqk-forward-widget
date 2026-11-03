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
        for(NSString *key in keys){id value=row[key];if([value isKindOfClass:NSString.class]&&[[(NSString *)value lowercaseString] containsString:query])return YES;}
        return NO;
    }]];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {self.searchText=searchController.searchBar.text?:@"";[self.tableView reloadData];}
- (void)viewDidLoad {
    [super viewDidLoad];NSString *catalogName=[self.catalog[@"name"] isKindOfClass:NSString.class]?self.catalog[@"name"]:@"";self.title=(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])?@"资源合集":catalogName;self.navigationItem.prompt=@"点按需要的站点按需加载 · 不必全量导入";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
    self.searchController=[[UISearchController alloc] initWithSearchResultsController:nil];self.searchController.searchResultsUpdater=self;self.searchController.obscuresBackgroundDuringPresentation=NO;self.searchController.searchBar.placeholder=@"搜索合集中的站点、协议或 URL";self.searchController.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchController.searchBar.autocorrectionType=UITextAutocorrectionTypeNo;self.navigationItem.searchController=self.searchController;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"square.and.arrow.down",@"title":@"全量导入（较慢）",@"action":[UIAction actionWithHandler:^(UIAction *a){
            TVBoxCatalogViewController *owner=weakSelf;if(!owner)return;
            NSUInteger scripts=0,native=0,live=0,unsupported=0;
            for(NSDictionary *site in owner.sites){if(![site[@"supported"] boolValue])unsupported++;else if([site[@"apiKind"] isEqual:@"script"])scripts++;else native++;}
            for(NSDictionary *row in owner.lives){if([row[@"supported"] boolValue])live++;else unsupported++;}
            NSString *message=[NSString stringWithFormat:@"推荐按需加载：回到首页或影视库，点顶部资源按钮，选择本合集，再点选需要的站点。这样只会下载所选脚本。\n\n全量影视导入会检查并下载 %lu 个脚本站点，耗时较长；%lu 个原生 API 站点可直接按需使用，%lu 个不兼容项仍保留在合集里。%lu 个直播清单不会整包订阅，会继续留在本合集，点选其中一个后才加载。",(unsigned long)scripts,(unsigned long)native,(unsigned long)unsupported,(unsigned long)live];
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"全量影视导入（较慢）" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"仍然导入影视脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if(owner.onImportCompatibleContents)owner.onImportCompatibleContents();}]];
            [owner presentViewController:alert animated:YES completion:nil];
        }]},
        @{@"icon":@"square.and.arrow.up",@"title":@"导出完整合集 JSON",@"action":[UIAction actionWithHandler:^(UIAction *a){if(weakSelf.onExportCatalog)weakSelf.onExportCatalog(@"json");}]},
        @{@"icon":@"archivebox",@"title":@"导出完整资源 ZIP（含 PY / JS）",@"action":[UIAction actionWithHandler:^(UIAction *a){if(weakSelf.onExportCatalog)weakSelf.onExportCatalog(@"zip");}]},
        @{@"icon":@"trash",@"title":@"移除资源合集",@"action":[UIAction actionWithHandler:^(UIAction *a){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除资源合集？" message:@"仅移除这份集合索引；已导入的脚本和直播订阅会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除合集" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){if(weakSelf.onRemove)weakSelf.onRemove();}]];[weakSelf presentViewController:alert animated:YES completion:nil];}]}
    ])];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self filteredRowsForSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {NSArray *rows=[self filteredRowsForSection:section];return section==0?[NSString stringWithFormat:@"影视站点 · %lu",(unsigned long)rows.count]:[NSString stringWithFormat:@"直播列表 · %lu",(unsigned long)rows.count];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"推荐按需加载：在首页顶部选择本合集，再从右侧胶囊点选站点；仅所选脚本会下载，type 1/4 JSON API 会直接读取。不兼容项会保留并标注。";return @"点按需要的直播清单即可加载；同一直播合集只保留当前选择的一个清单，其他清单仍留在合集内。刷新播放列表时会应用合集提供的 UA。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"tvbox.catalog.row"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tvbox.catalog.row"];cell.backgroundColor=HostCard();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.textColor=UIColor.labelColor;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    NSDictionary *row=[self filteredRowsForSection:ip.section][ip.row];cell.textLabel.text=row[@"name"]?:@"未命名";
    BOOL supported=[row[@"supported"] boolValue];NSDictionary *service=ip.section==0&&self.serviceForSite?self.serviceForSite(row):nil;NSString *status=row[@"status"]?:@"";if(service)status=[service[@"enabled"] boolValue]?@"服务运行中 · 点按打开资源":@"服务已导入 · 点按启动并打开资源";cell.detailTextLabel.text=ip.section==0?[NSString stringWithFormat:@"%@\n%@",status,row[@"api"]?:@""]:[NSString stringWithFormat:@"%@\n%@",status,row[@"url"]?:@""];cell.accessoryType=supported?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=supported?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.textLabel.textColor=supported?UIColor.labelColor:UIColor.tertiaryLabelColor;return cell;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSDictionary *row=[self filteredRowsForSection:ip.section][ip.row];NSString *kind=ip.section==0?@"site":@"live";NSUInteger index=[row[@"sourceIndex"] respondsToSelector:@selector(unsignedIntegerValue)]?[row[@"sourceIndex"] unsignedIntegerValue]:(NSUInteger)ip.row;NSString *title=[row[@"name"] isKindOfClass:NSString.class]?row[@"name"]:@"资源";__weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:[NSString stringWithFormat:@"%@:%@:%lu",self.catalog[@"id"]?:@"",kind,(unsigned long)index] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        UIAction *export=[UIAction actionWithTitle:[NSString stringWithFormat:@"导出 %@ JSON",title] image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action){if(weakSelf.onExportSingleResource)weakSelf.onExportSingleResource(row,kind,index);}];
        return [UIMenu menuWithTitle:@"单项资源" children:@[export]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];NSDictionary *row=[self filteredRowsForSection:ip.section][ip.row];
    if(ip.section==1){if([row[@"supported"] boolValue]&&self.onSubscribeLive)self.onSubscribeLive(row);return;}
    if(![row[@"supported"] boolValue])return;
    BOOL nativeAPI=[row[@"apiKind"] isEqual:@"tvbox-api"]||[row[@"apiKind"] isEqual:@"maccms-api"]||[row[@"apiKind"] isEqual:@"douban-index"];if(nativeAPI){if(self.onUseNativeSite)self.onUseNativeSite(row);return;}
    NSDictionary *existing=self.serviceForSite?self.serviceForSite(row):nil;UIAlertController *alert=[UIAlertController alertControllerWithTitle:row[@"name"] message:existing?@"此脚本已在资源中。打开后会启动该资源并进入影视库。":@"仅对当前选择的站点执行脚本导入。可直接导入并浏览，也可先保存到资源页。ext 会作为 Spider 初始化配置传递。" preferredStyle:UIAlertControllerStyleActionSheet];
    if(existing){[alert addAction:[UIAlertAction actionWithTitle:@"启动并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onUseImportedService)self.onUseImportedService(existing);}]];[alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onOpenImportedService)self.onOpenImportedService(existing);}]];}
    else {[alert addAction:[UIAlertAction actionWithTitle:@"导入并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,YES);}]];[alert addAction:[UIAlertAction actionWithTitle:@"仅导入到资源页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,NO);}]];}
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(alert.popoverPresentationController){UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];alert.popoverPresentationController.sourceView=cell;alert.popoverPresentationController.sourceRect=cell.bounds;}
    [self presentViewController:alert animated:YES completion:nil];
}
@end
