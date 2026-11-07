#import "SubscriptionResourceViewController.h"
#import "HostTheme.h"
#import "HostLogRedactor.h"
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
- (UITextField *)field:(NSString *)placeholder allowPaste:(BOOL)allowPaste tag:(NSInteger)tag {
    UITextField *field=[UITextField new];field.placeholder=placeholder;field.textColor=HostText();field.tintColor=HostAccent();field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];field.adjustsFontForContentSizeCategory=YES;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;field.clearButtonMode=UITextFieldViewModeWhileEditing;[field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
    if(allowPaste){
        UIButton *pasteBtn=[UIButton buttonWithType:UIButtonTypeSystem];
        pasteBtn.tag=tag;
        [pasteBtn setTitle:@"粘贴" forState:UIControlStateNormal];
        pasteBtn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        pasteBtn.tintColor=HostAccent();
        pasteBtn.frame=CGRectMake(0,0,44,32);
        pasteBtn.backgroundColor=HostSelectedSurface();
        pasteBtn.layer.cornerRadius=10;
        pasteBtn.layer.cornerCurve=kCACornerCurveContinuous;
        HostInstallPressFeedback(pasteBtn);
        [pasteBtn addTarget:self action:@selector(pasteIntoField:) forControlEvents:UIControlEventTouchUpInside];
        field.rightView=pasteBtn;
        field.rightViewMode=UITextFieldViewModeUnlessEditing;
    }
    return field;
}
- (void)pasteIntoField:(UIButton *)sender {
    if(!self.editingResource||self.saving)return;
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clip.length)return;
    UITextField *target=sender.tag==1?self.urlField:self.epgField;
    if(!target.enabled)return;
    target.text=clip;
    [self changed];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"直播资源";self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=64;
    self.nameField=[self field:@"资源名称" allowPaste:NO tag:0];self.urlField=[self field:@"HTTP / HTTPS 订阅地址" allowPaste:YES tag:1];self.urlField.keyboardType=UIKeyboardTypeURL;self.epgField=[self field:@"留空使用列表提供的 EPG" allowPaste:YES tag:2];self.epgField.keyboardType=UIKeyboardTypeURL;self.editingResource=self.initiallyEditing;[self loadFields];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(close)];[self updateAction];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(metadataChanged) name:ProfileStoreMetadataDidChangeNotification object:nil];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.nameField.textColor=HostText();self.nameField.tintColor=HostAccent();
    self.urlField.textColor=HostText();self.urlField.tintColor=HostAccent();
    self.epgField.textColor=HostText();self.epgField.tintColor=HostAccent();
    [self.tableView reloadData];
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
- (NSArray<NSDictionary *> *)managementRows {
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray arrayWithObjects:
        @{@"title":@"查看频道",@"icon":@"play.tv",@"action":@"open"},
        @{@"title":@"刷新此订阅",@"icon":@"arrow.clockwise",@"action":@"refresh"},
        nil];
    if(self.source.length&&self.onRecheckHealth)[rows addObject:@{@"title":@"重新检测健康",@"icon":@"checkmark.shield",@"action":@"recheck"}];
    if(self.source.length&&self.onRematchEPG)[rows addObject:@{@"title":@"重新匹配节目单（EPG）",@"icon":@"calendar.badge.clock",@"action":@"rematch"}];
    [rows addObject:@{@"title":@"导出单项资源文件",@"icon":@"square.and.arrow.up",@"action":@"export"}];
    if(self.source.length)[rows addObject:@{@"title":@"复制订阅地址",@"icon":@"doc.on.doc",@"action":@"copy"}];
    if(self.source.length&&self.onDelete)[rows addObject:@{@"title":@"移除此订阅",@"icon":@"trash",@"action":@"delete",@"destructive":@YES}];
    return rows;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?3:(section==1?2:self.managementRows.count);}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"资源配置",@"内容状态",@"使用与管理"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return self.notice?:@"修改订阅地址会先读取新清单，验证成功后替换。EPG 留空使用列表自动提供的地址。";return nil;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor=HostCard();
    cell.layer.cornerRadius=14;
    cell.layer.cornerCurve=kCACornerCurveContinuous;
    cell.clipsToBounds=YES;
    cell.layer.borderWidth=0.6;
    HostSetLayerBorderColor(cell,HostBorder());
    cell.textLabel.textColor=HostText();
    cell.detailTextLabel.textColor=HostSecondaryText();
    cell.textLabel.numberOfLines=0;
    cell.detailTextLabel.numberOfLines=0;
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    NSDictionary *profile=self.profileProvider?self.profileProvider():@{};
    if(ip.section==0){
        NSString *rowTitle=@[@"名称",@"订阅来源",@"XMLTV / EPG"][ip.row];
        if(self.editingResource){
            cell.textLabel.text=nil;
            cell.detailTextLabel.text=nil;
            UITextField *field=@[self.nameField,self.urlField,self.epgField][ip.row];
            field.accessibilityLabel=rowTitle;
            UILabel *label=[UILabel new];
            label.text=rowTitle;
            label.textColor=HostSecondaryText();
            label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            label.adjustsFontForContentSizeCategory=YES;
            label.numberOfLines=0;
            UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,field]];
            stack.translatesAutoresizingMaskIntoConstraints=NO;
            stack.axis=UILayoutConstraintAxisVertical;
            stack.alignment=UIStackViewAlignmentFill;
            stack.spacing=6;
            [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
            [cell.contentView addSubview:stack];
            [NSLayoutConstraint activateConstraints:@[
                [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
            ]];
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }else{
            cell.textLabel.text=rowTitle;
            cell.imageView.image=[UIImage systemImageNamed:@[@"tag",@"link",@"calendar.badge.clock"][ip.row]];
            cell.imageView.tintColor=HostAccent();
            NSURL *url=[NSURL URLWithString:self.source];
            NSDictionary *meta=[ProfileStore metadata:self.source];
            NSString *epgURL=self.epgField.text.length?self.epgField.text:(meta[@"detectedEPGURL"]?:@"");
            cell.detailTextLabel.text=ip.row==0?self.nameField.text:(ip.row==1?(url.host.length?[NSString stringWithFormat:@"%@ · %@",url.host,url.lastPathComponent?:@""]:([self.source hasPrefix:@"local-playlist:"]?@"本地文件":@"官方频道目录")):(epgURL.length?[NSString stringWithFormat:@"已配置 EPG · %@",[HostLogRedactor redactText:epgURL]]:@"自动使用列表提供的 EPG"));
            if(ip.row>0&&self.source.length)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    else if(ip.section==1){
        cell.textLabel.text=ip.row==0?[NSString stringWithFormat:@"%@ 个缓存频道",profile[@"count"]?:@0]:(profile[@"status"]?:@"尚未检查");
        if(ip.row==0){
            cell.detailTextLabel.text=profile[@"epgStatus"]?:@"EPG 自动匹配";
            cell.imageView.image=[UIImage systemImageNamed:@"tv"];
        }else{
            NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];
            if(updated>0){
                static NSDateFormatter *fmt;static dispatch_once_t once;
                dispatch_once(&once,^{fmt=[NSDateFormatter new];fmt.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];fmt.dateFormat=@"yyyy-MM-dd HH:mm";});
                cell.detailTextLabel.text=[NSString stringWithFormat:@"最近成功刷新：%@",[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]];
            }else{
                cell.detailTextLabel.text=@"尚无成功刷新时间记录";
            }
            cell.imageView.image=[UIImage systemImageNamed:@"checkmark.shield"];
        }
        cell.imageView.tintColor=HostAccent();
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else {
        NSArray<NSDictionary *> *rows=self.managementRows;
        if(ip.row>=0&&ip.row<(NSInteger)rows.count){
            NSDictionary *item=rows[ip.row];
            BOOL destructive=[item[@"destructive"] boolValue];
            cell.textLabel.text=item[@"title"];
            cell.textLabel.textColor=destructive?UIColor.systemRedColor:HostAccent();
            cell.imageView.image=[UIImage systemImageNamed:item[@"icon"]];
            cell.imageView.tintColor=destructive?UIColor.systemRedColor:HostAccent();
            cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}
- (void)confirmDeleteSubscription {
    if(!self.source.length||!self.onDelete)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除此订阅？" message:@"这会移除该订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"移除订阅" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        SubscriptionResourceViewController *owner=weakSelf;
        if(!owner)return;
        if(owner.onDelete)owner.onDelete();
        [owner.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(self.saving||self.editingResource)return;
    if(ip.section==0&&ip.row>0){NSString *value=ip.row==1?self.source:([ProfileStore metadata:self.source][@"epgURL"]?:[ProfileStore metadata:self.source][@"detectedEPGURL"]);if(!value.length)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:ip.row==1?@"完整订阅地址":@"EPG 地址" message:value preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"复制完整地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){UIPasteboard.generalPasteboard.string=value;}]];[alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
    else if(ip.section==2){
        NSArray<NSDictionary *> *rows=self.managementRows;
        if(ip.row<0||ip.row>=(NSInteger)rows.count)return;
        NSString *action=rows[ip.row][@"action"];
        if([action isEqual:@"open"]){if(self.onOpen)self.onOpen();}
        else if([action isEqual:@"refresh"]){if(self.onRefresh){self.onRefresh();self.notice=@"刷新请求已发起";[self.tableView reloadData];}}
        else if([action isEqual:@"recheck"]){if(self.onRecheckHealth){self.onRecheckHealth();self.notice=@"正在重新检测订阅健康状态…";[self.tableView reloadData];}}
        else if([action isEqual:@"rematch"]){if(self.onRematchEPG){self.onRematchEPG();self.notice=@"已发起节目单（EPG）重新匹配";[self.tableView reloadData];}}
        else if([action isEqual:@"export"]){if(self.onExport)self.onExport();}
        else if([action isEqual:@"copy"]){if(self.source.length){UIPasteboard.generalPasteboard.string=self.source;self.notice=@"订阅地址已复制到剪贴板";[self.tableView reloadData];}}
        else if([action isEqual:@"delete"]){[self confirmDeleteSubscription];}
    }
}
@end
