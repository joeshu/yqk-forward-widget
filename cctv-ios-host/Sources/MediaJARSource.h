#import <Foundation/Foundation.h>

// csp_* is a Java class selector, never a relative HTTP path.
static NSString *MediaJARClass(id value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *api=value;
    BOOL prefix=([api hasPrefix:@"csp_"]&&api.length>4)||([api hasPrefix:@"com.github.catvod.spider."]&&api.length>[@"com.github.catvod.spider." length]);
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$"];
    if (prefix&&api.length<=512&&[api rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound) return api;
    return @"";
}
static NSDictionary *MediaJARReference(id value, NSString *origin) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>8192) return nil;
    NSArray *fields=[value componentsSeparatedByString:@";md5;"];
    if (fields.count>2) return nil;
    NSString *address=[fields[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([address rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
    NSURL *url=[NSURL URLWithString:address relativeToURL:[NSURL URLWithString:origin?:@""]].absoluteURL;
    if (!url.host.length || ![@[@"http",@"https"] containsObject:url.scheme.lowercaseString] || url.user.length || url.password.length || url.fragment.length) return nil;
    NSString *md5=fields.count==2?[fields[1] lowercaseString]:@"";
    if (md5.length && (md5.length!=32 || [md5 rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)) return nil;
    return @{@"url":url.absoluteString,@"md5":md5};
}
static void MediaJARAttachSource(NSMutableDictionary *source, NSDictionary *site, NSDictionary *catalog) {
    if (!MediaJARClass(site[@"api"]).length) return;
    NSString *origin=[catalog[@"url"] isKindOfClass:NSString.class]?catalog[@"url"]:@"";
    id reference=[site[@"jar"] isKindOfClass:NSString.class]&&[site[@"jar"] length]?site[@"jar"]:catalog[@"tvboxConfig"][@"spider"];
    NSDictionary *jar=MediaJARReference(reference,origin);
    if (jar) { source[@"jar"]=jar; source[@"subscriptionURL"]=origin; }
}
static NSString *MediaJARExtension(NSDictionary *source) {
    id value=source[@"options"];
    if ([value isKindOfClass:NSDictionary.class]||[value isKindOfClass:NSArray.class]) {
        NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
        return json?[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]:@"";
    }
    if (![value isKindOfClass:NSString.class]) return @"";
    if ([value hasPrefix:@"./"]||[value hasPrefix:@"../"]||[value hasPrefix:@"/"]) {
        NSDictionary *reference=MediaJARReference(value,source[@"subscriptionURL"]);if(reference)return reference[@"url"];
    }
    return value;
}
static BOOL MediaJARUsesRuntime(NSDictionary *source) {
    if (![source[@"protocol"] isEqual:@"jar-bridge"] || !MediaJARClass(source[@"api"]).length || ![source[@"jar"] isKindOfClass:NSDictionary.class]) return NO;
    // Proven native ports avoid cold JVM startup. Other classes execute the supplied JAR.
    return ![@[@"csp_app3q",@"csp_sp360"] containsObject:[source[@"api"] lowercaseString]];
}
static NSDictionary *MediaJARParameters(NSString *operation, NSDictionary *arguments) {
    NSString *(^text)(id)=^NSString *(id value){return [value isKindOfClass:NSString.class]?value:([value isKindOfClass:NSNumber.class]?[value stringValue]:@"");};
    NSString *page=[NSString stringWithFormat:@"%ld",(long)MAX(1,[arguments[@"page"] integerValue])];
    if ([operation isEqual:@"home"]) return @{};
    if ([operation isEqual:@"search"]) return @{@"wd":text(arguments[@"keyword"]),@"pg":page};
    if ([operation isEqual:@"category"]) {
        NSDictionary *filters=[arguments[@"filters"] isKindOfClass:NSDictionary.class]?arguments[@"filters"]:@{};
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:filters options:0 error:NULL];
        return @{@"t":text(arguments[@"categoryId"]),@"pg":page,@"filters":encoded?[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]:@"{}"};
    }
    if ([operation isEqual:@"detail"]) return @{@"ids":text(arguments[@"id"])};
    if ([operation isEqual:@"play"]) return @{@"play":text(arguments[@"id"]),@"flag":text(arguments[@"lineId"]),@"detailID":text(arguments[@"detailId"]?:arguments[@"detailID"])};
    return nil;
}
