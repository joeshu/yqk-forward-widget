#import "M3UParser.h"

static const NSUInteger M3UMaximumChannels = 5000;
static const NSUInteger M3UMaximumLines = 100000;
static const NSUInteger M3UMaximumLineCharacters = 16384;
static NSError *M3ULimitError(NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostM3UParser" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static BOOL M3UHeaderNameAllowed(NSString *name) {
    if (!name.length || name.length > 128) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"] invertedSet];
    if ([name rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    return ![@[@"host", @"content-length", @"connection", @"transfer-encoding", @"keep-alive", @"upgrade", @"proxy-authorization", @"proxy-authenticate"] containsObject:name.lowercaseString];
}

static void M3UAddHeader(NSMutableDictionary<NSString *, NSString *> *headers, id rawName, id rawValue) {
    if (![rawName isKindOfClass:NSString.class] || ![rawValue isKindOfClass:NSString.class] || headers.count >= 32) return;
    NSString *name = [rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *value = [rawValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!M3UHeaderNameAllowed(name) || value.length > 8192 || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return;
    headers[name] = value;
}

static void M3UAddVLCOption(NSMutableDictionary<NSString *, NSString *> *headers, NSString *option) {
    NSRange split = [option rangeOfString:@"="];
    if (split.location == NSNotFound || split.location == 0) return;
    NSString *key = [[option substringToIndex:split.location] lowercaseString];
    NSString *value = [option substringFromIndex:NSMaxRange(split)];
    NSDictionary *mapped = @{@"http-user-agent": @"User-Agent", @"http-referrer": @"Referer", @"http-referer": @"Referer", @"http-origin": @"Origin", @"http-cookie": @"Cookie", @"http-authorization": @"Authorization", @"http-accept": @"Accept"};
    NSString *name = mapped[key];
    if (!name.length && [key hasPrefix:@"http-header-"]) name = [key substringFromIndex:[@"http-header-" length]];
    if (name.length) M3UAddHeader(headers, name, value);
}

static void M3UAddHTTPDirective(NSMutableDictionary<NSString *, NSString *> *headers, NSString *directive) {
    if (directive.length > 16384) return;
    NSData *data = [directive dataUsingEncoding:NSUTF8StringEncoding];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        for (id key in json) M3UAddHeader(headers, key, json[key]);
        return;
    }
    M3UAddVLCOption(headers, directive);
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
    __block NSMutableDictionary<NSString *, NSString *> *pendingHeaders = [NSMutableDictionary dictionary];
    __block NSUInteger lineCount=0;
    __block NSError *limitError=nil;
    [text enumerateLinesUsingBlock:^(NSString *raw, BOOL *stop) {
        lineCount++;
        if(lineCount>M3UMaximumLines){limitError=M3ULimitError(@"M3U 行数超过 100000 行安全上限");*stop=YES;return;}
        if(raw.length>M3UMaximumLineCharacters){limitError=M3ULimitError(@"M3U 单行超过 16384 字符安全上限");*stop=YES;return;}
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) return;

        if ([line hasPrefix:@"#EXTVLCOPT:"]) {
            M3UAddVLCOption(pendingHeaders, [line substringFromIndex:[@"#EXTVLCOPT:" length]]);
            return;
        }
        if ([line hasPrefix:@"#EXTHTTP:"]) {
            M3UAddHTTPDirective(pendingHeaders, [line substringFromIndex:[@"#EXTHTTP:" length]]);
            return;
        }

        if ([line hasPrefix:@"#EXTINF"]) {
            // Header directives belong to the next URL. Drop any directives
            // left behind by a malformed entry so they cannot leak to another
            // channel after a missing URL line.
            [pendingHeaders removeAllObjects];
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
        if (!url) { pendingName = nil; pendingLogo = nil; pendingEPGID = nil; pendingTVGName = nil; [pendingHeaders removeAllObjects]; return; }
        if(out.count>=M3UMaximumChannels){limitError=M3ULimitError(@"频道数量超过 5000 条安全上限；已保留上次有效订阅");*stop=YES;return;}

        M3UChannel *ch = [M3UChannel new];
        ch.name = pendingName;
        ch.url = url.absoluteString;
        ch.group = group.length ? group : @"订阅";
        ch.logo = pendingLogo;
        ch.epgID = pendingEPGID;
        ch.tvgName = pendingTVGName;
        ch.headers = pendingHeaders.copy ?: @{};
        [out addObject:ch];
        pendingName = nil;
        pendingLogo = nil;
        pendingEPGID = nil;
        pendingTVGName = nil;
        [pendingHeaders removeAllObjects];
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
