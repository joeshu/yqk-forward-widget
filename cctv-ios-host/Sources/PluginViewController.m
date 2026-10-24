#import "PluginViewController.h"
#import "PyHost.h"
#import "ServiceStore.h"

@interface PluginViewController ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *urlLabel;
@property(nonatomic,strong) UILabel *countLabel;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UIView *statusDot;
@property(nonatomic,strong) NSTimer *statusTimer;
@property(nonatomic,assign) NSUInteger subscriptionCount;
@end

@implementation PluginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"服务";
    self.view.backgroundColor = UIColor.blackColor;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
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

    UILabel *heading = [self label:@"服务" size:30 weight:UIFontWeightBold color:UIColor.whiteColor];
    [content addArrangedSubview:heading];
    UILabel *intro = [self label:@"运行本机频道插件并管理 M3U 订阅。" size:14 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    [content addArrangedSubview:intro];

    UIView *statusCard = [self card];
    UIStackView *statusRow = [self rowStack];
    self.statusDot = [UIView new];
    self.statusDot.backgroundColor = UIColor.systemGrayColor;
    self.statusDot.layer.cornerRadius = 6;
    [NSLayoutConstraint activateConstraints:@[[self.statusDot.widthAnchor constraintEqualToConstant:12], [self.statusDot.heightAnchor constraintEqualToConstant:12]]];
    self.statusLabel = [self label:@"未运行" size:17 weight:UIFontWeightSemibold color:UIColor.whiteColor];
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
    self.urlLabel = [self label:@"http://127.0.0.1:8767/all.m3u" size:14 weight:UIFontWeightMedium color:UIColor.whiteColor];
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
    [serviceStack addArrangedSubview:[self label:@"插件服务" size:17 weight:UIFontWeightSemibold color:UIColor.whiteColor]];
    UILabel *note = [self label:@"插件仅绑定本机回环地址。iOS 安全模式限制缓存 32 MB、高码率并发 2 路；后台服务可能被系统挂起。" size:13 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];
    note.numberOfLines = 0;
    [serviceStack addArrangedSubview:note];
    UIStackView *actions = [self rowStack];
    self.startButton = [self button:@"启动服务" action:@selector(start)];
    self.stopButton = [self button:@"停止服务" action:@selector(stop)];
    [actions addArrangedSubview:self.startButton];
    [actions addArrangedSubview:self.stopButton];
    [serviceStack addArrangedSubview:actions];
    [content addArrangedSubview:serviceCard];

    UIView *subscriptionCard = [self card];
    UIStackView *subscriptionStack = [self verticalStack];
    [subscriptionCard addSubview:subscriptionStack];
    [NSLayoutConstraint activateConstraints:@[[subscriptionStack.leadingAnchor constraintEqualToAnchor:subscriptionCard.leadingAnchor constant:16],[subscriptionStack.trailingAnchor constraintEqualToAnchor:subscriptionCard.trailingAnchor constant:-16],[subscriptionStack.topAnchor constraintEqualToAnchor:subscriptionCard.topAnchor constant:14],[subscriptionStack.bottomAnchor constraintEqualToAnchor:subscriptionCard.bottomAnchor constant:-14]]];
    self.countLabel = [self label:@"订阅源 · 0" size:17 weight:UIFontWeightSemibold color:UIColor.whiteColor];
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
    v.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    v.layer.cornerRadius = 18;
    v.clipsToBounds = YES;
    return v;
}
- (UIStackView *)verticalStack {
    UIStackView *s = [UIStackView new]; s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.translatesAutoresizingMaskIntoConstraints = NO; return s;
}
- (UIStackView *)rowStack {
    UIStackView *s = [UIStackView new]; s.axis = UILayoutConstraintAxisHorizontal; s.spacing = 12; s.distribution = UIStackViewDistributionFillEqually; s.translatesAutoresizingMaskIntoConstraints = NO; return s;
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [UILabel new]; l.text = text; l.textColor = color; l.font = [UIFont systemFontOfSize:size weight:weight]; l.numberOfLines = 0; return l;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
    b.layer.cornerRadius = 12;
    b.contentEdgeInsets = UIEdgeInsetsMake(13, 12, 13, 12);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
    [self.statusTimer invalidate];
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.statusTimer invalidate]; self.statusTimer = nil; }
- (void)dealloc { [self.statusTimer invalidate]; }
- (void)refreshStatus { [self updateRunning:PyHost.running subscriptionCount:self.subscriptionCount]; }
- (void)updateRunning:(BOOL)running subscriptionCount:(NSUInteger)count {
    self.subscriptionCount = count;
    self.statusDot.backgroundColor = running ? UIColor.systemGreenColor : UIColor.systemGrayColor;
    self.statusLabel.text = running ? [NSString stringWithFormat:@"运行中 · 端口 %ld",(long)PyHost.port] : @"未运行";
    self.urlLabel.text=[self subscriptionURL];
    self.countLabel.text = [NSString stringWithFormat:@"订阅源 · %lu", (unsigned long)count];
    self.startButton.enabled = !running;
    self.stopButton.enabled = running;
    self.startButton.alpha = running ? 0.45 : 1.0;
    self.stopButton.alpha = running ? 1.0 : 0.45;
}
- (void)start { if (self.onStart) self.onStart(); }
- (void)stop { if (self.onStop) self.onStop(); }
- (void)add { if (self.onAddSubscription) self.onAddSubscription(); }
- (void)manage { if (self.onManageSubscriptions) self.onManageSubscriptions(); }
- (void)openLog { if (self.onOpenLog) self.onOpenLog(); }
- (NSString *)subscriptionURL {
    NSInteger port=8767;
    for(NSDictionary *s in [ServiceStore services])if([s[@"builtin"] boolValue]){port=[s[@"port"] integerValue];break;}
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld/all.m3u",(long)port];
}
- (void)copyURL { UIPasteboard.generalPasteboard.string=[self subscriptionURL];self.urlLabel.text=[@"已复制 · " stringByAppendingString:[self subscriptionURL]]; }
@end
