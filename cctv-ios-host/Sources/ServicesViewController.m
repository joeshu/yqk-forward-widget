#import "ServicesViewController.h"
#import "PyHost.h"

@interface ServicesViewController ()
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIView *dot;
@property(nonatomic,strong) NSTimer *timer;
@end

@implementation ServicesViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"服务"; self.view.backgroundColor=UIColor.blackColor;
    UIScrollView *scroll=[UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new]; stack.translatesAutoresizingMaskIntoConstraints=NO; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=14; stack.layoutMargins=UIEdgeInsetsMake(20,18,28,18); stack.layoutMarginsRelativeArrangement=YES; [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor],[stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor]]];
    UILabel *intro=[self label:@"本机服务" size:13 color:UIColor.secondaryLabelColor]; [stack addArrangedSubview:intro];
    UIView *card=[self card]; UIStackView *body=[UIStackView new]; body.axis=UILayoutConstraintAxisVertical; body.spacing=13; body.translatesAutoresizingMaskIntoConstraints=NO; [card addSubview:body]; [NSLayoutConstraint activateConstraints:@[[body.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],[body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],[body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],[body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16]]];
    UIStackView *header=[UIStackView new]; header.axis=UILayoutConstraintAxisHorizontal; header.alignment=UIStackViewAlignmentCenter; header.spacing=9;
    self.dot=[UIView new]; self.dot.translatesAutoresizingMaskIntoConstraints=NO; self.dot.layer.cornerRadius=5; [NSLayoutConstraint activateConstraints:@[[self.dot.widthAnchor constraintEqualToConstant:10],[self.dot.heightAnchor constraintEqualToConstant:10]]];
    [header addArrangedSubview:self.dot]; self.statusLabel=[self label:@"检查服务状态…" size:17 color:UIColor.whiteColor]; self.statusLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; [header addArrangedSubview:self.statusLabel]; [body addArrangedSubview:header];
    [body addArrangedSubview:[self label:@"YSP Live · 内嵌 Python 3.13" size:14 color:UIColor.secondaryLabelColor]];
    [body addArrangedSubview:[self label:@"本机地址  http://127.0.0.1:8767/all.m3u" size:13 color:UIColor.systemPinkColor]];
    [body addArrangedSubview:[self label:@"iOS 安全模式：缓存 32 MB · 高码率并发 2 路" size:12 color:UIColor.tertiaryLabelColor]];
    [stack addArrangedSubview:card];
    UIButton *open=[self button:@"管理插件与订阅" icon:@"slider.horizontal.3"]; [open addTarget:self action:@selector(openPlugin) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:open];
    UIView *note=[self card]; UILabel *noteLabel=[self label:@"本服务只绑定本机回环地址，供 CCTVHost 订阅播放。切换到后台时，iOS 可能挂起服务；重新进入后请先查看状态。" size:13 color:UIColor.secondaryLabelColor]; noteLabel.numberOfLines=0; noteLabel.translatesAutoresizingMaskIntoConstraints=NO; [note addSubview:noteLabel]; [NSLayoutConstraint activateConstraints:@[[noteLabel.topAnchor constraintEqualToAnchor:note.topAnchor constant:15],[noteLabel.bottomAnchor constraintEqualToAnchor:note.bottomAnchor constant:-15],[noteLabel.leadingAnchor constraintEqualToAnchor:note.leadingAnchor constant:15],[noteLabel.trailingAnchor constraintEqualToAnchor:note.trailingAnchor constant:-15]]]; [stack addArrangedSubview:note];
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.timer invalidate]; self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self.timer invalidate]; self.timer=nil; }
- (void)dealloc { [self.timer invalidate]; }
- (void)refresh { BOOL running=PyHost.running; self.dot.backgroundColor=running?UIColor.systemGreenColor:UIColor.systemGrayColor; self.statusLabel.text=running?@"运行中":@"已停止"; }
- (void)openPlugin { if(self.onOpenYSP) self.onOpenYSP(); }
- (UIView *)card { UIView *v=[UIView new]; v.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1]; v.layer.cornerRadius=18; v.layer.masksToBounds=YES; return v; }
- (UILabel *)label:(NSString *)s size:(CGFloat)size color:(UIColor *)color { UILabel *l=[UILabel new]; l.text=s; l.font=[UIFont systemFontOfSize:size]; l.textColor=color; return l; }
- (UIButton *)button:(NSString *)title icon:(NSString *)icon { UIButtonConfiguration *c=[UIButtonConfiguration filledButtonConfiguration]; c.title=title; c.image=[UIImage systemImageNamed:icon]; c.imagePlacement=NSDirectionalRectEdgeLeading; c.imagePadding=8; c.baseBackgroundColor=[UIColor colorWithRed:0.78 green:0.18 blue:0.43 alpha:1]; c.cornerStyle=UIButtonConfigurationCornerStyleCapsule;     UIButton *b=[UIButton buttonWithConfiguration:c primaryAction:nil]; [b.heightAnchor constraintEqualToConstant:48].active=YES; return b; }
@end
