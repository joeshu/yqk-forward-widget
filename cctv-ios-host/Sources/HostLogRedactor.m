#import "HostLogRedactor.h"

@implementation HostLogRedactor
+ (NSString *)redactURL:(NSString *)url {
    if(![url isKindOfClass:NSString.class]||!url.length)return @"";
    NSString *trimmed=[url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([trimmed.lowercaseString hasPrefix:@"cenc://"])return @"cenc://[已脱敏]";
    NSURLComponents *parts=[NSURLComponents componentsWithString:trimmed];
    if(!parts.scheme.length||!parts.host.length){NSString *safe=[self redactText:trimmed];return safe.length>240?[[safe substringToIndex:240] stringByAppendingString:@"…"]:safe;}
    parts.user=nil;parts.password=nil;parts.fragment=nil;
    NSString *path=parts.path?:@"";
    NSRegularExpression *xtream=[NSRegularExpression regularExpressionWithPattern:@"(?i)(/(?:live|movie|series)/)[^/?#]+/[^/?#]+(?:/|$)" options:0 error:NULL];
    path=[xtream stringByReplacingMatchesInString:path options:0 range:NSMakeRange(0,path.length) withTemplate:@"$1[已脱敏]/[已脱敏]/"];
    parts.path=path;
    if(parts.queryItems.count){NSMutableArray *items=[NSMutableArray arrayWithCapacity:parts.queryItems.count];for(NSURLQueryItem *item in parts.queryItems)[items addObject:[NSURLQueryItem queryItemWithName:item.name value:item.value?@"[已脱敏]":nil]];parts.queryItems=items;}
    NSString *result=parts.string?:@"";
    return result.length>260?[[result substringToIndex:260] stringByAppendingString:@"…"]:result;
}

+ (NSString *)redactText:(NSString *)text {
    if(!text.length)return text?:@"";
    static NSArray<NSRegularExpression *> *expressions;
    static NSArray<NSString *> *templates;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSArray *patterns=@[
            @"(?im)(\\b(?:authorization|proxy-authorization|cookie|set-cookie)\\s*:\\s*)[^\\r\\n]+",
            @"(?i)(https?://)[^/@\\s]+@",
            @"(?i)(/(?:live|movie|series)/)[^/?#\\s]+/[^/?#\\s]+/",
            @"(?i)([?&][^=&#\\s]*(?:access[_-]?token|refresh[_-]?token|token|auth|signature|sign|ticket|api[_-]?key|secret|password|passwd|cookie|session|credential)[^=&#\\s]*=)[^&#\\s]*",
            @"(?i)\\b((?:access[_-]?token|refresh[_-]?token|token|auth(?:orization)?|signature|sign|ticket|api[_-]?key|secret|password|passwd|cookie|session(?:id)?|credential)s?)(\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;&]+)",
            @"(?i)\\b(Bearer\\s+)[A-Za-z0-9._~+/-]+=*"
        ];
        templates=@[@"$1[已脱敏]",@"$1[已脱敏]@",@"$1[已脱敏]/[已脱敏]/",@"$1[已脱敏]",@"$1$2[已脱敏]",@"$1[已脱敏]"];
        NSMutableArray *compiled=[NSMutableArray arrayWithCapacity:patterns.count];
        for(NSString *pattern in patterns){NSRegularExpression *expression=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];if(expression)[compiled addObject:expression];}
        expressions=[compiled copy];
    });
    NSString *redacted=text;
    for(NSUInteger index=0;index<expressions.count;index++){
        NSRegularExpression *expression=expressions[index];
        redacted=[expression stringByReplacingMatchesInString:redacted options:0 range:NSMakeRange(0,redacted.length) withTemplate:templates[index]];
    }
    return redacted;
}
@end
