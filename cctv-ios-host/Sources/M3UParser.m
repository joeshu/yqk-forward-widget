#import "M3UParser.h"

@implementation M3UChannel
@end

@implementation M3UParser

+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(NSURL *)baseURL {
    NSMutableArray<M3UChannel *> *out = [NSMutableArray array];
    if (!text.length) return out;

    NSString *group = nil;
    NSString *pendingName = nil;
    NSString *pendingLogo = nil;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;

        if ([line hasPrefix:@"#EXTINF"]) {
            group = [self attribute:@"group-title" in:line];
            NSString *tvg = [self attribute:@"tvg-name" in:line];
            pendingLogo = [self attribute:@"tvg-logo" in:line];
            NSRange comma = [line rangeOfString:@","];
            NSString *display = comma.location != NSNotFound ? [line substringFromIndex:comma.location + 1] : nil;
            pendingName = display.length ? display : (tvg.length ? tvg : @"未命名频道");
            continue;
        }
        if ([line hasPrefix:@"#"]) continue;

        if (!pendingName) pendingName = line.lastPathComponent.stringByDeletingPathExtension;

        NSURL *url = nil;
        @try {
            url = [NSURL URLWithString:line];
            if (url.scheme.length == 0 && baseURL) url = [NSURL URLWithString:line relativeToURL:baseURL];
            NSURLComponents *parts = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES] : nil;
            NSString *scheme = parts.scheme.lowercaseString;
            if ((! [scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) || !parts.host.length) url = nil;
            else url = parts.URL;
        } @catch (NSException *exception) {
            url = nil;
        }
        if (!url) { pendingName = nil; pendingLogo = nil; continue; }

        M3UChannel *ch = [M3UChannel new];
        ch.name = pendingName;
        ch.url = url.absoluteString;
        ch.group = group.length ? group : @"订阅";
        ch.logo = pendingLogo;
        [out addObject:ch];
        pendingName = nil;
        pendingLogo = nil;
    }
    return out;
}

+ (NSString *)attribute:(NSString *)key in:(NSString *)line {
    NSString *pattern = [NSString stringWithFormat:@"%@=\"([^\"]*)\"", key];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    return [line substringWithRange:[m rangeAtIndex:1]];
}

@end
