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
    return parts&&[@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] && parts.host.length && !parts.user.length && !parts.password.length && value.length<=8192;
}

static NSString *TVBoxBasicAuthorization(NSURLComponents *parts) {
    if (!parts.user.length && !parts.password.length) return nil;
    NSString *user = parts.percentEncodedUser.stringByRemovingPercentEncoding ?: @"";
    NSString *password = parts.percentEncodedPassword.stringByRemovingPercentEncoding ?: @"";
    NSData *credentials = [[NSString stringWithFormat:@"%@:%@", user, password] dataUsingEncoding:NSUTF8StringEncoding];
    return credentials.length ? [@"Basic " stringByAppendingString:[credentials base64EncodedStringWithOptions:0]] : nil;
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
    if (!data.length || data.length > 8*1024*1024) { if(error)*error=TVBoxError(@"TVBox 配置为空或超过 8 MiB"); return nil; }
    NSError *jsonError=nil;id json=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError];
    if (![json isKindOfClass:NSDictionary.class]) { if(error)*error=jsonError?:TVBoxError(@"TVBox 配置必须是 JSON 对象"); return nil; }
    NSArray *sites=[json[@"sites"] isKindOfClass:NSArray.class]?json[@"sites"]:@[];
    NSArray *lives=[json[@"lives"] isKindOfClass:NSArray.class]?json[@"lives"]:@[];
    if (!sites.count && !lives.count) { if(error)*error=TVBoxError(@"配置中没有可识别的 sites 或 lives"); return nil; }
    if (sites.count>2000 || lives.count>500) { if(error)*error=TVBoxError(@"站点或直播源数量超过 2000 / 500 项限制"); return nil; }
    NSMutableArray *cleanSites=[NSMutableArray array]; NSMutableSet *keys=[NSMutableSet set];NSUInteger siteIndex=0;
    for(id value in sites) {
        siteIndex++;
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSString *key=TVBoxString(value[@"key"] ?: value[@"id"],256), *name=TVBoxString(value[@"name"],256), *api=TVBoxString(value[@"api"],8192);
        if(!key.length)key=[NSString stringWithFormat:@"site-%lu",(unsigned long)siteIndex];
        if(!name.length)name=[NSString stringWithFormat:@"未命名站点 %lu",(unsigned long)siteIndex];
        if(api.length&&!TVBoxWebURL(api)&&TVBoxWebURL(sourceURL)){NSURL *base=[NSURL URLWithString:sourceURL];NSURL *resolved=[NSURL URLWithString:api relativeToURL:base].absoluteURL;if(TVBoxWebURL(resolved.absoluteString))api=resolved.absoluteString;}
        if([keys containsObject:key])key=[NSString stringWithFormat:@"%@-%lu",key,(unsigned long)siteIndex];
        [keys addObject:key];
        NSMutableDictionary *safeHeaders=[NSMutableDictionary dictionary];
        if([value[@"header"] isKindOfClass:NSDictionary.class]){NSUInteger headerCount=0;for(id headerKey in value[@"header"]){id headerValue=value[@"header"][headerKey];if(headerCount++>=24)break;if([headerKey isKindOfClass:NSString.class]&&[headerValue isKindOfClass:NSString.class]&&[headerKey length]<=128&&[headerValue length]<=4096)safeHeaders[headerKey]=headerValue;}}
        NSURLComponents *apiParts=[NSURLComponents componentsWithString:api?:@""];
        NSString *basicAuthorization=TVBoxBasicAuthorization(apiParts);
        if(basicAuthorization.length){apiParts.user=nil;apiParts.password=nil;api=apiParts.URL.absoluteString;BOOL hasAuthorization=NO;for(NSString *headerName in safeHeaders)if([headerName caseInsensitiveCompare:@"Authorization"]==NSOrderedSame){hasAuthorization=YES;break;}if(!hasAuthorization)safeHeaders[@"Authorization"]=basicAuthorization;}
        NSString *ext=TVBoxString(value[@"ext"],8192); id extObject=value[@"ext"];
        if ([extObject isKindOfClass:NSDictionary.class] || [extObject isKindOfClass:NSArray.class]) {
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:extObject options:0 error:NULL];
            if (encoded.length<=65536) ext=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]; else ext=nil;
        }
        apiParts=[NSURLComponents componentsWithString:api?:@""];
        NSString *path=apiParts.path.lowercaseString;
        if ([path hasSuffix:@".md5"]) path=[path stringByDeletingPathExtension];
        NSString *siteType=TVBoxString(value[@"type"],32)?:@"";BOOL scriptFile=[@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:path.pathExtension.lowercaseString];BOOL jarFile=[path.pathExtension.lowercaseString isEqual:@"jar"];BOOL jarSpiderClass=[api.lowercaseString hasPrefix:@"csp_"];
        BOOL apiKindMacCMS=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&[siteType isEqual:@"0"];
        BOOL apiKindTVBox=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&([siteType isEqual:@"1"]||[siteType isEqual:@"4"]);
        BOOL direct=TVBoxWebURL(api)&&scriptFile;
        BOOL supported=direct||apiKindTVBox||apiKindMacCMS;
        NSString *reason=apiKindMacCMS?@"TVBox type 0 · MacCMS JSON/XML API · 选中后请求":(apiKindTVBox?[NSString stringWithFormat:@"TVBox type %@ JSON API · 选中后请求，尚未验证",siteType]:(direct?@"可导入 · 将由现有脚本适配器检查":([siteType isEqual:@"3"]?((jarFile||jarSpiderClass)?@"需要 Android/JAR 运行时；iOS 不支持":@"脚本地址无法识别；保留在合集中"):([apiParts.scheme.lowercaseString isEqual:@"http"]||[apiParts.scheme.lowercaseString isEqual:@"https"]?@"此脚本类型需 Android/JAR 运行时；iOS 不支持":@"站点地址无效；保留在合集中"))));
        NSString *apiKind=apiKindMacCMS?@"maccms-api":(apiKindTVBox?@"tvbox-api":(direct?@"script":@"unsupported"));
        NSMutableDictionary *site=[@{@"key":key,@"name":name,@"api":api?:@"",@"ext":ext?:@"",@"type":siteType,@"supported":@(supported),@"status":reason,@"apiKind":apiKind} mutableCopy];
        if(safeHeaders.count)site[@"header"]=safeHeaders;
        if([value[@"playUrl"] isKindOfClass:NSString.class]&&[value[@"playUrl"] length]<=4096)site[@"playUrl"]=value[@"playUrl"];
        [cleanSites addObject:site];
    }
    NSMutableArray *cleanLives=[NSMutableArray array];NSUInteger liveIndex=0;
    for(id value in lives) {
        liveIndex++;NSString *name=nil,*url=nil,*type=@"0",*userAgent=nil;
        if ([value isKindOfClass:NSString.class]) { url=value; name=[NSURL URLWithString:value].host ?: @"TVBox 直播源"; }
        else if ([value isKindOfClass:NSDictionary.class]) { name=TVBoxString(value[@"name"],256); url=TVBoxString(value[@"url"],8192);type=TVBoxString(value[@"type"],32)?:@"0";userAgent=TVBoxString(value[@"ua"]?:value[@"userAgent"],1024); }
        if(url.length&&!TVBoxWebURL(url)&&TVBoxWebURL(sourceURL)){NSURL *base=[NSURL URLWithString:sourceURL];NSURL *resolved=[NSURL URLWithString:url relativeToURL:base].absoluteURL;if(TVBoxWebURL(resolved.absoluteString))url=resolved.absoluteString;}
        if (!name.length) name=[NSString stringWithFormat:@"TVBox 直播源 %lu",(unsigned long)liveIndex];
        BOOL validURL=TVBoxWebURL(url);BOOL supported=validURL&&[type isEqual:@"0"];
        NSString *status=supported?@"可订阅 · M3U/TXT 清单（刷新时应用 UA）":([type isEqual:@"3"]?@"需要 Android/JAR 运行时；直播项保留但不能直接订阅":@"直播地址无效或类型暂不支持；已保留");
        NSMutableDictionary *live=[@{@"name":name,@"url":url?:@"",@"type":type,@"supported":@(supported),@"status":status} mutableCopy];
        if(userAgent.length&&[userAgent rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location==NSNotFound)live[@"ua"]=userAgent;
        [cleanLives addObject:live];
    }
    NSString *name=TVBoxString(json[@"name"],256) ?: TVBoxString(json[@"title"],256) ?: @"资源合集";
    NSMutableDictionary *catalog=[@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"sites":cleanSites.copy,@"lives":cleanLives.copy,@"updatedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    NSMutableDictionary *tvboxConfig=[NSMutableDictionary dictionary];NSMutableArray *omittedConfigFields=[NSMutableArray array];NSUInteger extraBytes=0;
    for(NSString *field in @[@"notice",@"spider",@"wallpaper",@"logo",@"danmaku",@"parses",@"rules",@"doh",@"flags",@"ijk",@"ads"]){id item=json[field];if(!item)continue;if(![NSJSONSerialization isValidJSONObject:item]&&![item isKindOfClass:NSString.class]&&![item isKindOfClass:NSNumber.class]){[omittedConfigFields addObject:field];continue;}NSData *encoded=[NSJSONSerialization dataWithJSONObject:@{field:item} options:0 error:NULL];if(!encoded.length||encoded.length>1024*1024-extraBytes){[omittedConfigFields addObject:field];continue;}tvboxConfig[field]=item;extraBytes+=encoded.length;}
    if(tvboxConfig.count)catalog[@"tvboxConfig"]=tvboxConfig.copy;
    if(omittedConfigFields.count)catalog[@"tvboxConfigOmittedFields"]=omittedConfigFields.copy;
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
