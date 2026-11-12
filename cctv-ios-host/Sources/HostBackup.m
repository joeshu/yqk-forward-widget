#import "HostBackup.h"
#import "ProfileStore.h"
@implementation HostBackup
+ (NSArray<NSString *> *)preferenceKeys {return @[@"legacyNativePlayback",@"resumeLastChannel",@"rememberLastChannel",@"autoLoadEPG",@"allowBackgroundAudio",@"autoPiP",@"channelGridMode",@"nativeChannelsEnabled",@"nativeChannelLogoEnabled",@"nativeChannelPreviewEnabled",@"nativeChannelTelemetryEnabled",@"cctv.adaptationMonitor.enabled",@"cctv.mediaEpisodeShowBadge.v1",@"cctv.mediaEpisodeAutoExpand.v1",@"cctv.mediaAutoPlayNext",@"cctv.mediaKeepScreenAwake",@"media.globalSearchHistoryEnabled.v1",@"preloadNativeChannel",@"fastNativeStartup",@"nativeSDKVerboseLogs",@"runtimeDiagnosticsEnabled",@"cctv.restoreLastTab.v1",@"cctv.mediaAutoSkipIntroOutro",@"hostDarkTheme"];}
+ (NSArray<NSString *> *)numberPreferenceKeys {return @[@"cctv.mediaPlaybackRate",@"cctv.channelGridColumns.v1",@"cctv.channelSortMode.v1",@"cctv.mediaGridColumns.v1",@"cctv.networkTimeout.v1",@"cctv.appFontSize.v1",@"cctv.mediaEpisodeLayoutStyle.v1"];}
+ (NSArray<NSString *> *)stringPreferenceKeys {return @[@"cctv.mediaVideoGravity",@"cctv.mediaPreferredQuality.v1",@"hostThemeMode",@"cctv.themeIdentifier.v1"];}
+ (NSDictionary *)snapshot {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;NSMutableDictionary *preferences=[NSMutableDictionary dictionary];for(NSString *key in self.preferenceKeys)if([d objectForKey:key])preferences[key]=@([d boolForKey:key]);for(NSString *key in self.numberPreferenceKeys)if([[d objectForKey:key] isKindOfClass:NSNumber.class])preferences[key]=[d objectForKey:key];for(NSString *key in self.stringPreferenceKeys)if([[d objectForKey:key] isKindOfClass:NSString.class])preferences[key]=[d objectForKey:key];
    NSMutableDictionary *profiles=[NSMutableDictionary dictionary];NSArray *subscriptions=[d arrayForKey:@"subscriptions"]?:@[];
    for(NSString *source in subscriptions){NSMutableDictionary *p=[[ProfileStore metadata:source] mutableCopy];[p removeObjectForKey:@"cachedChannels"];[p removeObjectForKey:@"status"];[p removeObjectForKey:@"updatedAt"];profiles[source]=p;}
    return @{@"format":@"CCTVHost",@"version":@2,@"subscriptions":subscriptions,@"favorites":[d arrayForKey:@"favorites"]?:@[],@"preferences":preferences,@"profiles":profiles,@"order":[ProfileStore orderedSources:subscriptions],@"disabled":[d arrayForKey:@"disabledSubscriptions"]?:@[],@"epgMappings":[d dictionaryForKey:@"epgMappings"]?:@{},@"recents":[d arrayForKey:@"recents"]?:@[]};
}
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error {
    id json=data.length&&data.length<=32*1024*1024?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    NSDictionary *j=[json isKindOfClass:NSDictionary.class]?json:@{};id version=j[@"version"];
    BOOL valid=[j[@"format"] isEqual:@"CCTVHost"]&&([version isEqual:@1]||[version isEqual:@2])&&[j[@"subscriptions"] isKindOfClass:NSArray.class]&&[j[@"favorites"] isKindOfClass:NSArray.class]&&[j[@"preferences"] isKindOfClass:NSDictionary.class];
    NSArray *sources=valid?j[@"subscriptions"]:@[];NSArray *favorites=valid?j[@"favorites"]:@[];BOOL v2=[version isEqual:@2];
    valid=valid&&sources.count<=500&&favorites.count<=10000;
    for(id s in sources)if(!(v2?[ProfileStore isSource:s]:[ProfileStore isHTTP:s]))valid=NO;
    for(id cid in favorites)if(![cid isKindOfClass:NSString.class]||[cid length]>8192)valid=NO;
    if(valid)for(NSString *key in j[@"preferences"]){id value=j[@"preferences"][key];if([self.preferenceKeys containsObject:key]){if(![value isKindOfClass:NSNumber.class])valid=NO;}else if([self.numberPreferenceKeys containsObject:key]){if(![value isKindOfClass:NSNumber.class])valid=NO;else if([key isEqualToString:@"cctv.mediaPlaybackRate"]&&([value doubleValue]<0.5||[value doubleValue]>2.0))valid=NO;else if([key isEqualToString:@"cctv.channelGridColumns.v1"]&&([value integerValue]!=3&&[value integerValue]!=4))valid=NO;else if([key isEqualToString:@"cctv.mediaGridColumns.v1"]&&([value integerValue]!=3&&[value integerValue]!=4))valid=NO;else if([key isEqualToString:@"cctv.channelSortMode.v1"]&&([value integerValue]!=0&&[value integerValue]!=1))valid=NO;else if([key isEqualToString:@"cctv.networkTimeout.v1"]&&([value doubleValue]<5||[value doubleValue]>40))valid=NO;else if([key isEqualToString:@"cctv.appFontSize.v1"]&&([value integerValue]<0||[value integerValue]>2))valid=NO;else if([key isEqualToString:@"cctv.mediaEpisodeLayoutStyle.v1"]&&([value integerValue]<0||[value integerValue]>3))valid=NO;}else if([self.stringPreferenceKeys containsObject:key]){if(![value isKindOfClass:NSString.class])valid=NO;else if([key isEqualToString:@"cctv.mediaVideoGravity"]&&![@[@"AVLayerVideoGravityResizeAspect",@"AVLayerVideoGravityResizeAspectFill",@"AVLayerVideoGravityResize"] containsObject:value])valid=NO;else if([key isEqualToString:@"cctv.mediaPreferredQuality.v1"]&&![@[@"auto",@"smooth",@"hd",@"uhd"] containsObject:value])valid=NO;else if([key isEqualToString:@"hostThemeMode"]&&![@[@"system",@"light",@"dark"] containsObject:value])valid=NO;else if([key isEqualToString:@"cctv.themeIdentifier.v1"]&&![@[@"midnight",@"obsidian",@"ocean",@"amber",@"daylight",@"snow"] containsObject:value])valid=NO;}else valid=NO;if(!valid)break;}
    if(valid&&v2){
        NSDictionary *profiles=j[@"profiles"],*mappings=j[@"epgMappings"];NSArray *order=j[@"order"],*disabled=j[@"disabled"],*recents=j[@"recents"];
        valid=[profiles isKindOfClass:NSDictionary.class]&&[mappings isKindOfClass:NSDictionary.class]&&[order isKindOfClass:NSArray.class]&&[disabled isKindOfClass:NSArray.class]&&[recents isKindOfClass:NSArray.class];
        if(valid){
            for(id source in profiles){id p=profiles[source];if(![sources containsObject:source]||![p isKindOfClass:NSDictionary.class]){valid=NO;break;}
                for(id key in p)if(![@[@"name",@"text",@"epgURL",@"detectedEPGURL"] containsObject:key]||![p[key] isKindOfClass:NSString.class])valid=NO;
                if(!valid)break;
                if([p[@"text"] length]>10*1024*1024)valid=NO;
                for(NSString *key in @[@"epgURL",@"detectedEPGURL"])if([p[key] length]&&![ProfileStore isHTTP:p[key]])valid=NO;
            }
            for(NSString *source in sources)if(![ProfileStore isHTTP:source]&&![profiles[source][@"text"] length])valid=NO;
            for(id source in [order arrayByAddingObjectsFromArray:disabled])if(![sources containsObject:source])valid=NO;
            if(mappings.count>10000||recents.count>100)valid=NO;
            for(id key in mappings)if(![key isKindOfClass:NSString.class]||![mappings[key] isKindOfClass:NSString.class]||[mappings[key] length]>8192)valid=NO;
            for(id r in recents){if(![r isKindOfClass:NSDictionary.class]||![r[@"id"] isKindOfClass:NSString.class]||![r[@"name"] isKindOfClass:NSString.class]){valid=NO;break;}for(id key in r)if(![@[@"id",@"name",@"group",@"remoteURL"] containsObject:key]||![r[key] isKindOfClass:NSString.class])valid=NO;if(r[@"remoteURL"]&&![ProfileStore isHTTP:r[@"remoteURL"]])valid=NO;}
        }
    }
    if(!valid){if(error)*error=[NSError errorWithDomain:@"CCTVHostBackup" code:1 userInfo:@{NSLocalizedDescriptionKey:@"备份格式无效或超过限制；本机配置未修改。"}];return nil;}return j;
}
+ (void)restore:(NSDictionary *)backup {
    // 纵深防御：调用方应传 validatedBackup: 的输出，但 restore 本身也要校验，
    // 避免类型错误的备份写坏 NSUserDefaults（例如非数组的 subscriptions）。
    if(![backup isKindOfClass:NSDictionary.class])return;
    NSArray *subscriptions=backup[@"subscriptions"],*favorites=backup[@"favorites"];NSDictionary *preferences=backup[@"preferences"];
    if(![subscriptions isKindOfClass:NSArray.class]||![favorites isKindOfClass:NSArray.class]||![preferences isKindOfClass:NSDictionary.class])return;
    for(id s in subscriptions)if(![s isKindOfClass:NSString.class])return;
    for(id f in favorites)if(![f isKindOfClass:NSString.class])return;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setObject:subscriptions forKey:@"subscriptions"];[d setObject:favorites forKey:@"favorites"];
    for(NSString *key in self.preferenceKeys)[d removeObjectForKey:key];for(NSString *key in self.numberPreferenceKeys)[d removeObjectForKey:key];for(NSString *key in self.stringPreferenceKeys)[d removeObjectForKey:key];for(NSString *key in preferences)if(([self.preferenceKeys containsObject:key]||[self.numberPreferenceKeys containsObject:key])&&[preferences[key] isKindOfClass:NSNumber.class])[d setObject:preferences[key] forKey:key];else if([self.stringPreferenceKeys containsObject:key]&&[preferences[key] isKindOfClass:NSString.class])[d setObject:preferences[key] forKey:key];
    [d setObject:[backup[@"profiles"] isKindOfClass:NSDictionary.class]?backup[@"profiles"]:@{} forKey:@"profileMetadata"];[d setObject:[backup[@"order"] isKindOfClass:NSArray.class]?backup[@"order"]:@[] forKey:@"profileOrder"];[d setObject:[backup[@"disabled"] isKindOfClass:NSArray.class]?backup[@"disabled"]:@[] forKey:@"disabledSubscriptions"];[d setObject:[backup[@"epgMappings"] isKindOfClass:NSDictionary.class]?backup[@"epgMappings"]:@{} forKey:@"epgMappings"];[d setObject:[backup[@"recents"] isKindOfClass:NSArray.class]?backup[@"recents"]:@[] forKey:@"recents"];
}
@end
