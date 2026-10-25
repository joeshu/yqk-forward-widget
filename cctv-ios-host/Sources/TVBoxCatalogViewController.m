#import "TVBoxCatalogViewController.h"
#import "TVBoxCatalogStore.h"
#import "HostTheme.h"
#import "HostToolbar.h"

@implementation TVBoxCatalogViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSArray *)sites { return [self.catalog[@"sites"] isKindOfClass:NSArray.class]?self.catalog[@"sites"]:@[]; }
- (NSArray *)lives { return [self.catalog[@"lives"] isKindOfClass:NSArray.class]?self.catalog[@"lives"]:@[]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=self.catalog[@"name"]?:@"TVBox 资源目录"; self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"trash",@"title":@"移除目录",@"action":[UIAction actionWithHandler:^(UIAction *a){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除 TVBox 目录？" message:@"已导入的脚本和直播订阅会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除目录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){if(weakSelf.onRemove)weakSelf.onRemove();}]];[weakSelf presentViewController:alert animated:YES completion:nil];}]}])];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?self.sites.count:self.lives.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0? [NSString stringWithFormat:@"站点 · %lu",(unsigned long)self.sites.count]:[NSString stringWithFormat:@"直播列表 · %lu",(unsigned long)self.lives.count]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { if(section==0)return @"TVBox type 1/4 JSON API 和 MacCMS JSON/XML API 可在本机直接访问，不需要插件运行时；JS、Python 和 ZIP 站点走现有脚本适配器。Android/JAR 类型不支持。每个来源按需使用。";return @"直播地址会作为独立订阅导入，不会启动所有站点。"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"tvbox.catalog.row"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tvbox.catalog.row"];cell.backgroundColor=HostCard();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.textColor=UIColor.labelColor;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;
    NSDictionary *row=(ip.section==0?self.sites:self.lives)[ip.row];cell.textLabel.text=row[@"name"]?:@"未命名";
    BOOL supported=ip.section==1||[row[@"supported"] boolValue];cell.detailTextLabel.text=ip.section==0?[NSString stringWithFormat:@"%@\n%@",row[@"status"]?:@"",row[@"api"]?:@""]:row[@"url"];cell.accessoryType=supported?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=supported?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.textLabel.textColor=supported?UIColor.labelColor:UIColor.tertiaryLabelColor;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];NSDictionary *row=(ip.section==0?self.sites:self.lives)[ip.row];
    if(ip.section==1){if(self.onSubscribeLive)self.onSubscribeLive(row);return;}
    if(![row[@"supported"] boolValue])return;
    BOOL nativeAPI=[row[@"apiKind"] isEqual:@"tvbox-api"]||[row[@"apiKind"] isEqual:@"maccms-api"];NSString *protocol=[row[@"apiKind"] isEqual:@"maccms-api"]?@"MacCMS JSON/XML API":[NSString stringWithFormat:@"TVBox type %@ JSON API",row[@"type"]?:@"1"];UIAlertController *alert=[UIAlertController alertControllerWithTitle:row[@"name"] message:nativeAPI?[NSString stringWithFormat:@"此 %@ 将作为原生影视来源使用。请求仅在你选择它、搜索或浏览时发送。",protocol]:@"导入后先做静态入口检查，再由你决定是否启用。ext 会作为 Spider 初始化配置传递。" preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:nativeAPI?@"添加到影视来源":@"导入站点脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(nativeAPI){if(self.onUseNativeSite)self.onUseNativeSite(row);}else if(self.onImportSite)self.onImportSite(row);}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(alert.popoverPresentationController){UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];alert.popoverPresentationController.sourceView=cell;alert.popoverPresentationController.sourceRect=cell.bounds;}
    [self presentViewController:alert animated:YES completion:nil];
}
@end
