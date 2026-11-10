#import "ResourceContentInspection.h"

NSString *ResourceContentText(NSData *data) {
    if(![data isKindOfClass:NSData.class]||!data.length)return @"";
    NSUInteger count=MIN(data.length,(NSUInteger)512*1024);
    NSString *text=nil;
    for(NSUInteger trim=0;trim<4&&count>trim&&!text;trim++)text=[[NSString alloc] initWithBytes:data.bytes length:count-trim encoding:NSUTF8StringEncoding];
    if([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    return text?:@"";
}
BOOL ResourceContentIsHTML(NSData *data) {
    NSString *text=[[ResourceContentText(data) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if([text hasPrefix:@"<!--"]){NSRange end=[text rangeOfString:@"-->"];if(end.location!=NSNotFound)text=[[text substringFromIndex:NSMaxRange(end)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];}
    for(NSString *prefix in @[@"<!doctype html",@"<html",@"<head",@"<body"])if([text hasPrefix:prefix])return YES;
    return NO;
}
NSString *ResourceContentExtension(NSData *data,NSString *suggestedFilename) {
    NSString *extension=suggestedFilename.pathExtension.lowercaseString?:@"";
    if(data.length>=4&&memcmp(data.bytes,"PK\003\004",4)==0)return [extension isEqual:@"jar"]?@"jar":@"zip";
    if(ResourceContentIsHTML(data))return @"html";
    NSString *text=ResourceContentText(data),*trim=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([trim hasPrefix:@"#EXTM3U"])return @"m3u";
    NSRegularExpression *python=[NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*(?:class\\s+Spider\\s*[:(]|from\\s+base\\.spider\\s+import|def\\s+(?:homeContent|playerContent)\\s*\\()" options:0 error:NULL];
    if([python firstMatchInString:text options:0 range:NSMakeRange(0,text.length)])return @"py";
    if([extension isEqual:@"hjs"])return extension;
    if([trim hasPrefix:@"{"]||[trim hasPrefix:@"["]){id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if([json isKindOfClass:NSDictionary.class]||[json isKindOfClass:NSArray.class])return @"json";}
    if([@[@"js",@"mjs",@"cjs",@"py",@"zip",@"jar",@"m3u",@"m3u8",@"json",@"xml",@"txt",@"hawk"] containsObject:extension])return extension;
    NSRegularExpression *script=[NSRegularExpression regularExpressionWithPattern:@"(?m)(?:^|[;\\n])\\s*(?:export\\s+(?:default|const|function|class)|import\\s|(?:var|let|const)\\s+rule\\s*=|module\\.exports\\s*=|WeBox\\.define\\s*\\()" options:0 error:NULL];
    return [script firstMatchInString:text options:0 range:NSMakeRange(0,text.length)]?@"js":@"txt";
}
static NSString *ResourceContentUnescape(NSString *value) {
    return [[[[value stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""] stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"] stringByReplacingOccurrencesOfString:@"&#38;" withString:@"&"] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
}
static NSURL *ResourceContentLink(NSString *value,NSURL *origin) {
    NSString *address=[ResourceContentUnescape(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!address.length||address.length>8192||[address rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    NSURL *url=[NSURL URLWithString:address relativeToURL:origin].absoluteURL;
    if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||url.user.length||url.password.length)return nil;
    // A public GitHub file page is a resource link; import its actual bytes.
    if([url.host.lowercaseString isEqual:@"github.com"]){NSArray *parts=url.path.pathComponents;if(parts.count>=6&&[parts[3] isEqual:@"blob"]){NSMutableArray *raw=[parts mutableCopy];[raw removeObjectAtIndex:3];NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];c.host=@"raw.githubusercontent.com";c.path=[NSString pathWithComponents:raw];c.fragment=nil;url=c.URL;}}
    return url;
}
NSArray<NSDictionary *> *ResourceContentPageLinks(NSData *data,NSURL *origin) {
    if(!ResourceContentIsHTML(data))return @[];
    NSString *text=ResourceContentText(data);
    NSRegularExpression *anchors=[NSRegularExpression regularExpressionWithPattern:@"<a\\b[^>]{0,4096}?\\s+href\\s*=\\s*(?:\"([^\"]{1,8192})\"|'([^']{1,8192})'|([^\\s>]{1,8192}))[^>]{0,4096}>([\\s\\S]{0,2048}?)</a\\s*>" options:NSRegularExpressionCaseInsensitive error:NULL];
    NSRegularExpression *tags=[NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:NULL];
    NSSet *extensions=[NSSet setWithArray:@[@"json",@"hawk",@"js",@"hjs",@"mjs",@"cjs",@"py",@"zip",@"jar",@"md5",@"m3u",@"m3u8",@"txt",@"xml"]];
    NSMutableArray *links=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    [anchors enumerateMatchesInString:text options:0 range:NSMakeRange(0,text.length) usingBlock:^(NSTextCheckingResult *match,NSMatchingFlags flags,BOOL *stop){
        NSString *href=nil;for(NSUInteger group=1;group<=3;group++)if([match rangeAtIndex:group].location!=NSNotFound){href=[text substringWithRange:[match rangeAtIndex:group]];break;}
        NSURL *url=ResourceContentLink(href,origin);if(!url)return;
        NSString *title=[text substringWithRange:[match rangeAtIndex:4]];title=[tags stringByReplacingMatchesInString:title options:0 range:NSMakeRange(0,title.length) withTemplate:@""];title=[ResourceContentUnescape(title) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL explicitResource=[extensions containsObject:url.pathExtension.lowercaseString];
        if(!explicitResource){NSString *label=title.lowercaseString;for(NSString *word in @[@"订阅",@"配置",@"资源下载",@"tvbox",@"m3u",@"spider"]){if([label containsString:word]){explicitResource=YES;break;}}}
        if(!explicitResource||[seen containsObject:url.absoluteString]||[url.absoluteString isEqual:origin.absoluteString])return;
        [seen addObject:url.absoluteString];[links addObject:@{@"name":title.length?[title substringToIndex:MIN(title.length,(NSUInteger)128)]:(url.lastPathComponent?:@"资源链接"),@"url":url.absoluteString}];
        if(links.count>=32)*stop=YES;
    }];
    return links.copy;
}
