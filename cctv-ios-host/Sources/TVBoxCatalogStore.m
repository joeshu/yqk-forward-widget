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
        BOOL direct=TVBoxWebURL(api) && [@[@".js",@".mjs",@".cjs",@".py",@".zip"] containsObject:path.pathExtension.lowercaseString];
        NSString *reason=direct?@"可导入 · 将由现有脚本适配器检查":([apiParts.scheme.lowercaseString isEqual:@"http"]||[apiParts.scheme.lowercaseString isEqual:@"https"]?@"此站点 API 不是可直接导入的 JS/Python/ZIP 文件（常见为 JAR 类接口）":@"站点地址无效");
        [cleanSites addObject:@{@"key":key,@"name":name,@"api":api,@"ext":ext?:@"",@"type":TVBoxString(value[@"type"],32)?:@"",@"supported":@(direct),@"status":reason}];
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
    NSString *name=TVBoxString(json[@"name"],256) ?: TVBoxString(json[@"title"],256) ?: @"TVBox 资源目录";
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
