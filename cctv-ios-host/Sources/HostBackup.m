#import "HostBackup.h"
#import "ProfileStore.h"
#import <AVFoundation/AVFoundation.h>
static NSArray<NSString *> *booleanPreferenceKeys(void){return @[@"nativeChannelsEnabled",@"resumeLastChannel",@"autoLoadEPG",@"allowBackgroundAudio",@"autoPiP",@"legacyNativePlayback",@"preloadNativeChannel",@"fastNativeStartup",@"nativeSDKVerboseLogs",@"runtimeDiagnosticsEnabled",@"cctv.adaptationMonitor.enabled",@"channelGridMode",@"nativeChannelLogoEnabled",@"nativePlayerCornerLogoEnabled",@"nativeChannelPreviewEnabled",@"nativeChannelTelemetryEnabled",@"cctv.restoreLastTab.v1",@"cctv.mediaAutoPlayNext",@"cctv.mediaAutoSkipIntroOutro",@"cctv.mediaKeepScreenAwake",@"cctv.mediaEpisodeShowBadge.v1",@"cctv.mediaEpisodeAutoExpand.v1",@"media.globalSearchHistoryEnabled.v1",@"hostDarkTheme"];}
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
    for(NSString *s in subs){NSDictionary *m=[ProfileStore metadata:s];if(m.count)profiles[s]=m;}
    NSMutableDictionary *snap=[@{@"format":@"CCTVHost",@"version":@2,@"subscriptions":subs,@"favorites":[d arrayForKey:@"favorites"]?:@[],@"profiles":profiles,@"profileOrder":[d arrayForKey:@"profileOrder"]?:@[],@"disabledSubscriptions":[d arrayForKey:@"disabledSubscriptions"]?:@[],@"epgMappings":[d dictionaryForKey:@"epgMappings"]?:@{},@"preferences":p} mutableCopy];
    NSArray *recents=[d arrayForKey:@"recents"];
    if([recents isKindOfClass:NSArray.class]&&[NSJSONSerialization isValidJSONObject:recents])snap[@"recents"]=recents;
    NSDictionary *vodFavorites=[d dictionaryForKey:@"cctv.mediaFavorites.v1"];
    if([vodFavorites isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:vodFavorites])snap[@"vodFavorites"]=vodFavorites;
    NSArray *watchHistory=[d arrayForKey:@"cctv.mediaWatchHistory.v1"];
    if([watchHistory isKindOfClass:NSArray.class]&&[NSJSONSerialization isValidJSONObject:watchHistory])snap[@"watchHistory"]=watchHistory;
    NSDictionary *skipPoints=[d dictionaryForKey:@"cctv.mediaSkipPoints.v1"];
    if([skipPoints isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:skipPoints])snap[@"skipPoints"]=skipPoints;
    NSDictionary *epgReminders=[d dictionaryForKey:@"cctv.epgReminders.v1"];
    if([epgReminders isKindOfClass:NSDictionary.class]&&[NSJSONSerialization isValidJSONObject:epgReminders])snap[@"epgReminders"]=epgReminders;
    return snap.copy;
}
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error {
    id root=nil;
    NSInteger version=0;
    if(!data.length)goto invalid;
    root=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![root isKindOfClass:NSDictionary.class])goto invalid;
    version=[root[@"version"] integerValue];
    if(![root[@"format"] isEqual:@"CCTVHost"]||(version!=1&&version!=2))goto invalid;
    if(![root[@"subscriptions"] isKindOfClass:NSArray.class]||![root[@"favorites"] isKindOfClass:NSArray.class]||![root[@"preferences"] isKindOfClass:NSDictionary.class])goto invalid;
    for(id u in root[@"subscriptions"])if(![ProfileStore isSource:u])goto invalid;
    for(id f in root[@"favorites"])if(![f isKindOfClass:NSString.class]||![f length]||[f length]>512)goto invalid;
    if(root[@"profiles"]){if(![root[@"profiles"] isKindOfClass:NSDictionary.class])goto invalid;for(id k in root[@"profiles"]){id v=root[@"profiles"][k];if(![ProfileStore isSource:k]||![v isKindOfClass:NSDictionary.class])goto invalid;for(id mk in v){id mv=v[mk];if((![mk isEqual:@"name"]&&![mk isEqual:@"epgURL"]&&![mk isEqual:@"detectedEPGURL"]&&![mk isEqual:@"text"]&&![mk isEqual:@"status"]&&![mk isEqual:@"updatedAt"]&&![mk isEqual:@"cachedChannels"]&&![mk isEqual:@"unsupportedProtocols"]&&![mk isEqual:@"managedServiceID"]&&![mk isEqual:@"tvboxCatalogID"]&&![mk isEqual:@"tvboxLiveEntryName"]&&![mk isEqual:@"userAgent"]&&![mk isEqual:@"inlinePlaylist"])||([mk isEqual:@"updatedAt"]?![mv isKindOfClass:NSNumber.class]:([mk isEqual:@"cachedChannels"]?![mv isKindOfClass:NSArray.class]:([mk isEqual:@"unsupportedProtocols"]?![mv isKindOfClass:NSDictionary.class]:![mv isKindOfClass:NSString.class]))))goto invalid;if(([mk isEqual:@"epgURL"]||[mk isEqual:@"detectedEPGURL"])&&[mv length]&&![ProfileStore isHTTP:mv])goto invalid;}}}
    for(NSString *k in @[@"profileOrder",@"disabledSubscriptions"])if(root[k]){if(![root[k] isKindOfClass:NSArray.class])goto invalid;for(id s in root[k])if(![ProfileStore isSource:s])goto invalid;}
    if(root[@"epgMappings"]){if(![root[@"epgMappings"] isKindOfClass:NSDictionary.class])goto invalid;for(id k in root[@"epgMappings"])if(![k isKindOfClass:NSString.class]||![root[@"epgMappings"][k] isKindOfClass:NSString.class])goto invalid;}
    if(root[@"recents"]){if(![root[@"recents"] isKindOfClass:NSArray.class])goto invalid;for(id r in root[@"recents"])if(![r isKindOfClass:NSDictionary.class])goto invalid;}
    if(root[@"vodFavorites"]&&![root[@"vodFavorites"] isKindOfClass:NSDictionary.class])goto invalid;
    if(root[@"watchHistory"]){if(![root[@"watchHistory"] isKindOfClass:NSArray.class])goto invalid;for(id w in root[@"watchHistory"])if(![w isKindOfClass:NSDictionary.class])goto invalid;}
    if(root[@"skipPoints"]&&![root[@"skipPoints"] isKindOfClass:NSDictionary.class])goto invalid;
    if(root[@"epgReminders"]&&![root[@"epgReminders"] isKindOfClass:NSDictionary.class])goto invalid;
    {
        NSSet *boolKeys=[NSSet setWithArray:booleanPreferenceKeys()];
        NSSet *numKeys=[NSSet setWithArray:numberPreferenceKeys()];
        NSSet *strKeys=[NSSet setWithArray:stringPreferenceKeys()];
        NSSet *arrKeys=[NSSet setWithArray:[self arrayPreferenceKeys]];
        for(id k in root[@"preferences"]){
            id value=root[@"preferences"][k];
            if([boolKeys containsObject:k]){
                if(![value isKindOfClass:NSNumber.class]||strcmp([value objCType],@encode(BOOL))!=0)goto invalid;
            }else if([numKeys containsObject:k]){
                if(![value isKindOfClass:NSNumber.class]||strcmp([value objCType],@encode(BOOL))==0)goto invalid;
                if([k isEqual:@"cctv.mediaPlaybackRate"]&&([value doubleValue]<0.5||[value doubleValue]>2.0))goto invalid;
                if([k isEqual:@"cctv.channelGridColumns.v1"]&&[value integerValue]!=3&&[value integerValue]!=4)goto invalid;
                if([k isEqual:@"cctv.channelSortMode.v1"]&&[value integerValue]!=0&&[value integerValue]!=1)goto invalid;
                if([k isEqual:@"cctv.mediaGridColumns.v1"]&&[value integerValue]!=2&&[value integerValue]!=3&&[value integerValue]!=4)goto invalid;
                if([k isEqual:@"cctv.mediaEpisodeLayoutStyle.v1"]&&([value integerValue]<0||[value integerValue]>3))goto invalid;
                if([k isEqual:@"cctv.networkTimeout.v1"]&&([value doubleValue]<5||[value doubleValue]>40))goto invalid;
                if([k isEqual:@"cctv.appFontSize.v1"]&&([value integerValue]<0||[value integerValue]>2))goto invalid;
            }else if([strKeys containsObject:k]){
                if(![value isKindOfClass:NSString.class])goto invalid;
                if([k isEqual:@"cctv.mediaVideoGravity"]&&![@[AVLayerVideoGravityResizeAspect,AVLayerVideoGravityResizeAspectFill,AVLayerVideoGravityResize] containsObject:value])goto invalid;
                if([k isEqual:@"cctv.mediaPreferredQuality.v1"]&&![@[@"auto",@"smooth",@"hd",@"uhd"] containsObject:value])goto invalid;
                if([k isEqual:@"hostThemeMode"]&&![@[@"system",@"light",@"dark"] containsObject:value])goto invalid;
                if([k isEqual:@"cctv.themeIdentifier.v1"]&&![@[@"midnight",@"obsidian",@"ocean",@"amber",@"daylight",@"snow"] containsObject:value])goto invalid;
            }else if([arrKeys containsObject:k]){
                if(![value isKindOfClass:NSArray.class])goto invalid;
                for(id item in (NSArray *)value)if(![item isKindOfClass:NSString.class]||![item length]||[item length]>512)goto invalid;
            }else goto invalid;
        }
    }
    return root;
invalid:
    if(error)*error=[NSError errorWithDomain:@"HostBackup" code:1 userInfo:@{NSLocalizedDescriptionKey:@"备份文件格式无效，未修改现有配置。"}];
    return nil;
}
+ (void)restore:(NSDictionary *)backup {
    NSUserDefaults *d=[NSUserDefaults standardUserDefaults];[d setObject:backup[@"subscriptions"] forKey:@"subscriptions"];[d setObject:backup[@"favorites"] forKey:@"favorites"];
    [d setObject:backup[@"profiles"]?:@{} forKey:@"profileMetadata"];[d setObject:backup[@"profileOrder"]?:@[] forKey:@"profileOrder"];[d setObject:backup[@"disabledSubscriptions"]?:@[] forKey:@"disabledSubscriptions"];[d setObject:backup[@"epgMappings"]?:@{} forKey:@"epgMappings"];
    if([backup[@"recents"] isKindOfClass:NSArray.class])[d setObject:backup[@"recents"] forKey:@"recents"];
    if([backup[@"vodFavorites"] isKindOfClass:NSDictionary.class])[d setObject:backup[@"vodFavorites"] forKey:@"cctv.mediaFavorites.v1"];
    if([backup[@"watchHistory"] isKindOfClass:NSArray.class])[d setObject:backup[@"watchHistory"] forKey:@"cctv.mediaWatchHistory.v1"];
    if([backup[@"skipPoints"] isKindOfClass:NSDictionary.class])[d setObject:backup[@"skipPoints"] forKey:@"cctv.mediaSkipPoints.v1"];
    if([backup[@"epgReminders"] isKindOfClass:NSDictionary.class])[d setObject:backup[@"epgReminders"] forKey:@"cctv.epgReminders.v1"];
    NSDictionary *p=backup[@"preferences"];
    for(NSString *k in booleanPreferenceKeys())if(p[k])[d setBool:[p[k] boolValue] forKey:k];
    for(NSString *k in numberPreferenceKeys())if(p[k])[d setObject:p[k] forKey:k];
    for(NSString *k in stringPreferenceKeys())if(p[k])[d setObject:p[k] forKey:k];
    for(NSString *k in [self arrayPreferenceKeys])if([p[k] isKindOfClass:NSArray.class])[d setObject:p[k] forKey:k];
}
@end
