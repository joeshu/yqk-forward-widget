#import "CCTVLiveControlSheetViewController.h"
#import "HostGlassActionSheetViewController.h"
#import "RootViewController_Internal.h"
#import "HostMemoryBudgetCoordinator.h"


@implementation RootViewController (Playback)

#pragma mark - SDK

- (void)registerCallbackProtocol {
    Protocol *proto = NSProtocolFromString(@"CNPlayerCallbackProtocol");
    if (!proto) { [self log:@"回调协议不可见"]; return; }
    if (!class_conformsToProtocol(self.class, proto)) {
        class_addProtocol(self.class, proto);
        [self log:@"已注册回调协议"];
    }
}

- (void)activateAudioSession {
    Class sessionCls = NSClassFromString(@"AVAudioSession");
    if (!sessionCls) return;
    id session = ((id (*)(id, SEL))objc_msgSend)(sessionCls, NSSelectorFromString(@"sharedInstance"));
    if (!session) return;
    BOOL (*setCategory)(id, SEL, NSString *, NSError **) = (void *)objc_msgSend;
    BOOL (*setActive)(id, SEL, BOOL, NSError **) = (void *)objc_msgSend;
    NSString *category=CCTVBoolPreference(@"allowBackgroundAudio",YES)?@"AVAudioSessionCategoryPlayback":@"AVAudioSessionCategoryAmbient";
    setCategory(session, NSSelectorFromString(@"setCategory:error:"), category, NULL);
    setActive(session, NSSelectorFromString(@"setActive:error:"), YES, NULL);
}

- (void)configureSDKLogging {
    BOOL verbose=CCTVBoolPreference(@"nativeSDKVerboseLogs",NO);
    Class cls=NSClassFromString(@"CNPlayer");
    for(NSString *selector in @[@"logEnabled:",@"logToStatEnabled:",@"playerCoreLogEnabled:",@"playerNetWorkLogEnabled:",@"statInfoLogEnabled:",@"statCoreInfoLogEnabled:"])
        [self callClass:cls sel:selector args:@[@(verbose)]];
}

- (void)setupSDK {
    Class cls = NSClassFromString(@"CNPlayer");
    if (!cls) { self.titleLabel.text = @"SDK 未加载"; return; }
    BOOL thumbnailGuardInstalled=[CNPlayerCrashGuard install];
    [self configureSDKLogging];
    // Keep the SDK's per-core license defaults. Cicada and IJK use distinct
    // endpoints; do not replace Cicada's license URL with IJK's.
    @try {
        [CNPlayer startPlayerSDK_Options:[CNPlayer defaultOptions]];
    } @catch (NSException *e) {
        [self log:@"启动异常 %@", e.reason];
        return;
    }
    thumbnailGuardInstalled=thumbnailGuardInstalled||[CNPlayerCrashGuard install];
    if(thumbnailGuardInstalled)[self log:@"已启用央视播放器异常缩略图保护"];
    id ver = [self callClass:cls sel:@"SDKVersion" args:@[]];
    [self log:@"CCTVHost %@ · SDK %@ · 当前原生模式：%@ · Python %@",CCTVBuildTag(),ver,CCTVBoolPreference(@"legacyNativePlayback",YES)?@"兼容复用":@"独立实例",PyHost.running?@"运行中":@"未启动"];
    self.nativeCDNPreference=[NativeCDNPreference new];
    [self callClass:cls sel:@"authed" args:@[]];
    self.nativePreloader=[[NativeChannelPreloader alloc] initWithFactory:^id{ return [[NSClassFromString(@"CNPlayer") alloc] init]; } clock:^NSTimeInterval{return CACurrentMediaTime();}];
    __weak typeof(self) preloaderOwner=self;
    self.nativePreloader.onLog=^(NSString *message){[preloaderOwner log:@"%@",message];};

    // SDK 初始化返回后即可续播，不再固定等待 2.5 秒。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!CCTVBoolPreference(@"resumeLastChannel",NO)) { [self log:@"启动时自动续播已关闭，等待用户点选频道"]; return; }
        NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"lastChannel"];
        if (![last[@"id"] length] || self.channelID.length || self.activeTab>=2 || !self.view.window) return;
        NSDictionary *live=[self channelWithID:last[@"id"]];
        if(!live)return;
        NSArray *owners=CCTVStringArrayValue(live[@"subscriptionSources"]);
        NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
        if([live[@"remoteURL"] length]){
            BOOL available=NO;
            for(NSString *source in owners)if([self.subscriptionURLs containsObject:source]&&![disabled containsObject:source]){available=YES;break;}
            if(!available||self.activeTab!=1)return;
        }else if(self.activeTab!=0||!CCTVBoolPreference(@"nativeChannelsEnabled",YES))return;
        last=live;
        [self log:@"续播上次频道 %@", last[@"name"] ?: last[@"id"]];
        if ([last[@"remoteURL"] length]) [self playRemote:last];
        else [self playChannel:last route:nil];
    });

    // 预热：提前建好播放器实例，缩短首次起播时间
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.sdkPlayer) return;
        id inst = nil;
        inst = [weakSelf guardedNewInstanceOfClass:cls];
        if (inst) { weakSelf.sdkPlayer = inst; weakSelf.sdkPlayerUsed=NO; [weakSelf log:@"播放器实例已预热"]; }
    });
}

#pragma mark - 播放

- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route {
    [[PlaybackCoordinator shared] acquireSession:(id<PlaybackSession>)self];
    self.livePlaybackSuspendedForNavigation=NO;self.nativeUserPaused=NO;
    if([ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]]){[self routePlayback:ch];return;}
    NSString *cid = ch[@"id"];
    if (!cid.length) return;
    if(!self.nativeCDNPreference)self.nativeCDNPreference=[NativeCDNPreference new];
    NSError *routeError=nil;
    NSString *selectedURL=route?[self.nativeCDNPreference URLForRoute:route error:&routeError]:nil;
    if(route&&!selectedURL){[self showNativeRouteError:routeError channel:ch];return;}
    if(self.nativeCDNPreference.overrideMayBeActive&&![self.nativeCDNPreference restoreDefault:&routeError]){
        [self showNativeRouteError:routeError channel:ch];return;
    }
    self.nativePlainRouteActive=NO;
    self.remoteCatchupActive=NO;self.activeCatchupProgramTitle=nil;self.activeCatchupStart=0;self.activeCatchupEnd=0;self.activeCatchupLiveChannel=nil;
    if(!self.currentPlaybackTraceID.length||self.selectionRequestedAt<=0)self.currentPlaybackTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    self.requestedNativeRoute=route;
    self.directNativeRouteActive=(route!=nil);
    [self beginPlaybackPriority];
    if(self.activeTab!=0)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[0]];
    self.playbackGeneration += 1;self.selectionVersion++;
    self.currentRemoteURL = nil;
    self.currentRemoteHeaders = @{};
    self.playerExpanded=YES;
    [self.view setNeedsLayout];
    NSString *previousChannelID = self.channelID;
    self.channelID = cid;
    self.channelName = ch[@"name"] ?: cid;
    [self refreshVisibleChannelSelectionFromID:previousChannelID toID:cid];
    self.routeName = route ? [NSString stringWithFormat:@"%@ · 自选地址", [route[@"provider"] uppercaseString]] : @"自动";
    if(self.playerTabs.selectedSegmentIndex!=3)self.playerTabs.selectedSegmentIndex=1;
    [self updatePlayerChannelLogoForChannel:ch];
    [self selectPlayerPanel];
    self.firstRender = NO;
    self.stallReported = NO;
    self.nativeStartupRecoveryUsed = NO;
    self.nativeSafeStartupActive = NO;
    self.nativeAttemptStartedAt = 0;
    self.retryCount = 0;
    self.playStartedAt = self.selectionRequestedAt?:CACurrentMediaTime();self.selectionRequestedAt=0;
    if(!self.currentRemotePlaybackAttemptID.length)self.currentRemotePlaybackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration];[HostPerfMetrics.shared beginPlaybackAttemptWithSessionID:self.currentPlaybackTraceID attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration sourceRevision:self.selectionVersion engine:nil userAction:@"select" expectsVideo:YES];
    self.firstFrameSeconds = 0;
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 连接中", self.channelName];
    self.titleLabel.hidden = NO;
    self.infoLabel.hidden = NO;
    self.infoLabel.text = @"";
    [self.spinner startAnimating];
    [self log:@"起播 %@ (%@) 线路=%@ · Python %@ · variant %@",self.channelName,cid,self.routeName,PyHost.running?@"running":@"idle",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"]?:@"full"];

    [self stopPlayback];
    [self recordStartupStage:@"teardown"];
    if(route){
        if(CCTVRouteRequiresSDK(route)){
            [self log:@"所选线路标记为 UDRM / SDK 流，跳过普通 HLS 探测并交给 CNPlayer"];
            [self playViaSDKURL:selectedURL channelID:cid title:self.channelName];return;
        }
        NSUInteger generation=self.playbackGeneration;
        __weak typeof(self) weakSelf=self;
        void(^resolved)(BOOL)=^(BOOL plain){
            RootViewController *owner=weakSelf;
            if(!owner || generation!=owner.playbackGeneration || ![owner.channelID isEqual:cid] || ![owner.requestedNativeRoute isEqual:route])return;
            owner.nativeRouteProbe=nil;
            if(!owner.plainRouteCache)owner.plainRouteCache=[NSMutableDictionary dictionary];
            if(owner.plainRouteCache.count>=64){
                NSArray *sortedKeys=[owner.plainRouteCache keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                    return [a[@"at"] compare:b[@"at"]];
                }];
                NSUInteger evictCount=MAX((NSUInteger)1,sortedKeys.count/4);
                [owner.plainRouteCache removeObjectsForKeys:[sortedKeys subarrayWithRange:NSMakeRange(0,evictCount)]];
            }
            owner.plainRouteCache[selectedURL]=@{@"plain":@(plain),@"at":@(CACurrentMediaTime())};
            if(plain){
                [owner log:@"自选线路明文 HLS 清单可读，使用 AVPlayer；等待实际视频首帧"];
                [owner.remoteAttemptedURLs removeAllObjects];owner.remoteRetryCount=0;
                [owner startRemoteChannel:@{@"id":cid,@"name":ch[@"name"]?:cid,@"remoteURL":selectedURL,@"nativePlainRoute":@YES}];
            }else{
                [owner log:@"自选线路未确认明文 HLS，保留所选地址交给 SDK"];
                [owner playViaSDKURL:selectedURL channelID:cid title:owner.channelName];
            }
        };
        NSDictionary *cached=self.plainRouteCache[selectedURL];
        NSTimeInterval age=CACurrentMediaTime()-[cached[@"at"] doubleValue];
        if(cached && age>=0 && age<([cached[@"plain"] boolValue]?30:3))resolved([cached[@"plain"] boolValue]);
        else{self.nativeRouteProbe=[HLSRouteProbe new];[self.nativeRouteProbe startURL:[NSURL URLWithString:selectedURL] completion:resolved];}
    }
    else {[self log:@"使用 SDK 按频道 ID 自动调度"];[self playViaSDK:cid title:self.channelName];}

    // Defer optional EPG traffic until the first video frame.
}

- (void)playSelectedNativeRouteOrChannel {
    if(self.requestedNativeRoute){
        NSError *error=nil;NSString *url=[self.nativeCDNPreference URLForRoute:self.requestedNativeRoute error:&error];
        if(!url){[self displayNativePlaybackFailure:@"所选线路配置无效" error:error];return;}
        [self playViaSDKURL:url channelID:self.channelID title:self.channelName];return;
    }
    [self playViaSDK:self.channelID title:self.channelName];
}

// Starts a new native SDK session: bumps the session ID and installs a fresh
// session delegate as the SDK delegate for this playback. Every native play
// start goes through here so no callback can ever be attributed to an older
// session, even when the legacy path reuses the same CNPlayer instance.
- (CNPlayerSessionDelegate *)beginNativeSession {
    self.nativeSessionID++;
    self.nativeSessionDelegate=[[CNPlayerSessionDelegate alloc] initWithOwner:self sessionID:self.nativeSessionID];
    return self.nativeSessionDelegate;
}

- (void)rebuildTimeshiftController {
    // 控制器与播放器一一对应：每次起播（或起播失败换实例）都重建，
    // 旧控制器的回调随之丢弃，不串台；回调弱引用宿主，避免循环引用。
    if(!self.currentPlayer){self.timeshiftController=nil;return;}
    self.timeshiftController=[[CCTVTimeshiftController alloc] initWithPlayer:self.currentPlayer];
    __weak typeof(self) weakSelf=self;
    self.timeshiftController.onFailure=^(NSError *error){[weakSelf displayNativePlaybackFailure:@"时移 / 回看失败" error:error];};
    self.timeshiftController.onReturnToLiveFallback=^{[weakSelf playSelectedNativeRouteOrChannel];};
    self.timeshiftController.onProgress=^(NSTimeInterval behindLive,NSTimeInterval position){weakSelf.infoLabel.hidden=NO;NSString *prog=weakSelf.activeCatchupProgramTitle.length?[NSString stringWithFormat:@" · %@",weakSelf.activeCatchupProgramTitle]:@"";weakSelf.infoLabel.text=[NSString stringWithFormat:@"回看中%@ · 距直播 %.0f 分钟",prog,behindLive/60.0];};
}
- (void)playViaSDKURL:(NSString *)url channelID:(NSString *)cid title:(NSString *)title {
    [CNPlayerCrashGuard install];
    if(!url.length||!cid.length){[self displayNativePlaybackFailure:@"所选线路参数缺失" error:nil];return;}
    NSMutableDictionary *traceFields=[@{@"route_type":@"user_selected", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[traceFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:url])];[RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:traceFields];
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;self.nativeUserPaused=NO;[self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"所选地址交给央视 SDK 播放";[self.spinner startAnimating];
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    [self.nativePreloader cancel];self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
    Class cls=NSClassFromString(@"CNPlayer");SEL selector=NSSelectorFromString(@"playLIVEWithUrl:delegate:configOptions:");
    id player=[self guardedNewInstanceOfClass:cls];
    NSMethodSignature *signature=[player methodSignatureForSelector:selector];
    BOOL supported=player&&[player respondsToSelector:selector]&&signature&&signature.numberOfArguments==5&&signature.methodReturnType[0]=='B'&&strcmp([signature getArgumentTypeAtIndex:2],"@")==0&&strcmp([signature getArgumentTypeAtIndex:3],"@")==0&&strcmp([signature getArgumentTypeAtIndex:4],"@")==0;
    if(!supported){[self displayNativePlaybackFailure:@"SDK 不支持自选地址起播" error:nil];return;}
    self.currentPlayer=player;self.cicadaPlayer=nil;self.nativePlaybackFailed=NO;
    [self rebuildTimeshiftController];
    [self guardedSetValue:@YES forKey:@"autoPlay" onObject:player];
    self.nativeStartupTuner=CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSMutableDictionary *options=[@{kOptTitle:title?:cid,kOptURLChannelIDForStats:cid,CCTVTimeshiftConfigKeyLivePublicCheck:@NO,CCTVTimeshiftConfigKeyTimeshiftingChannelID:cid} mutableCopy];
    id dataManager=[self call:player sel:@"dataManager"];
    id userID=[self call:dataManager sel:@"userID"];
    if([userID isKindOfClass:NSString.class]&&[userID length])options[kOptUserID]=userID;
    [self log:@"CNPlayer URL 起播 %@ · %@",cid,[NSURL URLWithString:url].host?:@"未知主机"];
    CNPlayerSessionDelegate *session=[self beginNativeSession];
    id accepted=[self invokeTarget:player selector:selector args:@[url,session,options]];
    [self recordStartupStage:@"configure"];
    if(![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        self.nativeSessionDelegate=nil;self.currentPlayer=nil;[self guardedSetValue:nil forKey:@"delegate" onObject:player];[self call:player sel:@"stop"];
        [self log:@"CNPlayer 未接受所选地址；保留线路选择，不回退自动"];
        [self displayNativePlaybackFailure:@"SDK 拒绝所选地址" error:nil];return;
    }
    if(![CNPlayerCrashGuard install])[self log:@"未能安装播放器缩略图异常保护"];
    [self attachVideoView];[self call:player sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];if(!self.nativePlaybackFailed)[self startWatchdog];
    [self updateLiveScreenAwakeState];
}

- (void)playViaSDK:(NSString *)cid title:(NSString *)title {
    // Some SDK builds load their IJK core lazily; install the guard again
    // before prepareToPlay can enter its asynchronous decoder/error path.
    [CNPlayerCrashGuard install];
    NSMutableDictionary *startFields=[@{@"route_type":@"sdk_auto", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"channel_id_kind":([ProfileStore isHTTP:cid]?@"http_url":@"sdk_channel_id"), @"startup_mode":self.nativeSafeStartupActive?@"default_recovery":@"normal"} mutableCopy];
    if(![ProfileStore isHTTP:cid]&&cid.length<=128)startFields[@"sdk_channel_id"]=cid;
    [RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:startFields];
    if([ProfileStore isHTTP:cid]){[self playRemote:@{@"id":cid,@"name":title?:cid,@"remoteURL":cid}];return;}
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;self.nativeUserPaused=NO;[self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    // Default matches v0.12: stop the old playback, reset the retained wrapper,
    // then playLIVEWithChannelID + prepareToPlay. Fresh wrappers remain an A/B option.
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    Class cls=NSClassFromString(@"CNPlayer");SEL playSel=NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    BOOL legacy=!self.nativeSafeStartupActive && CCTVBoolPreference(@"legacyNativePlayback",YES);
    id prepared=(!self.nativeSafeStartupActive && !self.directNativeRouteActive && CCTVBoolPreference(@"preloadNativeChannel",YES))?[self.nativePreloader takeChannel:cid]:nil;
    [self.nativePreloader cancel];
    id inst=prepared?:self.sdkPlayer;
    if(prepared && self.sdkPlayer && prepared!=self.sdkPlayer)[self call:self.sdkPlayer sel:@"reset"];
    if(!prepared && !legacy&&self.sdkPlayerUsed)inst=nil;
    if(!prepared && legacy&&inst&&self.sdkPlayerUsed)[self call:inst sel:@"reset"];
    self.sdkPlayer=nil;
    if(!inst)inst=[self guardedNewInstanceOfClass:cls];
    if(!inst||![inst respondsToSelector:playSel]){[self displayNativePlaybackFailure:@"SDK 接口不可用" error:nil];return;}
    self.currentPlayer=inst;self.cicadaPlayer=nil;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;
    [self rebuildTimeshiftController];
    CNPlayerSessionDelegate *session=[self beginNativeSession];
    [self guardedSetValue:@YES forKey:@"autoPlay" onObject:inst];
    self.nativePlaybackFailed=NO;
    self.nativeStartupTuner=!self.nativeSafeStartupActive && CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSDictionary *options=@{kOptTitle:title?:cid,CCTVTimeshiftConfigKeyLivePublicCheck:@NO,CCTVTimeshiftConfigKeyTimeshiftingChannelID:cid};
    [self log:@"原生起播 %@ · %@",cid,self.nativeSafeStartupActive?@"SDK 默认配置恢复":(legacy?@"0.12 兼容复用":@"独立实例对比")];
    id accepted=@YES;
    if(prepared){
        if(![self guardedSetValue:session forKey:@"delegate" onObject:inst])prepared=nil;
        if(prepared){[self recordStartupStage:@"preloadedVDN"];[self log:@"命中原生预解析 %@，保留播放信息直接 prepare",cid];}
    }
    if(!prepared)accepted=[self invokeTarget:inst selector:playSel args:@[cid,session,options]];
    if(![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        id previous=inst;self.currentPlayer=nil;self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
        [self guardedSetValue:nil forKey:@"delegate" onObject:previous];
        [self call:previous sel:@"stop"];
        [self log:@"SDK 实例未确认起播，使用全新实例重试一次"];
        inst=[self guardedNewInstanceOfClass:cls];
        if(inst){self.currentPlayer=inst;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;self.nativePlaybackFailed=NO;self.nativeRetryPending=NO;[self rebuildTimeshiftController];session=[self beginNativeSession];[self guardedSetValue:@YES forKey:@"autoPlay" onObject:inst];accepted=[self invokeTarget:inst selector:playSel args:@[cid,session,options]];}
    }
    [self recordStartupStage:@"configure"];
    if(!inst||![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        self.currentPlayer=nil;self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
        [self.nativeStartupTuner restore];self.nativeStartupTuner=nil;
        [self guardedSetValue:nil forKey:@"delegate" onObject:inst];
        [self call:inst sel:@"stop"];
        [self log:@"SDK 未确认接受起播，停止本次尝试"];[self displayNativePlaybackFailure:@"起播被拒绝" error:nil];return;
    }
    BOOL thumbnailGuardInstalled=[CNPlayerCrashGuard install];
    if(!thumbnailGuardInstalled)[self log:@"未能安装播放器缩略图异常保护"];
    [self attachVideoView];[self call:inst sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];[self startWatchdog];
}

- (void)recordStartupStage:(NSString *)stage {
    if(![self.startupTrace record:stage atTime:CACurrentMediaTime()])return;
    [self log:@"起播阶段 %@ [%lu] %@ +%.2fs",self.channelID?:@"—",(unsigned long)self.playbackGeneration,stage,[self.startupTrace.stages[stage] doubleValue]];if([stage isEqualToString:@"frame"])[HostPerfMetrics.shared recordFirstFrameWithEngine:(self.remoteAdapter?@"cicada":(self.currentRemoteURL.length?@"avplayer":@"cnplayer")) channelID:self.channelID elapsedSeconds:[self.startupTrace.stages[@"frame"] doubleValue] stages:self.startupTrace.stages attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration sourceRevision:self.selectionVersion]; // 首帧按内核分类写入 perf_first_frame，并归属到当前 attempt（T01）
}

- (void)stopPlayback {
    [self stopRemoteProgressWatchdog];
    self.remoteAdapter.delegate=nil;[self.remoteAdapter destroy];self.remoteAdapter=nil;
    // Invalidate the native session first: any callback still in flight to the
    // old session delegate is dropped by its session check, and bumping the ID
    // keeps even a delegate retained by the SDK from forwarding again.
    self.nativeSessionDelegate=nil;self.nativeSessionID++;
    [self.nativeRouteProbe cancel];self.nativeRouteProbe=nil;
    self.nativeRetryPending=NO;
    self.moviePiPActive=NO;
    [self.moviePlayer pause];self.movieController.player=nil;self.moviePlayer=nil;self.movieController=nil;
    [self.nativeTimeshift cancel];self.nativeTimeshift=nil;self.nativeTransitionKind=nil;self.nativeTimeShiftActive=NO;self.nativeUserPaused=NO;
    [self.nativeStartupTuner restore];
    self.nativeStartupTuner=nil; // Restore before the retained SDK wrapper is stopped or reused.
    self.remotePlaybackWanted=NO;
    self.remoteFailureRecoveryPending=NO;
    if(self.avKeepUpObserved){[self guardedRemoveObserverFrom:self.avPlayer.currentItem keyPath:@"playbackLikelyToKeepUp" context:kAVItemStatusContext]; self.avKeepUpObserved=NO;}
    [self.playbackReadiness cancel];self.playbackReadiness=nil;
    if(self.avLayerObserved){[self guardedRemoveObserverFrom:self.avLayer keyPath:@"readyForDisplay" context:kAVLayerFrameContext]; self.avLayerObserved=NO;}

    self.epgListGeneration++;
    for(NSURLSessionDataTask *task in self.epgListTasks.allValues)[task cancel];[self.epgListTasks removeAllObjects];[self.epgInflight removeAllObjects];
    if(self.pip.isPictureInPictureActive)[self.pip stopPictureInPicture];self.pip=nil;
    [self.epgTask cancel];
    self.epgTask = nil;
    [self.epgTimer invalidate];
    self.epgTimer = nil;
    id previous = self.currentPlayer;
    // Ignore synchronous teardown callbacks before changing the core.
    self.currentPlayer = nil;
    if (previous) {
        [self guardedSetValue:nil forKey:@"delegate" onObject:previous];
        [self call:previous sel:@"stop"];
    }
    if (self.cicadaPlayer) {
        [self call:self.cicadaPlayer sel:@"destroy"];
    }
    if (self.avPlayer) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.avPlayer.currentItem];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:self.avPlayer.currentItem];
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.avPlayer.currentItem];
        [self.avPlayer pause];
        AVPlayerItem *previousItem=self.avPlayer.currentItem;
        [self guardedRemoveObserverFrom:previousItem keyPath:@"status" context:kAVItemStatusContext];
        [previousItem cancelPendingSeeks];[previousItem.asset cancelLoading];[self.avPlayer replaceCurrentItemWithPlayerItem:nil];
        self.avPlayer = nil;
    }
    self.avLayer.player=nil;
    [self.avLayer removeFromSuperlayer];
    self.avLayer = nil;
    self.currentPlayer = nil;
    self.cicadaPlayer = nil;
    [self.liveControlsOverlay invalidate];
    self.liveMuted = NO;
    [self.muteBtn setTitle:@"静音" forState:UIControlStateNormal];
    [self syncPlayPauseButtonIcon];
    [self.watchdog invalidate];
    self.watchdog = nil;
    [self.liveQualityBadgeTimer invalidate];
    self.liveQualityBadgeTimer = nil;
    self.liveVideoSize = CGSizeZero;
    self.liveBitrateBps = 0;
    self.livePeakBitrateBps = 0;
    self.liveFPS = 0;
    self.liveVideoCodec = nil;
    self.liveAudioCodec = nil;
    self.liveStallCount = 0;
    [self updateLiveQualityBadge];
    for (UIView *v in self.playerBox.subviews.copy) {
        if (v == self.titleLabel || v == self.infoLabel || v == self.spinner || v == self.controlBar || v == self.playerChannelLogo || v == self.playerTopScrim || v == self.playerBottomScrim) continue;
        [v removeFromSuperview];
    }
    [self updateLiveScreenAwakeState];
}

- (void)attachVideoView {
    id view = [self guardedValueForKey:@"view" ofObject:self.currentPlayer];
    if (![view isKindOfClass:UIView.class]) return;
    UIView *v = view;
    if (v.superview != self.playerBox) {
        [self.playerBox insertSubview:v atIndex:0];
    }
    v.translatesAutoresizingMaskIntoConstraints = YES;
    v.frame = self.playerBox.bounds;
    [self.playerBox sendSubviewToBack:v];
}

- (void)togglePlayPause {
    if(self.remoteAdapter){if([self sessionIsPlaying])[self sessionPause];else[self sessionPlay];return;}
    if(self.livePlaybackSuspendedForNavigation){
        self.livePlaybackSuspendedForNavigation=NO;
        if(self.activeTab==1&&self.currentRemoteURL.length){[self playRemote:@{@"id":self.channelID?:self.currentRemoteURL,@"name":self.channelName?:@"直播",@"remoteURL":self.currentRemoteURL,@"headers":self.currentRemoteHeaders?:@{}}];return;}
        NSDictionary *channel=[self channelWithID:self.channelID];
        if(!channel&&self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};
        if(channel){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];}
        return;
    }
    if(self.moviePlayer){if(self.moviePlayer.rate>0)[self.moviePlayer pause];else[self.moviePlayer play];return;}
    if(self.nativePlainRouteActive && self.remotePlaybackFailed){NSDictionary *channel=[self channelWithID:self.channelID];if(channel)[self playChannel:channel route:self.requestedNativeRoute];return;}
    if(self.remotePlaybackFailed && self.currentRemoteURL.length){[self playRemote:@{@"id":self.channelID?:self.currentRemoteURL,@"name":self.channelName?:self.currentRemoteURL,@"remoteURL":self.currentRemoteURL,@"headers":self.currentRemoteHeaders?:@{}}];return;}
    if(self.nativePlaybackFailed){NSDictionary *channel=[self channelWithID:self.channelID];if(!channel && self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};if(channel){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];}return;}
    if (self.avPlayer) {
        BOOL playing=self.remotePlaybackWanted;
        self.remotePlaybackWanted=!playing;
        self.remoteProgressSampleTime=0;
        self.remoteProgressLastAdvanceTime=0;
        if (playing) [self.avPlayer pause]; else [self.avPlayer play];
        [self.playPauseBtn setTitle:(playing ? @"继续" : @"暂停") forState:UIControlStateNormal];
        [self syncPlayPauseButtonIcon];
        return;
    }
    if (!self.currentPlayer) return;
    BOOL playing = NO;
    playing = [[self guardedValueForKey:@"isPlaying" ofObject:self.currentPlayer] boolValue];
    if ([self.playPauseBtn.currentTitle isEqualToString:@"继续"] || [self.playPauseBtn.currentTitle isEqualToString:@"继续播放"]) playing = NO;
    self.nativeUserPaused = playing;
    [self call:self.currentPlayer sel:(playing ? @"pause" : @"play")];
    [self.playPauseBtn setTitle:(playing ? @"继续" : @"暂停") forState:UIControlStateNormal];
    [self syncPlayPauseButtonIcon];
}

- (void)toggleMute {
    if(self.remoteAdapter){self.liveMuted=!self.liveMuted;[self.remoteAdapter setMuted:self.liveMuted];[self.muteBtn setTitle:self.liveMuted?@"发声":@"静音" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];return;}
    if (self.avPlayer) {
        self.liveMuted = !self.liveMuted;
        self.avPlayer.muted = self.liveMuted;
        [self.muteBtn setTitle:(self.liveMuted ? @"发声" : @"静音") forState:UIControlStateNormal];
        [self syncPlayPauseButtonIcon];
        return;
    }
    self.liveMuted = !self.liveMuted;
    [self guardedSetValue:@(self.liveMuted) forKey:@"muted" onObject:self.currentPlayer];
    [self.muteBtn setTitle:(self.liveMuted ? @"发声" : @"静音") forState:UIControlStateNormal];
    [self syncPlayPauseButtonIcon];
}

#pragma mark - 手势 / 锁屏

- (UISlider *)systemVolumeSlider {
    for (UIView *v in self.volumeView.subviews) {
        if ([v isKindOfClass:UISlider.class]) return (UISlider *)v;
    }
    return nil;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if(g.state==UIGestureRecognizerStateBegan||!self.livePanActive){
        CGPoint velocity=[g velocityInView:self.playerBox];self.livePanIgnored=fabs(velocity.x)>fabs(velocity.y)&&fabs(velocity.x)>0;
        self.livePanRightSide=[g locationInView:self.playerBox].x>self.playerBox.bounds.size.width/2;self.livePanActive=YES;
        if(!self.livePanIgnored)[[self liveOverlayPolicy] show];
    }
    CGFloat dy=[g translationInView:self.playerBox].y;[g setTranslation:CGPointZero inView:self.playerBox];
    if(!self.livePanIgnored){CGFloat delta=-dy/220.0;
        if(self.livePanRightSide){UISlider *slider=[self systemVolumeSlider];if(slider){float value=MIN(1,MAX(0,slider.value+delta*.35));[slider setValue:value animated:NO];[slider sendActionsForControlEvents:UIControlEventTouchUpInside];self.titleLabel.text=[NSString stringWithFormat:@"音量 %d%%",(int)(value*100)];}}
        else {CGFloat value=MIN(1,MAX(0,UIScreen.mainScreen.brightness+delta*.5));UIScreen.mainScreen.brightness=value;self.titleLabel.text=[NSString stringWithFormat:@"亮度 %d%%",(int)(value*100)];}
    }
    if(g.state==UIGestureRecognizerStateEnded||g.state==UIGestureRecognizerStateCancelled||g.state==UIGestureRecognizerStateFailed){self.livePanActive=NO;self.titleLabel.text=self.channelName;if(!self.livePanIgnored)[[self liveOverlayPolicy] show];}
}

- (void)setupRemoteCommands {
    // 用 target-action 而不用 addTargetWithHandler:：后者的 block 会被
    // MPRemoteCommandCenter 单例强引用，进而永久强引用 self，使 dealloc
    // 永远走不到、dealloc 里的 KVO 拆除也永远执行不了。target-action 配合
    // dealloc 中的 removeTarget: 才能正常释放。
    // 注意：MPRemoteCommand 的 action 只接受两种签名——返回
    // MPRemoteCommandHandlerStatus，或第二个参数为 completion handler。
    // void 无参的 togglePlayPause 会在 addTarget 时直接抛
    // NSInternalInconsistencyException（“Unsupported action method
    // signature”）导致启动即崩溃，故用下面的薄包装转发。
    MPRemoteCommandCenter *c = MPRemoteCommandCenter.sharedCommandCenter;
    [c.playCommand removeTarget:self];
    [c.pauseCommand removeTarget:self];
    [c.nextTrackCommand removeTarget:self];
    [c.previousTrackCommand removeTarget:self];
    (void)[PlaybackCoordinator shared];
}

- (MPRemoteCommandHandlerStatus)togglePlayPauseForRemoteCommand:(MPRemoteCommandEvent *)event {
    return event.command==MPRemoteCommandCenter.sharedCommandCenter.pauseCommand?[[PlaybackCoordinator shared] pause]:[[PlaybackCoordinator shared] play];
}
- (MPRemoteCommandHandlerStatus)stepToNextChannelForRemoteCommand:(MPRemoteCommandEvent *)event {return [[PlaybackCoordinator shared] step:1];}
- (MPRemoteCommandHandlerStatus)stepToPreviousChannelForRemoteCommand:(MPRemoteCommandEvent *)event {return [[PlaybackCoordinator shared] step:-1];}

- (void)updateNowPlaying {
    if([PlaybackCoordinator shared].currentSession!=(id<PlaybackSession>)self)return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = self.channelName ?: @"CCTVHost";
    info[MPMediaItemPropertyArtist] = @"CCTVHost";
    if (self.avPlayer.currentItem) {
        CMTime d = self.avPlayer.currentItem.duration;
        if (CMTIME_IS_NUMERIC(d)) info[MPMediaItemPropertyPlaybackDuration] = @(CMTimeGetSeconds(d));
    }
    info[MPNowPlayingInfoPropertyPlaybackRate]=@([self sessionIsPlaying]?1:0);
    double position=self.remoteAdapter?self.remoteAdapter.currentPosition:CMTimeGetSeconds(self.avPlayer.currentTime);if(isfinite(position)&&position>=0)info[MPNowPlayingInfoPropertyElapsedPlaybackTime]=@(position);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}
- (void)playRemote:(NSDictionary *)ch {
    self.livePlaybackSuspendedForNavigation=NO;
    if(![ch[@"catchupReplay"] boolValue]){
        self.remoteCatchupActive=NO;self.activeCatchupProgramTitle=nil;self.activeCatchupStart=0;self.activeCatchupEnd=0;self.activeCatchupLiveChannel=nil;
    }
    if(!self.currentPlaybackTraceID.length||self.selectionRequestedAt<=0)self.currentPlaybackTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    self.requestedNativeRoute=nil;self.directNativeRouteActive=NO;
    [self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.remoteFailureRecoveryPending=NO;self.remotePlaybackFailed=NO;
    [self startRemoteChannel:ch];
}
- (void)startRemoteChannel:(NSDictionary *)ch {
    self.remoteTriedCicada=NO;
    NSString *u=[self stableURLKey:ch[@"remoteURL"]];if(!u.length)return;
    [self.remoteAttemptedURLs addObject:u];
    [self.nativePreloader cancel];
    [self beginPlaybackPriority];
    self.nativePlainRouteActive=[ch[@"nativePlainRoute"] boolValue];
    self.currentRemoteHeaders=MediaPlaybackHeadersFromResult(@{@"headers":([ch[@"headers"] isKindOfClass:NSDictionary.class]?ch[@"headers"]:@{})});
    self.currentRemotePlaybackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;
    NSInteger playbackTab=self.nativePlainRouteActive?0:1;if(self.activeTab!=playbackTab)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[playbackTab]];
    self.playbackGeneration += 1;self.selectionVersion++;NSUInteger generation=self.playbackGeneration;self.remotePlaybackFailed=NO;self.nativePlaybackFailed=NO;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];
    NSMutableDictionary *traceFields=[@{@"route_type":self.nativePlainRouteActive?@"user_selected":@"subscription", @"playback_generation":@(generation), @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[traceFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[traceFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];[RuntimeDiagnostics.shared recordEvent:@"remote_playback_start_requested" category:@"playback" fields:traceFields];
    NSTimeInterval requestedAt=self.selectionRequestedAt?:CACurrentMediaTime();self.selectionRequestedAt=0;
    [self stopPlayback];self.remoteFailureRecoveryPending=NO;self.playerExpanded=YES;[self.view setNeedsLayout];
    self.currentRemoteURL=u;self.channelID=ch[@"id"]?:u;self.channelName=ch[@"name"]?:u;self.routeName=self.nativePlainRouteActive?[NSString stringWithFormat:@"%@ · AVPlayer 明文线路",self.requestedNativeRoute[@"provider"]?:@"自选"]:@"订阅";
    if(self.playerTabs.selectedSegmentIndex!=3)self.playerTabs.selectedSegmentIndex=1;[self updatePlayerChannelLogoForChannel:ch];[self selectPlayerPanel];
    self.firstRender=NO;self.retryCount=0;self.playStartedAt=requestedAt;self.firstFrameSeconds=0;
    self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration];[HostPerfMetrics.shared beginPlaybackAttemptWithSessionID:self.currentPlaybackTraceID attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration sourceRevision:self.selectionVersion engine:nil userAction:@"select" expectsVideo:YES];
    [self recordStartupStage:@"teardown"];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    [self reloadActiveCatalogView];[self log:@"订阅起播 %@ [%lu]",CCTVServiceLogAddress(u),(unsigned long)generation];
    NSDictionary *service=[self localServiceForChannel:ch URL:[NSURL URLWithString:u]];
    if(!service){[self startRemoteURL:u generation:generation];return;}
    if(![PyHost isRunningServiceIdentifier:service[@"id"]]){
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · 正在启动本机服务",self.channelName];
        self.infoLabel.text=@"频道请求会启动其所属服务，并在接口就绪后继续播放。";
        NSMutableDictionary *fields=[@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"trigger":@"channel_playback"} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];[RuntimeDiagnostics.shared recordEvent:@"local_service_start_for_playback_requested" category:@"service" fields:fields];
        [self logPluginLine:@"收到频道播放请求，正在启动本机服务" identifier:service[@"id"] name:service[@"name"]];
        __weak typeof(self) weakSelf=self;
        [self changeService:service enabled:YES completion:^(NSError *startError){
            RootViewController *owner=weakSelf;if(!owner||generation!=owner.playbackGeneration)return;
            NSMutableDictionary *result=[fields mutableCopy];result[@"result"]=startError?@"failed":@"accepted";if(startError){result[@"error_domain"]=startError.domain?:@"";result[@"error_code"]=@(startError.code);result[@"error_message"]=startError.localizedDescription?:@"";}[RuntimeDiagnostics.shared recordEvent:@"local_service_start_for_playback_result" category:@"service" fields:result];
            if(startError){[owner failRemoteReadiness:startError generation:generation];return;}
            // startService accepts the worker-thread request before CPython has
            // necessarily finished initializing. Let the cancellable HTTP
            // readiness probe wait for that transition instead of treating the
            // brief "starting" state as a failed service.
            [owner continueRemotePlaybackForURL:u service:service generation:generation];
        }];
        return;
    }
    [self continueRemotePlaybackForURL:u service:service generation:generation];
}
- (void)continueRemotePlaybackForURL:(NSString *)u service:(NSDictionary *)service generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;
    BOOL serviceRunning=[PyHost isRunningServiceIdentifier:service[@"id"]];
    BOOL serviceStarting=[PyHost isStartingServiceIdentifier:service[@"id"]];
    if(!serviceRunning&&!serviceStarting){
        NSString *engine=[service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"python";
        NSError *startupError=[engine isEqualToString:@"python"]?[PyHost startupErrorForServiceIdentifier:service[@"id"]]:nil;
        if(!startupError)startupError=[NSError errorWithDomain:@"CCTVHostService" code:3 userInfo:@{@"NSLocalizedDescriptionKey":@"服务既未运行也未处于启动状态，请检查服务日志后重试。"}];
        [self failRemoteReadiness:startupError generation:generation];return;
    }
    NSNumber *readyAt=self.readyLocalOrigins[[self originForURL:[NSURL URLWithString:u]]];
    if(readyAt && CACurrentMediaTime()-readyAt.doubleValue<5){
        [RuntimeDiagnostics.shared recordEvent:@"playback_readiness_cached" category:@"service" fields:@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"port":service[@"port"]?:@0, @"engine":service[@"engine"]?:@"unknown"}];
        [self recordStartupStage:@"serviceCached"];[self recordStartupStage:@"service"];
        [self startRemoteURL:u generation:generation];return;
    }
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待本机服务",self.channelName];
    self.infoLabel.text=@"正在检查此频道的本机接口，成功后开始请求视频。";
    LocalServiceReadiness *probe=[self readinessForURL:[NSURL URLWithString:u] service:service];self.playbackReadiness=probe;__weak typeof(self) w=self;
    [probe start:^(NSError *error,NSTimeInterval elapsed){
        if(generation!=w.playbackGeneration||w.playbackReadiness!=probe)return;
        w.playbackReadiness=nil;NSMutableDictionary *probeFields=[@{@"correlation_id":w.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:probe.diagnosticSummary];[probeFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];
        probeFields[@"probe_result"]=error?@"failed":@"ready";if(error){probeFields[@"error_domain"]=error.domain?:@"";probeFields[@"error_code"]=@(error.code);probeFields[@"error_message"]=error.localizedDescription?:@"";}[RuntimeDiagnostics.shared recordEvent:@"playback_readiness_probe_result" category:@"service" fields:probeFields];
        if(error){[w logPluginLine:[NSString stringWithFormat:@"播放接口健康检查失败 · %@",[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"]] identifier:service[@"id"] name:service[@"name"]];[w failRemoteReadiness:error generation:generation];return;}
        w.readyLocalOrigins[[w originForURL:[NSURL URLWithString:u]]]=@(CACurrentMediaTime());[w recordStartupStage:@"service"];
        [w logPluginLine:[NSString stringWithFormat:@"播放接口健康检查通过 · %.2f 秒",elapsed] identifier:service[@"id"] name:service[@"name"]];[w log:@"本机服务 HTTP 就绪 %.2fs",elapsed];[w startRemoteURL:u generation:generation];
    }];
}
- (void)failRemoteReadiness:(NSError *)error generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;NSDictionary *service=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];NSMutableDictionary *fields=[@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"failure_stage":error.code==1?@"health_probe_timeout":@"service_start_or_state", @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_readiness_failed" category:@"service" fields:fields];[HostPerfMetrics.shared recordPlaybackAttemptFailed:self.currentRemotePlaybackAttemptID generation:generation engine:service[@"engine"] stage:error.code==1?@"health_probe_timeout":@"service_start_or_state"];self.remotePlaybackFailed=YES;[self endPlaybackPriority];[self.spinner stopAnimating];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 服务未就绪",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;NSString *reason=[HostLogRedactor redactText:error.localizedDescription?:@""];if(service)[self logPluginLine:[NSString stringWithFormat:@"播放接口未就绪 · %@",reason.length?reason:@"无可用错误详情"] identifier:service[@"id"] name:service[@"name"]];[self log:@"本机续播失败 %@",reason];self.infoLabel.text=reason.length?[NSString stringWithFormat:@"%@\n查看该服务日志后重试。",reason]:@"服务未就绪。查看该服务日志后重试。";
}
- (BOOL)startRemoteCicada:(NSString *)address generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration||self.remoteTriedCicada||![MediaPlaybackCicadaAdapter isAvailable])return NO;
    [self stopPlayback];self.remoteTriedCicada=YES;self.remotePlaybackWanted=YES;
    MediaPlaybackCicadaAdapter *adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:address] headers:(self.nativePlainRouteActive?@{@"User-Agent":@"qqlive",@"Referer":@"https://live.cctv.cn/"}:self.currentRemoteHeaders) networkTimeout:12];
    adapter.liveStreamHint=!self.remoteCatchupActive;self.remoteAdapter=adapter;adapter.delegate=self;adapter.playerView.frame=self.playerBox.bounds;adapter.playerView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.playerBox insertSubview:adapter.playerView atIndex:0];
    [adapter prepare];[adapter start];[self updateLiveScreenAwakeState];return YES;
}
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter {
    if(adapter!=self.remoteAdapter)return;self.firstRender=YES;self.remotePlaybackFailed=NO;self.firstFrameSeconds=CACurrentMediaTime()-self.playStartedAt;
    [RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_ready" category:@"playback" fields:@{@"player":@"CicadaPlayer",@"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"",@"correlation_id":self.currentPlaybackTraceID?:@"",@"elapsed_ms":@(MAX(0,self.firstFrameSeconds*1000))}];
    [self.spinner stopAnimating];if(self.remoteCatchupActive){self.titleLabel.text=[NSString stringWithFormat:@"%@ · 回看",self.channelName?:@"频道"];self.titleLabel.hidden=NO;self.infoLabel.text=self.activeCatchupProgramTitle.length?[NSString stringWithFormat:@"回看中 · %@（点更多可返回直播）",self.activeCatchupProgramTitle]:@"回看中 · 点更多可返回直播";self.infoLabel.hidden=NO;self.playerTopScrim.hidden=NO;}else{self.titleLabel.text=self.channelName;}[self recordStartupStage:@"frame"];[self endPlaybackPriority];[self updateNowPlaying];[self startLiveQualityBadgeTimer];
}
- (void)cicadaAdapter:(id)adapter didUpdateVideoSize:(CGSize)size rotation:(NSInteger)rotation {
    (void)rotation;
    if(adapter!=self.remoteAdapter || size.width<=0 || size.height<=0)return;
    self.liveVideoSize=size;
    [self updateLiveQualityBadge];
}
- (void)cicadaAdapter:(id)adapter didUpdateDownloadSpeed:(double)bitsPerSecond {
    if(adapter!=self.remoteAdapter || bitsPerSecond<=0)return;
    self.liveBitrateBps=bitsPerSecond;
    self.livePeakBitrateBps=MAX(self.livePeakBitrateBps,bitsPerSecond);
}
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error {
    if(adapter!=self.remoteAdapter)return;[RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:@{@"player":@"CicadaPlayer",@"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"",@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];[HostPerfMetrics.shared recordPlaybackAttemptFailed:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration engine:@"cicada" stage:@"playback_failed"];self.remotePlaybackFailed=YES;self.remotePlaybackWanted=NO;[self.spinner stopAnimating];
    self.titleLabel.hidden=NO;self.titleLabel.text=self.remoteCatchupActive?@"回看源加载失败 · 可重试或返回直播":@"播放失败 · 可重试或切换线路";self.infoLabel.hidden=NO;self.infoLabel.text=error.localizedDescription;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];
    self.remoteAdapter.delegate=nil;[self.remoteAdapter destroy];self.remoteAdapter=nil;[self setLiveOverlayHidden:NO];[self endPlaybackPriority];
    if(self.remoteRetryCount==0&&CCTVRemotePlaybackErrorCanRetrySameURL(error)){self.remoteRetryCount++;[self startRemoteChannel:@{@"id":self.channelID?:@"",@"name":self.channelName?:@"直播",@"remoteURL":self.currentRemoteURL?:@"",@"headers":self.currentRemoteHeaders?:@{},@"nativePlainRoute":@(self.nativePlainRouteActive),@"catchupReplay":@(self.remoteCatchupActive)}];return;}
    NSDictionary *alternate=self.remoteCatchupActive?[self nextUntriedAlternateCatchupChannel]:[self nextUntriedAlternateChannel];
    if(alternate)[self startRemoteChannel:alternate];
}
- (void)cicadaAdapterDidComplete:(id)adapter {if(adapter!=self.remoteAdapter)return;self.remotePlaybackWanted=NO;[self.playPauseBtn setTitle:@"重播" forState:UIControlStateNormal];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=self.remoteCatchupActive?@"本段回看已播完 · 可重播或点更多返回实时直播":@"播放已结束 · 可重新连接";[self setLiveOverlayHidden:NO];[self updateNowPlaying];}
- (void)startRemoteURL:(NSString *)url generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;[[PlaybackCoordinator shared] acquireSession:(id<PlaybackSession>)self];
    NSDictionary *headers=self.nativePlainRouteActive?@{@"User-Agent":@"qqlive",@"Referer":@"https://live.cctv.cn/"}:(self.currentRemoteHeaders?:@{});
    NSMutableDictionary *descriptor=[@{@"url":url?:@""} mutableCopy];
    if(headers.count)descriptor[@"headers"]=headers;
    NSDictionary *telemetry=self.channelID.length?self.channelTelemetryStore[self.channelID]:nil;
    NSTimeInterval probeAge=NSDate.date.timeIntervalSince1970-[telemetry[@"ts"] doubleValue];
    if(![telemetry[@"probeURL"] isEqual:url]||probeAge<0||probeAge>60)telemetry=nil;
    if([telemetry[@"contentType"] isKindOfClass:NSString.class]&&[telemetry[@"contentType"] length])descriptor[@"probedMIME"]=telemetry[@"contentType"];
    if([telemetry[@"headerBytes"] isKindOfClass:NSData.class])descriptor[@"headerBytes"]=telemetry[@"headerBytes"];
    MediaPlaybackDecodeRoute liveFirst=MediaPlaybackDecodeRouteNextForLiveResult(descriptor,0);
    if(liveFirst==MediaPlaybackDecodeRouteCicadaPlayer&&[self startRemoteCicada:url generation:generation])return;
    if(liveFirst==MediaPlaybackDecodeRouteNone){[self.spinner stopAnimating];self.remotePlaybackFailed=YES;self.titleLabel.hidden=NO;self.titleLabel.text=@"该直播源没有可用的播放方式";self.infoLabel.hidden=NO;self.infoLabel.text=@"可重试或切换线路";[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;return;}
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL URLWithString:url] options:headers.count?@{@"AVURLAssetHTTPHeaderFieldsKey":headers,@"AVURLAssetPreferPreciseDurationAndTimingKey":@NO}:@{@"AVURLAssetPreferPreciseDurationAndTimingKey":@NO}];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];item.preferredForwardBufferDuration=1.0;
    // 直播 AVPlayer 回退路径也按默认清晰度偏好约束 HLS 自适应码率，
    // 与影视播放页的映射一致（smooth 1.5M / hd 4M / uhd 8M，auto 不限）。
    NSString *preferredQuality=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    if([preferredQuality isEqualToString:@"smooth"])item.preferredPeakBitRate=1500000;
    else if([preferredQuality isEqualToString:@"hd"])item.preferredPeakBitRate=4000000;
    else if([preferredQuality isEqualToString:@"uhd"])item.preferredPeakBitRate=8000000;
    self.avPlayer=[AVPlayer playerWithPlayerItem:item];self.avPlayer.automaticallyWaitsToMinimizeStalling=NO;self.avPlayer.allowsExternalPlayback=YES;self.avPlayer.usesExternalPlaybackWhileExternalScreenIsActive=YES;self.remotePlaybackWanted=YES;
    self.avLayer=[AVPlayerLayer playerLayerWithPlayer:self.avPlayer];self.avLayer.frame=self.playerBox.bounds;self.avLayer.videoGravity=AVLayerVideoGravityResizeAspect;[self.playerBox.layer insertSublayer:self.avLayer atIndex:0];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVItemStatusContext];
    self.avKeepUpObserved=YES;
    [item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:kAVItemStatusContext];
    self.avLayerObserved=YES;
    [self.avLayer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVLayerFrameContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
    if(generation!=self.playbackGeneration || item!=self.avPlayer.currentItem)return;[self startRemoteProgressWatchdogForItem:item generation:generation];[self recordStartupStage:@"prepareCall"];
    if(@available(iOS 10.0,*))[self.avPlayer playImmediatelyAtRate:1.0];
    else [self.avPlayer play];
    __weak typeof(self) w=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(generation!=w.playbackGeneration||item!=w.avPlayer.currentItem||!w.firstRender)return;item.preferredForwardBufferDuration=4.0;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        // A terminal AVPlayerItem failure has its own recovery path. Do not let
        // the first-frame watchdog overwrite that result with a second, false
        // timeout after retry/alternate-source recovery has already stopped.
        if(generation!=w.playbackGeneration||item!=w.avPlayer.currentItem||
           item.status==AVPlayerItemStatusFailed||!w.remotePlaybackWanted||w.firstRender)return;
        BOOL hasAudio=NO,hasVideo=NO;
        for(AVPlayerItemTrack *track in item.tracks){
            if(!track.enabled)continue;
            NSString *type=track.assetTrack.mediaType;
            if([type isEqualToString:AVMediaTypeAudio])hasAudio=YES;
            else if([type isEqualToString:AVMediaTypeVideo])hasVideo=YES;
        }
        double audioPosition=CMTimeGetSeconds(w.avPlayer.currentTime);
        if(hasAudio&&!hasVideo&&isfinite(audioPosition)&&audioPosition>0.5){
            [w.spinner stopAnimating];
            w.titleLabel.hidden=NO;w.titleLabel.text=[NSString stringWithFormat:@"%@ · 音频播放中",w.channelName?:@"频道"];
            w.infoLabel.hidden=NO;w.infoLabel.text=@"当前来源为音频流";
            [w endPlaybackPriority];
            return;
        }
        NSDictionary *liveDescriptor=@{@"url":w.currentRemoteURL?:@"",@"headers":w.currentRemoteHeaders?:@{}};
        if(MediaPlaybackDecodeRouteNextForLiveResult(liveDescriptor,MediaPlaybackDecodeRouteAttemptedAVPlayer)==MediaPlaybackDecodeRouteCicadaPlayer&&[w startRemoteCicada:w.currentRemoteURL generation:generation])return;
        NSMutableDictionary *timeoutFields=[@{@"player":@"AVPlayer", @"timeout_seconds":@12, @"playback_generation":@(generation), @"playback_attempt_id":w.currentRemotePlaybackAttemptID?:@"", @"correlation_id":w.currentPlaybackTraceID?:@""} mutableCopy];[timeoutFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(w.currentRemoteHeaders)];[timeoutFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:w.currentRemoteURL])];CCTVAddAVPlayerFailureFields(timeoutFields,item,w.avPlayer,item.error);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_timeout" category:@"playback" fields:timeoutFields];
        [w.spinner stopAnimating];w.remotePlaybackFailed=YES;w.titleLabel.hidden=NO;w.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待视频首帧",w.channelName];w.infoLabel.hidden=NO;w.infoLabel.text=@"仍可等待，或点按“重试”重新连接";[w.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];w.playPauseBtn.enabled=YES;NSDictionary *service=[w localServiceForURL:[NSURL URLWithString:w.currentRemoteURL?:@""]];if(service)[w logPluginLine:@"接口已请求，但 12 秒内未收到视频首帧" identifier:service[@"id"] name:service[@"name"]];[w log:@"订阅 12 秒未渲染首帧（并非播放器就绪时间）"];
    });
}

- (void)avItemStalled:(NSNotification *)n {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self avItemStalled:n];});return;}
    if(n.object!=self.avPlayer.currentItem)return;
    self.liveStallCount++;
    [self log:@"订阅缓冲不足 · 进度 %.2fs · %@",CMTimeGetSeconds(self.avPlayer.currentTime),self.remotePlaybackWanted?@"等待分片后续播":@"用户已暂停"];
    // Keep the current item/session. Recreating it here repeats the first frame.
    if(self.remotePlaybackWanted)[self.avPlayer play];
}

- (void)recoverRemoteFailureForItem:(AVPlayerItem *)item error:(NSError *)error {
    if(item==self.avPlayer.currentItem&&self.remotePlaybackWanted&&[self startRemoteCicada:self.currentRemoteURL generation:self.playbackGeneration])return;
    if(!item || item!=self.avPlayer.currentItem || !self.remotePlaybackWanted || self.remoteFailureRecoveryPending)return;
    BOOL retrySameURL=self.remoteRetryCount<1&&CCTVRemotePlaybackErrorCanRetrySameURL(error);
    NSMutableDictionary *failureFields=[@{@"player":@"AVPlayer", @"stage":@"item_failure", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"retry_count":@(self.remoteRetryCount), @"recovery_action":retrySameURL?@"retry_same_url":@"try_alternate_or_stop", @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(self.playbackGeneration)} mutableCopy];[failureFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[failureFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL])];CCTVAddAVPlayerFailureFields(failureFields,item,self.avPlayer,error);
    failureFields[@"route_type"]=self.nativePlainRouteActive?@"user_selected":@"subscription";
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:failureFields];
    self.remoteFailureRecoveryPending=YES;
    [self.readyLocalOrigins removeObjectForKey:[self originForURL:[NSURL URLWithString:self.currentRemoteURL]]];
    [self endPlaybackPriority];[self.spinner stopAnimating];
    NSString *safeReason=[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"];NSDictionary *failedService=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];if(failedService)[self logPluginLine:[NSString stringWithFormat:@"播放器请求失败 · %@",safeReason] identifier:failedService[@"id"] name:failedService[@"name"]];[self log:@"订阅播放失败 %@",safeReason];
    if(retrySameURL){
        self.remoteRetryCount++;NSUInteger generation=self.playbackGeneration;NSString *url=self.currentRemoteURL?:@"";
        NSDictionary *retry=@{@"id":self.channelID?:url,@"name":self.channelName?:url,@"remoteURL":url,@"nativePlainRoute":@(self.nativePlainRouteActive),@"headers":self.currentRemoteHeaders?:@{},@"catchupReplay":@(self.remoteCatchupActive)};
        [self log:@"同源自动恢复 1/1，保留一次短重试"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(generation!=self.playbackGeneration || item!=self.avPlayer.currentItem || !self.remotePlaybackWanted || ![url isEqualToString:self.currentRemoteURL])return;
            self.remoteFailureRecoveryPending=NO;[self startRemoteChannel:retry];
        });
        return;
    }
    [self tryAlternateSource];
}

- (void)avItemFailed:(NSNotification *)n {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self avItemFailed:n];});return;}
    if (n.object != self.avPlayer.currentItem) return;
    NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self recoverRemoteFailureForItem:n.object error:e];
}

- (void)avItemDidPlayToEnd:(NSNotification *)n {if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self avItemDidPlayToEnd:n];});return;}if(n.object!=self.avPlayer.currentItem)return;self.remotePlaybackWanted=NO;[self.spinner stopAnimating];[self.playPauseBtn setTitle:@"重播" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.playerTopScrim.hidden=NO;self.titleLabel.text=self.remoteCatchupActive?[NSString stringWithFormat:@"%@ · 回看已播完",self.channelName?:@"频道"]:[NSString stringWithFormat:@"%@ · 播放已结束",self.channelName?:@"频道"];self.infoLabel.text=self.remoteCatchupActive?@"本段回看已播完 · 可重播或点更多返回实时直播":@"播放已结束 · 可重新连接";[self setLiveOverlayHidden:NO];[self updateNowPlaying];}

- (NSDictionary *)nextUntriedAlternateChannel {
    // SDK 播放失败耗尽重试后也可复用：按同名找一条未试过、且订阅源未被禁用的远端地址。
    // 自选明文线路不自动换源；单频道最多试 4 条。
    if(self.nativePlainRouteActive || self.requestedNativeRoute || self.remoteAttemptedURLs.count>=4)return nil;
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSString *activeCanonical=CCTVRouteGroupKey([self channelWithID:self.channelID]?:@{@"id":self.channelID?:@""});
    for (NSDictionary *channel in self.allChannels) {
        NSString *candCanonical=CCTVRouteGroupKey(channel);
        BOOL sameStation=activeCanonical.length&&[activeCanonical isEqualToString:candCanonical];
        if(!sameStation)continue;
        NSString *url=[self stableURLKey:channel[@"remoteURL"]];
        if(!url.length || [self.remoteAttemptedURLs containsObject:url])continue;
        NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];[owners minusSet:disabled];
        if(!owners.count)continue;
        return channel;
    }
    return nil;
}
- (void)tryAlternateSource {
    if(!self.remotePlaybackWanted)return;
    NSDictionary *alternate=self.remoteCatchupActive?[self nextUntriedAlternateCatchupChannel]:[self nextUntriedAlternateChannel];
    if(alternate){
        self.remoteRetryCount=0;self.remoteFailureRecoveryPending=NO;
        [self log:self.remoteCatchupActive?@"回看换源重试 %lu/4":@"换源重试 %lu/4",(unsigned long)self.remoteAttemptedURLs.count+1];
        [self startRemoteChannel:alternate];
        return;
    }
    self.remotePlaybackWanted=NO;self.remotePlaybackFailed=YES;[self.avPlayer pause];[self.spinner stopAnimating];[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;
    self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;
    self.titleLabel.text=self.remoteCatchupActive?[NSString stringWithFormat:@"%@ · 回看失败",self.channelName?:@"频道"]:[NSString stringWithFormat:@"%@ · 播放失败",self.channelName?:@"频道"];
    self.infoLabel.text=self.remoteCatchupActive?@"回看源加载失败 · 点按“重试”或点更多返回实时直播":(self.nativePlainRouteActive?@"所选线路播放失败 · 点按“重试”或在线路面板换线":@"自动换源已结束 · 点按“重试”再试一次");
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)change context:(void *)context {
    if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(), ^{[self observeValueForKeyPath:kp ofObject:obj change:change context:context];});return;}
    if(context==kAVLayerFrameContext){
        if(obj!=self.avLayer||!self.avLayer.readyForDisplay||self.firstRender)return;
        NSURL *playingURL=[NSURL URLWithString:self.currentRemoteURL];NSDictionary *service=[self localServiceForURL:playingURL];
        if(service && [PyHost isRunningServiceIdentifier:service[@"id"]])self.readyLocalOrigins[[self originForURL:playingURL]]=@(CACurrentMediaTime());
        self.firstRender=YES;self.remotePlaybackFailed=NO;
        // Round 41 starts AVPlayer with automaticallyWaitsToMinimizeStalling=NO for a fast first frame; restore it once the frame is on screen so later stalls rebuffer instead of stalling the session.
        self.avPlayer.automaticallyWaitsToMinimizeStalling=YES;if(self.remotePlaybackWanted&&self.avPlayer.rate==0)[self.avPlayer playImmediatelyAtRate:1.0];[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;[self endPlaybackPriority];self.firstFrameSeconds=CACurrentMediaTime()-self.playStartedAt;[self recordStartupStage:@"frame"];
        NSMutableDictionary *frameFields=[@{@"player":@"AVPlayer", @"elapsed_ms":@((NSInteger)(self.firstFrameSeconds*1000)), @"playback_generation":@(self.playbackGeneration), @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[frameFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[frameFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL])];CCTVAddAVPlayerFailureFields(frameFields,self.avPlayer.currentItem,self.avPlayer,nil);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame" category:@"playback" fields:frameFields];if(service)[self logPluginLine:[NSString stringWithFormat:@"视频首帧已渲染 · %.2f 秒 · %@",self.firstFrameSeconds,self.startupTrace.summary] identifier:service[@"id"] name:service[@"name"]];
        [self.spinner stopAnimating];if(self.remoteCatchupActive){self.titleLabel.text=[NSString stringWithFormat:@"%@ · 回看",self.channelName?:@"频道"];self.titleLabel.hidden=NO;self.infoLabel.text=self.activeCatchupProgramTitle.length?[NSString stringWithFormat:@"回看中 · %@（点更多可返回直播）",self.activeCatchupProgramTitle]:@"回看中 · 点更多可返回直播";self.infoLabel.hidden=NO;self.playerTopScrim.hidden=NO;}else{self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;self.playerTopScrim.hidden=YES;}[self loadPlayerChannelLogoAfterFirstFrame];[self captureLivePreviewSnapshotForChannelID:self.channelID];[self startLiveQualityBadgeTimer];[self updateNowPlaying];[self refreshNowNext];[self restartEPGTimer];
        [self log:@"订阅视频首帧 %.2fs · %@",self.firstFrameSeconds,self.startupTrace.summary];return;
    }
    if(context==kAVItemStatusContext){
        AVPlayerItem *item=obj;if(item!=self.avPlayer.currentItem)return;
        if([kp isEqualToString:@"playbackLikelyToKeepUp"]){
            if(item.playbackLikelyToKeepUp && self.remotePlaybackWanted && self.avPlayer.rate==0){[self.avPlayer play];[self log:@"订阅分片恢复，继续原播放会话"];}return;
        }
        if(item.status==AVPlayerItemStatusReadyToPlay){[self recordStartupStage:@"itemReady"];[self log:@"订阅播放器就绪，继续等待视频渲染"];}else if(item.status==AVPlayerItemStatusFailed){self.titleLabel.text=[NSString stringWithFormat:@"%@ · 失败，尝试恢复",self.channelName];[self recoverRemoteFailureForItem:item error:item.error];}
        return;
    }
    [super observeValueForKeyPath:kp ofObject:obj change:change context:context];
}

- (void)showNativeRouteError:(NSError *)error channel:(NSDictionary *)channel {
    NSString *message=error.localizedDescription?:@"SDK 未接受所选线路。";
    [self log:@"线路配置失败：%@",message];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"自选线路无法起播" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) owner=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"使用 SDK 自动线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner playChannel:channel route:nil];}]];
    [(self.navigationController.topViewController?:self) presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 监视

- (void)startWatchdog {
    [self.watchdog invalidate];
    self.watchdogTicks = 0;
    self.nativeAttemptStartedAt=CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        RootViewController *strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf tick:timer];
    }];
    self.watchdog.tolerance = 0.1;
}
- (BOOL)recoverNativeStartupForReason:(NSString *)reason {
    if(self.directNativeRouteActive || self.nativeTimeShiftActive || self.nativeTransitionKind.length || self.firstRender || self.nativePlaybackFailed || self.nativeStartupRecoveryUsed || !self.currentPlayer || !self.channelID.length)return NO;
    NSString *channelID=self.channelID;
    NSTimeInterval now=CACurrentMediaTime();
    NSMutableDictionary *fields=[@{@"reason":reason?:@"startup_timeout", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"elapsed_seconds":@(MAX(0,now-self.playStartedAt)), @"attempt_seconds":@(MAX(0,now-self.nativeAttemptStartedAt)), @"startup_trace":self.startupTrace.summary?:@""} mutableCopy];
    if(![ProfileStore isHTTP:channelID]&&channelID.length<=128)fields[@"sdk_channel_id"]=channelID;
    [RuntimeDiagnostics.shared recordEvent:@"native_startup_recovery_started" category:@"playback" fields:fields];
    self.nativeStartupRecoveryUsed=YES;
    self.nativeSafeStartupActive=YES;
    self.playbackGeneration++;
    [self log:@"SDK 自动起播 %@，使用全新实例与默认配置恢复一次 · %@",reason?:@"超时",self.startupTrace.summary];
    [self stopPlayback];
    [self.nativePreloader cancel];
    self.sdkPlayer=nil;
    self.sdkPlayerUsed=NO;
    self.currentRemotePlaybackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration];[HostPerfMetrics.shared beginPlaybackAttemptWithSessionID:self.currentPlaybackTraceID attemptID:self.currentRemotePlaybackAttemptID generation:self.playbackGeneration sourceRevision:self.selectionVersion engine:nil userAction:@"auto_recovery" expectsVideo:YES];
    [self recordStartupStage:@"recovery"];
    self.stallReported=NO;
    [self playViaSDK:channelID title:self.channelName?:channelID];
    return YES;
}

- (void)tick:(NSTimer *)timer {
    if(timer!=self.watchdog)return;
    self.watchdogTicks += 1;
    if (!self.currentPlayer || self.nativePlaybackFailed) { [timer invalidate]; self.watchdog=nil; return; }
    [self attachVideoView];
    if (self.firstRender) { [timer invalidate]; self.watchdog=nil; return; }
    NSTimeInterval now=CACurrentMediaTime();
    NSTimeInterval elapsed=now-self.playStartedAt;
    NSTimeInterval attemptElapsed=self.nativeAttemptStartedAt>0?now-self.nativeAttemptStartedAt:elapsed;
    if(!self.directNativeRouteActive && !self.nativeTimeShiftActive && [self.startupTrace shouldRecoverMissingSetupAtTime:now alreadyRetried:self.nativeStartupRecoveryUsed failed:self.nativePlaybackFailed]){
        if([self recoverNativeStartupForReason:@"vdn_without_setup"])return;
    }
    if(elapsed>=10&&!self.stallReported){
        self.stallReported=YES;BOOL vdnDone=self.startupTrace.stages[@"vdn"]!=nil;NSString *waitState=self.directNativeRouteActive?@"自选地址等待视频数据":(vdnDone?@"等待视频数据":@"调度等待中");
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@",self.channelName,waitState];
        [self log:@"原生起播等待 %.2fs · %@ · %@",elapsed,self.directNativeRouteActive?@"SDK URL 路径":(vdnDone?@"VDN 已完成":@"VDN 尚未完成"),self.startupTrace.summary];
    }
    if(attemptElapsed>=25 || elapsed>=50){
        if(self.nativeTimeShiftActive || self.nativeTransitionKind.length){
            [timer invalidate];self.watchdog=nil;
            [self failNativeTransition:@"时移定位响应超时，已保留当前直播会话。"];
            return;
        }
        if(elapsed<50 && [self recoverNativeStartupForReason:@"first_frame_timeout"])return;
        [timer invalidate];[self log:@"%@ · 总计 %.2fs / 本次 %.2fs · %@",self.nativeStartupRecoveryUsed?@"SDK 默认配置恢复后仍未首帧":@"原生起播等待超时",elapsed,attemptElapsed,self.startupTrace.summary];
        [self displayNativePlaybackFailure:@"起播超时" error:nil];
        [self stopPlayback];
    }

}

#pragma mark - 通用调用

- (id)callClass:(Class)cls sel:(NSString *)name args:(NSArray *)args {
    return [self invokeTarget:cls selector:NSSelectorFromString(name) args:args];
}

- (id)call:(id)obj sel:(NSString *)name {
    return [self invokeTarget:obj selector:NSSelectorFromString(name) args:@[]];
}

- (id)call:(id)obj sel:(NSString *)name args:(NSArray *)args {
    return [self invokeTarget:obj selector:NSSelectorFromString(name) args:args];
}

- (id)invokeTarget:(id)target selector:(SEL)sel args:(NSArray *)args {
    if (!target || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil; // 异常边界只包了 invoke；signature 为 nil 时
    // invocationWithMethodSignature:nil 会直接抛异常，先判空返回。
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        id v = args[i];
        if (v == NSNull.null) { id z = nil; [inv setArgument:&z atIndex:i + 2]; continue; }
        if (strcmp(t, "@") == 0 || strcmp(t, "@?") == 0) {
            id a = v; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "B") == 0 || strcmp(t, "c") == 0) {
            char a = [v boolValue]; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "q") == 0 || strcmp(t, "l") == 0) {
            long long a = [v longLongValue]; [inv setArgument:&a atIndex:i + 2];
        }
    }
    @try { [inv invoke]; } @catch (NSException *e) {
        [self log:@"调用 %@ 异常 %@", NSStringFromSelector(sel), e.reason];
        return nil;
    }
    const char *rt = sig.methodReturnType;
    if (rt[0] == '@') { void *p = NULL; [inv getReturnValue:&p]; return (__bridge id)p; }
    if (rt[0] == 'B' || rt[0] == 'c') { char r = 0; [inv getReturnValue:&r]; return @(r != 0); }
    return nil;
}

#pragma mark - SDK 回调

- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player loadStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteLoadState:state];
    [self attachVideoView];
    if (state == 4) {                     // PrepareDone
        [self recordStartupStage:@"prepared"];
        if(self.nativeTransitionKind.length || self.nativeTimeShiftActive || self.timeshiftController.state == CCTVTimeshiftStateSeeking || self.timeshiftController.state == CCTVTimeshiftStatePlayingReplay || self.timeshiftController.state == CCTVTimeshiftStateReturningToLive){
            [self log:@"PrepareDone（%@）：由时移/回看会话驱动，不重复调用 play", self.nativeTransitionKind ?: @"时移"];
            [self ensureNativeTimeshiftPlayingForTrigger:@"timeshift_prepared"];
            if(self.timeshiftController.state == CCTVTimeshiftStatePlayingReplay || self.timeshiftController.seekLatency > 0){
                [self completeNativeFirstRenderIfNeededForTrigger:@"timeshift_prepared"];
            }
        } else if(!self.firstRender){
            [self log:@"PrepareDone → play"];
            [self call:self.currentPlayer sel:@"play"];
        } else [self log:@"PrepareDone：已自动出画面，不重复 play"];
    } else if (state == 5) {              // SeekSucceed
        [self recordStartupStage:@"seekSucceed"];
        if(self.nativeTransitionKind.length || self.nativeTimeShiftActive){
            [self ensureNativeTimeshiftPlayingForTrigger:@"seek_succeed"];
        }
        if(!self.firstRender && (self.nativeTransitionKind.length || self.nativeTimeShiftActive)){
            [self completeNativeFirstRenderIfNeededForTrigger:@"seek_succeed"];
        }
    } else if (state == 13) {
        [self log:@"加载取消"];
    }
}

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
    if (!self.firstRender && (self.nativeTransitionKind.length || self.nativeTimeShiftActive)) {
        [self completeNativeFirstRenderIfNeededForTrigger:@"periodic_tick"];
    }
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSTimeInterval received=CACurrentMediaTime();NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self log:@"SDK VDN callback %@ · raw +%.3fs · mainLag %.3fs",@(state),received-self.playStartedAt,CACurrentMediaTime()-received];[self player:player vdnRequestStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    if (state == 3) { [self recordStartupStage:@"vdn"]; [self log:@"VDN 成功"]; }
    else if (state == 2) [self log:@"VDN 失败"];
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (![NSThread isMainThread]) { NSTimeInterval received=CACurrentMediaTime();NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self log:@"SDK stat callback %@ · raw +%.3fs · mainLag %.3fs",@(event),received-self.playStartedAt,CACurrentMediaTime()-received];[self player:player statEvent:event value:value]; }); return; }
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteStatEvent:event];
    if((event==1 || event==2) && (self.nativeTimeShiftActive || self.nativeTransitionKind.length || self.timeshiftController.state==CCTVTimeshiftStateSeeking || self.timeshiftController.state==CCTVTimeshiftStateReturningToLive) && self.startupTrace.stages[@"prepared"]==nil){
        self.firstRender=NO;
        if(!self.nativeTransitionKind.length)self.nativeTransitionKind=self.nativeTimeShiftActive?(self.activeCatchupEnd>0?@"回看":@"时移"):@"返回直播";
    }
    if(event==1)[self recordStartupStage:@"sdkStartup"];
    if(event==2) {
        [self recordStartupStage:@"setup"];
        NSUInteger generation=self.playbackGeneration;NativeStartupTuner *tuner=self.nativeStartupTuner;
        // Setup is emitted immediately after core creation, BEFORE the SDK installs
        // its DRM config. Run next turn to preserve that completed config.
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=self.playbackGeneration || player!=self.currentPlayer || self.firstRender || !tuner || tuner!=self.nativeStartupTuner)return;
            BOOL applied=[tuner applyToPlayer:player];
            [self log:@"%@",tuner.summary];if(applied)[self recordStartupStage:@"bufferTuned"];
        });
    }
    if (event == 3 && !self.firstRender) {
        self.firstFrameSeconds = CACurrentMediaTime() - self.playStartedAt;
        self.firstRender = YES;self.nativePlaybackFailed=NO;self.nativeSafeStartupActive=NO;
        [self.watchdog invalidate];self.watchdog=nil;
        if(!self.nativeTimeShiftActive)[self.timeshiftController noteReturnedToLive];
        if([self.nativeStartupTuner restore])[self log:@"首帧后已恢复 SDK 稳态缓冲"];
        [self endPlaybackPriority];
        [self.spinner stopAnimating];
        self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];
        self.titleLabel.text = self.nativeTimeShiftActive ? [NSString stringWithFormat:@"%@ · 回看", self.channelName ?: @"频道"] : self.channelName;
        if(!self.nativeTimeShiftActive){self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;}if(!self.nativeTimeShiftActive){self.playerTopScrim.hidden=YES;}
        if(self.nativeTimeShiftActive){
            self.titleLabel.hidden=NO;
            NSTimeInterval behind=self.timeshiftController.behindLiveSeconds>0?self.timeshiftController.behindLiveSeconds:(self.activeCatchupStart>0?MAX(0,NSDate.date.timeIntervalSince1970-self.activeCatchupStart):0);
            NSString *prog=self.activeCatchupProgramTitle.length?[NSString stringWithFormat:@" · %@",self.activeCatchupProgramTitle]:@"";
            self.infoLabel.text=behind>0?[NSString stringWithFormat:@"回看中%@ · 距直播 %.0f 分钟（点更多可返回直播）",prog,MAX(1.0,round(behind/60.0))]:[NSString stringWithFormat:@"回看中%@（点更多可返回直播）",prog];
            self.infoLabel.hidden=NO;
            self.playerTopScrim.hidden=NO;
        }
        [self loadPlayerChannelLogoAfterFirstFrame];
        [self captureLivePreviewSnapshotForChannelID:self.channelID];
        [self startLiveQualityBadgeTimer];
        [self recordStartupStage:@"frame"];
        [RuntimeDiagnostics.shared recordEvent:@"playback_first_frame" category:@"playback" fields:@{@"player":@"CNPlayerSDK", @"elapsed_ms":@((NSInteger)(self.firstFrameSeconds*1000)), @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.requestedNativeRoute?@"user_selected":@"sdk_auto"}];
        if(self.nativeTransitionKind.length){[self log:@"原生%@首帧 %.2fs · %@",self.nativeTransitionKind,self.firstFrameSeconds,self.startupTrace.summary];self.nativeTransitionKind=nil;}
        else [self log:@"首帧渲染 %.2fs · %@", self.firstFrameSeconds,self.startupTrace.summary];
        [self log:@"SDK 报告节点 %@ · 请求线路 %@",[NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer],self.routeName?:@"自动"];
        [self updateNowPlaying];
        [self refreshVisibleChannelSelectionFromID:nil toID:self.channelID];
        [self refreshNowNext];
        [self restartEPGTimer];
        if([self.pendingNativeReplayProgram[@"channelID"] isEqualToString:self.channelID]){
            NSDictionary *pendingReplay=self.pendingNativeReplayProgram;
            self.pendingNativeReplayProgram=nil;
            self.activeCatchupProgramTitle=[pendingReplay[@"title"] isKindOfClass:NSString.class]&&[pendingReplay[@"title"] length]?pendingReplay[@"title"]:nil;
            self.activeCatchupStart=[pendingReplay[@"start"] doubleValue];
            self.activeCatchupEnd=[pendingReplay[@"end"] doubleValue];
            dispatch_async(dispatch_get_main_queue(),^{
                [self seekNativeStart:[pendingReplay[@"start"] doubleValue] end:[pendingReplay[@"end"] doubleValue]];
            });
        }
        NSUInteger generation=self.playbackGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self prepareNextNativeChannelForGeneration:generation];});
    }
}

- (void)refreshVisibleChannelSelectionFromID:(NSString *)previousID toID:(NSString *)currentID {
    if (!self.channelGrid && !self.table) return;
    NSMutableArray<NSIndexPath *> *gridPaths = [NSMutableArray array];
    for (NSIndexPath *ip in self.channelGrid.indexPathsForVisibleItems ?: @[]) {
        if ((NSUInteger)ip.item < self.shownChannels.count) {
            NSString *cid = self.shownChannels[ip.item][@"id"];
            if ((previousID.length && [cid isEqualToString:previousID]) ||
                (currentID.length && [cid isEqualToString:currentID])) {
                [gridPaths addObject:ip];
            }
        }
    }
    if (gridPaths.count) {
        [UIView performWithoutAnimation:^{
            [self.channelGrid reloadItemsAtIndexPaths:gridPaths];
        }];
    } else if (self.channelGrid.window && self.shownChannels.count <= 40) {
        [self.channelGrid reloadData];
    }
    NSMutableArray<NSIndexPath *> *tablePaths = [NSMutableArray array];
    for (NSIndexPath *ip in self.table.indexPathsForVisibleRows ?: @[]) {
        if ((NSUInteger)ip.row < self.shownChannels.count) {
            NSString *cid = self.shownChannels[ip.row][@"id"];
            if ((previousID.length && [cid isEqualToString:previousID]) ||
                (currentID.length && [cid isEqualToString:currentID])) {
                [tablePaths addObject:ip];
            }
        }
    }
    if (tablePaths.count) {
        [UIView performWithoutAnimation:^{
            [self.table reloadRowsAtIndexPaths:tablePaths withRowAnimation:UITableViewRowAnimationNone];
        }];
    }
}

- (void)ensureNativeTimeshiftPlayingForTrigger:(NSString *)trigger {
    if (!self.currentPlayer || self.avPlayer || self.nativePlaybackFailed || self.livePlaybackSuspendedForNavigation || self.nativeUserPaused) return;
    [self guardedSetValue:@YES forKey:@"autoPlay" onObject:self.currentPlayer];
    [self attachVideoView];
    [self call:self.currentPlayer sel:@"play"];
    self.playPauseBtn.enabled = YES;
    [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    [self syncPlayPauseButtonIcon];
}

- (void)completeNativeFirstRenderIfNeededForTrigger:(NSString *)trigger {
    [self ensureNativeTimeshiftPlayingForTrigger:trigger];

}

- (void)prepareNextNativeChannelForGeneration:(NSUInteger)generation {
    if(generation!=self.playbackGeneration || !self.firstRender || self.nativeTimeShiftActive || !self.currentPlayer || self.avPlayer || self.directNativeRouteActive || !CCTVBoolPreference(@"preloadNativeChannel",YES) || ![HostMemoryBudgetCoordinator shouldAllowBackgroundWarmup] || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    NSArray *sourceList=self.shownChannels.count>=2?self.shownChannels:self.allChannels;
    NSMutableArray *native=[NSMutableArray array];
    for(NSDictionary *channel in sourceList)if(![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:channel[@"id"]])[native addObject:channel];
    if(native.count<2 && sourceList!=self.allChannels){
        [native removeAllObjects];
        for(NSDictionary *channel in self.allChannels)if(![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:channel[@"id"]])[native addObject:channel];
    }
    NSUInteger index=[native indexOfObjectPassingTest:^BOOL(NSDictionary *channel,NSUInteger i,BOOL *stop){return [channel[@"id"] isEqualToString:self.channelID];}];
    if(index==NSNotFound || native.count<2)return;
    NSDictionary *next=native[(index+1)%native.count];[self.nativePreloader prepareChannel:next[@"id"] title:next[@"name"]];
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playBackStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer || self.nativePlaybackFailed) return;
    if (state == 1) { self.nativeUserPaused = NO; [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal]; [self syncPlayPauseButtonIcon]; }
    if (state == 2) {
        if (!self.nativeUserPaused && (self.nativeTimeShiftActive || self.nativeTransitionKind.length || self.timeshiftController.state == CCTVTimeshiftStateSeeking || self.timeshiftController.state == CCTVTimeshiftStatePlayingReplay || self.timeshiftController.state == CCTVTimeshiftStateReturningToLive)) {
            [self ensureNativeTimeshiftPlayingForTrigger:@"playback_paused_during_timeshift"];
            return;
        }
        [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];
        [self syncPlayPauseButtonIcon];
    }
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playbackFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    if(self.nativeRetryPending){[self log:@"忽略自动重连期间重复的播放器错误回调"];return;}
    if(self.nativePlaybackFailed)return;
    self.nativeSessionDelegate=nil;self.nativeSessionID++;
    [self guardedSetValue:nil forKey:@"delegate" onObject:player];
    if(player!=self.avPlayer)[self call:player sel:@"stop"];
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"播放失败 %ld %@", (long)error.code, error.localizedDescription];
    if(self.nativeTransitionKind.length || self.nativeTimeShiftActive){self.nativeTransitionKind=nil;[self.nativeTimeshift cancel];[self log:@"时移操作失败，请返回直播或重新选台"];[self displayNativePlaybackFailure:@"时移 / 回看失败" error:error];return;}
    if(self.directNativeRouteActive && self.requestedNativeRoute && CCTVRouteRequiresSDK(self.requestedNativeRoute) && error.code == -12909 && self.channelID.length && !self.nativeStartupRecoveryUsed){
        self.nativeStartupRecoveryUsed=YES;
        [self log:@"自选线路失败 -12909，自动切下一条线路"];[self retryPlaybackWithAlternateSource];
        return;
    }
    if (error.code >= 4000 && error.code < 5000) {
        [self log:@"参数/调度错误不自动重试，请查看错误详情"];
        [self displayNativePlaybackFailure:@"播放被拒绝" error:error];
        return;
    }
    if (self.retryCount < 2) {
        self.retryCount += 1;
        self.nativeRetryPending=YES;
        double delay = self.retryCount == 1 ? 1.0 : 3.0;
        [self log:@"断流重连 第 %ld 次（%.0fs 后）", (long)self.retryCount, delay];
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · 正在重连",self.channelName?:@"频道"];self.titleLabel.hidden=NO;self.infoLabel.text=[NSString stringWithFormat:@"第 %ld / 2 次自动恢复",(long)self.retryCount];self.infoLabel.hidden=NO;[self.spinner startAnimating];[self.playPauseBtn setTitle:@"重连中" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];self.playPauseBtn.enabled=NO;
        NSUInteger generation = self.playbackGeneration;
        NSString *cid = self.channelID;
        NSString *name = self.channelName;
        BOOL remotePlayback = self.avPlayer != nil;
        NSString *remoteURL = remotePlayback ? self.currentRemoteURL : nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.playbackGeneration || player != self.currentPlayer || ![cid isEqualToString:self.channelID]) return;
            if (remotePlayback) {
                self.nativeRetryPending=NO;
                if (remoteURL.length) [self playRemote:@{@"id": cid, @"name": name ?: cid, @"remoteURL": remoteURL}];
            } else {
                self.playbackGeneration+=1;self.stallReported=NO;
                self.playStartedAt=CACurrentMediaTime();self.firstRender=NO;self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
                [self playSelectedNativeRouteOrChannel];
            }
        });
    }else{
        // SDK 2 次重连耗尽：仍有未试过的同名订阅源时改走 AVPlayer，不直接判死刑；
        // 订阅源也耗尽才显示失败。自选明文线路不自动换源（见 nextUntriedAlternateChannel）。
        NSDictionary *alternate=[self nextUntriedAlternateChannel];
        if(alternate){[self log:@"SDK 播放失败，改用订阅源地址继续播放"];[self startRemoteChannel:alternate];}
        else [self displayNativePlaybackFailure:@"播放失败" error:error];
    }
}

- (void)retryPlaybackWithAlternateSource {
    // 失败后换源重试：订阅频道复用已有的备用源回退（未试过的同名源，最多 4 条），
    // 原生频道循环到下一条自选线路（绕回 SDK 自动）；无可换的就按原线路重试。
    if(self.remotePlaybackFailed&&self.currentRemoteURL.length){self.remotePlaybackWanted=YES;[self tryAlternateSource];return;}
    NSDictionary *channel=[self channelWithID:self.channelID];
    if(!channel&&self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};
    if(!channel)return;
    NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];
    if(!routes.count){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];return;}
    NSInteger current=[routes indexOfObjectPassingTest:^BOOL(NSDictionary *r,NSUInteger idx,BOOL *stop){return [r isEqual:self.requestedNativeRoute];}];
    NSDictionary *next=current==NSNotFound?routes.firstObject:(current+1<(NSInteger)routes.count?routes[current+1]:nil);
    [self log:@"换线路重试：%@ -> %@",self.routeName?:@"自动",next?@"自选线路":@"SDK 自动"];
    self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:next];
}
- (void)displayNativePlaybackFailure:(NSString *)stage error:(NSError *)error {
    NSString *player=self.avPlayer?@"AVPlayer":(self.cicadaPlayer?@"CicadaPlayer":@"CNPlayerSDK");
    NSMutableDictionary *failureFields=[@{@"player":player, @"stage":stage?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.directNativeRouteActive?@"user_selected":@"sdk_auto"} mutableCopy];
    if(![ProfileStore isHTTP:self.channelID]&&self.channelID.length<=128)failureFields[@"sdk_channel_id"]=self.channelID?:@"";
    if(self.currentPlayer&&!self.avPlayer)failureFields[@"sdk_reported_node"]=[NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer]?:@"unknown";
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:failureFields];
    self.nativePlaybackFailed=YES;self.nativeRetryPending=NO;[self.watchdog invalidate];self.watchdog=nil;[self.nativeStartupTuner restore];[self endPlaybackPriority];[self.spinner stopAnimating];
    NSString *channel=self.channelName.length?self.channelName:@"频道";
    self.titleLabel.text=error.code?[NSString stringWithFormat:@"%@ · %@ (%ld)",channel,stage,(long)error.code]:[NSString stringWithFormat:@"%@ · %@",channel,stage];
    self.titleLabel.hidden=NO;NSString *failureDetail=error.localizedDescription.length?[HostLogRedactor redactText:error.localizedDescription]:nil;self.infoLabel.text=failureDetail?[NSString stringWithFormat:@"%@ · 点按“重试”再次播放，或点“线路”换源后重试",failureDetail]:@"点按“重试”再次播放，或点“线路”换源后重试";self.infoLabel.hidden=NO;self.controlBar.hidden=NO;
    [self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];[self syncPlayPauseButtonIcon];self.playPauseBtn.enabled=YES;
    [self.channelGrid reloadData];[self.table reloadData];
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player vdnRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"VDN 请求失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"频道调度失败" error:error];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player parameterError:error rate:rate]; }); return; }
    if (player != self.currentPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"参数错误 %ld", (long)error.code];[self displayNativePlaybackFailure:@"参数错误" error:error];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player publicRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    if (self.directNativeRouteActive && self.channelID.length && !self.nativeStartupRecoveryUsed) {
        self.nativeStartupRecoveryUsed = YES;
        [self log:@"自选线路版权请求失败 %ld，自动回退频道 ID 调度", (long)error.code];
        [self playViaSDK:self.channelID title:self.channelName ?: self.channelID];
        return;
    }
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"版权请求失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"版权请求失败" error:error];
}

- (void)authFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration;dispatch_async(dispatch_get_main_queue(), ^{if(generation!=self.playbackGeneration)return;[self authFailed:error];}); return; }
    if (!self.currentPlayer || self.avPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];[self log:@"鉴权失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"鉴权失败" error:error];
}

- (void)showPlaybackInfo {
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[self playbackInformationPage]];HostStyleNavigation(nav);nav.navigationBar.prefersLargeTitles=NO;nav.modalPresentationStyle=UIModalPresentationPageSheet;nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];nav.sheetPresentationController.prefersGrabberVisible=YES;[self presentViewController:nav animated:YES completion:nil];
}
- (BOOL)isCatchupOrTimeshiftActive {
    return self.nativeTimeShiftActive || self.remoteCatchupActive;
}
- (void)returnToLivePlayback {
    if (self.remoteCatchupActive) {
        NSDictionary *liveChannel = self.activeCatchupLiveChannel ?: [self channelWithID:self.channelID];
        self.remoteCatchupActive = NO;
        self.activeCatchupProgramTitle = nil;
        self.activeCatchupStart = 0;
        self.activeCatchupEnd = 0;
        self.activeCatchupLiveChannel = nil;
        if (liveChannel) {
            [self log:@"从订阅回看返回实时直播：%@", liveChannel[@"name"] ?: self.channelName ?: @""];
            [self playRemote:liveChannel];
        }
        return;
    }
    [self returnToNativeLive];
}
- (void)seekCurrentChannelByOffsetMinutes:(double)minutes {
    if (fabs(minutes) < 0.01) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval currentAnchor = now;
    if (self.remoteCatchupActive && self.activeCatchupStart > 0) {
        double elapsed = self.remoteAdapter ? self.remoteAdapter.currentPosition : (self.avPlayer ? CMTimeGetSeconds(self.avPlayer.currentTime) : 0);
        if (!isfinite(elapsed) || elapsed < 0) elapsed = 0;
        currentAnchor = MIN(now, self.activeCatchupStart + elapsed);
    } else if (self.nativeTimeShiftActive && (self.activeCatchupStart > 0 || self.timeshiftController.seekStart > 0)) {
        currentAnchor = self.activeCatchupStart > 0 ? self.activeCatchupStart : self.timeshiftController.seekStart;
    }
    NSTimeInterval targetStart = currentAnchor - minutes * 60.0;
    if (targetStart >= now - 15.0) {
        [self returnToLivePlayback];
        return;
    }
    double totalBehindMinutes = MAX(1.0, round((now - targetStart) / 60.0));
    NSString *label = [NSString stringWithFormat:@"距直播 %.0f 分钟", totalBehindMinutes];
    if (self.currentPlayer && !self.avPlayer) {
        self.activeCatchupProgramTitle = label;
        self.activeCatchupStart = targetStart;
        self.activeCatchupEnd = 0;
        [self seekNativeStart:targetStart end:0];
        return;
    }
    NSDictionary *channel = self.activeCatchupLiveChannel ?: [self channelWithID:self.channelID];
    if (!channel && self.channelID.length) channel = @{@"id":self.channelID, @"name":self.channelName ?: self.channelID, @"remoteURL":self.currentRemoteURL ?: @""};
    NSDictionary *catchupRow = [self catchupChannelForChannel:channel] ?: [self anyCatchupChannelForStation:channel];
    if ([catchupRow[@"catchupSource"] isKindOfClass:NSString.class] && [catchupRow[@"catchupSource"] length]) {
        if (![self startRemoteCatchupForChannel:catchupRow program:@{@"title":label, @"start":@(targetStart), @"end":@(now)} start:targetStart end:now]) {
            [self showServiceError:@"所选回退时间超出该订阅源支持的回看窗口或模板格式不受支持。"];
        }
        return;
    }
    NSDictionary *nativeFallback = (![channel[@"remoteURL"] length]) ? channel : [self nativeFallbackChannelForChannel:channel];
    NSString *nativeID = [nativeFallback[@"id"] isKindOfClass:NSString.class] ? nativeFallback[@"id"] : @"";
    if (nativeFallback && nativeID.length) {
        self.pendingNativeReplayProgram = @{@"channelID":nativeID, @"start":@(targetStart), @"end":@0, @"title":label};
        [self playChannel:nativeFallback route:nil];
        return;
    }
    [self showServiceError:@"当前频道线路暂未声明 M3U 回看模板（catchup-source），请打开节目单或切换支持回看的源。"];
}
- (void)showNativeTimeshiftActions {
    NSDictionary *channel = self.activeCatchupLiveChannel ?: [self channelWithID:self.channelID];
    BOOL isRemoteCatchupCapable = ([self catchupChannelForChannel:channel] != nil || [self anyCatchupChannelForStation:channel] != nil);
    NSString *msg = (self.currentPlayer && !self.avPlayer)
        ? @"支持连续回退、快进微调或从节目单点选 7 天回看；若原生线路受限将自动尝试同台回看源。"
        : (isRemoteCatchupCapable ? @"支持按时间快速回退或打开节目单点选已播节目回看。" : @"可切换至官方 SDK 线路或打开节目单按时段回看。");
    BOOL inCatchup = [self isCatchupOrTimeshiftActive];
    NSString *tsTitle = inCatchup
        ? (self.activeCatchupProgramTitle.length ? self.activeCatchupProgramTitle : @"时移 / 回看")
        : @"时移 / 回看";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<HostGlassSheetAction *> *rewindChips = [NSMutableArray array];
    for (NSNumber *minutes in @[@1,@5,@15,@30,@60]) {
        double mins = minutes.doubleValue;
        [rewindChips addObject:[HostGlassSheetAction actionWithTitle:[NSString stringWithFormat:@"−%@m", minutes] subtitle:nil value:nil icon:nil tint:HostAccent() destructive:NO selected:NO handler:^{
            [weakSelf seekCurrentChannelByOffsetMinutes:mins];
        }]];
    }
    NSMutableArray<HostGlassSheetSection *> *sections = [NSMutableArray arrayWithObject:[HostGlassSheetSection chipSectionWithTitle:@"快速回退" actions:rewindChips]];
    if (inCatchup) {
        NSMutableArray<HostGlassSheetAction *> *fwdChips = [NSMutableArray array];
        for (NSNumber *forwardMinutes in @[@1, @5, @15]) {
            double fmins = forwardMinutes.doubleValue;
            [fwdChips addObject:[HostGlassSheetAction actionWithTitle:[NSString stringWithFormat:@"+%@m", forwardMinutes] subtitle:nil value:nil icon:nil tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{
                [weakSelf seekCurrentChannelByOffsetMinutes:-fmins];
            }]];
        }
        [sections addObject:[HostGlassSheetSection chipSectionWithTitle:@"快进微调" actions:fwdChips]];
    }
    NSArray<HostGlassSheetAction *> *navActions = @[
        [HostGlassSheetAction actionWithTitle:@"打开节目单选时段回看" subtitle:@"浏览近 7 天已播节目并一键点播" value:nil icon:@"calendar.badge.clock" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{ [weakSelf openEPG]; }],
        [HostGlassSheetAction actionWithTitle:@"返回实时直播" subtitle:@"同步至最新直播画面" value:nil icon:@"dot.radiowaves.left.and.right" tint:UIColor.systemGreenColor destructive:NO selected:NO handler:^{ [weakSelf returnToLivePlayback]; }]
    ];
    [sections addObject:[HostGlassSheetSection sectionWithTitle:@"节目与直播" actions:navActions]];
    [HostGlassActionSheetViewController presentOn:self title:tsTitle subtitle:msg badgeText:(inCatchup ? @"↺ 回看中" : @"● 实时直播") badgeColor:(inCatchup ? UIColor.systemOrangeColor : UIColor.systemGreenColor) sections:sections sourceView:(self.moreBtn ?: self.view)];
}
- (void)beginNativeTransition:(NSString *)kind {
    // Async native transition: 0.5s watchdog bounds SmokeDriver's terminal-state wait.
    [self.nativePreloader cancel];[self beginPlaybackPriority];self.playbackGeneration++;
    self.nativeUserPaused=NO;self.firstRender=NO;self.nativePlaybackFailed=NO;self.stallReported=NO;self.nativeStartupRecoveryUsed=NO;self.nativeSafeStartupActive=NO;self.nativeTransitionKind=kind;
    self.playStartedAt=CACurrentMediaTime();self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@中",self.channelName,kind];self.titleLabel.hidden=NO;[self.spinner startAnimating];[self startWatchdog];
}
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    if (!self.currentPlayer || self.avPlayer || (!self.firstRender && !self.nativeTimeShiftActive && !self.nativeTransitionKind.length)) {
        [self showServiceError:@"请等待 CCTV 原生频道起播完成后再操作。"]; return;
    }
    if (!self.timeshiftController) [self rebuildTimeshiftController];
    self.activeCatchupStart = start;
    self.activeCatchupEnd = end;
    [self beginNativeTransition:end == 0 ? @"时移" : @"回看"];
    self.nativeTimeShiftActive = YES;
    NSUInteger generation = self.playbackGeneration;
    __weak id player = self.currentPlayer;
    __weak typeof(self) weakSelf = self;
    [self.timeshiftController requestSeekToStart:start end:end channelID:self.channelID completion:^(BOOL ok, NSError *error) {
        if (generation != weakSelf.playbackGeneration || player != weakSelf.currentPlayer) return;
        if (!ok || error) {
            NSDictionary *channel = [weakSelf channelWithID:weakSelf.channelID];
            NSDictionary *catchupFallback = [weakSelf anyCatchupChannelForStation:channel];
            NSTimeInterval fallbackEnd = end > start ? end : NSDate.date.timeIntervalSince1970;
            if (catchupFallback && [weakSelf startRemoteCatchupForChannel:catchupFallback program:@{@"title":weakSelf.activeCatchupProgramTitle ?: @"节目回看", @"start":@(start), @"end":@(fallbackEnd)} start:start end:fallbackEnd]) {
                [weakSelf log:@"原生时移未放行，已自动切换至同台 M3U 回看源"];
                return;
            }
            [weakSelf failNativeTransition:error.localizedDescription.length
                ? error.localizedDescription
                : @"频道未允许该时间的时移/回看，请返回直播或重新选台。"];
        } else {
            [weakSelf log:@"原生时移请求已完成，等待/确认首帧"];
            [weakSelf ensureNativeTimeshiftPlayingForTrigger:@"timeshift_seek_completed"];

        }
    }];
}
- (void)failNativeTransition:(NSString *)message {
    [self.nativeTimeshift cancel];[self.timeshiftController cancel];self.nativeTimeShiftActive=NO;self.nativeTransitionKind=nil;self.nativePlaybackFailed=(self.currentPlayer==nil);if(self.currentPlayer)self.firstRender=YES;[self.watchdog invalidate];self.watchdog=nil;[self.spinner stopAnimating];[self endPlaybackPriority];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 时移操作失败",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.text=message;self.infoLabel.hidden=NO;[self log:@"%@",message];[self showServiceError:message];
}
- (void)returnToNativeLive {
    if (!self.currentPlayer || self.avPlayer) return;
    if (!self.timeshiftController) [self rebuildTimeshiftController];
    [self beginNativeTransition:@"返回直播"];
    self.nativeTimeShiftActive = NO;
    self.activeCatchupProgramTitle = nil;
    self.activeCatchupStart = 0;
    self.activeCatchupEnd = 0;
    [self.timeshiftController returnToLive];

}

- (NSString *)activeAirPlayDeviceName {
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *output in route.outputs) {
        if ([output.portType isEqualToString:AVAudioSessionPortAirPlay]) {
            return output.portName.length ? output.portName : @"AirPlay 设备";
        }
    }
    if (self.avPlayer && self.avPlayer.isExternalPlaybackActive) return @"AirPlay 电视";
    return nil;
}

- (void)triggerSystemAirPlayPicker {
    AVRoutePickerView *picker = self.hiddenRoutePicker ?: self.catalogFloatingAirPlayPicker;
    for (UIView *subview in picker.subviews) {
        if ([subview isKindOfClass:UIButton.class]) {
            [(UIButton *)subview sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
    }
}

- (NSString *)castableStreamURLForCurrentChannel {
    NSString *rawURL = self.currentRemoteURL;
    if (!rawURL.length && self.requestedNativeRoute[@"url"]) {
        rawURL = [self.requestedNativeRoute[@"url"] isKindOfClass:NSString.class] ? self.requestedNativeRoute[@"url"] : @"";
    }
    if (!rawURL.length && self.channelID.length) {
        NSDictionary *ch = [self channelWithID:self.channelID];
        if ([ch[@"remoteURL"] isKindOfClass:NSString.class] && [ch[@"remoteURL"] length]) {
            rawURL = ch[@"remoteURL"];
        } else {
            NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
            for (NSDictionary *r in routes) {
                if (!CCTVRouteRequiresSDK(r) && [r[@"url"] isKindOfClass:NSString.class] && [r[@"url"] length]) {
                    rawURL = r[@"url"];
                    break;
                }
            }
            if (!rawURL.length && [routes.firstObject[@"url"] isKindOfClass:NSString.class]) {
                rawURL = routes.firstObject[@"url"];
            }
        }
    }
    if (!rawURL.length) return @"";
    NSURLComponents *parts = [NSURLComponents componentsWithString:rawURL];
    NSString *host = parts.host.lowercaseString ?: @"";
    if ([@[@"127.0.0.1", @"localhost", @"::1"] containsObject:host]) {
        NSString *lanIP = CCTVDeviceLANIPv4Address();
        if (lanIP.length && ![lanIP isEqualToString:@"127.0.0.1"]) {
            parts.host = lanIP;
            if (parts.URL.absoluteString.length) return parts.URL.absoluteString;
        }
    }
    return rawURL;
}

- (BOOL)switchToAirPlayCompatibleRouteIfPossible {
    if (!self.channelID.length) return NO;
    NSDictionary *ch = [self channelWithID:self.channelID];
    if (!ch) return NO;
    NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
    for (NSDictionary *candidate in routes) {
        if (!CCTVRouteRequiresSDK(candidate)) {
            [self log:@"已切换至 AirPlay 兼容明文线路 (%@)", candidate[@"provider"] ?: @"HLS"];
            [self playChannel:ch route:candidate];
            return YES;
        }
    }
    NSDictionary *alt = [self nextUntriedAlternateChannel];
    if (alt) {
        [self log:@"已切换至同名订阅源以支持 AirPlay 视频投屏"];
        [self startRemoteChannel:alt];
        return YES;
    }
    return NO;
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *airPlayDevice = [self activeAirPlayDeviceName]; self.activeAirPlayRouteName = airPlayDevice;
        BOOL isAirPlay = (airPlayDevice.length > 0);
        // T10：视频投屏只认 AVPlayer 的 externalPlaybackActive；仅音频路由不得显示"投屏中"/"正在投屏至"。
        BOOL isAirPlayVideo = self.avPlayer && self.avPlayer.isExternalPlaybackActive;
        self.catalogFloatingAirPlayPicker.tintColor = isAirPlay ? HostAccent() : HostText();
        if (self.castBtn) { [self.castBtn setTitle:isAirPlayVideo ? @"投屏中" : @"投屏" forState:UIControlStateNormal]; self.castBtn.layer.borderColor = isAirPlayVideo ? HostAccent().CGColor : [UIColor colorWithWhite:1 alpha:0.22].CGColor; }
        if (isAirPlay && self.currentPlayer && !self.avPlayer && self.channelID.length) {
            if (![self switchToAirPlayCompatibleRouteIfPossible]) {
                self.infoLabel.hidden = NO; self.infoLabel.text = [NSString stringWithFormat:@"📺 已连接 %@ · 加密频道建议使用系统「屏幕镜像」", airPlayDevice];
            }
        } else if (isAirPlayVideo) {
            self.infoLabel.hidden = NO; self.infoLabel.text = [NSString stringWithFormat:@"📺 正在投屏至 %@", airPlayDevice];
        } else if (isAirPlay) {
            self.infoLabel.hidden = NO; self.infoLabel.text = [NSString stringWithFormat:@"🔊 音频已连接至 %@，视频仍在本机播放", airPlayDevice];
        }
    });
}

- (void)showCastingCenter {
    NSString *airPlayDevice = [self activeAirPlayDeviceName];
    NSString *castURL = [self castableStreamURLForCurrentChannel];
    NSString *statusSummary = airPlayDevice.length
        ? [NSString stringWithFormat:@"当前已连接：%@\n支持 AirPlay 无线投屏及智能电视局域网拉流。", airPlayDevice]
        : @"支持 AirPlay 无线音视频投屏、智能切换明文投屏线路及局域网电视地址复制。";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<HostGlassSheetAction *> *wirelessActions = [NSMutableArray array];
    [wirelessActions addObject:[HostGlassSheetAction actionWithTitle:(airPlayDevice.length ? @"切换 / 断开 AirPlay 设备" : @"选择 AirPlay 投屏设备") subtitle:@"无线投屏至 Apple TV 或支持隔空播放的电视" value:(airPlayDevice.length ? airPlayDevice : nil) icon:@"airplayvideo" tint:UIColor.systemBlueColor destructive:NO selected:(airPlayDevice.length > 0) handler:^{
        [weakSelf triggerSystemAirPlayPicker];
    }]];
    if (self.channelID.length && self.currentPlayer && !self.avPlayer) {
        [wirelessActions addObject:[HostGlassSheetAction actionWithTitle:@"切换 AirPlay 高清兼容线路" subtitle:@"自动切至明文 HLS 解决加密源有声无画" value:nil icon:@"tv.and.mediabox" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{
            if (![weakSelf switchToAirPlayCompatibleRouteIfPossible]) {
                [weakSelf showServiceError:@"该央视加密频道暂无明文 HLS 线路，请从 iOS 控制中心打开「屏幕镜像」进行整屏投射，或在「频道」页导入订阅源。"];
            }
        }]];
    }
    NSMutableArray<HostGlassSheetSection *> *sections = [NSMutableArray arrayWithObject:[HostGlassSheetSection sectionWithTitle:@"无线投屏" actions:wirelessActions]];
    if (castURL.length) {
        NSArray<HostGlassSheetAction *> *lanActions = @[
            [HostGlassSheetAction actionWithTitle:@"复制局域网 / 电视端投屏地址" subtitle:@"可粘贴至电视端 VLC / Kodi / 第三方播放器" value:nil icon:@"doc.on.doc" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{
                [UIPasteboard generalPasteboard].string = castURL;
                weakSelf.infoLabel.hidden = NO;
                weakSelf.infoLabel.text = @"已复制投屏流地址 · 可粘贴至电视端 VLC / Kodi / 播放器";
                [weakSelf log:@"已复制投屏流地址"];
            }],
            [HostGlassSheetAction actionWithTitle:@"分享直播流地址到其他设备" subtitle:@"通过隔空投送或系统分享面板发送" value:nil icon:@"square.and.arrow.up" tint:UIColor.systemIndigoColor destructive:NO selected:NO handler:^{
                NSURL *shareURL = [NSURL URLWithString:castURL];
                NSArray *items = shareURL ? @[shareURL] : @[castURL];
                UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
                activity.popoverPresentationController.sourceView = weakSelf.castBtn ?: weakSelf.view;
                activity.popoverPresentationController.sourceRect = (weakSelf.castBtn ?: weakSelf.view).bounds;
                [weakSelf presentViewController:activity animated:YES completion:nil];
            }]
        ];
        [sections addObject:[HostGlassSheetSection sectionWithTitle:@"局域网拉流与分享" actions:lanActions]];
    }
    UIView *anchor = self.castBtn && !self.castBtn.hidden ? self.castBtn : (self.catalogMoreButton ?: self.view);
    [HostGlassActionSheetViewController presentOn:self title:(self.channelName.length ? [NSString stringWithFormat:@"%@ · 投屏中心", self.channelName] : @"投屏中心") subtitle:statusSummary badgeText:(airPlayDevice.length ? [NSString stringWithFormat:@"已连接 · %@", airPlayDevice] : @"AirPlay / 局域网电视") badgeColor:(airPlayDevice.length ? UIColor.systemGreenColor : UIColor.systemBlueColor) sections:sections sourceView:anchor];
}

- (void)showMorePlaybackActions {
    NSString *modeSummary = [self isCatchupOrTimeshiftActive] ? (self.activeCatchupProgramTitle.length ? [NSString stringWithFormat:@"回看中 · %@", self.activeCatchupProgramTitle] : @"时移 / 回看中") : @"实时直播";
    NSDictionary *activeChannel = self.activeCatchupLiveChannel ?: [self channelWithID:self.channelID];
    BOOL canTimeshiftOrCatchup = (self.currentPlayer && !self.avPlayer) || [self channelSupportsCatchup:activeChannel] || ([self nativeFallbackChannelForChannel:activeChannel] != nil) || [self isCatchupOrTimeshiftActive];
    BOOL pipAvailable = (self.avLayer && AVPictureInPictureController.isPictureInPictureSupported);

    CCTVLiveControlSheetViewController *sheet = [CCTVLiveControlSheetViewController new];
    sheet.channelTitle = self.channelName ?: @"播放控制";
    sheet.routeLabel = self.routeName.length ? self.routeName : @"自动";
    sheet.modeLabel = modeSummary;
    sheet.catchupActive = [self isCatchupOrTimeshiftActive];
    sheet.playbackFailed = (self.nativePlaybackFailed || self.remotePlaybackFailed);
    sheet.canTimeshiftOrCatchup = canTimeshiftOrCatchup;
    sheet.fullscreenActive = self.fullscreen;
    sheet.pipSupported = pipAvailable;
    sheet.sleepMinutes = self.liveSleepMinutes;

    __weak typeof(self) weakSelf = self;
    sheet.onRoutes = ^{ [weakSelf showRoutes]; };
    sheet.onEPG = ^{ [weakSelf openEPG]; };
    sheet.onCast = ^{ [weakSelf showCastingCenter]; };
    sheet.onToggleFullscreen = ^{ [weakSelf toggleFullscreen]; };
    sheet.onPrevChannel = ^{ [weakSelf playAdjacentChannel:-1]; };
    sheet.onNextChannel = ^{ [weakSelf playAdjacentChannel:1]; };
    if (self.nativePlaybackFailed||self.remotePlaybackFailed) {
        sheet.onRetryAlternate = ^{ [weakSelf retryPlaybackWithAlternateSource]; };
    }
    if (canTimeshiftOrCatchup) {
        sheet.onTimeshift = ^{ [weakSelf showNativeTimeshiftActions]; };
        if ([self isCatchupOrTimeshiftActive]) {
            sheet.onReturnLive = ^{ [weakSelf returnToLivePlayback]; };
        }
    }
    sheet.onPlaybackInfo = ^{ [weakSelf showPlaybackInfo]; };
    if (pipAvailable) {
        sheet.onPiP = ^{ [weakSelf togglePiP]; };
    }
    sheet.onSelectSleepMinutes = ^(NSInteger minutes) { [weakSelf configureLiveSleepTimerMinutes:minutes]; };
    sheet.onDiagnosticLog = ^{ [weakSelf openDiagnosticLog]; };

    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sp = sheet.sheetPresentationController;
        if (sp) {
            sp.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
            sp.prefersGrabberVisible = YES;
            sp.preferredCornerRadius = 28.0;
            sp.prefersScrollingExpandsWhenScrolledToEdge = YES;
        }
    }
    if (sheet.popoverPresentationController) {
        UIView *anchor = self.moreBtn ?: self.view;
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}


- (void)beginPlaybackPriority {
    self.playbackIntentVersion++;NSUInteger intent=self.playbackIntentVersion;
    self.playbackPriorityUntil=CACurrentMediaTime()+12;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(intent==self.playbackIntentVersion && self.playbackPriorityUntil>0){[self log:@"起播优先窗口结束，恢复订阅刷新"];[self endPlaybackPriority];}
    });
    [self stopPreview];[[XMLTVStore shared] setPaused:YES];self.subscriptionParseGeneration++;

}
- (void)endPlaybackPriority {
    self.playbackPriorityUntil=0;BOOL background=UIApplication.sharedApplication.applicationState!=UIApplicationStateActive;[[XMLTVStore shared] setPaused:background];if(!background&&self.epgRefreshDesired){[self restartEPGTimer];[self refreshNowNext];}NSUInteger generation=self.playbackGeneration;
    __weak typeof(self) weakIdleSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{RootViewController *owner=weakIdleSelf;if(!owner)return;if(generation==owner.playbackGeneration&&CACurrentMediaTime()>=owner.playbackPriorityUntil){[owner refreshSubscriptionsWhenIdle];if(owner.activeTab<2)[owner reloadActiveCatalogView];}});
}
- (void)refreshSubscriptionsWhenIdle {
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    NSArray *pending=self.deferredLocalSubscriptions.allObjects;[self.deferredLocalSubscriptions removeAllObjects];for(NSString *s in pending)[self fetchSubscription:s silent:YES];
}
@end
