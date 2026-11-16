#import "ProfileStore.h"
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

@implementation ProfileStore
+ (BOOL)isHTTP:(id)source {
    if(![source isKindOfClass:NSString.class]||[source length]>8192)return NO;
    @try{NSURLComponents *c=[NSURLComponents componentsWithString:source];return c.URL&&c.host.length&&[@[@"http",@"https"] containsObject:c.scheme.lowercaseString];}@catch(NSException *e){return NO;}
}
+ (BOOL)isSource:(id)source {
    if([self isHTTP:source])return YES;
    return [source isKindOfClass:NSString.class]&&[source hasPrefix:@"local-playlist:"]&&[[NSUUID alloc] initWithUUIDString:[source substringFromIndex:15]]!=nil;
}
+ (NSString *)payloadFilePathForSource:(NSString *)source {
    NSString *dir=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"ProfilePayloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *safe=[[[source stringByReplacingOccurrencesOfString:@"://" withString:@"_"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    if(safe.length>120)safe=[NSString stringWithFormat:@"%@_%lu",[safe substringToIndex:96],(unsigned long)source.hash];
    return [dir stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"plist"]];
}
+ (NSDictionary *)metadata:(NSString *)source {
    if(![source isKindOfClass:NSString.class]||!source.length)return @{};
    @synchronized(self){
        id value=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"][source];
        if(![value isKindOfClass:NSDictionary.class])return @{};
        NSDictionary *dict=(NSDictionary *)value;
        if(![dict[@"_hasDiskPayload"] boolValue])return dict;
        NSMutableDictionary *merged=[dict mutableCopy];
        [merged removeObjectForKey:@"_hasDiskPayload"];
        NSDictionary *disk=[NSDictionary dictionaryWithContentsOfFile:[self payloadFilePathForSource:source]];
        if([disk isKindOfClass:NSDictionary.class])[merged addEntriesFromDictionary:disk];
        return [merged copy];
    }
}
+ (void)update:(NSString *)source values:(NSDictionary *)values {
    @synchronized(self){
    if((source.length&&![self isSource:source])||![values isKindOfClass:NSDictionary.class])return;
    NSString *storageKey=source.length?source:CCTVNativeLogoSourceKey;
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];
    NSMutableDictionary *p=[[all[storageKey] isKindOfClass:NSDictionary.class]?all[storageKey]:@{} mutableCopy];
    BOOL offload=([values[@"text"] isKindOfClass:NSString.class]&&[(NSString *)values[@"text"] length]>65536)||([values[@"cachedChannels"] isKindOfClass:NSArray.class]&&[(NSArray *)values[@"cachedChannels"] count]>200);
    if(offload){
        NSString *payloadPath=[self payloadFilePathForSource:storageKey];
        NSMutableDictionary *disk=[[NSDictionary dictionaryWithContentsOfFile:payloadPath] mutableCopy]?:[NSMutableDictionary dictionary];
        for(NSString *k in values){
            if([k isEqualToString:@"text"]||[k isEqualToString:@"cachedChannels"]){disk[k]=values[k];[p removeObjectForKey:k];}
            else p[k]=values[k];
        }
        if([disk writeToFile:payloadPath atomically:YES])p[@"_hasDiskPayload"]=@YES;
        else [p addEntriesFromDictionary:values];
    }else{
        [p addEntriesFromDictionary:values];
    }
    all[storageKey]=p;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
    }
}
+ (void)removeValueForKey:(NSString *)key source:(NSString *)source {
    @synchronized(self){
    // 只清一个键，其余元数据保留：重新匹配 EPG 时用它丢弃过期
    // detectedEPGURL，而不丢弃名称、状态与更新时间等其余字段。
    if(![self isSource:source]||![key isKindOfClass:NSString.class]||!key.length)return;
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];
    NSMutableDictionary *p=[[self metadata:source] mutableCopy];
    if(![p objectForKey:key])return;
    [p removeObjectForKey:key];all[source]=p;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];

    }
}
+ (void)remove:(NSString *)source {
    @synchronized(self){
    if([source isKindOfClass:NSString.class]&&source.length)[NSFileManager.defaultManager removeItemAtPath:[self payloadFilePathForSource:source] error:NULL];
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];[all removeObjectForKey:source];[NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
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
