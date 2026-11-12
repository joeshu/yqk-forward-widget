#import "ProfileStore.h"
NSNotificationName const ProfileStoreMetadataDidChangeNotification = @"CCTVHostProfileStoreMetadataDidChange";

static NSString *const CCTVNativeLogoSourceKey = @"__native_cctv__";
static NSString *const CCTVDisabledChannelLogoSourcesKey = @"disabledChannelLogoSources";
static NSString *const CCTVDisabledPlayerCornerLogoSourcesKey = @"disabledPlayerCornerLogoSources";
static NSString *const CCTVDisabledChannelPreviewSourcesKey = @"disabledChannelPreviewSources";
static NSString *const CCTVDisabledChannelTelemetrySourcesKey = @"disabledChannelTelemetrySources";

@implementation ProfileStore
+ (BOOL)isHTTP:(id)source {
    if(![source isKindOfClass:NSString.class]||[source length]>8192)return NO;
    @try{NSURLComponents *c=[NSURLComponents componentsWithString:source];return c.URL&&c.host.length&&[@[@"http",@"https"] containsObject:c.scheme.lowercaseString];}@catch(NSException *e){return NO;}
}
+ (BOOL)isSource:(id)source {
    if([self isHTTP:source])return YES;
    return [source isKindOfClass:NSString.class]&&[source hasPrefix:@"local-playlist:"]&&[[NSUUID alloc] initWithUUIDString:[source substringFromIndex:15]]!=nil;
}
+ (NSDictionary *)metadata:(NSString *)source {if(![source isKindOfClass:NSString.class]||!source.length)return @{};id value=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"][source];return [value isKindOfClass:NSDictionary.class]?value:@{};}
+ (void)update:(NSString *)source values:(NSDictionary *)values {
    @synchronized(self){
    if(![self isSource:source]||![values isKindOfClass:NSDictionary.class])return;
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];
    NSMutableDictionary *p=[[self metadata:source] mutableCopy];[p addEntriesFromDictionary:values];all[source]=p;
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
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];[all removeObjectForKey:source];[NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
    for(NSString *key in @[@"profileOrder",@"disabledSubscriptions",CCTVDisabledChannelLogoSourcesKey,CCTVDisabledPlayerCornerLogoSourcesKey,CCTVDisabledChannelPreviewSourcesKey,CCTVDisabledChannelTelemetrySourcesKey]){NSMutableArray *a=[[NSUserDefaults.standardUserDefaults arrayForKey:key]?:@[] mutableCopy];[a removeObject:source];[NSUserDefaults.standardUserDefaults setObject:a forKey:key];}

    }
}
+ (NSArray<NSString *> *)orderedSources:(NSArray<NSString *> *)sources {
    NSArray *order=[NSUserDefaults.standardUserDefaults arrayForKey:@"profileOrder"]?:@[];
    return [sources sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){NSUInteger x=[order indexOfObject:a],y=[order indexOfObject:b];if(x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;return [a compare:b];}];
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
    return trimmed.length ? trimmed : CCTVNativeLogoSourceKey;
}

+ (BOOL)isChannelLogoEnabledForSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
        id nativePref = [defaults objectForKey:@"nativeChannelLogoEnabled"];
        if (nativePref && ![nativePref boolValue]) return NO;
    }
    NSArray *disabled = [defaults arrayForKey:CCTVDisabledChannelLogoSourcesKey];
    if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:key]) return NO;
    NSDictionary *meta = [self metadata:key];
    NSString *serviceID = [meta[@"managedServiceID"] isKindOfClass:NSString.class] ? meta[@"managedServiceID"] : @"";
    if (serviceID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"plugin:" stringByAppendingString:serviceID]]) return NO;
    NSString *catalogID = [meta[@"tvboxCatalogID"] isKindOfClass:NSString.class] ? meta[@"tvboxCatalogID"] : @"";
    if (catalogID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"tvbox:" stringByAppendingString:catalogID]]) return NO;
    return YES;
}

+ (void)setChannelLogoEnabled:(BOOL)enabled forSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *disabled = [[defaults arrayForKey:CCTVDisabledChannelLogoSourcesKey] ?: @[] mutableCopy];
        [disabled removeObject:key];
        if (!enabled) [disabled addObject:key];
        [defaults setObject:disabled.copy forKey:CCTVDisabledChannelLogoSourcesKey];
        if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
            [defaults setBool:enabled forKey:@"nativeChannelLogoEnabled"];
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

+ (BOOL)isPlayerCornerLogoEnabledForSource:(NSString *)source {
    if (![self isChannelLogoEnabledForSource:source]) return NO;
    NSString *key = [self normalizedLogoSourceKey:source];
    NSArray *disabled = [NSUserDefaults.standardUserDefaults arrayForKey:CCTVDisabledPlayerCornerLogoSourcesKey];
    if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:key]) return NO;
    NSDictionary *meta = [self metadata:key];
    NSString *serviceID = [meta[@"managedServiceID"] isKindOfClass:NSString.class] ? meta[@"managedServiceID"] : @"";
    if (serviceID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"plugin:" stringByAppendingString:serviceID]]) return NO;
    NSString *catalogID = [meta[@"tvboxCatalogID"] isKindOfClass:NSString.class] ? meta[@"tvboxCatalogID"] : @"";
    if (catalogID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"tvbox:" stringByAppendingString:catalogID]]) return NO;
    return YES;
}

+ (void)setPlayerCornerLogoEnabled:(BOOL)enabled forSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *disabled = [[defaults arrayForKey:CCTVDisabledPlayerCornerLogoSourcesKey] ?: @[] mutableCopy];
        [disabled removeObject:key];
        if (!enabled) [disabled addObject:key];
        [defaults setObject:disabled.copy forKey:CCTVDisabledPlayerCornerLogoSourcesKey];
        if (enabled && ![self isChannelLogoEnabledForSource:key]) {
            NSMutableArray *channelDisabled = [[defaults arrayForKey:CCTVDisabledChannelLogoSourcesKey] ?: @[] mutableCopy];
            [channelDisabled removeObject:key];
            [defaults setObject:channelDisabled.copy forKey:CCTVDisabledChannelLogoSourcesKey];
            if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
                [defaults setBool:YES forKey:@"nativeChannelLogoEnabled"];
            }
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
    if (![self isChannelLogoEnabledForChannel:channel]) return NO;
    NSString *remoteURL = [channel[@"remoteURL"] isKindOfClass:NSString.class] ? channel[@"remoteURL"] : @"";
    if (!remoteURL.length || [channel[@"nativePlainRoute"] boolValue]) {
        return [self isPlayerCornerLogoEnabledForSource:CCTVNativeLogoSourceKey];
    }
    NSArray *sources = [channel[@"subscriptionSources"] isKindOfClass:NSArray.class] ? channel[@"subscriptionSources"] : @[];
    if (!sources.count) return [self isPlayerCornerLogoEnabledForSource:remoteURL];
    NSSet *disabledSubs = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] ?: @[]];
    for (id raw in sources) {
        if (![raw isKindOfClass:NSString.class] || ![(NSString *)raw length]) continue;
        if ([disabledSubs containsObject:raw]) continue;
        if ([self isPlayerCornerLogoEnabledForSource:raw]) return YES;
    }
    return NO;
}

+ (BOOL)isChannelPreviewEnabledForSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
        id nativePref = [defaults objectForKey:@"nativeChannelPreviewEnabled"];
        if (nativePref && ![nativePref boolValue]) return NO;
    }
    NSArray *disabled = [defaults arrayForKey:CCTVDisabledChannelPreviewSourcesKey];
    if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:key]) return NO;
    NSDictionary *meta = [self metadata:key];
    NSString *serviceID = [meta[@"managedServiceID"] isKindOfClass:NSString.class] ? meta[@"managedServiceID"] : @"";
    if (serviceID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"plugin:" stringByAppendingString:serviceID]]) return NO;
    NSString *catalogID = [meta[@"tvboxCatalogID"] isKindOfClass:NSString.class] ? meta[@"tvboxCatalogID"] : @"";
    if (catalogID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"tvbox:" stringByAppendingString:catalogID]]) return NO;
    return YES;
}

+ (void)setChannelPreviewEnabled:(BOOL)enabled forSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *disabled = [[defaults arrayForKey:CCTVDisabledChannelPreviewSourcesKey] ?: @[] mutableCopy];
        [disabled removeObject:key];
        if (!enabled) [disabled addObject:key];
        [defaults setObject:disabled.copy forKey:CCTVDisabledChannelPreviewSourcesKey];
        if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
            [defaults setBool:enabled forKey:@"nativeChannelPreviewEnabled"];
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
    NSString *key = [self normalizedLogoSourceKey:source];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
        id nativePref = [defaults objectForKey:@"nativeChannelTelemetryEnabled"];
        if (nativePref && ![nativePref boolValue]) return NO;
    }
    NSArray *disabled = [defaults arrayForKey:CCTVDisabledChannelTelemetrySourcesKey];
    if ([disabled isKindOfClass:NSArray.class] && [disabled containsObject:key]) return NO;
    NSDictionary *meta = [self metadata:key];
    NSString *serviceID = [meta[@"managedServiceID"] isKindOfClass:NSString.class] ? meta[@"managedServiceID"] : @"";
    if (serviceID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"plugin:" stringByAppendingString:serviceID]]) return NO;
    NSString *catalogID = [meta[@"tvboxCatalogID"] isKindOfClass:NSString.class] ? meta[@"tvboxCatalogID"] : @"";
    if (catalogID.length && [disabled isKindOfClass:NSArray.class] && [disabled containsObject:[@"tvbox:" stringByAppendingString:catalogID]]) return NO;
    return YES;
}

+ (void)setChannelTelemetryEnabled:(BOOL)enabled forSource:(NSString *)source {
    NSString *key = [self normalizedLogoSourceKey:source];
    @synchronized(self) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableArray *disabled = [[defaults arrayForKey:CCTVDisabledChannelTelemetrySourcesKey] ?: @[] mutableCopy];
        [disabled removeObject:key];
        if (!enabled) [disabled addObject:key];
        [defaults setObject:disabled.copy forKey:CCTVDisabledChannelTelemetrySourcesKey];
        if ([key isEqualToString:CCTVNativeLogoSourceKey]) {
            [defaults setBool:enabled forKey:@"nativeChannelTelemetryEnabled"];
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
        for (NSString *prefKey in @[CCTVDisabledChannelLogoSourcesKey, CCTVDisabledPlayerCornerLogoSourcesKey, CCTVDisabledChannelPreviewSourcesKey, CCTVDisabledChannelTelemetrySourcesKey]) {
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
        cctvRegex = [NSRegularExpression regularExpressionWithPattern:@"cctv[-\s_]*(5\+|5plus|4k|8k|1[0-7]|[1-9])(?![0-9])" options:NSRegularExpressionCaseInsensitive error:NULL];
        cetvRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:cetv|中国教育|教育)[-\s_]*([1-4])(?![0-9])" options:NSRegularExpressionCaseInsensitive error:NULL];
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
