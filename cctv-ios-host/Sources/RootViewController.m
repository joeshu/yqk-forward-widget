#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import <objc/message.h>
#import <string.h>

static NSString *const kLicenseUrl = @"https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense";
static NSString *const kLicenseUrlAlt = @"https://cdrm.live.cntv.cn/udrm/udmCNTVGetLicense";

@interface RootViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIView *playerBox;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) id currentPlayer;
@property (nonatomic, strong) CicadaPlayer *cicadaPlayer;

- (void)log:(NSString *)format, ...;
- (void)setupSDK;
- (id)callClass:(Class)cls selector:(SEL)sel args:(NSArray *)args;
- (void)callInstance:(id)obj selector:(SEL)sel args:(NSArray *)args;
- (void)tapChannel:(UIButton *)sender;
- (void)tapCicada:(UIButton *)sender;
@end

@implementation RootViewController

#pragma mark - 日志

- (void)log:(NSString *)format, ... {
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[CCTVHost] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [self.logView.text stringByAppendingFormat:@"%@\n", msg];
        NSRange end = NSMakeRange(self.logView.text.length, 0);
        [self.logView scrollRangeToVisible:end];
    });
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.title = @"CCTV 原生宿主 M1";

    CGFloat w = self.view.bounds.size.width;

    self.playerBox = [[UIView alloc] initWithFrame:CGRectMake(0, 100, w, w * 9 / 16)];
    self.playerBox.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    self.playerBox.clipsToBounds = YES;
    [self.view addSubview:self.playerBox];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 60, w - 16, 30)];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.text = @"未启动";
    [self.view addSubview:self.statusLabel];

    CGFloat y = CGRectGetMaxY(self.playerBox.frame) + 8;
    NSArray *channels = @[@"cctv1", @"cctv2", @"cctv5", @"cctv5plus", @"cctv6", @"cctv13"];
    CGFloat bw = (w - 8 * 4) / 3.0;
    for (NSUInteger i = 0; i < channels.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(8 + (i % 3) * (bw + 8), y + (i / 3) * 40, bw, 34);
        [b setTitle:channels[i] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.tag = (NSInteger)i;
        [b addTarget:self action:@selector(tapChannel:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
    y += 2 * 40 + 8;

    self.urlField = [[UITextField alloc] initWithFrame:CGRectMake(8, y, w - 16, 34)];
    self.urlField.placeholder = @"粘贴受保护 m3u8（Cicada 直连调试）";
    self.urlField.textColor = UIColor.whiteColor;
    self.urlField.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    self.urlField.font = [UIFont systemFontOfSize:12];
    self.urlField.delegate = self;
    self.urlField.returnKeyType = UIReturnKeyGo;
    [self.view addSubview:self.urlField];
    y += 40;

    UIButton *cicadaBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cicadaBtn.frame = CGRectMake(8, y, w - 16, 34);
    [cicadaBtn setTitle:@"Cicada 直连播放（调试用）" forState:UIControlStateNormal];
    cicadaBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.4 blue:0.3 alpha:1];
    [cicadaBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cicadaBtn addTarget:self action:@selector(tapCicada:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cicadaBtn];
    y += 44;

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(0, y, w, self.view.bounds.size.height - y)];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.logView.textColor = [UIColor colorWithRed:0.6 green:0.9 blue:0.6 alpha:1];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.logView.editable = NO;
    [self.view addSubview:self.logView];

    [self setupSDK];
}

#pragma mark - SDK 启动

- (void)setupSDK {
    Class CNPlayerCls = NSClassFromString(@"CNPlayer");
    [self log:@"CNPlayer class = %@, CicadaPlayer class = %@",
         CNPlayerCls, NSClassFromString(@"CicadaPlayer")];
    if (!CNPlayerCls) {
        self.statusLabel.text = @"SDK 未加载：检查三个 framework 是否 Embed & Sign";
        return;
    }
    @try {
        [CNPlayer logEnabled:YES];
    } @catch (NSException *e) { [self log:@"logEnabled 异常: %@", e]; }

    // 端点可注入，但默认让 SDK 使用自身配置更稳妥
    [self callClass:CNPlayerCls selector:NSSelectorFromString(@"configSDK_CICADA_UDRMUrl:") args:@[kLicenseUrl]];

    @try {
        id opts = [CNPlayer defaultOptions];
        [self log:@"defaultOptions = %@", opts];
        [CNPlayer startPlayerSDK_Options:opts];
        self.statusLabel.text = @"SDK 启动指令已发出，等待内部 auth/VDN";
    } @catch (NSException *e) {
        [self log:@"startPlayerSDK_Options 异常: %@", e];
    }
    [self log:@"如果 10 秒内没有 auth/VDN 日志，说明需要显式 appKey/appSecret（见 README 第 5 节）"];
}

#pragma mark - 通用调用（对未知签名容错）

- (id)callClass:(Class)cls selector:(SEL)sel args:(NSArray *)args {
    if (![cls respondsToSelector:sel]) {
        [self log:@"跳过（类方法不存在）: %@", NSStringFromSelector(sel)];
        return nil;
    }
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    [self log:@"调用 +[%@ %@] 返回类型 %s 参数 %lu",
         cls, NSStringFromSelector(sel), sig.methodReturnType, (unsigned long)args.count];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = cls;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        id v = args[i];
        if (v == NSNull.null) continue;
        if (strcmp(t, "@") == 0 || strcmp(t, "@?") == 0) {
            id a = v;
            [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "c") == 0 || strcmp(t, "B") == 0) {
            char a = [v boolValue];
            [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "q") == 0 || strcmp(t, "l") == 0) {
            long long a = [v longLongValue];
            [inv setArgument:&a atIndex:i + 2];
        } else {
            [self log:@"参数 %lu 类型 %s 暂不支持，跳过", (unsigned long)i, t];
        }
    }
    @try {
        [inv invoke];
    } @catch (NSException *e) {
        [self log:@"调用异常: %@", e];
        return nil;
    }
    const char *rt = sig.methodReturnType;
    if (rt[0] == '@') {
        void *p = NULL;
        [inv getReturnValue:&p];
        id ret = (__bridge id)p;
        [self log:@"返回对象: %@", ret];
        return ret;
    }
    if (rt[0] == 'B' || rt[0] == 'c') {
        char r = 0;
        [inv getReturnValue:&r];
        [self log:@"返回 bool: %d", r];
    }
    return nil;
}

- (void)callInstance:(id)obj selector:(SEL)sel args:(NSArray *)args {
    if (![obj respondsToSelector:sel]) {
        [self log:@"跳过（实例方法不存在）: %@", NSStringFromSelector(sel)];
        return;
    }
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        id v = args[i];
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        if (v == NSNull.null) continue;
        if (strcmp(t, "@") == 0 || strcmp(t, "@?") == 0) {
            id a = v;
            [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "c") == 0 || strcmp(t, "B") == 0) {
            char a = [v boolValue];
            [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "q") == 0 || strcmp(t, "l") == 0) {
            long long a = [v longLongValue];
            [inv setArgument:&a atIndex:i + 2];
        }
    }
    @try { [inv invoke]; } @catch (NSException *e) { [self log:@"调用异常: %@", e]; }
}

#pragma mark - 播放

- (void)tapChannel:(UIButton *)sender {
    NSArray *channels = @[@"cctv1", @"cctv2", @"cctv5", @"cctv5plus", @"cctv6", @"cctv13"];
    NSString *cid = channels[sender.tag];
    Class CNPlayerCls = NSClassFromString(@"CNPlayer");
    [self log:@"—— 起播 %@ ——", cid];
    SEL playSel = NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    NSArray *playArgs = @[cid, NSNull.null, @{@"Title": cid}];

    id player = [self callClass:CNPlayerCls selector:playSel args:playArgs];

    // 兼容：若 playLIVE… 实为实例方法（返回值不是对象），退回 alloc+init 再调用
    if (!player) {
        [self log:@"类方法未返回 player，尝试实例方法路径"];
        id inst = nil;
        @try { inst = [[CNPlayerCls alloc] init]; } @catch (NSException *e) { [self log:@"init 异常: %@", e]; }
        if (inst) {
            SEL initLive = NSSelectorFromString(@"initWithLivePlayItem:delegate:configOptions:");
            if ([inst respondsToSelector:initLive]) {
                [self log:@"存在 initWithLivePlayItem:，需要 CNPlayerItem（本版未构造），跳过"];
            } else if ([inst respondsToSelector:playSel]) {
                [self callInstance:inst selector:playSel args:playArgs];
                player = inst;
            }
        }
    }
    if (!player) {
        [self log:@"未取得 player 实例：停止在日志判读（见 README 第五节）"];
        return;
    }
    self.currentPlayer = player;
    id view = nil;
    @try {
        if ([player respondsToSelector:NSSelectorFromString(@"view")]) {
            view = [player valueForKey:@"view"];
        }
    } @catch (NSException *e) {
        [self log:@"取 view 异常: %@", e];
    }
    [self log:@"player = %@, view = %@", player, view];
    if ([view isKindOfClass:UIView.class]) {
        UIView *v = view;
        v.frame = self.playerBox.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.playerBox addSubview:v];
    }
    [self callInstance:player selector:NSSelectorFromString(@"prepareToPlay") args:@[]];
    self.statusLabel.text = [NSString stringWithFormat:@"请求起播 %@", cid];
}

- (void)tapCicada:(UIButton *)sender {
    NSString *url = self.urlField.text.length ? self.urlField.text : nil;
    if (!url) { [self log:@"请先输入受保护 m3u8"]; return; }
    [self log:@"—— Cicada 直连 ——\n%@", url];

    CicadaConfig *cfg = [CicadaConfig new];
    cfg.isNeedUDRMDecrypt_pvt = YES;
    cfg.udrmLicenseUrl = kLicenseUrl;
    cfg.networkTimeout = 15;
    [self log:@"CicadaConfig UDRM=%d license=%@", cfg.isNeedUDRMDecrypt_pvt, cfg.udrmLicenseUrl];

    CicadaPlayer *p = [[CicadaPlayer alloc] init];
    [p setConfig:cfg];
    [p setEnableHardwareDecoder:YES];
    [p setPlayerView:self.playerBox];
    [p setUrlSource:[CicadaUrlSource urlWithString:url]];
    [p prepare];
    [p start];
    self.cicadaPlayer = p;
    self.statusLabel.text = @"Cicada 直连已发起";
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self tapCicada:nil];
    return YES;
}

@end
