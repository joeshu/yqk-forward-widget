#import "MediaCapabilityRegistry.h"
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

static BOOL M3UIsLoopbackOrWildcardHost(NSString *host) {
    NSString *lower = host.lowercaseString;
    return [lower isEqualToString:@"127.0.0.1"] || [lower isEqualToString:@"localhost"] || [lower isEqualToString:@"0.0.0.0"] || [lower isEqualToString:@"::1"];
}

static NSURL *M3UNormalizedLoopbackURL(NSURL *url, NSURL *baseURL) {
    if (!url) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
    if (!parts.host.length) return url.absoluteURL;
    if (!M3UIsLoopbackOrWildcardHost(parts.host)) return parts.URL ?: url.absoluteURL;
    parts.host = @"127.0.0.1";
    if (!parts.scheme.length || [parts.scheme.lowercaseString isEqualToString:@"http"] || [parts.scheme.lowercaseString isEqualToString:@"https"]) {
        if (![parts.scheme.lowercaseString isEqualToString:@"https"]) parts.scheme = @"http";
    }
    NSInteger basePort = baseURL.port.integerValue;
    if (M3UIsLoopbackOrWildcardHost(baseURL.host) && basePort >= 1 && basePort <= 65535) {
        // 本机直播服务生成的 M3U 头部常硬编码作者默认端口（如 127.0.0.1:8080/epg.xml 或 localhost/epg.xml），
        // 统一对齐到当前本机服务的实际监听端口，避免节目单端口与服务端口脱节。
        parts.scheme = @"http";
        parts.port = @(basePort);
    }
    return parts.URL ?: url.absoluteURL;
}

@implementation M3UChannel
- (NSURL *)catchupURLForStart:(NSDate *)start end:(NSDate *)end {
    if(!self.catchupSource.length||!start||!end||[end timeIntervalSinceDate:start]<=0)return nil;
    if(self.catchupDays>0&&[start timeIntervalSinceNow]<-self.catchupDays*86400)return nil;
    NSTimeInterval shift=self.tvgShift*3600;
    NSString *address=self.catchupSource;
    NSDictionary *values=@{@"{utc}":[NSString stringWithFormat:@"%.0f",start.timeIntervalSince1970+shift],@"{utcend}":[NSString stringWithFormat:@"%.0f",end.timeIntervalSince1970+shift],@"{duration}":[NSString stringWithFormat:@"%.0f",[end timeIntervalSinceDate:start]],@"${start}":[NSString stringWithFormat:@"%.0f",start.timeIntervalSince1970+shift],@"${end}":[NSString stringWithFormat:@"%.0f",end.timeIntervalSince1970+shift]};
    for(NSString *token in values)address=[address stringByReplacingOccurrencesOfString:token withString:values[token]];
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];formatter.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];NSDictionary *dateTokens=@{@"{Y}":@"yyyy",@"{m}":@"MM",@"{d}":@"dd",@"{H}":@"HH",@"{M}":@"mm",@"{S}":@"ss"};
    for(NSString *token in dateTokens){formatter.dateFormat=dateTokens[token];address=[address stringByReplacingOccurrencesOfString:token withString:[formatter stringFromDate:[start dateByAddingTimeInterval:shift]]];}
    if([address containsString:@"{"]||[address containsString:@"}"])return nil;
    if([self.catchupMode isEqual:@"append"])address=[self.url stringByAppendingString:address];
    NSURL *url=[NSURL URLWithString:address relativeToURL:[NSURL URLWithString:self.url]].absoluteURL;
    return [@[@"http",@"https"] containsObject:url.scheme.lowercaseString]?url:nil;
}
@end

@implementation M3UParser
+ (NSDictionary *)reportForText:(NSString *)text baseURL:(NSURL *)baseURL {
    NSError *error=nil;NSArray *channels=[self parse:text baseURL:baseURL error:&error]?:@[];NSMutableDictionary *unsupported=[NSMutableDictionary dictionary];
    if(!error&&![self isHLSManifest:text])[text enumerateLinesUsingBlock:^(NSString *raw,BOOL *stop){
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if([line hasPrefix:@"#"])return;
        NSRange comma=[line rangeOfString:@","];if(comma.location!=NSNotFound){NSString *tail=[line substringFromIndex:NSMaxRange(comma)];if([tail containsString:@"://"])line=tail;}
        NSURLComponents *parts=[NSURLComponents componentsWithString:line];NSString *scheme=parts.scheme.lowercaseString;
        if(scheme.length&&![MediaCapabilityNetworkTransports() containsObject:scheme]&&[line containsString:@"://"])unsupported[scheme]=@([unsupported[scheme] unsignedIntegerValue]+1);
    }];
    return @{@"channels":channels,@"recognizedCount":@(channels.count),@"unsupportedProtocols":unsupported.copy,@"error":error.localizedDescription?:@"",@"kind":[self isHLSManifest:text]?@"hls":@"iptv"};
}
+ (BOOL)isHLSManifest:(NSString *)text {
    for(NSString *tag in @[@"#EXT-X-STREAM-INF:",@"#EXT-X-TARGETDURATION:",@"#EXT-X-MEDIA-SEQUENCE:",@"#EXT-X-MAP:"])if([text containsString:tag])return YES;
    return NO;
}
+ (NSString *)epgURL:(NSString *)text baseURL:(NSURL *)baseURL {
    if(!text.length)return nil;
    if([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    NSArray<NSString *> *keys=@[@"x-tvg-url",@"url-tvg",@"tvg-url",@"epg-url",@"tvg-epg"];
    NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@",;"];
    __block NSString *resolvedEPG=nil;
    __block NSUInteger scanned=0;
    [text enumerateLinesUsingBlock:^(NSString *raw, BOOL *stop) {
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"\uFEFF"])line=[[line substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!line.length)return;
        scanned++;
        if(scanned>30||![line hasPrefix:@"#"]){*stop=YES;return;}
        for(NSString *key in keys){
            NSString *rawValue=[self attribute:key in:line];
            if(!rawValue.length)continue;
            for(NSString *item in [rawValue componentsSeparatedByCharactersInSet:separators]){
                NSString *value=[item stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if(!value.length)continue;
                NSURL *u=[NSURL URLWithString:value relativeToURL:baseURL];
                if(!u)continue;
                NSURL *normalized=M3UNormalizedLoopbackURL(u,baseURL);
                if(![@[@"http",@"https"] containsObject:normalized.scheme.lowercaseString]||!normalized.host.length)continue;
                resolvedEPG=normalized.absoluteURL.absoluteString;
                *stop=YES;
                return;
            }
        }
        if([line hasPrefix:@"#EXTINF"]){*stop=YES;}
    }];
    return resolvedEPG;
}

+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(NSURL *)baseURL {
    return [self parse:text baseURL:baseURL error:NULL] ?: @[];
}

+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(NSURL *)baseURL error:(NSError **)error {
    NSMutableArray<M3UChannel *> *out = [NSMutableArray array];
    if (!text.length) return out;
    if([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    if([self isHLSManifest:text]){
        if(baseURL.host.length){M3UChannel *channel=[M3UChannel new];channel.name=baseURL.lastPathComponent?:@"HLS";channel.url=baseURL.absoluteString;channel.group=@"直播";channel.headers=@{};[out addObject:channel];}
        return out;
    }
    __block NSString *catchupMode=nil,*catchupSource=nil;
    __block double catchupDays=0,tvgShift=0;
    __block NSString *defaultMode=nil,*defaultSource=nil;__block double defaultDays=0,defaultShift=0;

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

        if([line hasPrefix:@"#EXTM3U"]){defaultMode=[self attribute:@"catchup" in:line];defaultSource=[self attribute:@"catchup-source" in:line];defaultDays=[[self attribute:@"catchup-days" in:line] doubleValue];defaultShift=[[self attribute:@"tvg-shift" in:line] doubleValue];return;}
        if ([line hasPrefix:@"#EXTVLCOPT:"]) {
            M3UAddVLCOption(pendingHeaders, [line substringFromIndex:[@"#EXTVLCOPT:" length]]);
            return;
        }
        if ([line hasPrefix:@"#EXTHTTP:"]) {
            M3UAddHTTPDirective(pendingHeaders, [line substringFromIndex:[@"#EXTHTTP:" length]]);
            return;
        }

        NSRange txtComma=[line rangeOfString:@","];
        if(![line hasPrefix:@"#"]&&txtComma.location!=NSNotFound){
            NSString *tail=[[line substringFromIndex:NSMaxRange(txtComma)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSString *label=[line substringToIndex:txtComma.location];
            if([tail isEqual:@"#genre#"]){group=label;return;}
            if([tail containsString:@"://"]){pendingName=label;line=tail;}
        }
        if ([line hasPrefix:@"#EXTINF"]) {
            catchupMode=[self attribute:@"catchup" in:line]?:defaultMode;catchupSource=[self attribute:@"catchup-source" in:line]?:defaultSource;NSString *days=[self attribute:@"catchup-days" in:line],*shift=[self attribute:@"tvg-shift" in:line];catchupDays=days.length?days.doubleValue:defaultDays;tvgShift=shift.length?shift.doubleValue:defaultShift;
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

        // Relative paths require an EXTINF entry; arbitrary script words are not channels.
        if(!pendingName&&![line containsString:@"://"])return;
        if (!pendingName) pendingName = line.lastPathComponent.stringByDeletingPathExtension;

        NSURL *url = nil;
        @try {
            url = [NSURL URLWithString:line];
            if (url.scheme.length == 0 && baseURL) url = [NSURL URLWithString:line relativeToURL:baseURL];
            NSURLComponents *parts = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES] : nil;
            NSString *scheme = parts.scheme.lowercaseString;
            if ((![MediaCapabilityNetworkTransports() containsObject:scheme]) || !parts.host.length) url = nil;
            else {
                if ([[parts.host lowercaseString] isEqualToString:@"0.0.0.0"] || [[parts.host lowercaseString] isEqualToString:@"localhost"]) {
                    parts.host = @"127.0.0.1";
                    if (!parts.port && M3UIsLoopbackOrWildcardHost(baseURL.host) && baseURL.port.integerValue >= 1 && baseURL.port.integerValue <= 65535) {
                        parts.port = baseURL.port;
                    }
                }
                url = parts.URL;
            }
        } @catch (NSException *exception) {
            url = nil;
        }
        if (!url) { pendingName = nil; pendingLogo = nil; pendingEPGID = nil; pendingTVGName = nil; catchupMode=nil;catchupSource=nil;catchupDays=0;tvgShift=0;[pendingHeaders removeAllObjects]; return; }
        if(out.count>=M3UMaximumChannels){limitError=M3ULimitError(@"频道数量超过 5000 条安全上限；已保留上次有效订阅");*stop=YES;return;}

        M3UChannel *ch = [M3UChannel new];
        ch.name = pendingName;
        ch.url = url.absoluteString;
        ch.group = group.length ? group : @"订阅";
        ch.logo = pendingLogo;
        ch.epgID = pendingEPGID;
        ch.tvgName = pendingTVGName;
        ch.headers = pendingHeaders.copy ?: @{};
        ch.catchupMode=catchupMode;ch.catchupSource=catchupSource;ch.catchupDays=catchupDays;ch.tvgShift=tvgShift;
        catchupMode=nil;catchupSource=nil;catchupDays=0;tvgShift=0;
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
    if (!key.length || !line.length) return nil;
    NSString *escaped = [NSRegularExpression escapedPatternForString:key];
    NSString *pattern = [NSString stringWithFormat:@"(?:^|[\\s,;])%@\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", escaped];
    // 属性键只有少量固定取值：缓存已编译的正则，避免每行每属性重编译。
    static NSCache *patternCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ patternCache = [NSCache new]; patternCache.countLimit = 32; });
    NSRegularExpression *re = [patternCache objectForKey:pattern];
    if(!re){re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:NULL];if(re)[patternCache setObject:re forKey:pattern];}
    if(!re)return nil;
    NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    if (!m || m.numberOfRanges < 3) return nil;
    NSRange dq = [m rangeAtIndex:1];
    if (dq.location != NSNotFound) return [line substringWithRange:dq];
    NSRange sq = [m rangeAtIndex:2];
    if (sq.location != NSNotFound) return [line substringWithRange:sq];
    return nil;
}

@end
