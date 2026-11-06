#import "SubscriptionResourceViewController.h"
#import "HostTheme.h"
#import "ProfileStore.h"
@interface SubscriptionResourceViewController () <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UITextField *nameField;
@property(nonatomic,strong) UITextField *urlField;
@property(nonatomic,strong) UITextField *epgField;
@property(nonatomic,copy) NSDictionary *snapshot;
@property(nonatomic) BOOL editingResource;
@property(nonatomic) BOOL saving;
@property(nonatomic,copy) NSString *notice;
@property(nonatomic,weak) id<UIGestureRecognizerDelegate> previousPopDelegate;
@end
@implementation SubscriptionResourceViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (UITextField *)field:(NSString *)placeholder {
    UITextField *field=[UITextField new];field.placeholder=placeholder;field.textColor=HostText();field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];field.adjustsFontForContentSizeCategory=YES;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;[field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];return field;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"直播资源";self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.nameField=[self field:@"资源名称"];self.urlField=[self field:@"HTTP / HTTPS 订阅地址"];self.urlField.keyboardType=UIKeyboardTypeURL;self.epgField=[self field:@"留空使用列表提供的 EPG"];self.epgField.keyboardType=UIKeyboardTypeURL;self.editingResource=self.initiallyEditing;[self loadFields];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(close)];[self updateAction];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(metadataChanged) name:ProfileStoreMetadataDidChangeNotification object:nil];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;self.previousPopDelegate=gesture.delegate;gesture.delegate=self;if(!self.editingResource)[self metadataChanged];}
- (void)viewWillDisappear:(BOOL)animated {[super viewWillDisappear:animated];UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;if(gesture.delegate==self)gesture.delegate=self.previousPopDelegate;}
- (NSDictionary *)values {return @{@"name":self.nameField.text?:@"",@"url":self.urlField.text?:@"",@"epg":self.epgField.text?:@""};}
- (void)loadFields {NSDictionary *metadata=[ProfileStore metadata:self.source],*profile=self.profileProvider?self.profileProvider():@{};self.nameField.text=metadata[@"name"]?:profile[@"name"]?:@"直播资源";self.urlField.text=self.source?:@"";self.epgField.text=metadata[@"epgURL"]?:@"";self.snapshot=[self values];}
- (void)metadataChanged {if(self.editingResource||self.saving)return;[self loadFields];[self.tableView reloadData];}
- (void)updateAction {
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:self.editingResource?(self.saving?@"验证中…":@"保存"):@"编辑" style:UIBarButtonItemStyleDone target:self action:self.editingResource?@selector(save):@selector(beginEditing)];self.navigationItem.rightBarButtonItem.enabled=!self.saving&&(self.editingResource?![[self values] isEqual:self.snapshot]:self.source.length>0);
    self.nameField.enabled=self.editingResource&&!self.saving;self.urlField.enabled=self.editingResource&&!self.saving&&[ProfileStore isHTTP:self.source];self.epgField.enabled=self.editingResource&&!self.saving;
}
- (void)changed {self.notice=nil;[self updateAction];}
- (void)beginEditing {self.editingResource=YES;[self loadFields];[self updateAction];[self.tableView reloadData];}
- (void)save {
    if(self.saving)return;NSString *name=[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*url=[self.urlField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*epg=[self.epgField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([ProfileStore isHTTP:self.source]){NSURLComponents *parts=[NSURLComponents componentsWithString:url];parts.scheme=parts.scheme.lowercaseString;parts.host=parts.host.lowercaseString;parts.fragment=nil;if(([parts.scheme isEqual:@"http"]&&parts.port.integerValue==80)||([parts.scheme isEqual:@"https"]&&parts.port.integerValue==443))parts.port=nil;url=parts.URL.absoluteString?:@"";}
    if(!name.length||([ProfileStore isHTTP:self.source]&&![ProfileStore isHTTP:url])||(epg.length&&![ProfileStore isHTTP:epg])){self.notice=@"请填写名称，并检查订阅或 EPG 的 HTTP / HTTPS 地址";[self.tableView reloadData];return;}if(!self.onCommit)return;
    [self.view endEditing:YES];self.saving=YES;[self updateAction];__weak typeof(self) weakSelf=self;
    self.onCommit(name,url,epg,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{SubscriptionResourceViewController *owner=weakSelf;if(!owner)return;owner.saving=NO;if(error)owner.notice=error.code==NSURLErrorCancelled?@"验证已取消，原订阅未改变":error.localizedDescription;else{owner.source=url;owner.editingResource=NO;owner.notice=@"已保存";[owner loadFields];}[owner updateAction];[owner.tableView reloadData];});});
}
- (void)close {
    if(self.saving)return;if(self.editingResource&&![[self values] isEqual:self.snapshot]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"有尚未保存的更改" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"放弃更改" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self.navigationController popViewControllerAnimated:YES];}]];[self presentViewController:alert animated:YES completion:nil];return;}[self.navigationController popViewControllerAnimated:YES];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {if(self.saving)return NO;if(self.editingResource&&![[self values] isEqual:self.snapshot]){[self close];return NO;}return YES;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?3:(section==1?2:3);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"资源配置",@"内容状态",@"使用与管理"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return self.notice?:@"修改订阅地址会先读取新清单，验证成功后替换。EPG 留空使用列表自动提供的地址。";return nil;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];NSDictionary *profile=self.profileProvider?self.profileProvider():@{};
    if(ip.section==0){cell.textLabel.text=@[@"名称",@"订阅来源",@"XMLTV / EPG"][ip.row];if(self.editingResource){UITextField *field=@[self.nameField,self.urlField,self.epgField][ip.row];[cell.contentView addSubview:field];field.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],[field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],[field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:32],[field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],[field.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];cell.selectionStyle=UITableViewCellSelectionStyleNone;}else{NSURL *url=[NSURL URLWithString:self.source];cell.detailTextLabel.text=ip.row==0?self.nameField.text:(ip.row==1?(url.host.length?[NSString stringWithFormat:@"%@ · %@",url.host,url.lastPathComponent?:@""]:@"本地文件"):(self.epgField.text.length?@"已指定 EPG 地址 · 点按查看":@"自动使用列表提供的 EPG"));if(ip.row>0)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}}
    else if(ip.section==1){cell.textLabel.text=ip.row==0?[NSString stringWithFormat:@"%@ 个缓存频道",profile[@"count"]?:@0]:(profile[@"status"]?:@"尚未检查");if(ip.row==0)cell.detailTextLabel.text=profile[@"epgStatus"]?:@"EPG 自动匹配";cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else {cell.textLabel.text=@[@"查看频道",@"刷新此订阅",@"导出单项资源文件"][ip.row];cell.textLabel.textColor=HostAccent();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(self.saving||self.editingResource)return;
    if(ip.section==0&&ip.row>0){NSString *value=ip.row==1?self.source:([ProfileStore metadata:self.source][@"epgURL"]?:[ProfileStore metadata:self.source][@"detectedEPGURL"]);if(!value.length)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:ip.row==1?@"完整订阅地址":@"EPG 地址" message:value preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"复制完整地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){UIPasteboard.generalPasteboard.string=value;}]];[alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
    else if(ip.section==2){if(ip.row==0&&self.onOpen)self.onOpen();else if(ip.row==1&&self.onRefresh){self.onRefresh();self.notice=@"刷新请求已发起";[self.tableView reloadData];}else if(ip.row==2&&self.onExport)self.onExport();}
}
@end
