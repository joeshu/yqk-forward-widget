#import "HostBackup.h"
#import "ServiceStore.h"
#import "ProfileStore.h"
#import "HostLogBuffer.h"
#import "MediaMetadataCache.h"
#import "MediaPlaybackStateStore.h"
#import "MediaSourceHealthStore.h"
#import <dispatch/dispatch.h>
#import <Foundation/Foundation.h>
static void check(BOOL ok, NSString *message) {
    if (!ok) {
        NSLog(@"FAILED: %@", message);
        exit(1);
    }
}
static NSData *encode(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}
int main(void) {
    @autoreleasepool {
        NSString *pythonPlaylist=@"from flask import Flask\napp = Flask(__name__)\n@app.route('/all.m3u')\ndef playlist():\n    return '#EXTM3U\\n#EXTINF:-1,测试频道\\nhttps://example.com/live.m3u8'\n";
        check([[ServiceStore inferredPlaylistPathInCode:pythonPlaylist] isEqual:@"/all.m3u"],@"Python HTTP M3U route is inferred from its actual route declaration");
        NSString *javascriptPlaylist=@"app.get('/channels.m3u', (req, res) => res.send('#EXTM3U\\n#EXTINF:-1,频道'))";
        check([[ServiceStore inferredPlaylistPathInCode:javascriptPlaylist] isEqual:@"/channels.m3u"],@"JavaScript HTTP M3U route is inferred from its actual route declaration");
        NSString *commentedJavascript=@"// app.get('/channels.m3u', (req, res) => res.send('#EXTM3U'))";
        check([ServiceStore inferredPlaylistPathInCode:commentedJavascript]==nil,@"commented JavaScript examples are not inferred as live playlist routes");
        NSString *commentOnly=@"# @app.route('/all.m3u')\n# return '#EXTM3U'\n";
        check([ServiceStore inferredPlaylistPathInCode:commentOnly]==nil,@"commented examples never become automatic service subscriptions");
        check([[ServiceStore subscriptionURLForService:@{@"id":@"python-http-fixture",@"port":@18769,@"protocol":@"python-http",@"playlistPath":@"/all.m3u"}] isEqual:@"http://127.0.0.1:18769/all.m3u"],@"Python HTTP service creates its exact loopback subscription address");
        NSDictionary *jsMediaService=@{@"id":@"js-media-fixture",@"engine":@"node",@"protocol":@"cctvhost.media/1",@"port":@18771,@"manifest":@{@"schemaVersion":@1}};
        check([ServiceStore playlistPathForService:jsMediaService]==nil,@"unverified JavaScript media host is not advertised as an active subscription");
        check([[ServiceStore playlistPathCandidatesForService:jsMediaService] isEqual:@[@"/all.m3u"]],@"JavaScript media host exposes its real M3U route as a detection candidate");
        NSMutableDictionary *verifiedJSService=[jsMediaService mutableCopy];verifiedJSService[@"playlistPath"]=@"/all.m3u";verifiedJSService[@"playlistPathSource"]=@"detected";
        check([[ServiceStore subscriptionURLForService:verifiedJSService] isEqual:@"http://127.0.0.1:18771/all.m3u"],@"verified JavaScript M3U path becomes a local subscription URL");
        NSString *managedURL=@"http://127.0.0.1:18769/all.m3u",*unrelatedURL=@"https://other.example/live.m3u",*guideURL=@"https://guide.example/xmltv.xml";
        [NSUserDefaults.standardUserDefaults setObject:@[unrelatedURL,managedURL] forKey:@"subscriptions"];
        [ProfileStore update:unrelatedURL values:@{@"managedServiceID":@"another-service",@"epgURL":@"https://other.example/epg.xml"}];
        [ProfileStore update:managedURL values:@{@"managedServiceID":@"python-http-fixture",@"detectedEPGURL":guideURL}];
        NSDictionary *managedService=@{@"id":@"python-http-fixture",@"port":@18769,@"protocol":@"python-http",@"playlistPath":@"/all.m3u"};
        check([[ServiceStore epgURLForService:managedService] isEqual:guideURL],@"service EPG resolves from its exact managed playlist instead of another source");
        [NSUserDefaults.standardUserDefaults setObject:@[unrelatedURL] forKey:@"subscriptions"];
        check([ServiceStore epgURLForService:@{@"id":@"python-http-fixture",@"port":@18770,@"protocol":@"python-http"}]==nil,@"service without a route never inherits another subscription EPG");
        [ProfileStore update:unrelatedURL values:@{@"managedServiceID":@"python-http-fixture",@"epgURL":guideURL}];
        check([[ServiceStore epgURLForService:@{@"id":@"python-http-fixture",@"port":@18770,@"protocol":@"python-http"}] isEqual:guideURL],@"explicit service EPG remains available during local port migration");
        NSString *legacyURL=@"http://127.0.0.1:18768/custom.m3u";[NSUserDefaults.standardUserDefaults setObject:@[legacyURL,unrelatedURL] forKey:@"subscriptions"];[ProfileStore update:legacyURL values:@{@"name":@"旧服务频道"}];
        [ServiceStore associateLegacyLoopbackSubscriptionsForService:@{@"id":@"legacy-http-fixture",@"port":@18768}];
        check([[ProfileStore metadata:legacyURL][@"managedServiceID"] isEqual:@"legacy-http-fixture"],@"legacy loopback playlist is linked to its matching service port");
        check([[ProfileStore metadata:legacyURL][@"name"] isEqual:@"旧服务频道"],@"linking legacy playlist preserves its user label");
        check(![ProfileStore metadata:unrelatedURL][@"managedServiceID"]||[[ProfileStore metadata:unrelatedURL][@"managedServiceID"] isEqual:@"python-http-fixture"],@"legacy association never claims a remote or differently managed source");
        HostLogBuffer *logs=[[HostLogBuffer alloc] initWithMaximumCharacters:64];
        check([logs append:@"first"], @"first log schedules a notification");
        check(![logs append:@"second"], @"pending log delivery is coalesced");
        check([[logs drain] isEqual:@"firstsecond"], @"drain preserves unsaturated log order");
        check([logs append:[[@"😀" stringByPaddingToLength:100000 withString:@"😀" startingAtIndex:0] stringByAppendingString:@"x"]], @"new batch schedules again");
        NSString *tail=[logs drain];check(tail.length<=64 && [tail dataUsingEncoding:NSUTF8StringEncoding]!=nil,@"oversized unicode log is bounded without splitting surrogate pairs");
        __block NSUInteger notifications=0;
        dispatch_apply(2000,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t index){@autoreleasepool {
            if([logs append:[NSString stringWithFormat:@"线程 %zu 😀\\n",index]]){@synchronized(logs){notifications++;}}
        }});
        check(notifications==1 && logs.length<=64,@"concurrent log flood has one pending notification and bounded memory");
        tail=[logs drain];check([tail dataUsingEncoding:NSUTF8StringEncoding]!=nil,@"concurrent log tail remains valid UTF-8");
        [logs append:@"old"];[logs clear];check([[logs drain] isEqual:@""],@"clear drops pending output");
        check([logs append:@"new"],@"clear permits a fresh notification");
        NSDictionary *valid = @{
            @"format" : @"CCTVHost",
            @"version" : @1,
            @"subscriptions" : @[ @"https://example.com/live.m3u" ],
            @"favorites" : @[ @"cctv1" ],
            @"preferences" : @{@"autoLoadEPG" : @NO}
        };
        check([HostBackup validatedBackup:encode(valid) error:NULL] != nil, @"valid backup accepted");
        for (id data in @[
                 [NSData data], encode(@[]), encode(@{@"format" : @"CCTVHost"}),
                 [@"{bad json" dataUsingEncoding:NSUTF8StringEncoding]
             ])
            check([HostBackup validatedBackup:data error:NULL] == nil, @"malformed backup rejected");
        check([HostBackup validatedBackup:nil error:NULL] == nil, @"missing file rejected without exception");
        NSMutableDictionary *bad = [valid mutableCopy];
        bad[@"subscriptions"] = @[ @42 ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"non-string URL rejected");
        bad[@"subscriptions"] = @[ @"file:///etc/hosts" ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"local file URL rejected");
        bad[@"subscriptions"] = @[ @"https://" ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"hostless URL rejected");
        bad = [valid mutableCopy];
        bad[@"preferences"] = @{@"activePythonService" : @YES};
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"unrecognized preference rejected");
        bad[@"preferences"] = @{@"autoLoadEPG" : @"yes"};
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"wrong preference type rejected");
        [HostBackup restore:valid];
        check([[NSUserDefaults.standardUserDefaults arrayForKey:@"favorites"] isEqual:valid[@"favorites"]],
              @"favorites restored");
        check(![NSUserDefaults.standardUserDefaults boolForKey:@"autoLoadEPG"], @"false preference restored");
        check([HostBackup validatedBackup:encode([HostBackup snapshot]) error:NULL] != nil,
              @"export round-trip");
        MediaMetadataCache *metadata=[MediaMetadataCache shared];[metadata clear];
        NSDictionary *mediaSource=@{@"id":@"source-a",@"port":@18781,@"protocol":@"python-spider",@"packageRoot":@"/package/a"};
        NSDictionary *searchArgs=@{@"keyword":@"news",@"page":@1,@"provider":@"site-a"};
        NSDictionary *searchResult=@{@"items":@[@{@"id":@"title-1",@"name":@"News"}],@"hasMore":@NO};
        [metadata storeResult:searchResult forSource:mediaSource operation:@"search" arguments:searchArgs];
        BOOL stale=YES;
        check([[metadata resultForSource:mediaSource operation:@"search" arguments:searchArgs maximumAge:3600 isStale:&stale][@"items"] count]==1&&!stale,@"fresh metadata cache returns an exact source and query match");
        check([metadata resultForSource:mediaSource operation:@"search" arguments:@{@"keyword":@"other",@"page":@1,@"provider":@"site-a"} maximumAge:3600 isStale:NULL]==nil,@"metadata cache isolates different search arguments");
        NSMutableDictionary *otherSource=[mediaSource mutableCopy];otherSource[@"id"]=@"source-b";
        check([metadata resultForSource:otherSource operation:@"search" arguments:searchArgs maximumAge:3600 isStale:NULL]==nil,@"metadata cache isolates different plugin sources");
        [metadata storeResult:@{@"url":@"https://media.example/video.m3u8"} forSource:mediaSource operation:@"play" arguments:searchArgs];
        check([metadata resultForSource:mediaSource operation:@"play" arguments:searchArgs maximumAge:3600 isStale:NULL]==nil,@"resolved playback URLs are never cached");
        NSDictionary *detailWithSignedEpisode=@{@"lines":@[@{@"episodes":@[@{@"id":@"https://cdn.example/video.m3u8?token=secret"}]}]};
        NSDictionary *detailArguments=@{@"id":@"film-1"};
        [metadata storeResult:detailWithSignedEpisode forSource:mediaSource operation:@"detail" arguments:detailArguments];
        check([metadata resultForSource:mediaSource operation:@"detail" arguments:detailArguments maximumAge:3600 isStale:NULL]==nil,@"episode identifiers that may contain signed URLs are never cached");
        [metadata storeResult:@{@"value":[@"x" stringByPaddingToLength:1024*1024+1 withString:@"x" startingAtIndex:0]} forSource:mediaSource operation:@"detail" arguments:@{@"id":@"large"}];
        check([metadata resultForSource:mediaSource operation:@"detail" arguments:@{@"id":@"large"} maximumAge:3600 isStale:NULL]==nil,@"oversized metadata entries are rejected");
        NSMutableDictionary *persistentSource=[mediaSource mutableCopy];persistentSource[@"id"]=[NSString stringWithFormat:@"persistent-%@",NSUUID.UUID.UUIDString];
        NSDictionary *homeArguments=@{@"provider":@"site-a"};
        NSDictionary *homeResult=@{@"items":@[@{@"id":@"film-1",@"name":@"Cached Film",@"poster":@"https://images.example/poster.jpg",@"playURL":@"https://cdn.example/video.m3u8?token=private-secret"}],@"categories":@[@{@"id":@"1",@"name":@"剧集"}]};
        [metadata storeResult:homeResult forSource:persistentSource operation:@"home" arguments:homeArguments];
        __block NSDictionary *restoredHome=nil;
        for(NSUInteger attempt=0;attempt<40&&!restoredHome;attempt++){@autoreleasepool{[NSThread sleepForTimeInterval:0.05];MediaMetadataCache *reopened=[MediaMetadataCache new];restoredHome=[reopened resultForSource:persistentSource operation:@"home" arguments:homeArguments maximumAge:3600 isStale:NULL];}}
        NSDictionary *restoredItem=[restoredHome[@"items"] isKindOfClass:NSArray.class]?[restoredHome[@"items"] firstObject]:nil;
        check([restoredItem[@"name"] isEqual:@"Cached Film"]&&[restoredItem[@"poster"] isEqual:@"https://images.example/poster.jpg"],@"home metadata survives a fresh cache instance and retains poster content");
        check(restoredItem[@"playURL"]==nil,@"persistent home cache excludes playback URLs and credentials");
        [metadata removeResultsForSourceID:@"source-a"];
        check([metadata resultForSource:mediaSource operation:@"search" arguments:searchArgs maximumAge:3600 isStale:NULL]==nil,@"source cache invalidation removes its metadata");
        [metadata clear];
        [MediaPlaybackStateStore clearWatchHistory];
        NSDictionary *historyContext=@{@"source":@{@"id":@"history-source",@"name":@"Fixture source"},@"provider":@"site-a",@"item":@{@"id":@"film-1",@"name":@"Fixture film"},@"detail":@{@"name":@"Fixture film",@"lines":@[@{@"id":@"line-a",@"episodes":@[@{@"id":@"episode-1",@"name":@"第1集"},@{@"id":@"episode-2",@"name":@"第2集"}]}]}};
        [MediaPlaybackStateStore recordContext:historyContext lineIndex:0 episodeIndex:0 position:45 duration:120 completed:NO];
        [MediaPlaybackStateStore recordContext:historyContext lineIndex:0 episodeIndex:1 position:0 duration:120 completed:NO];
        check([MediaPlaybackStateStore.watchHistory count]==2,@"watch history stores distinct episodes");
        NSString *removedHistoryKey=MediaPlaybackStateStore.watchHistory.firstObject[@"key"];
        [MediaPlaybackStateStore removeHistoryEntryWithKey:removedHistoryKey];
        check([MediaPlaybackStateStore.watchHistory count]==1&&![[MediaPlaybackStateStore.watchHistory.firstObject objectForKey:@"key"] isEqual:removedHistoryKey],@"single history removal preserves other entries");
        [MediaPlaybackStateStore clearWatchHistory];
        check(MediaPlaybackStateStore.watchHistory.count==0,@"clear watch history removes all entries");
        MediaSourceHealthStore *health=MediaSourceHealthStore.shared;NSString *healthID=@"health-fixture";
        [health recordSourceID:healthID success:NO elapsed:1.0];check([health isDeprioritizedSourceID:healthID],@"failed source receives bounded retry cooldown");
        [health recordSourceID:healthID success:YES elapsed:0.2];check(![health isDeprioritizedSourceID:healthID],@"successful source clears its retry cooldown");
        [NSUserDefaults.standardUserDefaults setObject:@{@"expired-fixture":@{@"updated":@(NSDate.date.timeIntervalSince1970-8*24*60*60),@"cooldownUntil":@(NSDate.date.timeIntervalSince1970+300)}} forKey:@"cctv.mediaSourceHealth.v1"];
        check(![health isDeprioritizedSourceID:@"expired-fixture"],@"expired source health state no longer affects scheduling");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.mediaSourceHealth.v1"];
        NSString *sid = NSUUID.UUID.UUIDString;
        NSDictionary *service = @{@"id" : sid, @"name" : @"Test service", @"port" : @18768};
        [ServiceStore save:service];
        NSUInteger matches = 0;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:sid])
                matches++;
        check(matches == 1, @"service persisted once");
        [ServiceStore save:@{@"id" : sid, @"name" : @"Updated", @"port" : @18769}];
        matches = 0;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:sid]) {
                matches++;
                check([s[@"name"] isEqual:@"Updated"], @"service edit persisted");
            }
        check(matches == 1, @"edit replaces existing service");
        [ServiceStore remove:sid];
        for (NSDictionary *s in [ServiceStore services])
            check(![s[@"id"] isEqual:sid], @"service removed");
        NSString *portableID=NSUUID.UUID.UUIDString;
        NSString *portableBase=[[ServiceStore directory] stringByAppendingPathComponent:portableID];
        NSString *package=[portableBase stringByAppendingPathComponent:@"package/中文目录"];
        [NSFileManager.defaultManager createDirectoryAtPath:package withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"class Spider: pass" writeToFile:[package stringByAppendingPathComponent:@"看剧 AI.py"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *legacy=@{@"id":portableID,@"name":@"看剧AI",@"port":@18781,@"engine":@"python",@"protocol":@"python-spider",@"packageRoot":[NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Services/%@/package/中文目录",portableID],@"archivePath":[NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Services/%@/source.zip",portableID],@"manifest":@{@"runtime":@"python",@"moduleType":@"esm",@"entry":@"看剧 AI.py",@"options":@{@"fixture":@YES}}};
        NSMutableArray *seed=[[NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"] mutableCopy];if(!seed)seed=[NSMutableArray array];[seed addObject:legacy];[NSUserDefaults.standardUserDefaults setObject:seed forKey:@"pythonServices"];
        NSDictionary *portable=nil;for(NSDictionary *row in [ServiceStore services])if([row[@"id"] isEqual:portableID])portable=row;
        check([portable[@"packageRoot"] isEqual:package],@"sandbox UUID changes rebase only the same service's package");
        check([NSFileManager.defaultManager fileExistsAtPath:[ServiceStore codePath:legacy]],@"stale in-memory snapshots also resolve the Chinese entry filename");
        check([portable[@"packageRelativePath"] isEqual:@"package/中文目录"]&&[portable[@"archiveRelativePath"] isEqual:@"source.zip"],@"portable relative paths are persisted for future container moves");
        check([portable[@"manifest"][@"options"] isEqual:legacy[@"manifest"][@"options"]]&&[portable[@"manifest"][@"moduleType"] isEqual:@"script"],@"migration preserves options and corrects the Python display type");
        NSMutableDictionary *invalid=[legacy mutableCopy];invalid[@"packageRoot"]=@"/unrelated/package";invalid[@"packageRelativePath"]=@"../another-service/package";
        check([[ServiceStore resolvedService:invalid][@"packageRoot"] isEqual:@"/unrelated/package"],@"relative traversal is never rebased into another service");
        [ServiceStore remove:portableID];
        [ServiceStore remove:@"builtin-ysp"];
        BOOL builtin = NO;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:@"builtin-ysp"])
                builtin = YES;
        check(builtin, @"bundled service preserved");
        [ServiceStore remove:@"builtin-yangshipin-js"];
        NSDictionary *javascript=nil;
        for(NSDictionary *s in [ServiceStore services])if([s[@"id"] isEqual:@"builtin-yangshipin-js"])javascript=s;
        check(javascript && [javascript[@"engine"] isEqual:@"javascript"], @"JS service preserved with explicit engine");
        check([javascript[@"port"] integerValue]==18770, @"JS service has separate subscription port");
        NSString *jsData=[ServiceStore dataDirectoryForService:javascript error:NULL];
        check([jsData.lastPathComponent isEqual:@"builtin-yangshipin-js"], @"JS data does not share legacy YSP directory");
        NSString *migrationID = NSUUID.UUID.UUIDString;
        NSString *prior = [[ServiceStore directory] stringByAppendingPathComponent:@"builtin-ysp"];
        NSString *historical =
            [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                    .firstObject stringByAppendingPathComponent:@"ysp"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:prior withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:historical withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *existing = [migrationID stringByAppendingString:@"-existing"],
                 *missing = [migrationID stringByAppendingString:@"-missing"];
        [@"keep-old-identity" writeToFile:[historical stringByAppendingPathComponent:existing]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:NULL];
        [@"do-not-overwrite" writeToFile:[prior stringByAppendingPathComponent:existing]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:NULL];
        [@"recover-new-state" writeToFile:[prior stringByAppendingPathComponent:missing]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:NULL];
        NSString *dataDir = [ServiceStore dataDirectoryForService:@{
            @"id" : @"builtin-ysp",
            @"builtin" : @YES
        }
                                                            error:NULL];
        check([dataDir isEqualToString:historical], @"built-in service returns to historical data directory");
        check([[NSString stringWithContentsOfFile:[dataDir stringByAppendingPathComponent:existing]
                                         encoding:NSUTF8StringEncoding
                                            error:NULL] isEqualToString:@"keep-old-identity"],
              @"migration never overwrites old device identity");
        check([[NSString stringWithContentsOfFile:[dataDir stringByAppendingPathComponent:missing]
                                         encoding:NSUTF8StringEncoding
                                            error:NULL] isEqualToString:@"recover-new-state"],
              @"missing state recovered from v0.16 directory");
        for (NSString *folder in @[ prior, historical ])
            for (NSString *name in @[ existing, missing ])
                [fm removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL];
        NSLog(@"Native backup and service persistence checks passed");
    }
    return 0;
}
