#import "HostBackup.h"
#import "ProfileStore.h"
@implementation HostBackup
+ (NSArray<NSString *> *)preferenceKeys {return @[@"legacyNativePlayback",@"resumeLastChannel",@"rememberLastChannel",@"autoLoadEPG",@"allowBackgroundAudio",@"autoPiP",@"channelGridMode",@"nativeChannelsEnabled"];}
+ (NSDictionary *)snapshot {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;NSMutableDictionary *preferences=[NSMutableDictionary dictionary];for(NSString *key in self.preferenceKeys)if([d objectForKey:key])preferences[key]=@([d boolForKey:key]);
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
    if(valid)for(NSString *key in j[@"preferences"])if(![self.preferenceKeys containsObject:key]||![j[@"preferences"][key] isKindOfClass:NSNumber.class])valid=NO;
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
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;[d setObject:backup[@"subscriptions"] forKey:@"subscriptions"];[d setObject:backup[@"favorites"] forKey:@"favorites"];
    for(NSString *key in self.preferenceKeys)[d removeObjectForKey:key];for(NSString *key in backup[@"preferences"])[d setObject:backup[@"preferences"][key] forKey:key];
    [d setObject:backup[@"profiles"]?:@{} forKey:@"profileMetadata"];[d setObject:backup[@"order"]?:@[] forKey:@"profileOrder"];[d setObject:backup[@"disabled"]?:@[] forKey:@"disabledSubscriptions"];[d setObject:backup[@"epgMappings"]?:@{} forKey:@"epgMappings"];[d setObject:backup[@"recents"]?:@[] forKey:@"recents"];
}
@end
