# 回看 / 时移集成补丁（CCTVTimeshiftController 接入）

> 状态：新文件已就位（`Sources/CCTVTimeshiftController.h/.m`、会话代理已转发
> `programPubicChanged` 与 `playerPeriodicTimeEvent`），本文件只写宿主
> `RootViewController.m` 需要改的 6 处。审计修复专员已完工，合入前请先
> `git diff --check` 并跑全量回归（基线 461 项 / 0 失败 / 46 跳过）。
>
> 约定：行号以 cdeeafff 为准；`nativeTimeshift` 仍保留作会话底层，
> 控制器内部自建会话，宿主不再直接调它。

## 0. 前置：属性与 import

位置：`RootViewController.m` 顶部 import 区、`@interface` 私有属性区。

```objc
#import "CCTVTimeshiftController.h"
@property (nonatomic, strong) CCTVTimeshiftController *timeshiftController;
```

说明：控制器与播放器实例绑定；每次起播换播放器后需重建（见第 1 步）。

## 1. 起播时重建控制器（`playViaSDK:` 与 `playViaSDKURL:`，各 1 行）

在两处 `self.currentPlayer = <新播放器实例>` 赋值之后、`prepareToPlay` 之前各加：

```objc
self.timeshiftController = [[CCTVTimeshiftController alloc] initWithPlayer:self.currentPlayer];
self.timeshiftController.onFailure = ^(NSError *error) {
    // 回看中版权丢失 / seek 失败：提示并提供返回直播（复用现有失败 UI）。
    [self displayNativePlaybackFailure:@"时移 / 回看失败" error:error];
};
self.timeshiftController.onReturnToLiveFallback = ^{
    // SDK 不支持 backToLive：整台重播（重新起播，不经过时移接口）。
    [self playSelectedNativeRouteOrChannel];
};
self.timeshiftController.onProgress = ^(NSTimeInterval behindLive, NSTimeInterval position) {
    // 回看中距直播指示：复用 infoLabel，首帧后保持可见（见第 5 步）。
    self.infoLabel.hidden = NO;
    self.infoLabel.text = [NSString stringWithFormat:@"回看中 · 距直播 %.0f 分钟", behindLive / 60.0];
};
```

为什么：控制器与播放器一一对应；旧播放器的控制器必须丢弃，否则代际守卫外的
回调可能串台。`onFailure`/`onReturnToLiveFallback`/`onProgress` 三处回调覆盖
失败、回退、进度三种宿主动作。

## 2. `seekNativeStart:end:` 改走控制器（约 RootViewController.m:3737）

原逻辑（直接建 `NativeTimeshiftSession`、调 `seekStart:`、失败调
`failNativeTransition:`）替换为：

```objc
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    if (!self.currentPlayer || self.avPlayer || !self.firstRender) {
        [self showServiceError:@"请等待 CCTV 原生频道起播完成后再操作。"]; return;
    }
    if (!self.timeshiftController)
        self.timeshiftController = [[CCTVTimeshiftController alloc] initWithPlayer:self.currentPlayer];
    [self beginNativeTransition:end == 0 ? @"时移" : @"回看"];
    self.nativeTimeShiftActive = YES;
    NSUInteger generation = self.playbackGeneration;
    __weak id player = self.currentPlayer;
    __weak typeof(self) weakSelf = self;
    [self.timeshiftController requestSeekToStart:start end:end channelID:self.channelID completion:^(BOOL ok, NSError *error) {
        if (generation != weakSelf.playbackGeneration || player != weakSelf.currentPlayer) return;
        if (!ok || error) {
            [weakSelf failNativeTransition:error.localizedDescription.length
                ? error.localizedDescription
                : @"频道未允许该时间的时移/回看，请返回直播或重新选台。"];
        } else {
            [weakSelf log:@"原生时移请求已完成，等待/确认首帧"];
        }
    }];
}
```

为什么：防抖（0.3 秒合并连续点按）、版权预检（无版权直接失败，不等 10 秒超时）、
瞬时失败重试一次（同实例，不重建播放器、不重新请求 VDN）都在控制器里；
宿主只保留原有的过渡 UI（`beginNativeTransition`）与失败 UI。

## 3. `returnToNativeLive` 改走控制器（约 RootViewController.m:3755）

```objc
- (void)returnToNativeLive {
    if (!self.currentPlayer || self.avPlayer) return;
    if (!self.timeshiftController)
        self.timeshiftController = [[CCTVTimeshiftController alloc] initWithPlayer:self.currentPlayer];
    [self beginNativeTransition:@"返回直播"];
    self.nativeTimeShiftActive = NO;
    [self.timeshiftController returnToLive];
}
```

为什么：`backToLive` 不可用时控制器走 `onReturnToLiveFallback`（第 1 步已接整台重播），
不再只显示“请重新选台”；成功返回后首帧处调 `noteReturnedToLive`（见第 5 步）。

## 4. SDK 回调转发（`loadStateDidChanged:` 与 `statEvent:` 内各加 1 行）

`player:loadStateDidChanged:` 的主线程分支内、`if (player != self.currentPlayer) return;` 之后加：

```objc
[self.timeshiftController noteLoadState:state];
```

`player:statEvent:` 同位置加：

```objc
[self.timeshiftController noteStatEvent:event];
```

为什么：SeekSucceed（5）/ Stalled（11）/ StalledRecovery（12）/ Cancelled（13）与
VODSeekStart（11）/ VODSeekCompletion（12）/ FirstRenderDidStart（3）此前无人处理；
控制器据此记录 seek 耗时、首帧耗时、回看中卡顿次数，并在 seek 完成时转态
`PlayingReplay`。转发本身无副作用（控制器内部按状态过滤）。

## 5. 版权变动、周期事件、返回直播确认、首帧后状态同步

新增三个方法（放在 SDK 回调区，与其它 `player:` 回调并列）：

```objc
- (void)player:(id)player programPubicChanged:(BOOL)isPublic {
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteCopyrightChanged:isPublic error:nil];
}

- (void)player:(id)player programPubicChanged:(BOOL)isPublic type:(NSUInteger)sourceType error:(NSError *)error {
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteCopyrightChanged:isPublic error:error];
}

- (void)playerPeriodicTimeEvent:(id)player {
    if (player != self.currentPlayer) return;
    [self.timeshiftController notePeriodicTick];
}
```

首帧回调 `statEvent == 3` 的分支内、`self.firstRender = YES;` 之后加：

```objc
if (!self.nativeTimeShiftActive) [self.timeshiftController noteReturnedToLive];
```

为什么：`programPubicChanged:` 覆盖播放中版权变动（手册 §4.7），回看中版权丢失时
控制器失败并通知宿主；`playerPeriodicTimeEvent:` 每秒驱动距直播指示（手册 §4.9）；
首帧处确认返回直播完成（控制器回 `Idle`）。`noteReturnedToLive` 只在非时移态调用，
避免回看首帧误清状态。

另：首帧分支目前会 `self.infoLabel.hidden = YES`；回看中需保留距直播指示，改为：

```objc
if (!self.nativeTimeShiftActive) { self.titleLabel.hidden = YES; self.infoLabel.hidden = YES; }
```

## 6. SDK 版权自动校验（三件套，缺一不可——需央视提供地址）

手册 §4.8：时移/回看、返回直播、返回前台、起播时，若配齐
`CNPlayerConfigOptionKey_LivePublicCheck_ONOFF=YES` +
`CNPlayerConfigOptionKey_TimeshiftingChannelID` +
`configSDK_VDN_LiveTSPublicUrl`（版权校验地址），SDK 自动做版权校验，
失败走 `publicRequestFailed:`（已接线）。

现状：三件套均未配置；`configSDK_VDN_LiveTSPublicUrl` 的真实地址仓库里没有，
手册也不给。**不要只开前两个开关**——缺地址时校验不生效，开了等于没开。

合入步骤（拿到地址后）：

1. `setupSDK` 内、`configSDK_CICADA_UDRMUrl:` 调用旁加：
   ```objc
   [self callClass:cls sel:@"configSDK_VDN_LiveTSPublicUrl:" args:@[<真实地址>]];
   ```
2. `playViaSDK:` 的 `options` 改为：
   ```objc
   NSDictionary *options = @{
       kOptTitle: title ?: cid,
       CCTVTimeshiftConfigKeyLivePublicCheck: @YES,
       CCTVTimeshiftConfigKeyTimeshiftingChannelID: cid,
   };
   ```
   （`playViaSDKURL:` 的 options 同理加两项，channelID 用 `cid`。）
3. 回归时确认：无版权时段起播/时移走 `publicRequestFailed:`，提示为“版权请求失败”
   而不是静默失败；有版权时段不受影响。

在地址到位前，控制器主动调 `checkPublicPlaytime` 的预检是唯一生效的版权关口，
不要绕过它。

## 验证清单

- [ ] `git diff --check` 通过；新文件括号平衡。
- [ ] 全量 Python 回归：基线 461 项 / 0 失败 / 46 跳过（新增 12 项合同测试 + 1 项 macOS 原生测试计入）。
- [ ] macOS 下跑 `Tests/test_native_timeshift_controller.py`（需 Xcode 命令行工具）。
- [ ] 真机验证（本机无 Xcode，无法验证）：EPG 点已播节目回看、回退 1/5/30 分钟、
      返回直播、连续点按防抖、无版权节目快速失败、回看中版权变动、seek 耗时与
      首帧耗时、距直播指示刷新。
