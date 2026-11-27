#import "ProfileStore.h"
#import <CommonCrypto/CommonDigest.h>

static NSDictionary *ProfileMetadataDefaultsSnapshot(void) {
    id stored=[NSUserDefaults.standardUserDefaults objectForKey:@"profileMetadata"];
    return [stored isKindOfClass:NSDictionary.class]?stored:@{};
}
NSNotificationName const ProfileStoreMetadataDidChangeNotification = @"CCTVHostProfileStoreMetadataDidChange";

static NSString *const CCTVNativeLogoSourceKey = @"__native_cctv__";
static NSString *const CCTVDisabledChannelLogoSourcesKey = @"disabledChannelLogoSources";
static NSString *const CCTVDisabledPlayerCornerLogoSourcesKey = @"disabledPlayerCornerLogoSources";
static NSString *const CCTVDisabledChannelPreviewSourcesKey = @"disabledChannelPreviewSources";
static NSString *const CCTVDisabledChannelTelemetrySourcesKey = @"disabledChannelTelemetrySources";
static NSString *const CCTVEnabledChannelLogoSourcesKey = @"enabledChannelLogoSources";
static NSString *const CCTVEnabledPlayerCornerLogoSourcesKey = @"enabledPlayerCornerLogoSources";
static NSString *const CCTVEnabledChannelPreviewSourcesKey = @"enabledChannelPreviewSources";
static NSString *const CCTVEnabledChannelTelemetrySourcesKey = @"enabledChannelTelemetrySources";

// T19/PERF-10：合并后元数据的只读快照（source → 合并后字典），与 @synchronized(self)
// 同锁读写。命中直接返回，不再每次读 NSUserDefaults + 磁盘 plist。
static NSMutableDictionary<NSString *, NSDictionary *> *gProfileMetadataCache = nil;

@implementation ProfileStore
+ (BOOL)isHTTP:(id)source {
    if(![source isKindOfClass:NSString.class]||[source length]>8192)return NO;
    NSURLComponents *c=[NSURLComponents componentsWithString:source];return c.URL&&c.host.length&&[@[@"http",@"https"] containsObject:c.scheme.lowercaseString];
}
+ (BOOL)isSource:(id)source {
    if([self isHTTP:source])return YES;
    return [source isKindOfClass:NSString.class]&&[source hasPrefix:@"local-playlist:"]&&[[NSUUID alloc] initWithUUIDString:[source substringFromIndex:15]]!=nil;
}
+ (NSString *)legacyPayloadFilePathForSource:(NSString *)source {
    NSString *dir=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"ProfilePayloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *safe=[[[source stringByReplacingOccurrencesOfString:@"://" withString:@"_"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    if(safe.length>120)safe=[NSString stringWithFormat:@"%@_%lu",[safe substringToIndex:96],(unsigned long)source.hash];
    return [dir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"plist"]];
}
+ (NSString *)payloadFilePathForSource:(NSString *)source {
    NSString *directory=[[self legacyPayloadFilePathForSource:@"legacy"] stringByDeletingLastPathComponent];
    NSData *data=[source dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *name=[NSMutableString stringWithString:@"v2-"];
    for(NSUInteger i=0;i<sizeof(digest);i++)[name appendFormat:@"%02x",digest[i]];
    return [directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"plist"]];
}
+ (NSDictionary *)metadata:(NSString *)source {
    if(source&&![source isKindOfClass:NSString.class])return @{};
    source=source.length?source:CCTVNativeLogoSourceKey;
    @synchronized(self){
        NSDictionary *cached=gProfileMetadataCache[source];
        if(cached)return cached;
        id value=ProfileMetadataDefaultsSnapshot()[source];
        if(![value isKindOfClass:NSDictionary.class])return @{};
        NSDictionary *dict=(NSDictionary *)value;
        if(![dict[@"_hasDiskPayload"] boolValue]){
            if(!gProfileMetadataCache)gProfileMetadataCache=[NSMutableDictionary dictionary];
            gProfileMetadataCache[source]=dict;
            return dict;
        }
        NSMutableDictionary *merged=[dict mutableCopy];
        NSString *payloadName=[dict[@"_payloadFile"] isKindOfClass:NSString.class]?dict[@"_payloadFile"]:nil;
        NSString *payloadPath=(payloadName.length && [payloadName.lastPathComponent isEqual:payloadName])?[[[self payloadFilePathForSource:source] stringByDeletingLastPathComponent] stringByAppendingPathComponent:payloadName]:[self payloadFilePathForSource:source];
        NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:payloadPath];
        if(!disk&&![dict[@"_hasDiskPayload"] isEqual:@2])disk=[NSDictionary dictionaryWithContentsOfFile:[self legacyPayloadFilePathForSource:source]];
        [merged removeObjectForKey:@"_hasDiskPayload"];
        [merged removeObjectForKey:@"_payloadFile"];
        for(NSString *key in @[@"text",@"cachedChannels"])if(!merged[key]&&disk[key])merged[key]=disk[key];
        if(merged[@"text"]&&![merged[@"text"] isKindOfClass:NSString.class])[merged removeObjectForKey:@"text"];
        if(merged[@"cachedChannels"]&&![merged[@"cachedChannels"] isKindOfClass:NSArray.class])[merged removeObjectForKey:@"cachedChannels"];
        NSDictionary *result=[merged copy];
        // 大条目不缓存：text/cachedChannels 超落盘阈值时每次读盘，不把大数组常驻内存。
        BOOL heavy=([result[@"text"] length]>65536)||([result[@"cachedChannels"] count]>200);
        if(!heavy){if(!gProfileMetadataCache)gProfileMetadataCache=[NSMutableDictionary dictionary];gProfileMetadataCache[source]=result;}
        return result;
    }
}
+ (BOOL)replaceBackupMetadata:(NSDictionary *)profiles error:(NSError **)error {
    @synchronized(self) {
        NSMutableDictionary *replacement=[NSMutableDictionary dictionary];
        NSMutableArray<NSString *> *created=[NSMutableArray array];
        NSString *directory=[[self payloadFilePathForSource:@"backup"] stringByDeletingLastPathComponent];
        BOOL failed=NO;
        for(NSString *source in profiles) {
            if(![self isSource:source] || ![profiles[source] isKindOfClass:NSDictionary.class]){failed=YES;break;}
            NSMutableDictionary *profile=[profiles[source] mutableCopy];
            [profile removeObjectForKey:@"_payloadFile"];
            [profile removeObjectForKey:@"_hasDiskPayload"];
            NSString *textVal=[profile[@"text"] isKindOfClass:NSString.class]?profile[@"text"]:nil;
            NSArray *channelsVal=[profile[@"cachedChannels"] isKindOfClass:NSArray.class]?profile[@"cachedChannels"]:nil;
            BOOL offload=(textVal.length>65536)||(channelsVal.count>200);
            if(offload) {
                NSMutableDictionary *payload=[NSMutableDictionary dictionary];
                for(NSString *key in @[@"text",@"cachedChannels"])if(profile[key])payload[key]=profile[key];
                NSString *name=[NSString stringWithFormat:@"backup-%@.plist",NSUUID.UUID.UUIDString];
                NSString *path=[directory stringByAppendingPathComponent:name];
                if(![payload writeToFile:path atomically:YES]){failed=YES;break;}
                [created addObject:path];
                [profile removeObjectsForKeys:payload.allKeys];
                profile[@"_hasDiskPayload"]=@2;
                profile[@"_payloadFile"]=name;
            }
            replacement[source]=profile;
        }
        if(!failed && ![NSPropertyListSerialization propertyList:replacement isValidForFormat:NSPropertyListBinaryFormat_v1_0]){
            failed=YES;
        }
        if(failed){
            for(NSString *path in created)[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            if(error)*error=[NSError errorWithDomain:@"ProfileStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"保存订阅缓存失败，原有配置未修改。"}];
            return NO;
        }
        NSDictionary *previous=ProfileMetadataDefaultsSnapshot();
        [NSUserDefaults.standardUserDefaults setObject:replacement forKey:@"profileMetadata"];
        // T19/PERF-10：整表替换，快照全失效。
        [gProfileMetadataCache removeAllObjects];
        for(NSString *source in previous) {
            NSDictionary *old=[previous[source] isKindOfClass:NSDictionary.class]?previous[source]:@{};
            NSString *name=[old[@"_payloadFile"] isKindOfClass:NSString.class]?old[@"_payloadFile"]:nil;
            if(name.length&&[name.lastPathComponent isEqual:name])[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
            else if([old[@"_hasDiskPayload"] boolValue])[NSFileManager.defaultManager removeItemAtPath:[self payloadFilePathForSource:source] error:NULL];
        }
        return YES;
    }
}
+ (void)storeProfile:(NSMutableDictionary *)profile forSource:(NSString *)source inMetadata:(NSMutableDictionary *)all {
    NSDictionary *oldProfile=[all[source] isKindOfClass:NSDictionary.class]?all[source]:@{};
    NSString *oldName=[oldProfile[@"_payloadFile"] isKindOfClass:NSString.class]?oldProfile[@"_payloadFile"]:nil;
    NSString *textVal=[profile[@"text"] isKindOfClass:NSString.class]?profile[@"text"]:nil;
    NSArray *channelsVal=[profile[@"cachedChannels"] isKindOfClass:NSArray.class]?profile[@"cachedChannels"]:nil;
    BOOL offload=(textVal.length>65536)||(channelsVal.count>200);
    NSString *path=[self payloadFilePathForSource:source];
    if(offload){
        NSMutableDictionary *payload=[NSMutableDictionary dictionary];
        for(NSString *key in @[@"text",@"cachedChannels"])if(profile[key])payload[key]=profile[key];
        if([payload writeToFile:path atomically:YES]){
            [profile removeObjectsForKeys:payload.allKeys];
            profile[@"_hasDiskPayload"]=@2;
        }else{
            // 落盘失败时保留原磁盘载荷，避免删除旧文件或把超大载荷写入 NSUserDefaults。
            return;
        }
    }
    if(!profile[@"_hasDiskPayload"])[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    all[source]=profile;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
    if(oldName.length&&[oldName.lastPathComponent isEqual:oldName])[NSFileManager.defaultManager removeItemAtPath:[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:oldName] error:NULL];
    // T19/PERF-10：本源快照失效（调用方 update:/removeValueForKey: 均持有 @synchronized(self)）。
    [gProfileMetadataCache removeObjectForKey:source];
}
+ (void)update:(NSString *)source values:(NSDictionary *)values {
    @synchronized(self){
    if((source.length&&![self isSource:source])||![values isKindOfClass:NSDictionary.class])return;
    NSString *storageKey=source.length?source:CCTVNativeLogoSourceKey;
    NSMutableDictionary *all=[ProfileMetadataDefaultsSnapshot() mutableCopy];
    NSMutableDictionary *p=[[self metadata:storageKey] mutableCopy];
    [p addEntriesFromDictionary:values];
    [self storeProfile:p forSource:storageKey inMetadata:all];
    }
}
+ (void)removeValueForKey:(NSString *)key source:(NSString *)source {
    @synchronized(self){
    // 只清一个键，其余元数据保留：重新匹配 EPG 时用它丢弃过期
    // detectedEPGURL，而不丢弃名称、状态与更新时间等其余字段。
    if(![self isSource:source]||![key isKindOfClass:NSString.class]||!key.length)return;
    NSMutableDictionary *all=[ProfileMetadataDefaultsSnapshot() mutableCopy];
    NSMutableDictionary *p=[[self metadata:source] mutableCopy];
    if(![p objectForKey:key])return;
    [p removeObjectForKey:key];
    [self storeProfile:p forSource:source inMetadata:all];

    }
}
+ (void)remove:(NSString *)source {
    if(![source isKindOfClass:NSString.class]||!source.length)return;
    @synchronized(self){
    NSDictionary *metadata=ProfileMetadataDefaultsSnapshot();NSDictionary *profile=[metadata[source] isKindOfClass:NSDictionary.class]?metadata[source]:@{};NSString *name=[profile[@"_payloadFile"] isKindOfClass:NSString.class]?profile[@"_payloadFile"]:nil;
    if([name isKindOfClass:NSString.class]&&name.length&&[name.lastPathComponent isEqual:name]){NSString *directory=[[self payloadFilePathForSource:source] stringByDeletingLastPathComponent];[NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];}
    if([source isKindOfClass:NSString.class]&&source.length)[NSFileManager.defaultManager removeItemAtPath:[self payloadFilePathForSource:source] error:NULL];
    NSMutableDictionary *all=[ProfileMetadataDefaultsSnapshot() mutableCopy];[all removeObjectForKey:source];[NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
    // T19/PERF-10：本源快照失效。
    [gProfileMetadataCache removeObjectForKey:source];
    for(NSString *key in @[@"profileOrder",@"disabledSubscriptions",CCTVDisabledChannelLogoSourcesKey,CCTVDisabledPlayerCornerLogoSourcesKey,CCTVDisabledChannelPreviewSourcesKey,CCTVDisabledChannelTelemetrySourcesKey,CCTVEnabledChannelLogoSourcesKey,CCTVEnabledPlayerCornerLogoSourcesKey,CCTVEnabledChannelPreviewSourcesKey,CCTVEnabledChannelTelemetrySourcesKey]){NSMutableArray *a=[[NSUserDefaults.standardUserDefaults arrayForKey:key]?:@[] mutableCopy];[a removeObject:source];[NSUserDefaults.standardUserDefaults setObject:a forKey:key];}

    }
}
+ (NSArray<NSString *> *)orderedSources:(NSArray<NSString *> *)sources {
    if(sources.count<=1)return sources?:@[];
    NSArray *order=[NSUserDefaults.standardUserDefaults arrayForKey:@"profileOrder"]?:@[];
    NSMutableDictionary<NSString *,NSNumber *> *rankMap=[NSMutableDictionary dictionaryWithCapacity:order.count];
    [order enumerateObjectsUsingBlock:^(NSString *item,NSUInteger idx,__unused BOOL *stop){
        if([item isKindOfClass:NSString.class]&&!rankMap[item])rankMap[item]=@(idx);
    }];
    return [sources sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){
        NSNumber *rx=rankMap[a],*ry=rankMap[b];
        NSUInteger x=rx?rx.unsignedIntegerValue:NSNotFound,y=ry?ry.unsignedIntegerValue:NSNotFound;
        if(x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;
        return [a compare:b];
    }];
}
+ (void)move:(NSString *)source offset:(NSInteger)offset sources:(NSArray<NSString *> *)sources {
    @synchronized(self){
    NSMutableArray *a=[[self orderedSources:sources] mutableCopy];NSUInteger i=[a indexOfObject:source];if(i==NSNotFound)return;NSInteger j=(NSInteger)i+offset;if(j<0||j>=a.count)return;[a exchangeObjectAtIndex:i withObjectAtIndex:j];[NSUserDefaults.standardUserDefaults setObject:a forKey:@"profileOrder"];

    }
}
+ (NSString *)epgSourceForChannel:(NSDictionary *)channel {
    for(NSString *s in [self orderedSources:channel[@"subscriptionSources"]?:@[]]){NSDictionary *p=[self metadata:s];NSString *u=p[@"epgURL"];if(!u.length)u=p[@"detectedEPGURL"];if([self isHTTP:u])return u;}
    return nil;
}
+ (NSString *)epgIDForChannel:(NSDictionary *)channel {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"][channel[@"id"]?:@""]?:channel[@"epgID"]?:channel[@"tvgName"]?:([self canonicalStationIDForChannel:channel]?:channel[@"name"]?:@"");
}

+ (NSString *)normalizedLogoSourceKey:(NSString *)source {
    if (![source isKindOfClass:NSString.class]) return CCTVNativeLogoSourceKey;
    NSString *trimmed = [source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed isEqualToString:@"builtin:cctv"]) return CCTVNativeLogoSourceKey;
    return trimmed;
}

+ (BOOL)isSource:(NSString *)source enabledInKey:(NSString *)enabledKey disabledInKey:(NSString *)disabledKey nativePrefKey:(NSString *)nativePrefKey {
    NSString *key = [self normalizedLogoSourceKey:source];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *disabled = [defaults arrayForKey:disabledKey];
    if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:key]) return NO;
    NSArray *enabled = [defaults arrayForKey:enabledKey];
    if ([enabled isKindOfClass:NSArray.class] && [enabled containsObject:key]) return YES;
    if (nativePrefKey.length && [key isEqualToString:CCTVNativeLogoSourceKey]) {
        id nativePref = [defaults objectForKey:nativePrefKey];
        if (nativePref != nil) return [nativePref boolValue];
    }
    NSDictionary *meta = [self metadata:key];
    NSString *serviceID = [meta[@"managedServiceID"] isKindOfClass:NSString.class] ? meta[@"managedServiceID"] : @"";
    if (serviceID.length) {
        NSString *pluginKey = [@"plugin:" stringByAppendingString:serviceID];
        if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:pluginKey]) return NO;
        if ([enabled isKindOfClass:NSArray.class] && [enabled containsObject:pluginKey]) return YES;
    }
    NSString *catalogID = [meta[@"tvboxCatalogID"] isKindOfClass:NSString.class] ? meta[@"tvboxCatalogID"] : @"";
    if (catalogID.length) {
        NSString *tvboxKey = [@"tvbox:" stringByAppendingString:catalogID];
        if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:tvboxKey]) return NO;
        if ([enabled isKindOfClass:NSArray.class] && [enabled containsObject:tvboxKey]) return YES;
    }
    // 默认全部关闭，需由用户手动开启
    return NO;
}

+ (void)setSource:(NSString *)source enabled:(BOOL)enabled enabledKey:(NSString *)enabledKey disabledKey:(NSString *)disabledKey nativePrefKey:(NSString *)nativePrefKey {
    NSString *key = [self normalizedLogoSourceKey:source];
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *enabledList = [[defaults arrayForKey:enabledKey] ?: @[] mutableCopy];
        NSMutableArray *disabledList = [[defaults arrayForKey:disabledKey] ?: @[] mutableCopy];
        [enabledList removeObject:key];
        [disabledList removeObject:key];
        if (enabled) {
            [enabledList addObject:key];
        } else {
            [disabledList addObject:key];
        }
        [defaults setObject:enabledList.copy forKey:enabledKey];
        [defaults setObject:disabledList.copy forKey:disabledKey];
        if (nativePrefKey.length && [key isEqualToString:CCTVNativeLogoSourceKey]) {
            [defaults setBool:enabled forKey:nativePrefKey];
        }
    }
    if (NSThread.isMainThread) {
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:key];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:key];
        });
    }
}

+ (BOOL)isChannelLogoEnabledForSource:(NSString *)source {
    return [self isSource:source enabledInKey:CCTVEnabledChannelLogoSourcesKey disabledInKey:CCTVDisabledChannelLogoSourcesKey nativePrefKey:@"nativeChannelLogoEnabled"];
}

+ (void)setChannelLogoEnabled:(BOOL)enabled forSource:(NSString *)source {
    [self setSource:source enabled:enabled enabledKey:CCTVEnabledChannelLogoSourcesKey disabledKey:CCTVDisabledChannelLogoSourcesKey nativePrefKey:@"nativeChannelLogoEnabled"];
}

+ (BOOL)isPlayerCornerLogoEnabledForSource:(NSString *)source {
    return [self isSource:source enabledInKey:CCTVEnabledPlayerCornerLogoSourcesKey disabledInKey:CCTVDisabledPlayerCornerLogoSourcesKey nativePrefKey:@"nativePlayerCornerLogoEnabled"];
}

+ (void)setPlayerCornerLogoEnabled:(BOOL)enabled forSource:(NSString *)source {
    [self setSource:source enabled:enabled enabledKey:CCTVEnabledPlayerCornerLogoSourcesKey disabledKey:CCTVDisabledPlayerCornerLogoSourcesKey nativePrefKey:@"nativePlayerCornerLogoEnabled"];
}

+ (BOOL)isChannelLogoEnabledForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return NO;
    NSString *remoteURL = [channel[@"remoteURL"] isKindOfClass:NSString.class] ? channel[@"remoteURL"] : @"";
    if (!remoteURL.length || [channel[@"nativePlainRoute"] boolValue]) {
        return [self isChannelLogoEnabledForSource:CCTVNativeLogoSourceKey];
    }
    NSArray *sources = [channel[@"subscriptionSources"] isKindOfClass:NSArray.class] ? channel[@"subscriptionSources"] : @[];
    if (!sources.count) return [self isChannelLogoEnabledForSource:remoteURL];
    NSSet *disabledSubs = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] ?: @[]];
    BOOL hasActiveOwner = NO;
    for (id raw in sources) {
        if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) continue;
        if ([disabledSubs containsObject:raw]) continue;
        hasActiveOwner = YES;
        if ([self isChannelLogoEnabledForSource:raw]) return YES;
    }
    if (!hasActiveOwner) {
        for (id raw in sources) {
            if ([raw isKindOfClass:NSString.class] && [self isChannelLogoEnabledForSource:raw]) return YES;
        }
    }
    return NO;
}

+ (BOOL)isPlayerCornerLogoEnabledForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return NO;
    NSString *remoteURL = [channel[@"remoteURL"] isKindOfClass:NSString.class] ? channel[@"remoteURL"] : @"";
    if (!remoteURL.length || [channel[@"nativePlainRoute"] boolValue]) {
        return [self isPlayerCornerLogoEnabledForSource:CCTVNativeLogoSourceKey];
    }
    NSArray *sources = [channel[@"subscriptionSources"] isKindOfClass:NSArray.class] ? channel[@"subscriptionSources"] : @[];
    if (!sources.count) return [self isPlayerCornerLogoEnabledForSource:remoteURL];
    NSSet *disabledSubs = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] ?: @[]];
    BOOL hasActiveOwner = NO;
    for (id raw in sources) {
        if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) continue;
        if ([disabledSubs containsObject:raw]) continue;
        hasActiveOwner = YES;
        if ([self isPlayerCornerLogoEnabledForSource:raw]) return YES;
    }
    if (!hasActiveOwner) {
        for (id raw in sources) {
            if ([raw isKindOfClass:NSString.class] && [self isPlayerCornerLogoEnabledForSource:raw]) return YES;
        }
    }
    return NO;
}

+ (BOOL)isChannelPreviewEnabledForSource:(NSString *)source {
    return [self isSource:source enabledInKey:CCTVEnabledChannelPreviewSourcesKey disabledInKey:CCTVDisabledChannelPreviewSourcesKey nativePrefKey:@"nativeChannelPreviewEnabled"];
}

+ (void)setChannelPreviewEnabled:(BOOL)enabled forSource:(NSString *)source {
    [self setSource:source enabled:enabled enabledKey:CCTVEnabledChannelPreviewSourcesKey disabledKey:CCTVDisabledChannelPreviewSourcesKey nativePrefKey:@"nativeChannelPreviewEnabled"];
}

+ (BOOL)isChannelPreviewEnabledForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return NO;
    NSString *remoteURL = [channel[@"remoteURL"] isKindOfClass:NSString.class] ? channel[@"remoteURL"] : @"";
    if (!remoteURL.length || [channel[@"nativePlainRoute"] boolValue]) {
        return [self isChannelPreviewEnabledForSource:CCTVNativeLogoSourceKey];
    }
    NSArray *sources = [self subscriptionSourcesForChannel:channel];
    if (!sources.count) return [self isChannelPreviewEnabledForSource:remoteURL];
    NSSet *disabledSubs = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] ?: @[]];
    BOOL hasActiveOwner = NO;
    for (id raw in sources) {
        if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) continue;
        if ([disabledSubs containsObject:raw]) continue;
        hasActiveOwner = YES;
        if ([self isChannelPreviewEnabledForSource:raw]) return YES;
    }
    if (!hasActiveOwner) {
        for (id raw in sources) {
            if ([raw isKindOfClass:NSString.class] && [self isChannelPreviewEnabledForSource:raw]) return YES;
        }
    }
    return NO;
}

+ (BOOL)isChannelTelemetryEnabledForSource:(NSString *)source {
    return [self isSource:source enabledInKey:CCTVEnabledChannelTelemetrySourcesKey disabledInKey:CCTVDisabledChannelTelemetrySourcesKey nativePrefKey:@"nativeChannelTelemetryEnabled"];
}

+ (void)setChannelTelemetryEnabled:(BOOL)enabled forSource:(NSString *)source {
    [self setSource:source enabled:enabled enabledKey:CCTVEnabledChannelTelemetrySourcesKey disabledKey:CCTVDisabledChannelTelemetrySourcesKey nativePrefKey:@"nativeChannelTelemetryEnabled"];
}

+ (BOOL)isChannelTelemetryEnabledForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return NO;
    NSString *remoteURL = [channel[@"remoteURL"] isKindOfClass:NSString.class] ? channel[@"remoteURL"] : @"";
    if (!remoteURL.length || [channel[@"nativePlainRoute"] boolValue]) {
        return [self isChannelTelemetryEnabledForSource:CCTVNativeLogoSourceKey];
    }
    NSArray *sources = [self subscriptionSourcesForChannel:channel];
    if (!sources.count) return [self isChannelTelemetryEnabledForSource:remoteURL];
    NSSet *disabledSubs = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] ?: @[]];
    BOOL hasActiveOwner = NO;
    for (id raw in sources) {
        if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) continue;
        if ([disabledSubs containsObject:raw]) continue;
        hasActiveOwner = YES;
        if ([self isChannelTelemetryEnabledForSource:raw]) return YES;
    }
    if (!hasActiveOwner) {
        for (id raw in sources) {
            if ([raw isKindOfClass:NSString.class] && [self isChannelTelemetryEnabledForSource:raw]) return YES;
        }
    }
    return NO;
}

+ (void)migrateResourceDisplaySettingsFromSource:(NSString *)oldSource toSource:(NSString *)newSource {
    NSString *fromKey = [self normalizedLogoSourceKey:oldSource];
    NSString *toKey = [self normalizedLogoSourceKey:newSource];
    if (!fromKey.length || !toKey.length || [fromKey isEqualToString:toKey]) return;
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSString *prefKey in @[CCTVDisabledChannelLogoSourcesKey, CCTVDisabledPlayerCornerLogoSourcesKey, CCTVDisabledChannelPreviewSourcesKey, CCTVDisabledChannelTelemetrySourcesKey, CCTVEnabledChannelLogoSourcesKey, CCTVEnabledPlayerCornerLogoSourcesKey, CCTVEnabledChannelPreviewSourcesKey, CCTVEnabledChannelTelemetrySourcesKey]) {
            NSMutableArray *arr = [[defaults arrayForKey:prefKey] ?: @[] mutableCopy];
            if ([arr containsObject:fromKey]) {
                [arr removeObject:fromKey];
                if (![arr containsObject:toKey]) [arr addObject:toKey];
                [defaults setObject:arr.copy forKey:prefKey];
            }
        }
    }
}

+ (NSArray<NSString *> *)subscriptionSourcesForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return @[];
    id raw = channel[@"subscriptionSources"];
    return [raw isKindOfClass:NSArray.class] ? raw : @[];
}

+ (NSString *)canonicalStationIDForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return nil;
    static NSSet<NSString *> *knownIDs;
    static NSDictionary<NSString *, NSString *> *keywordMap;
    static NSRegularExpression *cctvRegex;
    static NSRegularExpression *cetvRegex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownIDs = [NSSet setWithArray:@[
            @"cctv1",@"cctv2",@"cctv3",@"cctv4",@"cctveurope",@"cctvamerica",@"cctv5",@"cctv5plus",
            @"cctv6",@"cctv7",@"cctv8",@"cctvjilu",@"cctv10",@"cctv11",@"cctv12",@"cctv13",
            @"cctvchild",@"cctv15",@"cctv16",@"cctv17",
            @"cetv1",@"cetv2",@"cetv3",@"cetv4",
            @"btv1",@"btv2",@"btv3",@"btv4",@"btv5",@"btv7",@"btv9",
            @"guangdong",@"dongfang",@"shenzhen",@"shandong",@"henan",@"sichuan",@"hubei",
            @"liaoning",@"tianjin",@"anhui",@"heilongjiang",@"jilin",@"hebei",@"shan1xi",@"shan3xi",
            @"jiangxi",@"dongnan",@"guangxi",@"guizhou",@"yunnan",@"gansu",@"qinghai",@"ningxia",
            @"xinjiang",@"xizang",@"neimenggu",@"neimenggu2",@"travel",@"chongqing",@"xianggangweishi",
            @"ipanda-live"
        ]];
        keywordMap = @{
            @"北京卫视": @"btv1", @"brtv北京卫视": @"btv1",
            @"brtv文艺": @"btv2", @"北京文艺": @"btv2",
            @"brtv纪实科教": @"btv3", @"北京纪实": @"btv3", @"北京科教": @"btv3",
            @"brtv影视": @"btv4", @"北京影视": @"btv4",
            @"brtv财经": @"btv5", @"北京财经": @"btv5",
            @"brtv生活": @"btv7", @"北京生活": @"btv7",
            @"brtv新闻": @"btv9", @"北京新闻": @"btv9",
            @"广东卫视": @"guangdong",
            @"东方卫视": @"dongfang", @"上海东方卫视": @"dongfang",
            @"深圳卫视": @"shenzhen",
            @"山东卫视": @"shandong",
            @"河南卫视": @"henan",
            @"四川卫视": @"sichuan",
            @"湖北卫视": @"hubei",
            @"辽宁卫视": @"liaoning",
            @"天津卫视": @"tianjin",
            @"安徽卫视": @"anhui",
            @"黑龙江卫视": @"heilongjiang",
            @"吉林卫视": @"jilin",
            @"河北卫视": @"hebei",
            @"山西卫视": @"shan1xi",
            @"陕西卫视": @"shan3xi",
            @"江西卫视": @"jiangxi",
            @"东南卫视": @"dongnan", @"福建东南": @"dongnan",
            @"广西卫视": @"guangxi",
            @"贵州卫视": @"guizhou",
            @"云南卫视": @"yunnan",
            @"甘肃卫视": @"gansu",
            @"青海卫视": @"qinghai",
            @"宁夏卫视": @"ningxia",
            @"新疆卫视": @"xinjiang",
            @"西藏卫视": @"xizang",
            @"内蒙古蒙语": @"neimenggu2", @"蒙语卫视": @"neimenggu2", @"蒙语台": @"neimenggu2",
            @"内蒙古卫视": @"neimenggu",
            @"海南卫视": @"travel", @"旅游卫视": @"travel",
            @"重庆卫视": @"chongqing",
            @"香港卫视": @"xianggangweishi",
            @"熊猫直播": @"ipanda-live", @"熊猫频道": @"ipanda-live"
        };
        cctvRegex = [NSRegularExpression regularExpressionWithPattern:@"cctv[-\\s_]*(5\\+|5plus|4k|8k|1[0-7]|[1-9])(?![0-9])" options:NSRegularExpressionCaseInsensitive error:NULL];
        cetvRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:cetv|中国教育|教育)[-\\s_]*([1-4])(?![0-9])" options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    for (NSString *field in @[@"id", @"epgID", @"tvgName", @"name"]) {
        NSString *raw = [channel[field] isKindOfClass:NSString.class] ? channel[field] : @"";
        if (!raw.length) continue;
        NSString *lower = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if ([knownIDs containsObject:lower]) return lower;
        if ([lower isEqualToString:@"cctv9"] || [lower isEqualToString:@"cctv-9"]) return @"cctvjilu";
        if ([lower isEqualToString:@"cctv14"] || [lower isEqualToString:@"cctv-14"]) return @"cctvchild";
        if ([lower containsString:@"cctv"] || [lower containsString:@"中央"]) {
            if ([lower containsString:@"欧洲"] || [lower containsString:@"europe"] || [lower containsString:@"cctv4o"]) return @"cctveurope";
            if ([lower containsString:@"美洲"] || [lower containsString:@"america"] || [lower containsString:@"cctv4a"]) return @"cctvamerica";
            if ([lower containsString:@"5+"] || [lower containsString:@"5plus"] || [lower containsString:@"体育赛事"]) return @"cctv5plus";
            NSTextCheckingResult *m = [cctvRegex firstMatchInString:lower options:0 range:NSMakeRange(0, lower.length)];
            if (m && m.numberOfRanges > 1) {
                NSString *num = [lower substringWithRange:[m rangeAtIndex:1]];
                if ([num isEqualToString:@"5+"] || [num isEqualToString:@"5plus"]) return @"cctv5plus";
                if ([num isEqualToString:@"9"]) return @"cctvjilu";
                if ([num isEqualToString:@"14"]) return @"cctvchild";
                NSString *candidate = [@"cctv" stringByAppendingString:num];
                if ([knownIDs containsObject:candidate]) return candidate;
            }
        }
        NSTextCheckingResult *cm = [cetvRegex firstMatchInString:lower options:0 range:NSMakeRange(0, lower.length)];
        if (cm && cm.numberOfRanges > 1) {
            NSString *cNum = [lower substringWithRange:[cm rangeAtIndex:1]];
            NSString *candidate = [@"cetv" stringByAppendingString:cNum];
            if ([knownIDs containsObject:candidate]) return candidate;
        }
        for (NSString *kw in keywordMap) {
            if ([lower containsString:kw]) return keywordMap[kw];
        }
    }
    return nil;
}
@end
