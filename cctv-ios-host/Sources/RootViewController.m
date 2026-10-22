#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import "EPGViewController.h"
#import <objc/message.h>
#import <string.h>

static NSString *const kLicenseUrl = @"https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense";

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
// 播放
@property (nonatomic, strong) UIView *playerBox;
@property (nonatomic, strong) UILabel *overlayTitle;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) id currentPlayer;
@property (nonatomic, copy) NSString *currentChannelID;
@property (nonatomic, copy) NSString *currentChannelName;
@property (nonatomic, assign) BOOL firstRender;
// 控制条
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *muteBtn;
@property (nonatomic, strong) UIButton *fullBtn;
@property (nonatomic, strong) UIButton *logBtn;
// 频道列表
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISegmentedControl *groupControl;
@property (nonatomic, strong) NSArray<NSDictionary *> *allChannels;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownChannels;
// 日志
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, assign) BOOL logVisible;
@property (nonatomic, assign) BOOL fullscreen;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) NSInteger watchdogTicks;
@property (nonatomic, strong) id sdkPlayer;
@property (nonatomic, strong) CicadaPlayer *cicadaPlayer;
@property (nonatomic, strong) UILabel *nowLabel;
@property (nonatomic, strong) UIButton *epgBtn;
@property (nonatomic, strong) NSURLSessionDataTask *epgTask;
@property (nonatomic, strong) NSTimer *epgTimer;
@property (nonatomic, copy) NSString *epgChannel;
@end

@implementation RootViewController

#pragma mark - 日志

- (void)log:(NSString *)format, ... {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[CCTVHost] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendFormat:@"%@\n", msg];
        if (self.logBuffer.length > 12000) {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 10000)];
        }
        if (self.logVisible) {
            self.logView.text = self.logBuffer;
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
        }
    });
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1];
    self.title = @"CCTVHost";
    self.logBuffer = [NSMutableString string];
    self.firstRender = NO;
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor = UIColor.whiteColor;

    [self loadChannels];
    [self buildPlayerArea];
    [self buildList];
    [self activateAudioSession];
    [self setupSDK];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.watchdog invalidate];
}

- (void)onBackground {
    [self callInstance:self.currentPlayer selector:NSSelectorFromString(@"resignActive") args:@[]];
    [self log:@"进入后台"];
}

- (void)onForeground {
    [self callInstance:self.currentPlayer selector:NSSelectorFromString(@"becomeActive") args:@[]];
    [self log:@"回到前台"];
}

- (void)activateAudioSession {
    Class sessionCls = NSClassFromString(@"AVAudioSession");
    if (!sessionCls) return;
    id session = ((id (*)(id, SEL))objc_msgSend)(sessionCls, NSSelectorFromString(@"sharedInstance"));
    if (!session) return;
    BOOL (*setCategory)(id, SEL, NSString *, NSError **) = (void *)objc_msgSend;
    BOOL (*setActive)(id, SEL, BOOL, NSError **) = (void *)objc_msgSend;
    setCategory(session, NSSelectorFromString(@"setCategory:error:"), @"AVAudioSessionCategoryPlayback", NULL);
    setActive(session, NSSelectorFromString(@"setActive:error:"), YES, NULL);
    [self log:@"音频会话已设为播放模式"];
}

#pragma mark - 频道数据

- (void)loadChannels {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"channels" ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSArray *arr = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    self.allChannels = [arr isKindOfClass:NSArray.class] ? arr : @[];
    self.shownChannels = self.allChannels;
    [self log:@"频道目录载入 %lu 项", (unsigned long)self.allChannels.count];
}

- (void)filterChannels:(NSInteger)index {
    NSArray *groups = @[@"全部", @"央视", @"卫视", @"地方", @"教育"];
    NSString *g = groups[MAX(0, MIN((NSInteger)groups.count - 1, index))];
    if ([g isEqualToString:@"全部"]) {
        self.shownChannels = self.allChannels;
    } else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *obj, NSDictionary *bindings) {
            return [obj[@"group"] isEqualToString:g];
        }];
        self.shownChannels = [self.allChannels filteredArrayUsingPredicate:p];
    }
    [self.table reloadData];
}

#pragma mark - 播放区

- (void)buildPlayerArea {
    CGFloat w = self.view.bounds.size.width;
    self.playerBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, w * 9.0 / 16.0)];
    self.playerBox.backgroundColor = UIColor.blackColor;
    self.playerBox.clipsToBounds = YES;
    [self.view addSubview:self.playerBox];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];
    [self.playerBox addGestureRecognizer:tap];

    self.overlayTitle = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 20)];
    self.overlayTitle.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    self.overlayTitle.font = [UIFont systemFontOfSize:12];
    self.overlayTitle.text = @"未选择频道";
    [self.playerBox addSubview:self.overlayTitle];

    self.nowLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 28, w - 24, 16)];
    self.nowLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.nowLabel.font = [UIFont systemFontOfSize:11];
    self.nowLabel.text = @"";
    [self.playerBox addSubview:self.nowLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(w / 2, w * 9 / 32);
    self.spinner.hidesWhenStopped = YES;
    [self.playerBox addSubview:self.spinner];

    CGFloat cy = w * 9.0 / 16.0 - 40;
    self.playPauseBtn = [self controlButton:@"暂停" x:8 y:cy action:@selector(togglePlayPause)];
    self.muteBtn = [self controlButton:@"静音" x:80 y:cy action:@selector(toggleMute)];
    self.fullBtn = [self controlButton:@"全屏" x:152 y:cy action:@selector(toggleFullscreen)];
    self.epgBtn = [self controlButton:@"节目单" x:w - 146 y:cy action:@selector(openEPG)];
    self.logBtn = [self controlButton:@"日志" x:w - 74 y:cy action:@selector(toggleLog)];
}

- (UIButton *)controlButton:(NSString *)title x:(CGFloat)x y:(CGFloat)y action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(x, y, 68, 30);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    b.titleLabel.font = [UIFont systemFontOfSize:13];
    b.layer.cornerRadius = 6;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.playerBox addSubview:b];
    return b;
}

- (void)toggleControls {
    self.overlayTitle.hidden = !self.overlayTitle.hidden;
}

- (void)buildList {
    CGFloat y = CGRectGetMaxY(self.playerBox.frame);
    self.groupControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"央视", @"卫视", @"地方", @"教育"]];
    self.groupControl.frame = CGRectMake(8, y + 6, self.view.bounds.size.width - 16, 30);
    self.groupControl.selectedSegmentIndex = 0;
    self.groupControl.tintColor = [UIColor colorWithWhite:0.7 alpha:1];
    [self.groupControl addTarget:self action:@selector(onGroupChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.groupControl];

    CGFloat ty = CGRectGetMaxY(self.groupControl.frame) + 6;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.table.separatorColor = [UIColor colorWithWhite:0.2 alpha:1];
    self.table.rowHeight = 46;
    [self.view addSubview:self.table];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty)];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.97];
    self.logView.textColor = [UIColor colorWithRed:0.6 green:0.9 blue:0.6 alpha:1];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.logView.editable = NO;
    self.logView.hidden = YES;
    [self.view addSubview:self.logView];
}

- (void)onGroupChanged {
    [self filterChannels:self.groupControl.selectedSegmentIndex];
}

#pragma mark - 列表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.shownChannels.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"ch";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        UIView *bg = [[UIView alloc] init];
        bg.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
        cell.selectedBackgroundView = bg;
    }
    NSDictionary *ch = self.shownChannels[indexPath.row];
    cell.textLabel.text = ch[@"name"] ?: ch[@"id"];
    BOOL verified = [ch[@"verified"] boolValue];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", ch[@"group"], verified ? @"已验证线路" : @"未验证线路"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *ch = self.shownChannels[indexPath.row];
    NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ch[@"name"]
                                                                  message:[NSString stringWithFormat:@"%@ · %lu 条线路",
                                                                           ch[@"group"], (unsigned long)routes.count]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"自动选线（SDK 调度）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self playChannel:ch[@"id"] name:ch[@"name"] route:nil];
    }]];
    for (NSDictionary *r in routes) {
        NSString *res = [r[@"w"] intValue] > 0 ? [NSString stringWithFormat:@"%dx%d", [r[@"w"] intValue], [r[@"h"] intValue]] : @"";
        NSString *title = [NSString stringWithFormat:@"节点 %@ %@", [r[@"provider"] uppercaseString], res];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playChannel:ch[@"id"] name:ch[@"name"] route:r];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"查看节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self openEPGforChannel:ch[@"id"] name:ch[@"name"]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = tableView;
    sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - SDK

- (void)setupSDK {
    Class CNPlayerCls = NSClassFromString(@"CNPlayer");
    if (!CNPlayerCls) {
        self.overlayTitle.text = @"SDK 未加载";
        [self log:@"CNPlayer 未找到：framework 未嵌入或未签名"];
        return;
    }
    @try { [CNPlayer logEnabled:YES]; } @catch (NSException *e) { [self log:@"logEnabled 异常: %@", e.reason]; }
    [self callClass:CNPlayerCls selector:NSSelectorFromString(@"configSDK_CICADA_UDRMUrl:") args:@[kLicenseUrl]];
    @try {
        [CNPlayer startPlayerSDK_Options:[CNPlayer defaultOptions]];
        id ver = [self callClass:CNPlayerCls selector:NSSelectorFromString(@"SDKVersion") args:@[]];
        [self log:@"SDK 已启动 version=%@", ver];
        [self callClass:CNPlayerCls selector:NSSelectorFromString(@"authed") args:@[]];
    } @catch (NSException *e) {
        [self log:@"startPlayerSDK 异常: %@", e.reason];
    }
}

#pragma mark - 播放控制

- (void)playChannel:(NSString *)cid name:(NSString *)name route:(NSDictionary *)route {
    if (!cid.length) return;
    NSString *routeDesc = route ? [NSString stringWithFormat:@"节点 %@", [route[@"provider"] uppercaseString]] : @"自动选线";
    [self log:@"—— 切换 %@ (%@) · %@ ——", name, cid, routeDesc];

    [self stopCurrent];
    self.currentChannelID = cid;
    self.currentChannelName = name ?: cid;
    self.firstRender = NO;
    self.overlayTitle.text = [NSString stringWithFormat:@"%@ · 连接中", self.currentChannelName];
    self.nowLabel.text = @"";
    [self.spinner startAnimating];
    self.playPauseBtn.selected = NO;
    [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];

    if (route[@"url"]) {
        [self playViaCicada:route[@"url"]];
    } else {
        [self playViaSDK:cid];
    }
    [self refreshNowNext];
    [self startEPGTimer];
}

- (void)playViaSDK:(NSString *)cid {
    Class CNPlayerCls = NSClassFromString(@"CNPlayer");
    id inst = self.sdkPlayer;
    SEL playSel = NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");

    // 复用已有实例：省掉每次 alloc/init 与 SDK 内部重建
    if (inst && [inst respondsToSelector:playSel]) {
        [self log:@"复用播放器实例，跳过初始化"];
        [self callInstance:inst selector:NSSelectorFromString(@"reset") args:@[]];
    } else {
        @try { inst = [[CNPlayerCls alloc] init]; } @catch (NSException *e) { [self log:@"init 异常: %@", e.reason]; }
        self.sdkPlayer = inst;
    }
    if (!inst) { self.overlayTitle.text = @"播放器创建失败"; return; }
    self.currentPlayer = inst;
    self.cicadaPlayer = nil;

    @try { [inst setValue:@(YES) forKey:@"autoPlay"]; } @catch (NSException *e) {}
    if (![inst respondsToSelector:playSel]) {
        self.overlayTitle.text = @"SDK 接口不匹配";
        [self log:@"SDK 不支持 playLIVEWithChannelID:"];
        return;
    }
    id accepted = [self callInstance:inst selector:playSel args:@[cid, self, @{}]];
    if ([accepted isKindOfClass:NSNumber.class] && ![accepted boolValue]) {
        self.overlayTitle.text = @"起播被拒绝";
        [self log:@"起播返回 0，等待错误回调"];
        return;
    }
    [self attachPlayerViewAnimated:NO];
    [self callInstance:inst selector:NSSelectorFromString(@"prepareToPlay") args:@[]];
    [self startWatchdog];
}

- (void)playViaCicada:(NSString *)url {
    Class cicadaCls = NSClassFromString(@"CicadaPlayer");
    Class cfgCls = NSClassFromString(@"CicadaConfig");
    Class srcCls = NSClassFromString(@"CicadaUrlSource");
    if (!cicadaCls || !cfgCls || !srcCls) {
        self.overlayTitle.text = @"Cicada 内核不可用";
        return;
    }
    id cfg = [[cfgCls alloc] init];
    [cfg setValue:@(YES) forKey:@"isNeedUDRMDecrypt_pvt"];
    [cfg setValue:kLicenseUrl forKey:@"udrmLicenseUrl"];
    [cfg setValue:@(15) forKey:@"networkTimeout"];

    id player = [[cicadaCls alloc] init];
    self.currentPlayer = player;
    self.cicadaPlayer = player;
    self.sdkPlayer = nil;

    [self callInstance:player selector:NSSelectorFromString(@"setConfig:") args:@[cfg]];
    [self callInstance:player selector:NSSelectorFromString(@"setEnableHardwareDecoder:") args:@[@(YES)]];
    [self callInstance:player selector:NSSelectorFromString(@"setPlayerView:") args:@[self.playerBox]];
    id source = [self callClass:srcCls selector:NSSelectorFromString(@"urlWithString:") args:@[url]];
    if (source) [self callInstance:player selector:NSSelectorFromString(@"setUrlSource:") args:@[source]];
    [self callInstance:player selector:NSSelectorFromString(@"prepare") args:@[]];
    [self callInstance:player selector:NSSelectorFromString(@"start") args:@[]];
    [self log:@"Cicada 直连已发起：%@", url];
    [self startWatchdog];
}

- (void)stopCurrent {
    if (!self.currentPlayer) return;
    [self callInstance:self.currentPlayer selector:NSSelectorFromString(@"stop") args:@[]];
    if (self.cicadaPlayer) {
        [self callInstance:self.cicadaPlayer selector:NSSelectorFromString(@"destroy") args:@[]];
        self.cicadaPlayer = nil;
    }
    @try { [self.currentPlayer setValue:nil forKey:@"delegate"]; } @catch (NSException *e) {}
    self.currentPlayer = nil;
    [self.watchdog invalidate]; self.watchdog = nil;
    [self.epgTask cancel]; [self.epgTimer invalidate];
    for (UIView *v in self.playerBox.subviews.copy) {
        if (v != self.overlayTitle && v != self.spinner && v != self.playPauseBtn &&
            v != self.muteBtn && v != self.fullBtn && v != self.logBtn) {
            [v removeFromSuperview];
        }
    }
}

- (void)attachPlayerViewAnimated:(BOOL)animated {
    id view = nil;
    @try { view = [self.currentPlayer valueForKey:@"view"]; } @catch (NSException *e) { return; }
    if (![view isKindOfClass:UIView.class]) return;
    UIView *v = view;
    if (v.superview != self.playerBox) {
        [self.playerBox insertSubview:v atIndex:0];
        [self.playerBox sendSubviewToBack:v];
    }
    v.translatesAutoresizingMaskIntoConstraints = YES;
    CGRect box = self.playerBox.bounds;
    if (!CGRectEqualToRect(v.frame, box)) {
        v.frame = box;
    }
}

- (void)togglePlayPause {
    if (!self.currentPlayer) return;
    BOOL playing = NO;
    @try { playing = [[self.currentPlayer valueForKey:@"isPlaying"] boolValue]; } @catch (NSException *e) {}
    SEL sel = NSSelectorFromString(playing ? @"pause" : @"play");
    [self callInstance:self.currentPlayer selector:sel args:@[]];
    [self.playPauseBtn setTitle:playing ? @"继续" : @"暂停" forState:UIControlStateNormal];
    [self log:@"%@", playing ? @"暂停" : @"继续"];
}

- (void)toggleMute {
    static BOOL muted = YES;
    muted = !muted;
    @try { [self.currentPlayer setValue:@(muted) forKey:@"muted"]; } @catch (NSException *e) {}
    [self.muteBtn setTitle:muted ? @"取消静音" : @"静音" forState:UIControlStateNormal];
}

- (void)toggleFullscreen {
    self.fullscreen = !self.fullscreen;
    [self.fullBtn setTitle:self.fullscreen ? @"退出全屏" : @"全屏" forState:UIControlStateNormal];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    if (self.fullscreen) {
        self.playerBox.frame = CGRectMake(0, 0, w, h);
        self.table.hidden = YES;
        self.groupControl.hidden = YES;
        self.navigationController.navigationBarHidden = YES;
    } else {
        self.playerBox.frame = CGRectMake(0, 0, w, w * 9.0 / 16.0);
        self.table.hidden = NO;
        self.groupControl.hidden = NO;
        self.navigationController.navigationBarHidden = NO;
    }
    [self repositionControls];
    [self attachPlayerViewAnimated:NO];
}

- (void)repositionControls {
    CGRect box = self.playerBox.bounds;
    CGFloat cy = box.size.height - 40;
    self.playPauseBtn.frame = CGRectMake(8, cy, 68, 30);
    self.muteBtn.frame = CGRectMake(80, cy, 70, 30);
    self.fullBtn.frame = CGRectMake(152, cy, 70, 30);
    self.epgBtn.frame = CGRectMake(box.size.width - 146, cy, 68, 30);
    self.logBtn.frame = CGRectMake(box.size.width - 74, cy, 68, 30);
    self.spinner.center = CGPointMake(box.size.width / 2, box.size.height / 2);
    self.overlayTitle.frame = CGRectMake(12, 8, box.size.width - 24, 20);
    self.nowLabel.frame = CGRectMake(12, 28, box.size.width - 24, 16);
}

- (void)toggleLog {
    self.logVisible = !self.logVisible;
    self.logView.hidden = !self.logVisible;
    if (self.logVisible) {
        self.logView.text = self.logBuffer;
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    }
}

#pragma mark - 节目单

- (void)openEPG {
    if (!self.currentChannelID.length) { [self log:@"请先选择频道"]; return; }
    [self openEPGforChannel:self.currentChannelID name:self.currentChannelName];
}

- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name {
    EPGViewController *vc = [[EPGViewController alloc] initWithChannelID:cid name:name];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)startEPGTimer {
    [self.epgTimer invalidate];
    self.epgTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshNowNext) userInfo:nil repeats:YES];
}

- (void)refreshNowNext {
    NSString *cid = self.currentChannelID;
    if (!cid.length) return;
    self.epgChannel = cid;
    NSString *encoded = [cid stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 10;

    __weak typeof(self) weakSelf = self;
    [self.epgTask cancel];
    self.epgTask = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!data.length) return;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSArray *rows = [(NSDictionary *)json objectForKey:@"EPG"];
        if (![rows isKindOfClass:NSArray.class]) return;
        double now = NSDate.date.timeIntervalSince1970;
        NSString *current = nil, *next = nil;
        for (NSDictionary *row in rows) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            double s0 = [row[@"startTime"] doubleValue], e0 = [row[@"endTime"] doubleValue];
            if (s0 > 1e11) s0 /= 1000.0;
            if (e0 > 1e11) e0 /= 1000.0;
            if (now >= s0 && now < e0) current = row[@"title"];
            else if (s0 > now && !next) next = row[@"title"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf.epgChannel isEqualToString:cid]) return;
            NSMutableArray *parts = [NSMutableArray array];
            if (current) [parts addObject:[NSString stringWithFormat:@"正在播出：%@", current]];
            if (next) [parts addObject:[NSString stringWithFormat:@"接下来：%@", next]];
            weakSelf.nowLabel.text = [parts componentsJoinedByString:@"    "];
        });
    }];
    [self.epgTask resume];
}

#pragma mark - 监视

- (void)startWatchdog {
    [self.watchdog invalidate];
    self.watchdogTicks = 0;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    self.watchdogTicks += 1;
    if (!self.currentPlayer) { [timer invalidate]; return; }
    [self attachPlayerViewAnimated:NO];
    double pos = 0;
    @try { pos = [[self.currentPlayer valueForKey:@"currentPosition"] doubleValue]; } @catch (NSException *e) {}
    if (self.firstRender) {
        [timer invalidate];          // 首帧后立即停止监视，减少主线程开销
        [self log:@"已渲染，监视结束 pos=%.1f", pos];
        return;
    }
    if (self.watchdogTicks > 30) {
        [timer invalidate];
        [self.spinner stopAnimating];
        if (!self.firstRender) {
            self.overlayTitle.text = [NSString stringWithFormat:@"%@ · 无画面", self.currentChannelName];
            [self log:@"监视结束仍未首帧"];
        }
    }
}

#pragma mark - 通用调用

- (id)callClass:(Class)cls selector:(SEL)sel args:(NSArray *)args {
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = cls; inv.selector = sel;
    [self fillInvocation:inv sig:sig args:args];
    @try { [inv invoke]; } @catch (NSException *e) { [self log:@"调用异常 %@: %@", NSStringFromSelector(sel), e.reason]; return nil; }
    const char *rt = sig.methodReturnType;
    if (rt[0] == '@') { void *p = NULL; [inv getReturnValue:&p]; return (__bridge id)p; }
    if (rt[0] == 'B' || rt[0] == 'c') { char r = 0; [inv getReturnValue:&r]; return @(r != 0); }
    return nil;
}

- (id)callInstance:(id)obj selector:(SEL)sel args:(NSArray *)args {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = obj; inv.selector = sel;
    [self fillInvocation:inv sig:sig args:args];
    @try { [inv invoke]; } @catch (NSException *e) { [self log:@"调用异常 %@: %@", NSStringFromSelector(sel), e.reason]; return nil; }
    const char *rt = sig.methodReturnType;
    if (rt[0] == '@') { void *p = NULL; [inv getReturnValue:&p]; return (__bridge id)p; }
    if (rt[0] == 'B' || rt[0] == 'c') { char r = 0; [inv getReturnValue:&r]; return @(r != 0); }
    return nil;
}

- (void)fillInvocation:(NSInvocation *)inv sig:(NSMethodSignature *)sig args:(NSArray *)args {
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        id v = args[i];
        if (v == NSNull.null) { id zero = nil; [inv setArgument:&zero atIndex:i + 2]; continue; }
        if (strcmp(t, "@") == 0 || strcmp(t, "@?") == 0) {
            id a = v; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "B") == 0 || strcmp(t, "c") == 0) {
            char a = [v boolValue]; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "q") == 0 || strcmp(t, "l") == 0) {
            long long a = [v longLongValue]; [inv setArgument:&a atIndex:i + 2];
        }
    }
}

#pragma mark - SDK 回调

- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {
    [self log:@"loadState=%lu", (unsigned long)state];
    [self attachPlayerViewAnimated:NO];
    if (state == 4) {
        [self callInstance:self.currentPlayer selector:NSSelectorFromString(@"play") args:@[]];
    }
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    [self log:@"VDN state=%lu", (unsigned long)state];
    if (state == 3) { self.overlayTitle.text = [NSString stringWithFormat:@"%@ · 已取流", self.currentChannelName]; }
    if (state == 2) { self.overlayTitle.text = [NSString stringWithFormat:@"%@ · 取流失败", self.currentChannelName]; }
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (event == 3) {
        self.firstRender = YES;
        [self.spinner stopAnimating];
        self.overlayTitle.text = [NSString stringWithFormat:@"%@", self.currentChannelName];
        [self log:@"首帧已渲染"];
    }
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    [self log:@"playback state=%lu", (unsigned long)state];
    if (state == 2) { [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal]; }
    if (state == 1) { [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal]; }
}

- (void)authFailed:(NSError *)error {
    [self log:@"authFailed code=%ld %@", (long)error.code, error.localizedDescription];
    self.overlayTitle.text = @"鉴权失败";
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    [self log:@"playbackFailed code=%ld %@", (long)error.code, error.localizedDescription];
    self.overlayTitle.text = [NSString stringWithFormat:@"%@ · 播放失败", self.currentChannelName];
    [self.spinner stopAnimating];
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    [self log:@"vdnRequestFailed code=%ld %@", (long)error.code, error.localizedDescription];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    [self log:@"parameterError code=%ld %@", (long)error.code, error.localizedDescription];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    [self log:@"publicRequestFailed code=%ld", (long)error.code];
}

@end
