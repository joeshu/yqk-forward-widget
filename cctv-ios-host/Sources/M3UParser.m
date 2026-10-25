#import "M3UParser.h"

static const NSUInteger M3UMaximumChannels = 5000;
static const NSUInteger M3UMaximumLines = 100000;
static const NSUInteger M3UMaximumLineCharacters = 16384;
static NSError *M3ULimitError(NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostM3UParser" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

@implementation M3UChannel
@end

@implementation M3UParser
+ (NSString *)epgURL:(NSString *)text baseURL:(NSURL *)baseURL {
    if(!text.length)return nil;
    NSString *header=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet].firstObject;
    NSString *value=[self attribute:@"x-tvg-url" in:header]?:[self attribute:@"url-tvg" in:header];
    value=[value componentsSeparatedByString:@","].firstObject;
    NSURL *u=value.length?[NSURL URLWithString:value relativeToURL:baseURL]:nil;
    if(![@[@"http",@"https"] containsObject:u.scheme.lowercaseString]||!u.host.length)return nil;return u.absoluteURL.absoluteString;
}

+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(NSURL *)baseURL {
    return [self parse:text baseURL:baseURL error:NULL] ?: @[];
}

+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(NSURL *)baseURL error:(NSError **)error {
    NSMutableArray<M3UChannel *> *out = [NSMutableArray array];
    if (!text.length) return out;

    __block NSString *group = nil;
    __block NSString *pendingName = nil;
    __block NSString *pendingLogo = nil;
    __block NSString *pendingEPGID = nil;
    __block NSString *pendingTVGName = nil;
    __block NSUInteger lineCount=0;
    __block NSError *limitError=nil;
    [text enumerateLinesUsingBlock:^(NSString *raw, BOOL *stop) {
        lineCount++;
        if(lineCount>M3UMaximumLines){limitError=M3ULimitError(@"M3U 行数超过 100000 行安全上限");*stop=YES;return;}
        if(raw.length>M3UMaximumLineCharacters){limitError=M3ULimitError(@"M3U 单行超过 16384 字符安全上限");*stop=YES;return;}
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) return;

        if ([line hasPrefix:@"#EXTINF"]) {
            group = [self attribute:@"group-title" in:line];
            pendingTVGName = [self attribute:@"tvg-name" in:line];
            pendingLogo = [self attribute:@"tvg-logo" in:line];
            pendingEPGID = [self attribute:@"tvg-id" in:line];
            NSRange comma = [line rangeOfString:@","];
            NSString *display = comma.location != NSNotFound ? [line substringFromIndex:comma.location + 1] : nil;
            pendingName = display.length ? display : (pendingTVGName.length ? pendingTVGName : @"未命名频道");
            return;
        }
        if ([line hasPrefix:@"#"]) return;

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
        if (!url) { pendingName = nil; pendingLogo = nil; pendingEPGID = nil; pendingTVGName = nil; return; }
        if(out.count>=M3UMaximumChannels){limitError=M3ULimitError(@"频道数量超过 5000 条安全上限；已保留上次有效订阅");*stop=YES;return;}

        M3UChannel *ch = [M3UChannel new];
        ch.name = pendingName;
        ch.url = url.absoluteString;
        ch.group = group.length ? group : @"订阅";
        ch.logo = pendingLogo;
        ch.epgID = pendingEPGID;
        ch.tvgName = pendingTVGName;
        [out addObject:ch];
        pendingName = nil;
        pendingLogo = nil;
        pendingEPGID = nil;
        pendingTVGName = nil;
    }];
    if(limitError){if(error)*error=limitError;return nil;}
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
