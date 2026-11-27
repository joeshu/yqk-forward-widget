// MediaPlaybackSettingsCoordinator.m
//
// 播放设置菜单协调器实现（阶段 B-P1）。逻辑逐行自 MediaPlaybackViewController 迁出，
// 仅把对宿主状态/控件的访问改为经 self.owner；引擎作用类操作经 owner 回调以保持
// 状态机/路由层不被触碰。accessibilityIdentifier 与菜单 identifier 全部保留。
// 为保持与既有源码契约测试一致，菜单构建体沿用原始紧凑写法（if(!x)return nil;）。
#import "MediaPlaybackSettingsCoordinator.h"
#import "MediaPlaybackViewController.h"
#import "MediaPlaybackCicadaAdapter.h"
#import "MediaPlaybackMPVAdapter.h"
#import "CCTVPlaybackEngineProtocol.h"
#import "RuntimeDiagnostics.h"
#import "MediaPlaybackStateStore.h"
#import <AVKit/AVKit.h>

@interface MediaPlaybackSettingsCoordinator ()
@end

@implementation MediaPlaybackSettingsCoordinator

- (instancetype)initWithOwner:(id<MediaPlaybackSettingsCoordinatorOwner>)owner {
    if ((self=[super init])){_owner=owner;} return self;
}

- (void)refreshMenus {
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    if(!owner)return;
    owner.playbackOptionsItem.menu=[self playbackOptionsMenu];
}

#pragma mark - 睡眠定时

- (void)invalidateSleepTimer {
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;self.mediaSleepMinutes=0;
}

- (void)configureMediaSleepTimerMinutes:(NSInteger)minutes {
    [self.mediaSleepTimer invalidate];self.mediaSleepTimer=nil;self.mediaSleepMinutes=minutes;
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    if(minutes<=0){[owner showGestureFeedback:@"已关闭睡眠定时"];[self refreshMenus];return;}
    __weak typeof(self) weakSelf=self;
    self.mediaSleepTimer=[NSTimer timerWithTimeInterval:minutes*60.0 repeats:NO block:^(__unused NSTimer *t){
        MediaPlaybackSettingsCoordinator *coordinator=weakSelf;if(!coordinator)return;
        id<MediaPlaybackSettingsCoordinatorOwner> host=coordinator.owner;if(!host)return;
        coordinator.mediaSleepTimer=nil;coordinator.mediaSleepMinutes=0;
        [host pauseActiveEngine];host.status.text=@"已按睡眠定时自动暂停播放";[host showGestureFeedback:@"睡眠定时已到 · 已暂停"];
        [coordinator refreshMenus];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.mediaSleepTimer forMode:NSRunLoopCommonModes];
    [owner showGestureFeedback:[NSString stringWithFormat:@"%ld 分钟后自动暂停",(long)minutes]];
    [self refreshMenus];
}

- (UIMenu *)playbackSleepTimerMenu {
    __weak typeof(self) weakSelf=self;NSMutableArray *items=[NSMutableArray array];
    for(NSNumber *candidate in @[@0,@15,@30,@60]){
        NSInteger mins=candidate.integerValue;NSString *title=mins==0?@"关闭定时":[NSString stringWithFormat:@"%ld 分钟后暂停",(long)mins];
        UIAction *act=[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner configureMediaSleepTimerMinutes:mins];}];
        act.state=(self.mediaSleepMinutes==mins)?UIMenuElementStateOn:UIMenuElementStateOff;
        [items addObject:act];
    }
    UIMenu *menu=[UIMenu menuWithTitle:@"睡眠定时" image:[UIImage systemImageNamed:@"moon.zzz"] identifier:nil options:0 children:items];
    if(@available(iOS 16.0,*)){
        menu.subtitle=self.mediaSleepMinutes>0?[NSString stringWithFormat:@"%ld 分钟后暂停",(long)self.mediaSleepMinutes]:@"已关闭";
    }
    return menu;
}

#pragma mark - 轨道选择（音轨 / 字幕）

// T09：菜单会话守卫——菜单构建时抓取会话快照，点选时校验；会话已变
// （换集/换线/换引擎/换 item）则拒绝过期动作并刷新菜单。
- (BOOL)menuSessionChangedSinceAdapter:(nullable id)builtAdapter item:(nullable AVPlayerItem *)builtItem episode:(NSInteger)builtEpisode line:(NSInteger)builtLine {
    id<MediaPlaybackSettingsCoordinatorOwner> host=self.owner;
    if(!host)return YES;
    if(host.episodeIndex!=builtEpisode||host.lineIndex!=builtLine)return YES;
    if(builtAdapter&&host.cicadaAdapter!=(id)builtAdapter)return YES;
    if(builtItem&&host.player.currentItem!=builtItem)return YES;
    return NO;
}

- (void)refuseStaleMenuAction {
    id<MediaPlaybackSettingsCoordinatorOwner> host=self.owner;
    if(!host)return;
    host.status.text=@"已切换剧集或线路，菜单已过期";
    [self refreshMenus];
}

// T09：切换验证——重查轨道列表确认目标轨道当前已选中（MPV 的 selected
// 是引擎同步值）；Cicada 不暴露选中状态时一律返回 NO（未确认）。
- (BOOL)verifyTrackSelectionForAdapter:(id<CCTVPlaybackEngine>)adapter index:(NSInteger)index kind:(NSString *)kind {
    if(![adapter respondsToSelector:@selector(availableTracks)])return NO;
    for(NSDictionary *track in [adapter availableTracks]){
        if(![track[@"type"] isEqual:kind])continue;
        if([track[@"index"] integerValue]!=index)continue;
        return [track[@"selected"] isEqual:@(YES)];
    }
    return NO;
}

- (BOOL)verifyTrackOffForAdapter:(id<CCTVPlaybackEngine>)adapter kind:(NSString *)kind {
    if(![adapter respondsToSelector:@selector(availableTracks)])return NO;
    for(NSDictionary *track in [adapter availableTracks]){
        if(![track[@"type"] isEqual:kind])continue;
        if([track[@"selected"] isEqual:@(YES)])return NO;
    }
    return YES;
}

// 字幕/音轨子菜单：优先用宿主提供的版本（1.67 契约，宿主经通用轨道构建器生成），
// 宿主未提供（无轨道返回 nil）时直接用通用轨道构建器再建一次。
- (nullable UIMenu *)subtitleSelectionMenu {UIMenu *menu=[self.owner subtitleSelectionMenu];return menu?:[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicLegible title:@"字幕"];}
- (nullable UIMenu *)audioSelectionMenu {UIMenu *menu=[self.owner audioSelectionMenu];return menu?:[self mediaSelectionMenuForCharacteristic:AVMediaCharacteristicAudible title:@"音轨"];}

- (nullable UIMenu *)mediaSelectionMenuForCharacteristic:(AVMediaCharacteristic)characteristic title:(NSString *)title {
    BOOL isAudio=[characteristic isEqual:AVMediaCharacteristicAudible];
    UIImage *icon=[UIImage systemImageNamed:isAudio?@"waveform":@"captions.bubble"];
    NSString *kind=isAudio?@"audio":@"subtitle";__weak typeof(self) weakSelf=self;
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    if(!owner)return nil;
    // 协议将 availableTracks / canSelectTracks / selectTrackWithIndex: 标记为 @optional；
    // 经 respondsToSelector 安全调用，引擎未实现或无轨道时不显示该子菜单（P5 契约）。
    id<CCTVPlaybackEngine> adapter=(id<CCTVPlaybackEngine>)owner.cicadaAdapter;
    if(adapter){
        if(![adapter respondsToSelector:@selector(availableTracks)])return nil;
        BOOL canSelect=[adapter respondsToSelector:@selector(canSelectTracks)]&&[adapter canSelectTracks];
        if(!canSelect)return nil;
        // T09：抓取菜单构建时的会话快照；点选时校验，换集/换线/换引擎后
        // 拒绝过期动作（旧 index 不得作用于新 adapter），并刷新菜单。
        id<CCTVPlaybackEngine> builtAdapter=adapter;
        NSInteger builtEpisode=owner.episodeIndex;
        NSInteger builtLine=owner.lineIndex;
        NSArray<NSDictionary *> *tracks=[adapter availableTracks];
        // T09：当前选中只认引擎真实上报的 selected=YES（MPV）；全部是
        // @"unknown"（Cicada）时选中状态未知，不标当前、不提供关闭项。
        BOOL selectionKnown=NO;NSString *currentName=nil;NSUInteger kindTrackCount=0;
        for(NSDictionary *t in tracks){
            if(![t[@"type"] isEqual:kind])continue;
            kindTrackCount++;
            if([t[@"selected"] isKindOfClass:NSNumber.class]){selectionKnown=YES;if([t[@"selected"] boolValue])currentName=[t[@"name"] isKindOfClass:NSString.class]?t[@"name"]:[NSString stringWithFormat:@"%@ %ld",kind,(long)[t[@"index"] integerValue]];}
        }
        NSMutableArray *actions=[NSMutableArray array];
        if(selectionKnown){
            // 关闭项：MPV 关闭哨兵（音频 0、字幕 10000）；选中状态已知时才提供。
            NSInteger offIndex=[kind isEqualToString:@"audio"]?0:10000;
            BOOL currentIsOff=!currentName;
            UIAction *off=[UIAction actionWithTitle:@"关闭" image:nil identifier:nil handler:^(UIAction *action){MediaPlaybackSettingsCoordinator *coordinator=weakSelf;if(!coordinator)return;id<MediaPlaybackSettingsCoordinatorOwner> host=coordinator.owner;if(!host)return;if([coordinator menuSessionChangedSinceAdapter:builtAdapter item:nil episode:builtEpisode line:builtLine]){[coordinator refuseStaleMenuAction];return;}id<CCTVPlaybackEngine> current=(id<CCTVPlaybackEngine>)host.cicadaAdapter;BOOL ok=current&&[current respondsToSelector:@selector(selectTrackWithIndex:)]&&[current selectTrackWithIndex:offIndex];BOOL verified=ok&&[coordinator verifyTrackOffForAdapter:current kind:kind];[RuntimeDiagnostics.shared recordEvent:@"playback_track_selected" category:@"playback" fields:@{@"track_kind":kind,@"track_index":@(-1),@"track_name":@"off",@"engine_selectable":@(canSelect),@"selection_succeeded":@(ok),@"selection_verified":@(verified),@"correlation_id":host.diagnosticTraceID?:@"",@"line_index":@(host.lineIndex),@"episode_index":@(host.episodeIndex)}];if(!ok)host.status.text=@"当前引擎未能切换轨道";else if(!verified)host.status.text=@"已发送切换请求，尚未确认是否切换";[coordinator refreshMenus];}];
            off.state=currentIsOff?UIMenuElementStateOn:UIMenuElementStateOff;
            [actions addObject:off];
        }
        for(NSDictionary *track in tracks){
            if(![track[@"type"] isEqual:kind])continue;
            NSInteger index=[track[@"index"] integerValue];
            NSString *trackName=[track[@"name"] isKindOfClass:NSString.class]?track[@"name"]:[NSString stringWithFormat:@"%@ %ld",kind,(long)index];
            BOOL isCurrent=[track[@"selected"] isEqual:@(YES)];
            UIAction *trackAct=[UIAction actionWithTitle:trackName image:nil identifier:nil handler:^(UIAction *action){MediaPlaybackSettingsCoordinator *coordinator=weakSelf;if(!coordinator)return;id<MediaPlaybackSettingsCoordinatorOwner> host=coordinator.owner;if(!host)return;if([coordinator menuSessionChangedSinceAdapter:builtAdapter item:nil episode:builtEpisode line:builtLine]){[coordinator refuseStaleMenuAction];return;}id<CCTVPlaybackEngine> current=(id<CCTVPlaybackEngine>)host.cicadaAdapter;BOOL ok=current&&[current respondsToSelector:@selector(selectTrackWithIndex:)]&&[current selectTrackWithIndex:index];BOOL verified=ok&&[coordinator verifyTrackSelectionForAdapter:current index:index kind:kind];[RuntimeDiagnostics.shared recordEvent:@"playback_track_selected" category:@"playback" fields:@{@"track_kind":kind,@"track_index":@(index),@"track_name":trackName?:@"",@"engine_selectable":@(canSelect),@"selection_succeeded":@(ok),@"selection_verified":@(verified),@"correlation_id":host.diagnosticTraceID?:@"",@"line_index":@(host.lineIndex),@"episode_index":@(host.episodeIndex)}];if(!ok)host.status.text=@"当前引擎未能切换轨道";else if(!verified)host.status.text=@"已发送切换请求，尚未确认是否切换";[coordinator refreshMenus];}];
            trackAct.state=isCurrent?UIMenuElementStateOn:UIMenuElementStateOff;
            [actions addObject:trackAct];
        }
        if(!actions.count)return nil;
        UIMenu *menu=[UIMenu menuWithTitle:title image:icon identifier:nil options:0 children:actions];
        if(@available(iOS 16.0,*))menu.subtitle=selectionKnown?(currentName?:@"关闭"):[NSString stringWithFormat:@"%lu 个可选轨道 · 选中状态未确认",(unsigned long)kindTrackCount];
        return menu;
    }

    AVPlayerItem *item=owner.player.currentItem;BOOL ready=item&&item.status==AVPlayerItemStatusReadyToPlay&&[item.asset statusOfValueForKey:@"availableMediaCharacteristicsWithMediaSelectionOptions" error:NULL]==AVKeyValueStatusLoaded;AVMediaSelectionGroup *group=ready?[item.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;
    if(!group.options.count)return nil;
    NSMutableArray *actions=[NSMutableArray array];AVMediaSelection *selection=item.currentMediaSelection;AVMediaSelectionOption *selected=[selection selectedMediaOptionInMediaSelectionGroup:group];
    // T09：AV 分支同样抓取会话快照（item 对象 + 集/线路），点选时校验，
    // 换集后旧 option 不得作用于新 item 的 group。
    AVPlayerItem *builtItem=item;NSInteger builtEpisode=owner.episodeIndex;NSInteger builtLine=owner.lineIndex;
    if(group.allowsEmptySelection){UIAction *off=[UIAction actionWithTitle:@"关闭" image:nil identifier:nil handler:^(UIAction *action){MediaPlaybackSettingsCoordinator *coordinator=weakSelf;if(!coordinator)return;id<MediaPlaybackSettingsCoordinatorOwner> host=coordinator.owner;if(!host)return;if([coordinator menuSessionChangedSinceAdapter:nil item:builtItem episode:builtEpisode line:builtLine]){[coordinator refuseStaleMenuAction];return;}AVPlayerItem *current=host.player.currentItem;AVMediaSelectionGroup *currentGroup=current?[current.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;if(current&&currentGroup)[current selectMediaOption:nil inMediaSelectionGroup:currentGroup];[RuntimeDiagnostics.shared recordEvent:@"playback_track_selected" category:@"playback" fields:@{@"track_kind":kind,@"track_index":@(-1),@"track_name":@"off",@"engine_selectable":@(YES),@"selection_succeeded":@(YES),@"correlation_id":host.diagnosticTraceID?:@"",@"line_index":@(host.lineIndex),@"episode_index":@(host.episodeIndex)}];[coordinator refreshMenus];}];off.state=selected?UIMenuElementStateOff:UIMenuElementStateOn;[actions addObject:off];}
    for(AVMediaSelectionOption *option in group.options){NSString *name=option.displayName.length?option.displayName:@"默认";UIAction *optAct=[UIAction actionWithTitle:name image:nil identifier:nil handler:^(UIAction *action){MediaPlaybackSettingsCoordinator *coordinator=weakSelf;if(!coordinator)return;id<MediaPlaybackSettingsCoordinatorOwner> host=coordinator.owner;if(!host)return;if([coordinator menuSessionChangedSinceAdapter:nil item:builtItem episode:builtEpisode line:builtLine]){[coordinator refuseStaleMenuAction];return;}AVPlayerItem *current=host.player.currentItem;AVMediaSelectionGroup *currentGroup=current?[current.asset mediaSelectionGroupForMediaCharacteristic:characteristic]:nil;BOOL ok=NO;if(current&&currentGroup){[current selectMediaOption:option inMediaSelectionGroup:currentGroup];ok=YES;}[RuntimeDiagnostics.shared recordEvent:@"playback_track_selected" category:@"playback" fields:@{@"track_kind":kind,@"track_name":name,@"engine_selectable":@(YES),@"selection_succeeded":@(ok),@"correlation_id":host.diagnosticTraceID?:@"",@"line_index":@(host.lineIndex),@"episode_index":@(host.episodeIndex)}];[coordinator refreshMenus];}];optAct.state=[selected isEqual:option]?UIMenuElementStateOn:UIMenuElementStateOff;[actions addObject:optAct];}
    UIMenu *menu=[UIMenu menuWithTitle:title image:icon identifier:nil options:0 children:actions];
    if(@available(iOS 16.0,*))menu.subtitle=selected?(selected.displayName.length?selected.displayName:@"默认"):(group.allowsEmptySelection?@"关闭":@"默认");
    return menu;
}

#pragma mark - 倍速

- (nullable UIMenu *)playbackRateMenu {
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    BOOL supportsRate=[owner activeEngineSupportsRateWriting];
    owner.playbackSpeedButton.hidden=!supportsRate;
    if(!supportsRate){owner.playbackSpeedButton.menu=nil;return nil;}
    __weak typeof(self) weakSelf=self;NSMutableArray *rateActions=[NSMutableArray array];
    NSArray<NSNumber *> *rates=@[@0.5,@0.75,@1.0,@1.25,@1.5,@2.0,@3.0];double currentRate=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaPlaybackRate"] doubleValue]:1.0;
    for(NSNumber *candidate in rates){double rate=candidate.doubleValue;NSString *title=rate==1.0?@"正常速度 (1.0×)":[NSString stringWithFormat:@"%.2g×",rate];UIAction *rateAct=[UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *action){[weakSelf.owner setPlaybackRate:rate];}];rateAct.state=fabs(currentRate-rate)<0.01?UIMenuElementStateOn:UIMenuElementStateOff;[rateActions addObject:rateAct];}
    UIMenu *menu=[UIMenu menuWithTitle:@"播放速度" image:[UIImage systemImageNamed:@"gauge.with.needle"] identifier:nil options:0 children:rateActions];
    if(@available(iOS 16.0,*))menu.subtitle=fabs(currentRate-1.0)<0.01?@"正常 1.0×":[NSString stringWithFormat:@"%.2g×",currentRate];
    return menu;
}

#pragma mark - 外挂字幕

- (UIMenu *)externalSubtitleMenu {
    __weak typeof(self) weakSelf=self;
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    // T09：外挂字幕 overlay 只在 AV 路径被喂数据与驱动（VC 只在 AV setup
    // 里调 loadExternalSubtitlesForResult、只在 AV 进度回调里调
    // updateForPlaybackTime）；adapter 路径下 overlay 无数据，字号/偏移/
    // 隐藏控件是无效控件，不提供，改给一句说明（标识符保持不变）。
    id<CCTVPlaybackEngine> adapter=(id<CCTVPlaybackEngine>)owner.cicadaAdapter;
    if(adapter){
        BOOL isMPV=[adapter isKindOfClass:[MediaPlaybackMPVAdapter class]];
        NSString *note=isMPV?@"MPV 字幕由内核渲染，请用字幕菜单切换":@"Cicada 暂不支持外挂字幕";
        UIAction *noteAct=[UIAction actionWithTitle:note image:[UIImage systemImageNamed:@"captions.bubble"] identifier:nil handler:^(__unused UIAction *a){}];
        noteAct.attributes=UIMenuElementAttributesDisabled;
        return [UIMenu menuWithTitle:@"外挂字幕调节" image:[UIImage systemImageNamed:@"captions.bubble"] identifier:@"media.playback.menu.extsub" options:0 children:@[noteAct]];
    }
    BOOL enabled=owner.subtitleOverlay?owner.subtitleOverlay.subtitlesEnabled:YES;
    UIAction *toggle=[UIAction actionWithTitle:(enabled?@"隐藏外挂字幕":@"显示外挂字幕") image:[UIImage systemImageNamed:@"captions.bubble"] identifier:nil handler:^(__unused UIAction *a){
        [weakSelf.owner ensureSubtitleOverlayInstalled];
        weakSelf.owner.subtitleOverlay.subtitlesEnabled=!enabled;
        [weakSelf refreshMenus];
    }];
    UIAction *scaleStd=[UIAction actionWithTitle:@"字号 · 标准 (1.0×)" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.fontScale=1.0;}];
    UIAction *scaleLg=[UIAction actionWithTitle:@"字号 · 大号 (1.25×)" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.fontScale=1.25;}];
    UIAction *scaleXl=[UIAction actionWithTitle:@"字号 · 超大 (1.5×)" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.fontScale=1.5;}];
    UIAction *offMinus=[UIAction actionWithTitle:@"时间轴 · 提前 0.5 秒" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.timeOffset-=0.5;}];
    UIAction *offZero=[UIAction actionWithTitle:@"时间轴 · 重置 0 秒" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.timeOffset=0.0;}];
    UIAction *offPlus=[UIAction actionWithTitle:@"时间轴 · 延后 0.5 秒" image:nil identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner ensureSubtitleOverlayInstalled];weakSelf.owner.subtitleOverlay.timeOffset+=0.5;}];
    UIMenu *menu=[UIMenu menuWithTitle:@"外挂字幕调节" image:[UIImage systemImageNamed:@"captions.bubble"] identifier:@"media.playback.menu.extsub" options:0 children:@[toggle,scaleStd,scaleLg,scaleXl,offMinus,offZero,offPlus]];
    // T09：overlay 只做纯文本渲染（ASS/VTT 的复杂样式已去除），菜单上明确标注。
    if(@available(iOS 16.0,*))menu.subtitle=@"仅显示纯文本（复杂样式已去除）";
    return menu;
}

#pragma mark - 顶层菜单

// 解码模式切换经宿主回调（B-P1 契约）：解码菜单动作先到协调器，再转给宿主执行切换。
- (void)applyDecodeModeChange:(NSString *)val {id<MediaPlaybackSettingsCoordinatorOwner> host=self.owner;if(!host)return;[host applyDecodeModeChange:val];}

- (UIMenu *)playbackOptionsMenu {
    __weak typeof(self) weakSelf=self;
    id<MediaPlaybackSettingsCoordinatorOwner> owner=self.owner;
    if(owner.playbackSpeedButton)owner.playbackSpeedButton.menu=[self playbackRateMenu];
    NSArray *gravityValues=@[@{@"title":@"画面适应",@"value":AVLayerVideoGravityResizeAspect},@{@"title":@"铺满裁切",@"value":AVLayerVideoGravityResizeAspectFill},@{@"title":@"拉伸填满",@"value":AVLayerVideoGravityResize}];
    NSMutableArray *gravityActions=[NSMutableArray array];NSString *currentGravity=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    NSString *currentGravityTitle=@"画面适应";
    for(NSDictionary *option in gravityValues){NSString *value=option[@"value"];BOOL active=[currentGravity isEqual:value];if(active)currentGravityTitle=option[@"title"];UIAction *gravAct=[UIAction actionWithTitle:option[@"title"] image:nil identifier:nil handler:^(UIAction *action){[weakSelf.owner setVideoGravity:value];}];gravAct.state=active?UIMenuElementStateOn:UIMenuElementStateOff;[gravityActions addObject:gravAct];}
    UIMenu *gravityMenu=[UIMenu menuWithTitle:@"画面比例" image:[UIImage systemImageNamed:@"aspectratio"] identifier:nil options:0 children:gravityActions];
    if(@available(iOS 16.0,*))gravityMenu.subtitle=currentGravityTitle;

    UIAction *intro=[UIAction actionWithTitle:@"将当前时间记为片头结束" image:[UIImage systemImageNamed:@"forward.end"] identifier:nil handler:^(UIAction *action){[weakSelf.owner rememberIntroEnd];}];
    UIAction *outro=[UIAction actionWithTitle:@"将剩余时间记为片尾" image:[UIImage systemImageNamed:@"forward.end.fill"] identifier:nil handler:^(UIAction *action){[weakSelf.owner rememberOutroSkip];}];
    UIAction *clear=[UIAction actionWithTitle:@"清除本片跳过位置" image:[UIImage systemImageNamed:@"eraser"] identifier:nil handler:^(UIAction *action){id<MediaPlaybackSettingsCoordinatorOwner> host=weakSelf.owner;[MediaPlaybackStateStore clearSkipPointsForContext:host.context?:@{}];[host updateSkipButtonForCurrentPosition];host.status.text=@"已清除本片的片头片尾位置";}];
    clear.attributes=UIMenuElementAttributesDestructive;
    UIMenu *skipMenu=[UIMenu menuWithTitle:@"片头片尾跳过" image:[UIImage systemImageNamed:@"forward.end.alt"] identifier:@"media.playback.menu.skip" options:0 children:@[intro,outro,clear]];
    if(@available(iOS 16.0,*))skipMenu.subtitle=@"设置片头 / 片尾 / 清除";

    BOOL keepAwake=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaKeepScreenAwake"]?[NSUserDefaults.standardUserDefaults boolForKey:@"cctv.mediaKeepScreenAwake"]:YES;
    UIAction *awake=[UIAction actionWithTitle:@"保持屏幕常亮" image:[UIImage systemImageNamed:@"sun.max"] identifier:nil handler:^(UIAction *action){[weakSelf.owner setKeepScreenAwake:!keepAwake];}];
    awake.state=keepAwake?UIMenuElementStateOn:UIMenuElementStateOff;

    UIAction *autoNextAction=[owner autoPlayNextAction];

    UIAction *danmaku=[owner danmakuDisabledAction];

    UIMenu *decodeMenu=[owner decodeModeMenu];

    UIAction *copyDiag=[UIAction actionWithTitle:@"复制流媒体诊断信息" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner copyCurrentStreamDiagnostics];}];
    UIAction *openMonitor=[UIAction actionWithTitle:@"站点与播放适配监测" image:[UIImage systemImageNamed:@"waveform.path.ecg"] identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner openAdaptationMonitor];}];
    NSMutableArray<UIMenuElement *> *episodeNav=[NSMutableArray array];
    if(owner.episodeIndex>0&&owner.episodes.count>1){
        [episodeNav addObject:[UIAction actionWithTitle:@"播放上一集" image:[UIImage systemImageNamed:@"backward.end.fill"] identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner playPreviousEpisodeManually];}]];
    }
    if(owner.episodeIndex+1<owner.episodes.count){
        [episodeNav addObject:[UIAction actionWithTitle:@"播放下一集" image:[UIImage systemImageNamed:@"forward.end.fill"] identifier:nil handler:^(__unused UIAction *a){[weakSelf.owner playNextEpisodeManually];}]];
    }
    UIMenu *subtitleMenu=[self subtitleSelectionMenu];
    UIMenu *audioMenu=[self audioSelectionMenu];
    NSMutableArray<UIMenuElement *> *avChildren=[NSMutableArray arrayWithObjects:decodeMenu,[owner externalSubtitleMenu],danmaku,nil];
    if(subtitleMenu)[avChildren insertObject:subtitleMenu atIndex:1];
    if(audioMenu)[avChildren insertObject:audioMenu atIndex:avChildren.count-1];
    UIMenu *playbackGroup=[UIMenu menuWithTitle:@"音画与解码" image:nil identifier:@"media.playback.menu.av" options:UIMenuOptionsDisplayInline children:avChildren];
    NSMutableArray<UIMenuElement *> *controlsChildren=[NSMutableArray arrayWithObjects:gravityMenu,[owner playbackSleepTimerMenu],nil];
    if([owner activeEngineSupportsRateWriting])[controlsChildren insertObject:[self playbackRateMenu] atIndex:0];
    UIMenu *controlsGroup=[UIMenu menuWithTitle:@"播放控制" image:nil identifier:@"media.playback.menu.controls" options:UIMenuOptionsDisplayInline children:controlsChildren];
    UIMenu *prefsGroup=[UIMenu menuWithTitle:@"观看偏好" image:nil identifier:@"media.playback.menu.prefs" options:UIMenuOptionsDisplayInline children:@[autoNextAction,awake,skipMenu]];
    UIMenu *diagGroup=[UIMenu menuWithTitle:@"诊断与监测" image:nil identifier:@"media.playback.menu.diag" options:UIMenuOptionsDisplayInline children:@[openMonitor,copyDiag]];
    NSMutableArray<UIMenuElement *> *topChildren=[NSMutableArray array];
    if(episodeNav.count)[topChildren addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"media.playback.menu.episodes" options:UIMenuOptionsDisplayInline children:episodeNav]];
    [topChildren addObjectsFromArray:@[playbackGroup,controlsGroup,prefsGroup,diagGroup]];
    UIMenu *menu=[UIMenu menuWithChildren:topChildren];if(owner.inlineOptionsButton)owner.inlineOptionsButton.menu=menu;return menu;
}

@end
