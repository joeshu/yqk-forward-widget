#import "MediaAPIClient.h"
#import "MediaSP360Adapter.h"
#import "MediaPlaybackHeaders.h"
#import "RuntimeDiagnostics.h"
#import "TVBoxCatalogStore.h"
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonCryptor.h>

BOOL MediaSourceUsesNativeCatalogAPI(NSDictionary *source) {
    NSString *protocol=[source[@"protocol"] isKindOfClass:NSString.class]?source[@"protocol"]:@"";
    return [protocol isEqual:@"tvbox-api"]||[protocol isEqual:@"maccms-api"]||[protocol isEqual:@"douban-index"]||[protocol isEqual:@"jar-bridge"];
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
static id MediaSanitizedJSONObjectWithData(NSData *data,NSError **error) {
    if(!data.length)return nil;
    NSError *firstError=nil;
    id object=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&firstError];
    if(object)return object;
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text){
        NSStringEncoding gbk=CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        text=[[NSString alloc] initWithData:data encoding:gbk];
    }
    if(!text){if(error)*error=firstError;return nil;}
    if([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    NSString *trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([trimmed hasPrefix:@"<?xml"]||[trimmed hasPrefix:@"<rss"]){if(error)*error=firstError;return nil;}
    NSRange firstBrace=[trimmed rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"{["]];
    if(firstBrace.location!=NSNotFound&&firstBrace.location>0&&firstBrace.location<2048){
        NSString *prefix=[[trimmed substringToIndex:firstBrace.location] lowercaseString];
        if(![prefix containsString:@"<html"]&&![prefix containsString:@"<!doctype"])trimmed=[trimmed substringFromIndex:firstBrace.location];
    }
    NSMutableString *clean=[NSMutableString stringWithCapacity:trimmed.length];
    for(NSUInteger i=0;i<trimmed.length;i++){
        unichar ch=[trimmed characterAtIndex:i];
        if(ch<0x20&&ch!='\n'&&ch!='\r'&&ch!='\t')continue;
        [clean appendFormat:@"%C",ch];
    }
    NSData *cleanData=[clean dataUsingEncoding:NSUTF8StringEncoding];
    if(!cleanData.length){if(error)*error=firstError;return nil;}
    return [NSJSONSerialization JSONObjectWithData:cleanData options:NSJSONReadingFragmentsAllowed error:error];
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
static BOOL MediaTVBoxURLHasSignedQuery(NSString *value) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value?:@""];
    for(NSURLQueryItem *item in parts.queryItems?:@[])if(MediaTVBoxQueryNameLooksSigned(item.name))return YES;
    return NO;
}
static BOOL MediaTVBoxURLLooksLikeWebPage(NSString *value) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value?:@""];NSString *path=parts.percentEncodedPath?:parts.path?:@"";NSString *lastComponent=path.lastPathComponent?:@"";NSString *extension=lastComponent.pathExtension.lowercaseString?:@"";
    static NSSet<NSString *> *webExtensions;static dispatch_once_t once;dispatch_once(&once,^{webExtensions=[NSSet setWithArray:@[@"html",@"htm",@"xhtml",@"php",@"asp",@"aspx",@"jsp",@"shtml"]];});
    if([webExtensions containsObject:extension])return YES;
    if(MediaPlaybackResultSupportsNativePlayback(@{@"url":value?:@""}))return NO;
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
static BOOL MediaTVBoxHeaderIsSensitive(NSString *name) {
    if(!name.length)return NO;
    NSString *compact=[[[name lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@"_" withString:@""];
    for(NSString *marker in @[@"authorization",@"cookie",@"token",@"apikey",@"secret",@"password",@"credential",@"signature",@"sign",@"session"])if([compact containsString:marker])return YES;
    return [compact hasSuffix:@"key"];
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
    NSArray *raw=MediaTVBoxArray(root[@"class"]?:root[@"categories"]);
    NSMutableSet<NSString *> *parentIDs=[NSMutableSet set];
    for(id value in raw){
        NSDictionary *row=MediaTVBoxObject(value);
        NSString *pid=[MediaTVBoxFirstString(row,@[@"type_pid",@"pid",@"parent_id"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(pid.length&&![pid isEqualToString:@"0"])[parentIDs addObject:pid];
    }
    NSMutableArray *categories=[NSMutableArray array];
    NSMutableArray *allCategories=[NSMutableArray array];
    for(id value in raw){
        NSDictionary *row=MediaTVBoxObject(value);
        NSString *identifier=[MediaTVBoxFirstString(row,@[@"type_id",@"id",@"tid"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *name=[MediaTVBoxFirstString(row,@[@"type_name",@"name",@"title"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!identifier.length||!name.length)continue;
        NSDictionary *entry=@{@"id":identifier,@"name":name};
        [allCategories addObject:entry];
        if(![parentIDs containsObject:identifier])[categories addObject:entry];
    }
    return categories.count?categories:allCategories;
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
    NSCharacterSet *entrySeparators=[NSCharacterSet characterSetWithCharactersInString:@"#\r\n"];
    for(NSString *entry in [playList componentsSeparatedByCharactersInSet:entrySeparators]){if(!entry.length)continue;NSRange split=[entry rangeOfString:@"$"];NSString *name=nil,*address=nil;if(split.location==NSNotFound||[[entry substringToIndex:split.location] containsString:@"://"]){name=[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];address=entry;}else{name=[entry substringToIndex:split.location];address=[entry substringFromIndex:split.location+1];}
        name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];address=[address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        address=[address stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        if([address hasPrefix:@"//"])address=[@"https:" stringByAppendingString:address];
        if(([address hasPrefix:@"http://"]||[address hasPrefix:@"https://"])&&[address containsString:@" "])address=[address stringByReplacingOccurrencesOfString:@" " withString:@"%20"];
        if(!address.length)continue;NSURLComponents *parts=[NSURLComponents componentsWithString:address];BOOL absoluteURL=[@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length;if(!absoluteURL&&MediaTVBoxEpisodeAddressIsRelativeURL(address))address=MediaTVBoxResolvedPoster(address,source);
        [episodes addObject:@{@"id":address,@"name":name.length?name:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1],@"lineId":flag?:@""}];index++;
    }
    return episodes;
}
static NSDictionary *MediaTVBoxDetail(NSDictionary *root,NSDictionary *arguments,NSDictionary *source) {
    id raw=MediaTVBoxArray(root[@"list"]).firstObject?:root[@"data"];NSDictionary *row=MediaTVBoxObject(raw);NSMutableDictionary *item=[(MediaTVBoxItem(row,source)?:@{@"name":@"影片详情"}) mutableCopy];if(![item[@"id"] length])item[@"id"]=MediaTVBoxString(arguments[@"id"]);
    NSString *playFrom=MediaTVBoxFirstString(row,@[@"vod_play_from",@"play_from"]),*playURL=MediaTVBoxFirstString(row,@[@"vod_play_url",@"play_url"]);
    NSArray *names=playFrom.length?[playFrom componentsSeparatedByString:@"$$$"]:@[];NSArray *groups=playURL.length?[playURL componentsSeparatedByString:@"$$$"]:@[];
    NSMutableArray *lines=[NSMutableArray array];for(NSUInteger i=0;i<groups.count;i++){NSString *flag=i<names.count?[names[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";if(!flag.length)flag=[NSString stringWithFormat:@"线路 %lu",(unsigned long)i+1];NSArray *episodes=MediaTVBoxEpisodes(groups[i],flag,source);if(!episodes.count)continue;[lines addObject:@{@"id":flag,@"name":flag,@"episodes":episodes}];}
    BOOL macCMS=[source[@"protocol"] isEqual:@"maccms-api"]||[source[@"protocol"] isEqual:@"jar-bridge"]||[source[@"_jarBridge"] boolValue];
    BOOL directType1=[source[@"tvboxType"] integerValue]==1&&!MediaTVBoxString(source[@"playUrl"]).length;
    if((macCMS||directType1)&&lines.count>1){
        NSMutableArray *nativeLines=[NSMutableArray array],*webLines=[NSMutableArray array];
        for(NSDictionary *line in lines){
            NSString *flagName=[line[@"name"] isKindOfClass:NSString.class]?[line[@"name"] lowercaseString]:@"";
            NSString *firstEpID=[line[@"episodes"] count]?MediaTVBoxString(line[@"episodes"][0][@"id"]):@"";
            NSString *lowFirstEp=firstEpID.lowercaseString;
            BOOL isDeadLiangzi=[lowFirstEp containsString:@"lzcdn"]||[lowFirstEp containsString:@"lzfile"]||[lowFirstEp containsString:@"lfthirtytwo"];
            BOOL isNative=!isDeadLiangzi&&([flagName containsString:@"m3u8"]||[flagName containsString:@"mp4"]||(firstEpID.length&&!MediaTVBoxURLLooksLikeWebPage(firstEpID)));
            if(isNative)[nativeLines addObject:line];else[webLines addObject:line];
        }
        if(nativeLines.count&&webLines.count){[nativeLines addObjectsFromArray:webLines];lines=nativeLines;}
    }
    NSMutableDictionary *detail=[item mutableCopy];detail[@"lines"]=lines;NSString *banner=MediaTVBoxFirstString(row,@[@"vod_pic_slide",@"banner"]);if(banner.length)detail[@"banner"]=banner;return detail;
}
static NSString *MediaDoubanFilterValue(NSDictionary *filters,NSString *key,NSString *fallback) {
    id value=filters[key];if([value isKindOfClass:NSString.class]&&[(NSString *)value length])return value;if([value isKindOfClass:NSNumber.class])return [value description];return fallback?:@"";
}
static NSString *MediaDoubanTags(NSDictionary *filters) {
    NSMutableArray *values=[NSMutableArray array];for(id key in filters){if(![key isKindOfClass:NSString.class]||[key isEqual:@"sort"])continue;id value=filters[key];NSString *text=[value isKindOfClass:NSString.class]?value:([value isKindOfClass:NSNumber.class]?[value description]:@"");if(text.length)[values addObject:text];}return [values componentsJoinedByString:@","];
}
static NSURLRequest *MediaDoubanRequest(NSString *operation,NSDictionary *arguments,NSError **error) {
    NSString *path=@"";NSMutableDictionary<NSString *,NSString *> *query=[@{@"apikey":@"0ac44ae016490db2204ce0a042db2916",@"count":@"20"} mutableCopy];NSInteger page=MAX(1,MIN(100,[arguments[@"page"] integerValue]));query[@"start"]=[NSString stringWithFormat:@"%ld",(long)(page-1)*20];NSDictionary *filters=[arguments[@"filters"] isKindOfClass:NSDictionary.class]?arguments[@"filters"]:@{};
    if([operation isEqual:@"home"]){path=@"/api/v2/subject_collection/subject_real_time_hotest/items";}
    else if([operation isEqual:@"search"]){NSString *keyword=MediaTVBoxString(arguments[@"keyword"]);if(!keyword.length){if(error)*error=[NSError errorWithDomain:@"CCTVHostDouban" code:1 userInfo:@{NSLocalizedDescriptionKey:@"请输入搜索关键词"}];return nil;}path=@"/api/v2/search/subjects";query[@"q"]=keyword;}
    else if([operation isEqual:@"category"]){NSString *category=MediaTVBoxString(arguments[@"categoryId"]);NSString *collection=@"";
        if([category isEqual:@"tv_hot"]||[category isEqual:@"show_hot"]){collection=MediaDoubanFilterValue(filters,@"type",category);}
        else if([category isEqual:@"rank_list_movie"]){collection=MediaDoubanFilterValue(filters,@"榜单",@"movie_real_time_hotest");}
        else if([category isEqual:@"rank_list_tv"]){collection=MediaDoubanFilterValue(filters,@"榜单",@"tv_real_time_hotest");}
        if(collection.length){path=[NSString stringWithFormat:@"/api/v2/subject_collection/%@/items",collection];}
        else if([category isEqual:@"tv"]||[category isEqual:@"tv_hot"]){path=@"/api/v2/tv/recommend";query[@"sort"]=MediaDoubanFilterValue(filters,@"sort",@"T");NSString *tags=MediaDoubanTags(filters);if(tags.length)query[@"tags"]=tags;}
        else if([category isEqual:@"hot_gaia"]){path=@"/api/v2/movie/hot_gaia";query[@"sort"]=MediaDoubanFilterValue(filters,@"sort",@"recommend");NSString *area=MediaDoubanFilterValue(filters,@"area",@"全部");query[@"area"]=area;NSString *tags=MediaDoubanTags(filters);if(tags.length)query[@"tags"]=tags;}
        else {path=@"/api/v2/movie/recommend";query[@"sort"]=MediaDoubanFilterValue(filters,@"sort",@"T");NSString *tags=MediaDoubanTags(filters);if(tags.length)query[@"tags"]=tags;}
    }else{if(error)*error=[NSError errorWithDomain:@"CCTVHostDouban" code:2 userInfo:@{NSLocalizedDescriptionKey:@"豆瓣索引只提供首页、分类和搜索，不提供独立播放地址"}];return nil;}
    NSURLComponents *parts=[NSURLComponents componentsWithString:[@"https://frodo.douban.com" stringByAppendingString:path]];NSMutableArray *items=[NSMutableArray array];for(NSString *key in [query.allKeys sortedArrayUsingSelector:@selector(compare:)])[items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]?:@""]];parts.queryItems=items;NSURL *url=parts.URL;if(!url||url.absoluteString.length>8192){if(error)*error=[NSError errorWithDomain:@"CCTVHostDouban" code:3 userInfo:@{NSLocalizedDescriptionKey:@"豆瓣索引请求地址无效"}];return nil;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];request.HTTPMethod=@"GET";[request setValue:@"application/json, */*" forHTTPHeaderField:@"Accept"];[request setValue:@"https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html" forHTTPHeaderField:@"Referer"];[request setValue:@"Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.143 Safari/537.36 MicroMessenger/7.0.9.501 NetType/WIFI MiniProgramEnv/Windows WindowsWechat" forHTTPHeaderField:@"User-Agent"];return request;
}
static NSArray<NSDictionary *> *MediaDoubanItems(id raw) {
    NSDictionary *root=MediaTVBoxObject(raw);id rows=root[@"subject_collection_items"]?:root[@"items"];if([rows isKindOfClass:NSDictionary.class])rows=rows[@"items"];if(![rows isKindOfClass:NSArray.class]&&[root[@"subjects"] isKindOfClass:NSDictionary.class])rows=root[@"subjects"][@"items"];NSMutableArray *items=[NSMutableArray array];if(![rows isKindOfClass:NSArray.class])return items;
    for(id value in (NSArray *)rows){NSDictionary *outer=MediaTVBoxObject(value);if([outer[@"target_type"] isKindOfClass:NSString.class]&&[outer[@"target_type"] isEqual:@"chart"])continue;NSDictionary *row=[outer[@"target"] isKindOfClass:NSDictionary.class]?outer[@"target"]:outer;NSString *title=MediaTVBoxFirstString(row,@[@"title",@"name"]);if(!title.length)continue;NSDictionary *pic=MediaTVBoxObject(row[@"pic"]);NSString *poster=MediaTVBoxFirstString(pic,@[@"normal",@"large"]);if(!poster.length)poster=MediaTVBoxFirstString(row,@[@"cover_url",@"cover"]);NSDictionary *rating=MediaTVBoxObject(row[@"rating"]);NSString *subtitle=MediaTVBoxFirstString(row,@[@"card_subtitle",@"abstract",@"description"]);NSString *score=MediaTVBoxFirstString(rating,@[@"value"]);if(!subtitle.length&&score.length)subtitle=[NSString stringWithFormat:@"评分 %@",score];NSMutableDictionary *normalized=[@{@"vod_id":[NSString stringWithFormat:@"msearch:###%@###%@",title,poster],@"vod_name":title,@"vod_pic":poster?:@"",@"vod_remarks":subtitle?:@"",@"vod_content":MediaTVBoxFirstString(row,@[@"abstract",@"description"])?:@""} mutableCopy];NSString *year=MediaTVBoxString(row[@"year"]);if(year.length)normalized[@"vod_year"]=year;NSDictionary *item=MediaTVBoxItem(normalized,@{});if(item)[items addObject:item];}
    return items;
}
static id MediaDoubanNormalize(NSString *operation,NSDictionary *arguments,id raw) {
    if([operation isEqual:@"capabilities"])return @{@"engine":@"Douban metadata index (native iOS adapter)",@"protocol":@"douban-index",@"capabilities":@[@"home",@"category",@"search"]};
    if([operation isEqual:@"providers"])return @[];
    if([operation isEqual:@"detail"]||[operation isEqual:@"play"])return @{@"error":@"此豆瓣源只提供片名索引，请使用“跨来源搜索”在已导入点播源中查找可播放线路"};
    NSDictionary *root=MediaTVBoxObject(raw);NSArray *items=MediaDoubanItems(root);NSInteger page=MAX(1,[arguments[@"page"] integerValue]);NSDictionary *subjects=MediaTVBoxObject(root[@"subjects"]);id totalValue=root[@"total"]?:root[@"count"]?:subjects[@"total"];NSInteger total=[totalValue respondsToSelector:@selector(integerValue)]?[totalValue integerValue]:0;NSInteger pageCount=total>0?(total+19)/20:page+(items.count>=20?1:0);NSMutableDictionary *result=[@{@"items":items,@"page":@(page),@"pageCount":@(MAX(page,pageCount)),@"hasMore":@(page<pageCount)} mutableCopy];
    if([operation isEqual:@"home"]){result[@"categories"]=@[@{@"id":@"hot_gaia",@"name":@"热门电影"},@{@"id":@"tv_hot",@"name":@"热播剧集"},@{@"id":@"show_hot",@"name":@"热播综艺"},@{@"id":@"movie",@"name":@"电影筛选"},@{@"id":@"tv",@"name":@"电视筛选"},@{@"id":@"rank_list_movie",@"name":@"电影榜单"},@{@"id":@"rank_list_tv",@"name":@"电视剧榜单"}];result[@"filters"]=@{};}
    return result;
}
static id MediaJARBridgeNormalize(NSString *operation,NSDictionary *arguments,NSDictionary *source,id raw);
static id MediaTVBoxNormalize(NSString *operation,NSDictionary *arguments,NSDictionary *source,id raw) {
    if([source[@"protocol"] isEqual:@"douban-index"])return MediaDoubanNormalize(operation,arguments?:@{},raw);
    if([source[@"protocol"] isEqual:@"jar-bridge"])return MediaJARBridgeNormalize(operation,arguments?:@{},source,raw);
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
        if(macCMS){NSString *url=MediaTVBoxString(arguments[@"id"]);if(!url.length)return @{@"error":@"MacCMS 分集没有播放地址"};BOOL webPage=MediaTVBoxURLLooksLikeWebPage(url);NSMutableDictionary *result=[@{@"url":url,@"originalURL":url,@"parse":@(webPage),@"jx":@0,@"headers":headers} mutableCopy];for(NSString *key in @[@"format",@"contentType",@"mimeType",@"mediaType"])if([root[key] isKindOfClass:NSString.class])result[key]=root[key];NSString *extension=[NSURL URLWithString:url].pathExtension.lowercaseString?:@"";BOOL explicitWebPage=[@[@"html",@"htm",@"xhtml",@"php",@"asp",@"aspx",@"jsp",@"shtml"] containsObject:extension];BOOL cicada=MediaPlaybackResultSupportsCicada(result);if(!explicitWebPage&&MediaPlaybackResultSupportsNativePlayback(result))webPage=NO;BOOL native=!webPage&&(MediaPlaybackResultSupportsNativePlayback(result)||MediaTVBoxURLHasSignedQuery(url));if(cicada)result[@"playbackEngine"]=@"cicada";else if(native)result[@"playbackEngine"]=@"avplayer";result[@"parse"]=@(webPage);result[@"nativePlayable"]=@(native);result[@"directMedia"]=@(!webPage&&MediaPlaybackResultIsDirectMedia(result));result[@"requiresWebPlayback"]=@(webPage||!native);return result;}
        if([source[@"tvboxType"] integerValue]==1||(source[@"tvboxType"]!=nil&&[source[@"tvboxType"] integerValue]==0)){NSString *url=MediaTVBoxString(arguments[@"id"]);NSString *prefix=MediaTVBoxString(source[@"playUrl"]);if(!url.length)return @{@"error":@"TVBox type 1 没有返回分集地址"};NSMutableDictionary *result=[@{@"url":[prefix stringByAppendingString:url],@"parse":@(prefix.length>0),@"headers":headers} mutableCopy];BOOL cicada=MediaPlaybackResultSupportsCicada(result),native=MediaPlaybackResultSupportsNativePlayback(result);if(cicada)result[@"playbackEngine"]=@"cicada";else if(native)result[@"playbackEngine"]=@"avplayer";result[@"nativePlayable"]=@(native);result[@"directMedia"]=@(MediaPlaybackResultIsDirectMedia(result));result[@"requiresWebPlayback"]=@(prefix.length>0&&!native);return result;}
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
        NSMutableDictionary *result=[@{@"url":url,@"parse":@(parse),@"jx":@(jx),@"playUrl":prefix,@"headers":headers} mutableCopy];for(NSString *key in @[@"format",@"contentType",@"mimeType",@"mediaType"])if([root[key] isKindOfClass:NSString.class])result[key]=root[key];BOOL cicada=MediaPlaybackResultSupportsCicada(result),native=MediaPlaybackResultSupportsNativePlayback(result);if(cicada)result[@"playbackEngine"]=@"cicada";else if(native)result[@"playbackEngine"]=@"avplayer";result[@"nativePlayable"]=@(native);result[@"directMedia"]=@(MediaPlaybackResultIsDirectMedia(result));result[@"requiresWebPlayback"]=@((parse>0||jx>0||prefix.length>0)&&!native);if(alternates.count>1)result[@"alternates"]=alternates;
        return result;
    }
    return root;
}

static NSString *MediaParserEncodeValue(NSString *value) {
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed]?:@"";
}
static NSString *MediaParserRequestURL(NSDictionary *parser,NSString *mediaURL) {
    NSString *template=[parser[@"url"] isKindOfClass:NSString.class]?parser[@"url"]:@"";
    if(!template.length||template.length>8192||!mediaURL.length||mediaURL.length>8192)return @"";
    NSString *encoded=MediaParserEncodeValue(mediaURL),*result=template;BOOL replaced=NO;
    for(NSString *placeholder in @[@"{url}",@"$url",@"%s"]){if([result containsString:placeholder]){result=[result stringByReplacingOccurrencesOfString:placeholder withString:encoded];replaced=YES;}}
    if(!replaced){
        NSURLComponents *base=[NSURLComponents componentsWithString:result];BOOL filled=NO;NSMutableArray *items=[NSMutableArray array];
        for(NSURLQueryItem *item in base.queryItems?:@[]){if(!filled&&([item.name caseInsensitiveCompare:@"url"]==NSOrderedSame||[item.name caseInsensitiveCompare:@"v"]==NSOrderedSame||[item.name caseInsensitiveCompare:@"target"]==NSOrderedSame||[item.name caseInsensitiveCompare:@"link"]==NSOrderedSame)&&(!item.value.length||[item.value isEqual:@"{url}"]||[item.value isEqual:@"$url"])){[items addObject:[NSURLQueryItem queryItemWithName:item.name value:mediaURL]];filled=YES;}else[items addObject:item];}
        if(!filled)[items addObject:[NSURLQueryItem queryItemWithName:@"url" value:mediaURL]];base.queryItems=items;result=base.URL.absoluteString?:@"";
    }
    NSURLComponents *parts=[NSURLComponents componentsWithString:result];
    if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length||result.length>16384)return @"";
    return parts.URL.absoluteString?:@"";
}
static NSDictionary *MediaParserObjectWithURL(id value,NSUInteger depth) {
    if(depth>6)return nil;
    if([value isKindOfClass:NSString.class]){
        NSString *candidate=[[[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"] stringByReplacingOccurrencesOfString:@"\\u002f" withString:@"/"];
        if(([candidate hasPrefix:@"aHR0cHM6Ly"]||[candidate hasPrefix:@"aHR0cDovL"])&&candidate.length>=16&&candidate.length<=4096){
            NSData *b64=[[NSData alloc] initWithBase64EncodedString:candidate options:NSDataBase64DecodingIgnoreUnknownCharacters];
            NSString *dec=b64?[[NSString alloc] initWithData:b64 encoding:NSUTF8StringEncoding]:nil;
            if([dec hasPrefix:@"http://"]||[dec hasPrefix:@"https://"])candidate=dec;
        }
        NSURLComponents *parts=[NSURLComponents componentsWithString:candidate];
        if([@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length&&!parts.user.length&&!parts.password.length)return @{ @"url":candidate };
        if([candidate containsString:@"player_aaaa"]){
            static NSRegularExpression *paRegex;static dispatch_once_t paOnce;
            dispatch_once(&paOnce,^{paRegex=[NSRegularExpression regularExpressionWithPattern:@"player_aaaa\\s*=\\s*(\\{[^\\n;]+\\})" options:NSRegularExpressionCaseInsensitive error:NULL];});
            NSTextCheckingResult *paMatch=[paRegex firstMatchInString:candidate options:0 range:NSMakeRange(0,candidate.length)];
            if(paMatch&&paMatch.numberOfRanges>1){
                NSString *jsonStr=[candidate substringWithRange:[paMatch rangeAtIndex:1]];
                NSData *jData=[jsonStr dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *paObj=jData?[NSJSONSerialization JSONObjectWithData:jData options:0 error:NULL]:nil;
                if([paObj isKindOfClass:NSDictionary.class]&&[paObj[@"url"] isKindOfClass:NSString.class]){
                    NSString *paURL=paObj[@"url"];
                    NSInteger enc=[paObj[@"encrypt"] respondsToSelector:@selector(integerValue)]?[paObj[@"encrypt"] integerValue]:0;
                    if(enc==1)paURL=[paURL stringByRemovingPercentEncoding]?:paURL;
                    else if(enc==2){
                        NSData *b64=[[NSData alloc] initWithBase64EncodedString:paURL options:NSDataBase64DecodingIgnoreUnknownCharacters];
                        NSString *dec=b64?[[NSString alloc] initWithData:b64 encoding:NSUTF8StringEncoding]:nil;
                        if(dec.length)paURL=[dec stringByRemovingPercentEncoding]?:dec;
                    }
                    paURL=[paURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                    NSURLComponents *paParts=[NSURLComponents componentsWithString:paURL];
                    if([@[@"http",@"https"] containsObject:paParts.scheme.lowercaseString]&&paParts.host.length)return @{@"url":paURL};
                }
            }
        }
        if(candidate.length>10&&([candidate containsString:@"http://"]||[candidate containsString:@"https://"])){
            static NSRegularExpression *regex;static dispatch_once_t onceToken;
            dispatch_once(&onceToken,^{regex=[NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>\\\\]+?\\.(?:m3u8|mp4|flv|mpd)(?:[?#][^\\s\"'<>\\\\]*)?" options:NSRegularExpressionCaseInsensitive error:NULL];});
            NSTextCheckingResult *match=[regex firstMatchInString:candidate options:0 range:NSMakeRange(0,candidate.length)];
            if(match&&match.range.location!=NSNotFound){
                NSString *extracted=[candidate substringWithRange:match.range];
                NSURLComponents *subParts=[NSURLComponents componentsWithString:extracted];
                if([@[@"http",@"https"] containsObject:subParts.scheme.lowercaseString]&&subParts.host.length&&!subParts.user.length&&!subParts.password.length)return @{ @"url":extracted };
            }
        }
        return nil;
    }
    if([value isKindOfClass:NSArray.class]){for(id child in value){NSDictionary *found=MediaParserObjectWithURL(child,depth+1);if(found)return found;}return nil;}
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSDictionary *dictionary=value;
    for(NSString *key in @[@"url",@"playUrl",@"playurl",@"videoUrl",@"video_url",@"mediaUrl",@"src",@"m3u8",@"link",@"stream",@"vurl",@"uri"]){
        id candidate=dictionary[key];
        if([candidate isKindOfClass:NSString.class]){
            NSDictionary *found=MediaParserObjectWithURL(candidate,depth+1);
            if(found){
                NSMutableDictionary *merged=[dictionary mutableCopy];
                [merged addEntriesFromDictionary:found];
                merged[@"url"]=found[@"url"];
                return merged;
            }
        }
    }
    for(NSString *key in @[@"data",@"result",@"payload",@"response",@"play",@"video",@"info",@"stream",@"body",@"content",@"item"]){
        NSDictionary *found=MediaParserObjectWithURL(dictionary[key],depth+1);
        if(found){
            NSMutableDictionary *merged=[dictionary mutableCopy];
            [merged addEntriesFromDictionary:found];
            merged[@"url"]=found[@"url"];
            return merged;
        }
    }
    return nil;
}
static BOOL MediaParserSameOrigin(NSURL *left,NSURL *right) {
    if(!left.host.length||!right.host.length||![left.scheme.lowercaseString isEqual:right.scheme.lowercaseString]||![left.host.lowercaseString isEqual:right.host.lowercaseString])return NO;
    NSNumber *leftPort=left.port?:([left.scheme.lowercaseString isEqual:@"https"]?@443:@80),*rightPort=right.port?:([right.scheme.lowercaseString isEqual:@"https"]?@443:@80);return [leftPort isEqual:rightPort];
}
static NSString *MediaParserKind(NSDictionary *parser) {
    id raw=parser[@"type"];NSString *type=[raw respondsToSelector:@selector(stringValue)]?[raw stringValue]:([raw isKindOfClass:NSString.class]?raw:@"0");type=type.lowercaseString;
    if([@[@"0",@"web",@"html"] containsObject:type])return @"web";
    if([@[@"1",@"json",@"api"] containsObject:type])return @"api";
    return @"unknown";
}
static BOOL MediaParserResponseIsDirectMedia(NSURLResponse *response) {
    NSString *mime=response.MIMEType.lowercaseString?:@"";NSRange separator=[mime rangeOfString:@";"];if(separator.location!=NSNotFound)mime=[mime substringToIndex:separator.location];
    NSURL *url=response.URL;NSString *extension=url.pathExtension.lowercaseString?:@"";
    BOOL mediaMIME=[mime hasPrefix:@"video/"]||[mime hasPrefix:@"audio/"]||[@[@"application/vnd.apple.mpegurl",@"application/x-mpegurl",@"audio/mpegurl",@"application/dash+xml"] containsObject:mime];
    BOOL mediaExtension=[@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3",@"aac",@"ts",@"mpd"] containsObject:extension];
    if(!mediaExtension&&url.absoluteString.length){
        NSString *low=url.absoluteString.lowercaseString;
        if([low containsString:@".m3u8"]||[low containsString:@".mp4"]||[low containsString:@".flv"]||[low containsString:@".mpd"])mediaExtension=YES;
    }
    return mediaMIME||mediaExtension;
}
static BOOL MediaParserCandidateSupportsNativePlayer(NSString *address,NSDictionary *candidate) {
    NSString *format=[MediaTVBoxString(candidate[@"format"]?:candidate[@"type"]) lowercaseString];
    NSString *mime=[MediaTVBoxString(candidate[@"contentType"]?:candidate[@"content_type"]?:candidate[@"mimeType"]?:candidate[@"mime"]) lowercaseString];
    NSMutableDictionary *descriptor=[@{@"url":address?:@""} mutableCopy];
    if(format.length)descriptor[@"format"]=format;
    if(mime.length)descriptor[@"mimeType"]=mime;
    return MediaPlaybackResultSupportsNativePlayback(descriptor)||MediaTVBoxURLHasSignedQuery(address);
}
static id MediaParserExtractHeaderValue(NSDictionary *parser) {
    if(![parser isKindOfClass:NSDictionary.class])return nil;
    id direct=parser[@"header"]?:parser[@"headers"];
    if(direct)return direct;
    id ext=parser[@"ext"];
    if([ext isKindOfClass:NSDictionary.class]){
        return ((NSDictionary *)ext)[@"header"]?:((NSDictionary *)ext)[@"headers"];
    }
    return nil;
}
static NSDictionary *MediaParserCleanHeaders(id value,NSURL *mediaURL,NSURL *parserURL) {
    NSMutableDictionary *candidates=[NSMutableDictionary dictionary];
    if([value isKindOfClass:NSDictionary.class]){NSUInteger count=0;for(id rawName in (NSDictionary *)value){if(count++>=32||![rawName isKindOfClass:NSString.class]||![(NSString *)rawName length]||![value[rawName] isKindOfClass:NSString.class])continue;candidates[rawName]=value[rawName];}}
    else if([value isKindOfClass:NSString.class]&&[(NSString *)value length]<=65536){NSUInteger count=0;for(NSString *part in [(NSString *)value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n#"]]){if(count++>=32)break;NSRange separator=[part rangeOfString:@"$"];if(separator.location==NSNotFound)separator=[part rangeOfString:@":"];if(separator.location==NSNotFound||separator.location==0)continue;NSString *name=[[part substringToIndex:separator.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*headerValue=[[part substringFromIndex:NSMaxRange(separator)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(name.length)candidates[name]=headerValue;}}
    NSMutableDictionary *result=[NSMutableDictionary dictionary];for(NSString *name in candidates){NSString *headerValue=candidates[name];if(!MediaTVBoxHeaderAllowed(name,headerValue))continue;if(MediaTVBoxHeaderIsSensitive(name)&&!MediaParserSameOrigin(mediaURL,parserURL))continue;result[name]=headerValue;}
    return result.copy;
}

@interface MediaAPIRequestContext : NSObject
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSError *failure;
@property(nonatomic) NSUInteger redirectCount;
@property(nonatomic) BOOL parserRequest;
@property(nonatomic,copy) NSString *parserDirectURL;
@property(nonatomic,copy) NSString *parserDirectMIME;
@property(nonatomic,copy) void (^processor)(NSData *,NSURLResponse *,NSError *);
@end
@implementation MediaAPIRequestContext @end

@interface MediaAPIClient () <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSession *playSession;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSOperationQueue *delegateQueue;
@property(nonatomic,strong) NSLock *contextLock;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,MediaAPIRequestContext *> *requestContexts;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSInteger port;
@property(nonatomic) NSTimeInterval requestTimeout;
@property(nonatomic, copy) NSString *activeRequestID;
@property(nonatomic, copy) NSString *activeCorrelationID;
@property(nonatomic, copy) NSString *activeOperation;
@property(nonatomic, copy) NSDictionary *tvboxSource;
@property(nonatomic,copy) NSString *parserCatalogID;
@property(nonatomic,copy) NSDictionary *parserFallbackResult;
@property(nonatomic,copy) NSDictionary *parserWebFallbackResult;
@property(nonatomic,copy) NSArray<NSDictionary *> *parserAPIEntries;
@property(nonatomic,copy) void (^parserCompletion)(id,NSError *);
@property(nonatomic,copy) NSString *parserCorrelationID;
@property(nonatomic,copy) NSString *selectedParserID;
@property(nonatomic) NSUInteger parserGeneration;
- (void)cancelWithReason:(NSString *)reason;
- (void)completeResult:(id)result error:(NSError *)error operation:(NSString *)operation generation:(NSUInteger)generation correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion;
- (void)resolveParserResult:(NSDictionary *)result generation:(NSUInteger)generation correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion;
- (void)tryParserAtIndex:(NSUInteger)index;
- (void)finishParserWithResult:(NSDictionary *)result;
- (NSUInteger)maximumResponseBytes;
- (BOOL)sameOrigin:(NSURL *)left as:(NSURL *)right;
- (BOOL)sameCredentialScope:(NSURL *)origin as:(NSURL *)target;
@end

@implementation MediaAPIClient
@synthesize playTimeoutMilliseconds = _playTimeoutMilliseconds;
- (instancetype)initWithPort:(NSInteger)port {
    NSTimeInterval savedTimeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;
    return [self initWithPort:port requestTimeout:savedTimeout];
}
- (instancetype)initWithPort:(NSInteger)port requestTimeout:(NSTimeInterval)requestTimeout {
    if((self=[super init])){
        _port=port;
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        NSTimeInterval timeout=MIN(40,MAX(5,requestTimeout));
        _requestTimeout=timeout;
        _playTimeoutMilliseconds=15000;
        configuration.timeoutIntervalForRequest=timeout;
        configuration.timeoutIntervalForResource=timeout+5;
        configuration.URLCache=nil;
        configuration.HTTPMaximumConnectionsPerHost=6;configuration.HTTPShouldUsePipelining=YES;
        _delegateQueue=[NSOperationQueue new];_delegateQueue.name=@"com.cctvhost.media-api";_delegateQueue.maxConcurrentOperationCount=1;
        _contextLock=[NSLock new];_requestContexts=[NSMutableDictionary dictionary];
        _session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
    }
    return self;
}
- (instancetype)initWithPort:(NSInteger)port catalogID:(NSString *)catalogID {
    if((self=[self initWithPort:port]))_parserCatalogID=[catalogID copy];
    return self;
}
- (void)setPlayTimeoutMilliseconds:(NSInteger)playTimeoutMilliseconds {
    _playTimeoutMilliseconds=playTimeoutMilliseconds>0?MIN(120000,MAX(1000,playTimeoutMilliseconds)):15000;
}
- (NSURLSession *)sessionForOperation:(NSString *)operation {
    if(![operation isEqual:@"play"])return self.session;
    if(!self.playSession){
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest=120;
        configuration.timeoutIntervalForResource=125;
        configuration.URLCache=nil;
        configuration.HTTPMaximumConnectionsPerHost=6;configuration.HTTPShouldUsePipelining=YES;
        self.playSession=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:self.delegateQueue];
    }
    return self.playSession;
}
- (instancetype)initWithTVBoxSource:(NSDictionary *)source {
    // TVBox/MacCMS 也走网络超时偏好（默认 20 秒，夹取 5–40 秒），不再写死 20 秒。
    NSTimeInterval savedTimeout=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.networkTimeout.v1"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.networkTimeout.v1"]:20;
    if((self=[self initWithPort:0 requestTimeout:savedTimeout])){_tvboxSource=[source copy];_parserCatalogID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");}
    return self;
}
- (NSUInteger)maximumResponseBytes {return self.tvboxSource?8*1024*1024:2*1024*1024;}
- (BOOL)sameOrigin:(NSURL *)left as:(NSURL *)right {
    if(!left||!right)return NO;
    NSURLComponents *a=[NSURLComponents componentsWithURL:left resolvingAgainstBaseURL:NO],*b=[NSURLComponents componentsWithURL:right resolvingAgainstBaseURL:NO];if(!a||!b||![a.scheme.lowercaseString isEqual:b.scheme.lowercaseString]||![a.host.lowercaseString isEqual:b.host.lowercaseString])return NO;
    NSNumber *aPort=a.port?:([a.scheme.lowercaseString isEqual:@"https"]?@443:@80),*bPort=b.port?:([b.scheme.lowercaseString isEqual:@"https"]?@443:@80);return [aPort isEqual:bPort];
}
- (BOOL)sameCredentialScope:(NSURL *)origin as:(NSURL *)target {
    if(!origin||!target)return NO;
    if([self sameOrigin:origin as:target])return YES;
    NSURLComponents *a=[NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO],*b=[NSURLComponents componentsWithURL:target resolvingAgainstBaseURL:NO];if(!a||!b||![a.scheme.lowercaseString isEqual:@"http"]||![b.scheme.lowercaseString isEqual:@"https"]||![a.host.lowercaseString isEqual:b.host.lowercaseString])return NO;
    NSNumber *aPort=a.port?:@80,*bPort=b.port?:@443;return [aPort isEqual:@80]&&[bPort isEqual:@443];
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
    self.parserCompletion=nil;self.parserFallbackResult=nil;self.parserWebFallbackResult=nil;self.parserAPIEntries=nil;self.parserCorrelationID=nil;self.selectedParserID=nil;
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
    [self.playSession invalidateAndCancel];
}
- (void)completeResult:(id)result error:(NSError *)error operation:(NSString *)operation generation:(NSUInteger)generation correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion {
    if(generation!=self.generation)return;
    NSDictionary *dictionary=[result isKindOfClass:NSDictionary.class]?result:nil;
    BOOL manualSelection=self.selectedParserID.length>0;
    BOOL asksForParser=[operation isEqual:@"play"]&&dictionary&&(manualSelection||[dictionary[@"requiresWebPlayback"] boolValue]||[dictionary[@"webPlayback"] boolValue]||[dictionary[@"parse"] boolValue]||[dictionary[@"jx"] boolValue])&&!MediaPlaybackResultSupportsNativePlayback(dictionary);
    if(!error&&asksForParser){[self resolveParserResult:dictionary generation:generation correlationID:correlationID completion:completion];return;}
    if(completion)completion(result,error);
}
- (void)resolveParserResult:(NSDictionary *)result generation:(NSUInteger)generation correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion {
    NSString *mediaURL=[result[@"url"] isKindOfClass:NSString.class]?result[@"url"]:@"";
    NSURLComponents *mediaParts=[NSURLComponents componentsWithString:mediaURL];
    if(!mediaURL.length||mediaURL.length>8192||![@[@"http",@"https"] containsObject:mediaParts.scheme.lowercaseString]||!mediaParts.host.length||mediaParts.user.length||mediaParts.password.length){if(completion)completion(result,nil);return;}
    NSString *catalogID=self.parserCatalogID?:([self.tvboxSource[@"catalogID"] isKindOfClass:NSString.class]?self.tvboxSource[@"catalogID"]:([self.tvboxSource[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.tvboxSource[@"tvboxCatalogID"]:@""));
    catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // An unscoped source must never inherit parser endpoints from whichever
    // TVBox collection happened to be imported most recently.
    if(!catalogID.length){if(completion)completion(result,nil);return;}
    NSArray<NSDictionary *> *available=[TVBoxCatalogStore playbackParsersForCatalogID:catalogID];NSMutableArray *apiParsers=[NSMutableArray array];NSDictionary *webParser=nil,*selectedParser=nil;
    for(NSDictionary *parser in available){NSString *kind=MediaParserKind(parser);if([kind isEqual:@"api"]&&apiParsers.count<3)[apiParsers addObject:parser];else if([kind isEqual:@"web"]&&!webParser&&self.selectedParserID.length)webParser=parser;if(self.selectedParserID.length&&[parser[@"id"] isEqual:self.selectedParserID])selectedParser=parser;}
    if(selectedParser){NSString *kind=MediaParserKind(selectedParser);if([kind isEqual:@"web"]){webParser=selectedParser;[apiParsers removeAllObjects];}else{[apiParsers removeAllObjects];[apiParsers addObject:selectedParser];}}
    if(!apiParsers.count&&!selectedParser&&available.count){
        for(NSDictionary *p in available){
            if(apiParsers.count>=3)break;
            NSString *u=[p[@"url"] isKindOfClass:NSString.class]?p[@"url"]:@"";
            NSString *low=[u lowercaseString];
            if([low containsString:@"json"]||[low containsString:@"jiexi"]||[low containsString:@"xmflv"]||[low containsString:@"yparse"]||[low containsString:@"analysis"]||[low containsString:@"api"]||[low containsString:@"playm3u8"]||[low containsString:@"m3u8.tv"]||[low containsString:@"ckplayer"]){
                [apiParsers addObject:p];
            }
        }
        if(!apiParsers.count){
            for(NSDictionary *p in available){
                if(apiParsers.count>=3)break;
                [apiParsers addObject:p];
            }
        }
    }
    if(!apiParsers.count&&!webParser){if(completion)completion(result,nil);return;}
    [apiParsers sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSInteger sa=MediaParserScoreForEntry(a),sb=MediaParserScoreForEntry(b);return sa>sb?NSOrderedAscending:(sa<sb?NSOrderedDescending:NSOrderedSame);}];self.parserGeneration=generation;self.parserFallbackResult=[result copy];self.parserAPIEntries=apiParsers.copy;self.parserCorrelationID=[correlationID copy];self.parserCompletion=[completion copy];self.parserWebFallbackResult=nil;
    if(webParser){NSString *webURL=MediaParserRequestURL(webParser,mediaURL);if(webURL.length){NSMutableDictionary *webResult=[@{@"url":webURL,@"originalURL":webURL,@"parse":@YES,@"jx":@YES,@"requiresWebPlayback":@YES,@"parserName":webParser[@"name"]?:@"资源合集解析"} mutableCopy];NSDictionary *webHeaders=MediaParserCleanHeaders(MediaParserExtractHeaderValue(webParser),[NSURL URLWithString:webURL],[NSURL URLWithString:webURL]);if(webHeaders.count)webResult[@"headers"]=webHeaders;self.parserWebFallbackResult=webResult.copy;}}
    [RuntimeDiagnostics.shared recordEvent:@"media_parser_resolution_started" category:@"playback" fields:@{@"correlation_id":correlationID?:@"",@"parser_api_count":@(apiParsers.count),@"web_parser_available":@(self.parserWebFallbackResult!=nil),@"source_host":mediaParts.host.lowercaseString?:@""}];
    if(!apiParsers.count){[self finishParserWithResult:self.parserWebFallbackResult?:self.parserFallbackResult];return;}
    [self tryParserAtIndex:0];
}
static NSMutableDictionary<NSString *, NSNumber *> *MediaParserSuccessScoreCache(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *scores=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{scores=[NSMutableDictionary dictionary];});
    return scores;
}
static NSInteger MediaParserScoreForEntry(NSDictionary *parser) {
    NSString *u=[parser[@"url"] isKindOfClass:NSString.class]?parser[@"url"]:@"";
    if(!u.length)return 0;
    @synchronized(MediaParserSuccessScoreCache()){
        return [MediaParserSuccessScoreCache()[u] integerValue];
    }
}
static void MediaParserRecordOutcome(NSDictionary *parser, BOOL succeeded) {
    NSString *u=[parser[@"url"] isKindOfClass:NSString.class]?parser[@"url"]:@"";
    if(!u.length)return;
    @synchronized(MediaParserSuccessScoreCache()){
        NSInteger cur=[MediaParserSuccessScoreCache()[u] integerValue];
        MediaParserSuccessScoreCache()[u]=@(MAX(-30,MIN(100,cur+(succeeded?10:-3))));
    }
}
- (void)finishParserWithResult:(NSDictionary *)result {
    void (^completion)(id,NSError *)=self.parserCompletion;NSString *correlationID=self.parserCorrelationID?:@"";
    BOOL resolved=result&&![result[@"requiresWebPlayback"] boolValue]&&[result[@"nativePlayable"] boolValue];
    [RuntimeDiagnostics.shared recordEvent:@"media_parser_resolution_finished" category:@"playback" fields:@{@"correlation_id":correlationID,@"resolved_native_media":@(resolved),@"fallback_to_web_or_source":@(!resolved),@"parser_name":result[@"parserName"]?:@""}];
    self.parserCompletion=nil;self.parserFallbackResult=nil;self.parserWebFallbackResult=nil;self.parserAPIEntries=nil;self.parserCorrelationID=nil;
    if(completion)completion(result,nil);
}
- (void)tryParserAtIndex:(NSUInteger)index {
    NSUInteger generation=self.parserGeneration;if(generation!=self.generation||!self.parserCompletion)return;
    if(index>=self.parserAPIEntries.count){[self finishParserWithResult:self.parserWebFallbackResult?:self.parserFallbackResult];return;}
    NSDictionary *parser=self.parserAPIEntries[index];NSString *original=[self.parserFallbackResult[@"url"] isKindOfClass:NSString.class]?self.parserFallbackResult[@"url"]:@"";NSString *target=MediaParserRequestURL(parser,original);NSURL *targetURL=[NSURL URLWithString:target];
    if(!targetURL){[self tryParserAtIndex:index+1];return;}
    NSTimeInterval maxProbeTimeout=self.selectedParserID.length?8.0:3.2;
    NSTimeInterval timeout=MIN(maxProbeTimeout,MAX(1.0,self.playTimeoutMilliseconds/1000.0));NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:targetURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];request.HTTPMethod=@"GET";[request setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
    NSDictionary *requestHeaders=MediaParserCleanHeaders(MediaParserExtractHeaderValue(parser),targetURL,targetURL);for(NSString *name in requestHeaders)[request setValue:requestHeaders[name] forHTTPHeaderField:name];
    self.activeRequestID=NSUUID.UUID.UUIDString.lowercaseString;self.activeCorrelationID=self.parserCorrelationID;self.activeOperation=@"parse_resolver";
    MediaAPIRequestContext *context=[MediaAPIRequestContext new];context.data=[NSMutableData data];context.parserRequest=YES;__weak typeof(self) weakSelf=self;__weak MediaAPIRequestContext *weakContext=context;NSString *parserName=parser[@"name"]?:@"解析接口";
    context.processor=^(NSData *data,NSURLResponse *response,NSError *networkError){MediaAPIRequestContext *requestContext=weakContext;if(!requestContext)return;dispatch_async(dispatch_get_main_queue(),^{MediaAPIClient *owner=weakSelf;if(!owner||owner.generation!=generation||!owner.parserCompletion)return;owner.task=nil;owner.activeRequestID=nil;owner.activeCorrelationID=nil;owner.activeOperation=nil;NSDictionary *resolved=nil;
            if(requestContext.parserDirectURL.length){NSURL *directURL=[NSURL URLWithString:requestContext.parserDirectURL];NSMutableDictionary *native=[@{@"url":requestContext.parserDirectURL,@"originalURL":requestContext.parserDirectURL,@"format":requestContext.parserDirectMIME?:@"",@"nativePlayable":@YES,@"directMedia":@YES,@"parse":@0,@"jx":@0,@"requiresWebPlayback":@NO,@"parserName":parserName} mutableCopy];if(![native[@"format"] length])[native removeObjectForKey:@"format"];native[@"playbackEngine"]=MediaPlaybackResultSupportsCicada(native)?@"cicada":@"avplayer";NSDictionary *mediaHeaders=MediaParserCleanHeaders(MediaParserExtractHeaderValue(parser),directURL,targetURL);if(mediaHeaders.count)native[@"headers"]=mediaHeaders;resolved=native.copy;}
            else if(!networkError&&[response isKindOfClass:NSHTTPURLResponse.class]&&[(NSHTTPURLResponse *)response statusCode]>=200&&[(NSHTTPURLResponse *)response statusCode]<300&&data.length<=1024*1024){id payload=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];if(!payload){NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];payload=text;}NSDictionary *found=MediaParserObjectWithURL(payload,0);NSString *address=[found[@"url"] isKindOfClass:NSString.class]?found[@"url"]:@"";NSURL *candidateURL=[NSURL URLWithString:address];NSString *pathExt=candidateURL.pathExtension.lowercaseString?:@"";NSString *format=[found[@"format"] isKindOfClass:NSString.class]?[(NSString *)found[@"format"] lowercaseString]:([found[@"type"] isKindOfClass:NSString.class]?[(NSString *)found[@"type"] lowercaseString]:@"");BOOL isDirectStream=MediaParserCandidateSupportsNativePlayer(address,found);BOOL page=(!isDirectStream&&([@[@"html",@"htm",@"php",@"asp",@"aspx",@"jsp"] containsObject:pathExt]||[found[@"parse"] boolValue]||[found[@"jx"] boolValue]||[@[@"web",@"html",@"page"] containsObject:format]));if(address.length&&!page&&isDirectStream){NSURL *mediaURL=[NSURL URLWithString:address];NSMutableDictionary *candidate=[found mutableCopy];candidate[@"url"]=address;candidate[@"originalURL"]=address;candidate[@"parse"]=@0;candidate[@"jx"]=@0;candidate[@"requiresWebPlayback"]=@NO;candidate[@"directMedia"]=@YES;candidate[@"nativePlayable"]=@YES;candidate[@"parserName"]=parserName;if(format.length)candidate[@"format"]=format;candidate[@"playbackEngine"]=MediaPlaybackResultSupportsCicada(candidate)?@"cicada":@"avplayer";NSDictionary *mediaHeaders=MediaParserCleanHeaders(found[@"headers"]?:found[@"header"],mediaURL,targetURL);if(mediaHeaders.count)candidate[@"headers"]=mediaHeaders;else[candidate removeObjectForKey:@"headers"];resolved=candidate.copy;}}
            MediaParserRecordOutcome(parser,resolved!=nil);if(resolved){[RuntimeDiagnostics.shared recordEvent:@"media_parser_endpoint_succeeded" category:@"playback" fields:@{@"correlation_id":owner.parserCorrelationID?:@"",@"parser_name":parserName,@"parser_host":targetURL.host.lowercaseString?:@"",@"native_media":@YES}];[owner finishParserWithResult:resolved];}else{[RuntimeDiagnostics.shared recordEvent:@"media_parser_endpoint_failed" category:@"playback" fields:@{@"correlation_id":owner.parserCorrelationID?:@"",@"parser_name":parserName,@"parser_host":targetURL.host.lowercaseString?:@"",@"failure_stage":networkError?@"network_or_timeout":@"unrecognized_result",@"error_code":@(networkError.code)}];[owner tryParserAtIndex:index+1];}
        });};
    self.task=[[self sessionForOperation:@"play"] dataTaskWithRequest:request];[self.contextLock lock];self.requestContexts[@(self.task.taskIdentifier)]=context;[self.contextLock unlock];[self.task resume];
}
static NSDictionary *MediaJARBridgeJSONDictionary(id raw) {
    if([raw isKindOfClass:NSDictionary.class])return raw;
    if([raw isKindOfClass:NSData.class]){
        id res=[NSJSONSerialization JSONObjectWithData:(NSData *)raw options:0 error:NULL];
        if([res isKindOfClass:NSDictionary.class])return res;
    }
    if([raw isKindOfClass:NSString.class]){
        NSData *data=[(NSString *)raw dataUsingEncoding:NSUTF8StringEncoding];
        id res=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
        if([res isKindOfClass:NSDictionary.class])return res;
    }
    return @{};
}
static NSMutableDictionary<NSString *,NSString *> *MediaJARBridgeMirrorCache(void) {
    static NSMutableDictionary<NSString *,NSString *> *cache=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{cache=[NSMutableDictionary dictionary];});
    return cache;
}
static NSString *MediaJARBridgeLookupMirror(NSString *txtURL) {
    if(!txtURL.length)return @"";
    @synchronized(MediaJARBridgeMirrorCache()){
        return MediaJARBridgeMirrorCache()[txtURL]?:@"";
    }
}
static void MediaJARBridgeSaveMirror(NSString *txtURL,NSString *resolvedURL) {
    if(!txtURL.length||!resolvedURL.length)return;
    @synchronized(MediaJARBridgeMirrorCache()){
        MediaJARBridgeMirrorCache()[txtURL]=resolvedURL;
    }
}
static NSString *MediaJARBridgeExtractTxtMirrorURL(id candidate) {
    if([candidate isKindOfClass:NSArray.class]){
        for(id item in (NSArray *)candidate){
            NSString *u=MediaJARBridgeExtractTxtMirrorURL(item);
            if(u.length)return u;
        }
        return @"";
    }
    if([candidate isKindOfClass:NSDictionary.class]){
        NSDictionary *dict=(NSDictionary *)candidate;
        return MediaJARBridgeExtractTxtMirrorURL(@[dict[@"url"]?:@"",dict[@"host"]?:@"",dict[@"site"]?:@""]);
    }
    if(![candidate isKindOfClass:NSString.class])return @"";
    NSCharacterSet *seps=[NSCharacterSet characterSetWithCharactersInString:@",; \t\r\n"];
    for(NSString *part in [(NSString *)candidate componentsSeparatedByCharactersInSet:seps]){
        NSString *trimmed=[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *low=trimmed.lowercaseString;
        if(([low hasPrefix:@"http://"]||[low hasPrefix:@"https://"])&&![low containsString:@"127.0.0.1:9978"]&&[low hasSuffix:@".txt"]){
            return trimmed;
        }
    }
    return @"";
}
static NSArray<NSString *> *MediaJARBridgeCandidateURLs(id candidate) {
    NSMutableArray<NSString *> *results=[NSMutableArray array];
    if([candidate isKindOfClass:NSArray.class]){
        for(id item in (NSArray *)candidate){
            for(NSString *u in MediaJARBridgeCandidateURLs(item)){
                if(![results containsObject:u])[results addObject:u];
            }
        }
        return results.copy;
    }
    if([candidate isKindOfClass:NSDictionary.class]){
        NSDictionary *dict=(NSDictionary *)candidate;
        return MediaJARBridgeCandidateURLs(@[dict[@"url"]?:@"",dict[@"host"]?:@"",dict[@"site"]?:@"",dict[@"api"]?:@"",dict[@"domain"]?:@"",dict[@"domains"]?:@""]);
    }
    if(![candidate isKindOfClass:NSString.class])return @[];
    NSString *rawStr=[(NSString *)candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!rawStr.length)return @[];
    if([rawStr hasPrefix:@"{"]||[rawStr hasPrefix:@"["]){
        NSData *jsonData=[rawStr dataUsingEncoding:NSUTF8StringEncoding];
        id jsonObj=jsonData?[NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL]:nil;
        if(jsonObj)return MediaJARBridgeCandidateURLs(jsonObj);
    }
    if(![rawStr.lowercaseString containsString:@"http://"]&&![rawStr.lowercaseString containsString:@"https://"]&&rawStr.length>=16&&rawStr.length<=4096){
        NSData *b64=[[NSData alloc] initWithBase64EncodedString:rawStr options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *dec=b64.length?[[NSString alloc] initWithData:b64 encoding:NSUTF8StringEncoding]:nil;
        if(dec.length&&([dec.lowercaseString containsString:@"http://"]||[dec.lowercaseString containsString:@"https://"])){
            rawStr=dec;
        }
    }
    NSCharacterSet *seps=[NSCharacterSet characterSetWithCharactersInString:@",;| \t\r\n\"'<>[]()"];
    for(NSString *part in [rawStr componentsSeparatedByCharactersInSet:seps]){
        NSString *trimmed=[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        while([trimmed hasSuffix:@"/"])trimmed=[trimmed substringToIndex:trimmed.length-1];
        NSString *low=trimmed.lowercaseString;
        if(![low hasPrefix:@"http://"]&&![low hasPrefix:@"https://"])continue;
        if([low containsString:@"127.0.0.1:9978"]||[low hasSuffix:@".json"]||[low hasSuffix:@".js"]||[low hasSuffix:@".py"]||[low hasSuffix:@".jar"]||[low hasSuffix:@".png"]||[low hasSuffix:@".jpg"])continue;
        if([low hasSuffix:@".txt"]){
            NSString *resolved=MediaJARBridgeLookupMirror(trimmed);
            if(resolved.length&&![results containsObject:resolved])[results addObject:resolved];
            continue;
        }
        for(NSString *suffix in @[@"/api.php/app",@"/api.php/provide/vod",@"/api.php/v1.vod",@"/app/bn"]){
            if([low hasSuffix:suffix]){trimmed=[trimmed substringToIndex:trimmed.length-suffix.length];break;}
        }
        while([trimmed hasSuffix:@"/"])trimmed=[trimmed substringToIndex:trimmed.length-1];
        if(trimmed.length&&![results containsObject:trimmed])[results addObject:trimmed];
    }
    return results.copy;
}
static NSString *MediaJARBridgeFirstValidURL(id candidate) {
    return MediaJARBridgeCandidateURLs(candidate).firstObject?:@"";
}
static NSMutableDictionary<NSString *,NSString *> *MediaJARBridgeWorkingBaseMap(void) {
    static NSMutableDictionary<NSString *,NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{map=[NSMutableDictionary dictionary];});
    return map;
}
static NSString *MediaJARBridgeSourceCacheKey(NSDictionary *source) {
    NSString *sid=MediaTVBoxFirstString(source,@[@"id",@"key",@"name",@"api"]);
    return sid.length?sid:@"default";
}
static void MediaJARBridgeSaveWorkingBase(NSDictionary *source,NSString *base) {
    if(!source||!base.length)return;
    NSString *key=MediaJARBridgeSourceCacheKey(source);
    @synchronized(MediaJARBridgeWorkingBaseMap()){MediaJARBridgeWorkingBaseMap()[key]=base;}
}
static NSArray<NSString *> *MediaJARBridgeCandidatesForSource(NSDictionary *source) {
    id rawOptions=source[@"options"];
    NSDictionary *cfg=MediaJARBridgeJSONDictionary(rawOptions);
    NSMutableArray<NSString *> *list=[NSMutableArray array];
    NSString *key=MediaJARBridgeSourceCacheKey(source);
    NSString *cached=nil;
    @synchronized(MediaJARBridgeWorkingBaseMap()){cached=MediaJARBridgeWorkingBaseMap()[key];}
    if(cached.length)[list addObject:cached];
    for(NSString *u in MediaJARBridgeCandidateURLs(@[cfg[@"url"]?:@"",cfg[@"host"]?:@"",cfg[@"site"]?:@"",rawOptions?:@""])){
        if(u.length&&![list containsObject:u])[list addObject:u];
    }
    return list.copy;
}
static NSURLRequest *MediaJARBridgeMacCMSFallbackRequest(NSString *cmsAPI,NSString *operation,NSDictionary *arguments) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:cmsAPI];
    NSMutableDictionary<NSString *,NSString *> *values=[NSMutableDictionary dictionary];
    if([operation isEqual:@"home"]){
        NSString *overrideAC=[arguments[@"_maccms_ac"] isKindOfClass:NSString.class]?arguments[@"_maccms_ac"]:@"";
        values[@"ac"]=overrideAC.length?overrideAC:@"videolist";
    }else if([operation isEqual:@"category"]){
        values[@"ac"]=@"videolist";
        NSString *tid=MediaTVBoxString(arguments[@"categoryId"]);
        if(tid.length)values[@"t"]=tid;
        values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
    }else if([operation isEqual:@"search"]){
        values[@"ac"]=@"videolist";
        values[@"wd"]=MediaTVBoxString(arguments[@"keyword"]);
        values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
    }else if([operation isEqual:@"detail"]){
        values[@"ac"]=@"detail";
        values[@"ids"]=MediaTVBoxString(arguments[@"id"]);
    }else if([operation isEqual:@"play"]){
        NSString *playID=MediaTVBoxString(arguments[@"id"]);
        if([playID hasPrefix:@"http://"]||[playID hasPrefix:@"https://"]){
            NSMutableURLRequest *directReq=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:playID] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
            directReq.HTTPMethod=@"GET";
            [directReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
            return directReq;
        }
        values[@"ac"]=@"detail";
        values[@"ids"]=playID;
    }
    NSMutableArray *query=[NSMutableArray array];
    for(NSString *key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        [query addObject:[NSURLQueryItem queryItemWithName:key value:values[key]?:@""]];
    }
    parts.queryItems=query;
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:parts.URL?:[NSURL URLWithString:cmsAPI] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    req.HTTPMethod=@"GET";
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json, application/xml, text/xml, */*" forHTTPHeaderField:@"Accept"];
    return req;
}
static NSData *MediaJARBridgeTryDecryptData(NSData *data,NSDictionary *source) {
    if(!data.length)return nil;
    NSDictionary *cfg=MediaJARBridgeJSONDictionary(source[@"options"]);
    NSString *keyStr=MediaTVBoxFirstString(cfg,@[@"dataKey",@"siteKey",@"key"]);
    NSString *ivStr=MediaTVBoxFirstString(cfg,@[@"dataIv",@"listKey",@"iv"]);
    if(!keyStr.length)return nil;
    if(!ivStr.length)ivStr=keyStr;
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    text=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!text.length)return nil;
    if([text hasPrefix:@"{"]){
        NSDictionary *outer=MediaJARBridgeJSONDictionary(text);
        if([outer[@"data"] isKindOfClass:NSString.class]&&[(NSString *)outer[@"data"] length]>24){
            text=[(NSString *)outer[@"data"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    }
    NSData *cipherData=[[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if(!cipherData.length)return nil;
    NSMutableArray<NSData *> *keyCandidates=[NSMutableArray array];
    NSData *utf8Key=[keyStr dataUsingEncoding:NSUTF8StringEncoding];
    if(utf8Key.length){
        NSMutableData *k16=[NSMutableData dataWithLength:kCCKeySizeAES128];
        memcpy(k16.mutableBytes,utf8Key.bytes,MIN(utf8Key.length,(NSUInteger)kCCKeySizeAES128));
        [keyCandidates addObject:k16];
        if(utf8Key.length>=kCCKeySizeAES256){
            NSMutableData *k32=[NSMutableData dataWithLength:kCCKeySizeAES256];
            memcpy(k32.mutableBytes,utf8Key.bytes,kCCKeySizeAES256);
            [keyCandidates addObject:k32];
        }
    }
    if(keyStr.length==32&&[keyStr rangeOfString:@"^[0-9A-Fa-f]{32}$" options:NSRegularExpressionSearch].location!=NSNotFound){
        NSMutableData *hexKey=[NSMutableData dataWithCapacity:16];
        for(NSUInteger i=0;i<32;i+=2){
            unsigned int byteVal=0;
            [[NSScanner scannerWithString:[keyStr substringWithRange:NSMakeRange(i,2)]] scanHexInt:&byteVal];
            uint8_t b=(uint8_t)byteVal;
            [hexKey appendBytes:&b length:1];
        }
        [keyCandidates addObject:hexKey];
    }
    NSMutableArray<NSData *> *ivCandidates=[NSMutableArray array];
    NSData *utf8IV=[ivStr dataUsingEncoding:NSUTF8StringEncoding];
    if(utf8IV.length){
        NSMutableData *iv16=[NSMutableData dataWithLength:kCCBlockSizeAES128];
        memcpy(iv16.mutableBytes,utf8IV.bytes,MIN(utf8IV.length,(NSUInteger)kCCBlockSizeAES128));
        [ivCandidates addObject:iv16];
    }
    NSData *b64IV=[[NSData alloc] initWithBase64EncodedString:ivStr options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if(b64IV.length>=8){
        NSMutableData *iv16=[NSMutableData dataWithLength:kCCBlockSizeAES128];
        memcpy(iv16.mutableBytes,b64IV.bytes,MIN(b64IV.length,(NSUInteger)kCCBlockSizeAES128));
        [ivCandidates addObject:iv16];
    }
    size_t bufferSize=cipherData.length+kCCBlockSizeAES128;
    void *buffer=malloc(bufferSize);
    if(!buffer)return nil;
    for(NSData *kData in keyCandidates){
        for(NSData *iData in ivCandidates){
            size_t numBytesDecrypted=0;
            CCCryptorStatus status=CCCrypt(kCCDecrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding,kData.bytes,kData.length,iData.bytes,cipherData.bytes,cipherData.length,buffer,bufferSize,&numBytesDecrypted);
            if(status==kCCSuccess&&numBytesDecrypted>0){
                const uint8_t *bytes=(const uint8_t *)buffer;
                if(bytes[0]=='{'||bytes[0]=='['){
                    return [NSData dataWithBytesNoCopy:buffer length:numBytesDecrypted freeWhenDone:YES];
                }
            }
        }
        size_t ecbDecrypted=0;
        CCCryptorStatus ecbStatus=CCCrypt(kCCDecrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding|kCCOptionECBMode,kData.bytes,kData.length,NULL,cipherData.bytes,cipherData.length,buffer,bufferSize,&ecbDecrypted);
        if(ecbStatus==kCCSuccess&&ecbDecrypted>0){
            const uint8_t *bytes=(const uint8_t *)buffer;
            if(bytes[0]=='{'||bytes[0]=='['){
                return [NSData dataWithBytesNoCopy:buffer length:ecbDecrypted freeWhenDone:YES];
            }
        }
    }
    free(buffer);
    return nil;
}
static NSURLRequest *MediaJARBridgeRequest(NSDictionary *source,NSString *operation,NSDictionary *arguments,NSError **error) {
    NSString *api=MediaTVBoxString(source[@"api"]);
    NSString *siteName=MediaTVBoxString(source[@"name"]).length?MediaTVBoxString(source[@"name"]):api;
    NSString *lowAPI=api.lowercaseString;
    if([lowAPI isEqual:@"csp_sp360"])return MediaSP360Request(operation,arguments,error);
    id rawOptions=source[@"options"];
    NSDictionary *cfg=MediaJARBridgeJSONDictionary(rawOptions);
    NSArray<NSString *> *candidates=MediaJARBridgeCandidatesForSource(source);
    NSUInteger siteIdx=[arguments[@"_jar_site_index"] respondsToSelector:@selector(unsignedIntegerValue)]?[arguments[@"_jar_site_index"] unsignedIntegerValue]:0;
    NSString *base=candidates.count?candidates[MIN(siteIdx,candidates.count-1)]:@"";
    if([arguments[@"_jar_fallback"] boolValue]){
        if(!base.length){
            if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」（%@）未提供可直连的接口地址（ext 为空），已关闭统一采集兜底以真实反馈站点状态",siteName,api]}];
            return nil;
        }
        NSString *sameHostCMS=[base.lowercaseString hasSuffix:@".php"]?base:[base stringByAppendingString:@"/api.php/provide/vod/"];
        return MediaJARBridgeMacCMSFallbackRequest(sameHostCMS,operation,arguments);
    }
    NSString *urlStr=@"";
    if([lowAPI containsString:@"xbpq"]||[lowAPI containsString:@"xyqhiker"]||[lowAPI containsString:@"music1"]){
        NSString *catTpl=MediaTVBoxString(cfg[@"分类url"]?:cfg[@"首页url"]?:cfg[@"url"]);
        if(!catTpl.length&&![operation isEqual:@"play"]){
            if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」（%@）配置中缺少直接可请求的 分类url/首页url（ext=%@）",siteName,api,[rawOptions description]?:@"空"]}];
            return nil;
        }
        if([operation isEqual:@"home"]||[operation isEqual:@"category"]){
            NSString *tpl=catTpl;
            NSString *tid=MediaTVBoxString(arguments[@"categoryId"]);if(!tid.length)tid=@"1";
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[[[tpl stringByReplacingOccurrencesOfString:@"{cateId}" withString:tid] stringByReplacingOccurrencesOfString:@"{catePg}" withString:pg] stringByReplacingOccurrencesOfString:@"{pg}" withString:pg];
            NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"\\{[a-zA-Z0-9_]+\\}" options:0 error:NULL];
            if(re&&urlStr.length)urlStr=[re stringByReplacingMatchesInString:urlStr options:0 range:NSMakeRange(0,urlStr.length) withTemplate:@""];
        } else if([operation isEqual:@"search"]){
            NSString *tpl=MediaTVBoxString(cfg[@"搜索url"]?:cfg[@"search_url"]);
            if(!tpl.length){
                if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」（%@）未配置搜索接口地址（搜索url 为空）",siteName,api]}];
                return nil;
            }
            NSString *kw=MediaParserEncodeValue(MediaTVBoxString(arguments[@"keyword"]));
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[[[tpl stringByReplacingOccurrencesOfString:@"{wd}" withString:kw] stringByReplacingOccurrencesOfString:@"**" withString:kw] stringByReplacingOccurrencesOfString:@"{pg}" withString:pg];
        } else if([operation isEqual:@"detail"]||[operation isEqual:@"play"]){
            urlStr=MediaTVBoxString(arguments[@"id"]);
            if(![urlStr hasPrefix:@"http://"]&&![urlStr hasPrefix:@"https://"]){
                if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」详情/播放地址无效：%@",siteName,urlStr]}];
                return nil;
            }
        }
    } else if([lowAPI containsString:@"bili"]){
        if([operation isEqual:@"home"]){
            urlStr=@"https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1";
        } else if([operation isEqual:@"category"]){
            NSString *tid=MediaParserEncodeValue(MediaTVBoxString(arguments[@"categoryId"]));
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=%@&page=%@",tid.length?tid:@"番剧",pg];
        } else if([operation isEqual:@"search"]){
            NSString *kw=MediaParserEncodeValue(MediaTVBoxString(arguments[@"keyword"]));
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=%@&page=%@",kw,pg];
        } else if([operation isEqual:@"detail"]||[operation isEqual:@"play"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            urlStr=[vid hasPrefix:@"http"]?vid:[NSString stringWithFormat:@"https://www.bilibili.com/video/%@",vid];
        }
    } else if(([lowAPI containsString:@"panweb"]||[lowAPI containsString:@"wogg"])&&base.length){
        if([operation isEqual:@"home"]){
            urlStr=[base stringByAppendingString:@"/index.php/vod/show/id/1/page/1.html"];
        } else if([operation isEqual:@"category"]){
            NSString *tid=MediaTVBoxString(arguments[@"categoryId"]);if(!tid.length)tid=@"1";
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"%@/index.php/vod/show/id/%@/page/%@.html",base,tid,pg];
        } else if([operation isEqual:@"search"]){
            NSString *kw=MediaParserEncodeValue(MediaTVBoxString(arguments[@"keyword"]));
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"%@/index.php/vod/search/page/%@/wd/%@.html",base,pg,kw];
        } else if([operation isEqual:@"detail"]||[operation isEqual:@"play"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            urlStr=[vid hasPrefix:@"http"]?vid:[NSString stringWithFormat:@"%@/index.php/vod/detail/id/%@.html",base,vid];
        }
    } else {
        if(!base.length){
            NSString *txtMirror=MediaJARBridgeExtractTxtMirrorURL(@[cfg[@"url"]?:@"",cfg[@"host"]?:@"",cfg[@"site"]?:@"",rawOptions?:@""]);
            NSString *reasonMsg=txtMirror.length?[NSString stringWithFormat:@"站点「%@」（%@）动态域名配置（%@）未能解析出有效接口地址，请检查网络或切换站点",siteName,api,txtMirror.lastPathComponent]:[NSString stringWithFormat:@"站点「%@」（%@）属于 Android JAR 封闭爬虫且未在合集 ext 中提供独立接口地址（ext 为空），无法在 iOS 上直连",siteName,api];
            if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:2 userInfo:@{NSLocalizedDescriptionKey:reasonMsg}];
            return nil;
        }
        if([base.lowercaseString hasSuffix:@".php"]){
            return MediaJARBridgeMacCMSFallbackRequest(base,operation,arguments);
        }
        if([operation isEqual:@"home"]){
            urlStr=[base stringByAppendingString:@"/api.php/app/nav"];
        } else if([operation isEqual:@"category"]){
            NSString *tid=MediaTVBoxString(arguments[@"categoryId"]);if(!tid.length)tid=@"1";
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"%@/api.php/app/video?tid=%@&pg=%@&limit=20",base,tid,pg];
        } else if([operation isEqual:@"search"]){
            NSString *kw=MediaParserEncodeValue(MediaTVBoxString(arguments[@"keyword"]));
            NSString *pg=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
            urlStr=[NSString stringWithFormat:@"%@/api.php/app/video?text=%@&pg=%@",base,kw,pg];
        } else if([operation isEqual:@"detail"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            urlStr=[NSString stringWithFormat:@"%@/api.php/app/video_detail?id=%@",base,vid];
        } else if([operation isEqual:@"play"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            urlStr=[vid hasPrefix:@"http"]?vid:[NSString stringWithFormat:@"%@/api.php/app/video_url?url=%@",base,vid];
        }
    }
    NSURL *url=urlStr.length?[NSURL URLWithString:urlStr]:nil;
    if(!url){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostJARBridge" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」（%@）生成的请求地址无效：%@",siteName,api,urlStr]}];
        return nil;
    }
    NSMutableURLRequest *req=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    req.HTTPMethod=@"GET";
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json, text/html, */*" forHTTPHeaderField:@"Accept"];
    if([lowAPI containsString:@"bili"])[req setValue:@"https://www.bilibili.com/" forHTTPHeaderField:@"Referer"];
    return req;
}
static NSDictionary *MediaJARBridgeBuildPlayResult(NSString *url,NSDictionary *source,NSDictionary *extraHeaders) {
    NSString *clean=[url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    clean=[clean stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    NSMutableDictionary *headers=[MediaTVBoxPlaybackHeaders(source,extraHeaders?:@{}) mutableCopy];
    NSDictionary *probe=@{@"url":clean?:@""};
    BOOL isDirect=MediaPlaybackResultIsDirectMedia(probe)||MediaTVBoxURLHasSignedQuery(clean);
    BOOL isNative=isDirect||MediaPlaybackResultSupportsNativePlayback(probe);
    BOOL cicada=MediaPlaybackResultSupportsCicada(probe);
    NSMutableDictionary *res=[@{
        @"url":clean?:@"",
        @"originalURL":clean?:@"",
        @"directMedia":@(isDirect),
        @"nativePlayable":@(isNative),
        @"parse":@(!isNative),
        @"jx":@(!isNative),
        @"requiresWebPlayback":@(!isNative),
        @"playbackEngine":cicada?@"cicada":@"avplayer"
    } mutableCopy];
    if(headers.count)res[@"headers"]=headers.copy;
    return res.copy;
}
static id MediaJARBridgeNormalize(NSString *operation,NSDictionary *arguments,NSDictionary *source,id raw) {
    if([operation isEqual:@"capabilities"])return @{@"engine":@"站点接口适配 · 待读取验证",@"protocol":@"jar-bridge",@"capabilities":@[@"home",@"category",@"search",@"detail",@"play"]};
    if([operation isEqual:@"providers"])return @[@{@"id":@"",@"name":source[@"name"]?:@"JAR 站点"}];
    NSString *api=MediaTVBoxString(source[@"api"]).lowercaseString;
    if([api isEqual:@"csp_sp360"])return MediaSP360Normalize(operation,arguments,raw);
    id rawOptions=source[@"options"];
    NSDictionary *cfg=MediaJARBridgeJSONDictionary(rawOptions);
    if([api containsString:@"bili"]){
        NSDictionary *root=MediaTVBoxObject(raw);
        NSDictionary *dataObj=MediaTVBoxObject(root[@"data"]);
        NSArray *rows=MediaTVBoxArray(dataObj[@"list"]?:dataObj[@"result"]);
        NSMutableArray *items=[NSMutableArray array];
        for(id rowVal in rows){
            NSDictionary *row=MediaTVBoxObject(rowVal);
            NSString *bvid=MediaTVBoxFirstString(row,@[@"bvid",@"aid",@"id"]);
            NSString *title=MediaTVBoxFirstString(row,@[@"title",@"name"]);
            title=[[title stringByReplacingOccurrencesOfString:@"<em class=\"keyword\">" withString:@""] stringByReplacingOccurrencesOfString:@"</em>" withString:@""];
            NSString *pic=MediaTVBoxFirstString(row,@[@"pic",@"cover"]);
            if([pic hasPrefix:@"//"])pic=[@"https:" stringByAppendingString:pic];
            if(bvid.length&&title.length)[items addObject:@{@"id":bvid,@"name":title,@"poster":pic?:@""}];
        }
        if([operation isEqual:@"home"]){
            NSArray *cats=@[@{@"id":@"番剧",@"name":@"番剧"},@{@"id":@"国创",@"name":@"国创"},@{@"id":@"纪录片",@"name":@"纪录片"},@{@"id":@"电影",@"name":@"电影"},@{@"id":@"电视剧",@"name":@"电视剧"}];
            NSDictionary *flt=[NSDictionary dictionary];
            return @{@"categories":cats,@"items":items,@"filters":flt};
        }
        if([operation isEqual:@"category"]||[operation isEqual:@"search"]){
            NSInteger page=MAX(1,[arguments[@"page"] integerValue]);
            return @{@"items":items,@"page":@(page),@"hasMore":@(items.count>=10)};
        }
        if([operation isEqual:@"detail"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            NSString *playURL=[vid hasPrefix:@"http"]?vid:[NSString stringWithFormat:@"https://www.bilibili.com/video/%@",vid];
            return @{@"id":vid,@"name":source[@"name"]?:@"B站视频",@"lines":@[@{@"id":@"bili",@"name":@"B站线路",@"episodes":@[@{@"id":playURL,@"name":@"正片"}]}]};
        }
        if([operation isEqual:@"play"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            NSString *playURL=[vid hasPrefix:@"http"]?vid:[NSString stringWithFormat:@"https://www.bilibili.com/video/%@",vid];
            return @{@"url":playURL,@"originalURL":playURL,@"parse":@1,@"jx":@1,@"requiresWebPlayback":@YES,@"headers":@{@"Referer":@"https://www.bilibili.com/"}};
        }
    }
    if([operation isEqual:@"play"]){
        if([raw isKindOfClass:NSDictionary.class]){
            NSDictionary *found=MediaParserObjectWithURL(raw,0);
            NSString *foundURL=[found[@"url"] isKindOfClass:NSString.class]?found[@"url"]:@"";
            if(foundURL.length)return MediaJARBridgeBuildPlayResult(foundURL,source,found);
        }
        NSString *html=[raw isKindOfClass:NSString.class]?raw:([raw isKindOfClass:NSData.class]?[[NSString alloc] initWithData:(NSData *)raw encoding:NSUTF8StringEncoding]:@"");
        if(html.length){
            NSString *unescaped=[html stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            NSDictionary *found=MediaParserObjectWithURL(unescaped,0);
            NSString *foundURL=[found[@"url"] isKindOfClass:NSString.class]?found[@"url"]:@"";
            if(foundURL.length)return MediaJARBridgeBuildPlayResult(foundURL,source,nil);
        }
        NSString *argURL=MediaTVBoxString(arguments[@"id"]);
        if(argURL.length)return MediaJARBridgeBuildPlayResult(argURL,source,nil);
    }
    if(![raw isKindOfClass:NSDictionary.class]){
        NSString *html=[raw isKindOfClass:NSString.class]?raw:([raw isKindOfClass:NSData.class]?[[NSString alloc] initWithData:(NSData *)raw encoding:NSUTF8StringEncoding]:@"");
        NSArray<NSString *> *candidates=MediaJARBridgeCandidateURLs(@[cfg[@"url"]?:@"",cfg[@"host"]?:@"",cfg[@"site"]?:@"",rawOptions?:@""]);
        NSUInteger siteIdx=[arguments[@"_jar_site_index"] respondsToSelector:@selector(unsignedIntegerValue)]?[arguments[@"_jar_site_index"] unsignedIntegerValue]:0;
        NSString *baseHost=candidates.count?candidates[MIN(siteIdx,candidates.count-1)]:@"";
        NSArray *(^parseHTMLItems)(NSString *)=^NSArray *(NSString *pageHTML){
            if(!pageHTML.length)return @[];
            NSMutableArray *parsed=[NSMutableArray array];
            NSMutableSet *seen=[NSMutableSet set];
            NSString *arrRule=MediaTVBoxString(cfg[@"分类数组"]);
            NSString *sep=arrRule.length?[arrRule componentsSeparatedByString:@"&&"].firstObject:([pageHTML containsString:@"module-item"]?@"module-item":@"<li");
            NSArray *chunks=[pageHTML componentsSeparatedByString:sep];
            if(chunks.count<=2)chunks=[pageHTML componentsSeparatedByString:@"<a "];
            for(NSUInteger i=1;i<MIN(chunks.count,(NSUInteger)45);i++){
                NSString *chunk=chunks[i];
                NSString *title=@"";
                for(NSString *attr in @[@"title=\"",@"alt=\""]){
                    NSRange r=[chunk rangeOfString:attr];
                    if(r.location!=NSNotFound){
                        NSString *rest=[chunk substringFromIndex:NSMaxRange(r)];
                        NSRange endQ=[rest rangeOfString:@"\""];
                        if(endQ.location!=NSNotFound){title=[rest substringToIndex:endQ.location];if(title.length)break;}
                    }
                }
                NSString *link=@"";
                NSRange hrefR=[chunk rangeOfString:@"href=\""];
                if(hrefR.location!=NSNotFound){
                    NSString *rest=[chunk substringFromIndex:NSMaxRange(hrefR)];
                    NSRange endQ=[rest rangeOfString:@"\""];
                    if(endQ.location!=NSNotFound)link=[rest substringToIndex:endQ.location];
                }
                if([link hasPrefix:@"javascript"]||[link isEqualToString:@"#"]||[link isEqualToString:@"/"])continue;
                if([link hasPrefix:@"/"]&&baseHost.length)link=[baseHost stringByAppendingString:link];
                NSString *pic=@"";
                for(NSString *pAttr in @[@"data-src=\"",@"data-original=\"",@"src=\""]){
                    NSRange srcR=[chunk rangeOfString:pAttr];
                    if(srcR.location!=NSNotFound){
                        NSString *rest=[chunk substringFromIndex:NSMaxRange(srcR)];
                        NSRange endQ=[rest rangeOfString:@"\""];
                        if(endQ.location!=NSNotFound){pic=[rest substringToIndex:endQ.location];if(pic.length)break;}
                    }
                }
                if([pic hasPrefix:@"//"])pic=[@"https:" stringByAppendingString:pic];
                else if([pic hasPrefix:@"/"]&&baseHost.length)pic=[baseHost stringByAppendingString:pic];
                if(title.length&&link.length&&![seen containsObject:link]){
                    [seen addObject:link];
                    [parsed addObject:@{@"id":link,@"name":title,@"poster":pic?:@""}];
                }
            }
            return parsed.copy;
        };
        if([operation isEqual:@"home"]){
            NSMutableArray *cats=[NSMutableArray array];
            NSString *rawCats=MediaTVBoxString(cfg[@"分类"]);
            if(rawCats.length){
                for(NSString *item in [rawCats componentsSeparatedByString:@"#"]){
                    NSRange r=[item rangeOfString:@"$"];
                    if(r.location!=NSNotFound){
                        NSString *name=[item substringToIndex:r.location];
                        NSString *tid=[item substringFromIndex:NSMaxRange(r)];
                        [cats addObject:@{@"id":tid,@"name":name}];
                    }
                }
            }
            if(!cats.count)[cats addObjectsFromArray:@[@{@"id":@"1",@"name":@"精选"},@{@"id":@"2",@"name":@"电影"},@{@"id":@"3",@"name":@"连续剧"},@{@"id":@"4",@"name":@"动漫"}]];
            NSArray *items=parseHTMLItems(html);
            NSDictionary *flt=[NSDictionary dictionary];return @{@"categories":cats,@"items":items,@"filters":flt};
        }
        if([operation isEqual:@"category"]||[operation isEqual:@"search"]){
            NSArray *items=parseHTMLItems(html);
            NSInteger page=MAX(1,[arguments[@"page"] integerValue]);
            return @{@"items":items,@"page":@(page),@"hasMore":@(items.count>=10)};
        }
        if([operation isEqual:@"detail"]){
            NSString *vid=MediaTVBoxString(arguments[@"id"]);
            NSString *title=source[@"name"]?:@"影片详情";
            NSMutableArray *episodes=[NSMutableArray array];
            if(html.length){
                NSURL *baseURL=[NSURL URLWithString:vid];
                NSArray *aChunks=[html componentsSeparatedByString:@"<a "];
                for(NSUInteger i=1;i<MIN(aChunks.count,(NSUInteger)120);i++){
                    NSString *chunk=aChunks[i];
                    NSRange hrefR=[chunk rangeOfString:@"href=\""];
                    if(hrefR.location==NSNotFound)continue;
                    NSString *rest=[chunk substringFromIndex:NSMaxRange(hrefR)];
                    NSRange endQ=[rest rangeOfString:@"\""];
                    if(endQ.location==NSNotFound)continue;
                    NSString *href=[rest substringToIndex:endQ.location];
                    if(![href containsString:@"/play"]&&![href containsString:@".m3u8"]&&![href containsString:@".mp4"]&&![href containsString:@"vod"])continue;
                    NSRange closeBracket=[rest rangeOfString:@">"];
                    NSRange closeTag=[rest rangeOfString:@"</a>"];
                    NSString *epName=@"";
                    if(closeBracket.location!=NSNotFound&&closeTag.location!=NSNotFound&&closeTag.location>closeBracket.location){
                        epName=[[rest substringWithRange:NSMakeRange(NSMaxRange(closeBracket),closeTag.location-NSMaxRange(closeBracket))] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    }
                    if([href hasPrefix:@"/"]&&baseURL.scheme.length&&baseURL.host.length){
                        href=[NSString stringWithFormat:@"%@://%@%@",baseURL.scheme,baseURL.host,href];
                    }
                    if(href.length)[episodes addObject:@{@"id":href,@"name":epName.length?epName:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)episodes.count+1]}];
                }
            }
            if(!episodes.count)[episodes addObject:@{@"id":vid.length?vid:@"https://example.com/play.m3u8",@"name":@"第 1 集"}];
            return @{@"id":vid,@"name":title,@"lines":@[@{@"id":@"line1",@"name":@"默认线路",@"episodes":episodes}]};
        }
    }
    NSMutableDictionary *delegatedSource=[source mutableCopy]?:[NSMutableDictionary dictionary];
    delegatedSource[@"protocol"]=@"tvbox-api";
    delegatedSource[@"_jarBridge"]=@YES;
    id normalized=MediaTVBoxNormalize(operation,arguments,delegatedSource,raw);
    if([operation isEqual:@"home"]&&[normalized isKindOfClass:NSDictionary.class]){
        NSString *combined=[[NSString stringWithFormat:@"%@ %@ %@",api,source[@"name"]?:@"",source[@"catalogName"]?:@""] lowercaseString];
        BOOL isAdult=[combined containsString:@"adultdj"]||[combined containsString:@"2048"]||[combined containsString:@"成人"]||[combined containsString:@"野果"]||[combined containsString:@"橙果"]||[combined containsString:@"吃瓜"]||[combined containsString:@"chigua"]||[combined containsString:@"伦理"]||[combined containsString:@"🔞"];
        BOOL isDrama=!isAdult&&([combined containsString:@"dj"]||[combined containsString:@"短剧"]||[combined containsString:@"duanju"]||[combined containsString:@"七猫"]||[combined containsString:@"围观"]||[combined containsString:@"好看"]||[combined containsString:@"喜番"]);
        if(isAdult||isDrama){
            NSArray *cats=[normalized[@"categories"] isKindOfClass:NSArray.class]?normalized[@"categories"]:@[];
            if(cats.count>1){
                NSMutableArray *preferred=[NSMutableArray array],*others=[NSMutableArray array];
                NSArray *keywords=isAdult?@[@"福利",@"伦理",@"写真",@"热舞",@"短剧",@"解说"]:@[@"短剧",@"爽文",@"都市",@"女频",@"反转",@"古装",@"脑洞",@"年代"];
                for(NSDictionary *cat in cats){
                    NSString *cname=[cat[@"name"] isKindOfClass:NSString.class]?cat[@"name"]:@"";
                    BOOL match=NO;
                    for(NSString *kw in keywords){if([cname containsString:kw]){match=YES;break;}}
                    if(match)[preferred addObject:cat];else[others addObject:cat];
                }
                if(preferred.count){
                    [preferred addObjectsFromArray:others];
                    NSMutableDictionary *mNorm=[normalized mutableCopy];
                    mNorm[@"categories"]=preferred.copy;
                    normalized=mNorm.copy;
                }
            }
        }
    }
    return normalized;
}
- (NSURLRequest *)tvboxRequestForOperation:(NSString *)operation arguments:(NSDictionary *)arguments error:(NSError **)error {
    if([self.tvboxSource[@"protocol"] isEqual:@"douban-index"])return MediaDoubanRequest(operation,arguments?:@{},error);
    if([self.tvboxSource[@"protocol"] isEqual:@"jar-bridge"])return MediaJARBridgeRequest(self.tvboxSource,operation,arguments?:@{},error);
    NSString *api=MediaTVBoxString(self.tvboxSource[@"api"]);NSURLComponents *parts=[NSURLComponents componentsWithString:api];
    if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length||api.length>8192){if(error)*error=[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:1 userInfo:@{NSLocalizedDescriptionKey:@"TVBox API 地址无效"}];return nil;}
    BOOL macCMS=[self.tvboxSource[@"protocol"] isEqual:@"maccms-api"];
    NSInteger type=[self.tvboxSource[@"tvboxType"] integerValue];
    BOOL cmsStyle=macCMS||(self.tvboxSource[@"tvboxType"]!=nil&&(type==0||type==1));
    NSMutableDictionary<NSString *,NSString *> *values=[NSMutableDictionary dictionary];
    if([operation isEqual:@"home"]){
        if(!macCMS&&type==4)values[@"filter"]=@"true";
        if(cmsStyle){
            NSString *overrideAC=[arguments[@"_maccms_ac"] isKindOfClass:NSString.class]?arguments[@"_maccms_ac"]:@"";
            values[@"ac"]=overrideAC.length?overrideAC:@"videolist";
        }
    }
    else if([operation isEqual:@"search"]){values[@"wd"]=MediaTVBoxString(arguments[@"keyword"]);if(!macCMS)values[@"quick"]=@"false";values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];if(cmsStyle)values[@"ac"]=@"videolist";}
    else if([operation isEqual:@"category"]){values[@"ac"]=cmsStyle?@"videolist":@"detail";values[@"t"]=MediaTVBoxString(arguments[@"categoryId"]);values[@"pg"]=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];NSDictionary *filters=[arguments[@"filters"] isKindOfClass:NSDictionary.class]?arguments[@"filters"]:@{};for(id key in filters){id value=filters[key];if([key isKindOfClass:NSString.class]&&[key length]<=128&&![MediaTVBoxReservedFilterKeys() containsObject:[key lowercaseString]]&&([value isKindOfClass:NSString.class]||[value isKindOfClass:NSNumber.class])&&[value description].length<=512)values[key]=[value description];}}
    else if([operation isEqual:@"detail"]){values[@"ac"]=@"detail";values[@"ids"]=MediaTVBoxString(arguments[@"id"]);}
    else if([operation isEqual:@"play"]){values[@"play"]=MediaTVBoxString(arguments[@"id"]);values[@"flag"]=MediaTVBoxString(arguments[@"lineId"]);}
    NSString *extend=MediaTVBoxString(self.tvboxSource[@"options"]);if(extend.length)values[@"extend"]=extend;
    NSMutableArray *query=[NSMutableArray array];for(NSURLQueryItem *item in parts.queryItems?:@[])if(!values[item.name])[query addObject:item];for(NSString *key in [values.allKeys sortedArrayUsingSelector:@selector(compare:)])[query addObject:[NSURLQueryItem queryItemWithName:key value:values[key]?:@""]];parts.queryItems=query;
    NSURL *url=parts.URL;if(!url||url.absoluteString.length>16384){if(error)*error=[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:2 userInfo:@{NSLocalizedDescriptionKey:@"TVBox API 请求地址无效或过长"}];return nil;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];request.HTTPMethod=@"GET";
    NSDictionary *headers=[self.tvboxSource[@"header"] isKindOfClass:NSDictionary.class]?self.tvboxSource[@"header"]:@{};NSUInteger count=0;for(id rawKey in headers){if(count++>=24)break;if(![rawKey isKindOfClass:NSString.class]||![headers[rawKey] isKindOfClass:NSString.class])continue;NSString *key=rawKey,*value=headers[key];if(!MediaTVBoxHeaderAllowed(key,value))continue;[request setValue:value forHTTPHeaderField:key];}
    if(![request valueForHTTPHeaderField:@"User-Agent"])[request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:cmsStyle?@"application/json, application/xml, text/xml, */*":@"application/json, */*" forHTTPHeaderField:@"Accept"];return request;
}
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id,NSError *))completion {
    [self call:operation arguments:arguments correlationID:nil completion:completion];
}
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments correlationID:(NSString *)correlationID completion:(void (^)(id,NSError *))completion {
    // NSAssert 只在 Debug 生效：Release 下后台线程调用会直接跑下去并触碰主线程状态，
    // 改为切回主队列重调（一次性异步派发，不形成保留环）。
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self call:operation arguments:arguments correlationID:correlationID completion:completion];});return;}
    [self cancelWithReason:@"superseded_by_new_request"];
    self.selectedParserID=[arguments[@"parserID"] isKindOfClass:NSString.class]?arguments[@"parserID"]:@"";
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

    BOOL macCMS=[self.tvboxSource[@"protocol"] isEqual:@"maccms-api"],doubanIndex=[self.tvboxSource[@"protocol"] isEqual:@"douban-index"],jarBridge=[self.tvboxSource[@"protocol"] isEqual:@"jar-bridge"];
    NSString *playArgID=MediaTVBoxString(arguments[@"id"]);
    BOOL jarDirectPlay=jarBridge&&([[self.tvboxSource[@"api"] lowercaseString] containsString:@"bili"]||[[self.tvboxSource[@"api"] lowercaseString] isEqual:@"csp_sp360"]||MediaPlaybackResultIsDirectMedia(@{@"url":playArgID})||MediaTVBoxURLHasSignedQuery(playArgID));
    BOOL localBiliDetail=jarBridge&&[operation isEqual:@"detail"]&&[[self.tvboxSource[@"api"] lowercaseString] containsString:@"bili"];
    BOOL localDirectPlay=[operation isEqual:@"play"]&&(macCMS||doubanIndex||jarDirectPlay||[self.tvboxSource[@"tvboxType"] integerValue]==1||(self.tvboxSource[@"tvboxType"]!=nil&&[self.tvboxSource[@"tvboxType"] integerValue]==0));
    BOOL localTVBoxOperation=self.tvboxSource&&([operation isEqual:@"capabilities"]||[operation isEqual:@"providers"]||localDirectPlay||localBiliDetail||(doubanIndex&&[operation isEqual:@"detail"]));
    if(localTVBoxOperation){
        id direct=MediaTVBoxNormalize(operation,arguments?:@{},self.tvboxSource,@{});
        NSDictionary *directDictionary=[direct isKindOfClass:NSDictionary.class]?direct:nil;
        NSString *directMessage=[directDictionary[@"error"] isKindOfClass:NSString.class]?directDictionary[@"error"]:nil;
        NSError *directError=directMessage.length?[NSError errorWithDomain:@"CCTVHostTVBoxAPI" code:3 userInfo:@{NSLocalizedDescriptionKey:directMessage}]:nil;
        NSString *resultType=direct?NSStringFromClass([direct class]):@"none";
        if(diagnosticsEnabled){NSMutableDictionary *fields=[@{@"request_id":requestID,@"operation":operation?:@"unknown",@"port":@(self.port),@"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-startedAt)*1000)),@"http_status":@0,@"result_type":resultType,@"result_shape":resultType,@"result_has_media_url":@([directDictionary[@"url"] isKindOfClass:NSString.class]&&[directDictionary[@"url"] length]>0),@"failure_stage":directError?@"direct_url_missing":@"none",@"protocol":self.tvboxSource[@"protocol"]?:@"tvbox-api",@"error_domain":directError.domain?:@"",@"error_code":@(directError.code)} mutableCopy];if(correlationID.length)fields[@"correlation_id"]=correlationID;[RuntimeDiagnostics.shared recordEvent:directError?@"media_api_failed":@"media_api_succeeded" category:@"media_api" fields:fields];}
        self.activeRequestID=nil;self.activeCorrelationID=nil;self.activeOperation=nil;
        dispatch_async(dispatch_get_main_queue(),^{if(self.generation==generation)[self completeResult:directError?nil:direct error:directError operation:operation generation:generation correlationID:correlationID completion:completion];});
        return;
    }

    if(jarBridge&&![arguments[@"_jar_txt_resolved"] boolValue]){
        NSDictionary *jarCfg=MediaJARBridgeJSONDictionary(self.tvboxSource[@"options"]);
        NSArray<NSString *> *knownCandidates=MediaJARBridgeCandidateURLs(@[jarCfg[@"url"]?:@"",jarCfg[@"host"]?:@"",jarCfg[@"site"]?:@"",self.tvboxSource[@"options"]?:@""]);
        NSString *txtMirrorURL=knownCandidates.count?@"":MediaJARBridgeExtractTxtMirrorURL(@[jarCfg[@"url"]?:@"",jarCfg[@"host"]?:@"",jarCfg[@"site"]?:@"",self.tvboxSource[@"options"]?:@""]);
        NSURL *mirrorTarget=txtMirrorURL.length?[NSURL URLWithString:txtMirrorURL]:nil;
        if(mirrorTarget){
            NSMutableURLRequest *mirrorReq=[NSMutableURLRequest requestWithURL:mirrorTarget cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
            [mirrorReq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
            __weak typeof(self) weakMirrorSelf=self;
            MediaAPIRequestContext *mirrorCtx=[MediaAPIRequestContext new];
            mirrorCtx.data=[NSMutableData data];
            mirrorCtx.processor=^(NSData *mData,NSURLResponse *mResp,NSError *mErr){
                MediaAPIClient *owner=weakMirrorSelf;
                if(!owner||owner.generation!=generation)return;
                if(!mErr&&mData.length){
                    NSString *mText=[[NSString alloc] initWithData:mData encoding:NSUTF8StringEncoding]?:@"";
                    NSString *resolved=MediaJARBridgeFirstValidURL(mText);
                    if(resolved.length)MediaJARBridgeSaveMirror(txtMirrorURL,resolved);
                }
                NSMutableDictionary *nextArgs=[arguments mutableCopy]?:[NSMutableDictionary dictionary];
                nextArgs[@"_jar_txt_resolved"]=@YES;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(owner.generation==generation)[owner call:operation arguments:nextArgs correlationID:correlationID completion:completion];
                });
            };
            self.task=[[self sessionForOperation:operation] dataTaskWithRequest:mirrorReq];
            [self.contextLock lock];
            self.requestContexts[@(self.task.taskIdentifier)]=mirrorCtx;
            [self.contextLock unlock];
            [self.task resume];
            return;
        }
    }
    NSError *requestError=nil;NSURL *url=nil;NSMutableURLRequest *request=nil;
    if(self.tvboxSource){request=[[self tvboxRequestForOperation:operation arguments:arguments?:@{} error:&requestError] mutableCopy];url=request.URL;}
    else{url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/api/v1/%@",(long)self.port,operation]];request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"POST";request.HTTPBody=[NSJSONSerialization dataWithJSONObject:arguments?:@{} options:0 error:NULL];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];[request setValue:requestID forHTTPHeaderField:@"X-CCTVHost-Request-ID"];if(correlationID.length)[request setValue:correlationID forHTTPHeaderField:@"X-CCTVHost-Correlation-ID"];}
    if(!request){NSError *failure=requestError?:[NSError errorWithDomain:@"CCTVHostMedia" code:5 userInfo:@{NSLocalizedDescriptionKey:@"无法创建资源请求"}];if(diagnosticsEnabled){NSMutableDictionary *fields=[@{@"request_id":requestID,@"operation":operation?:@"unknown",@"protocol":self.tvboxSource[@"protocol"]?:@"plugin",@"failure_stage":@"invalid_request",@"error_domain":failure.domain?:@"",@"error_code":@(failure.code),@"error_message":failure.localizedDescription?:@""} mutableCopy];if(correlationID.length)fields[@"correlation_id"]=correlationID;[RuntimeDiagnostics.shared recordEvent:@"media_api_failed" category:@"media_api" fields:fields];}self.activeRequestID=nil;self.activeCorrelationID=nil;self.activeOperation=nil;if(completion)completion(nil,failure);return;}
    request.timeoutInterval=[operation isEqual:@"play"]?self.playTimeoutMilliseconds/1000.0:self.requestTimeout;
    __weak typeof(self) weakSelf=self;
    // processor 存入 requestContexts（self 持有），块内再强引 self.tvboxSource/self.port
    // 会形成保留环（仅靠请求完成/40s 超时打破）；tvboxSource/port 初始化后不变，
    // 改为块前捕获局部值，彻底断开循环引用。
    NSDictionary *tvboxSource=self.tvboxSource;NSInteger port=self.port;
    void (^processor)(NSData *,NSURLResponse *,NSError *)=^(NSData *data,NSURLResponse *response,NSError *networkError){
        __block NSError *failure=networkError;
        id reply=nil;
        NSError *jsonError=nil;
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        NSString *pluginCode=@"";
        NSString *pluginMessage=@"";
        BOOL pluginRetryable=NO;
        NSString *failureStage=failure?@"network_or_timeout":@"none";
        if(!failure && data.length>[self maximumResponseBytes]){
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"资源服务响应超过 %lu MiB",(unsigned long)([self maximumResponseBytes]/(1024*1024))]}];
            failureStage=@"response_too_large";
        } else if(!failure && !data.length){
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:4 userInfo:@{NSLocalizedDescriptionKey:@"资源服务返回空响应"}];
            failureStage=@"empty_response";
        } else if(!failure){
            reply=MediaSanitizedJSONObjectWithData(data,&jsonError);
            if(jsonError&&[tvboxSource[@"protocol"] isEqual:@"jar-bridge"]){
                NSData *decrypted=MediaJARBridgeTryDecryptData(data,tvboxSource);
                if(decrypted.length){
                    jsonError=nil;
                    reply=MediaSanitizedJSONObjectWithData(decrypted,&jsonError);
                }
                if(!reply){
                    NSString *html=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if(!html){
                        NSStringEncoding gbk=CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
                        html=[[NSString alloc] initWithData:data encoding:gbk];
                    }
                    if(html.length){jsonError=nil;reply=html;}
                }
            }
            NSInteger srcType=[tvboxSource[@"tvboxType"] integerValue];
            BOOL allowXML=tvboxSource&&([tvboxSource[@"protocol"] isEqual:@"maccms-api"]||[tvboxSource[@"protocol"] isEqual:@"jar-bridge"]||(tvboxSource[@"tvboxType"]!=nil&&(srcType==0||srcType==1)));
            if(jsonError&&allowXML){jsonError=nil;reply=MediaCMSXMLObject(data,&jsonError);if(!reply&&jsonError){failure=jsonError;failureStage=@"invalid_xml";}}
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
        if(!failure && tvboxSource && [reply isKindOfClass:NSDictionary.class]){
            NSDictionary *rootPayload=MediaTVBoxObject(reply);NSDictionary *payload=([rootPayload[@"data"] isKindOfClass:NSDictionary.class]&&![rootPayload[@"list"] isKindOfClass:NSArray.class])?rootPayload[@"data"]:rootPayload;NSInteger apiCode=[rootPayload[@"code"] integerValue];NSString *apiMessage=MediaTVBoxFirstString(rootPayload,@[@"msg",@"message",@"errMsg"]);
            BOOL hasUsablePayload=[payload[@"list"] isKindOfClass:NSArray.class]||[payload[@"class"] isKindOfClass:NSArray.class]||([payload[@"data"] isKindOfClass:NSDictionary.class]&&payload[@"data"]!=NSNull.null)||MediaTVBoxString(payload[@"url"]).length>0||MediaTVBoxString(payload[@"playUrl"]).length>0;
            // CMS forks disagree on success codes. Treat code 0 as an error only
            // when an error message is present and the response carries no usable data.
            if(rootPayload[@"code"]&&apiCode==0&&apiMessage.length&&!hasUsablePayload){failure=[NSError errorWithDomain:@"CCTVHostCatalogAPI" code:apiCode userInfo:@{NSLocalizedDescriptionKey:apiMessage}];failureStage=@"catalog_api_error";}
        }
        if(!failure && !tvboxSource && !responseOK){
            NSString *message=pluginMessage.length?pluginMessage:@"资源未返回有效结果，请查看插件日志";
            NSMutableDictionary *info=[@{NSLocalizedDescriptionKey:message} mutableCopy];
            if(pluginCode.length)info[@"plugin_error_code"]=pluginCode;
            info[@"plugin_retryable"]=@(pluginRetryable);
            if([errorPayload[@"request_id"] isKindOfClass:NSString.class])info[@"service_request_id"]=errorPayload[@"request_id"];
            if([errorPayload[@"stage"] isKindOfClass:NSString.class])info[@"service_failure_stage"]=errorPayload[@"stage"];
            failure=[NSError errorWithDomain:@"CCTVHostMedia" code:2 userInfo:info];
            failureStage=errorPayload.count?@"plugin_error":@"invalid_response_shape";
        }
        id result=tvboxSource?MediaTVBoxNormalize(operation,arguments?:@{},tvboxSource,reply):([reply isKindOfClass:NSDictionary.class]?reply[@"data"]:nil);
        if(!failure&&[result isKindOfClass:NSDictionary.class]&&[result[@"error"] isKindOfClass:NSString.class]){failure=[NSError errorWithDomain:@"CCTVHostCatalogAPI" code:3 userInfo:@{NSLocalizedDescriptionKey:result[@"error"]}];failureStage=@"catalog_api_error";}
        if(diagnosticsEnabled){
        NSMutableDictionary *fields=[@{@"request_id":requestID,
                                        @"operation":operation?:@"unknown",
                                        @"port":@(port),
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
            if([tvboxSource[@"protocol"] isEqual:@"jar-bridge"]&&[operation isEqual:@"play"]&&failure){
                NSString *argID=MediaTVBoxString(arguments[@"id"]);
                if([argID hasPrefix:@"http://"]||[argID hasPrefix:@"https://"]){
                    NSDictionary *fallbackPlay=MediaJARBridgeBuildPlayResult(argID,tvboxSource,nil);
                    [client completeResult:fallbackPlay error:nil operation:operation generation:generation correlationID:correlationID completion:completion];
                    return;
                }
            }
            NSArray<NSString *> *jarCandidates=MediaJARBridgeCandidatesForSource(tvboxSource);
            NSUInteger jarSiteIdx=[arguments[@"_jar_site_index"] respondsToSelector:@selector(unsignedIntegerValue)]?[arguments[@"_jar_site_index"] unsignedIntegerValue]:0;
            NSString *jarBase=jarCandidates.count?jarCandidates[MIN(jarSiteIdx,jarCandidates.count-1)]:@"";
            BOOL jarResultMissing=failure||([result isKindOfClass:NSDictionary.class]&&(([operation isEqual:@"home"]&&![result[@"items"] count])||(([operation isEqual:@"category"]||[operation isEqual:@"search"])&&![result[@"items"] count])||([operation isEqual:@"detail"]&&![result[@"lines"] count])));
            if([tvboxSource[@"protocol"] isEqual:@"jar-bridge"]&&!jarResultMissing&&jarBase.length){
                MediaJARBridgeSaveWorkingBase(tvboxSource,jarBase);
            }
            BOOL jarEmptyResult=[tvboxSource[@"protocol"] isEqual:@"jar-bridge"]&&jarBase.length>0&&![jarBase.lowercaseString hasSuffix:@".php"]&&![arguments[@"_jar_fallback"] boolValue]&&![operation isEqual:@"play"]&&jarResultMissing;
            if(jarEmptyResult){
                NSMutableDictionary *fbArgs=[arguments mutableCopy]?:[NSMutableDictionary dictionary];
                fbArgs[@"_jar_fallback"]=@YES;
                [client call:operation arguments:fbArgs correlationID:correlationID completion:completion];
                return;
            }
            if([tvboxSource[@"protocol"] isEqual:@"jar-bridge"]&&![operation isEqual:@"play"]&&jarResultMissing&&jarSiteIdx+1<MIN(jarCandidates.count,(NSUInteger)6)){
                NSMutableDictionary *nextSiteArgs=[arguments mutableCopy]?:[NSMutableDictionary dictionary];
                [nextSiteArgs removeObjectForKey:@"_jar_fallback"];
                nextSiteArgs[@"_jar_site_index"]=@(jarSiteIdx+1);
                [client call:operation arguments:nextSiteArgs correlationID:correlationID completion:completion];
                return;
            }
            if([tvboxSource[@"protocol"] isEqual:@"jar-bridge"]&&!failure&&![operation isEqual:@"play"]&&[result isKindOfClass:NSDictionary.class]&&(([operation isEqual:@"home"]&&![result[@"items"] count])||([operation isEqual:@"detail"]&&![result[@"lines"] count]))){
                NSString *sName=MediaTVBoxString(tvboxSource[@"name"]).length?MediaTVBoxString(tvboxSource[@"name"]):MediaTVBoxString(tvboxSource[@"api"]);
                NSString *sHost=[NSURL URLWithString:jarBase].host?:jarBase;
                failure=[NSError errorWithDomain:@"CCTVHostJARBridge" code:4 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"站点「%@」（%@）未返回有效影视列表（远端返回了非标准 JSON/加密网页或源已失效）",sName,sHost.length?sHost:MediaTVBoxString(tvboxSource[@"api"])]}];
            }
            NSInteger srcType=[tvboxSource[@"tvboxType"] integerValue];
            BOOL cmsStyle=tvboxSource&&([tvboxSource[@"protocol"] isEqual:@"maccms-api"]||[tvboxSource[@"protocol"] isEqual:@"jar-bridge"]||(tvboxSource[@"tvboxType"]!=nil&&(srcType==0||srcType==1)));
            BOOL needsCategories=!failure&&cmsStyle&&[operation isEqual:@"home"]&&![arguments[@"_maccms_ac"] length]&&[result isKindOfClass:NSDictionary.class]&&![result[@"categories"] count];
            if(needsCategories){
                NSMutableDictionary *listArgs=[arguments mutableCopy]?:[NSMutableDictionary dictionary];
                listArgs[@"_maccms_ac"]=@"list";
                NSURLRequest *listReq=[client tvboxRequestForOperation:@"home" arguments:listArgs error:NULL];
                if(listReq){
                    MediaAPIRequestContext *listCtx=[MediaAPIRequestContext new];listCtx.data=[NSMutableData data];
                    listCtx.processor=^(NSData *listData,NSURLResponse *listResp,NSError *listErr){
                        NSMutableDictionary *merged=[result mutableCopy];
                        if(!listErr&&listData.length&&listData.length<=[client maximumResponseBytes]){
                            id listReply=MediaSanitizedJSONObjectWithData(listData,NULL)?:MediaCMSXMLObject(listData,NULL);
                            if([listReply isKindOfClass:NSDictionary.class]){
                                NSDictionary *listNorm=MediaTVBoxNormalize(@"home",listArgs,tvboxSource,listReply);
                                if([listNorm isKindOfClass:NSDictionary.class]&&[listNorm[@"categories"] count]){
                                    merged[@"categories"]=listNorm[@"categories"];
                                }
                            }
                        }
                        dispatch_async(dispatch_get_main_queue(),^{
                            MediaAPIClient *inner=weakSelf;
                            if(!inner||inner.generation!=generation)return;
                            inner.task=nil;
                            [inner completeResult:merged.copy error:nil operation:operation generation:generation correlationID:correlationID completion:completion];
                        });
                    };
                    client.task=[[client sessionForOperation:operation] dataTaskWithRequest:listReq];
                    [client.contextLock lock];client.requestContexts[@(client.task.taskIdentifier)]=listCtx;[client.contextLock unlock];
                    [client.task resume];
                    return;
                }
            }
            [client completeResult:result==NSNull.null?nil:result error:failure operation:operation generation:generation correlationID:correlationID completion:completion];
        });
    };
    MediaAPIRequestContext *requestContext=[MediaAPIRequestContext new];requestContext.data=[NSMutableData data];requestContext.processor=processor;
    self.task=[[self sessionForOperation:operation] dataTaskWithRequest:request];
    [self.contextLock lock];self.requestContexts[@(self.task.taskIdentifier)]=requestContext;[self.contextLock unlock];
    [self.task resume];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(dataTask.taskIdentifier)];if(context)context.response=response;[self.contextLock unlock];
    if(!context){completionHandler(NSURLSessionResponseCancel);return;}
    if(context.parserRequest&&[response isKindOfClass:NSHTTPURLResponse.class]&&[(NSHTTPURLResponse *)response statusCode]>=200&&[(NSHTTPURLResponse *)response statusCode]<300&&MediaParserResponseIsDirectMedia(response)){
        NSURL *finalURL=response.URL;NSURLComponents *parts=[NSURLComponents componentsWithURL:finalURL resolvingAgainstBaseURL:NO];
        if(parts&&[@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length&&!parts.user.length&&!parts.password.length){context.parserDirectURL=finalURL.absoluteString;context.parserDirectMIME=response.MIMEType?:@"";completionHandler(NSURLSessionResponseCancel);return;}
    }
    NSUInteger limit=context.parserRequest?1024*1024:[self maximumResponseBytes];
    if(response.expectedContentLength>0&&response.expectedContentLength>(long long)limit){context.failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"资源服务响应超过 %lu MiB",(unsigned long)(limit/(1024*1024))]}];completionHandler(NSURLSessionResponseCancel);return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(dataTask.taskIdentifier)];
    NSUInteger limit=context.parserRequest?1024*1024:[self maximumResponseBytes];
    if(context&&context.data.length+data.length<=limit)[context.data appendData:data];
    else if(context&&!context.failure)context.failure=[NSError errorWithDomain:@"CCTVHostMedia" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"资源服务响应超过 %lu MiB",(unsigned long)(limit/(1024*1024))]}];
    BOOL overLimit=context&&context.failure.code==3;[self.contextLock unlock];if(overLimit)[dataTask cancel];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(task.taskIdentifier)];NSUInteger redirectCount=context?++context.redirectCount:NSUIntegerMax;[self.contextLock unlock];
    NSURLComponents *to=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    BOOL valid=context&&redirectCount<=5&&to.scheme.length&&[@[@"http",@"https"] containsObject:to.scheme.lowercaseString]&&to.host.length&&!to.user.length&&!to.password.length;
    if(valid&&![self sameOrigin:response.URL as:request.URL]){
        NSMutableURLRequest *safe=[request mutableCopy];NSURL *sourceURL=[NSURL URLWithString:MediaTVBoxString(self.tvboxSource[@"api"])];BOOL sameHostUpgrade=!context.parserRequest&&[self sameCredentialScope:sourceURL as:response.URL]&&[self sameCredentialScope:sourceURL as:request.URL]&&[response.URL.scheme.lowercaseString isEqual:@"http"]&&[request.URL.scheme.lowercaseString isEqual:@"https"];
        if(sameHostUpgrade){
            NSDictionary *headers=[self.tvboxSource[@"header"] isKindOfClass:NSDictionary.class]?self.tvboxSource[@"header"]:@{};
            for(id rawName in headers){if(![rawName isKindOfClass:NSString.class])continue;NSString *name=rawName;if(MediaTVBoxHeaderIsSensitive(name)&&[headers[name] isKindOfClass:NSString.class]&&MediaTVBoxHeaderAllowed(name,headers[name]))[safe setValue:headers[name] forHTTPHeaderField:name];}
        }else{
            for(NSString *name in safe.allHTTPHeaderFields?:@{})if(MediaTVBoxHeaderIsSensitive(name))[safe setValue:nil forHTTPHeaderField:name];
        }
        request=safe;
    }
    completionHandler(valid?request:nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.contextLock lock];MediaAPIRequestContext *context=self.requestContexts[@(task.taskIdentifier)];[self.requestContexts removeObjectForKey:@(task.taskIdentifier)];NSData *data=[context.data copy];NSURLResponse *response=context.response;NSError *failure=context.failure?:error;void(^processor)(NSData *,NSURLResponse *,NSError *)=[context.processor copy];[self.contextLock unlock];
    if(processor)processor(data?:[NSData data],response,failure);
}
@end
