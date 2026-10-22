#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import <objc/message.h>
#import <string.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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
- (id)callInstance:(id)obj selector:(SEL)sel args:(NSArray *)args;
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
    self.title = @"CCTVHost 0.1.2 诊断版";

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

    [self log:@"BUILD 0.1.2 — delegate / BOOL / option-key diagnostics"];
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

        id ver = [self callClass:CNPlayerCls selector:NSSelectorFromString(@"SDKVersion") args:@[]];
        [self log:@"SDKVersion = %@", ver];
        [self callClass:CNPlayerCls selector:NSSelectorFromString(@"authed") args:@[]];

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf callClass:CNPlayerCls selector:NSSelectorFromString(@"authed") args:@[]];
        });
    } @catch (NSException *e) {
        [self log:@"startPlayerSDK_Options 异常: %@", e];
    }
    [self log:@"尚未验证授权；无回调不能推断缺少凭据，不提取或复用原 App 密钥。"];
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
        if (v == NSNull.null) { id zero = nil; [inv setArgument:&zero atIndex:i + 2]; continue; }
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

- (id)callInstance:(id)obj selector:(SEL)sel args:(NSArray *)args {
    if (![obj respondsToSelector:sel]) {
        [self log:@"跳过（实例方法不存在）: %@", NSStringFromSelector(sel)];
        return nil;
    }
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        id v = args[i];
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        if (v == NSNull.null) { id zero = nil; [inv setArgument:&zero atIndex:i + 2]; continue; }
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
    @try { [inv invoke]; } @catch (NSException *e) { [self log:@"调用异常: %@", e]; return nil; }
    const char *rt = sig.methodReturnType;
    [self log:@"- [%@ %@] 返回类型 %s", [obj class], NSStringFromSelector(sel), rt];
    if (rt[0] == '@') {
        void *p = NULL;
        [inv getReturnValue:&p];
        return (__bridge id)p;
    }
    if (rt[0] == 'B' || rt[0] == 'c') {
        char r = 0;
        [inv getReturnValue:&r];
        [self log:@"   返回 %d", r];
        return @(r != 0);
    }
    return nil;
}

#pragma mark - 播放

- (void)tapChannel:(UIButton *)sender {
    NSArray *channels = @[@"cctv1", @"cctv2", @"cctv5", @"cctv5plus", @"cctv6", @"cctv13"];
    NSString *cid = channels[sender.tag];
    Class CNPlayerCls = NSClassFromString(@"CNPlayer");
    [self log:@"—— 起播 %@ ——", cid];

    if (self.currentPlayer) {
        [self callInstance:self.currentPlayer selector:NSSelectorFromString(@"stop") args:@[]];
        self.currentPlayer = nil;
    }
    for (UIView *v in self.playerBox.subviews.copy) [v removeFromSuperview];
    [self callClass:CNPlayerCls selector:NSSelectorFromString(@"authed") args:@[]];
    id inst = nil;
    @try { inst = [[CNPlayerCls alloc] init]; } @catch (NSException *e) { [self log:@"init 异常: %@", e]; }
    if (!inst) {
        [self log:@"CNPlayer 实例化失败"];
        return;
    }
    [self log:@"CNPlayer 实例 = %@", inst];

    SEL playSel = NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    if (![inst respondsToSelector:playSel]) {
        [self log:@"实例也不响应 playLIVEWithChannelID:，SDK 版本可能不同"];
        return;
    }
    self.currentPlayer = inst; // retain before asynchronous callbacks
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    // Use only the named SDK config constant when publicly exported.
    NSString * __unsafe_unretained *titleKey = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "CNPlayerConfigOptionKey_Title");
    if (titleKey && *titleKey) options[*titleKey] = cid;
    else [self log:@"Title option constant not exported; no guessed key injected"];
    Protocol *proto = NSProtocolFromString(@"CNPlayerCallbackProtocol");
    [self log:@"callback protocol visible=%d", proto != nil];
    if (proto) class_addProtocol(self.class, proto);
    id accepted = [self callInstance:inst selector:playSel args:@[cid, self, options]];
    if (![accepted isKindOfClass:NSNumber.class] || ![accepted boolValue]) {
        self.statusLabel.text = @"SDK 拒绝起播（BOOL 0），请查看错误回调";
        [self log:@"起播未获接受，未调用 prepareToPlay。等待 authFailed / parameterError / VDN 回调。"];
        return;
    }
    id view = nil;
    @try {
        if ([inst respondsToSelector:NSSelectorFromString(@"view")]) {
            view = [inst valueForKey:@"view"];
        }
    } @catch (NSException *e) {
        [self log:@"取 view 异常: %@", e];
    }
    [self log:@"player.view = %@", view];
    if ([view isKindOfClass:UIView.class]) {
        UIView *v = view;
        v.frame = self.playerBox.bounds;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.playerBox addSubview:v];
    }
    [self callInstance:inst selector:NSSelectorFromString(@"prepareToPlay") args:@[]];
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


#pragma mark - Documented SDK callbacks (no license or credential payload logging)
- (void)authFailed:(NSError *)error {
    [self log:@"authFailed domain=%@ code=%ld description=%@", error.domain, (long)error.code, error.localizedDescription];
}
- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    [self log:@"parameterError domain=%@ code=%ld description=%@", error.domain, (long)error.code, error.localizedDescription];
}
- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    [self log:@"vdnRequestFailed domain=%@ code=%ld description=%@", error.domain, (long)error.code, error.localizedDescription];
}
- (void)player:(id)player playbackFailed:(NSError *)error {
    [self log:@"playbackFailed domain=%@ code=%ld description=%@", error.domain, (long)error.code, error.localizedDescription];
}
- (void)player:(id)player publicRequestFailed:(NSError *)error {
    [self log:@"publicRequestFailed domain=%@ code=%ld description=%@", error.domain, (long)error.code, error.localizedDescription];
}
- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {
    [self log:@"loadState=%lu (not proof of first frame)", (unsigned long)state];
}
- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    [self log:@"VDN state=%lu", (unsigned long)state];
}
- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    [self log:@"playback state=%lu", (unsigned long)state];
}

@end
