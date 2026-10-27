#import "RuntimeDiagnosticsViewController.h"
#import "RuntimeDiagnostics.h"
#import "HostTheme.h"

@interface RuntimeDiagnosticsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy, nullable) NSString *sessionID;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *sessions;
@property(nonatomic, copy) NSArray<NSDictionary *> *events;
@property(nonatomic, strong) UIBarButtonItem *clearButton;
@property(nonatomic, strong) UIBarButtonItem *exportButton;
@property(nonatomic, strong) UIBarButtonItem *deleteButton;
@end

@implementation RuntimeDiagnosticsViewController

- (instancetype)initWithSessionID:(NSString *)sessionID {
    if ((self = [super init])) { _sessionID = [sessionID copy]; _sessions = @[]; _events = @[]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = HostBackground();
    self.navigationController.navigationBar.tintColor = HostAccent();
    self.title = self.sessionID.length ? @"运行记录" : @"运行诊断记录";
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = HostBackground();
    self.table.dataSource = self; self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension; self.table.estimatedRowHeight = 86;
    self.table.tintColor = HostAccent();
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[[self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];

    if (self.sessionID.length) {
        self.exportButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:UIBarButtonItemStylePlain target:self action:@selector(exportSession)];
        self.deleteButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"] style:UIBarButtonItemStylePlain target:self action:@selector(confirmDeleteCurrentSession)];
        self.deleteButton.tintColor = UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItems = @[self.deleteButton, self.exportButton];
    } else {
        self.clearButton = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearAll)];
        self.clearButton.tintColor = UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItem = self.clearButton;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRecords];
}

- (void)reloadRecords {
    __weak typeof(self) weakSelf = self;
    if (self.sessionID.length) {
        [[RuntimeDiagnostics shared] loadEventsForSessionID:self.sessionID completion:^(NSArray<NSDictionary *> *events, NSError *error) {
            RuntimeDiagnosticsViewController *owner = weakSelf; if (!owner) return;
            owner.events = events ?: @[];
            owner.table.backgroundView = owner.events.count ? nil : [owner emptyViewWithText:error.localizedDescription ?: @"这次运行没有诊断记录。"];
            [owner.table reloadData];
        }];
    } else {
        [[RuntimeDiagnostics shared] loadSessionsWithCompletion:^(NSArray<NSDictionary *> *sessions, NSError *error) {
            RuntimeDiagnosticsViewController *owner = weakSelf; if (!owner) return;
            owner.sessions = sessions ?: @[];
            owner.clearButton.enabled = owner.sessions.count > 0;
            owner.table.backgroundView = owner.sessions.count ? nil : [owner emptyViewWithText:error.localizedDescription ?: @"暂无运行记录。开启运行诊断并复现问题后，每次 App 运行会单独出现在这里。"];
            [owner.table reloadData];
        }];
    }
}

- (UIView *)emptyViewWithText:(NSString *)text {
    UILabel *label = [UILabel new]; label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text; label.textAlignment = NSTextAlignmentCenter; label.textColor = HostSecondaryText();
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.numberOfLines = 0;
    UIView *view = [UIView new]; [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor], [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:32], [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-32]]];
    return view;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.sessionID.length ? self.events.count : self.sessions.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.sessionID.length ? [NSString stringWithFormat:@"事件 · %lu 条", (unsigned long)self.events.count] : [NSString stringWithFormat:@"按次记录 · %lu 次", (unsigned long)self.sessions.count]; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"diagnostic.row"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"diagnostic.row"];
    cell.backgroundColor = HostCard(); cell.textLabel.textColor = HostText(); cell.detailTextLabel.textColor = HostSecondaryText();
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.sessionID.length) {
        NSDictionary *event = self.events[indexPath.row];
        NSString *category = event[@"category"] ?: @"unknown";
        NSString *time = event[@"time"] ?: @"时间未知";
        NSDictionary *fields = [event[@"fields"] isKindOfClass:NSDictionary.class] ? event[@"fields"] : nil;
        NSString *payload = @"";
        if (fields.count) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:NSJSONWritingPrettyPrinted error:NULL];
            if (data.length) payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        }
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", event[@"event"] ?: @"未知事件", category];
        cell.detailTextLabel.text = payload.length ? [NSString stringWithFormat:@"%@\n%@", time, payload] : time;
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].pointSize weight:UIFontWeightRegular];
    } else {
        NSDictionary *session = self.sessions[indexPath.row];
        NSString *date = session[@"started_at"] ?: @"开始时间未知";
        NSString *versionValue = [session[@"app_version"] isKindOfClass:NSString.class] ? session[@"app_version"] : @"";
        NSString *buildValue = [session[@"app_build"] isKindOfClass:NSString.class] && [session[@"app_build"] length] ? session[@"app_build"] : @"未知";
        NSString *version = versionValue.length ? [NSString stringWithFormat:@"版本 %@ · 构建 %@", versionValue, buildValue] : @"版本信息未知";
        NSString *state = [session[@"is_current"] boolValue] ? @"本次运行" : ([session[@"is_open"] boolValue] ? @"运行中" : ([session[@"cleanly_ended"] boolValue] ? @"已结束" : @"未正常收尾"));
        unsigned long long bytes = [session[@"bytes"] unsignedLongLongValue];
        NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleMemory];
        cell.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@", date, state];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%lu 条事件 · %@ · 最后事件：%@", version, (unsigned long)[session[@"event_count"] unsignedIntegerValue], size, session[@"last_event"] ?: @"未知"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.sessionID.length) return;
    NSString *sessionID = self.sessions[indexPath.row][@"session_id"];
    RuntimeDiagnosticsViewController *detail = [[RuntimeDiagnosticsViewController alloc] initWithSessionID:sessionID];
    [self.navigationController pushViewController:detail animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.sessionID.length) return nil;
    NSDictionary *session = self.sessions[indexPath.row]; NSString *sessionID = session[@"session_id"];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, UIView *sourceView, void (^done)(BOOL)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这次运行记录？" message:@"删除后无法恢复，其他运行记录不受影响。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *item) { done(NO); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *item) {
            [[RuntimeDiagnostics shared] deleteSessionID:sessionID completion:^(NSError *error) { done(error == nil); [self reloadRecords]; }];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (void)confirmClearAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空全部运行诊断记录？" message:@"将删除所有按次诊断日志，包括崩溃前的运行检查点。此操作不能撤销；其他配置、订阅、插件和播放历史不会受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空全部" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[RuntimeDiagnostics shared] clearAllSessionsWithCompletion:^(NSError *error) {
            if (error) [self showMessage:error.localizedDescription];
            [self reloadRecords];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteCurrentSession {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这次运行记录？" message:@"删除后无法恢复。其他运行记录不受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[RuntimeDiagnostics shared] deleteSessionID:self.sessionID completion:^(NSError *error) {
            if (error) [self showMessage:error.localizedDescription];
            else [self.navigationController popViewControllerAnimated:YES];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportSession {
    [[RuntimeDiagnostics shared] prepareExportForSessionID:self.sessionID completion:^(NSURL *url, NSError *error) {
        if (!url) { [self showMessage:error.localizedDescription ?: @"导出诊断日志失败"]; return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        UIBarButtonItem *anchor = self.exportButton;
        share.popoverPresentationController.barButtonItem = anchor;
        [self presentViewController:share animated:YES completion:nil];
    }];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"运行诊断" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
