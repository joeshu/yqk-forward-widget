# VOD CicadaPlayer 回退 · 集成补丁说明

> 给父 agent 合入用。审计修复专员已于 2026-11-05 ~23:06 完成 10 项修复，
> 本补丁只改 `cctv-ios-host/Sources/MediaPlaybackViewController.m` 一个文件，
> 其余文件（路由、适配器、测试）已就绪，不用再改。
> 行号为补丁编写时的当前值（审计修复后），合入时以**锚点代码文本**为准，
> 行号仅供定位参考。
> 构建系统自动收录新文件（`ci-build.sh` 用 `find Sources -maxdepth 1 -name '*.m'`；
> `ui-smoke.sh` 编译 `Sources/*.m`），无需改构建脚本。
> 新文件不引用任何 SDK 符号，ui-smoke 构建（不链接 CicadaPlayerSDK）不受影响。
> 2026-11-06 port 分支统一：VC 里的旧直连 CicadaPlayer 引擎（`playCicadaResult:` /
> `tearDownCicadaPlayer` 等）已删除，Cicada 播放只走适配器 + 路由；本文所述的
> 回退链与适配器接口不变，另见 `Tests/test_decode_router.py` 的统一路径断言。

## 0. 决策摘要

- 回退引擎选**直连 CicadaPlayer**（`Sources/MediaPlaybackCicadaAdapter.*`），不用
  CNPlayer 的 `playVODUrl:`。原因：CNPlayer 起播要走 VDN（一级 HLS/EPG），
  对第三方猫源 URL 的行为未验证，且其 configOptions 没有请求头/UA/Referer
  透传口（猫源常需 Referer 才能出流）；直连 CicadaPlayer 无 VDN 步骤，
  `CicadaConfig` 可直接带 `httpHeaders`/`userAgent`/`referer`。
- 路由集中在 `Sources/MediaPlaybackDecodeRouter.*`：
  `MediaPlaybackDecodeRouteNextForResult(result, attemptedRoutes)` 是唯一决策入口，
  返回下一个未尝试的路由（`AVPlayer` / `CicadaPlayer` / `WebView` / `None`），
  `attemptedRoutes` 位掩码防回退循环。
- 回退链：`AVPlayer → CicadaPlayer → WebView`，每路失败都有下一路。
  初始路由按格式/mime/扩展名定；运行时 AVPlayer 失败自动切 Cicada；
  Cicada 失败自动切 WebView；WebView 回原生（`tryNativePlayback`）时按
  attempted 掩码继续走下一路，不循环。

## 1. 导入（文件顶部，锚点：`#import "MediaPlaybackHeaders.h"`）

```objc
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackCicadaAdapter.h"
```

## 2. 类扩展：属性 + 代理 + 助手方法声明

锚点：`@interface MediaPlaybackViewController () <UIGestureRecognizerDelegate, AVPlayerViewControllerDelegate>`

- 协议列表追加 `MediaPlaybackCicadaAdapterDelegate`。
- 在 `@property(nonatomic) NSUInteger generation;` 附近追加：

```objc
@property(nonatomic,strong,nullable) MediaPlaybackCicadaAdapter *cicadaAdapter;
@property(nonatomic) NSUInteger attemptedRoutes; // 已尝试的路由位掩码，见路由头文件
@property(nonatomic) NSTimeInterval cicadaPosition;
@property(nonatomic) NSTimeInterval cicadaDuration;
```

- 在方法声明区（`recordPlaybackFailureForItem:` 声明附近，约 226 行）追加：

```objc
- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration;
- (void)teardownCicadaAdapter;
- (void)advanceFromCicadaFailureWithError:(NSError *)error;
- (void)handleCicadaFirstFrameTimeoutForAdapter:(id)adapter;
- (void)offerResumeForCicada;
- (void)applyPendingPlaybackSeekForCicada;
- (void)markCicadaFirstFrameReady;
- (BOOL)isCicadaEngineActive;
- (NSTimeInterval)activeEngineCurrentPosition;
- (NSTimeInterval)activeEngineDuration;
- (void)seekActiveEngineToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion;
- (void)setActiveEngineRate:(float)rate;
- (void)pauseActiveEngine;
- (void)playActiveEngine;
```

## 3. playResult: 路由接入（约 800–816 行）

### 3.1 头部拆解

锚点：

```objc
NSUInteger playerGeneration=++self.playerGeneration;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];
```

改为（追加一行拆解 Cicada 适配器；`attemptedRoutes` 不在这里复位，见 §13）：

```objc
NSUInteger playerGeneration=++self.playerGeneration;[self.player pause];self.playerController.player=nil;[self stopObservingCurrentPlayback];[self teardownCicadaAdapter];
```

### 3.2 路由决策替换

锚点（约 811–812 行）：

```objc
BOOL directMedia=MediaPlaybackResultSupportsAVPlayer(result)||MediaPlaybackResultSupportsAVPlayer(@{@"url":raw});
BOOL requiresWebPlayback=([result[@"requiresWebPlayback"] boolValue]||[result[@"parse"] integerValue]>0||[result[@"jx"] integerValue]>0)&&!directMedia;
```

保留这两行（WebView 分支仍用它们做条件），在其后追加：

```objc
MediaPlaybackDecodeRoute initialRoute=MediaPlaybackDecodeRouteNextForResult(result,self.attemptedRoutes);
```

锚点（`playback_owner_acquired` 事件，约 813 行）：

```objc
fields:@{@"owner":@"vod",@"engine":requiresWebPlayback?@"webview":@"avplayer",...
```

把 `engine` 值改为 `MediaPlaybackDecodeRouteName(initialRoute)`。

### 3.3 WebView 分支不动

锚点：`if(requiresWebPlayback && !directMedia){[self.spinner stopAnimating];self.status.text=@"正在打开来源网页播放器…";...`

保持原样。但注意：当 `initialRoute == MediaPlaybackDecodeRouteWebView`
且 `requiresWebPlayback` 为 NO 时（例如 AVI/WMV/RMVB，见路由表），
现有条件不会进 WebView 分支——因此在该 `if` 之前追加：

```objc
if(initialRoute==MediaPlaybackDecodeRouteWebView&&!requiresWebPlayback){[self openWebPlaybackFallback];return;}
```

（`openWebPlaybackFallback` 内部会处理 `awaitingWebPlaybackReturn` 与状态文案；
若希望 AVI 直接进 WebView 而不经过“正在尝试网页播放”中间态，可改为直接复用
该 `if` 块内的 WebView 创建代码，此处用现成方法是最少改动。）

### 3.4 Cicada 分支（插在 WebView 分支之后、AVPlayer 分支之前）

锚点：AVPlayer 分支起始行（约 816 行）：

```objc
NSMutableDictionary *handoffFields=[@{@"player":@"avplayer", ...
```

在其前插入：

```objc
if(initialRoute==MediaPlaybackDecodeRouteCicadaPlayer){[self startCicadaPlaybackWithResult:result url:url sourceURL:sourceURL playerGeneration:playerGeneration];return;}
if(initialRoute==MediaPlaybackDecodeRouteNone){[self.spinner stopAnimating];self.status.text=@"该资源没有可用的播放方式 · 可切换线路";self.status.accessibilityLabel=self.status.text;[self setRetryAvailable:YES];[self recordPlaybackAttemptOutcome:@"rejected" failureKind:@"no_playback_route" httpStatus:0 terminal:YES];return;}
```

（`None` 只在三路都试过时出现，正常流程几乎到不了；作为兜底不静默。）

## 4. 新方法：startCicadaPlaybackWithResult（加在 playResult: 之后任意位置）

```objc
- (void)startCicadaPlaybackWithResult:(NSDictionary *)result url:(NSURL *)url sourceURL:(NSURL *)sourceURL playerGeneration:(NSUInteger)playerGeneration {
    self.attemptedRoutes|=MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
    NSString *serviceID=[self.context[@"source"][@"id"] isKindOfClass:NSString.class]?self.context[@"source"][@"id"]:@"";
    NSMutableDictionary *handoffFields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(MediaPlaybackHeadersFromResult(result))];
    [handoffFields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(sourceURL)];
    [RuntimeDiagnostics.shared recordEvent:@"episode_player_handoff" category:@"playback" fields:handoffFields];
    self.hasDiagnosticTimeControlStatus=NO;self.playbackStartedAt=CACurrentMediaTime();
    self.status.text=@"正在使用 ffmpeg 内核载入媒体…";self.status.accessibilityLabel=self.status.text;
    [self.spinner startAnimating];[self setRetryAvailable:NO];
    NSTimeInterval timeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;
    NSDictionary *requestHeaders=self.basePlaybackHeaders?:MediaPlaybackHeadersFromResult(result);
    MediaPlaybackCicadaAdapter *adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:url headers:requestHeaders networkTimeout:timeout];
    adapter.delegate=self;self.cicadaAdapter=adapter;self.cicadaPosition=0;self.cicadaDuration=0;
    UIView *playerView=adapter.playerView;playerView.translatesAutoresizingMaskIntoConstraints=NO;
    [self.videoView addSubview:playerView];
    [NSLayoutConstraint activateConstraints:@[[playerView.leadingAnchor constraintEqualToAnchor:self.videoView.leadingAnchor],[playerView.trailingAnchor constraintEqualToAnchor:self.videoView.trailingAnchor],[playerView.topAnchor constraintEqualToAnchor:self.videoView.topAnchor],[playerView.bottomAnchor constraintEqualToAnchor:self.videoView.bottomAnchor]]];
    [self.playerController.view setHidden:YES];
    NSString *gravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    [adapter applyVideoGravity:gravity];
    [adapter prepare];
    if(!self.resumePromptPending&&!self.pendingPlaybackSeekTime)[adapter start];
    // 首帧看门狗（VC 侧后备；适配器内部另有 20 秒看门狗，二者走同一幂等回退）。
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaPlaybackViewController *owner=weakSelf;if(!owner||playerGeneration!=owner.playerGeneration||owner.cicadaAdapter!=adapter||owner.resumePromptPending||owner.pendingPlaybackSeekTime||owner.videoFrameReady)return;[owner handleCicadaFirstFrameTimeoutForAdapter:adapter];});
}
```

## 5. 适配器 Delegate 回调（新增一组方法，放 `playerItemEnded:` 附近）

```objc
#pragma mark - MediaPlaybackCicadaAdapterDelegate

- (void)cicadaAdapterDidPrepare:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    if(self.pendingPlaybackSeekTime)[self applyPendingPlaybackSeekForCicada];
    else if(self.resumePromptPending)[self offerResumeForCicada];
}

- (void)cicadaAdapterDidShowFirstFrame:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    [self markCicadaFirstFrameReady];
}

- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error {
    if(adapter!=self.cicadaAdapter)return;
    [self advanceFromCicadaFailureWithError:error];
}

- (void)cicadaAdapterDidComplete:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    NSTimeInterval position=self.cicadaPosition,duration=self.cicadaDuration;
    [MediaPlaybackStateStore recordContext:self.context?:@{} lineIndex:self.lineIndex episodeIndex:self.episodeIndex position:position duration:duration completed:YES];
    [self.spinner stopAnimating];[self recordPlaybackAttemptOutcome:@"completed" failureKind:nil httpStatus:0 terminal:YES];
    BOOL autoNext=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaAutoPlayNext"]?[NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaAutoPlayNext"]:YES;
    if(autoNext&&self.episodeIndex+1<self.episodes.count){NSInteger previousEpisode=self.episodeIndex;self.episodeIndex++;self.stallRecoveryAttempts=0;self.pendingResolutionReason=@"auto_advance";[self updateEpisodeTitle];self.status.text=@"本集已结束 · 正在加载下一集";self.status.accessibilityLabel=self.status.text;[RuntimeDiagnostics.shared recordEvent:@"playback_auto_advance" category:@"playback" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"line_index":@(self.lineIndex),@"from_episode_index":@(previousEpisode),@"to_episode_index":@(self.episodeIndex)}];[self resolveAndPlay];return;}
    self.status.text=@"播放完成";self.status.accessibilityLabel=self.status.text;
}

- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration {
    if(adapter!=self.cicadaAdapter)return;
    self.cicadaPosition=position;self.cicadaDuration=duration;
    if(position-self.lastPersistedPosition>=10.0)[self persistPlaybackProgress];
    [self updateSkipButtonForCurrentPosition];
}

- (void)cicadaAdapter:(id)adapter didUpdateLoading:(BOOL)loading progress:(float)progress {
    if(adapter!=self.cicadaAdapter)return;
    if(loading){self.status.text=@"正在缓冲 · 等待 CicadaPlayer";self.status.accessibilityLabel=self.status.text;[self.spinner startAnimating];}
    else if(self.videoFrameReady){self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;[self.spinner stopAnimating];}
}

- (void)cicadaAdapterDidSeek:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    [self updateSkipButtonForCurrentPosition];
}
```

## 6. 引擎助手方法（新增，放 `startCicadaPlaybackWithResult:` 附近）

```objc
- (BOOL)isCicadaEngineActive { return self.cicadaAdapter!=nil; }

- (NSTimeInterval)activeEngineCurrentPosition {
    if(self.cicadaAdapter)return self.cicadaAdapter.currentPosition;
    return CMTimeGetSeconds(self.player.currentTime);
}

- (NSTimeInterval)activeEngineDuration {
    if(self.cicadaAdapter)return self.cicadaAdapter.duration;
    return CMTimeGetSeconds(self.observedItem.duration);
}

- (void)seekActiveEngineToTime:(NSTimeInterval)time completion:(nullable void (^)(BOOL finished))completion {
    if(self.cicadaAdapter){[self.cicadaAdapter seekToTime:time completion:completion];return;}
    [self.player seekToTime:CMTimeMakeWithSeconds(time,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completion];
}

- (void)setActiveEngineRate:(float)rate {
    if(self.cicadaAdapter){[self.cicadaAdapter setRate:rate];return;}
    self.player.defaultRate=rate;
}

- (void)pauseActiveEngine {
    if(self.cicadaAdapter){[self.cicadaAdapter pause];return;}
    [self.player pause];
}

- (void)playActiveEngine {
    if(self.cicadaAdapter){[self.cicadaAdapter start];return;}
    [self.player play];
}

- (void)teardownCicadaAdapter {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;self.cicadaAdapter=nil;
    if(!adapter)return;
    [adapter.playerView removeFromSuperview];
    [adapter destroy];
    [self.playerController.view setHidden:NO];
}

- (void)markCicadaFirstFrameReady {
    if(self.videoFrameReady)return;
    self.videoFrameReady=YES;self.hasVideoTrack=self.cicadaAdapter.hasVideoTrack;
    [self.spinner stopAnimating];
    self.status.text=@"视频首帧已就绪 · CicadaPlayer 正在播放";self.status.accessibilityLabel=self.status.text;
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"elapsed_ms":@(MAX(0,(NSInteger)((CACurrentMediaTime()-self.playbackStartedAt)*1000))), @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"media_first_frame_ready" category:@"playback" fields:fields];
}
```

## 7. 运行时失败自动回退

### 7.1 AVPlayer 失败 → 下一路

锚点：`recordPlaybackFailureForItem:` 实现（约 859 行）。在其现有失败上报
（`recordPlaybackAttemptOutcome:@"failed"...`）之前插入：

```objc
MediaPlaybackDecodeRoute nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
if(nextRoute==MediaPlaybackDecodeRouteCicadaPlayer){
    // 新尝试：清掉本次失败标记，让 Cicada 路径有自己的失败上报。
    self.playbackFailureRecorded=NO;self.terminalPlaybackOutcomeRecorded=NO;
    self.resumePromptPending=NO;self.pendingPlaybackSeekTime=nil;
    NSURL *fallbackURL=[NSURL URLWithString:[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:@""];
    [self startCicadaPlaybackWithResult:self.result url:fallbackURL sourceURL:MediaPlaybackOriginalSourceURL(self.result) playerGeneration:self.playerGeneration];
    return;
}
if(nextRoute==MediaPlaybackDecodeRouteWebView){[self openWebPlaybackFallback];return;}
```

注意：`recordPlaybackFailureForItem:` 开头的 `playbackFailureRecorded`  early-return
守卫仍在；回退分支在守卫之后、上报之前插入，上报仍只对最终失败执行一次。

### 7.2 Cicada 失败 → 下一路（幂等）

```objc
- (void)advanceFromCicadaFailureWithError:(NSError *)error {
    MediaPlaybackCicadaAdapter *adapter=self.cicadaAdapter;
    if(!adapter)return; // 已回退过或已拆解：幂等，不重复推进
    [self teardownCicadaAdapter];
    NSMutableDictionary *fields=[@{@"player":@"cicada", @"playback_attempt_id":self.playbackAttemptID?:@"", @"failure_kind":@"cicada_playback_failed", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"line_index":@(self.lineIndex), @"episode_index":@(self.episodeIndex), @"correlation_id":self.diagnosticTraceID?:@""} mutableCopy];
    [fields addEntriesFromDictionary:MediaPlaybackDiagnosticSourceFields(MediaPlaybackOriginalSourceURL(self.result))];
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:fields];
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:@"cicada_playback_failed" httpStatus:0 terminal:NO];
    MediaPlaybackDecodeRoute nextRoute=MediaPlaybackDecodeRouteNextForResult(self.result,self.attemptedRoutes);
    if(nextRoute==MediaPlaybackDecodeRouteWebView){[self openWebPlaybackFallback];return;}
    // 无下一路：显示失败（与 AVPlayer 最终失败同一文案风格）。
    [self.spinner stopAnimating];
    self.status.text=@"ffmpeg 内核也无法播放此资源 · 可重试或切换线路";self.status.accessibilityLabel=self.status.text;
    [self setRetryAvailable:YES];
    [self recordPlaybackAttemptOutcome:@"failed" failureKind:@"cicada_playback_failed" httpStatus:0 terminal:YES];
}

- (void)handleCicadaFirstFrameTimeoutForAdapter:(id)adapter {
    if(adapter!=self.cicadaAdapter)return;
    NSError *error=[NSError errorWithDomain:MediaPlaybackCicadaAdapterErrorDomain code:-1001 userInfo:@{NSLocalizedDescriptionKey:@"CicadaPlayer 20 秒内未显示首帧"}];
    [self advanceFromCicadaFailureWithError:error];
}
```

（适配器内部 20 秒看门狗也会经 `didFailWithError:` 走到同一方法；
先到者把 `cicadaAdapter` 置 nil，后到者因 `adapter != self.cicadaAdapter`
直接返回，不会重复推进。）

## 8. 控制点泛化清单（逐处改 `self.player` 直引）

以下每处只改本行，其余不动。`player` 本身保留（AVPlayer 路径仍用它）。

| 位置（行号约值） | 锚点 | 改法 |
|---|---|---|
| 412 双击 ±10 秒 | `[self.player seekToTime:CMTimeMakeWithSeconds(target,600) toleranceBefore:CMTimeMake(1,10) toleranceAfter:CMTimeMake(1,10)];` | 改为 `[self seekActiveEngineToTime:target completion:nil];` |
| 476 拖动 seek | `[self.player seekToTime:CMTimeMakeWithSeconds(self.panTargetTime,600) toleranceBefore:CMTimeMake(2,10) toleranceAfter:CMTimeMake(2,10)];` | 改为 `[self seekActiveEngineToTime:self.panTargetTime completion:nil];` |
| 611 “从头播放” | `[owner.player seekToTime:kCMTimeZero ... completionHandler:^(BOOL finished){... [owner.player play];` | seek 改为 `[owner seekActiveEngineToTime:0 completion:^(BOOL finished){...}]`；`owner.player.defaultRate=...` 改为 `[owner setActiveEngineRate:...]`；`[owner.player play]` 改为 `[owner playActiveEngine]`；守卫 `item!=owner.player.currentItem` 改为 `owner.cicadaAdapter==nil && item!=owner.player.currentItem`（Cicada 路径无 item，用适配器存在性判断） |
| 612 “继续观看” | 同 611，`CMTime target=...` 那行 | 同上，seek 目标改为 `MAX(0,position)` |
| 615–618 `applyPendingPlaybackSeekForItem:` | `[self.player seekToTime:CMTimeMakeWithSeconds(position,600) ...` 与块内的 `owner.player.defaultRate=...`、`[owner.player play]` / `[owner.player pause]` | seek 改为 `[self seekActiveEngineToTime:position completion:...]`；defaultRate 改为 `[owner setActiveEngineRate:...]`；play/pause 改为 `[owner playActiveEngine]` / `[owner pauseActiveEngine]` |
| 696 画质切换 | `NSTimeInterval current=CMTimeGetSeconds(self.player.currentTime);` 与 `self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying` | 改为 `[self activeEngineCurrentPosition]`；playing 判断改为 `([self isCicadaEngineActive] ? self.cicadaAdapter.state==MediaPlaybackCicadaAdapterStatePlaying : self.player.timeControlStatus==AVPlayerTimeControlStatusPlaying)` |
| 723 倍速菜单 | `self.player.defaultRate=(float)rate;` | 改为 `[self setActiveEngineRate:(float)rate];`（前面的 defaults 写入不动） |
| 729 画面比例菜单 | `self.playerController.videoGravity=gravity;` | 追加一行 `[self.cicadaAdapter applyVideoGravity:gravity];`（适配器为 nil 时是空操作） |
| 771–772 `performSkipAction` | `[self.player seekToTime:CMTimeMakeWithSeconds(target,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];` | 改为 `[self seekActiveEngineToTime:target completion:nil];` |
| 835/847 `openWebPlaybackFallback` / `openEpisodePageWebFallback` | `[self.player pause];` | 改为 `[self pauseActiveEngine];`（同时把当前引擎进度先持久化——`persistPlaybackProgress` 已泛化，见 §9） |
| 800 `playResult:` 头部 | 见 §3.1 | 追加 `[self teardownCicadaAdapter];` |
| 831 AVPlayer 20 秒看门狗 | `dispatch_after(...20*NSEC_PER_SEC...` 块 | 不动：守卫里的 `item!=owner.player.currentItem` 在 Cicada 路径下恒为真（无 currentItem），天然不触发；Cicada 路径的首帧超时由适配器内部看门狗 + §4 的 dispatch_after 覆盖 |

## 9. 持久化与跳过按钮泛化

### 9.1 persistPlaybackProgress（约 599 行）

锚点：

```objc
- (void)persistPlaybackProgress {
    AVPlayerItem *item=self.observedItem;if(!item||item!=self.player.currentItem||!self.context)return;
    NSTimeInterval position=CMTimeGetSeconds(self.player.currentTime),duration=CMTimeGetSeconds(item.duration);if(!isfinite(position)||position<0)return;if(!isfinite(duration)||duration<0)duration=0;
```

改为：

```objc
- (void)persistPlaybackProgress {
    if(!self.context)return;
    NSTimeInterval position,duration;
    if(self.cicadaAdapter){position=self.cicadaAdapter.currentPosition;duration=self.cicadaAdapter.duration;}
    else{AVPlayerItem *item=self.observedItem;if(!item||item!=self.player.currentItem)return;position=CMTimeGetSeconds(self.player.currentTime);duration=CMTimeGetSeconds(item.duration);}
    if(!isfinite(position)||position<0)return;if(!isfinite(duration)||duration<0)duration=0;
```

（其余 `recordContext:...` 与 `lastPersistedPosition` 不动。）

### 9.2 updateSkipButtonForCurrentPosition（约 758 行）

锚点：

```objc
- (void)updateSkipButtonForCurrentPosition {
    if(!self.skipButton||!self.observedItem||self.observedItem!=self.player.currentItem){self.skipButton.hidden=YES;return;}
    NSTimeInterval position=CMTimeGetSeconds(self.player.currentTime),duration=CMTimeGetSeconds(self.player.currentItem.duration);if(!isfinite(position)||position<0){self.skipButton.hidden=YES;return;}
```

改为：

```objc
- (void)updateSkipButtonForCurrentPosition {
    if(!self.skipButton){self.skipButton.hidden=YES;return;}
    if(!self.cicadaAdapter&&(!self.observedItem||self.observedItem!=self.player.currentItem)){self.skipButton.hidden=YES;return;}
    NSTimeInterval position=[self activeEngineCurrentPosition],duration=[self activeEngineDuration];if(!isfinite(position)||position<0){self.skipButton.hidden=YES;return;}
```

（其余片头/片尾判断不动；Cicada 路径的位置由适配器 1 秒轮询驱动，
`didUpdatePosition:` 里已调本方法。）

## 10. 拆解点

- `playResult:` 头部：见 §3.1（`teardownCicadaAdapter`）。
- `viewDidDisappear:`（约 497 行）与 `dealloc`（约 563 行）：
  各追加一行 `[self teardownCicadaAdapter];`
  （`teardownCicadaAdapter` 内部判空，重复调无害；`destroy` 会先摘 delegate
  再 stop/destroy，避免拆解回调。）
- `stopObservingCurrentPlayback`（约 573 行）：不动——AVPlayer 观测的拆解
  与 Cicada 适配器无关，适配器生命周期由 `teardownCicadaAdapter` 单独管。

## 11. tryNativePlayback 调整（约 907–911 行）

锚点：

```objc
NSMutableDictionary *candidate=[self.result mutableCopy];candidate[@"parse"]=@0;candidate[@"jx"]=@0;candidate[@"requiresWebPlayback"]=@NO;candidate[@"playbackMethodOverride"]=@\"avplayer\";
```

- `candidate[@"playbackMethodOverride"]=@\"avplayer\"` 删除（该键全仓库无读取处，
  是死数据；删掉后路由按格式决定，不会把 FLV 再推回注定失败的 AVPlayer）。
- `self.awaitingWebPlaybackReturn=NO;[self playResult:candidate];` 不动；
  `attemptedRoutes` 在此处**不要**复位（WebView 已试过，掩码保证不循环）。

## 12. attemptedRoutes 复位点

`attemptedRoutes` 是一次解析的回退链状态，新解析开始时清零：

- `resolveAndPlay`（约 540 行，方法头）追加 `self.attemptedRoutes=0;`
- 画质切换回调（约 697 行，`playback_quality_selected` 事件附近，
  `[self playResult:selected];` 之前）追加 `self.attemptedRoutes=0;`
- 分集选择回调（约 797 行，`page.onSelectEpisode` 块内，
  `[owner buildLines];` 之前）追加 `owner.attemptedRoutes=0;`

其余直接调 `playResult:` 的地方（重试走 `resolveAndPlay`；`tryNativePlayback`
见 §11；WebView 的 `onResolvedMedia` 是新解析结果，走 `resolveAndPlay`
链路或直接 `playResult:`——若直接 `playResult:`，因 `self.result` 的 URL
已变，需在 §3.1 的头部按 URL 变化复位：如 `self.result` 的 URL 与新结果
URL 不同则 `self.attemptedRoutes=0;`。为稳妥起见，建议在 §3.1 头部追加
该 URL 变化判断，而不只依赖上面三处。）

## 13. 续播提示（offerResumeForItem:）的 Cicada 版

`offerResumeForItem:`（约 606 行）本身不动（AVPlayer 用）。
新增 `offerResumeForCicada`（放其后，照抄其结构，只做三处替换）：
`item` 守卫改为 `adapter != self.cicadaAdapter`；
seek 用 `[self seekActiveEngineToTime:...]`；
`defaultRate` / `play` 用 `[self setActiveEngineRate:...]` /
`[self playActiveEngine]`。
`applyPendingPlaybackSeekForCicada` 同理照抄 `applyPendingPlaybackSeekForItem:`
（约 615 行），seek/rate/play/pause 四处换成引擎助手方法。

## 14. 验证清单

- 静态：`git diff --check`；新文件括号平衡；`Tests/test_decode_router.py`
  全过；全量回归对照基线 **447 项 / 0 失败 / 46 跳过**
  （审计修复后基线，2026-11-05 ~23:06 父 agent 实测）。
- CI：`build (full)` 必须绿（新文件随 `find Sources` 自动编译；
  适配器无 SDK 链接依赖，`ui-preview` 不受影响——SmokeDriver 不走 VOD）。
- 真机（本机无 Xcode、无真机，以下均未验证，合入后必须在 iPhone 上确认）：
  1. 虎牙/斗鱼 FLV 直播流出画面、首帧 ≤20 秒；斗鱼/虎牙切换线路后回退链正常。
  2. 哔哩影视 DASH/MPD 出画面（MPD 解析在 Cicada 层，需确认）。
  3. MKV（H.264/H.265）出画面；3GP（MPEG-4）出画面；RTMP（如有）出画面。
  4. Cicada 路径下：暂停/继续、±10 秒、拖动 seek、倍速 0.5–2.0、续播提示、
     自动跳过片头、进度持久化与恢复、下一集自动连播，均与 AVPlayer 路径一致。
  5. 失败链：AVPlayer 失败自动切 Cicada；Cicada 失败自动切 WebView；
     三路都失败显示失败文案，不黑屏、不循环。
  6. `scalingMode` 映射（0=AspectFit、1=AspectFill）与 `seekMode:0` 的实际效果。
  7. 无扩展名地址（豆儿·瓜子）AVPlayer 失败后自动试 Cicada。
  8. `duration` / `currentPosition` 单位（秒 vs 毫秒）是否与归一化假设一致。

## 15. 回滚

- 只想关掉 Cicada 回退：`MediaPlaybackDecodeRouter.m` 的
  `MediaPlaybackResultSupportsCicadaPlayer` 首行加 `return NO;` 即可，
  路由退回 AVPlayer → WebView，适配器永不实例化。
- 彻底移除：删 4 个新文件 + 恢复本补丁对 `MediaPlaybackViewController.m`
  的修改（git checkout 该文件即可，因本补丁是该文件唯一的新增改动——
  注意先确认审计修复的改动已入库，别误删）。
