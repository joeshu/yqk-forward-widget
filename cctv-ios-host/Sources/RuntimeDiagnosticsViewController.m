#import "RuntimeDiagnosticsViewController.h"
#import "RuntimeDiagnostics.h"
#import "HostTheme.h"

@interface RuntimeDiagnosticsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy, nullable) NSString *sessionID;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, copy) NSArray<NSDictionary *> *sessions;
@property(nonatomic, copy) NSArray<NSDictionary *> *events;
@property(nonatomic, copy) NSArray<NSDictionary *> *allEvents;
@property(nonatomic, strong) UISegmentedControl *eventCategoryFilter;
@property(nonatomic, strong) UIBarButtonItem *clearButton;
@property(nonatomic, strong) UIBarButtonItem *exportButton;
@property(nonatomic, strong) UIBarButtonItem *deleteButton;
// 异步加载的代次：viewWillAppear 与删除/清空后的 reload 可能重叠，
// 先发出的旧加载后完成时会把已删会话写回列表；代次不符直接丢弃。
@property(nonatomic) NSUInteger reloadGeneration;
@end

@implementation RuntimeDiagnosticsViewController

- (instancetype)initWithSessionID:(NSString *)sessionID {
    if ((self = [super init])) { _sessionID = [sessionID copy]; _sessions = @[]; _events = @[]; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.navigationController.navigationBar.tintColor = HostAccent();
    self.title = self.sessionID.length ? @"运行记录" : @"运行诊断记录";
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
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
        self.eventCategoryFilter = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"播放", @"接口", @"服务", @"异常"]];
        self.eventCategoryFilter.selectedSegmentIndex = 0;
        self.eventCategoryFilter.selectedSegmentTintColor = HostAccent();
        [self.eventCategoryFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateNormal];
        [self.eventCategoryFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateSelected];
        self.eventCategoryFilter.accessibilityIdentifier = @"diagnostic.event.filter";
        [self.eventCategoryFilter addTarget:self action:@selector(applyEventCategoryFilter) forControlEvents:UIControlEventValueChanged];
        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 48)];
        self.eventCategoryFilter.frame = CGRectMake(16, 6, 288, 36);
        self.eventCategoryFilter.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:self.eventCategoryFilter];
        self.table.tableHeaderView = header;
    } else {
        self.clearButton = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearAll)];
        self.clearButton.tintColor = UIColor.systemRedColor;
        self.navigationItem.rightBarButtonItem = self.clearButton;
    }
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.navigationController.navigationBar.tintColor = HostAccent();
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    self.table.tintColor = HostAccent();
    if (self.eventCategoryFilter) {
        self.eventCategoryFilter.selectedSegmentTintColor = HostAccent();
        [self.eventCategoryFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateNormal];
        [self.eventCategoryFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateSelected];
    }
    [self.table reloadData];
}

- (void)showTransientPrompt:(NSString *)prompt {
    self.navigationItem.prompt = prompt;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([weakSelf.navigationItem.prompt isEqualToString:prompt]) {
            weakSelf.navigationItem.prompt = nil;
        }
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRecords];
}

- (void)reloadRecords {
    // 异步加载完成前先给一个加载态，避免空表被误读成“没有记录”。
    if(self.sessionID.length ? !self.events.count : !self.sessions.count)self.table.backgroundView=[self emptyViewWithText:@"正在加载…"];
    self.reloadGeneration++;NSUInteger generation=self.reloadGeneration;
    __weak typeof(self) weakSelf = self;
    if (self.sessionID.length) {
        [[RuntimeDiagnostics shared] loadEventsForSessionID:self.sessionID completion:^(NSArray<NSDictionary *> *events, NSError *error) {
            RuntimeDiagnosticsViewController *owner = weakSelf; if (!owner||owner.reloadGeneration!=generation) return;
            owner.allEvents = events ?: @[];
            [owner applyEventCategoryFilter];
            if (!owner.allEvents.count) owner.table.backgroundView = [owner emptyViewWithText:error.localizedDescription ?: @"这次运行没有诊断记录。"];
        }];
    } else {
        [[RuntimeDiagnostics shared] loadSessionsWithCompletion:^(NSArray<NSDictionary *> *sessions, NSError *error) {
            RuntimeDiagnosticsViewController *owner = weakSelf; if (!owner||owner.reloadGeneration!=generation) return;
            owner.sessions = sessions ?: @[];
            owner.clearButton.enabled = owner.sessions.count > 0;
            owner.table.backgroundView = owner.sessions.count ? nil : [owner emptyViewWithText:error.localizedDescription ?: @"暂无运行记录。开启运行诊断并复现问题后，每次 App 运行会单独出现在这里。"];
            [owner.table reloadData];
        }];
    }
}

- (void)applyEventCategoryFilter {
    NSArray<NSDictionary *> *source = self.allEvents ?: @[];
    NSInteger idx = self.eventCategoryFilter ? self.eventCategoryFilter.selectedSegmentIndex : 0;
    if (idx <= 0) {
        self.events = source;
    } else {
        self.events = [source filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
            if (![event isKindOfClass:NSDictionary.class]) return NO;
            NSString *cat = [event[@"category"] isKindOfClass:NSString.class] ? event[@"category"] : @"";
            NSString *name = [event[@"event"] isKindOfClass:NSString.class] ? event[@"event"] : @"";
            if (idx == 1) return [cat isEqualToString:@"playback"];
            if (idx == 2) return [cat isEqualToString:@"media_api"];
            if (idx == 3) return [cat isEqualToString:@"service"];
            return [name localizedCaseInsensitiveContainsString:@"fail"] || [name localizedCaseInsensitiveContainsString:@"error"] || [name localizedCaseInsensitiveContainsString:@"timeout"] || [name localizedCaseInsensitiveContainsString:@"reject"];
        }]];
    }
    self.table.backgroundView = self.events.count ? nil : [self emptyViewWithText:@"当前筛选分类下没有诊断事件。"];
    [self.table reloadData];
}

- (UIView *)emptyViewWithText:(NSString *)text {
    UILabel *label = [UILabel new]; label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text; label.textAlignment = NSTextAlignmentCenter; label.textColor = HostSecondaryText();
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; label.adjustsFontForContentSizeCategory = YES; label.numberOfLines = 0;
    UIView *view = [UIView new]; [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor], [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:32], [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-32]]];
    return view;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.sessionID.length ? self.events.count : self.sessions.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return self.sessionID.length ? [NSString stringWithFormat:@"事件 · %lu 条 · 点按可复制", (unsigned long)self.events.count] : [NSString stringWithFormat:@"按次记录 · %lu 次", (unsigned long)self.sessions.count]; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"diagnostic.row"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"diagnostic.row"];
    cell.backgroundColor = HostCard(); cell.layer.cornerRadius = 14; cell.layer.cornerCurve = kCACornerCurveContinuous; cell.clipsToBounds = YES; cell.layer.borderWidth = 0.6; HostSetLayerBorderColor(cell, HostBorder()); cell.textLabel.textColor = HostText(); cell.detailTextLabel.textColor = HostSecondaryText();
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *rows=self.sessionID.length?self.events:self.sessions;if(indexPath.row<0||indexPath.row>=rows.count)return cell;
    if (self.sessionID.length) {
        NSDictionary *event = rows[indexPath.row];if(![event isKindOfClass:NSDictionary.class])return cell;
        // 磁盘 JSON 里的 NSNull 若直接进 %@ 只会显示“<null>”，但进 boolValue /
        // unsignedIntegerValue 会因不识别 selector 而崩溃：取值前一律验类型。
        NSString *category = [event[@"category"] isKindOfClass:NSString.class] ? event[@"category"] : @"unknown";
        NSString *time = [event[@"time"] isKindOfClass:NSString.class] ? event[@"time"] : @"时间未知";
        NSString *eventName = [event[@"event"] isKindOfClass:NSString.class] ? event[@"event"] : @"未知事件";
        NSDictionary *fields = [event[@"fields"] isKindOfClass:NSDictionary.class] ? event[@"fields"] : nil;
        NSString *payload = @"";
        if (fields.count) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:NSJSONWritingPrettyPrinted error:NULL];
            if (data.length) payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        }
        // 长列表里单个事件的完整 JSON 会把行撑成巨型卡片：列表只给前 500 字预览，完整内容见导出。
        if(payload.length>500){NSRange prefix=[payload rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,500)];payload=[[payload substringWithRange:prefix] stringByAppendingString:@"…（完整内容见导出）"];}
        cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", eventName, category];
        cell.detailTextLabel.text = payload.length ? [NSString stringWithFormat:@"%@\n%@", time, payload] : time;
        cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote].pointSize weight:UIFontWeightRegular];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        NSDictionary *session = rows[indexPath.row];if(![session isKindOfClass:NSDictionary.class])return cell;
        NSString *date = [session[@"started_at"] isKindOfClass:NSString.class] ? session[@"started_at"] : @"开始时间未知";
        NSString *versionValue = [session[@"app_version"] isKindOfClass:NSString.class] ? session[@"app_version"] : @"";
        NSString *buildValue = [session[@"app_build"] isKindOfClass:NSString.class] && [session[@"app_build"] length] ? session[@"app_build"] : @"未知";
        NSString *version = versionValue.length ? [NSString stringWithFormat:@"版本 %@ · 构建 %@", versionValue, buildValue] : @"版本信息未知";
        BOOL isCurrent=[session[@"is_current"] isKindOfClass:NSNumber.class]?[session[@"is_current"] boolValue]:NO;BOOL isOpen=[session[@"is_open"] isKindOfClass:NSNumber.class]?[session[@"is_open"] boolValue]:NO;BOOL cleanlyEnded=[session[@"cleanly_ended"] isKindOfClass:NSNumber.class]?[session[@"cleanly_ended"] boolValue]:NO;
        NSString *state = isCurrent ? @"本次运行" : (isOpen ? @"运行中" : (cleanlyEnded ? @"已结束" : @"未正常收尾 ⚠"));
        if(!cleanlyEnded && !isOpen && !isCurrent) { cell.layer.borderWidth=1.0; HostSetLayerBorderColor(cell, [UIColor systemRedColor]); }
        unsigned long long bytes = [session[@"bytes"] isKindOfClass:NSNumber.class] ? [session[@"bytes"] unsignedLongLongValue] : 0;
        NSString *size = [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleMemory];
        cell.textLabel.text = [NSString stringWithFormat:@"%@  ·  %@", date, state];
        unsigned long eventCount=[session[@"event_count"] isKindOfClass:NSNumber.class]?[session[@"event_count"] unsignedIntegerValue]:0;NSString *lastEvent=[session[@"last_event"] isKindOfClass:NSString.class]?session[@"last_event"]:@"未知";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%lu 条事件 · %@ · 最后事件：%@", version, eventCount, size, lastEvent];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.sessionID.length) {
        // 事件行点按复制本条事件，便于对照日志中心逐条粘贴排查。
        if(indexPath.row<0||indexPath.row>=self.events.count)return;
        NSDictionary *event=self.events[indexPath.row];if(![event isKindOfClass:NSDictionary.class])return;
        NSString *eventName=[event[@"event"] isKindOfClass:NSString.class]?event[@"event"]:@"未知事件";NSString *category=[event[@"category"] isKindOfClass:NSString.class]?event[@"category"]:@"";NSString *time=[event[@"time"] isKindOfClass:NSString.class]?event[@"time"]:@"时间未知";
        NSDictionary *fields=[event[@"fields"] isKindOfClass:NSDictionary.class]?event[@"fields"]:nil;
        NSString *payload=@"";
        if(fields.count){NSData *data=[NSJSONSerialization dataWithJSONObject:fields options:NSJSONWritingPrettyPrinted error:NULL];if(data.length)payload=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:@"";}
        UIPasteboard.generalPasteboard.string=payload.length?[NSString stringWithFormat:@"%@ · %@\n%@\n%@",eventName,category,time,payload]:[NSString stringWithFormat:@"%@ · %@\n%@",eventName,category,time];
        [self showTransientPrompt:@"诊断事件已复制"];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"事件已复制");
        return;
    }
    if(indexPath.row<0||indexPath.row>=self.sessions.count)return;
    id rawID=self.sessions[indexPath.row][@"session_id"];if(![rawID isKindOfClass:NSString.class]||![rawID length])return;
    NSString *sessionID = rawID;
    RuntimeDiagnosticsViewController *detail = [[RuntimeDiagnosticsViewController alloc] initWithSessionID:sessionID];
    [self.navigationController pushViewController:detail animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.sessionID.length) return nil;
    if(indexPath.row<0||indexPath.row>=self.sessions.count)return nil;
    NSDictionary *session = self.sessions[indexPath.row];if(![session isKindOfClass:NSDictionary.class])return nil;
    id rawID=session[@"session_id"];if(![rawID isKindOfClass:NSString.class]||![rawID length])return nil;
    NSString *sessionID = rawID;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *action, UIView *sourceView, void (^done)(BOOL)) {
        __weak typeof(self) weakSelf=self;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这次运行记录？" message:@"删除后无法恢复，其他运行记录不受影响。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *item) { done(NO); }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *item) {
            [[RuntimeDiagnostics shared] deleteSessionID:sessionID completion:^(NSError *error) { done(error == nil); RuntimeDiagnosticsViewController *owner=weakSelf; if(owner)[owner reloadRecords]; }];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (void)confirmClearAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空全部运行诊断记录？" message:@"将删除所有按次诊断日志，包括崩溃前的运行检查点。此操作不能撤销；其他配置、订阅、插件和播放历史不会受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空全部" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[RuntimeDiagnostics shared] clearAllSessionsWithCompletion:^(NSError *error) {
            RuntimeDiagnosticsViewController *owner=weakSelf;if(!owner)return;
            if (error) [owner showMessage:error.localizedDescription];
            [owner reloadRecords];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteCurrentSession {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除这次运行记录？" message:@"删除后无法恢复。其他运行记录不受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[RuntimeDiagnostics shared] deleteSessionID:self.sessionID completion:^(NSError *error) {
            RuntimeDiagnosticsViewController *owner=weakSelf;if(!owner)return;
            if (error) [owner showMessage:error.localizedDescription];
            else [owner.navigationController popViewControllerAnimated:YES];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)exportSession {
    __weak typeof(self) weakSelf=self;
    [[RuntimeDiagnostics shared] prepareExportForSessionID:self.sessionID completion:^(NSURL *url, NSError *error) {
        RuntimeDiagnosticsViewController *owner=weakSelf;if(!owner)return;
        if (!url) { [owner showMessage:error.localizedDescription ?: @"导出诊断日志失败"]; return; }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        UIBarButtonItem *anchor = owner.exportButton;
        share.popoverPresentationController.barButtonItem = anchor;
        [owner presentViewController:share animated:YES completion:nil];
    }];
}

- (void)showMessage:(NSString *)message {
    // 页面已不在窗口层级时弹 alert 只会打一条层级警告、用户也看不到，直接跳过。
    if(!self.view.window)return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"运行诊断" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
