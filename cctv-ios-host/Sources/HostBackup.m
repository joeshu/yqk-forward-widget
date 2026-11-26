#import "HostBackup.h"
#import "ProfileStore.h"
#import "HostLibraryStore.h"
static NSArray<NSString *> *booleanPreferenceKeys(void){return @[@"nativeChannelsEnabled",@"resumeLastChannel",@"rememberLastChannel",@"autoLoadEPG",@"allowBackgroundAudio",@"autoPiP",@"legacyNativePlayback",@"preloadNativeChannel",@"fastNativeStartup",@"nativeSDKVerboseLogs",@"runtimeDiagnosticsEnabled",@"cctv.adaptationMonitor.enabled",@"channelGridMode",@"nativeChannelLogoEnabled",@"nativePlayerCornerLogoEnabled",@"nativeChannelPreviewEnabled",@"nativeChannelTelemetryEnabled",@"cctv.restoreLastTab.v1",@"cctv.mediaAutoPlayNext",@"cctv.mediaAutoSkipIntroOutro",@"cctv.mediaKeepScreenAwake",@"cctv.mediaEpisodeShowBadge.v1",@"cctv.mediaEpisodeAutoExpand.v1",@"media.globalSearchHistoryEnabled.v1",@"hostDarkTheme"];}
static NSArray<NSString *> *numberPreferenceKeys(void){return @[@"cctv.mediaPlaybackRate",@"cctv.channelGridColumns.v1",@"cctv.channelSortMode.v1",@"cctv.mediaGridColumns.v1",@"cctv.mediaEpisodeLayoutStyle.v1",@"cctv.networkTimeout.v1",@"cctv.appFontSize.v1"];}
static NSArray<NSString *> *stringPreferenceKeys(void){return @[@"cctv.mediaVideoGravity",@"cctv.mediaPreferredQuality.v1",@"hostThemeMode",@"cctv.themeIdentifier.v1"];}
@implementation HostBackup
+ (NSArray<NSString *> *)arrayPreferenceKeys {return @[@"disabledChannelLogoSources",@"disabledPlayerCornerLogoSources",@"disabledChannelPreviewSources",@"disabledChannelTelemetrySources",@"enabledChannelLogoSources",@"enabledPlayerCornerLogoSources",@"enabledChannelPreviewSources",@"enabledChannelTelemetrySources",@"resourceUnifiedOrder",@"cctv.mediaHome.modules.v1"];}
+ (NSDictionary *)snapshot {
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults];NSMutableDictionary *p=[NSMutableDictionary dictionary];
    for(NSString *k in booleanPreferenceKeys())if([d objectForKey:k])p[k]=@([d boolForKey:k]);
    for(NSString *k in numberPreferenceKeys())if([d objectForKey:k])p[k]=[d objectForKey:k];
    for(NSString *k in stringPreferenceKeys()){id v=[d stringForKey:k];if(v)p[k]=v;}
    for(NSString *k in [self arrayPreferenceKeys]){NSArray *v=[d arrayForKey:k];if([v isKindOfClass:NSArray.class])p[k]=v;}
    NSArray *subs=[d arrayForKey:@"subscriptions"]?:@[];NSMutableDictionary *profiles=[NSMutableDictionary dictionary];
    NSArray *profileKeys=@[@"name",@"epgURL",@"detectedEPGURL",@"text",@"status",@"updatedAt",@"cachedChannels",@"unsupportedProtocols",@"managedServiceID",@"tvboxCatalogID",@"tvboxLiveEntryName",@"userAgent",@"inlinePlaylist",@"importFingerprint",@"importSourceFilename",@"count"];
    for(NSString *s in subs){NSDictionary *m=[ProfileStore metadata:s];NSMutableDictionary *saved=[NSMutableDictionary dictionary];for(NSString *key in profileKeys)if(m[key])saved[key]=m[key];if(saved.count)profiles[s]=saved;}
    NSMutableDictionary *snap=[@{@"format":@"CCTVHost",@"version":@3,@"subscriptions":subs,@"favorites":[HostLibraryStore.shared allFavorites]?:@[],@"profiles":profiles,@"profileOrder":[d arrayForKey:@"profileOrder"]?:@[],@"disabledSubscriptions":[d arrayForKey:@"disabledSubscriptions"]?:@[],@"epgMappings":[d dictionaryForKey:@"epgMappings"]?:@{},@"preferences":p} mutableCopy];
    NSMutableArray *catalogs=[NSMutableArray array],*dependencies=[NSMutableArray array];
    for(id value in [d arrayForKey:@"tvboxCatalogs"]?:@[]) {
        if(![value isKindOfClass:NSDictionary.class]||![value[@"id"] isKindOfClass:NSString.class]||![value[@"id"] length])continue;
        NSMutableDictionary *catalog=[value mutableCopy];[catalog removeObjectForKey:@"_sourceConfigData"];
        if([NSJSONSerialization isValidJSONObject:catalog]&&[NSPropertyListSerialization propertyList:catalog isValidForFormat:NSPropertyListBinaryFormat_v1_0])[catalogs addObject:catalog];
        else [dependencies addObject:@{@"kind":@"catalog",@"id":value[@"id"],@"name":[value[@"name"] isKindOfClass:NSString.class]?value[@"name"]:@"资源合集"}];
    }
    for(id service in [d arrayForKey:@"pythonServices"]?:@[]) {
        if(![service isKindOfClass:NSDictionary.class]||![service[@"id"] isKindOfClass:NSString.class]||![service[@"id"] length]||[service[@"builtin"] boolValue])continue;
        [dependencies addObject:@{@"kind":@"service",@"id":service[@"id"],@"name":[service[@"name"] isKindOfClass:NSString.class]?service[@"name"]:@"脚本资源"}];
    }
    snap[@"catalogs"]=catalogs;snap[@"resourceDependencies"]=dependencies;
    NSArray *recents=[HostLibraryStore.shared recents];
    if([recents isKindOfClass:NSArray.class]&&[NSJSONSerialization isValidJSONObject:recents])snap[@"recents"]=recents;
    NSDictionary *vodFavorites=HostLibraryStore.shared.mediaFavorites;
    if([vodFavorites isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:vodFavorites])snap[@"vodFavorites"]=vodFavorites;
    NSArray *watchHistory=HostLibraryStore.shared.mediaWatchHistory;
    if([watchHistory isKindOfClass:NSArray.class]){
        NSMutableArray *rows=[NSMutableArray array];
        for(id value in watchHistory){
            if(![value isKindOfClass:NSDictionary.class])continue;
            NSMutableDictionary *row=[value mutableCopy];
            if([row[@"updatedAt"] isKindOfClass:NSDate.class])row[@"updatedAt"]=@([row[@"updatedAt"] timeIntervalSince1970]);
            if([NSJSONSerialization isValidJSONObject:row])[rows addObject:row];
        }
        snap[@"watchHistory"]=rows;
    }
    NSDictionary *skipPoints=[d dictionaryForKey:@"cctv.mediaSkipPoints.v1"];
    if([skipPoints isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:skipPoints])snap[@"skipPoints"]=skipPoints;
    NSDictionary *epgReminders=[d dictionaryForKey:@"cctv.epgReminders.v1"];
    if([epgReminders isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:epgReminders])snap[@"epgReminders"]=epgReminders;
    return snap.copy;
}
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error {
    id root=nil;
    NSInteger version=0;
    if(!data.length||data.length>32*1024*1024)goto invalid;
    root=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![root isKindOfClass:NSDictionary.class])goto invalid;
    if(![root[@"version"] isKindOfClass:NSNumber.class])goto invalid;
    version=[root[@"version"] integerValue];
    if([root[@"version"] doubleValue]!=(double)version)goto invalid;
    if(![root[@"format"] isEqual:@"CCTVHost"]||(version!=1&&version!=2&&version!=3))goto invalid;
    if(![root[@"subscriptions"] isKindOfClass:NSArray.class]||![root[@"favorites"] isKindOfClass:NSArray.class]||![root[@"preferences"] isKindOfClass:NSDictionary.class])goto invalid;
    for(id u in root[@"subscriptions"])if(![ProfileStore isSource:u])goto invalid;
    for(id f in root[@"favorites"])if(![f isKindOfClass:NSString.class]||![f length]||[f length]>512)goto invalid;
    if(root[@"profiles"]){if(![root[@"profiles"] isKindOfClass:NSDictionary.class])goto invalid;for(id k in root[@"profiles"]){id v=root[@"profiles"][k];if(![ProfileStore isSource:k]||![v isKindOfClass:NSDictionary.class])goto invalid;for(id mk in v){id mv=v[mk];if((![mk isEqual:@"name"]&&![mk isEqual:@"epgURL"]&&![mk isEqual:@"detectedEPGURL"]&&![mk isEqual:@"text"]&&![mk isEqual:@"status"]&&![mk isEqual:@"updatedAt"]&&![mk isEqual:@"cachedChannels"]&&![mk isEqual:@"unsupportedProtocols"]&&![mk isEqual:@"managedServiceID"]&&![mk isEqual:@"tvboxCatalogID"]&&![mk isEqual:@"tvboxLiveEntryName"]&&![mk isEqual:@"userAgent"]&&![mk isEqual:@"inlinePlaylist"]&&![mk isEqual:@"importFingerprint"]&&![mk isEqual:@"importSourceFilename"]&&![mk isEqual:@"count"])||(([mk isEqual:@"updatedAt"]||[mk isEqual:@"count"])?![mv isKindOfClass:NSNumber.class]:([mk isEqual:@"cachedChannels"]?![mv isKindOfClass:NSArray.class]:([mk isEqual:@"unsupportedProtocols"]?![mv isKindOfClass:NSDictionary.class]:![mv isKindOfClass:NSString.class]))))goto invalid;if(([mk isEqual:@"epgURL"]||[mk isEqual:@"detectedEPGURL"])&&[mv length]&&![ProfileStore isHTTP:mv])goto invalid;}}}
    for(NSString *k in @[@"profileOrder",@"disabledSubscriptions"])if(root[k]){if(![root[k] isKindOfClass:NSArray.class])goto invalid;for(id s in root[k])if(![ProfileStore isSource:s])goto invalid;}
    if(root[@"epgMappings"]){if(![root[@"epgMappings"] isKindOfClass:NSDictionary.class])goto invalid;for(id k in root[@"epgMappings"])if(![k isKindOfClass:NSString.class]||![root[@"epgMappings"][k] isKindOfClass:NSString.class])goto invalid;}
    if(root[@"recents"]){if(![root[@"recents"] isKindOfClass:NSArray.class])goto invalid;for(id r in root[@"recents"])if(![r isKindOfClass:NSDictionary.class]||![r[@"id"] isKindOfClass:NSString.class]||![r[@"id"] length])goto invalid;}
    if(root[@"vodFavorites"]&&![root[@"vodFavorites"] isKindOfClass:NSDictionary.class])goto invalid;
    if(root[@"watchHistory"]){if(![root[@"watchHistory"] isKindOfClass:NSArray.class])goto invalid;for(id w in root[@"watchHistory"])if(![w isKindOfClass:NSDictionary.class]||![w[@"key"] isKindOfClass:NSString.class]||![w[@"key"] length])goto invalid;}
    if(root[@"skipPoints"]&&![root[@"skipPoints"] isKindOfClass:NSDictionary.class])goto invalid;
    if(root[@"epgReminders"]){if(![root[@"epgReminders"] isKindOfClass:NSDictionary.class]||[root[@"epgReminders"] count]>10000)goto invalid;for(id key in root[@"epgReminders"]){id reminder=root[@"epgReminders"][key];if(![key isKindOfClass:NSString.class]||![key length]||[key length]>512||![reminder isKindOfClass:NSDictionary.class]||![reminder[@"start"] isKindOfClass:NSNumber.class]||![reminder[@"title"] isKindOfClass:NSString.class]||(reminder[@"channelName"]&&![reminder[@"channelName"] isKindOfClass:NSString.class]))goto invalid;}}
    if(root[@"catalogs"]){if(![root[@"catalogs"] isKindOfClass:NSArray.class]||[root[@"catalogs"] count]>64)goto invalid;NSMutableSet *ids=[NSMutableSet set];for(id catalog in root[@"catalogs"]){if(![catalog isKindOfClass:NSDictionary.class]||![catalog[@"id"] isKindOfClass:NSString.class]||![catalog[@"id"] length]||[catalog[@"id"] length]>256||[ids containsObject:catalog[@"id"]])goto invalid;[ids addObject:catalog[@"id"]];}}
    if(root[@"resourceDependencies"]){if(![root[@"resourceDependencies"] isKindOfClass:NSArray.class]||[root[@"resourceDependencies"] count]>4096)goto invalid;for(id item in root[@"resourceDependencies"]){if(![item isKindOfClass:NSDictionary.class]||![@[@"service",@"catalog"] containsObject:item[@"kind"]]||![item[@"id"] isKindOfClass:NSString.class]||![item[@"id"] length]||[item[@"id"] length]>256||![item[@"name"] isKindOfClass:NSString.class]||[item[@"name"] length]>512)goto invalid;}}
    {
        NSSet *boolKeys=[NSSet setWithArray:booleanPreferenceKeys()];
        NSSet *numKeys=[NSSet setWithArray:numberPreferenceKeys()];
        NSSet *strKeys=[NSSet setWithArray:stringPreferenceKeys()];
        NSSet *arrKeys=[NSSet setWithArray:[self arrayPreferenceKeys]];
        for(id k in root[@"preferences"]){
            id value=root[@"preferences"][k];
            if([boolKeys containsObject:k]){
                if(![value isKindOfClass:NSNumber.class])goto invalid;
            }else if([numKeys containsObject:k]){
                if(![value isKindOfClass:NSNumber.class]||strcmp([value objCType],@encode(BOOL))==0)goto invalid;
                if([k isEqual:@"cctv.mediaPlaybackRate"]&&([value doubleValue]<0.5||[value doubleValue]>2.0))goto invalid;
                if([k isEqual:@"cctv.channelGridColumns.v1"]&&[value integerValue]!=3&&[value integerValue]!=4)goto invalid;
                if([k isEqual:@"cctv.channelSortMode.v1"]&&([value integerValue]<0||[value integerValue]>2))goto invalid;
                if([k isEqual:@"cctv.mediaGridColumns.v1"]&&[value integerValue]!=2&&[value integerValue]!=3&&[value integerValue]!=4)goto invalid;
                if([k isEqual:@"cctv.mediaEpisodeLayoutStyle.v1"]&&([value integerValue]<0||[value integerValue]>3))goto invalid;
                if([k isEqual:@"cctv.networkTimeout.v1"]&&([value doubleValue]<5||[value doubleValue]>40))goto invalid;
                if([k isEqual:@"cctv.appFontSize.v1"]&&([value integerValue]<0||[value integerValue]>2))goto invalid;
            }else if([strKeys containsObject:k]){
                if(![value isKindOfClass:NSString.class])goto invalid;
                if([k isEqual:@"cctv.mediaVideoGravity"]&&![@[@"AVLayerVideoGravityResizeAspect",@"AVLayerVideoGravityResizeAspectFill",@"AVLayerVideoGravityResize"] containsObject:value])goto invalid;
                if([k isEqual:@"cctv.mediaPreferredQuality.v1"]&&![@[@"auto",@"smooth",@"hd",@"uhd"] containsObject:value])goto invalid;
                if([k isEqual:@"hostThemeMode"]&&![@[@"system",@"light",@"dark"] containsObject:value])goto invalid;
                if([k isEqual:@"cctv.themeIdentifier.v1"]&&![@[@"midnight",@"obsidian",@"ocean",@"amber",@"daylight",@"snow"] containsObject:value])goto invalid;
            }else if([arrKeys containsObject:k]){
                if(![value isKindOfClass:NSArray.class])goto invalid;
                for(id item in (NSArray *)value)if(![item isKindOfClass:NSString.class]||![item length]||[item length]>512)goto invalid;
            }else goto invalid;
        }
    }
    if(![NSPropertyListSerialization propertyList:root isValidForFormat:NSPropertyListBinaryFormat_v1_0])goto invalid;
    return root;
invalid:
    if(error)*error=[NSError errorWithDomain:@"HostBackup" code:1 userInfo:@{NSLocalizedDescriptionKey:@"备份文件格式无效，未修改现有配置。"}];
    return nil;
}
+ (void)restore:(NSDictionary *)backup {
    [self restore:backup error:NULL];
}
+ (BOOL)restore:(NSDictionary *)backup error:(NSError **)error {
    if(![ProfileStore replaceBackupMetadata:backup[@"profiles"]?:@{} error:error])return NO;
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults];[d setObject:backup[@"subscriptions"] forKey:@"subscriptions"];[d setObject:backup[@"favorites"] forKey:@"favorites"];[HostLibraryStore.shared replaceFavorites:backup[@"favorites"]];
    [d setObject:backup[@"profileOrder"]?:@[] forKey:@"profileOrder"];[d setObject:backup[@"disabledSubscriptions"]?:@[] forKey:@"disabledSubscriptions"];[d setObject:backup[@"epgMappings"]?:@{} forKey:@"epgMappings"];
    if([backup[@"catalogs"] isKindOfClass:NSArray.class]){
        NSMutableArray *catalogs=[[d arrayForKey:@"tvboxCatalogs"] mutableCopy]?:[NSMutableArray array];
        NSMutableSet *existing=[NSMutableSet set];for(id catalog in catalogs)if([catalog isKindOfClass:NSDictionary.class]&&[catalog[@"id"] isKindOfClass:NSString.class])[existing addObject:catalog[@"id"]];
        for(NSDictionary *catalog in backup[@"catalogs"])if(![existing containsObject:catalog[@"id"]]&&catalogs.count<64){[catalogs addObject:catalog];[existing addObject:catalog[@"id"]];}
        [d setObject:catalogs forKey:@"tvboxCatalogs"];
    }
    if([backup[@"recents"] isKindOfClass:NSArray.class])[d setObject:backup[@"recents"] forKey:@"recents"];else[d removeObjectForKey:@"recents"];
    [HostLibraryStore.shared replaceRecents:[backup[@"recents"] isKindOfClass:NSArray.class]?backup[@"recents"]:@[]];
    if([backup[@"vodFavorites"] isKindOfClass:NSDictionary.class]){[HostLibraryStore.shared replaceMediaFavorites:backup[@"vodFavorites"]];[d setObject:backup[@"vodFavorites"] forKey:@"cctv.mediaFavorites.v1"];}else{[HostLibraryStore.shared replaceMediaFavorites:@{}];[d removeObjectForKey:@"cctv.mediaFavorites.v1"];}
    if([backup[@"watchHistory"] isKindOfClass:NSArray.class]){
        NSMutableArray *rows=[NSMutableArray array];
        for(NSDictionary *entry in backup[@"watchHistory"]){
            NSMutableDictionary *row=[entry mutableCopy];
            if([row[@"updatedAt"] isKindOfClass:NSNumber.class])row[@"updatedAt"]=[NSDate dateWithTimeIntervalSince1970:[row[@"updatedAt"] doubleValue]];
            [rows addObject:row];
        }
        // defaults 侧存为带时间戳 NSNumber 的 JSON 可序列化形式，保持与 snapshot 一致
        NSMutableArray *defaultsRows=[NSMutableArray array];
        for(NSDictionary *entry in rows){NSMutableDictionary *row=[entry mutableCopy];if([row[@"updatedAt"] isKindOfClass:NSDate.class])row[@"updatedAt"]=@([row[@"updatedAt"] timeIntervalSince1970]);[defaultsRows addObject:row];}
        [HostLibraryStore.shared replaceMediaWatchHistory:rows];
        [d setObject:defaultsRows forKey:@"cctv.mediaWatchHistory.v1"];
    }else{[HostLibraryStore.shared clearMediaWatchHistory];[d removeObjectForKey:@"cctv.mediaWatchHistory.v1"];}
    if([backup[@"skipPoints"] isKindOfClass:NSDictionary.class])[d setObject:backup[@"skipPoints"] forKey:@"cctv.mediaSkipPoints.v1"];else[d removeObjectForKey:@"cctv.mediaSkipPoints.v1"];
    if([backup[@"epgReminders"] isKindOfClass:NSDictionary.class])[d setObject:backup[@"epgReminders"] forKey:@"cctv.epgReminders.v1"];else[d removeObjectForKey:@"cctv.epgReminders.v1"];
    NSDictionary *p=backup[@"preferences"];
    for(NSString *k in booleanPreferenceKeys())[d removeObjectForKey:k];
    for(NSString *k in numberPreferenceKeys())[d removeObjectForKey:k];
    for(NSString *k in stringPreferenceKeys())[d removeObjectForKey:k];
    for(NSString *k in [self arrayPreferenceKeys])[d removeObjectForKey:k];
    for(NSString *k in booleanPreferenceKeys())if(p[k])[d setBool:[p[k] boolValue] forKey:k];
    for(NSString *k in numberPreferenceKeys())if(p[k])[d setObject:p[k] forKey:k];
    for(NSString *k in stringPreferenceKeys())if(p[k])[d setObject:p[k] forKey:k];
    for(NSString *k in [self arrayPreferenceKeys])if([p[k] isKindOfClass:NSArray.class])[d setObject:p[k] forKey:k];
    [HostLibraryStore.shared markRestorePendingIfFallback];
    // T19/PERF-10：恢复直接写了 NSUserDefaults 回退键（两面写），使 LibraryStore
    // 快照失效，下次读重建——回退模式下异步写块可能先于直接写执行。
    [HostLibraryStore.shared invalidateSnapshots];
    return YES;
}
@end
