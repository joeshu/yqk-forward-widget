#import "PluginViewController.h"

@interface PluginViewController ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *urlLabel;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UILabel *subscriptionsLabel;
@end

@implementation PluginViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"插件与订阅"; self.view.backgroundColor=[UIColor colorWithWhite:0.06 alpha:1];
    UIStackView *stack=[[UIStackView alloc]init]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=16; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack]; [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],[stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],[stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24]]];
    UILabel *title=[self label:@"YSP Live 插件" size:24 bold:YES]; [stack addArrangedSubview:title];
    self.statusLabel=[self label:@"状态：未运行" size:16 bold:NO]; [stack addArrangedSubview:self.statusLabel];
    UILabel *desc=[self label:@"在本机启动频道服务；启动后可将 M3U 订阅导入播放器。停止服务后，需重启 App 才能再次启动 Python。" size:14 bold:NO]; desc.numberOfLines=0; [stack addArrangedSubview:desc];
    self.urlLabel=[self label:@"播放列表：http://127.0.0.1:8767/all.m3u" size:13 bold:NO]; self.urlLabel.numberOfLines=0; self.urlLabel.textColor=UIColor.systemGrayColor; [stack addArrangedSubview:self.urlLabel];
    UIStackView *buttons=[[UIStackView alloc]init]; buttons.axis=UILayoutConstraintAxisHorizontal; buttons.spacing=12; buttons.distribution=UIStackViewDistributionFillEqually;
    self.startButton=[self button:@"启动插件" action:@selector(start)]; self.stopButton=[self button:@"停止插件" action:@selector(stop)]; [buttons addArrangedSubview:self.startButton]; [buttons addArrangedSubview:self.stopButton]; [stack addArrangedSubview:buttons];
    self.subscriptionsLabel=[self label:@"订阅源：0" size:16 bold:YES]; [stack addArrangedSubview:self.subscriptionsLabel];
    [stack addArrangedSubview:[self button:@"添加 M3U 订阅" action:@selector(add)]];
    [stack addArrangedSubview:[self button:@"管理订阅源" action:@selector(manage)]];
    [stack addArrangedSubview:[self button:@"查看运行日志" action:@selector(openLog)]];
    [stack addArrangedSubview:[self button:@"复制播放列表地址" action:@selector(copyURL)]];
}
- (UILabel *)label:(NSString *)s size:(CGFloat)size bold:(BOOL)bold { UILabel *l=[UILabel new]; l.text=s; l.textColor=UIColor.whiteColor; l.font=bold?[UIFont boldSystemFontOfSize:size]:[UIFont systemFontOfSize:size]; return l; }
- (UIButton *)button:(NSString *)s action:(SEL)sel { UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:s forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightMedium]; b.backgroundColor=[UIColor colorWithWhite:0.16 alpha:1]; b.layer.cornerRadius=10; b.contentEdgeInsets=UIEdgeInsetsMake(13,12,13,12); [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside]; return b; }
- (void)updateRunning:(BOOL)running subscriptionCount:(NSUInteger)count { self.statusLabel.text=running?@"状态：运行中 · 端口 8767":@"状态：未运行"; self.statusLabel.textColor=running?UIColor.systemGreenColor:UIColor.systemGrayColor; self.subscriptionsLabel.text=[NSString stringWithFormat:@"订阅源：%lu",(unsigned long)count]; self.startButton.enabled=!running; self.stopButton.enabled=running; }
- (void)start { if(self.onStart) self.onStart(); }
- (void)stop { if(self.onStop) self.onStop(); }
- (void)add { if(self.onAddSubscription) self.onAddSubscription(); }
- (void)manage { if(self.onManageSubscriptions) self.onManageSubscriptions(); }
- (void)openLog { if(self.onOpenLog) self.onOpenLog(); }
- (void)copyURL { UIPasteboard.generalPasteboard.string=@"http://127.0.0.1:8767/all.m3u"; self.urlLabel.text=@"已复制播放列表地址"; }
@end
