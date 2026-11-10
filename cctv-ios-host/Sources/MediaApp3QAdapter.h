// App3Q's published catalog configuration supplies the request signing fields.
// Protocol verified against the provider's App3Q class and signed HTTP replies.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSString *App3QText(id value) {
    return [value isKindOfClass:NSString.class]?value:([value respondsToSelector:@selector(stringValue)]?[value stringValue]:@"");
}
static NSDictionary *MediaApp3QHeaders(NSDictionary *config, NSString *timestamp, NSString *nonce) {
    NSString *input=[NSString stringWithFormat:@"finger=%@&id=%@&nonce=%@&sk=%@&time=%@&v=%@",App3QText(config[@"finger"]),App3QText(config[@"pkg"]),nonce,App3QText(config[@"sk"]),timestamp,App3QText(config[@"ver"])];
    NSData *bytes=[input dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *signature=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[signature appendFormat:@"%02X",digest[i]];
    return @{@"User-Agent":@"okhttp/4.12.0",@"Accept":@"application/json",@"x-platform":@"android",@"x-ave":App3QText(config[@"ver"]),@"x-aid":App3QText(config[@"pkg"]),@"x-time":timestamp,@"x-nonc":nonce,@"x-sign":signature,@"x-device-id":[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""],@"x-device-brand":App3QText(config[@"deviceBrand"]),@"x-device-model":App3QText(config[@"deviceModel"]),@"x-update-id":App3QText(config[@"host"])};
}

static NSURLRequest *MediaApp3QRequest(NSDictionary *config, NSString *operation, NSDictionary *args, NSError **error) {
    NSString *host=[App3QText(config[@"host"]) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSURLComponents *origin=[NSURLComponents componentsWithString:host];
    BOOL valid=[@[@"http",@"https"] containsObject:origin.scheme.lowercaseString]&&origin.host.length&&!origin.user.length&&!origin.password.length&&!origin.query.length&&!origin.fragment.length;
    for(NSString *key in @[@"finger",@"pkg",@"sk",@"ver"])if(!App3QText(config[key]).length)valid=NO;
    for(NSString *key in @[@"pkg",@"ver",@"deviceBrand",@"deviceModel",@"host"]){NSString *value=App3QText(config[key]);if(value.length>4096||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)valid=NO;}
    if(!valid){if(error)*error=[NSError errorWithDomain:@"CCTVHostApp3Q" code:1 userInfo:@{NSLocalizedDescriptionKey:@"三秋配置缺少有效地址或请求签名参数，请刷新来源配置"}];return nil;}
    NSString *path=@"/api.php/app/index/home",*page=[NSString stringWithFormat:@"%ld",(long)MAX(1,[args[@"page"] integerValue])];NSDictionary *params=@{};
    if([operation isEqual:@"category"]){path=@"/api.php/app/filter/vod";params=@{@"type_name":App3QText(args[@"categoryId"]),@"page":page,@"sort":@"hits"};}
    else if([operation isEqual:@"search"]){path=@"/api.php/app/search/index";params=@{@"wd":App3QText(args[@"keyword"]),@"page":page,@"limit":@"15"};}
    else if([operation isEqual:@"detail"]){path=@"/api.php/app/vod/get_detail";params=@{@"vod_id":App3QText(args[@"id"])};}
    else if([operation isEqual:@"play"]){path=@"/api.php/app/decode/url/";params=@{@"url":App3QText(args[@"id"]),@"vodFrom":App3QText(args[@"lineId"])};}
    NSURLComponents *url=[NSURLComponents componentsWithString:[host stringByAppendingString:path]];NSMutableArray *query=[NSMutableArray array];
    for(NSString *key in [params.allKeys sortedArrayUsingSelector:@selector(compare:)])[query addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];if(query.count)url.queryItems=query;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url.URL];
    NSString *timestamp=[NSString stringWithFormat:@"%.0f",floor(NSDate.date.timeIntervalSince1970)],*nonce=[NSString stringWithFormat:@"%u",arc4random_uniform(999)+1];
    NSDictionary *headers=MediaApp3QHeaders(config,timestamp,nonce);for(NSString *key in headers)[request setValue:headers[key] forHTTPHeaderField:key];return request;
}
