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
    self.view.backgroundColor = UIColor.blackColor;
    _editor = [UITextView new];
    _editor.translatesAutoresizingMaskIntoConstraints = NO;
    _editor.backgroundColor = HostCard();
    _editor.textColor = UIColor.whiteColor;
    _editor.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _editor.editable = !self.readOnly;
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.text =
        [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
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
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UITextField *urlField;
@property(nonatomic, strong) UITextField *argsField;
@property(nonatomic, strong) UISwitch *lanSwitch;
@property(nonatomic, strong) UISegmentedControl *sourceControl;
@property(nonatomic, strong) UILabel *fileLabel;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *code;
@property(nonatomic, strong) NSURLSessionDataTask *downloadTask;
@property(nonatomic, assign) BOOL downloading;
@end
@implementation ServiceEditorViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (UITextField *)field:(NSString *)placeholder value:(NSString *)value {
    UITextField *f = [UITextField new];
    f.placeholder = placeholder;
    f.text = value;
    f.textColor = UIColor.whiteColor;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.service ? @"编辑服务" : @"添加服务";
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.rowHeight = 54;
    self.identifier = self.service[@"id"] ?: NSUUID.UUID.UUIDString;
    self.nameField = [self field:@"服务名称" value:self.service[@"name"]];
    self.portField = [self field:@"端口 1024–65535" value:[self.service[@"port"] description] ?: @"18768"];
    self.portField.keyboardType = UIKeyboardTypeNumberPad;
    self.urlField = [self field:@"https://…/service.py" value:self.service[@"url"]];
    self.urlField.keyboardType = UIKeyboardTypeURL;
    [self.urlField addTarget:self action:@selector(urlChanged) forControlEvents:UIControlEventEditingChanged];
    self.argsField = [self field:@"参数以 | 分隔，可用 {port} / {bind}" value:self.service[@"arguments"]];
    self.lanSwitch = [UISwitch new];
    self.lanSwitch.onTintColor = HostAccent();
    self.lanSwitch.on = [self.service[@"lan"] boolValue];
    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[ @"文件", @"远程链接", @"手动代码" ]];
    self.sourceControl.selectedSegmentIndex = 1;
    [self.sourceControl addTarget:self
                           action:@selector(sourceChanged)
                 forControlEvents:UIControlEventValueChanged];
    if (self.service)
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
    if (![self.service[@"builtin"] boolValue])
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
           : section == 1 ? ([self.service[@"builtin"] boolValue] ? 1 : 3)
           : section == 2 ? ([self.service[@"builtin"] boolValue] ? 1 : 2)
                          : 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ ([self.service[@"engine"] isEqual:@"javascript"]?@"JavaScript 服务":@"Python 服务"), @"代码来源", @"网络与启动", @"" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return @"导入后可查看、编辑或导出代码。内置服务代码只读。";
    if (section == 2)
        return @"自定义脚本的参数用 | 分隔，支持 {port}、{bind}、{dataDir}。本机一次运行一个 Python "
               @"服务；切换前须等待旧服务释放线程和端口。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.backgroundColor = HostCard();
    c.textLabel.textColor = UIColor.whiteColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *input = nil;
    if (ip.section == 0) {
        c.textLabel.text = ip.row == 0 ? @"服务名称" : @"本机端口";
        input = ip.row == 0 ? self.nameField : self.portField;
    } else if (ip.section == 1) {
        if ([self.service[@"builtin"] boolValue]) {
            c.textLabel.text = @"查看内置代码";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 0)
            input = self.sourceControl;
        else if (ip.row == 1) {
            if (self.sourceControl.selectedSegmentIndex == 1)
                input = self.urlField;
            else {
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
            if ([self.service[@"builtin"] boolValue]) {
                c.textLabel.text = @"允许局域网访问";
                c.accessoryView = self.lanSwitch;
            } else {
                c.textLabel.text = @"网络绑定";
                c.detailTextLabel.text = @"由脚本启动参数决定";
            }
        } else
            input = self.argsField;
    } else {
        c.textLabel.text = @"保存服务";
        c.textLabel.textColor = HostAccent();
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    if (input) {
        input.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:input];
        [NSLayoutConstraint activateConstraints:@[
            [input.leadingAnchor constraintEqualToAnchor:c.contentView.leadingAnchor
                                                constant:(ip.section == 0 ? 115 : 16)],
            [input.trailingAnchor constraintEqualToAnchor:c.contentView.trailingAnchor constant:-16],
            [input.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
            [input.heightAnchor constraintEqualToConstant:40]
        ]];
    }
    return c;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 3) {
        [self save];
        return;
    }
    if (ip.section != 1)
        return;
    if ([self.service[@"builtin"] boolValue]) {
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
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Python 服务"
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
- (void)editManual {
    NSString *path = [self draftPath];
    [self.code ?: @"# Python service\n" writeToFile:path
                                         atomically:YES
                                           encoding:NSUTF8StringEncoding
                                              error:NULL];
    ServiceCodeViewController *v = [ServiceCodeViewController new];
    v.path = path;
    v.readOnly = [self.service[@"builtin"] boolValue];
    [self.navigationController pushViewController:v animated:YES];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSString *text = [NSString stringWithContentsOfFile:[self draftPath]
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text)
        self.code = text;
    [self.tableView reloadData];
}
- (void)save {
    if (PyHost.running && [[ServiceStore activeIdentifier] isEqualToString:self.identifier]) {
        [self message:@"请先停止此服务，再修改端口或代码。"];
        return;
    }
    NSInteger port = self.portField.text.integerValue;
    NSString *name =
        [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || port < 1024 || port > 65535) {
        [self message:@"请填写名称，以及 1024–65535 范围内的端口。"];
        return;
    }
    if (![self.service[@"builtin"] boolValue] && !self.code.length) {
        [self message:@"请先加载或输入 Python 代码。"];
        return;
    }
    NSMutableDictionary *service = [self.service ?: @{} mutableCopy];
    service[@"id"] = self.identifier;
    service[@"name"] = name;
    service[@"port"] = @(port);
    service[@"lan"] = @(self.lanSwitch.on);
    service[@"arguments"] = self.argsField.text ?: @"";
    service[@"url"] = self.urlField.text ?: @"";
    service[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    if (![service[@"builtin"] boolValue]) {
        NSError *error = nil;
        if (![self.code writeToFile:[ServiceStore codePath:service]
                         atomically:YES
                           encoding:NSUTF8StringEncoding
                              error:&error]) {
            [self message:error.localizedDescription];
            return;
        }
    }
    [ServiceStore save:service];
    [NSFileManager.defaultManager removeItemAtPath:[self draftPath] error:NULL];
    if (self.onSave)
        self.onSave();
    [self.navigationController popViewControllerAnimated:YES];
}
@end
