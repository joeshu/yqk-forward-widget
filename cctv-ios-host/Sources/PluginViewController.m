#import "PluginViewController.h"
#import "HostTheme.h"
#import "HostLocalPort.h"
#import "PyHost.h"
#import "ServiceStore.h"

@interface PluginViewController ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *urlLabel;
@property(nonatomic,strong) UILabel *countLabel;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UIButton *restartButton;
@property(nonatomic,strong) UIView *statusDot;
@property(nonatomic,assign) NSUInteger subscriptionCount;
@property(nonatomic,assign) BOOL running;
@property(nonatomic,assign) BOOL restarting;
@property(nonatomic,strong) NSURLSessionDataTask *httpProbeTask;
@property(nonatomic,assign) NSUInteger httpProbeGeneration;
@property(nonatomic,strong,nullable) NSNumber *httpReachable;
@property(nonatomic, copy, nullable) NSNumber *stopPortState; // 0 端口已释放，1 仍可访问，-1 未知
@property(nonatomic, assign) NSUInteger stopVerifyGeneration;
@property(nonatomic, assign) NSUInteger restartGeneration;
@property(nonatomic, assign) NSUInteger startStopGeneration;
@property(nonatomic, assign) BOOL startStopPending;
@end

@implementation PluginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"服务";
    self.view.backgroundColor = HostBackground();

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];

    UIStackView *content = [UIStackView new];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 16;
    content.layoutMargins = UIEdgeInsetsMake(18, 18, 28, 18);
    content.layoutMarginsRelativeArrangement = YES;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];

    UILabel *heading = [self label:@"YSP Live" size:30 weight:UIFontWeightBold color:HostText()];
    [content addArrangedSubview:heading];
    UILabel *intro = [self label:@"运行本机频道插件并管理 M3U 订阅。" size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    [content addArrangedSubview:intro];

    UIView *statusCard = [self card];
    UIStackView *statusRow = [self rowStack];
    // 状态行是圆点 + 文案：FillEqually 会把 12pt 圆点拉成半行宽，改用 Fill 并居中对齐。
    statusRow.distribution = UIStackViewDistributionFill;
    statusRow.alignment = UIStackViewAlignmentCenter;
    self.statusDot = [UIView new];
    self.statusDot.backgroundColor = UIColor.systemGrayColor;
    self.statusDot.layer.cornerRadius = 6;
    [NSLayoutConstraint activateConstraints:@[[self.statusDot.widthAnchor constraintEqualToConstant:12], [self.statusDot.heightAnchor constraintEqualToConstant:12]]];
    self.statusLabel = [self label:@"未运行" size:17 weight:UIFontWeightSemibold color:HostText()];
    [statusRow addArrangedSubview:self.statusDot];
    [statusRow addArrangedSubview:self.statusLabel];
    [statusCard addSubview:statusRow];
    [NSLayoutConstraint activateConstraints:@[[statusRow.leadingAnchor constraintEqualToAnchor:statusCard.leadingAnchor constant:16],[statusRow.trailingAnchor constraintLessThanOrEqualToAnchor:statusCard.trailingAnchor constant:-16],[statusRow.topAnchor constraintEqualToAnchor:statusCard.topAnchor constant:18],[statusRow.bottomAnchor constraintEqualToAnchor:statusCard.bottomAnchor constant:-18]]];
    [content addArrangedSubview:statusCard];

    UIView *feedCard = [self card];
    UIStackView *feedStack = [self verticalStack];
    [feedCard addSubview:feedStack];
    [NSLayoutConstraint activateConstraints:@[[feedStack.leadingAnchor constraintEqualToAnchor:feedCard.leadingAnchor constant:16],[feedStack.trailingAnchor constraintEqualToAnchor:feedCard.trailingAnchor constant:-16],[feedStack.topAnchor constraintEqualToAnchor:feedCard.topAnchor constant:14],[feedStack.bottomAnchor constraintEqualToAnchor:feedCard.bottomAnchor constant:-14]]];
    [feedStack addArrangedSubview:[self label:@"播放列表地址" size:13 weight:UIFontWeightMedium color:UIColor.secondaryLabelColor]];
    self.urlLabel = [self label:@"http://127.0.0.1:8767/all.m3u" size:14 weight:UIFontWeightMedium color:HostText()];
    self.urlLabel.numberOfLines = 0;
    self.urlLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [feedStack addArrangedSubview:self.urlLabel];
    UIButton *copy = [self button:@"复制地址" action:@selector(copyURL)];
    [feedStack addArrangedSubview:copy];
    [content addArrangedSubview:feedCard];

    UIView *serviceCard = [self card];
    UIStackView *serviceStack = [self verticalStack];
    [serviceCard addSubview:serviceStack];
    [NSLayoutConstraint activateConstraints:@[[serviceStack.leadingAnchor constraintEqualToAnchor:serviceCard.leadingAnchor constant:16],[serviceStack.trailingAnchor constraintEqualToAnchor:serviceCard.trailingAnchor constant:-16],[serviceStack.topAnchor constraintEqualToAnchor:serviceCard.topAnchor constant:14],[serviceStack.bottomAnchor constraintEqualToAnchor:serviceCard.bottomAnchor constant:-14]]];
    [serviceStack addArrangedSubview:[self label:@"插件服务" size:17 weight:UIFontWeightSemibold color:HostText()]];
    UILabel *note = [self label:@"插件仅绑定本机回环地址。iOS 安全模式限制缓存 32 MB、高码率并发 2 路；后台服务可能被系统挂起。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    note.numberOfLines = 0;
    [serviceStack addArrangedSubview:note];
    UIStackView *actions = [self rowStack];
    self.startButton = [self button:@"启动服务" action:@selector(start)];
    self.stopButton = [self button:@"停止服务" action:@selector(stop)];
    self.restartButton = [self button:@"重启服务" action:@selector(restart)];
    [actions addArrangedSubview:self.startButton];
    [actions addArrangedSubview:self.stopButton];
    [actions addArrangedSubview:self.restartButton];
    [serviceStack addArrangedSubview:actions];
    [content addArrangedSubview:serviceCard];

    UIView *subscriptionCard = [self card];
    UIStackView *subscriptionStack = [self verticalStack];
    [subscriptionCard addSubview:subscriptionStack];
    [NSLayoutConstraint activateConstraints:@[[subscriptionStack.leadingAnchor constraintEqualToAnchor:subscriptionCard.leadingAnchor constant:16],[subscriptionStack.trailingAnchor constraintEqualToAnchor:subscriptionCard.trailingAnchor constant:-16],[subscriptionStack.topAnchor constraintEqualToAnchor:subscriptionCard.topAnchor constant:14],[subscriptionStack.bottomAnchor constraintEqualToAnchor:subscriptionCard.bottomAnchor constant:-14]]];
    self.countLabel = [self label:@"订阅源 · 0" size:17 weight:UIFontWeightSemibold color:HostText()];
    [subscriptionStack addArrangedSubview:self.countLabel];
    [subscriptionStack addArrangedSubview:[self button:@"添加 M3U 订阅" action:@selector(add)]];
    [subscriptionStack addArrangedSubview:[self button:@"管理订阅源" action:@selector(manage)]];
    [content addArrangedSubview:subscriptionCard];

    UIButton *logs = [self button:@"查看运行日志" action:@selector(openLog)];
    [content addArrangedSubview:logs];
    [self updateRunning:NO subscriptionCount:0];
}

- (UIView *)card {
    UIView *v = [UIView new];
    HostStyleGlassCard(v,18);
    return v;
}
- (UIStackView *)verticalStack {
    UIStackView *s = [UIStackView new]; s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = NO; return s;
}
- (UIStackView *)rowStack {
    UIStackView *s = [UIStackView new]; s.axis = UILayoutConstraintAxisHorizontal; s.spacing = 12; s.distribution = UIStackViewDistributionFillEqually; s.translatesAutoresizingMaskIntoConstraints = NO; return s;
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new]; l.text = text; l.textColor = color;
    // 本页此前全部用固定字号，大字体下不缩放：按字号映射到对应文本样式后缩放。
    UIFontTextStyle style = size >= 28 ? UIFontTextStyleLargeTitle : (size >= 17 ? UIFontTextStyleHeadline : (size >= 14 ? UIFontTextStyleSubheadline : UIFontTextStyleFootnote));
    l.font = [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    l.adjustsFontForContentSizeCategory = YES; l.numberOfLines = 0; return l;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    HostInstallPressFeedback(b);
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]];
    b.titleLabel.adjustsFontForContentSizeCategory = YES;
    b.titleLabel.adjustsFontSizeToFitWidth=YES;b.titleLabel.minimumScaleFactor=0.6;
    [b setTitleColor:HostText() forState:UIControlStateNormal];
    b.backgroundColor = HostRaisedSurface();
    b.layer.cornerRadius = 12;
    b.contentEdgeInsets = UIEdgeInsetsMake(13, 12, 13, 12);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
    [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshStatus) name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil]; [self.httpProbeTask cancel]; self.httpProbeTask=nil; self.httpProbeGeneration++; self.stopVerifyGeneration++; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self.httpProbeTask cancel]; }
- (NSInteger)pluginServicePort {
    // 端口只认 builtin-ysp 这一项，且落在 1…65535 内；配置缺失或非法时
    // 回落 8767，避免拼出 http://127.0.0.1:0/all.m3u 这种无效地址。
    for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:@"builtin-ysp"]){NSInteger port=[service[@"port"] integerValue];return (port>=1&&port<=65535)?port:8767;}
    return 8767;
}
- (void)refreshStatus {
    self.startStopPending=NO;
    // 订阅数不在本页维护：每次出现时向调用方现取，否则在资源页增删订阅
    // 后返回本页仍显示旧数。未提供 provider 时沿用上次传入的值。
    NSUInteger count=self.subscriptionCountProvider?self.subscriptionCountProvider():self.subscriptionCount;
    BOOL wasRunning=self.running;
    [self updateRunning:[PyHost isRunningServiceIdentifier:@"builtin-ysp"] subscriptionCount:count];
    if(self.running)[self probeHTTPIfNeeded];
    if(!wasRunning&&self.running)self.stopPortState=nil;
    // 运行 → 已停止：停止只代表会话结束，不代表监听端口已释放，
    // 后台确认一次端口状态再写进状态文案；结果只改文案。
    if(wasRunning&&!self.running)[self verifyPortReleasedAfterStop];
}
- (void)verifyPortReleasedAfterStop {
    NSInteger port=[self pluginServicePort];
    if(port<1||port>65535)return;
    NSUInteger generation=++self.stopVerifyGeneration;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int state=HostLocalPortState((int)port);
        dispatch_async(dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(!owner||generation!=owner.stopVerifyGeneration||owner.running)return;owner.stopPortState=@(state);[owner updateStatusLabelWithPort:port];});
    });
}
- (NSString *)stoppedStatusText {
    if(!self.stopPortState)return @"未运行";
    if([self.stopPortState integerValue]==0)return @"未运行 · 本机端口已释放";
    if([self.stopPortState integerValue]==1)return @"未运行 · 端口仍可访问，请检查是否有其他程序占用";
    return @"未运行 · 端口状态未知";
}
- (void)updateStatusLabelWithPort:(NSInteger)port {
    if(!self.running){self.statusLabel.text=[self stoppedStatusText];return;}
    NSString *http=self.httpReachable==nil?@"HTTP 检测中…":([self.httpReachable boolValue]?@"HTTP 可达":@"HTTP 未响应");
    self.statusLabel.text=[NSString stringWithFormat:@"YSP Live 运行时活跃 · 端口 %ld · %@",(long)port,http];
}
- (void)probeHTTPIfNeeded {
    // 进程活跃不等于接口可达：每次出现时对 /health 做一次 3 秒探测，
    // 把状态文案换成实测结果；代次守卫丢弃过期回调。
    if(!self.running)return;
    [self.httpProbeTask cancel];self.httpProbeTask=nil;
    NSUInteger generation=++self.httpProbeGeneration;
    self.httpReachable=nil;
    NSInteger port=[self pluginServicePort];
    [self updateStatusLabelWithPort:port];
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/health",(long)port]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:3];
    __weak typeof(self) weakSelf=self;
    self.httpProbeTask=[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(!owner||owner.httpProbeGeneration!=generation||!owner.running)return;NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;owner.httpReachable=@(!error&&status>=200&&status<300);owner.httpProbeTask=nil;[owner updateStatusLabelWithPort:port];});
    }];
    [self.httpProbeTask resume];
}
- (void)updateRunning:(BOOL)running subscriptionCount:(NSUInteger)count {
    NSInteger port=[self pluginServicePort];
    self.subscriptionCount = count;
    self.running = running;
    self.statusDot.backgroundColor = running ? UIColor.systemGreenColor : UIColor.systemGrayColor;
    [self updateStatusLabelWithPort:port];
    self.urlLabel.text=[self subscriptionURL];
    self.countLabel.text = [NSString stringWithFormat:@"订阅源 · %lu", (unsigned long)count];
    self.startButton.enabled = !running && !self.restarting;
    self.stopButton.enabled = running && !self.restarting;
    self.restartButton.enabled = running && !self.restarting;
    self.startButton.alpha = (running||self.restarting) ? 0.45 : 1.0;
    self.stopButton.alpha = (running&&!self.restarting) ? 1.0 : 0.45;
    self.restartButton.alpha = (running&&!self.restarting) ? 1.0 : 0.45;
}
- (void)start { if(self.startStopPending)return;self.startStopPending=YES;self.startButton.enabled=NO;self.stopButton.enabled=NO;if(self.onStart)self.onStart();[self armStartStopWatchdog]; }
- (void)stop { if(self.startStopPending)return;self.startStopPending=YES;self.startButton.enabled=NO;self.stopButton.enabled=NO;if(self.onStop)self.onStop();[self armStartStopWatchdog]; }
- (void)armStartStopWatchdog {
    // 启停是异步的：状态通知回来前按钮仍可用，连点会重复下发启停。
    // 先锁住按钮，状态通知（refreshStatus）或 10 秒看门狗会恢复。
    NSUInteger generation=++self.startStopGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(!owner||generation!=owner.startStopGeneration||!owner.startStopPending)return;owner.startStopPending=NO;[owner refreshStatus];});
}
- (void)restart {
    // 重启只对运行中的服务有意义：复用与服务详情同一条 restartMediaService
    //（先停、确认端口释放后再启动），失败弹框给明确原因。
    if(!self.running||self.restarting||!self.onRestart)return;
    self.restarting=YES;[self updateRunning:self.running subscriptionCount:self.subscriptionCount];
    __weak typeof(self) weakSelf=self;
    NSUInteger restartGeneration=++self.restartGeneration;
    self.onRestart(^(NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(!owner)return;owner.restarting=NO;[owner refreshStatus];if(error)[owner showRestartError:error];});
    });
    // onRestart 回调若永不触发，重启按钮会永久锁死：30 秒看门狗兜底复位（与服务详情页一致）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(!owner||restartGeneration!=owner.restartGeneration||!owner.restarting)return;owner.restarting=NO;[owner refreshStatus];[owner showRestartError:[NSError errorWithDomain:@"CCTVHost" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"重启超时，服务未重新启动，请查看运行日志。"}]];});
}
- (void)showRestartError:(NSError *)error {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"重启失败" message:error.localizedDescription?:@"服务未重新启动，请查看运行日志。" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"查看运行日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(weakSelf.onOpenLog)weakSelf.onOpenLog();}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)add { if (self.onAddSubscription) self.onAddSubscription(); }
- (void)manage { if (self.onManageSubscriptions) self.onManageSubscriptions(); }
- (void)openLog { if (self.onOpenLog) self.onOpenLog(); }
- (NSString *)subscriptionURL {
    // 之前取“第一个 builtin 服务”的端口，可能取到别的服务或 0 端口；与状态文案用同一来源。
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld/all.m3u",(long)[self pluginServicePort]];
}
- (void)copyURL { UIPasteboard.generalPasteboard.string=[self subscriptionURL];self.urlLabel.text=[@"已复制 · " stringByAppendingString:[self subscriptionURL]];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"播放列表地址已复制");__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{PluginViewController *owner=weakSelf;if(owner&&[owner.urlLabel.text hasPrefix:@"已复制 · "])owner.urlLabel.text=[owner subscriptionURL];}); }
@end
