#import "TVBoxCatalogStore.h"

static NSError *TVBoxError(NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostTVBox" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSString *TVBoxString(id value, NSUInteger limit) {
    if ([value isKindOfClass:NSString.class]) return [value length] <= limit ? value : nil;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static BOOL TVBoxWebURL(NSString *value) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value ?: @""];
    return [@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] && parts.host.length && !parts.user.length && !parts.password.length && value.length<=8192;
}

@implementation TVBoxCatalogStore
+ (NSDictionary *)catalogWithMacCMSAPIURL:(NSString *)apiURL name:(NSString *)name error:(NSError **)error {
    NSString *trimmed=[apiURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!TVBoxWebURL(trimmed)){if(error)*error=TVBoxError(@"MacCMS 接口必须是有效的 HTTP/HTTPS 地址，且不能包含用户名或密码");return nil;}
    NSURLComponents *parts=[NSURLComponents componentsWithString:trimmed];
    if(parts.fragment.length){if(error)*error=TVBoxError(@"接口 URL 不能包含片段标记 #");return nil;}
    NSString *displayName=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!displayName.length)displayName=parts.host?:@"MacCMS 影视源";
    if(displayName.length>256){if(error)*error=TVBoxError(@"来源名称不能超过 256 个字符");return nil;}
    NSString *siteKey=[NSString stringWithFormat:@"maccms-%@",NSUUID.UUID.UUIDString.lowercaseString];
    NSDictionary *site=@{@"key":siteKey,@"name":displayName,@"api":trimmed,@"type":@"maccms",@"apiKind":@"maccms-api",@"supported":@YES,@"status":@"尚未验证 · 选中后读取",@"maccmsFormat":@"auto"};
    return @{@"id":NSUUID.UUID.UUIDString.lowercaseString,@"name":displayName,@"sites":@[site],@"lives":@[],@"url":trimmed,@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"catalogKind":@"maccms"};
}
+ (NSDictionary *)parseData:(NSData *)data sourceURL:(NSString *)sourceURL error:(NSError **)error {
    if (!data.length || data.length > 2*1024*1024) { if(error)*error=TVBoxError(@"TVBox 配置为空或超过 2 MiB"); return nil; }
    NSError *jsonError=nil;id json=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError];
    if (![json isKindOfClass:NSDictionary.class]) { if(error)*error=jsonError?:TVBoxError(@"TVBox 配置必须是 JSON 对象"); return nil; }
    NSArray *sites=[json[@"sites"] isKindOfClass:NSArray.class]?json[@"sites"]:@[];
    NSArray *lives=[json[@"lives"] isKindOfClass:NSArray.class]?json[@"lives"]:@[];
    if (!sites.count && !lives.count) { if(error)*error=TVBoxError(@"配置中没有可识别的 sites 或 lives"); return nil; }
    if (sites.count>500 || lives.count>100) { if(error)*error=TVBoxError(@"站点或直播源数量超过 500 项限制"); return nil; }
    NSMutableArray *cleanSites=[NSMutableArray array]; NSMutableSet *keys=[NSMutableSet set];
    for(id value in sites) {
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSString *key=TVBoxString(value[@"key"] ?: value[@"id"],256), *name=TVBoxString(value[@"name"],256), *api=TVBoxString(value[@"api"],8192);
        if(api.length&&!TVBoxWebURL(api)&&TVBoxWebURL(sourceURL)){NSURL *base=[NSURL URLWithString:sourceURL];NSURL *resolved=[NSURL URLWithString:api relativeToURL:base].absoluteURL;if(TVBoxWebURL(resolved.absoluteString))api=resolved.absoluteString;}
        if (!key.length || !name.length || !api.length || [keys containsObject:key]) continue;
        [keys addObject:key];
        NSString *ext=TVBoxString(value[@"ext"],8192); id extObject=value[@"ext"];
        if ([extObject isKindOfClass:NSDictionary.class] || [extObject isKindOfClass:NSArray.class]) {
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:extObject options:0 error:NULL];
            if (encoded.length<=65536) ext=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]; else ext=nil;
        }
        NSURLComponents *apiParts=[NSURLComponents componentsWithString:api];
        NSString *path=apiParts.path.lowercaseString;
        if ([path hasSuffix:@".md5"]) path=[path stringByDeletingPathExtension];
        NSString *siteType=TVBoxString(value[@"type"],32)?:@"";BOOL scriptFile=[@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:path.pathExtension.lowercaseString];BOOL jarFile=[path.pathExtension.lowercaseString isEqual:@"jar"];
        BOOL apiKindTVBox=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&([siteType isEqual:@"1"]||[siteType isEqual:@"4"]);
        BOOL direct=TVBoxWebURL(api)&&scriptFile;
        NSString *reason=apiKindTVBox?[NSString stringWithFormat:@"TVBox type %@ JSON API · 选中后请求，尚未验证",siteType]:(direct?@"可导入 · 将由现有脚本适配器检查":([siteType isEqual:@"3"]?@"需要 Android/JAR 运行时；iOS 不支持":([apiParts.scheme.lowercaseString isEqual:@"http"]||[apiParts.scheme.lowercaseString isEqual:@"https"]?@"此脚本类型需 Android/JAR 运行时；iOS 不支持":@"站点地址无效")));
        NSMutableDictionary *site=[@{@"key":key,@"name":name,@"api":api,@"ext":ext?:@"",@"type":siteType,@"supported":@((direct||apiKindTVBox)),@"status":reason,@"apiKind":apiKindTVBox?@"tvbox-api":(direct?@"script":@"unsupported")} mutableCopy];
        if([value[@"header"] isKindOfClass:NSDictionary.class]){NSMutableDictionary *safe=[NSMutableDictionary dictionary];NSUInteger headerCount=0;for(id headerKey in value[@"header"]){id headerValue=value[@"header"][headerKey];if(headerCount++>=24)break;if([headerKey isKindOfClass:NSString.class]&&[headerValue isKindOfClass:NSString.class]&&[headerKey length]<=128&&[headerValue length]<=4096)safe[headerKey]=headerValue;}if(safe.count)site[@"header"]=safe;}
        if([value[@"playUrl"] isKindOfClass:NSString.class]&&[value[@"playUrl"] length]<=4096)site[@"playUrl"]=value[@"playUrl"];
        [cleanSites addObject:site];
    }
    NSMutableArray *cleanLives=[NSMutableArray array]; NSMutableSet *urls=[NSMutableSet set];
    for(id value in lives) {
        NSString *name=nil,*url=nil;
        if ([value isKindOfClass:NSString.class]) { url=value; name=[NSURL URLWithString:value].host ?: @"TVBox 直播源"; }
        else if ([value isKindOfClass:NSDictionary.class]) { name=TVBoxString(value[@"name"],256); url=TVBoxString(value[@"url"],8192); }
        if (!name.length) name=@"TVBox 直播源";
        if (!TVBoxWebURL(url) || [urls containsObject:url]) continue;
        [urls addObject:url]; [cleanLives addObject:@{@"name":name,@"url":url}];
    }
    NSString *name=TVBoxString(json[@"name"],256) ?: TVBoxString(json[@"title"],256) ?: @"资源合集";
    NSMutableDictionary *catalog=[@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"sites":cleanSites.copy,@"lives":cleanLives.copy,@"updatedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    if (TVBoxWebURL(sourceURL)) catalog[@"url"]=sourceURL;
    return catalog;
}
+ (NSArray<NSDictionary *> *)catalogs {
    NSArray *rows=[NSUserDefaults.standardUserDefaults arrayForKey:@"tvboxCatalogs"];
    return [rows isKindOfClass:NSArray.class]?rows:@[];
}
+ (void)saveCatalog:(NSDictionary *)catalog {
    NSMutableArray *rows=[[self catalogs] mutableCopy];
    for(NSUInteger i=0;i<rows.count;i++) if([rows[i][@"id"] isEqual:catalog[@"id"]]) { NSMutableDictionary *merged=[rows[i] mutableCopy]; [merged addEntriesFromDictionary:catalog]; rows[i]=merged; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"]; return; }
    [rows addObject:catalog]; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"];
}
+ (NSDictionary *)catalogForID:(NSString *)identifier { for(NSDictionary *row in [self catalogs])if([row[@"id"] isEqual:identifier])return row; return nil; }
+ (void)removeCatalog:(NSString *)identifier { NSMutableArray *rows=[[self catalogs] mutableCopy]; NSIndexSet *remove=[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger idx,BOOL *stop){return [row[@"id"] isEqual:identifier];}]; [rows removeObjectsAtIndexes:remove]; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"]; }
+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:(NSDictionary *)catalog { return [catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[]; }
@end
