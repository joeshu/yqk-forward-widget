#import "TVBoxCatalogStore.h"
#import <zlib.h>

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

static NSString *TVBoxCatalogStorageDirectory(void) {
    NSString *applicationSupport=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory=[applicationSupport stringByAppendingPathComponent:@"TVBoxCatalogs"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

static BOOL TVBoxSafeCatalogID(NSString *identifier) {
    if(![identifier isKindOfClass:NSString.class]||!identifier.length||identifier.length>128)return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}

static NSString *TVBoxExportFilename(NSString *name) {
    NSString *base=[name isKindOfClass:NSString.class]?name:@"资源合集";
    base=[base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r"];
    NSMutableString *safe=[NSMutableString string];
    [base enumerateSubstringsInRange:NSMakeRange(0,base.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange substringRange,NSRange enclosingRange,BOOL *stop){
        [safe appendString:([substring rangeOfCharacterFromSet:invalid].location==NSNotFound&&[substring rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound)?substring:@"_"];
        if(safe.length>=64)*stop=YES;
    }];
    base=[safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!base.length)base=@"资源合集";
    return base;
}

static void TVBoxAppendLE16(NSMutableData *data,uint16_t value) {uint8_t bytes[2]={(uint8_t)value,(uint8_t)(value>>8)};[data appendBytes:bytes length:sizeof(bytes)];}
static void TVBoxAppendLE32(NSMutableData *data,uint32_t value) {uint8_t bytes[4]={(uint8_t)value,(uint8_t)(value>>8),(uint8_t)(value>>16),(uint8_t)(value>>24)};[data appendBytes:bytes length:sizeof(bytes)];}

static NSData *TVBoxZIPData(NSDictionary<NSString *,NSData *> *files,NSError **error) {
    NSMutableData *archive=[NSMutableData data],*central=[NSMutableData data];NSUInteger entryCount=0;
    NSArray<NSString *> *paths=[[files allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *path in paths){
        if(![path isKindOfClass:NSString.class]||!path.length||[path hasPrefix:@"/"]||[path containsString:@".."]||[path containsString:@"\\"]||[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){if(error)*error=TVBoxError(@"ZIP 文件路径无效");return nil;}
        NSData *plain=files[path];NSData *name=[path dataUsingEncoding:NSUTF8StringEncoding];if(!plain||!name.length||name.length>UINT16_MAX||plain.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 中有文件超过格式限制");return nil;}
        z_stream stream={0};if(deflateInit2(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY)!=Z_OK){if(error)*error=TVBoxError(@"无法初始化 ZIP 压缩");return nil;}
        NSMutableData *compressed=[NSMutableData dataWithLength:MAX(64,compressBound((uLong)plain.length))];stream.next_in=(Bytef *)plain.bytes;stream.avail_in=(uInt)plain.length;stream.next_out=compressed.mutableBytes;stream.avail_out=(uInt)compressed.length;int zresult=deflate(&stream,Z_FINISH);if(zresult!=Z_STREAM_END){deflateEnd(&stream);if(error)*error=TVBoxError(@"压缩资源 ZIP 失败");return nil;}compressed.length=stream.total_out;deflateEnd(&stream);
        if(compressed.length>UINT32_MAX||archive.length>UINT32_MAX||central.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 超过 4 GiB 格式限制");return nil;}
        uint32_t crc=(uint32_t)crc32(0,plain.bytes,(uInt)plain.length),offset=(uint32_t)archive.length;
        TVBoxAppendLE32(archive,0x04034b50);TVBoxAppendLE16(archive,20);TVBoxAppendLE16(archive,0x0800);TVBoxAppendLE16(archive,8);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,0x0021);TVBoxAppendLE32(archive,crc);TVBoxAppendLE32(archive,(uint32_t)compressed.length);TVBoxAppendLE32(archive,(uint32_t)plain.length);TVBoxAppendLE16(archive,(uint16_t)name.length);TVBoxAppendLE16(archive,0);[archive appendData:name];[archive appendData:compressed];
        TVBoxAppendLE32(central,0x02014b50);TVBoxAppendLE16(central,20);TVBoxAppendLE16(central,20);TVBoxAppendLE16(central,0x0800);TVBoxAppendLE16(central,8);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0x0021);TVBoxAppendLE32(central,crc);TVBoxAppendLE32(central,(uint32_t)compressed.length);TVBoxAppendLE32(central,(uint32_t)plain.length);TVBoxAppendLE16(central,(uint16_t)name.length);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE32(central,0);TVBoxAppendLE32(central,offset);[central appendData:name];entryCount++;
    }
    if(entryCount>UINT16_MAX||archive.length>UINT32_MAX||central.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 超过经典 ZIP 格式限制");return nil;}
    uint32_t centralOffset=(uint32_t)archive.length;[archive appendData:central];TVBoxAppendLE32(archive,0x06054b50);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,(uint16_t)entryCount);TVBoxAppendLE16(archive,(uint16_t)entryCount);TVBoxAppendLE32(archive,(uint32_t)central.length);TVBoxAppendLE32(archive,centralOffset);TVBoxAppendLE16(archive,0);return archive;
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
        NSString *siteType=TVBoxString(value[@"type"],32)?:@"";BOOL scriptFile=[@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:path.pathExtension.lowercaseString];BOOL jarFile=[path.pathExtension.lowercaseString isEqual:@"jar"];BOOL jarSpiderClass=[api.lowercaseString hasPrefix:@"csp_"];BOOL apiKindDouban=[siteType isEqual:@"3"]&&[api.lowercaseString isEqual:@"csp_doudou"];
        BOOL apiKindMacCMS=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&[siteType isEqual:@"0"];
        BOOL apiKindTVBox=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&([siteType isEqual:@"1"]||[siteType isEqual:@"4"]);
        BOOL direct=TVBoxWebURL(api)&&scriptFile;
        BOOL supported=direct||apiKindTVBox||apiKindMacCMS||apiKindDouban;
        NSString *reason=apiKindDouban?@"豆瓣影视索引 · iOS 原生适配 · 影片需跨点播源搜索播放":(apiKindMacCMS?@"TVBox type 0 · MacCMS JSON/XML API · 选中后请求":(apiKindTVBox?[NSString stringWithFormat:@"TVBox type %@ JSON API · 选中后请求，尚未验证",siteType]:(direct?@"可导入 · 将由现有脚本适配器检查":([siteType isEqual:@"3"]?((jarFile||jarSpiderClass)?@"需要 Android/JAR 运行时；iOS 不支持":@"脚本地址无法识别；保留在合集中"):([apiParts.scheme.lowercaseString isEqual:@"http"]||[apiParts.scheme.lowercaseString isEqual:@"https"]?@"此脚本类型需 Android/JAR 运行时；iOS 不支持":@"站点地址无效；保留在合集中")))));
        NSString *apiKind=apiKindDouban?@"douban-index":(apiKindMacCMS?@"maccms-api":(apiKindTVBox?@"tvbox-api":(direct?@"script":@"unsupported")));
        NSMutableDictionary *site=[@{@"key":key,@"name":name,@"api":api?:@"",@"ext":ext?:@"",@"type":siteType,@"supported":@(supported),@"status":reason,@"apiKind":apiKind,@"sourceIndex":@(siteIndex-1)} mutableCopy];
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
        NSMutableDictionary *live=[@{@"name":name,@"url":url?:@"",@"type":type,@"supported":@(supported),@"status":status,@"sourceIndex":@(liveIndex-1)} mutableCopy];
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
    // Keep the provider's original JSON as a sidecar when saved. Normalized
    // records drive browsing; exports still preserve every provider field.
    catalog[@"_sourceConfigData"]=data.copy;
    return catalog;
}
+ (NSArray<NSDictionary *> *)catalogs {
    NSArray *rows=[NSUserDefaults.standardUserDefaults arrayForKey:@"tvboxCatalogs"];
    return [rows isKindOfClass:NSArray.class]?rows:@[];
}
+ (NSArray<NSDictionary *> *)playbackParsers {
    return [self playbackParsersForCatalogID:nil];
}
+ (NSArray<NSDictionary *> *)playbackParsersForCatalogID:(NSString *)catalogID {
    catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Parser endpoints belong to their importing collection. With no known
    // collection there is no safe fallback, so never borrow another package's.
    if(!catalogID.length)return @[];
    NSMutableArray<NSDictionary *> *result=[NSMutableArray array];
    for(id rawCatalog in [[self catalogs] reverseObjectEnumerator]){
        if(![rawCatalog isKindOfClass:NSDictionary.class])continue;
        NSDictionary *catalog=rawCatalog;
        NSString *currentID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";
        if(![currentID isEqual:catalogID])continue;
        NSDictionary *config=[catalog[@"tvboxConfig"] isKindOfClass:NSDictionary.class]?catalog[@"tvboxConfig"]:@{};
        NSArray *parses=[config[@"parses"] isKindOfClass:NSArray.class]?config[@"parses"]:@[];
        NSUInteger limit=MIN(parses.count,(NSUInteger)32);
        for(NSUInteger index=0;index<limit;index++){
            id value=parses[index];
            if(result.count>=64)break;
            NSDictionary *row=[value isKindOfClass:NSDictionary.class]?value:nil;
            NSString *url=[value isKindOfClass:NSString.class]?value:([row[@"url"] isKindOfClass:NSString.class]?row[@"url"]:@"");
            url=[url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if(!url.length||url.length>8192)continue;
            NSString *probe=[[[url stringByReplacingOccurrencesOfString:@"{url}" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"$url" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"%s" withString:@"fixture"];
            NSURLComponents *parts=[NSURLComponents componentsWithString:probe];
            if((!parts.scheme.length||!parts.host.length)&&[catalog[@"url"] isKindOfClass:NSString.class]){
                NSString *marker=@"__TVBOX_MEDIA_URL_PLACEHOLDER__",*template=url;
                for(NSString *placeholder in @[@"{url}",@"$url",@"%s"])template=[template stringByReplacingOccurrencesOfString:placeholder withString:marker];
                NSURL *baseURL=[NSURL URLWithString:catalog[@"url"]],*absolute=[[NSURL URLWithString:template relativeToURL:baseURL] absoluteURL];
                if(absolute){url=[absolute.absoluteString stringByReplacingOccurrencesOfString:marker withString:@"{url}"];probe=[[[url stringByReplacingOccurrencesOfString:@"{url}" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"$url" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"%s" withString:@"fixture"];parts=[NSURLComponents componentsWithString:probe];}
            }
            if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length)continue;
            id rawType=row[@"type"];id type=([rawType isKindOfClass:NSString.class]||[rawType isKindOfClass:NSNumber.class])?rawType:@0;
            NSString *name=[row[@"name"] isKindOfClass:NSString.class]?[(NSString *)row[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
            if(name.length>256)name=[name substringToIndex:256];if(!name.length)name=@"资源合集解析";
            NSString *identifier=[NSString stringWithFormat:@"%@:%lu",currentID.length?currentID:@"legacy",(unsigned long)index];
            NSMutableDictionary *parser=[NSMutableDictionary dictionaryWithDictionary:@{@"id":identifier,@"url":url,@"name":name,@"type":type,@"index":@(index),@"catalogID":currentID}];
            if([row[@"header"] isKindOfClass:NSDictionary.class])parser[@"header"]=row[@"header"];
            if([row[@"ext"] isKindOfClass:NSDictionary.class]||[row[@"ext"] isKindOfClass:NSArray.class]||[row[@"ext"] isKindOfClass:NSString.class])parser[@"ext"]=row[@"ext"];
            if([row[@"flag"] isKindOfClass:NSString.class])parser[@"flag"]=row[@"flag"];
            parser[@"catalogName"]=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";
            [result addObject:parser.copy];
        }
    }
    return result.copy;
}
+ (void)saveCatalog:(NSDictionary *)catalog {
    NSString *identifier=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";
    NSData *sourceData=[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class]?catalog[@"_sourceConfigData"]:nil;
    NSMutableDictionary *storedCatalog=[catalog mutableCopy];
    if(sourceData.length){BOOL saved=NO;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];saved=[sourceData writeToFile:path options:NSDataWritingAtomic error:NULL];}if(saved)[storedCatalog removeObjectForKey:@"_sourceConfigData"];else storedCatalog[@"_sourceConfigData"]=sourceData;}
    else [storedCatalog removeObjectForKey:@"_sourceConfigData"];
    NSMutableArray *rows=[[self catalogs] mutableCopy];
    for(NSUInteger i=0;i<rows.count;i++) if([rows[i][@"id"] isEqual:identifier]) { NSMutableDictionary *merged=[rows[i] mutableCopy]; [merged addEntriesFromDictionary:storedCatalog]; rows[i]=merged; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"]; return; }
    [rows addObject:storedCatalog]; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"];
}
+ (NSDictionary *)catalogForID:(NSString *)identifier { for(NSDictionary *row in [self catalogs])if([row[@"id"] isEqual:identifier])return row; return nil; }
+ (void)removeCatalog:(NSString *)identifier { NSMutableArray *rows=[[self catalogs] mutableCopy]; NSIndexSet *remove=[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger idx,BOOL *stop){return [row[@"id"] isEqual:identifier];}]; [rows removeObjectsAtIndexes:remove]; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"];if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];[NSFileManager.defaultManager removeItemAtPath:path error:NULL];} }
+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:(NSDictionary *)catalog { return [catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[]; }
+ (NSDictionary *)reconstructedConfigForCatalog:(NSDictionary *)catalog {
    NSMutableDictionary *config=[NSMutableDictionary dictionary];NSString *name=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";config[@"name"]=name;
    NSMutableArray *sites=[NSMutableArray array];for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[]){NSMutableDictionary *row=[NSMutableDictionary dictionary];for(NSString *key in @[@"key",@"name",@"api",@"type",@"header",@"playUrl"]){id value=site[key];if(value)row[key]=value;}NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";if(ext.length){id value=[NSJSONSerialization JSONObjectWithData:[ext dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL];row[@"ext"]=value?:ext;}if(row.count)[sites addObject:row];}
    NSMutableArray *lives=[NSMutableArray array];for(NSDictionary *live in [catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[]){NSMutableDictionary *row=[NSMutableDictionary dictionary];for(NSString *key in @[@"name",@"url",@"type",@"ua"]){id value=live[key];if(value)row[key]=value;}if(row.count)[lives addObject:row];}config[@"sites"]=sites;config[@"lives"]=lives;
    NSDictionary *extras=[catalog[@"tvboxConfig"] isKindOfClass:NSDictionary.class]?catalog[@"tvboxConfig"]:@{};[config addEntriesFromDictionary:extras];return config;
}
+ (nullable NSDictionary *)originalConfigForCatalogID:(NSString *)identifier catalog:(NSDictionary **)catalogOut error:(NSError **)error {
    NSDictionary *catalog=[self catalogForID:identifier];if(!catalog){if(error)*error=TVBoxError(@"找不到此资源合集");return nil;}if(catalogOut)*catalogOut=catalog;
    NSData *data=nil;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];}
    if(!data.length&&[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class])data=catalog[@"_sourceConfigData"];
    NSDictionary *config=nil;if(data.length){id value=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];if([value isKindOfClass:NSDictionary.class])config=value;}
    return config?:[self reconstructedConfigForCatalog:catalog];
}
+ (nullable NSData *)exportDataForCatalogID:(NSString *)identifier error:(NSError **)error {
    NSDictionary *catalog=nil,*config=[self originalConfigForCatalogID:identifier catalog:&catalog error:error];if(!config)return nil;
    NSData *preserved=nil;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];preserved=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];}if(!preserved.length&&[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class])preserved=catalog[@"_sourceConfigData"];if(preserved.length){id original=[NSJSONSerialization JSONObjectWithData:preserved options:NSJSONReadingFragmentsAllowed error:NULL];if([original isKindOfClass:NSDictionary.class])return preserved;}
    NSData *result=[NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!result&&error&&!*error)*error=TVBoxError(@"无法生成资源合集 JSON");return result;
}
+ (nullable NSData *)exportSingleResourceForCatalogID:(NSString *)identifier kind:(NSString *)kind index:(NSUInteger)index error:(NSError **)error {
    NSDictionary *catalog=nil,*original=[self originalConfigForCatalogID:identifier catalog:&catalog error:error];if(!original||!catalog)return nil;
    BOOL isLive=[kind isEqual:@"live"];if(!isLive&&![kind isEqual:@"site"]){if(error)*error=TVBoxError(@"未知的资源类型");return nil;}
    NSArray *rows=[catalog[isLive?@"lives":@"sites"] isKindOfClass:NSArray.class]?catalog[isLive?@"lives":@"sites"]:@[];if(index>=rows.count){if(error)*error=TVBoxError(@"找不到要导出的资源");return nil;}NSDictionary *selected=rows[index];
    NSString *sourceKey=isLive?@"lives":@"sites";NSArray *originalRows=[original[sourceKey] isKindOfClass:NSArray.class]?original[sourceKey]:@[];NSUInteger sourceIndex=[selected[@"sourceIndex"] respondsToSelector:@selector(unsignedIntegerValue)]?[selected[@"sourceIndex"] unsignedIntegerValue]:index;
    id raw=sourceIndex<originalRows.count?originalRows[sourceIndex]:nil;
    if(!raw){NSMutableDictionary *fallback=[NSMutableDictionary dictionary];for(NSString *key in (isLive?@[@"name",@"url",@"type",@"ua"]:@[@"key",@"name",@"api",@"ext",@"type",@"header",@"playUrl"]))if(selected[key])fallback[key]=selected[key];raw=fallback;}
    if(isLive&&[raw isKindOfClass:NSString.class])raw=selected[@"url"]?:raw;
    else if([raw isKindOfClass:NSDictionary.class]){NSMutableDictionary *resolved=[raw mutableCopy];NSString *urlKey=isLive?@"url":@"api";if([selected[urlKey] isKindOfClass:NSString.class]&&[selected[urlKey] length])resolved[urlKey]=selected[urlKey];raw=resolved;}
    NSMutableDictionary *single=[original mutableCopy];single[@"sites"]=isLive?@[]:@[raw];single[@"lives"]=isLive?@[raw]:@[];
    NSData *data=[NSJSONSerialization dataWithJSONObject:single options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!data&&error&&!*error)*error=TVBoxError(@"无法生成单资源 JSON");return data;
}
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier files:(NSDictionary<NSString *,NSData *> *)files error:(NSError **)error {
    if(![self catalogForID:identifier]){if(error)*error=TVBoxError(@"找不到此资源合集");return nil;}NSMutableDictionary *contents=[files mutableCopy]?:[NSMutableDictionary dictionary];if(!contents[@"config.json"]){NSData *json=[self exportDataForCatalogID:identifier error:error];if(!json)return nil;contents[@"config.json"]=json;}
    NSDictionary *catalog=[self catalogForID:identifier];NSString *name=TVBoxExportFilename(catalog[@"name"]);if(!contents[@"README.txt"]){NSString *readme=[NSString stringWithFormat:@"%@\n\n本 ZIP 包含完整 TVBox JSON 配置，以及可下载的内部 PY/JS 文件。source-manifest.json 记录文件与站点的对应关系和未能获取的项目。\n",name];contents[@"README.txt"]=[readme dataUsingEncoding:NSUTF8StringEncoding];}NSData *archive=TVBoxZIPData(contents,error);if(!archive)return nil;
    NSString *filename=[NSString stringWithFormat:@"%@-%@.zip",name,NSUUID.UUID.UUIDString.lowercaseString];NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];if(![archive writeToURL:url options:NSDataWritingAtomic error:error])return nil;return url;
}
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier error:(NSError **)error {return [self writeZIPArchiveForCatalogID:identifier files:nil error:error];}
@end
