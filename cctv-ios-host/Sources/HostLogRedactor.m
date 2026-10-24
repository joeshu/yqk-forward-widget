#import "HostLogRedactor.h"

@implementation HostLogRedactor
+ (NSString *)redactText:(NSString *)text {
    if(!text.length)return text?:@"";
    static NSArray<NSRegularExpression *> *expressions;
    static NSArray<NSString *> *templates;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSArray *patterns=@[
            @"(?im)(\\b(?:authorization|proxy-authorization|cookie|set-cookie)\\s*:\\s*)[^\\r\\n]+",
            @"(?i)(https?://)[^/@\\s]+@",
            @"(?i)([?&][^=&#\\s]*(?:access[_-]?token|refresh[_-]?token|token|auth|signature|sign|ticket|api[_-]?key|secret|password|passwd|cookie|session|credential)[^=&#\\s]*=)[^&#\\s]*",
            @"(?i)\\b((?:access[_-]?token|refresh[_-]?token|token|auth(?:orization)?|signature|sign|ticket|api[_-]?key|secret|password|passwd|cookie|session(?:id)?|credential)s?)(\\s*[:=]\\s*)(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;&]+)",
            @"(?i)\\b(Bearer\\s+)[A-Za-z0-9._~+/-]+=*"
        ];
        templates=@[@"$1[已脱敏]",@"$1[已脱敏]@",@"$1[已脱敏]",@"$1$2[已脱敏]",@"$1[已脱敏]"];
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
