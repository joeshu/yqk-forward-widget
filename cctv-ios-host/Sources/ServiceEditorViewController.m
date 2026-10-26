#import "ServiceEditorViewController.h"
#import "HostTheme.h"
#import "PyHost.h"
#import "ServiceStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation ServiceCodeViewController {
    UITextView *_editor;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.readOnly ? @"查看代码" : @"编辑代码";
    self.view.backgroundColor = HostBackground();
    _editor = [UITextView new];
    _editor.translatesAutoresizingMaskIntoConstraints = NO;
    _editor.backgroundColor = HostCard();
    _editor.textColor = HostText();
    UIFont *baseCodeFont=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    _editor.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:baseCodeFont];
    _editor.adjustsFontForContentSizeCategory=YES;
    _editor.editable = !self.readOnly;
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.text=@"正在读取代码…";_editor.editable=NO;
    NSString *path=self.path;NSUInteger limit=self.readOnly?64*1024:2*1024*1024;__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSError *error=nil;NSData *data=nil;NSFileHandle *file=path.length?[NSFileHandle fileHandleForReadingAtPath:path]:nil;
        @try{if(file)data=[file readDataUpToLength:limit+1 error:&error];}@catch(NSException *exception){error=[NSError errorWithDomain:@"CCTVHostCode" code:1 userInfo:nil];}@finally{[file closeAndReturnError:NULL];}
        BOOL truncated=data.length>limit;if(truncated)data=[data subdataWithRange:NSMakeRange(0,limit)];
        NSString *text=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
        for(NSUInteger trim=1;!text && truncated && trim<=3;trim++)text=[[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0,data.length-trim)] encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(),^{ServiceCodeViewController *owner=weakSelf;if(!owner)return;
            if(!text || error){owner->_editor.text=@"无法读取 UTF-8 代码文件";owner.navigationItem.rightBarButtonItem=nil;return;}
            owner->_editor.text=text;if(truncated){owner.readOnly=YES;owner.navigationItem.rightBarButtonItem=nil;owner.navigationItem.prompt=@"只读预览已截断，导出包含完整文件";}
            owner->_editor.editable=!owner.readOnly;owner.navigationItem.rightBarButtonItem.enabled=YES;
        });
    }});
    [self.view addSubview:_editor];
    [NSLayoutConstraint activateConstraints:@[
        [_editor.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_editor.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_editor.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_editor.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]
    ]];
    if (!self.readOnly)
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                          target:self
                                                          action:@selector(save)];
}
- (void)save {
    if(!_editor.editable)return;
    NSError *error = nil;
    BOOL ok = [_editor.text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (ok)
        [self.navigationController popViewControllerAnimated:YES];
    else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"保存失败"
                                                                   message:error.localizedDescription
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

@interface ServiceEditorViewController () <UIDocumentPickerDelegate>
- (BOOL)customCodeMatchesSavedVersion;
- (BOOL)writeCodeForService:(NSDictionary *)service;
- (void)applyPortChange:(NSDictionary *)service;
- (void)persistService:(NSDictionary *)service;
- (void)finishSavingService:(NSDictionary *)service;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UITextField *playlistPathField;
@property(nonatomic, strong) UITextField *urlField;
@property(nonatomic, strong) UITextField *argsField;
@property(nonatomic, strong) UISwitch *lanSwitch;
@property(nonatomic, strong) UISegmentedControl *sourceControl;
@property(nonatomic, strong) UILabel *fileLabel;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *code;
@property(nonatomic, strong) NSURLSessionDataTask *downloadTask;
@property(nonatomic, assign) BOOL downloading;
@property(nonatomic, copy) NSString *optionsText;
@property(nonatomic, assign) BOOL applyingPortChange;
@end
@implementation ServiceEditorViewController
- (BOOL)managedCode {return [self.service[@"builtin"] boolValue] || [self.service[@"manifest"] isKindOfClass:NSDictionary.class];}
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (UITextField *)field:(NSString *)placeholder value:(NSString *)value {
    UITextField *f = [UITextField new];
    f.placeholder = placeholder;
    f.text = value;
    f.textColor = HostText();
    f.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    f.adjustsFontForContentSizeCategory=YES;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.service ? @"编辑服务" : @"添加服务";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.identifier = self.service[@"id"] ?: NSUUID.UUID.UUIDString;
    self.nameField = [self field:@"服务名称" value:self.service[@"name"]];
    self.portField = [self field:@"端口 1024–65535" value:[self.service[@"port"] description] ?: @"18768"];
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    NSString *configuredPlaylistPath=[self.service[@"playlistPathSource"] isEqual:@"inferred"]?@"":[ServiceStore playlistPathForService:self.service];
    self.playlistPathField=[self field:@"留空自动识别，或填 /all.m3u" value:configuredPlaylistPath];self.playlistPathField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.urlField = [self field:@"https://…/service.py" value:self.service[@"url"]];
    self.urlField.keyboardType = UIKeyboardTypeURL;
    [self.urlField addTarget:self action:@selector(urlChanged) forControlEvents:UIControlEventEditingChanged];
    self.argsField = [self field:@"参数以 | 分隔，可用 {port} / {bind}" value:self.service[@"arguments"]];
    self.lanSwitch = [UISwitch new];
    self.lanSwitch.onTintColor = HostAccent();
    self.lanSwitch.on = [self.service[@"lan"] boolValue];
    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[ @"文件", @"链接", @"代码" ]];
    self.sourceControl.accessibilityLabel=@"服务代码来源";
    self.sourceControl.selectedSegmentIndex = 1;
    [self.sourceControl addTarget:self
                           action:@selector(sourceChanged)
                 forControlEvents:UIControlEventValueChanged];
    if (self.service && ![self managedCode])
        self.code = [NSString stringWithContentsOfFile:[ServiceStore codePath:self.service]
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    self.fileLabel = [UILabel new];
    self.fileLabel.textColor = UIColor.secondaryLabelColor;
    self.fileLabel.font = [UIFont systemFontOfSize:12];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(save)];
}
- (void)dealloc {
    [self.downloadTask cancel];
}
- (void)urlChanged {
    if (![self managedCode])
        self.code = nil;
}
- (void)sourceChanged {
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0   ? 2
           : section == 1 ? ([self managedCode] ? 1 : 3)
           : section == 2 ? ([self.service[@"builtin"] boolValue] ? 1 : 3)
                          : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ ([self.service[@"engine"] isEqual:@"javascript"]?@"JavaScript 服务":@"Python 服务"), @"代码来源", @"网络与启动", @"" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return @"导入后可查看、编辑或导出代码。内置服务代码只读。";
    if (section == 2)
        return @"自定义脚本的参数用 | 分隔，支持 {port}、{bind}、{dataDir}。直播列表路径可留空自动识别；手动填写时只接受本机绝对路径，例如 /all.m3u。服务可按 ID 分别启停；"
               @"并行运行时每个 HTTP 服务必须使用不同端口。常见 Python HTTPServer 会采用这里设置的端口；其他框架请将启动参数设为 {port} 或读取 CCTVHOST_PORT。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.backgroundColor = HostCard();
    c.textLabel.textColor = HostText();
    c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines=0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *input = nil;
    if (ip.section == 0) {
        c.textLabel.text = ip.row == 0 ? @"服务名称" : @"本机端口";
        input = ip.row == 0 ? self.nameField : self.portField;
    } else if (ip.section == 1) {
        if ([self managedCode]) {
            c.textLabel.text = [self.service[@"manifest"] isKindOfClass:NSDictionary.class]?@"查看资源入口代码":@"查看内置代码";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 0)
            input = self.sourceControl;
        else if (ip.row == 1) {
            if (self.sourceControl.selectedSegmentIndex == 1) {
                c.textLabel.text=@"远程代码 URL";
                input = self.urlField;
            } else {
                c.textLabel.text =
                    self.sourceControl.selectedSegmentIndex == 0 ? @"选择 Python 文件" : @"输入 / 编辑代码";
                c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                c.selectionStyle = UITableViewCellSelectionStyleDefault;
            }
        } else {
            c.textLabel.text = self.downloading   ? @"正在加载…"
                               : self.code.length ? @"代码已加载 · 点击查看"
                                                  : @"加载代码";
            c.textLabel.textColor = HostAccent();
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (ip.section == 2) {
        if (ip.row == 0) {
            if ([self managedCode]) {
                c.textLabel.text = @"允许局域网访问";
                c.accessoryView = self.lanSwitch;
            } else {
                c.textLabel.text = @"网络绑定";
                c.detailTextLabel.text = @"由脚本启动参数决定";
            }
        } else if(ip.row == 1 && [self.service[@"manifest"] isKindOfClass:NSDictionary.class]){
            c.textLabel.text=@"插件参数";c.detailTextLabel.text=@"编辑账号、画质等 JSON 配置";c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;c.selectionStyle=UITableViewCellSelectionStyleDefault;
        }else if(ip.row==1){c.textLabel.text=@"启动参数";input=self.argsField;}
        else{c.textLabel.text=@"直播列表路径";input=self.playlistPathField;}
    } else {
        c.textLabel.text = @"保存服务";
        c.textLabel.textColor = HostAccent();
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    if (input) {
        NSString *rowTitle=[c.textLabel.text copy];
        c.textLabel.text=nil;
        c.detailTextLabel.text=nil;
        c.accessoryType=UITableViewCellAccessoryNone;
        UIStackView *stack=[[UIStackView alloc] init];
        stack.translatesAutoresizingMaskIntoConstraints=NO;
        stack.axis=UILayoutConstraintAxisVertical;
        stack.alignment=UIStackViewAlignmentFill;
        stack.spacing=rowTitle.length?6:0;
        if(rowTitle.length){
            UILabel *title=[UILabel new];
            title.text=rowTitle;
            title.textColor=HostSecondaryText();
            title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            title.adjustsFontForContentSizeCategory=YES;
            title.numberOfLines=0;
            [stack addArrangedSubview:title];
            input.accessibilityLabel=rowTitle;
        }
        input.translatesAutoresizingMaskIntoConstraints=NO;
        [stack addArrangedSubview:input];
        [input.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
        [c.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-16],
            [stack.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:10],
            [stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-10]
        ]];
    } else {
        c.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        c.detailTextLabel.numberOfLines=0;
    }
    return c;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 3) {
        [self save];
        return;
    }
    if(ip.section==2 && ip.row==1 && [self.service[@"manifest"] isKindOfClass:NSDictionary.class]){
        NSString *path=[self optionsDraftPath];id options=self.service[@"manifest"][@"options"]?:@{};
        NSData *data=[NSJSONSerialization dataWithJSONObject:options options:NSJSONWritingPrettyPrinted|NSJSONWritingFragmentsAllowed error:NULL];
        if(![NSFileManager.defaultManager fileExistsAtPath:path])[data writeToFile:path atomically:YES];
        ServiceCodeViewController *editor=[ServiceCodeViewController new];editor.path=path;[self.navigationController pushViewController:editor animated:YES];return;
    }
    if (ip.section != 1)
        return;
    if ([self managedCode]) {
        [self editManual];
        return;
    }
    if (ip.row == 1 && self.sourceControl.selectedSegmentIndex == 0) {
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[ UTTypePythonScript, UTTypePlainText ]
                                asCopy:YES];
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    } else if (ip.row == 1 && self.sourceControl.selectedSegmentIndex == 2) {
        [self editManual];
    } else if (ip.row == 2) {
        if (self.sourceControl.selectedSegmentIndex == 1 && !self.code.length)
            [self loadRemote];
        else
            [self editManual];
    }
}
- (void)message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"资源配置"
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)acceptCode:(NSData *)data {
    if (data.length > 2 * 1024 * 1024) {
        [self message:@"文件超过 2 MB，请选择较小的 Python 脚本。"];
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text.length) {
        [self message:@"无法读取 UTF-8 Python 代码。"];
        return;
    }
    self.code = text;
    [self.tableView reloadData];
}
- (void)loadRemote {
    NSURL *url = [NSURL URLWithString:self.urlField.text];
    if (!([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"]) ||
        !url.host.length) {
        [self message:@"请输入有效的 HTTP 或 HTTPS 代码链接。"];
        return;
    }
    self.downloading = YES;
    [self.tableView reloadData];
    __weak typeof(self) w = self;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 20;
    self.downloadTask = [NSURLSession.sharedSession
        dataTaskWithRequest:r
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              w.downloading = NO;
              if (error || [(NSHTTPURLResponse *)response statusCode] != 200)
                  [w message:error.localizedDescription ?: @"下载失败，请检查代码链接。"];
              else
                  [w acceptCode:data];
              [w.tableView reloadData];
            });
          }];
    [self.downloadTask resume];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject;
    BOOL scoped = [u startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:u];
    if (scoped)
        [u stopAccessingSecurityScopedResource];
    [self acceptCode:data];
}
- (NSString *)draftPath {
    return [[ServiceStore directory]
        stringByAppendingPathComponent:[self.identifier stringByAppendingString:@"-draft.py"]];
}
- (NSString *)optionsDraftPath {return [[ServiceStore directory] stringByAppendingPathComponent:[self.identifier stringByAppendingString:@"-options.json"]];}
- (void)editManual {
    if([self managedCode]){ServiceCodeViewController *view=[ServiceCodeViewController new];view.path=[ServiceStore codePath:self.service];view.readOnly=YES;[self.navigationController pushViewController:view animated:YES];return;}
    NSString *path = [self draftPath];
    [self.code ?: @"# Python service\n" writeToFile:path
                                         atomically:YES
                                           encoding:NSUTF8StringEncoding
                                              error:NULL];
    ServiceCodeViewController *v = [ServiceCodeViewController new];
    v.path = path;
    v.readOnly = [self managedCode];
    [self.navigationController pushViewController:v animated:YES];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *text = [NSString stringWithContentsOfFile:[self draftPath]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text)
        self.code = text;
    self.optionsText=[NSString stringWithContentsOfFile:[self optionsDraftPath] encoding:NSUTF8StringEncoding error:NULL];
    [self.tableView reloadData];
}
- (void)save {
    if(self.applyingPortChange)return;
    NSInteger port = self.portField.text.integerValue;
    NSString *name =
        [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || port < 1024 || port > 65535) {
        [self message:@"请填写名称，以及 1024–65535 范围内的端口。"];
        return;
    }
    if (![self managedCode] && !self.code.length) {
        [self message:@"请先加载或输入 Python 代码。"];
        return;
    }
    NSMutableDictionary *service = [self.service ?: @{} mutableCopy];
    service[@"id"] = self.identifier;
    service[@"name"] = name;
    service[@"port"] = @(port);
    service[@"lan"] = @(self.lanSwitch.on);
    NSString *arguments=self.argsField.text?:@"";
    if(![arguments isEqual:(self.service[@"arguments"]?:@"")])service[@"argumentsSource"]=@"manual";
    service[@"arguments"] = arguments;
    service[@"url"] = self.urlField.text ?: @"";
    NSString *playlistPath=[self.playlistPathField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(playlistPath.length){if(![playlistPath hasPrefix:@"/"]||[playlistPath hasPrefix:@"//"]||playlistPath.length>=128||[playlistPath containsString:@".."]||[playlistPath containsString:@"?"]||[playlistPath containsString:@"#"]||[playlistPath containsString:@"\\"]||[playlistPath containsString:@":"]||[playlistPath rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[self message:@"直播列表路径须以单个 / 开头，且不能包含 ..、查询参数、片段或控制字符。例：/all.m3u"];return;}service[@"playlistPath"]=playlistPath;service[@"playlistPathSource"]=@"manual";}else{[service removeObjectForKey:@"playlistPath"];[service removeObjectForKey:@"playlistPathSource"];}
    service[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    if([service[@"manifest"] isKindOfClass:NSDictionary.class] && self.optionsText){
        NSError *jsonError=nil;id options=[NSJSONSerialization JSONObjectWithData:[self.optionsText dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:&jsonError];
        if(![options isKindOfClass:NSDictionary.class] && ![options isKindOfClass:NSString.class]){[self message:jsonError.localizedDescription?:@"插件参数须为 JSON 对象或字符串"];return;}
        NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy];manifest[@"options"]=options;service[@"manifest"]=manifest;
    }
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:self.service];
    if([PyHost isManagedServiceIdentifier:self.identifier]){
        NSInteger oldPort=[self.service[@"port"] integerValue];
        if(oldPort==port){[self message:@"此服务仍在运行。停止服务后才能保存其他配置。"];return;}
        if(!self.onApplyService){[self message:@"端口尚未保存。请先停止服务，再保存新端口并重新启动。"] ;return;}
        if(![self customCodeMatchesSavedVersion]){[self message:@"当前脚本也有未保存修改。运行中的服务不能同时改代码和端口；请先停止服务后再保存。"];return;}
        UIAlertController *confirmation=[UIAlertController alertControllerWithTitle:@"应用新端口？"
                                                                              message:[NSString stringWithFormat:@"将停止 %@，把 HTTP 监听端口从 %ld 改为 %ld，再重新启动。重启失败时新端口仍会保存，并显示失败原因。",self.service[@"name"]?:@"此服务",(long)oldPort,(long)port]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf=self;
        [confirmation addAction:[UIAlertAction actionWithTitle:@"停止并重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf applyPortChange:service];}]];
        [self presentViewController:confirmation animated:YES completion:nil];
        return;
    }
    [self persistService:service];
}
- (BOOL)customCodeMatchesSavedVersion {
    if([self managedCode]||[self.service[@"builtin"] boolValue])return YES;
    NSString *saved=[NSString stringWithContentsOfFile:[ServiceStore codePath:self.service]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    return [saved isEqualToString:self.code?:@""];
}
- (BOOL)writeCodeForService:(NSDictionary *)service {
    if (![service[@"builtin"] boolValue] && ![service[@"manifest"] isKindOfClass:NSDictionary.class]) {
        NSError *error = nil;
        if (![self.code writeToFile:[ServiceStore codePath:service]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&error]) {
            [self message:error.localizedDescription];
            return NO;
        }
    }
    return YES;
}
- (void)applyPortChange:(NSDictionary *)service {
    if(self.applyingPortChange)return;
    if(![self writeCodeForService:service])return;
    self.applyingPortChange=YES;
    self.navigationItem.rightBarButtonItem.enabled=NO;
    __weak typeof(self) weakSelf=self;
    self.onApplyService(self.service,service,^(NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            ServiceEditorViewController *owner=weakSelf;if(!owner)return;
            owner.applyingPortChange=NO;
            owner.navigationItem.rightBarButtonItem.enabled=YES;
            if(error){
                BOOL saved=[error.userInfo[@"CCTVHostServiceConfigurationSaved"] boolValue];
                UIAlertController *alert=[UIAlertController alertControllerWithTitle:saved?@"端口已保存，服务未启动":@"端口更新失败"
                                                                                message:error.localizedDescription?:@"请查看此服务的独立日志。"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:saved?@"返回服务详情":@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(saved)[owner.navigationController popViewControllerAnimated:YES];}]];
                [owner presentViewController:alert animated:YES completion:nil];
                return;
            }
            [owner finishSavingService:service];
        });
    });
}
- (void)persistService:(NSDictionary *)service {
    if(![self writeCodeForService:service])return;
    [ServiceStore save:service];
    [self finishSavingService:service];
}
- (void)finishSavingService:(NSDictionary *)service {
    [NSFileManager.defaultManager removeItemAtPath:[self draftPath] error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[self optionsDraftPath] error:NULL];
    if (self.onSave)
        self.onSave();
    [self.navigationController popViewControllerAnimated:YES];
}
@end
