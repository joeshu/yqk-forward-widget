#import "RootViewController_Internal.h"

@implementation RootViewController (EPG)

#pragma mark - EPG 缓存

- (NSString *)epgCachePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"epg-cache.json"];
}

- (void)loadEPGCache {
    NSData *data = [NSData dataWithContentsOfFile:[self epgCachePath]];
    if (!data) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return;
    double now = NSDate.date.timeIntervalSince1970;
    [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (![obj isKindOfClass:NSDictionary.class]) return;
        double ts = [obj[@"ts"] doubleValue];
        if (ts > 0 && ts <= now && now - ts < 6 * 3600 &&
            [obj[@"now"] isKindOfClass:NSString.class]) self.epgCache[key] = obj;
    }];
    [self trimEPGCache];
    [self log:@"EPG 缓存载入 %lu 条", (unsigned long)self.epgCache.count];
}

- (void)saveEPGCache {
    if(self.epgWriteScheduled)return;self.epgWriteScheduled=YES;__weak typeof(self) w=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        w.epgWriteScheduled=NO;NSDictionary *snapshot=w.epgCache.copy;NSString *path=[w epgCachePath];if(!snapshot||!path.length)return;
        dispatch_async(w.epgDiskQueue, ^{NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];[data writeToFile:path atomically:YES];});
    });
}

- (void)loadEPGForChannel:(NSString *)cid channel:(NSDictionary *)channel section:(NSIndexPath *)ip {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) return;
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    if (!cid.length || self.epgCache[cid] || [self.epgInflight containsObject:cid]) return;
    // cellForRow 已持有该频道字典：直接复用，避免每次出现新 cell 都对
    // 全量频道做两次线性查找（约 2 万条时滚动掉帧）。
    if(!channel)channel=[self channelWithID:cid];NSString *xmlSource=[ProfileStore epgSourceForChannel:channel];
    if(xmlSource.length){NSArray *rows=[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:channel]];[self cacheXMLRows:rows channel:cid];if(self.epgCache[cid])return;}
    if (self.epgInflight.count >= 3) return;
    NSString *epgCID=[self epgIDForChannel:channel];
    if(!epgCID.length)return;
    [self.epgInflight addObject:cid];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [epgCID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 8;
    NSUInteger listGeneration=self.epgListGeneration;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 先清理在途标记再判代次：代次不匹配时若直接 return，该频道会永久
            // 留在 epgInflight 里，此后 loadEPGForChannel 每次都因
            // containsObject: 提前返回，EPG 再也加载不出来。
            [weakSelf.epgListTasks removeObjectForKey:cid];
            [weakSelf.epgInflight removeObject:cid];
            if(listGeneration!=weakSelf.epgListGeneration)return;
            if (!data.length) return;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSArray *rows = [json isKindOfClass:NSDictionary.class] ? [(NSDictionary *)json objectForKey:@"EPG"] : nil;
            if (![rows isKindOfClass:NSArray.class]) return;
            double now = NSDate.date.timeIntervalSince1970;
            NSString *cur = nil, *nxt = nil;
            for (NSDictionary *row in rows) {
                if (![row isKindOfClass:NSDictionary.class]) continue;
                double s0 = [row[@"startTime"] doubleValue], e0 = [row[@"endTime"] doubleValue];
                if (s0 > 1e11) s0 /= 1000; if (e0 > 1e11) e0 /= 1000;
                NSString *title=[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil;
                if (now >= s0 && now < e0) cur = title;
                else if (s0 > now && !nxt) nxt = title;
            }
            if (cur || nxt) {
                weakSelf.epgCache[cid] = @{@"now": cur ?: @"", @"next": nxt ?: @"", @"ts": @(now)};
                [weakSelf saveEPGCache];
                [weakSelf reloadVisibleCatalogItemForChannelID:cid];
            }
        });
    }];self.epgListTasks[cid]=task;[task resume];
}

#pragma mark - 节目单

- (void)openEPG {
    if (!self.channelID.length) { [self log:@"请先选择频道"]; return; }
    [self openEPGforChannel:self.channelID name:self.channelName];
}

- (NSString *)epgIDForChannel:(NSDictionary *)ch {
    if(!ch)return nil;if(![ch[@"remoteURL"] length])return ch[@"id"];
    NSString *key=[[ProfileStore epgIDForChannel:ch] lowercaseString];NSDictionary *matched=key.length?[self channelWithID:key]:nil;if(matched&&![matched[@"remoteURL"] length])return key;
    NSString *canonical=[ProfileStore canonicalStationIDForChannel:ch];
    if(canonical.length){NSDictionary *nativeMatch=[self channelWithID:canonical];if(nativeMatch&&![nativeMatch[@"remoteURL"] length])return canonical;}
    for(NSDictionary *native in self.allChannels){if([native[@"remoteURL"] length])continue;if([native[@"name"] isEqualToString:ch[@"tvgName"]]||[native[@"name"] isEqualToString:ch[@"name"]])return native[@"id"];}
    return nil;
}
- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name {
    [self.navigationController pushViewController:[self epgPageForChannel:cid name:name] animated:YES];
}

- (void)restartEPGTimer {
    self.epgRefreshDesired=CCTVBoolPreference(@"autoLoadEPG",YES);
    if (!self.epgRefreshDesired || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || CACurrentMediaTime()<self.playbackPriorityUntil) { [self.epgTimer invalidate]; self.epgTimer=nil; return; }
    [self.epgTimer invalidate];
    self.epgTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshNowNext) userInfo:nil repeats:YES];
}

- (void)refreshNowNext {
    if(!CCTVBoolPreference(@"autoLoadEPG",YES)||!self.firstRender)return;
    NSDictionary *channel=[self channelWithID:self.channelID];NSString *source=[ProfileStore epgSourceForChannel:channel];
    if(!source.length){[self refreshOfficialNowNext];return;}
    NSString *cid=self.channelID;NSUInteger epgGeneration=self.playbackGeneration;__weak typeof(self) w=self;
    [[XMLTVStore shared] loadSource:source channel:[ProfileStore epgIDForChannel:channel] force:NO completion:^(NSArray *rows,NSError *error){
        if(epgGeneration!=w.playbackGeneration||![w.channelID isEqualToString:cid])return;
        if(rows.count){[w cacheXMLRows:rows channel:cid];[w saveEPGCache];[w reloadVisibleCatalogItemForChannelID:cid];}
        else if(error.code!=NSURLErrorCancelled)[w refreshOfficialNowNext];
    }];
}
- (void)refreshOfficialNowNext {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||CACurrentMediaTime()<self.playbackPriorityUntil) return;
    NSString *cid = self.channelID;
    if (!cid.length) return;
    self.epgChannel = cid;
    NSDictionary *cached = self.epgCache[cid];
    if (cached && [cached[@"ts"] doubleValue] <= NSDate.date.timeIntervalSince1970 &&
        NSDate.date.timeIntervalSince1970 - [cached[@"ts"] doubleValue] < 6 * 3600) {
        NSMutableArray *cachedParts = [NSMutableArray array];
        if ([cached[@"now"] length]) [cachedParts addObject:[NSString stringWithFormat:@"正在播：%@", cached[@"now"]]];
        if ([cached[@"next"] length]) [cachedParts addObject:[NSString stringWithFormat:@"接下来：%@", cached[@"next"]]];
        if (cachedParts.count) self.infoLabel.text = [cachedParts componentsJoinedByString:@"  "];
    }
    NSString *officialID=[self epgIDForChannel:[self channelWithID:cid]];if(!officialID.length)return;
    NSUInteger epgGeneration = self.playbackGeneration;
    NSUInteger requestGeneration=++self.officialEPGRequestGeneration;
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [officialID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 8;

    __weak typeof(self) weakSelf = self;
    [self.epgTask cancel];
    self.epgTask = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data.length) return;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSArray *rows = [(NSDictionary *)json objectForKey:@"EPG"];
        if (![rows isKindOfClass:NSArray.class]) return;
        double now = NSDate.date.timeIntervalSince1970;
        NSString *cur = nil, *next = nil;
        for (NSDictionary *row in rows) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            double s0 = [row[@"startTime"] doubleValue], e0 = [row[@"endTime"] doubleValue];
            if (s0 > 1e11) s0 /= 1000; if (e0 > 1e11) e0 /= 1000;
            NSString *title=[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil;
            if (now >= s0 && now < e0) cur = title;
            else if (s0 > now && !next) next = title;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf.epgChannel isEqualToString:cid] || requestGeneration!=weakSelf.officialEPGRequestGeneration || epgGeneration != weakSelf.playbackGeneration ||
                ![weakSelf.channelID isEqualToString:cid]) return;
            if (cur || next) {
                weakSelf.epgCache[cid] = @{@"now": cur ?: @"", @"next": next ?: @"", @"ts": @(now)};
                [weakSelf trimEPGCache];
                [weakSelf saveEPGCache];
                [weakSelf reloadVisibleCatalogItemForChannelID:cid];
            }
            NSMutableArray *parts = [NSMutableArray array];
            if (cur) [parts addObject:[NSString stringWithFormat:@"正在播：%@", cur]];
            if (next) [parts addObject:[NSString stringWithFormat:@"接下来：%@", next]];
            if (parts.count) weakSelf.infoLabel.text = [parts componentsJoinedByString:@"  "];
        });
    }];
    [self.epgTask resume];
}

- (EPGViewController *)epgPageForChannel:(NSString *)cid name:(NSString *)name {
    NSDictionary *channel=[self channelWithID:cid]?:@{@"id":cid?:@"",@"name":name?:@"节目单"};
    EPGViewController *page=[[EPGViewController alloc] initWithChannel:channel officialID:[self epgIDForChannel:channel]?:@""];
    if(![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:cid]){
        __weak typeof(self) weakSelf=self;
        page.onReplay=^(NSDictionary *program){
            RootViewController *owner=weakSelf;if(!owner||!cid.length)return;
            [owner.navigationController popToViewController:owner animated:YES];
            owner.playerTabs.selectedSegmentIndex=1;[owner selectPlayerPanel];
            if(![owner.channelID isEqualToString:cid] || !owner.currentPlayer || owner.avPlayer || !owner.firstRender){
                owner.pendingNativeReplayProgram=@{@"channelID":cid?:@"",@"start":@([program[@"start"] doubleValue]),@"end":@([program[@"end"] doubleValue])};
                if(channel&&(![owner.channelID isEqualToString:cid] || !owner.currentPlayer || owner.avPlayer))[owner selectChannel:channel];
                return;
            }
            [owner seekNativeStart:[program[@"start"] doubleValue] end:[program[@"end"] doubleValue]];
        };
    }
    if([channel[@"catchupSource"] isKindOfClass:NSString.class]&&[channel[@"catchupSource"] length]){
        M3UChannel *catchup=[M3UChannel new];catchup.url=channel[@"remoteURL"];catchup.catchupSource=channel[@"catchupSource"];catchup.catchupMode=channel[@"catchupMode"]?:@"default";catchup.catchupDays=[channel[@"catchupDays"] doubleValue];catchup.tvgShift=[channel[@"tvgShift"] doubleValue];
        page.canReplay=^BOOL(NSDictionary *program){return [catchup catchupURLForStart:[NSDate dateWithTimeIntervalSince1970:[program[@"start"] doubleValue]] end:[NSDate dateWithTimeIntervalSince1970:[program[@"end"] doubleValue]]]!=nil;};
        __weak typeof(self) weakSelf=self;
        page.onReplay=^(NSDictionary *program){RootViewController *owner=weakSelf;NSURL *url=[catchup catchupURLForStart:[NSDate dateWithTimeIntervalSince1970:[program[@"start"] doubleValue]] end:[NSDate dateWithTimeIntervalSince1970:[program[@"end"] doubleValue]]];if(!owner||!url)return;NSMutableDictionary *replay=[channel mutableCopy];replay[@"remoteURL"]=url.absoluteString;replay[@"headers"]=MediaPlaybackHeadersScopedToURL(channel[@"headers"],[NSURL URLWithString:channel[@"remoteURL"]?:@""],url);[owner.navigationController popToViewController:owner animated:YES];[owner playRemote:replay];};
    }
    return page;
}
- (void)cacheXMLRows:(NSArray *)rows channel:(NSString *)cid {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSString *current=nil,*next=nil;for(NSDictionary *r in rows){if(![r isKindOfClass:NSDictionary.class])continue;double start=[r[@"start"] doubleValue],end=[r[@"end"] doubleValue];NSString *title=[r[@"title"] isKindOfClass:NSString.class]?r[@"title"]:nil;if(now>=start&&now<end)current=title;else if(start>now&&!next)next=title;}
    if(current||next){self.epgCache[cid]=@{@"now":current?:@"",@"next":next?:@"",@"ts":@(now)};[self trimEPGCache];}
}
- (void)trimEPGCache {
    // EPG 缓存无上限会随频道浏览持续增长；保留最近的 128 条，按 ts 淘汰最旧。
    while(self.epgCache.count>128){
        NSString *oldest=nil;NSTimeInterval oldestTS=DBL_MAX;
        for(NSString *key in self.epgCache){NSTimeInterval ts=[self.epgCache[key][@"ts"] doubleValue];if(ts<oldestTS){oldestTS=ts;oldest=key;}}
        if(!oldest.length)break;
        [self.epgCache removeObjectForKey:oldest];
    }
}
@end
