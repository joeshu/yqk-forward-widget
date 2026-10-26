#import "MediaAPIClient.h"
#import "RuntimeDiagnostics.h"
#import <QuartzCore/QuartzCore.h>

BOOL MediaSourceUsesNativeCatalogAPI(NSDictionary *source) {
    NSString *protocol=[source[@"protocol"] isKindOfClass:NSString.class]?source[@"protocol"]:@"";
    return [protocol isEqual:@"tvbox-api"]||[protocol isEqual:@"maccms-api"];
}

@interface MediaCMSXMLNode : NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSDictionary *attributes;
@property(nonatomic,strong) NSMutableString *text;
@property(nonatomic,strong) NSMutableArray<MediaCMSXMLNode *> *children;
@end
@implementation MediaCMSXMLNode
- (instancetype)init { if((self=[super init])){_text=[NSMutableString string];_children=[NSMutableArray array];_attributes=@{};}return self; }
@end

@interface MediaCMSXMLReader : NSObject <NSXMLParserDelegate>
@property(nonatomic,strong) MediaCMSXMLNode *root;
@property(nonatomic,strong) NSMutableArray<MediaCMSXMLNode *> *stack;
@property(nonatomic) NSUInteger nodeCount;
@property(nonatomic) NSUInteger textBytes;
@property(nonatomic) BOOL exceededLimit;
@end
@implementation MediaCMSXMLReader
- (instancetype)init { if((self=[super init]))_stack=[NSMutableArray array];return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    if(++self.nodeCount>50000){self.exceededLimit=YES;[parser abortParsing];return;}
    MediaCMSXMLNode *node=[MediaCMSXMLNode new];node.name=element.lowercaseString;node.attributes=attributes?:@{};
    if(self.stack.lastObject)[self.stack.lastObject.children addObject:node];else self.root=node;
    [self.stack addObject:node];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { NSUInteger bytes=[string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];if(self.textBytes+bytes>1024*1024||(self.stack.lastObject.text.length+string.length)>256*1024){self.exceededLimit=YES;[parser abortParsing];return;}self.textBytes+=bytes;if(self.stack.lastObject)[self.stack.lastObject.text appendString:string]; }
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)CDATABlock { if(self.textBytes+CDATABlock.length>1024*1024){self.exceededLimit=YES;[parser abortParsing];return;}NSString *value=[[NSString alloc] initWithData:CDATABlock encoding:NSUTF8StringEncoding];if(value.length&&self.stack.lastObject&&(self.stack.lastObject.text.length+value.length)<=256*1024){self.textBytes+=CDATABlock.length;[self.stack.lastObject.text appendString:value];}else if(value.length){self.exceededLimit=YES;[parser abortParsing];} }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName { if(self.stack.count)[self.stack removeLastObject]; }
- (NSData *)parser:(NSXMLParser *)parser resolveExternalEntityName:(NSString *)name systemID:(NSString *)systemID { return nil; }
@end

static MediaCMSXMLNode *MediaCMSChild(MediaCMSXMLNode *node,NSString *name) { for(MediaCMSXMLNode *child in node.children)if([child.name isEqual:name.lowercaseString])return child;return nil; }
static NSString *MediaCMSText(MediaCMSXMLNode *node) { return [node.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@""; }
static NSDictionary *MediaCMSVideo(MediaCMSXMLNode *node) {
    NSMutableDictionary *row=[NSMutableDictionary dictionary];
    for(MediaCMSXMLNode *child in node.children){
        if([child.name isEqual:@"dl"]){NSMutableArray *flags=[NSMutableArray array],*payloads=[NSMutableArray array];for(MediaCMSXMLNode *dd in child.children)if([dd.name isEqual:@"dd"]){NSString *flag=[dd.attributes[@"flag"] isKindOfClass:NSString.class]?dd.attributes[@"flag"]:@"";NSString *payload=MediaCMSText(dd);if(!payload.length)continue;[flags addObject:flag.length?flag:[NSString stringWithFormat:@"线路 %lu",(unsigned long)flags.count+1]];[payloads addObject:payload];}if(flags.count){row[@"vod_play_from"]=[flags componentsJoinedByString:@"$$$"];row[@"vod_play_url"]=[payloads componentsJoinedByString:@"$$$"];}continue;}
        NSString *text=MediaCMSText(child);if(text.length)row[child.name]=text;
    }
    if(!row[@"vod_id"]&&row[@"id"])row[@"vod_id"]=row[@"id"];
    if(!row[@"vod_name"]&&row[@"name"])row[@"vod_name"]=row[@"name"];
    if(!row[@"vod_pic"]&&row[@"pic"])row[@"vod_pic"]=row[@"pic"];
    if(!row[@"vod_content"]&&row[@"des"])row[@"vod_content"]=row[@"des"];
    return row;
}
static NSDictionary *MediaCMSXMLObject(NSData *data,NSError **error) {
    MediaCMSXMLReader *reader=[MediaCMSXMLReader new];NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];parser.delegate=reader;parser.shouldResolveExternalEntities=NO;parser.externalEntityResolvingPolicy=NSXMLParserResolveExternalEntitiesNever;
    if(![parser parse]||!reader.root){if(error)*error=reader.exceededLimit?[NSError errorWithDomain:@"CCTVHostMacCMS" code:2 userInfo:@{NSLocalizedDescriptionKey:@"MacCMS XML 节点或文本超过安全上限"}]:(parser.parserError?:[NSError errorWithDomain:@"CCTVHostMacCMS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"MacCMS XML 内容无法解析"}]);return nil;}
    MediaCMSXMLNode *rss=[reader.root.name isEqual:@"rss"]?reader.root:MediaCMSChild(reader.root,@"rss");if(!rss){if(error)*error=[NSError errorWithDomain:@"CCTVHostMacCMS" code:3 userInfo:@{NSLocalizedDescriptionKey:@"XML 可以解析，但根节点不是 MacCMS rss 格式"}];return nil;}
    MediaCMSXMLNode *list=MediaCMSChild(rss,@"list");NSMutableDictionary *result=[NSMutableDictionary dictionary];NSMutableArray *items=[NSMutableArray array];
    for(MediaCMSXMLNode *child in list.children)if([child.name isEqual:@"video"])[items addObject:MediaCMSVideo(child)];
    result[@"list"]=items;
    NSDictionary *attrs=list.attributes?:@{};if(attrs[@"page"] )result[@"page"]=attrs[@"page"];if(attrs[@"pagecount"])result[@"pagecount"]=attrs[@"pagecount"];if(attrs[@"pagesize"])result[@"limit"]=attrs[@"pagesize"];if(attrs[@"recordcount"])result[@"total"]=attrs[@"recordcount"];
    MediaCMSXMLNode *classNode=MediaCMSChild(rss,@"class");NSMutableArray *categories=[NSMutableArray array];
    for(MediaCMSXMLNode *child in classNode.children){NSString *identifier=child.attributes[@"type_id"]?:child.attributes[@"id"]?:child.attributes[@"tid"];NSString *name=child.attributes[@"type_name"]?:child.attributes[@"name"]?:MediaCMSText(child);if(identifier.length&&name.length)[categories addObject:@{@"type_id":identifier,@"type_name":name}];}
    if(categories.count)result[@"class"]=categories;
    NSString *message=MediaCMSText(MediaCMSChild(rss,@"msg"));if(message.length)result[@"msg"]=message;
    if(!list&&!categories.count&&!message.length){if(error)*error=[NSError errorWithDomain:@"CCTVHostMacCMS" code:4 userInfo:@{NSLocalizedDescriptionKey:@"MacCMS XML 中没有可识别的 list 或 class 节点"}];return nil;}
    return result;
}

static NSString *MediaTVBoxString(id value) {
    if([value isKindOfClass:NSString.class])return value;
    if([value isKindOfClass:NSNumber.class])return [value stringValue];
    return @"";
}
static NSDictionary *MediaTVBoxObject(id value) {return [value isKindOfClass:NSDictionary.class]?value:@{};}
static NSArray *MediaTVBoxArray(id value) {return [value isKindOfClass:NSArray.class]?value:@[];}
static NSString *MediaTVBoxFirstString(NSDictionary *row,NSArray<NSString *> *keys) {
    for(NSString *key in keys){NSString *value=MediaTVBoxString(row[key]);if(value.length)return value;}return @"";
}
static BOOL MediaTVBoxQueryNameLooksSigned(NSString *rawName) {
    NSString *name=rawName.lowercaseString?:@"";
    NSString *compact=[[name stringByReplacingOccurrencesOfString:@"_" withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if([name hasPrefix:@"x-amz-"]||[name hasPrefix:@"x-oss-"])return YES;
    for(NSString *marker in @[@"token",@"sign",@"auth",@"ticket",@"secret",@"credential",@"policy",@"expires",@"expire",@"deadline",@"hdnea"])
        if([compact containsString:marker])return YES;
    return [compact hasSuffix:@"key"]||[@[@"key",@"keyid",@"apikey",@"hash",@"st",@"e"] containsObject:compact];
}
static BOOL MediaTVBoxURLLooksLikeWebPage(NSString *value) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value?:@""];NSString *extension=parts.path.pathExtension.lowercaseString?:@"";
    static NSSet<NSString *> *webExtensions,*directExtensions;static dispatch_once_t once;dispatch_once(&once,^{webExtensions=[NSSet setWithArray:@[@"html",@"htm",@"xhtml",@"php",@"asp",@"aspx",@"jsp",@"shtml"]];directExtensions=[NSSet setWithArray:@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3",@"ts"]];});
    if([webExtensions containsObject:extension])return YES;
    if([directExtensions containsObject:extension])return NO;
    for(NSURLQueryItem *item in parts.queryItems?:@[])if(MediaTVBoxQueryNameLooksSigned(item.name))return NO;
    // Retain the legacy web handoff for unknown URLs without signed-media hints.
    return YES;
}
static BOOL MediaTVBoxHeaderAllowed(NSString *name,NSString *value) {
    if(!name.length||name.length>128||value.length>4096)return NO;
    NSCharacterSet *controls=NSCharacterSet.controlCharacterSet;
    if([name rangeOfCharacterFromSet:controls].location!=NSNotFound||[value rangeOfCharacterFromSet:controls].location!=NSNotFound)return NO;
    static NSSet<NSString *> *reserved;static dispatch_once_t once;dispatch_once(&once,^{reserved=[NSSet setWithArray:@[@"host",@"content-length",@"transfer-encoding",@"connection",@"proxy-authorization",@"proxy-authenticate"]];});
    return ![reserved containsObject:name.lowercaseString];
}
static NSDictionary *MediaTVBoxPlaybackHeaders(NSDictionary *source,NSDictionary *response) {
    NSMutableDictionary *headers=[NSMutableDictionary dictionary];
    for(NSDictionary *input in @[([source[@"header"] isKindOfClass:NSDictionary.class]?source[@"header"]:@{}),
                                 ([response[@"header"] isKindOfClass:NSDictionary.class]?response[@"header"]:@{}),
                                 ([response[@"headers"] isKindOfClass:NSDictionary.class]?response[@"headers"]:@{})]) {
        NSUInteger count=0;for(id rawKey in input){if(count++>=24)break;id rawValue=input[rawKey];if(![rawKey isKindOfClass:NSString.class]||![rawValue isKindOfClass:NSString.class])continue;NSString *key=rawKey,*value=rawValue;if(!MediaTVBoxHeaderAllowed(key,value))continue;headers[key]=value;}
    }
    id serialized=response[@"header"]?:response[@"headers"];
    if([serialized isKindOfClass:NSString.class]&&[serialized length]<=65536){
        NSString *text=serialized;NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];id decoded=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if([decoded isKindOfClass:NSDictionary.class]){NSUInteger count=0;for(id rawKey in decoded){if(count++>=24)break;id rawValue=decoded[rawKey];if(![rawKey isKindOfClass:NSString.class]||![rawValue isKindOfClass:NSString.class])continue;NSString *key=rawKey,*value=rawValue;if(MediaTVBoxHeaderAllowed(key,value))headers[key]=value;}}
        else {NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@"\r\n#"];NSUInteger count=0;for(NSString *part in [text componentsSeparatedByCharactersInSet:separators]){if(count++>=24)break;NSRange split=[part rangeOfString:@"$"];if(split.location==NSNotFound)split=[part rangeOfString:@":"];if(split.location==NSNotFound)continue;NSString *key=[[part substringToIndex:split.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*value=[[part substringFromIndex:NSMaxRange(split)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(MediaTVBoxHeaderAllowed(key,value))headers[key]=value;}}
    }
    NSString *ua=MediaTVBoxFirstString(response,@[@"UA",@"ua"]);if(ua.length&&MediaTVBoxHeaderAllowed(@"User-Agent",ua))headers[@"User-Agent"]=ua;
    return headers;
}
static NSString *MediaTVBoxResolvedPoster(NSString *value,NSDictionary *source);
static NSSet<NSString *> *MediaTVBoxReservedFilterKeys(void) {
    static NSSet<NSString *> *keys;static dispatch_once_t once;dispatch_once(&once,^{keys=[NSSet setWithArray:@[@"ac",@"t",@"pg",@"ids",@"play",@"flag",@"wd",@"quick",@"filter",@"extend",@"token",@"api_key",@"apikey"]];});return keys;
}
static NSDictionary *MediaTVBoxItem(id value,NSDictionary *source) {
    NSDictionary *row=MediaTVBoxObject(value);NSString *identifier=MediaTVBoxFirstString(row,@[@"vod_id",@"id",@"idStr",@"key"]);
    NSString *name=MediaTVBoxFirstString(row,@[@"vod_name",@"name",@"title",@"vod_title"]);
    if(!identifier.length||!name.length)return nil;
    NSMutableDictionary *item=[@{@"id":identifier,@"name":name} mutableCopy];
    NSDictionary *mapping=@{@"poster":@[@"vod_pic",@"pic",@"poster",@"cover"],@"remarks":@[@"vod_remarks",@"remarks",@"note"],@"year":@[@"vod_year",@"year"],@"area":@[@"vod_area",@"area"],@"lang":@[@"vod_lang",@"lang"],@"type":@[@"type_name",@"vod_class",@"type"],@"actor":@[@"vod_actor",@"actor"],@"director":@[@"vod_director",@"director"],@"description":@[@"vod_content",@"content",@"description"]};
    [mapping enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSArray *aliases,BOOL *stop){NSString *text=MediaTVBoxFirstString(row,aliases);if(text.length)item[key]=[key isEqual:@"poster"]?MediaTVBoxResolvedPoster(text,source):text;}];
    return item;
}
static NSString *MediaTVBoxResolvedPoster(NSString *value,NSDictionary *source) {
    if(!value.length||value.length>8192)return @"";NSURLComponents *candidate=[NSURLComponents componentsWithString:value];
    if([@[@"http",@"https"] containsObject:candidate.scheme.lowercaseString]&&candidate.host.length&&!candidate.user.length&&!candidate.password.length)return value;
    NSURLComponents *api=[NSURLComponents componentsWithString:MediaTVBoxString(source[@"api"])];if(!api.host.length||![@[@"http",@"https"] containsObject:api.scheme.lowercaseString])return value;
    NSURL *base=api.URL;if(![api.path hasSuffix:@"/"])base=[base URLByDeletingLastPathComponent];NSURL *resolved=[NSURL URLWithString:value relativeToURL:base].absoluteURL;NSURLComponents *parts=[NSURLComponents componentsWithURL:resolved resolvingAgainstBaseURL:NO];
    if(![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length||resolved.absoluteString.length>8192)return value;return resolved.absoluteString;
}
static BOOL MediaTVBoxEpisodeAddressIsRelativeURL(NSString *value) {
    if(!value.length)return NO;
    NSString *lower=value.lowercaseString;
    if([lower hasPrefix:@"/"]||[lower hasPrefix:@"./"]||[lower hasPrefix:@"../"]||[lower hasPrefix:@"//"])return YES;
    NSString *extension=[NSURL URLWithString:value].pathExtension.lowercaseString;
    static NSSet<NSString *> *extensions;static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{extensions=[NSSet setWithArray:@[@"m3u8",@"mp4",@"m4v",@"mov",@"ts",@"flv",@"mpd",@"mp3",@"m4a"]];});
    return [extensions containsObject:extension];
}
static NSArray<NSDictionary *> *MediaTVBoxCategories(NSDictionary *root) {
    NSArray *raw=MediaTVBoxArray(root[@"class"]?:root[@"categories"]);NSMutableArray *categories=[NSMutableArray array];
    for(id value in raw){NSDictionary *row=MediaTVBoxObject(value);NSString *identifier=MediaTVBoxFirstString(row,@[@"type_id",@"id",@"tid"]),*name=MediaTVBoxFirstString(row,@[@"type_name",@"name",@"title"]);if(identifier.length&&name.length)[categories addObject:@{@"id":identifier,@"name":name}];}
    return categories;
}
static NSDictionary *MediaTVBoxFilters(NSDictionary *root) {
    id raw=root[@"filters"]?:root[@"filter"];
    if(![raw isKindOfClass:NSDictionary.class])return @{};
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    [(NSDictionary *)raw enumerateKeysAndObjectsUsingBlock:^(id category,id groups,BOOL *stop){
        if(![category isKindOfClass:NSString.class]||![(NSString *)category length]||![groups isKindOfClass:NSArray.class])return;
        NSMutableArray *clean=[NSMutableArray array];
        for(id candidate in groups){if(![candidate isKindOfClass:NSDictionary.class])continue;NSDictionary *group=candidate;NSString *key=MediaTVBoxFirstString(group,@[@"key",@"name"]),*name=MediaTVBoxFirstString(group,@[@"name",@"key"]);if(!key.length)continue;
            NSMutableArray *options=[NSMutableArray array];for(id rawOption in MediaTVBoxArray(group[@"value"]?:group[@"values"])){if(![rawOption isKindOfClass:NSDictionary.class])continue;NSDictionary *option=rawOption;id value=option[@"v"]?:option[@"value"];if(![value isKindOfClass:NSString.class]&&![value isKindOfClass:NSNumber.class])continue;NSString *title=MediaTVBoxFirstString(option,@[@"n",@"name"]);[options addObject:@{@"n":title.length?title:[value description],@"v":value}];}
            if(options.count)[clean addObject:@{@"key":key,@"name":name.length?name:key,@"value":options}];
        }
        if(clean.count)result[category]=clean;
    }];
    return result;
}
static NSArray<NSDictionary *> *MediaTVBoxEpisodes(NSString *playList,NSString *flag,NSDictionary *source) {
    NSMutableArray *episodes=[NSMutableArray array];NSUInteger index=0;
    for(NSString *entry in [playList componentsSeparatedByString:@"#"]){if(!entry.length)continue;NSRange split=[entry rangeOfString:@"$"];NSString *name=nil,*address=nil;if(split.location==NSNotFound||[[entry substringToIndex:split.location] containsString:@"://"]){name=[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];address=entry;}else{name=[entry substringToIndex:split.location];address=[entry substringFromIndex:split.location+1];}
        name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];address=[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!address.length)continue;NSURLComponents *parts=[NSURLComponents componentsWithString:address];BOOL absoluteURL=[@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length;if(!absoluteURL&&MediaTVBoxEpisodeAddressIsRelativeURL(address))address=MediaTVBoxResolvedPoster(address,source);
        [episodes addObject:@{@"id":address,@"name":name.length?name:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1],@"lineId":flag?:@""}];index++;
    }
    return episodes;
}
static NSDictionary *MediaTVBoxDetail(NSDictionary *root,NSDictionary *arguments,NSDictionary *source) {
    id raw=MediaTVBoxArray(root[@"list"]).firstObject?:root[@"data"];NSDictionary *row=MediaTVBoxObject(raw);NSMutableDictionary *item=[(MediaTVBoxItem(row,source)?:@{@"name":@"影片详情"}) mutableCopy];if(![item[@"id"] length])item[@"id"]=MediaTVBoxString(arguments[@"id"]);
    NSString *playFrom=MediaTVBoxFirstString(row,@[@"vod_play_from",@"play_from"]),*playURL=MediaTVBoxFirstString(row,@[@"vod_play_url",@"play_url"]);
    NSArray *names=playFrom.length?[playFrom componentsSeparatedByString:@"$$$"]:@[];NSArray *groups=playURL.length?[playURL componentsSeparatedByString:@"$$$"]:@[];
    NSMutableArray *lines=[NSMutableArray array];for(NSUInteger i=0;i<groups.count;i++){NSString *flag=i<names.count?names[i]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)i+1];NSArray *episodes=MediaTVBoxEpisodes(groups[i],flag,source);if(!episodes.count)continue;[lines addObject:@{@"id":flag,@"name":flag,@"episodes":episodes}];}
    NSMutableDictionary *detail=[item mutableCopy];detail[@"lines"]=lines;NSString *banner=MediaTVBoxFirstString(row,@[@"vod_pic_slide",@"banner"]);if(banner.length)detail[@"banner"]=banner;return detail;
}
static id MediaTVBoxNormalize(NSString *operation,NSDictionary *arguments,NSDictionary *source,id raw) {
    NSDictionary *root=MediaTVBoxObject(raw);if([root[@"data"] isKindOfClass:NSDictionary.class]&&![root[@"list"] isKindOfClass:NSArray.class])root=root[@"data"];
    if([root[@"list"] isKindOfClass:NSDictionary.class]){NSMutableDictionary *copy=[root mutableCopy];copy[@"list"]=@[root[@"list"]];root=copy;}
    if(![root[@"list"] isKindOfClass:NSArray.class]&&[root[@"data"] isKindOfClass:NSArray.class]){NSMutableDictionary *copy=[root mutableCopy];copy[@"list"]=root[@"data"];root=copy;}
    if([root[@"class"] isKindOfClass:NSDictionary.class]){NSMutableDictionary *copy=[root mutableCopy];copy[@"class"]=@[root[@"class"]];root=copy;}
    BOOL macCMS=[source[@"protocol"] isEqual:@"maccms-api"];
    if(macCMS&&[@[@"home",@"category",@"search",@"detail"] containsObject:operation]&&![root[@"list"] isKindOfClass:NSArray.class]&&![root[@"class"] isKindOfClass:NSArray.class]){NSString *message=MediaTVBoxFirstString(root,@[@"msg",@"message",@"errMsg"]);return @{@"error":message.length?message:@"MacCMS JSON 已返回，但没有识别到 list 或 class 数据"};}
    if([operation isEqual:@"capabilities"])return @{@"engine":macCMS?@"MacCMS JSON/XML API":@"TVBox JSON API",@"protocol":source[@"protocol"]?:@"tvbox-api",@"capabilities":@[@"home",@"category",@"search",@"detail",@"play"]};
    if([operation isEqual:@"providers"])return @[@{@"id":@"",@"name":source[@"name"]?: (macCMS?@"MacCMS 站点":@"TVBox 站点")}];
    if([operation isEqual:@"home"]){NSMutableArray *items=[NSMutableArray array];for(id row in MediaTVBoxArray(root[@"list"])) {NSDictionary *item=MediaTVBoxItem(row,source);if(item)[items addObject:item];}NSInteger pageCount=[root[@"pagecount"] integerValue];if(pageCount<1)pageCount=[root[@"pageCount"] integerValue];NSInteger page=MAX(1,[root[@"page"] integerValue]);return @{@"categories":MediaTVBoxCategories(root),@"items":items,@"filters":MediaTVBoxFilters(root),@"hasMore":@(pageCount>page),@"page":@(page),@"pageCount":@(pageCount)};}
    if([operation isEqual:@"category"]||[operation isEqual:@"search"]){NSMutableArray *items=[NSMutableArray array];for(id row in MediaTVBoxArray(root[@"list"])) {NSDictionary *item=MediaTVBoxItem(row,source);if(item)[items addObject:item];}NSInteger page=MAX(1,[arguments[@"page"] integerValue]);NSInteger pageCount=[root[@"pagecount"] integerValue];if(pageCount<1)pageCount=[root[@"pageCount"] integerValue];if(pageCount<1){NSInteger total=[root[@"total"] integerValue],limit=[root[@"limit"] integerValue];if(total>0&&limit>0)pageCount=(total+limit-1)/limit;}if(pageCount<1)pageCount=page;return @{@"items":items,@"hasMore":@(page<pageCount),@"page":@(page),@"pageCount":@(pageCount)};}
    if([operation isEqual:@"detail"])return MediaTVBoxDetail(root,arguments,source);
    if([operation isEqual:@"play"]){
        NSDictionary *headers=MediaTVBoxPlaybackHeaders(source,root);
        if(macCMS){NSString *url=MediaTVBoxString(arguments[@"id"]);BOOL webPage=MediaTVBoxURLLooksLikeWebPage(url);if(!url.length)return @{@"error":@"MacCMS 分集没有播放地址"};/* Signed and extensionless media endpoints should be tried by AVPlayer; only explicit page endpoints use the web player by default. */return @{@"url":url,@"originalURL":url,@"parse":@(webPage),@"jx":@0,@"requiresWebPlayback":@(webPage),@"headers":headers};}
        if([source[@"tvboxType"] integerValue]==1){NSString *url=MediaTVBoxString(arguments[@"id"]);NSString *prefix=MediaTVBoxString(source[@"playUrl"]);if(!url.length)return @{@"error":@"TVBox type 1 没有返回分集地址"};return @{@"url":[prefix stringByAppendingString:url],@"parse":@(prefix.length>0),@"headers":headers};}
        id rawURL=root[@"url"];NSString *prefix=MediaTVBoxFirstString(root,@[@"playUrl"]);
        NSMutableArray<NSDictionary *> *alternates=[NSMutableArray array];NSString *url=@"";
        if([rawURL isKindOfClass:NSString.class]){url=[prefix stringByAppendingString:[rawURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];}
        else if([rawURL isKindOfClass:NSArray.class]){NSArray *values=rawURL;
            if(values.count&&[values.firstObject isKindOfClass:NSDictionary.class]){
                NSUInteger count=MIN(values.count,32);for(NSUInteger index=0;index<count;index++){NSDictionary *choice=MediaTVBoxObject(values[index]);NSString *name=MediaTVBoxFirstString(choice,@[@"name",@"n",@"quality"]),*address=MediaTVBoxFirstString(choice,@[@"url",@"value",@"v"]);address=[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!address.length)continue;NSMutableDictionary *alternate=[@{@"name":name.length?name:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)index+1],@"url":[prefix stringByAppendingString:address]} mutableCopy];NSMutableDictionary *choiceHeaders=[headers mutableCopy];[choiceHeaders addEntriesFromDictionary:MediaTVBoxPlaybackHeaders(@{},choice)];if(choiceHeaders.count)alternate[@"headers"]=choiceHeaders;[alternates addObject:alternate];}
            }else{NSUInteger count=MIN(values.count-(values.count%2),32);for(NSUInteger index=0;index<count;index+=2){NSString *name=MediaTVBoxString(values[index]),*address=MediaTVBoxString(values[index+1]);address=[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!address.length)continue;NSMutableDictionary *alternate=[@{@"name":name.length?name:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)(index/2+1)],@"url":[prefix stringByAppendingString:address]} mutableCopy];if(headers.count)alternate[@"headers"]=headers;[alternates addObject:alternate];}}
            url=alternates.firstObject[@"url"]?:@"";}
        if(!url.length){NSString *message=MediaTVBoxFirstString(root,@[@"msg",@"message",@"errMsg"]);return @{ @"error":message.length?message:@"TVBox API 没有返回播放地址" };}
        NSInteger parse=[root[@"parse"] respondsToSelector:@selector(integerValue)]?[root[@"parse"] integerValue]:0,jx=[root[@"jx"] respondsToSelector:@selector(integerValue)]?[root[@"jx"] integerValue]:0;
        NSMutableDictionary *result=[@{@"url":url,@"parse":@(parse),@"jx":@(jx),@"playUrl":prefix,@"requiresWebPlayback":@((parse>0||jx>0||prefix.length>0)&&![@[@"m3u8",@"mp4",@"m4v",@"mov",@"m4a",@"mp3"] containsObject:[NSURL URLWithString:url].pathExtension.lowercaseString?:@""]),@"headers":headers} mutableCopy];if(alternates.count>1)result[@"alternates"]=alternates;
        return result;
    }
    return root;
}

@interface MediaAPIRequestContext : NSObject
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic,copy) void (^processor)(NSData *,NSURLResponse *,NSError *);
@end
@implementation MediaAPIRequestContext @end

@interface MediaAPIClient () <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSOperationQueue *delegateQueue;
@property(nonatomic,strong) NSLock *contextLock;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,MediaAPIRequestContext *> *requestContexts;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger port;
@property(nonatomic, copy) NSString *activeRequestID;
@property(nonatomic, copy) NSString *activeCorrelationID;
@property(nonatomic, copy) NSString *activeOperation;
@property(nonatomic, copy) NSDictionary *tvboxSource;
- (void)cancelWithReason:(NSString *)reason;
@end

@implementation MediaAPIClient
- (instancetype)initWithPort:(NSInteger)port {
    return [self initWithPort:port requestTimeout:40];
}
- (instancetype)initWithPort:(NSInteger)port requestTimeout:(NSTimeInterval)requestTimeout {
    if((self=[super init])){
        _port=port;
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        NSTimeInterval timeout=MIN(40,MAX(5,requestTimeout));
        configuration.timeoutIntervalForRequest=timeout;
        configuration.timeoutIntervalForResource=timeout+5;
        configuration.URLCache=nil;
        configuration.HTTPMaximumConnectionsPerHost=2;
        _delegateQueue=[NSOperationQueue new];_delegateQueue.name=@"com.cctvhost.media-api";_delegateQueue.maxConcurrentOperationCount=1;
        _contextLock=[NSLock new];_requestContexts=[NSMutableDictionary dictionary];
        _session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
    }
    return self;
}
- (instancetype)initWithTVBoxSource:(NSDictionary *)source {
    if((self=[self initWithPort:0 requestTimeout:20]))_tvboxSource=[source copy];
    return self;
}
- (void)cancelWithReason:(NSString *)reason {
    if(self.task && self.activeRequestID.length){
        NSMutableDictionary *fields=[@{@"request_id":self.activeRequestID,
                                        @"operation":self.activeOperation?:@"unknown",
                                        @"port":@(self.port),
                                        @"reason":reason?:@"caller_cancelled"} mutableCopy];
        if(self.activeCorrelationID.length)fields[@"correlation_id"]=self.activeCorrelationID;
        [RuntimeDiagnostics.shared recordEvent:@"media_api_cancelled" category:@"media_api" fields:fields];
    }
    self.generation++;
    if(self.task){[self.contextLock lock];[self.requestContexts removeObjectForKey:@(self.task.taskIdentifier)];[self.contextLock unlock];}
    [self.task cancel];
    self.task=nil;
    self.activeRequestID=nil;
    self.activeCorrelationID=nil;
    self.activeOperation=nil;
}
- (void)cancel { [self cancelWithReason:@"caller_cancelled"]; }
- (void)dealloc {
    [self.task cancel];
    [self.session invalidateAndCancel];
}
- (NSURLRequest *)tvboxRequestForOperation:(NSString *)operation arguments:(NSDictionary *)arguments error:(NSError **)error {
    NSString *api=MediaTVBoxString(self.tvboxSource[@"api"]);NSURLComponents *parts=[NSURLComponents componentsWithString:api];
    if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length||api.length>8192){if(error)*error=[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:1 userInfo:@{NSLocalizedDescriptionKey:@"TVBox API 地址无效"}];return nil;}
    BOOL macCMS=[self.tvboxSource[@"protocol"] isEqual:@"maccms-api"];
    NSInteger type=[self.tvboxSource[@"tvboxType"] integerValue];NSMutableDictionary<NSString *,NSString *> *values=[NSMutableDictionary dictionary];
    if([operation isEqual:@"home"]){if(!macCMS&&type==4)values[@"filter"]=@"true";if(macCMS)values[@"ac"]=@"videolist";}
    else if([operation isEqual:@"search"]){values[@"wd"]=MediaTVBoxString(arguments[@"keyword"]);if(!macCMS)values[@"quick"]=@"false";values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];if(macCMS)values[@"ac"]=@"videolist";}
    else if([operation isEqual:@"category"]){values[@"ac"]=macCMS?@"videolist":@"detail";values[@"t"]=MediaTVBoxString(arguments[@"categoryId"]);values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];NSDictionary *filters=[arguments[@"filters"] isKindOfClass:NSDictionary.class]?arguments[@"filters"]:@{};for(id key in filters){id value=filters[key];if([key isKindOfClass:NSString.class]&&[key length]<=128&&![MediaTVBoxReservedFilterKeys() containsObject:[key lowercaseString]]&&([value isKindOfClass:NSString.class]||[value isKindOfClass:NSNumber.class])&&[value description].length<=512)values[key]=[value description];}}
    else if([operation isEqual:@"detail"]){values[@"ac"]=@"detail";values[@"ids"]=MediaTVBoxString(arguments[@"id"]);}
    else if([operation isEqual:@"play"]){values[@"play"]=MediaTVBoxString(arguments[@"id"]);values[@"flag"]=MediaTVBoxString(arguments[@"lineId"]);}
    NSString *extend=MediaTVBoxString(self.tvboxSource[@"options"]);if(extend.length)values[@"extend"]=extend;
    NSMutableArray *query=[NSMutableArray array];for(NSURLQueryItem *item in parts.queryItems?:@[])if(!values[item.name])[query addObject:item];for(NSString *key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)])[query addObject:[NSURLQueryItem queryItemWithName:key value:values[key]?:@""]];parts.queryItems=query;
    NSURL *url=parts.URL;if(!url||url.absoluteString.length>16384){if(error)*error=[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:2 userInfo:@{NSLocalizedDescriptionKey:@"TVBox API 请求地址无效或过长"}];return nil;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];request.HTTPMethod=@"GET";
    NSDictionary *headers=[self.tvboxSource[@"header"] isKindOfClass:NSDictionary.class]?self.tvboxSource[@"header"]:@{};NSUInteger count=0;for(id rawKey in headers){if(count++>=24)break;if(![rawKey isKindOfClass:NSString.class]||![headers[rawKey] isKindOfClass:NSString.class])continue;NSString *key=rawKey,*value=headers[key];if(!MediaTVBoxHeaderAllowed(key,value))continue;[request setValue:value forHTTPHeaderField:key];}
    [request setValue:macCMS?@"application/json, application/xml, text/xml, */*":@"application/json, */*" forHTTPHeaderField:@"Accept"];return request;
}
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id,NSError *))completion {
    [self call:operation arguments:arguments correlationID:nil completion:completion];
}
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion {
    NSAssert(NSThread.isMainThread,@"Media client UI operations run on main thread");
    [self cancelWithReason:@"superseded_by_new_request"];
    NSUInteger generation=self.generation;
    NSTimeInterval startedAt=CACurrentMediaTime();
    BOOL diagnosticsEnabled=RuntimeDiagnostics.shared.enabled;
    NSString *requestID=NSUUID.UUID.UUIDString.lowercaseString;
    self.activeRequestID=diagnosticsEnabled?requestID:nil;
    self.activeCorrelationID=diagnosticsEnabled&&correlationID.length?[correlationID copy]:nil;
    self.activeOperation=diagnosticsEnabled?([operation copy]?:@"unknown"):nil;
    if(diagnosticsEnabled){
    NSMutableDictionary *startFields=[@{@"request_id":requestID,
                                          @"operation":self.activeOperation,
                                          @"port":@(self.port),
                                          @"argument_count":@([arguments isKindOfClass:NSDictionary.class]?arguments.count:0)} mutableCopy];
    if(correlationID.length)startFields[@"correlation_id"]=correlationID;
    [RuntimeDiagnostics.shared recordEvent:@"media_api_started" category:@"media_api" fields:startFields];
    }

    BOOL macCMS=[self.tvboxSource[@"protocol"] isEqual:@"maccms-api"];
    BOOL localDirectPlay=[operation isEqual:@"play"]&&(macCMS||[self.tvboxSource[@"tvboxType"] integerValue]==1);
    BOOL localTVBoxOperation=self.tvboxSource&&([operation isEqual:@"capabilities"]||[operation isEqual:@"providers"]||localDirectPlay);
    if(localTVBoxOperation){
        id direct=MediaTVBoxNormalize(operation,arguments?:@{},self.tvboxSource,@{});
        NSDictionary *directDictionary=[direct isKindOfClass:NSDictionary.class]?direct:nil;
        NSString *directMessage=[directDictionary[@"error"] isKindOfClass:NSString.class]?directDictionary[@"error"]:nil;
        NSError *directError=directMessage.length?[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:3 userInfo:@{NSLocalizedDescriptionKey:directMessage}]:nil;
        NSString *resultType=direct?NSStringFromClass([direct class]):@"none";
        if(diagnosticsEnabled){NSMutableDictionary *fields=[@{@"request_id":requestID,@"operation":operation?:@"unknown",@"port":@(self.port),@"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-startedAt)*1000)),@"http_status":@0,@"result_type":resultType,@"result_shape":resultType,@"result_has_media_url":@([directDictionary[@"url"] isKindOfClass:NSString.class]&&[directDictionary[@"url"] length]>0),@"failure_stage":directError?@"direct_url_missing":@"none",@"protocol":self.tvboxSource[@"protocol"]?:@"tvbox-api",@"error_domain":directError.domain?:@"",@"error_code":@(directError.code)} mutableCopy];if(correlationID.length)fields[@"correlation_id"]=correlationID;[RuntimeDiagnostics.shared recordEvent:directError?@"media_api_failed":@"media_api_succeeded" category:@"media_api" fields:fields];}
        self.activeRequestID=nil;self.activeCorrelationID=nil;self.activeOperation=nil;
        dispatch_async(dispatch_get_main_queue(),^{if(self.generation==generation&&completion)completion(directError?nil:direct,directError);});
        return;
    }

    NSError *requestError=nil;NSURL *url=nil;NSMutableURLRequest *request=nil;
    if(self.tvboxSource){request=[[self tvboxRequestForOperation:operation arguments:arguments?:@{} error:&requestError] mutableCopy];url=request.URL;}
    else{url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/api/v1/%@",(long)self.port,operation]];request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"POST";request.HTTPBody=[NSJSONSerialization dataWithJSONObject:arguments?:@{} options:0 error:NULL];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];[request setValue:requestID forHTTPHeaderField:@"X-CCTVHost-Request-ID"];if(correlationID.length)[request setValue:correlationID forHTTPHeaderField:@"X-CCTVHost-Correlation-ID"];}
    if(!request){NSError *failure=requestError?:[NSError errorWithDomain:@"CCTVHostMedia" code:5 userInfo:@{NSLocalizedDescriptionKey:@"无法创建资源请求"}];if(diagnosticsEnabled){NSMutableDictionary *fields=[@{@"request_id":requestID,@"operation":operation?:@"unknown",@"protocol":self.tvboxSource[@"protocol"]?:@"plugin",@"failure_stage":@"invalid_request",@"error_domain":failure.domain?:@"",@"error_code":@(failure.code),@"error_message":failure.localizedDescription?:@""} mutableCopy];if(correlationID.length)fields[@"correlation_id"]=correlationID;[RuntimeDiagnostics.shared recordEvent:@"media_api_failed" category:@"media_api" fields:fields];}self.activeRequestID=nil;self.activeCorrelationID=nil;self.activeOperation=nil;if(completion)completion(nil,failure);return;}
    __weak typeof(self) weakSelf=self;
    void (^processor)(NSData *,NSURLResponse *,NSError *)=^(NSData *data,NSURLResponse *response,NSError *networkError){
        NSError *failure=networkError;
        id reply=nil;
        NSError *jsonError=nil;
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        NSString *pluginCode=@"";
        NSString *pluginMessage=@"";
        BOOL pluginRetryable=NO;
        NSString *failureStage=failure?@"network_or_timeout":@"none";
        if(!failure && data.length>2*1024*1024){
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源服务响应超过 2 MiB"}];
            failureStage=@"response_too_large";
        } else if(!failure && !data.length){
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:4 userInfo:@{NSLocalizedDescriptionKey:@"资源服务返回空响应"}];
            failureStage=@"empty_response";
        } else if(!failure){
            reply=[NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if(jsonError&&self.tvboxSource&&[self.tvboxSource[@"protocol"] isEqual:@"maccms-api"]){jsonError=nil;reply=MediaCMSXMLObject(data,&jsonError);if(!reply&&jsonError){failure=jsonError;failureStage=@"invalid_xml";}}
            else if(jsonError){failure=jsonError;failureStage=@"invalid_json";}
        }
        NSDictionary *errorPayload=[reply isKindOfClass:NSDictionary.class]&&[reply[@"error"] isKindOfClass:NSDictionary.class]?reply[@"error"]:@{};
        if([errorPayload[@"code"] isKindOfClass:NSString.class])pluginCode=errorPayload[@"code"];
        if([errorPayload[@"message"] isKindOfClass:NSString.class])pluginMessage=errorPayload[@"message"];
        pluginRetryable=[errorPayload[@"retryable"] isKindOfClass:NSNumber.class]?[errorPayload[@"retryable"] boolValue]:NO;
        if(!networkError && (status<200||status>=300)){
            NSMutableDictionary *httpInfo=[@{NSLocalizedDescriptionKey:pluginMessage.length?pluginMessage:[NSString stringWithFormat:@"资源服务返回 HTTP %ld",(long)status],@"plugin_retryable":@(pluginRetryable)} mutableCopy];
            if(pluginCode.length)httpInfo[@"plugin_error_code"]=pluginCode;
            if([errorPayload[@"request_id"] isKindOfClass:NSString.class])httpInfo[@"service_request_id"]=errorPayload[@"request_id"];
            if([errorPayload[@"stage"] isKindOfClass:NSString.class])httpInfo[@"service_failure_stage"]=errorPayload[@"stage"];
            failure=[NSError errorWithDomain:@"CCTVHostMediaHTTP" code:status userInfo:httpInfo];
            failureStage=@"http_status";
        }
        BOOL responseOK=[reply isKindOfClass:NSDictionary.class]&&[reply[@"ok"] isKindOfClass:NSNumber.class]&&[reply[@"ok"] boolValue];
        if(!failure && self.tvboxSource && [reply isKindOfClass:NSDictionary.class]){
            NSDictionary *rootPayload=MediaTVBoxObject(reply);NSDictionary *payload=([rootPayload[@"data"] isKindOfClass:NSDictionary.class]&&![rootPayload[@"list"] isKindOfClass:NSArray.class])?rootPayload[@"data"]:rootPayload;NSInteger apiCode=[rootPayload[@"code"] integerValue];NSString *apiMessage=MediaTVBoxFirstString(rootPayload,@[@"msg",@"message",@"errMsg"]);
            BOOL hasUsablePayload=[payload[@"list"] isKindOfClass:NSArray.class]||[payload[@"class"] isKindOfClass:NSArray.class]||([payload[@"data"] isKindOfClass:NSDictionary.class]&&payload[@"data"]!=NSNull.null)||MediaTVBoxString(payload[@"url"]).length>0||MediaTVBoxString(payload[@"playUrl"]).length>0;
            // CMS forks disagree on success codes. Treat code 0 as an error only
            // when an error message is present and the response carries no usable data.
            if(rootPayload[@"code"]&&apiCode==0&&apiMessage.length&&!hasUsablePayload){failure=[NSError errorWithDomain:@"CCTVHostCatalogAPI" code:apiCode userInfo:@{NSLocalizedDescriptionKey:apiMessage}];failureStage=@"catalog_api_error";}
        }
        if(!failure && !self.tvboxSource && !responseOK){
            NSString *message=pluginMessage.length?pluginMessage:@"资源未返回有效结果，请查看插件日志";
            NSMutableDictionary *info=[@{NSLocalizedDescriptionKey:message} mutableCopy];
            if(pluginCode.length)info[@"plugin_error_code"]=pluginCode;
            info[@"plugin_retryable"]=@(pluginRetryable);
            if([errorPayload[@"request_id"] isKindOfClass:NSString.class])info[@"service_request_id"]=errorPayload[@"request_id"];
            if([errorPayload[@"stage"] isKindOfClass:NSString.class])info[@"service_failure_stage"]=errorPayload[@"stage"];
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:2 userInfo:info];
            failureStage=errorPayload.count?@"plugin_error":@"invalid_response_shape";
        }
        id result=self.tvboxSource?MediaTVBoxNormalize(operation,arguments?:@{},self.tvboxSource,reply):([reply isKindOfClass:NSDictionary.class]?reply[@"data"]:nil);
        if(!failure&&[result isKindOfClass:NSDictionary.class]&&[result[@"error"] isKindOfClass:NSString.class]){failure=[NSError errorWithDomain:@"CCTVHostCatalogAPI" code:3 userInfo:@{NSLocalizedDescriptionKey:result[@"error"]}];failureStage=@"catalog_api_error";}
        if(diagnosticsEnabled){
        NSMutableDictionary *fields=[@{@"request_id":requestID,
                                        @"operation":operation?:@"unknown",
                                        @"port":@(self.port),
                                        @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-startedAt)*1000)),
                                        @"http_status":@(status),
                                        @"response_bytes":@(data.length),
                                        @"response_mime_type":response.MIMEType?:@"",
                                        @"result_type":result?NSStringFromClass([result class]):@"none",
                                        @"failure_stage":failureStage,
                                        @"error_domain":failure.domain?:@"",
                                        @"error_code":@(failure.code)} mutableCopy];
        if([result isKindOfClass:NSDictionary.class]){
            fields[@"result_shape"]=@"dictionary";
            fields[@"result_has_media_url"]=@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0);
            fields[@"result_parse_mode"]=@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0);
            fields[@"result_alternate_count"]=@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0);
            NSURL *mediaURL=[result[@"url"] isKindOfClass:NSString.class]?[NSURL URLWithString:result[@"url"]]:nil;
            if(mediaURL){
                fields[@"playback_scheme"]=mediaURL.scheme.lowercaseString?:@"";
                fields[@"playback_host"]=mediaURL.host.lowercaseString?:@"";
                fields[@"playback_port"]=mediaURL.port?:@0;
                fields[@"playback_extension"]=mediaURL.pathExtension.lowercaseString?:@"";
            }
        } else if(result) fields[@"result_shape"]=NSStringFromClass([result class]);
        if(correlationID.length)fields[@"correlation_id"]=correlationID;
        if(pluginCode.length)fields[@"plugin_error_code"]=pluginCode;
        if(pluginMessage.length)fields[@"plugin_error_message"]=pluginMessage;
        if([failure.userInfo[@"service_request_id"] isKindOfClass:NSString.class])fields[@"service_request_id"]=failure.userInfo[@"service_request_id"];
        if([failure.userInfo[@"service_failure_stage"] isKindOfClass:NSString.class])fields[@"service_failure_stage"]=failure.userInfo[@"service_failure_stage"];
        if(errorPayload.count)fields[@"plugin_retryable"]=@(pluginRetryable);
        if(failure.localizedDescription.length)fields[@"error_message"]=failure.localizedDescription;
        if(![failure.domain isEqualToString:NSURLErrorDomain]||failure.code!=NSURLErrorCancelled){
            [RuntimeDiagnostics.shared recordEvent:failure?@"media_api_failed":@"media_api_succeeded" category:@"media_api" fields:fields];
        }
        }
        dispatch_async(dispatch_get_main_queue(),^{
            MediaAPIClient *client=weakSelf;
            if(!client || client.generation!=generation)return;
            client.task=nil;
            client.activeRequestID=nil;
            client.activeCorrelationID=nil;
            client.activeOperation=nil;
            if(completion)completion(result==NSNull.null?nil:result,failure);
        });
    };
    MediaAPIRequestContext *requestContext=[MediaAPIRequestContext new];requestContext.data=[NSMutableData data];requestContext.processor=processor;
    self.task=[self.session dataTaskWithRequest:request];
    [self.contextLock lock];self.requestContexts[@(self.task.taskIdentifier)]=requestContext;[self.contextLock unlock];
    [self.task resume];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(dataTask.taskIdentifier)];if(context)context.response=response;[self.contextLock unlock];
    if(!context){completionHandler(NSURLSessionResponseCancel);return;}
    if(response.expectedContentLength>2*1024*1024){context.failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源服务响应超过 2 MiB"}];completionHandler(NSURLSessionResponseCancel);return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(dataTask.taskIdentifier)];
    if(context&&context.data.length+data.length<=2*1024*1024)[context.data appendData:data];
    else if(context&&!context.failure)context.failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源服务响应超过 2 MiB"}];
    BOOL overLimit=context&&context.failure.code==3;[self.contextLock unlock];if(overLimit)[dataTask cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(task.taskIdentifier)];[self.requestContexts removeObjectForKey:@(task.taskIdentifier)];NSData *data=[context.data copy];NSURLResponse *response=context.response;NSError *failure=context.failure?:error;void(^processor)(NSData *,NSURLResponse *,NSError *)=[context.processor copy];[self.contextLock unlock];
    if(processor)processor(data?:[NSData data],response,failure);
}
@end
