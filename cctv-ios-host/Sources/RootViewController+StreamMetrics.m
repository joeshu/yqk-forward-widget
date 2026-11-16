#import "RootViewController_Internal.h"

@implementation RootViewController (StreamMetrics)
- (NSString *)formatBitrateMbps:(double)bps {
    if (bps <= 0 || isnan(bps) || isinf(bps)) return @"检测中";
    if (bps >= 1000000.0) return [NSString stringWithFormat:@"%.2f Mbps", bps / 1000000.0];
    return [NSString stringWithFormat:@"%.0f kbps", bps / 1000.0];
}
- (NSString *)resolutionTierTagForSize:(CGSize)size {
    CGFloat h = MIN(size.width, size.height);
    if (h <= 0) return @"";
    if (h >= 2160) return @"4K UHD";
    if (h >= 1080) return @"1080P FHD";
    if (h >= 720) return @"720P HD";
    if (h >= 480) return @"540P SD";
    return @"SD";
}
- (NSString *)codecNameFromFourCC:(FourCharCode)subType {
    switch (subType) {
        case 'avc1': case 'avc3': return @"H.264";
        case 'hvc1': case 'hev1': return @"HEVC (H.265)";
        case 'mp4a': case 'aac ': return @"AAC";
        case 'ac-3': return @"AC-3";
        case 'ec-3': return @"E-AC-3";
        default: return @"";
    }
}
- (NSDictionary *)collectLiveStreamMetrics {
    NSString *engine = self.remoteAdapter ? @"CicadaPlayer" : (self.avPlayer ? @"AVPlayer" : (self.cicadaPlayer ? @"CicadaPlayer" : (self.currentPlayer ? @"CNPlayer (原生)" : @"等待播放")));
    CGSize videoSize = self.liveVideoSize;
    double bitrateBps = self.liveBitrateBps;
    double peakBps = self.livePeakBitrateBps;
    double fps = self.liveFPS;
    NSString *videoCodec = self.liveVideoCodec ?: @"";
    NSString *audioCodec = self.liveAudioCodec ?: @"";
    NSTimeInterval bufferedSec = -1;
    NSInteger droppedFrames = 0;
    NSInteger stalls = self.liveStallCount;
    NSString *nodeInfo = @"";

    if (self.avPlayer.currentItem) {
        AVPlayerItem *item = self.avPlayer.currentItem;
        if (item.presentationSize.width > 0 && item.presentationSize.height > 0) {
            videoSize = item.presentationSize;
        }
        for (AVPlayerItemTrack *track in item.tracks) {
            AVAssetTrack *at = track.assetTrack;
            if (!at) continue;
            if ([at.mediaType isEqualToString:AVMediaTypeVideo]) {
                if (videoSize.width <= 0 && at.naturalSize.width > 0) {
                    CGSize transformed = CGSizeApplyAffineTransform(at.naturalSize, at.preferredTransform);
                    videoSize = CGSizeMake(fabs(transformed.width), fabs(transformed.height));
                }
                if (at.nominalFrameRate > 0) fps = at.nominalFrameRate;
                if (!videoCodec.length && at.formatDescriptions.count) {
                    CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
                    if (fmt) videoCodec = [self codecNameFromFourCC:CMFormatDescriptionGetMediaSubType(fmt)];
                }
            } else if ([at.mediaType isEqualToString:AVMediaTypeAudio]) {
                if (!audioCodec.length && at.formatDescriptions.count) {
                    CMFormatDescriptionRef fmt = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
                    if (fmt) audioCodec = [self codecNameFromFourCC:CMFormatDescriptionGetMediaSubType(fmt)];
                }
            }
        }
        AVPlayerItemAccessLogEvent *event = item.accessLog.events.lastObject;
        if (event) {
            double obs = event.observedBitrate;
            double ind = event.indicatedBitrate;
            if (obs > 0 && !isnan(obs)) bitrateBps = obs;
            else if (ind > 0 && !isnan(ind)) bitrateBps = ind;
            else if (event.segmentsDownloadedDuration > 0 && event.numberOfBytesTransferred > 0) {
                bitrateBps = (event.numberOfBytesTransferred * 8.0) / event.segmentsDownloadedDuration;
            }
            if (ind > 0 && !isnan(ind)) peakBps = MAX(peakBps, ind);
            if (obs > 0 && !isnan(obs)) peakBps = MAX(peakBps, obs);
            droppedFrames = event.numberOfDroppedVideoFrames;
            stalls = MAX(stalls, event.numberOfStalls);
            if (event.URI.length) {
                NSString *host = [NSURL URLWithString:event.URI].host;
                if (host.length) nodeInfo = host;
            }
        }
        NSValue *rangeVal = item.loadedTimeRanges.firstObject;
        if (rangeVal) {
            CMTimeRange range = rangeVal.CMTimeRangeValue;
            double endSec = CMTimeGetSeconds(CMTimeRangeGetEnd(range));
            double curSec = CMTimeGetSeconds(item.currentTime);
            if (!isnan(endSec) && !isnan(curSec) && endSec >= curSec) {
                bufferedSec = endSec - curSec;
            }
        }
    } else if (self.remoteAdapter) {
        for (NSDictionary *tr in [self.remoteAdapter availableTracks]) {
            if (![tr isKindOfClass:NSDictionary.class]) continue;
            NSString *type = [tr[@"type"] description].lowercaseString ?: @"";
            if ([type containsString:@"video"] || [tr[@"width"] doubleValue] > 0) {
                double w = [tr[@"width"] doubleValue], h = [tr[@"height"] doubleValue];
                if (videoSize.width <= 0 && w > 0 && h > 0) videoSize = CGSizeMake(w, h);
                double tfps = [tr[@"videoFPS"] doubleValue] > 0 ? [tr[@"videoFPS"] doubleValue] : [tr[@"fps"] doubleValue];
                if (tfps > 0) fps = tfps;
                double tbr = [tr[@"videoBitrate"] doubleValue] > 0 ? [tr[@"videoBitrate"] doubleValue] : [tr[@"bitrate"] doubleValue];
                if (bitrateBps <= 0 && tbr > 0) bitrateBps = tbr;
                NSString *cName = [tr[@"codecName"] isKindOfClass:NSString.class] ? tr[@"codecName"] : ([tr[@"codec"] isKindOfClass:NSString.class] ? tr[@"codec"] : @"");
                if (cName.length) videoCodec = cName.uppercaseString;
            } else if ([type containsString:@"audio"]) {
                NSString *aName = [tr[@"codecName"] isKindOfClass:NSString.class] ? tr[@"codecName"] : ([tr[@"codec"] isKindOfClass:NSString.class] ? tr[@"codec"] : @"");
                if (aName.length) audioCodec = aName.uppercaseString;
            }
        }
        if (self.remoteAdapter.bufferedPosition > self.remoteAdapter.currentPosition) {
            bufferedSec = self.remoteAdapter.bufferedPosition - self.remoteAdapter.currentPosition;
        }
    } else if (self.currentPlayer) {
        nodeInfo = [NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer] ?: @"";
        double rw = [self.requestedNativeRoute[@"w"] doubleValue];
        double rh = [self.requestedNativeRoute[@"h"] doubleValue];
        if (rw > 0 && rh > 0) {
            videoSize = CGSizeMake(rw, rh);
        } else if ([self.routeName containsString:@"4K"]) {
            videoSize = CGSizeMake(3840, 2160);
        } else if ([self.routeName containsString:@"1080"] || [self.routeName containsString:@"超高清"]) {
            videoSize = CGSizeMake(1920, 1080);
        } else if ([self.routeName containsString:@"720"] || [self.routeName containsString:@"高清"]) {
            videoSize = CGSizeMake(1280, 720);
        }
        if (bitrateBps <= 0 && self.channelID.length) {
            double kbps = [self.channelTelemetryStore[self.channelID][@"sampleKBps"] doubleValue];
            if (kbps > 0) bitrateBps = kbps * 8.0 * 1000.0;
        }
    }

    if (videoSize.width > 0 && videoSize.height > 0) self.liveVideoSize = videoSize;
    if (bitrateBps > 0) {
        self.liveBitrateBps = bitrateBps;
        self.livePeakBitrateBps = MAX(self.livePeakBitrateBps, bitrateBps);
    }
    if (fps > 0) self.liveFPS = fps;
    if (videoCodec.length) self.liveVideoCodec = videoCodec;
    if (audioCodec.length) self.liveAudioCodec = audioCodec;

    NSString *tier = [self resolutionTierTagForSize:videoSize];
    NSString *resLong = videoSize.width > 0
        ? (tier.length ? [NSString stringWithFormat:@"%.0f × %.0f (%@)", videoSize.width, videoSize.height, tier] : [NSString stringWithFormat:@"%.0f × %.0f", videoSize.width, videoSize.height])
        : @"等待视频信息";
    NSString *resShort = tier.length ? [[tier componentsSeparatedByString:@" "] firstObject] : (videoSize.width > 0 ? [NSString stringWithFormat:@"%.0fP", MIN(videoSize.width, videoSize.height)] : @"—");
    NSString *bitrateStr = [self formatBitrateMbps:bitrateBps];
    NSString *bitrateShort = bitrateBps >= 1000000.0 ? [NSString stringWithFormat:@"%.1fM", bitrateBps / 1000000.0] : (bitrateBps > 0 ? [NSString stringWithFormat:@"%.0fK", bitrateBps / 1000.0] : @"—");
    NSString *peakStr = peakBps > 0 ? [self formatBitrateMbps:peakBps] : @"—";
    NSString *fpsStr = fps > 0 ? [NSString stringWithFormat:@"%.0f FPS", fps] : @"—";
    NSString *codecStr = videoCodec.length ? (audioCodec.length ? [NSString stringWithFormat:@"%@ / %@", videoCodec, audioCodec] : videoCodec) : @"硬解自动";
    NSString *codecShort = videoCodec.length ? [[videoCodec componentsSeparatedByString:@" "] firstObject] : @"自动";
    NSString *bufferStr = bufferedSec >= 0 ? [NSString stringWithFormat:@"%.1f 秒", bufferedSec] : (self.firstRender ? @"实时流正常" : @"缓冲中");
    if (!nodeInfo.length && self.currentRemoteURL.length) {
        nodeInfo = [NSURL URLWithString:self.currentRemoteURL].host ?: @"";
    }
    return @{
        @"engine": engine,
        @"resolution": resLong,
        @"resolutionShort": resShort,
        @"bitrate": bitrateStr,
        @"bitrateShort": bitrateShort,
        @"peakBitrate": peakStr,
        @"fps": fpsStr,
        @"codec": codecStr,
        @"codecShort": codecShort,
        @"buffer": bufferStr,
        @"droppedFrames": [NSString stringWithFormat:@"%ld 帧", (long)droppedFrames],
        @"stalls": [NSString stringWithFormat:@"%ld 次", (long)stalls],
        @"node": nodeInfo.length ? nodeInfo : @"自动调度"
    };
}
- (void)updateLiveQualityBadge {
    if (!self.playbackQualityBadgeBtn) return;
    if (!self.firstRender) {
        [self.playbackQualityBadgeBtn setTitle:@"信息" forState:UIControlStateNormal];
        return;
    }
    NSDictionary *m = [self collectLiveStreamMetrics];
    NSString *res = m[@"resolutionShort"];
    NSString *br = m[@"bitrateShort"];
    NSString *badge = @"信息";
    if (res.length && ![res isEqualToString:@"—"] && br.length && ![br isEqualToString:@"—"]) {
        badge = [NSString stringWithFormat:@"%@·%@", res, br];
    } else if (res.length && ![res isEqualToString:@"—"]) {
        badge = res;
    } else if (br.length && ![br isEqualToString:@"—"]) {
        badge = br;
    }
    [self.playbackQualityBadgeBtn setTitle:badge forState:UIControlStateNormal];
}
- (void)startLiveQualityBadgeTimer {
    [self.liveQualityBadgeTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.liveQualityBadgeTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf updateLiveQualityBadge];
    }];
    [self updateLiveQualityBadge];
}
- (PlaybackInfoViewController *)playbackInformationPage {
    PlaybackInfoViewController *v = [PlaybackInfoViewController new];
    v.autoRefreshInterval = 1.5;
    __weak typeof(self) w = self;
    v.summaryProvider = ^NSDictionary * {
        if (!w || !w.channelID.length) return nil;
        NSDictionary *m = [w collectLiveStreamMetrics];
        return @{
            @"channelName": w.channelName ?: @"未选台",
            @"engine": m[@"engine"] ?: @"等待播放",
            @"resolution": m[@"resolutionShort"] ?: @"—",
            @"bitrate": m[@"bitrateShort"] ?: @"—",
            @"fps": m[@"fps"] ?: @"—",
            @"codec": m[@"codecShort"] ?: @"自动"
        };
    };
    NSArray *(^buildSections)(void) = ^NSArray * {
        if (!w) return @[];
        NSDictionary *m = [w collectLiveStreamMetrics];
        NSDictionary *ch = w.channelID.length ? [w channelWithID:w.channelID] : nil;
        NSUInteger altCount = ch ? [w sourceCountForChannel:ch] : 0;

        NSMutableArray *streamRows = [NSMutableArray arrayWithArray:@[
            @{@"title": @"视频分辨率", @"value": m[@"resolution"]},
            @{@"title": @"实时码率", @"value": m[@"bitrate"]},
            @{@"title": @"峰值带宽", @"value": m[@"peakBitrate"]},
            @{@"title": @"视频帧率", @"value": m[@"fps"]},
            @{@"title": @"编码格式", @"value": m[@"codec"]}
        ]];

        NSMutableArray *playerRows = [NSMutableArray arrayWithArray:@[
            @{@"title": @"频道名称", @"value": w.channelName ?: @"未选台"},
            @{@"title": @"频道 ID", @"value": w.channelID ?: @"—"},
            @{@"title": @"播放引擎", @"value": m[@"engine"]},
            @{@"title": @"首帧耗时", @"value": w.firstRender ? [NSString stringWithFormat:@"%.2f 秒", w.firstFrameSeconds] : @"等待画面"},
            @{@"title": @"缓冲健康度", @"value": m[@"buffer"]},
            @{@"title": @"丢帧 / 卡顿", @"value": [NSString stringWithFormat:@"%@ / %@", m[@"droppedFrames"], m[@"stalls"]]}
        ]];

        NSMutableArray *routeRows = [NSMutableArray arrayWithArray:@[
            @{@"title": @"线路方式", @"value": w.routeName ?: @"自动"},
            @{@"title": @"节点 / 服务", @"value": m[@"node"]},
            @{@"title": @"同台可用源", @"value": [NSString stringWithFormat:@"%lu 条", (unsigned long)MAX(1, altCount)]},
            @{@"title": @"应用版本", @"value": CCTVBuildTag()}
        ]];
        if (w.requestedNativeRoute[@"url"]) {
            [routeRows insertObject:@{@"title": @"所选线路完整地址", @"value": [w displaySafeSourceURL:w.requestedNativeRoute[@"url"]]} atIndex:1];
        } else if (w.currentRemoteURL.length) {
            [routeRows insertObject:@{@"title": @"当前流地址", @"value": [w displaySafeSourceURL:w.currentRemoteURL]} atIndex:1];
        }

        return @[
            @{@"title": @"流媒体画质参数", @"rows": streamRows},
            @{@"title": @"播放与缓冲状态", @"rows": playerRows},
            @{@"title": @"线路与节点诊断", @"rows": routeRows}
        ];
    };
    v.sectionsProvider = buildSections;
    v.rowsProvider = ^NSArray<NSDictionary *> * {
        NSMutableArray *flat = [NSMutableArray array];
        for (NSDictionary *sec in buildSections()) {
            [flat addObjectsFromArray:sec[@"rows"] ?: @[]];
        }
        return flat;
    };
    return v;
}
- (NSString *)displaySafeSourceURL:(NSString *)raw {
    NSURLComponents *components=[NSURLComponents componentsWithString:raw?:@""];
    if(!components.host.length||![@[@"http",@"https"] containsObject:components.scheme.lowercaseString])return @"播放地址已隐藏";
    BOOL hidden=components.user.length||components.password.length;
    components.user=nil;components.password=nil;components.fragment=nil;
    NSString *value=components.string?:@"播放地址已隐藏";
    return hidden?[value stringByAppendingString:@" · 凭据已隐藏"]:value;
}
- (void)updatePlayerChannelLogoForChannel:(NSDictionary *)channel {
    NSString *logo=[channel[@"logo"] isKindOfClass:NSString.class]?channel[@"logo"]:@"";NSString *identifier=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    BOOL showCornerLogo=(channel!=nil&&[ProfileStore isPlayerCornerLogoEnabledForChannel:channel]);
    self.playerChannelLogo.hidden=!showCornerLogo;
    if(!showCornerLogo){self.playerChannelLogo.image=nil;self.playerChannelLogo.accessibilityIdentifier=@"";self.playerChannelLogo.backgroundColor=UIColor.clearColor;self.playerChannelLogo.layer.cornerRadius=0;self.playerChannelLogo.clipsToBounds=NO;return;}
    if(logo.length){self.playerChannelLogo.image=CCTVChannelLogoImage(channel);self.playerChannelLogo.accessibilityIdentifier=logo;self.playerChannelLogo.backgroundColor=UIColor.clearColor;self.playerChannelLogo.layer.cornerRadius=0;self.playerChannelLogo.clipsToBounds=NO;if(self.firstRender)[[HostImageLoader shared] loadURL:logo intoImageView:self.playerChannelLogo];}
    else{self.playerChannelLogo.image=channel?CCTVChannelLogoImage(channel):nil;self.playerChannelLogo.accessibilityIdentifier=identifier.length?[@"channel-logo:" stringByAppendingString:identifier]:@"";BOOL dark=CCTVChannelNeedsDarkLogoBacking(channel,identifier);self.playerChannelLogo.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;self.playerChannelLogo.layer.cornerRadius=dark?5:0;self.playerChannelLogo.clipsToBounds=dark;}
}
- (void)loadPlayerChannelLogoAfterFirstFrame {
    NSDictionary *activeChannel=[self channelWithID:self.channelID];
    if(activeChannel&&![ProfileStore isPlayerCornerLogoEnabledForChannel:activeChannel]){self.playerChannelLogo.hidden=YES;self.playerChannelLogo.image=nil;return;}
    NSString *url=self.playerChannelLogo.accessibilityIdentifier;if([NSURL URLWithString:url].host.length&&self.firstRender)[[HostImageLoader shared] loadURL:url intoImageView:self.playerChannelLogo];
}
- (void)handleProfileLogoOrMetadataChange:(NSNotification *)note {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self handleProfileLogoOrMetadataChange:note];});return;}
    NSDictionary *active=[self channelWithID:self.channelID];
    if(active)[self updatePlayerChannelLogoForChannel:active];
    [self refreshChannelPreviewSnapshotsForChannels:self.shownChannels force:NO];
    if(self.isViewLoaded){[self.table reloadData];[self.channelGrid reloadData];[self refreshConfigurationPage];}
}
- (void)applyResourcePreviewOrTelemetryToggleForSource:(NSString *)source enabled:(BOOL)enabled isPreview:(BOOL)isPreview {
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *subURL=service?[ServiceStore subscriptionURLForService:service]?:@"":@"";
    if(isPreview){
        [ProfileStore setChannelPreviewEnabled:enabled forSource:source];
        if(subURL.length)[ProfileStore setChannelPreviewEnabled:enabled forSource:subURL];
        if(enabled)[self refreshChannelPreviewSnapshotsForChannels:self.shownChannels force:YES];
    }else{
        [ProfileStore setChannelTelemetryEnabled:enabled forSource:source];
        if(subURL.length)[ProfileStore setChannelTelemetryEnabled:enabled forSource:subURL];
    }
    [self.table reloadData];[self.channelGrid reloadData];[self refreshConfigurationPage];
}
- (NSString *)channelPreviewCacheDirectory {
    NSString *caches=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
    NSString *dir=[caches stringByAppendingPathComponent:@"ChannelPreviewSnapshots"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}
- (NSString *)channelPreviewDiskPathForChannelID:(NSString *)cid {
    if(!cid.length)return nil;
    uint64_t hash=1469598103934665603ULL;
    NSData *utf8=[cid dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes=utf8.bytes;
    for(NSUInteger i=0;i<utf8.length;i++){hash^=bytes[i];hash*=1099511628211ULL;}
    return [[self channelPreviewCacheDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"snap_%016llx.jpg",hash]];
}
- (UIImage *)cachedRealPreviewImageForChannelID:(NSString *)cid {
    if(!cid.length)return nil;
    if(!self.channelPreviewSnapshots)self.channelPreviewSnapshots=[NSMutableDictionary dictionary];
    UIImage *mem=self.channelPreviewSnapshots[cid];
    if(mem)return mem;
    NSString *path=[self channelPreviewDiskPathForChannelID:cid];
    if(path.length&&[NSFileManager.defaultManager fileExistsAtPath:path]){
        UIImage *diskImg=[UIImage imageWithContentsOfFile:path];
        if(diskImg){
            if(self.channelPreviewSnapshots.count>=128)[self.channelPreviewSnapshots removeAllObjects];
            self.channelPreviewSnapshots[cid]=diskImg;
            return diskImg;
        }
    }
    return nil;
}
- (void)storeRealPreviewImage:(UIImage *)image forChannelID:(NSString *)cid {
    if(!image||!cid.length)return;
    if(!self.channelPreviewSnapshots)self.channelPreviewSnapshots=[NSMutableDictionary dictionary];
    if(!self.channelPreviewCapturedAt)self.channelPreviewCapturedAt=[NSMutableDictionary dictionary];
    if(self.channelPreviewSnapshots.count>=128)[self.channelPreviewSnapshots removeAllObjects];
    self.channelPreviewSnapshots[cid]=image;
    self.channelPreviewCapturedAt[cid]=@(NSDate.date.timeIntervalSince1970);
    [self.channelPreviewRefreshPending removeObject:cid];
    NSString *path=[self channelPreviewDiskPathForChannelID:cid];
    if(path.length){
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,0),^{
            NSData *jpg=UIImageJPEGRepresentation(image,0.78);
            if(jpg.length)[jpg writeToFile:path atomically:YES];
        });
    }
}
- (void)refreshChannelPreviewSnapshotsForChannels:(NSArray<NSDictionary *> *)channels force:(BOOL)force {
    if(!channels.count)return;
    if(!self.channelPreviewRefreshPending)self.channelPreviewRefreshPending=[NSMutableSet set];
    NSMutableArray<NSDictionary *> *candidates=[NSMutableArray array];
    for(NSDictionary *ch in channels){
        if(![ch isKindOfClass:NSDictionary.class])continue;
        if(![ProfileStore isChannelPreviewEnabledForChannel:ch])continue;
        NSString *cid=[ch[@"id"] isKindOfClass:NSString.class]?ch[@"id"]:@"";
        if(!cid.length)continue;
        if(force)[self.channelPreviewRefreshPending addObject:cid];
        [candidates addObject:ch];
    }
    NSUInteger limit=MIN((NSUInteger)6,candidates.count);
    for(NSUInteger idx=0;idx<limit;idx++){
        [self detectRealPreviewFrameForChannel:candidates[idx] force:force];
    }
}
- (void)detectRealPreviewFrameForChannel:(NSDictionary *)channel force:(BOOL)force {
    if(![channel isKindOfClass:NSDictionary.class])return;
    if(![ProfileStore isChannelPreviewEnabledForChannel:channel])return;
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    if(!cid.length)return;
    if(!self.channelPreviewInflight)self.channelPreviewInflight=[NSMutableSet set];
    if(!self.channelPreviewGenerators)self.channelPreviewGenerators=[NSMutableDictionary dictionary];
    if(!self.channelPreviewCapturedAt)self.channelPreviewCapturedAt=[NSMutableDictionary dictionary];
    if(!self.channelPreviewRefreshPending)self.channelPreviewRefreshPending=[NSMutableSet set];
    BOOL isPendingRefresh=[self.channelPreviewRefreshPending containsObject:cid];
    if(!force&&!isPendingRefresh&&(self.channelPreviewCapturedAt[cid]!=nil||[self cachedRealPreviewImageForChannelID:cid]!=nil)){
        return;
    }
    if([self.channelPreviewInflight containsObject:cid]||self.channelPreviewInflight.count>=2)return;
    NSString *probeURLStr=[self primaryProbeURLForChannel:channel];
    NSURL *probeURL=probeURLStr.length?[NSURL URLWithString:probeURLStr]:nil;
    if(!probeURL||!probeURL.host.length)return;
    [self.channelPreviewInflight addObject:cid];
    [self.channelPreviewRefreshPending removeObject:cid];
    self.channelPreviewCapturedAt[cid]=@(NSDate.date.timeIntervalSince1970);
    NSDictionary *headers=[channel[@"headers"] isKindOfClass:NSDictionary.class]?channel[@"headers"]:nil;
    NSDictionary *options=headers.count?@{@"AVURLAssetHTTPHeaderFieldsKey":headers}:nil;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:probeURL options:options];
    AVAssetImageGenerator *generator=[AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    generator.appliesPreferredTrackTransform=YES;
    generator.maximumSize=CGSizeMake(320,180);
    generator.requestedTimeToleranceBefore=kCMTimePositiveInfinity;
    generator.requestedTimeToleranceAfter=kCMTimePositiveInfinity;
    self.channelPreviewGenerators[cid]=generator;
    __weak typeof(self) weakSelf=self;
    __weak AVAssetImageGenerator *weakGen=generator;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        RootViewController *owner=weakSelf;
        if(!owner)return;
        if(owner.channelPreviewGenerators[cid]==weakGen){
            [weakGen cancelAllCGImageGeneration];
            [owner.channelPreviewGenerators removeObjectForKey:cid];
            [owner.channelPreviewInflight removeObject:cid];
        }
    });
    [generator generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:CMTimeMakeWithSeconds(0.1,600)]]
                                    completionHandler:^(__unused CMTime requestedTime,CGImageRef imageRef,__unused CMTime actualTime,AVAssetImageGeneratorResult result,__unused NSError *error){
        UIImage *captured=(result==AVAssetImageGeneratorSucceeded&&imageRef!=NULL)?[UIImage imageWithCGImage:imageRef]:nil;
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.channelPreviewInflight removeObject:cid];
            [owner.channelPreviewGenerators removeObjectForKey:cid];
            if(captured){
                [owner storeRealPreviewImage:captured forChannelID:cid];
                [owner reloadVisibleCatalogItemForChannelID:cid];
            }
            if(owner.channelPreviewRefreshPending.count){
                NSString *nextID=owner.channelPreviewRefreshPending.anyObject;
                NSDictionary *nextCh=nextID.length?[owner channelWithID:nextID]:nil;
                if(nextCh)[owner detectRealPreviewFrameForChannel:nextCh force:YES];
                else if(nextID.length)[owner.channelPreviewRefreshPending removeObject:nextID];
            }
        });
    }];
}
- (UIImage *)previewImageForChannel:(NSDictionary *)channel {
    if(![channel isKindOfClass:NSDictionary.class])return nil;
    if(![ProfileStore isChannelPreviewEnabledForChannel:channel])return nil;
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    if(!cid.length)return nil;
    UIImage *realSnapshot=[self cachedRealPreviewImageForChannelID:cid];
    BOOL needsRefresh=[self.channelPreviewRefreshPending containsObject:cid];
    if(needsRefresh||(!realSnapshot&&!self.channelPreviewCapturedAt[cid])){
        [self detectRealPreviewFrameForChannel:channel force:needsRefresh];
    }
    return realSnapshot;
}
- (void)captureLivePreviewSnapshotForChannelID:(NSString *)cid {
    if(!cid.length||!self.firstRender)return;
    NSDictionary *ch=[self channelWithID:cid];
    if(ch&&![ProfileStore isChannelPreviewEnabledForChannel:ch])return;
    AVAsset *activeAsset=self.avPlayer.currentItem.asset;
    if(activeAsset){
        AVAssetImageGenerator *generator=[AVAssetImageGenerator assetImageGeneratorWithAsset:activeAsset];
        generator.appliesPreferredTrackTransform=YES;
        generator.maximumSize=CGSizeMake(320,180);
        generator.requestedTimeToleranceBefore=kCMTimePositiveInfinity;
        generator.requestedTimeToleranceAfter=kCMTimePositiveInfinity;
        CMTime targetTime=CMTIME_IS_NUMERIC(self.avPlayer.currentItem.currentTime)?self.avPlayer.currentItem.currentTime:CMTimeMakeWithSeconds(0.1,600);
        __weak typeof(self) weakSelf=self;
        [generator generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:targetTime]]
                                        completionHandler:^(__unused CMTime requestedTime,CGImageRef imageRef,__unused CMTime actualTime,AVAssetImageGeneratorResult result,__unused NSError *error){
            if(result==AVAssetImageGeneratorSucceeded&&imageRef!=NULL){
                UIImage *realFrame=[UIImage imageWithCGImage:imageRef];
                dispatch_async(dispatch_get_main_queue(),^{
                    RootViewController *owner=weakSelf;if(!owner)return;
                    [owner storeRealPreviewImage:realFrame forChannelID:cid];
                    [owner reloadVisibleCatalogItemForChannelID:cid];
                });
            }
        }];
        return;
    }
    if(!self.playerBox||CGRectIsEmpty(self.playerBox.bounds))return;
    UIGraphicsImageRendererFormat *fmt=[UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale=1.0;fmt.opaque=YES;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(160,90) format:fmt];
    UIImage *snap=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *ctx){
        [self.playerBox drawViewHierarchyInRect:CGRectMake(0,0,160,90) afterScreenUpdates:NO];
    }];
    if(snap)[self storeRealPreviewImage:snap forChannelID:cid];
}
- (NSString *)primaryProbeURLForChannel:(NSDictionary *)channel {
    if(![channel isKindOfClass:NSDictionary.class])return @"";
    NSString *remote=[channel[@"remoteURL"] isKindOfClass:NSString.class]?channel[@"remoteURL"]:@"";
    if([ProfileStore isHTTP:remote])return remote;
    NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];
    for(NSDictionary *r in routes){
        if(![r isKindOfClass:NSDictionary.class])continue;
        NSString *u=[r[@"url"] isKindOfClass:NSString.class]?r[@"url"]:@"";
        if([ProfileStore isHTTP:u])return u;
    }
    return @"";
}
- (NSString *)telemetryBadgeTextForChannel:(NSDictionary *)channel color:(UIColor * __autoreleasing *)colorOut {
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    NSDictionary *entry=cid.length?self.channelTelemetryStore[cid]:nil;
    NSString *url=[self primaryProbeURLForChannel:channel];
    if(!url.length)return @"未测";
    if([self.channelTelemetryInflight containsObject:cid])return @"检测";
    BOOL sameURL=[entry[@"probeURL"] isEqual:url];
    if(!entry||!sameURL)return @"未测";
    if(NSDate.date.timeIntervalSince1970-[entry[@"ts"] doubleValue]>=60.0)return @"过期";
    if(![entry[@"ok"] boolValue]){
        if(colorOut)*colorOut=[UIColor colorWithRed:1.0 green:0.32 blue:0.28 alpha:1.0];
        return @"失败";
    }
    double ms=[entry[@"requestMs"] doubleValue];
    double kbps=[entry[@"sampleKBps"] doubleValue];
    if(colorOut){
        *colorOut=(ms>350.0)?[UIColor colorWithRed:1.0 green:0.68 blue:0.18 alpha:1.0]:[UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1.0];
    }
    if(kbps>=1024.0 && ms>0)return [NSString stringWithFormat:@"%.1fM/s · %.0fms",kbps/1024.0,ms];
    if(kbps>0 && ms>0)return [NSString stringWithFormat:@"%.0fK/s · %.0fms",kbps,ms];
    if(ms>0)return [NSString stringWithFormat:@"%.0fms",ms];
    return @"可达";
}
- (NSString *)telemetryAccessibilityValueForChannel:(NSDictionary *)channel selected:(BOOL)selected {
    NSMutableArray<NSString *> *details=[NSMutableArray array];
    if(selected){
        if(self.nativePlaybackFailed||self.remotePlaybackFailed)[details addObject:@"当前频道，播放失败，可重试"];
        else if(self.firstRender)[details addObject:[self sessionIsPlaying]?@"正在播放":@"当前频道，已暂停"];
        else if([self sessionHasContent]||CACurrentMediaTime()<self.playbackPriorityUntil)[details addObject:@"当前频道，正在连接"];
        else [details addObject:@"当前频道"];
        if(self.firstRender&&self.firstFrameSeconds>0)[details addObject:[NSString stringWithFormat:@"首帧 %.1f 秒",self.firstFrameSeconds]];
    }
    if(![ProfileStore isChannelTelemetryEnabledForChannel:channel])return details.count?[details componentsJoinedByString:@"；"]:@"频道";
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    NSDictionary *entry=self.channelTelemetryStore[cid];
    NSString *url=[self primaryProbeURLForChannel:channel];
    if(!url.length)[details addObject:@"连接检测不可用"];
    else if([self.channelTelemetryInflight containsObject:cid])[details addObject:@"连接检测中"];
    else if(!entry||![entry[@"probeURL"] isEqual:url])[details addObject:@"连接尚未检测"];
    else if(NSDate.date.timeIntervalSince1970-[entry[@"ts"] doubleValue]>=60.0)[details addObject:@"连接检测已过期"];
    else if(![entry[@"ok"] boolValue])[details addObject:[NSString stringWithFormat:@"连接检测失败，HTTP 状态 %ld",(long)[entry[@"status"] integerValue]]];
    else {
        NSUInteger bytes=[entry[@"sampleBytes"] unsignedIntegerValue];
        double kbps=[entry[@"sampleKBps"] doubleValue];
        NSString *sample=bytes?[NSString stringWithFormat:@"样本 %.1f KB，样本吞吐 %.0f KB/s",bytes/1024.0,kbps]:@"服务器接受了连接，但未返回样本数据";
        [details addObject:[NSString stringWithFormat:@"连接可达，HTTP %ld，响应头 %.0f 毫秒，%@",(long)[entry[@"status"] integerValue],[entry[@"requestMs"] doubleValue],sample]];
    }
    return details.count?[details componentsJoinedByString:@"；"]:@"频道";
}
- (void)probeTelemetryForChannel:(NSDictionary *)channel {
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    if(!cid.length)return;
    if(!self.channelTelemetryStore)self.channelTelemetryStore=[NSMutableDictionary dictionary];
    if(!self.channelTelemetryInflight)self.channelTelemetryInflight=[NSMutableSet set];
    if(!self.channelTelemetryTasks)self.channelTelemetryTasks=[NSMutableDictionary dictionary];
    NSString *probeURLStr=[self primaryProbeURLForChannel:channel];
    NSURL *probeURL=probeURLStr.length?[NSURL URLWithString:probeURLStr]:nil;
    if(!probeURL||!probeURL.host.length)return;
    NSDictionary *existing=self.channelTelemetryStore[cid];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(existing&&[existing[@"probeURL"] isEqual:probeURLStr]&&(now-[existing[@"ts"] doubleValue])<60.0)return;
    if(![existing[@"probeURL"] isEqual:probeURLStr])[self.channelTelemetryStore removeObjectForKey:cid];
    if([self.channelTelemetryInflight containsObject:cid]||self.channelTelemetryInflight.count>=3)return;
    [self.channelTelemetryInflight addObject:cid];
    __weak typeof(self) weakSelf=self;
    MediaChannelProbe *probe=[MediaChannelProbe new];self.channelTelemetryTasks[cid]=probe;
    [probe startWithURL:probeURL completion:^(NSDictionary<NSString *,id> *result){
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.channelTelemetryInflight removeObject:cid];[owner.channelTelemetryTasks removeObjectForKey:cid];
            if(owner.channelTelemetryStore.count>=256)[owner.channelTelemetryStore removeAllObjects];
            NSMutableDictionary *entry=[result mutableCopy];entry[@"probeURL"]=probeURLStr;entry[@"ts"]=@(NSDate.date.timeIntervalSince1970);owner.channelTelemetryStore[cid]=entry;
            [owner reloadVisibleCatalogItemForChannelID:cid];
        });
    }];
}
- (void)applyResourceChannelLogoToggleForSource:(NSString *)source enabled:(BOOL)enabled cornerOnly:(BOOL)cornerOnly {
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *subURL=service?[ServiceStore subscriptionURLForService:service]?:@"":@"";
    if(cornerOnly){
        [ProfileStore setPlayerCornerLogoEnabled:enabled forSource:source];
        if(subURL.length)[ProfileStore setPlayerCornerLogoEnabled:enabled forSource:subURL];
    }else{
        [ProfileStore setChannelLogoEnabled:enabled forSource:source];
        if(subURL.length)[ProfileStore setChannelLogoEnabled:enabled forSource:subURL];
    }
    NSDictionary *active=[self channelWithID:self.channelID];
    if(active)[self updatePlayerChannelLogoForChannel:active];
    [self.table reloadData];[self.channelGrid reloadData];[self refreshConfigurationPage];
}
- (NSArray<NSDictionary *> *)sameStationAlternateChannelsForChannel:(NSDictionary *)channel {
    if(![channel isKindOfClass:NSDictionary.class])return @[];
    NSString *targetID=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    NSString *targetName=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"";
    NSString *canonical=[ProfileStore canonicalStationIDForChannel:channel];
    NSString *groupKey=CCTVRouteGroupKey(channel);
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSMutableArray<NSDictionary *> *matches=[NSMutableArray array];
    NSMutableSet<NSString *> *seenIDs=[NSMutableSet set];
    if(targetID.length)[seenIDs addObject:targetID];
    for(NSDictionary *candidate in self.allChannels){
        NSString *cid=[candidate[@"id"] isKindOfClass:NSString.class]?candidate[@"id"]:@"";
        if(!cid.length||[seenIDs containsObject:cid])continue;
        BOOL isRemote=[candidate[@"remoteURL"] length]>0;
        if(isRemote){
            NSMutableSet *owners=[NSMutableSet setWithArray:[ProfileStore subscriptionSourcesForChannel:candidate]];
            [owners minusSet:disabled];
            if(!owners.count)continue;
        }else if(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)){
            continue;
        }
        NSString *candCanonical=[ProfileStore canonicalStationIDForChannel:candidate];
        BOOL sameStation=(canonical.length&&[canonical isEqualToString:candCanonical])||
                         (groupKey.length&&[groupKey isEqualToString:CCTVRouteGroupKey(candidate)])||
                         (targetName.length&&[targetName isEqualToString:candidate[@"name"]]);
        if(sameStation){
            [seenIDs addObject:cid];
            [matches addObject:candidate];
        }
    }
    return matches.copy;
}
- (void)matchOfficialStationLogosAndEPGForSource:(NSString *)source {
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *effectiveSource=service?([ServiceStore subscriptionURLForService:service]?:source):source;
    NSUInteger matchedCount=0;
    NSMutableArray *updatedChannels=[NSMutableArray arrayWithCapacity:self.allChannels.count];
    for(NSDictionary *ch in self.allChannels){
        BOOL belongs=NO;
        if(!effectiveSource.length){
            belongs=![ch[@"remoteURL"] length];
        }else{
            for(NSString *owner in [ProfileStore subscriptionSourcesForChannel:ch]){
                if([self subscriptionOwner:owner matchesLiveResourceSource:effectiveSource]){belongs=YES;break;}
            }
        }
        if(!belongs){[updatedChannels addObject:ch];continue;}
        NSString *canonical=[ProfileStore canonicalStationIDForChannel:ch];
        if(canonical.length){
            matchedCount++;
            NSMutableDictionary *mut=[ch mutableCopy];
            if(![mut[@"epgID"] length])mut[@"epgID"]=canonical;
            if(![mut[@"group"] length]||[mut[@"group"] isEqualToString:@"订阅"]){
                if([canonical hasPrefix:@"cctv"])mut[@"group"]=@"央视";
                else if([canonical hasPrefix:@"cetv"])mut[@"group"]=@"教育";
                else if([canonical hasPrefix:@"btv"]&&![canonical isEqualToString:@"btv1"])mut[@"group"]=@"地方";
                else mut[@"group"]=@"卫视";
            }
            [updatedChannels addObject:mut.copy];
        }else{
            [updatedChannels addObject:ch];
        }
    }
    self.allChannels=updatedChannels;
    [self.altSources removeAllObjects];
    for(NSDictionary *c in updatedChannels){
        NSString *url=c[@"remoteURL"],*gk=CCTVRouteGroupKey(c);
        if(!url.length||!gk.length)continue;
        if(!self.altSources[gk])self.altSources[gk]=[NSMutableArray array];
        if(![self.altSources[gk] containsObject:url])[self.altSources[gk] addObject:url];
    }
    [self applyFilter];
    NSDictionary *active=[self channelWithID:self.channelID];
    if(active)[self updatePlayerChannelLogoForChannel:active];
    if(self.firstRender)[self refreshNowNext];
    NSString *statusTarget=effectiveSource?:@"";
    [ProfileStore update:statusTarget values:@{@"status":[NSString stringWithFormat:@"已匹配 %lu 个官方台标与节目单",(unsigned long)matchedCount],@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
    [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:statusTarget];
    [self refreshConfigurationPage];
    [self log:@"智能台标与节目单归一匹配完成：识别 %lu 个官方电视台",(unsigned long)matchedCount];
}
- (void)handlePlayerChannelLogoTap {
    NSDictionary *active=[self channelWithID:self.channelID];
    if(!active&&self.channelID.length)active=@{@"id":self.channelID,@"name":self.channelName?:self.channelID,@"remoteURL":self.currentRemoteURL?:@""};
    if(!active)return;
    [self presentStationEnhancementSheetForChannel:active sourceView:self.playerChannelLogo];
}
- (void)presentStationEnhancementSheetForChannel:(NSDictionary *)channel sourceView:(UIView *)sourceView {
    if(![channel isKindOfClass:NSDictionary.class])return;
    NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:(self.channelName?:cid);
    NSString *canonical=[ProfileStore canonicalStationIDForChannel:channel];
    NSDictionary *epg=cid.length?self.epgCache[cid]:nil;
    NSString *nowProgram=[epg[@"now"] isKindOfClass:NSString.class]&&[epg[@"now"] length]?epg[@"now"]:@"暂无实时节目单";
    NSString *nextProgram=[epg[@"next"] isKindOfClass:NSString.class]&&[epg[@"next"] length]?epg[@"next"]:nil;
    NSArray<NSDictionary *> *sameStationList=[self sameStationAlternateChannelsForChannel:channel];
    NSMutableString *summary=[NSMutableString stringWithFormat:@"正在播：%@",nowProgram];
    if(nextProgram.length)[summary appendFormat:@"\n稍后播：%@",nextProgram];
    if(canonical.length)[summary appendFormat:@"\n官方台号归一：%@",canonical.uppercaseString];
    if(sameStationList.count)[summary appendFormat:@" · 发现 %lu 个同台跨源频道",(unsigned long)sameStationList.count];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · 电视台增强",name] message:summary preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for(NSDictionary *alt in sameStationList){
        NSString *altURL=[alt[@"remoteURL"] isKindOfClass:NSString.class]?alt[@"remoteURL"]:@"";
        NSString *sourceLabel=altURL.length?([NSURL URLWithString:altURL].host?:@"订阅源"):@"央视官方源";
        NSString *title=[NSString stringWithFormat:@"切换同台源 · %@ (%@)",alt[@"name"]?:name,sourceLabel];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf selectChannel:alt];}]];
    }
    NSArray *owners=[ProfileStore subscriptionSourcesForChannel:channel];
    NSString *primarySource=([channel[@"remoteURL"] length]&&owners.count)?owners.firstObject:@"";
    BOOL cornerOn=[ProfileStore isPlayerCornerLogoEnabledForSource:primarySource];
    BOOL listLogoOn=[ProfileStore isChannelLogoEnabledForSource:primarySource];
    BOOL previewOn=[ProfileStore isChannelPreviewEnabledForSource:primarySource];
    BOOL telemetryOn=[ProfileStore isChannelTelemetryEnabledForSource:primarySource];
    [sheet addAction:[UIAlertAction actionWithTitle:cornerOn?@"隐藏此资源播放器右上角台标":@"显示此资源播放器右上角台标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf applyResourceChannelLogoToggleForSource:primarySource enabled:!cornerOn cornerOnly:YES];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:listLogoOn?@"关闭此资源全部台标显示":@"开启此资源全部台标显示" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf applyResourceChannelLogoToggleForSource:primarySource enabled:!listLogoOn cornerOnly:NO];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:previewOn?@"关闭此资源频道预览图":@"开启此资源频道预览图" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf applyResourcePreviewOrTelemetryToggleForSource:primarySource enabled:!previewOn isPreview:YES];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:telemetryOn?@"关闭此资源速率与延迟显示":@"开启此资源速率与延迟显示" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf applyResourcePreviewOrTelemetryToggleForSource:primarySource enabled:!telemetryOn isPreview:NO];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"查看本台完整节目单（EPG）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf openEPGforChannel:cid name:name];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"智能匹配官方高清台标与 EPG" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[weakSelf matchOfficialStationLogosAndEPGForSource:primarySource];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor=sourceView?:self.playerChannelLogo?:self.view;
    sheet.popoverPresentationController.sourceView=anchor;
    sheet.popoverPresentationController.sourceRect=anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
