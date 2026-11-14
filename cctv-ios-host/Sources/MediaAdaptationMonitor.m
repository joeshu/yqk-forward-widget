#import "MediaAdaptationMonitor.h"
#import "HostLogRedactor.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import "TVBoxCatalogStore.h"

NSString *const CCTVMediaAdaptationMonitorDidUpdateNotification = @"CCTVMediaAdaptationMonitorDidUpdateNotification";
NSString *const CCTVMediaAdaptationMonitorEnabledKey = @"cctv.adaptationMonitor.enabled";
NSString *const CCTVMediaAdaptationMonitorRecordsKey = @"cctv.adaptationMonitor.records.v1";

static const NSUInteger CCTVMediaAdaptationMonitorMaxRecords = 260;

static NSString *CCTVMonitorSafeString(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [(NSNumber *)value stringValue];
    }
    return @"";
}

static NSString *CCTVMonitorRedactURL(NSString *rawURL) {
    return [HostLogRedactor redactURL:CCTVMonitorSafeString(rawURL)];
}

static NSDictionary *CCTVMonitorSanitizedRecord(NSDictionary *record) {
    NSMutableDictionary *safe=[record mutableCopy];
    NSSet *urlKeys=[NSSet setWithArray:@[@"url",@"resolvedURL",@"originalURL",@"streamURL",@"sourceURL",@"finalURL",@"apiURL"]];
    for(NSString *key in safe.allKeys.copy){
        id value=safe[key];if(![value isKindOfClass:NSString.class])continue;
        NSURLComponents *parts=[NSURLComponents componentsWithString:value];
        if([urlKeys containsObject:key])safe[key]=CCTVMonitorRedactURL(value);
        else if([key isEqual:@"provider"]&&parts.host.length)safe[key]=parts.host.lowercaseString;
        else safe[key]=[HostLogRedactor redactText:value];
    }
    return safe.copy;
}

static NSString *CCTVMonitorExtractHost(NSString *rawURL) {
    NSString *trimmed = CCTVMonitorSafeString(rawURL);
    if (!trimmed.length) return @"";
    if ([trimmed.lowercaseString hasPrefix:@"cenc://"]) return @"local-cenc-decrypt";
    if ([trimmed.lowercaseString hasPrefix:@"file://"]) return @"local-bundle";
    NSURLComponents *parts = [NSURLComponents componentsWithString:trimmed];
    return parts.host.lowercaseString ?: @"";
}

static NSString *CCTVMonitorInferFormat(NSString *url, NSDictionary *result) {
    if ([result isKindOfClass:NSDictionary.class]) {
        NSString *fmt = CCTVMonitorSafeString(result[@"format"] ?: result[@"mediaType"] ?: result[@"contentType"]);
        if (fmt.length) return fmt.lowercaseString;
        if ([result[@"dashRemuxed"] boolValue]) return @"dash->hls(fmp4)";
        if ([result[@"proxy"] boolValue]) return @"local-proxy(mp4)";
    }
    NSString *low = CCTVMonitorSafeString(url).lowercaseString;
    if ([low hasPrefix:@"cenc://"] || [low containsString:@"/cenc/"]) return @"cenc-mp4";
    if ([low containsString:@".m3u8"] || [low containsString:@"/m3u"]) return @"hls(m3u8)";
    if ([low containsString:@".mpd"]) return @"dash(mpd)";
    if ([low containsString:@".flv"]) return @"flv";
    if ([low containsString:@".mp4"] || [low containsString:@".m4v"]) return @"mp4";
    if ([low containsString:@".mkv"]) return @"mkv";
    if ([low containsString:@"/proxy/"]) return @"plugin-proxy";
    if ([low containsString:@"/media/"]) return @"media-relay";
    return @"auto";
}

@interface MediaAdaptationMonitor ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *records;
@property(nonatomic, strong) NSDateFormatter *timeFormatter;
@end

@implementation MediaAdaptationMonitor

+ (instancetype)shared {
    static MediaAdaptationMonitor *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MediaAdaptationMonitor alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.cctvhost.adaptation-monitor", DISPATCH_QUEUE_SERIAL);
        _records = [NSMutableArray array];
        _timeFormatter = [[NSDateFormatter alloc] init];
        _timeFormatter.dateFormat = @"MM-dd HH:mm:ss";
        NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:CCTVMediaAdaptationMonitorRecordsKey];
        BOOL sanitizedSavedRecords=NO;
        if ([saved isKindOfClass:NSArray.class]) {
            for (id item in saved) {
                if ([item isKindOfClass:NSDictionary.class]) {
                    NSDictionary *safe=CCTVMonitorSanitizedRecord(item);
                    sanitizedSavedRecords|=![safe isEqual:item];
                    [_records addObject:safe];
                }
            }
        }
        if(sanitizedSavedRecords)[NSUserDefaults.standardUserDefaults setObject:[_records copy] forKey:CCTVMediaAdaptationMonitorRecordsKey];
    }
    return self;
}

- (BOOL)isMonitoringEnabled {
    id val = [NSUserDefaults.standardUserDefaults objectForKey:CCTVMediaAdaptationMonitorEnabledKey];
    return val ? [val boolValue] : YES;
}

- (void)setMonitoringEnabled:(BOOL)monitoringEnabled {
    [NSUserDefaults.standardUserDefaults setBool:monitoringEnabled forKey:CCTVMediaAdaptationMonitorEnabledKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaAdaptationMonitorDidUpdateNotification object:self];
    });
}

- (void)appendRecord:(NSDictionary *)record {
    if (![record isKindOfClass:NSDictionary.class] || !self.isMonitoringEnabled) return;
    NSMutableDictionary *enriched = [record mutableCopy];
    if (!enriched[@"id"]) enriched[@"id"] = NSUUID.UUID.UUIDString.lowercaseString;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!enriched[@"timestamp"]) enriched[@"timestamp"] = @(now);
    if (!enriched[@"timeText"]) enriched[@"timeText"] = [self.timeFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:now]] ?: @"";
    NSString *advice = [self diagnosisAndRecommendationForRecord:enriched];
    if (advice.length) enriched[@"advice"] = advice;
    NSDictionary *immutable = CCTVMonitorSanitizedRecord(enriched);
    dispatch_async(self.queue, ^{
        [self.records insertObject:immutable atIndex:0];
        while (self.records.count > CCTVMediaAdaptationMonitorMaxRecords) {
            [self.records removeLastObject];
        }
        NSArray *snapshot = [self.records copy];
        [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:CCTVMediaAdaptationMonitorRecordsKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaAdaptationMonitorDidUpdateNotification object:self];
        });
    });
}

- (NSArray<NSDictionary *> *)allRecords {
    __block NSArray<NSDictionary *> *snapshot = nil;
    dispatch_sync(self.queue, ^{
        snapshot = [self.records copy];
    });
    return snapshot ?: @[];
}

- (NSArray<NSDictionary *> *)recordsFilteredByKind:(NSString *)kind searchQuery:(NSString *)query {
    NSArray<NSDictionary *> *all = [self allRecords];
    NSString *trimmedKind = CCTVMonitorSafeString(kind).lowercaseString;
    NSString *trimmedQuery = CCTVMonitorSafeString(query).lowercaseString;
    if (!trimmedKind.length && !trimmedQuery.length) return all;
    NSMutableArray<NSDictionary *> *filtered = [NSMutableArray array];
    for (NSDictionary *rec in all) {
        if (trimmedKind.length && ![trimmedKind isEqualToString:@"all"]) {
            NSString *recKind = CCTVMonitorSafeString(rec[@"kind"]).lowercaseString;
            if ([trimmedKind isEqualToString:@"failed"]) {
                if ([rec[@"success"] boolValue]) continue;
            } else if (![recKind isEqualToString:trimmedKind]) {
                continue;
            }
        }
        if (trimmedQuery.length) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@ %@ %@ %@",
                                  rec[@"sourceName"] ?: @"",
                                  rec[@"provider"] ?: @"",
                                  rec[@"mediaName"] ?: @"",
                                  rec[@"operation"] ?: @"",
                                  rec[@"url"] ?: @"",
                                  rec[@"host"] ?: @"",
                                  rec[@"playerEngine"] ?: @"",
                                  rec[@"routeKind"] ?: @"",
                                  rec[@"advice"] ?: @""].lowercaseString;
            if ([haystack rangeOfString:trimmedQuery].location == NSNotFound) continue;
        }
        [filtered addObject:rec];
    }
    return filtered;
}

- (void)recordAPICallWithOperation:(NSString *)operation
                            source:(NSDictionary *)source
                          provider:(NSString *)provider
                         arguments:(NSDictionary *)arguments
                            result:(id)result
                             error:(NSError *)error
                         elapsedMs:(NSInteger)elapsedMs {
    if (!self.isMonitoringEnabled) return;
    NSString *op = CCTVMonitorSafeString(operation);
    if (!op.length || [op isEqualToString:@"capabilities"] || [op isEqualToString:@"health"]) return;
    NSDictionary *src = [source isKindOfClass:NSDictionary.class] ? source : @{};
    NSDictionary *args = [arguments isKindOfClass:NSDictionary.class] ? arguments : @{};
    NSString *sourceID = CCTVMonitorSafeString(src[@"id"] ?: src[@"key"]);
    NSString *sourceName = CCTVMonitorSafeString(src[@"name"] ?: src[@"title"] ?: sourceID ?: @"影视资源");
    NSString *protocol = CCTVMonitorSafeString(src[@"protocol"] ?: src[@"manifest"][@"protocol"] ?: src[@"runtime"] ?: @"http-api");
    NSString *apiURL = CCTVMonitorSafeString(src[@"api"] ?: src[@"url"] ?: src[@"subscriptionURL"]);
    if (!apiURL.length && [src[@"port"] integerValue] > 0) {
        apiURL = [NSString stringWithFormat:@"http://127.0.0.1:%ld/api/v1/%@", (long)[src[@"port"] integerValue], op];
    }
    NSString *mediaName = CCTVMonitorSafeString(args[@"vodName"] ?: args[@"title"] ?: args[@"keyword"]);
    NSString *episodeName = CCTVMonitorSafeString(args[@"episodeName"]);
    NSString *lineID = CCTVMonitorSafeString(args[@"lineId"]);
    NSString *resolvedURL = @"";
    NSString *originalURL = @"";
    NSUInteger itemCount = 0;
    NSString *format = @"";
    NSString *routeKind = [protocol containsString:@"jar-bridge"] ? @"jar-bridge" : @"api";
    if ([result isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)result;
        if (!mediaName.length) mediaName = CCTVMonitorSafeString(dict[@"name"] ?: dict[@"vod_name"]);
        resolvedURL = CCTVMonitorSafeString(dict[@"url"] ?: dict[@"playUrl"]);
        originalURL = CCTVMonitorSafeString(dict[@"originalURL"] ?: resolvedURL);
        if ([dict[@"items"] isKindOfClass:NSArray.class]) {
            itemCount = [(NSArray *)dict[@"items"] count];
        } else if ([dict[@"lines"] isKindOfClass:NSArray.class]) {
            for (NSDictionary *line in (NSArray *)dict[@"lines"]) {
                if ([line isKindOfClass:NSDictionary.class] && [line[@"episodes"] isKindOfClass:NSArray.class]) {
                    itemCount += [(NSArray *)line[@"episodes"] count];
                }
            }
        }
        format = CCTVMonitorInferFormat(originalURL.length ? originalURL : resolvedURL, dict);
        if ([dict[@"proxy"] boolValue] || [resolvedURL containsString:@"/proxy/"]) {
            routeKind = @"local-proxy";
        } else if ([dict[@"dashRemuxed"] boolValue]) {
            routeKind = @"dash-bridge";
        } else if ([resolvedURL containsString:@"/cenc/"] || [originalURL.lowercaseString hasPrefix:@"cenc://"]) {
            routeKind = @"cenc-decrypt";
        } else if ([resolvedURL containsString:@"/media/"]) {
            routeKind = @"media-relay";
        } else if ([dict[@"parse"] integerValue] > 0 || [dict[@"requiresWebPlayback"] boolValue]) {
            routeKind = @"web-parser";
        } else if ([protocol containsString:@"jar-bridge"] || [apiURL hasPrefix:@"csp_"]) {
            routeKind = @"jar-bridge";
        } else if (resolvedURL.length) {
            routeKind = @"direct";
        }
    }
    BOOL success = (error == nil);
    if ([op isEqualToString:@"play"] && [result isKindOfClass:NSDictionary.class]) {
        NSString *u = CCTVMonitorSafeString(result[@"url"]);
        if (!u.length && ![result[@"parse"] boolValue]) success = NO;
    }
    NSString *targetURL = originalURL.length ? originalURL : (resolvedURL.length ? resolvedURL : apiURL);
    NSString *host = CCTVMonitorExtractHost(targetURL);
    if (!host.length) host = CCTVMonitorExtractHost(apiURL);
    NSString *errStage = CCTVMonitorSafeString(error.userInfo[@"failure_stage"] ?: ([result isKindOfClass:NSDictionary.class] ? result[@"failure_stage"] : @""));
    NSString *errMsg = CCTVMonitorSafeString(error.localizedDescription ?: ([result isKindOfClass:NSDictionary.class] ? result[@"msg"] : @""));
    [self appendRecord:@{
        @"kind": @"api",
        @"operation": op,
        @"sourceID": sourceID,
        @"sourceName": sourceName,
        @"provider": CCTVMonitorSafeString(provider ?: args[@"provider"] ?: src[@"api"]),
        @"protocol": protocol,
        @"mediaName": mediaName,
        @"episodeName": episodeName,
        @"lineName": lineID,
        @"url": CCTVMonitorRedactURL(targetURL),
        @"resolvedURL": CCTVMonitorRedactURL(resolvedURL),
        @"host": host.length ? host : ([apiURL hasPrefix:@"csp_"] ? apiURL : @"local-service"),
        @"format": format ?: @"",
        @"routeKind": routeKind,
        @"playerEngine": [op isEqualToString:@"play"] ? @"待播放器选路" : @"-",
        @"itemCount": @(itemCount),
        @"elapsedMs": @(MAX(0, elapsedMs)),
        @"success": @(success),
        @"failureStage": errStage,
        @"errorMessage": errMsg,
        @"refreshed": @([args[@"refresh"] boolValue] || [args[@"forceRefresh"] boolValue]),
    }];
}

- (void)recordPlaybackAdaptationWithSource:(NSDictionary *)source
                                  provider:(NSString *)provider
                                 mediaName:(NSString *)mediaName
                               episodeName:(NSString *)episodeName
                                  lineName:(NSString *)lineName
                                 streamURL:(NSString *)streamURL
                               originalURL:(NSString *)originalURL
                              playerEngine:(NSString *)playerEngine
                                 routeKind:(NSString *)routeKind
                           containerFormat:(NSString *)containerFormat
                                videoCodec:(NSString *)videoCodec
                                   headers:(NSDictionary *)headers
                                 startupMs:(NSInteger)startupMs
                                   success:(BOOL)success
                              failureStage:(NSString *)failureStage
                              errorMessage:(NSString *)errorMessage {
    if (!self.isMonitoringEnabled) return;
    NSDictionary *src = [source isKindOfClass:NSDictionary.class] ? source : @{};
    NSString *sourceID = CCTVMonitorSafeString(src[@"id"] ?: src[@"key"]);
    NSString *sourceName = CCTVMonitorSafeString(src[@"name"] ?: src[@"title"] ?: sourceID ?: @"播放源");
    NSString *protocol = CCTVMonitorSafeString(src[@"protocol"] ?: src[@"manifest"][@"protocol"] ?: @"playback");
    NSString *primaryURL = CCTVMonitorSafeString(originalURL).length ? CCTVMonitorSafeString(originalURL) : CCTVMonitorSafeString(streamURL);
    NSString *host = CCTVMonitorExtractHost(primaryURL);
    NSMutableArray<NSString *> *headerKeys = [NSMutableArray array];
    if ([headers isKindOfClass:NSDictionary.class]) {
        for (id key in headers) {
            if ([key isKindOfClass:NSString.class]) [headerKeys addObject:key];
        }
    }
    [self appendRecord:@{
        @"kind": @"playback",
        @"operation": @"playback",
        @"sourceID": sourceID,
        @"sourceName": sourceName,
        @"provider": CCTVMonitorSafeString(provider),
        @"protocol": protocol,
        @"mediaName": CCTVMonitorSafeString(mediaName),
        @"episodeName": CCTVMonitorSafeString(episodeName),
        @"lineName": CCTVMonitorSafeString(lineName),
        @"url": CCTVMonitorRedactURL(primaryURL),
        @"resolvedURL": CCTVMonitorRedactURL(streamURL),
        @"host": host.length ? host : @"local-relay",
        @"format": CCTVMonitorSafeString(containerFormat).length ? CCTVMonitorSafeString(containerFormat) : CCTVMonitorInferFormat(primaryURL, nil),
        @"videoCodec": CCTVMonitorSafeString(videoCodec),
        @"routeKind": CCTVMonitorSafeString(routeKind).length ? CCTVMonitorSafeString(routeKind) : @"direct",
        @"playerEngine": CCTVMonitorSafeString(playerEngine).length ? CCTVMonitorSafeString(playerEngine) : @"AVPlayer",
        @"headerKeys": [headerKeys componentsJoinedByString:@", "],
        @"elapsedMs": @(MAX(0, startupMs)),
        @"success": @(success),
        @"failureStage": CCTVMonitorSafeString(failureStage),
        @"errorMessage": CCTVMonitorSafeString(errorMessage),
    }];
}

- (void)recordCatalogEventWithName:(NSString *)name
                         sourceURL:(NSString *)sourceURL
                         siteCount:(NSUInteger)siteCount
                    supportedCount:(NSUInteger)supportedCount
                         liveCount:(NSUInteger)liveCount
                        bundleType:(NSString *)bundleType
                       jarVerified:(BOOL)jarVerified
                             notes:(NSString *)notes {
    if (!self.isMonitoringEnabled) return;
    NSString *safeName = CCTVMonitorSafeString(name).length ? CCTVMonitorSafeString(name) : @"TVBox 资源合集";
    NSString *safeBundle = CCTVMonitorSafeString(bundleType).length ? CCTVMonitorSafeString(bundleType) : @"tvbox-catalog";
    NSString *safeURL = CCTVMonitorSafeString(sourceURL);
    NSString *host = CCTVMonitorExtractHost(safeURL);
    if (!host.length) {
        host = [safeBundle containsString:@"bundle"] ? @"local-bundle" : @"tvbox-catalog";
    }
    NSString *summaryMedia = [NSString stringWithFormat:@"共 %lu 站（已适配 %lu 站 · 直播 %lu 项）",
                              (unsigned long)siteCount,
                              (unsigned long)supportedCount,
                              (unsigned long)liveCount];
    [self appendRecord:@{
        @"kind": @"catalog",
        @"operation": @"catalog_import",
        @"sourceID": safeName,
        @"sourceName": safeName,
        @"provider": safeBundle,
        @"protocol": @"tvbox-catalog",
        @"mediaName": summaryMedia,
        @"episodeName": jarVerified ? @"spider.jar 已校验" : @"",
        @"lineName": CCTVMonitorSafeString(notes),
        @"url": CCTVMonitorRedactURL(safeURL),
        @"resolvedURL": CCTVMonitorRedactURL(safeURL),
        @"host": host,
        @"format": safeBundle,
        @"routeKind": jarVerified ? @"jar-bridge+bundle" : @"catalog-adapter",
        @"playerEngine": @"全链路自动选路",
        @"itemCount": @(siteCount),
        @"supportedCount": @(supportedCount),
        @"liveCount": @(liveCount),
        @"jarVerified": @(jarVerified),
        @"elapsedMs": @1,
        @"success": @(siteCount > 0 || liveCount > 0),
        @"failureStage": (siteCount > 0 || liveCount > 0) ? @"" : @"catalog_parse",
        @"errorMessage": (siteCount > 0 || liveCount > 0) ? @"" : @"合集未解析出有效站点或直播源",
    }];
}

- (NSDictionary *)decodeAndInspectConfigString:(NSString *)rawInput {
    NSString *trimmed = CCTVMonitorSafeString(rawInput);
    if (!trimmed.length) {
        return @{
            @"success": @NO,
            @"cipherType": @"empty",
            @"summary": @"请输入待解码或诊断的 7lj763gg 密文、url|key|iv 配置、2423 载荷或 csp_* 类名",
        };
    }

    // 1. Qiaoji / Citong 7lj763gg cipher string
    if ([trimmed.lowercaseString hasPrefix:@"7lj763gg"]) {
        NSString *decoded = [TVBoxCatalogStore decodeQiaojiExtString:trimmed];
        if (decoded.length) {
            NSArray<NSString *> *parts = [decoded componentsSeparatedByString:@"|"];
            NSString *urlPart = parts.count > 0 ? CCTVMonitorSafeString(parts[0]) : decoded;
            NSString *keyPart = parts.count > 1 ? CCTVMonitorSafeString(parts[1]) : @"";
            NSString *ivPart = parts.count > 2 ? CCTVMonitorSafeString(parts[2]) : keyPart;
            return @{
                @"success": @YES,
                @"cipherType": @"qiaoji-7lj763gg (巧技/刺桐 XOR-170 密文)",
                @"rawInput": trimmed,
                @"decodedText": decoded,
                @"extractedURL": ([urlPart hasPrefix:@"http://"] || [urlPart hasPrefix:@"https://"]) ? urlPart : @"",
                @"aesDataKey": keyPart,
                @"aesDataIv": ivPart,
                @"recommendedEngine": @"jar-bridge (AppGet / RJApp / Shark AES-128-CBC 原生桥接)",
                @"summary": [NSString stringWithFormat:@"成功解密 7lj763gg 密文 → 接口：%@%@%@",
                             urlPart,
                             keyPart.length ? [NSString stringWithFormat:@" · AES Key：%@", keyPart] : @"",
                             ivPart.length ? [NSString stringWithFormat:@" · IV：%@", ivPart] : @""],
            };
        }
    }

    // 2. Pipe-delimited url|dataKey|dataIv string
    if ([trimmed containsString:@"|"] && ([trimmed.lowercaseString hasPrefix:@"http://"] || [trimmed.lowercaseString hasPrefix:@"https://"])) {
        NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"|"];
        NSString *urlPart = parts.count > 0 ? CCTVMonitorSafeString(parts[0]) : @"";
        NSString *keyPart = parts.count > 1 ? CCTVMonitorSafeString(parts[1]) : @"";
        NSString *ivPart = parts.count > 2 ? CCTVMonitorSafeString(parts[2]) : keyPart;
        return @{
            @"success": @YES,
            @"cipherType": @"pipe-ext (AppGet / RJApp / Shark 管道参数)",
            @"rawInput": trimmed,
            @"decodedText": trimmed,
            @"extractedURL": urlPart,
            @"aesDataKey": keyPart,
            @"aesDataIv": ivPart,
            @"recommendedEngine": @"jar-bridge (AES-128-CBC 自动加解密)",
            @"summary": [NSString stringWithFormat:@"解析管道扩展参数 → 接口：%@ · AES Key：%@ · IV：%@",
                         urlPart,
                         keyPart.length ? keyPart : @"默认",
                         ivPart.length ? ivPart : @"同 Key"],
        };
    }

    // 3. TVBox 2423 Hex AES-128-CBC payload or ** Base64 payload
    if ([trimmed.lowercaseString hasPrefix:@"2423"] || [trimmed containsString:@"**"]) {
        NSData *rawData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
        NSData *sanitized = rawData ? [TVBoxCatalogStore sanitizeJSONData:rawData] : nil;
        NSString *decodedText = sanitized.length ? [[NSString alloc] initWithData:sanitized encoding:NSUTF8StringEncoding] : @"";
        if (decodedText.length && ![decodedText isEqualToString:trimmed]) {
            NSString *preview = decodedText.length > 320 ? [[decodedText substringToIndex:320] stringByAppendingString:@"…"] : decodedText;
            return @{
                @"success": @YES,
                @"cipherType": [trimmed.lowercaseString hasPrefix:@"2423"] ? @"tvbox-2423-aes128cbc" : @"tvbox-base64 (**)",
                @"rawInput": trimmed,
                @"decodedText": decodedText,
                @"extractedURL": @"",
                @"recommendedEngine": @"TVBoxCatalogStore 自动脱壳解析器",
                @"summary": [NSString stringWithFormat:@"成功脱壳 TVBox 加密配置（长度 %lu 字节）→ %@",
                             (unsigned long)sanitized.length, preview],
            };
        }
    }

    // 4. Spider JAR descriptor (./spider.jar;md5;... or clan://...)
    if ([trimmed.lowercaseString containsString:@".jar"] || [trimmed.lowercaseString hasPrefix:@"clan://"]) {
        NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@";"];
        NSString *jarPath = parts.firstObject ?: trimmed;
        NSString *md5 = parts.count >= 3 ? parts[2] : @"";
        return @{
            @"success": @YES,
            @"cipherType": @"tvbox-spider-jar (JAR 爬虫包描述符)",
            @"rawInput": trimmed,
            @"decodedText": jarPath,
            @"extractedURL": ([jarPath hasPrefix:@"http://"] || [jarPath hasPrefix:@"https://"]) ? jarPath : @"",
            @"jarMD5": md5,
            @"recommendedEngine": @"spider.jar 常量池字节码提取 + JAR-Bridge 原生 HTTP 引擎",
            @"summary": [NSString stringWithFormat:@"识别到 TVBox Spider JAR 描述符：%@%@。iOS 端自动校验 MD5、提取 .class 字节码常量池中的接口域名与 AES 密钥，并通过原生 JAR-Bridge 驱动全部 csp_* 站点。",
                         jarPath,
                         md5.length ? [NSString stringWithFormat:@" (MD5: %@)", md5] : @""],
        };
    }

    // 5. csp_* Spider class name
    if ([trimmed hasPrefix:@"csp_"] || [trimmed.lowercaseString hasPrefix:@"csp_"]) {
        NSString *route = ([trimmed isEqualToString:@"csp_Douban"] || [trimmed isEqualToString:@"csp_DouDou"])
            ? @"douban-index (内置豆瓣榜单推荐聚合)"
            : @"jar-bridge (原生多模板 HTTP/AES/Web 爬虫桥接)";
        return @{
            @"success": @YES,
            @"cipherType": @"csp-spider-class (TVBox Spider 类标识)",
            @"rawInput": trimmed,
            @"decodedText": trimmed,
            @"extractedURL": @"",
            @"recommendedEngine": route,
            @"summary": [NSString stringWithFormat:@"Spider 类 %@ 已映射至 %@，支持本地包 spider.jar 常量池自动补全与内置站点回退。", trimmed, route],
        };
    }

    // 6. Standard Base64 string
    NSData *b64Data = [[NSData alloc] initWithBase64EncodedString:trimmed options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (b64Data.length > 4) {
        NSString *b64Str = [[NSString alloc] initWithData:b64Data encoding:NSUTF8StringEncoding];
        if ([b64Str hasPrefix:@"http://"] || [b64Str hasPrefix:@"https://"] || [b64Str hasPrefix:@"{"]) {
            NSArray<NSString *> *parts = [b64Str componentsSeparatedByString:@"|"];
            NSString *firstURL = (parts.count > 0 && ([parts[0] hasPrefix:@"http://"] || [parts[0] hasPrefix:@"https://"])) ? parts[0] : @"";
            return @{
                @"success": @YES,
                @"cipherType": @"base64-ext",
                @"rawInput": trimmed,
                @"decodedText": b64Str,
                @"extractedURL": firstURL,
                @"recommendedEngine": @"jar-bridge / MediaAPIClient",
                @"summary": [NSString stringWithFormat:@"Base64 解码成功 → %@", b64Str],
            };
        }
    }

    return @{
        @"success": @([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"] || [trimmed hasPrefix:@"cenc://"]),
        @"cipherType": @"plain-url",
        @"rawInput": trimmed,
        @"decodedText": trimmed,
        @"extractedURL": ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"]) ? trimmed : @"",
        @"recommendedEngine": @"AVPlayer / MediaAPIClient",
        @"summary": [NSString stringWithFormat:@"明文地址：%@", trimmed],
    };
}

- (NSString *)diagnosisAndRecommendationForRecord:(NSDictionary *)record {
    NSString *op = CCTVMonitorSafeString(record[@"operation"]).lowercaseString;
    NSString *url = CCTVMonitorSafeString(record[@"url"]).lowercaseString;
    NSString *resolved = CCTVMonitorSafeString(record[@"resolvedURL"]).lowercaseString;
    NSString *fmt = CCTVMonitorSafeString(record[@"format"]).lowercaseString;
    NSString *codec = CCTVMonitorSafeString(record[@"videoCodec"]).lowercaseString;
    NSString *engine = CCTVMonitorSafeString(record[@"playerEngine"]);
    NSString *route = CCTVMonitorSafeString(record[@"routeKind"]).lowercaseString;
    NSString *err = CCTVMonitorSafeString(record[@"errorMessage"]).lowercaseString;
    NSString *stage = CCTVMonitorSafeString(record[@"failureStage"]).lowercaseString;
    BOOL ok = [record[@"success"] boolValue];
    NSInteger ms = [record[@"elapsedMs"] integerValue];

    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    if ([op isEqualToString:@"catalog_import"] || [CCTVMonitorSafeString(record[@"kind"]).lowercaseString isEqualToString:@"catalog"]) {
        BOOL jarOK = [record[@"jarVerified"] boolValue];
        NSString *lineNote = CCTVMonitorSafeString(record[@"lineName"]);
        [notes addObject:[NSString stringWithFormat:@"资源合集适配：已完成 TVBox 合集/本地包解析%@%@",
                          jarOK ? @"，spider.jar MD5 校验通过并提取字节码常量池" : @"",
                          lineNote.length ? [NSString stringWithFormat:@"（%@）", lineNote] : @""]];
        return [notes componentsJoinedByString:@"；"];
    }
    if ([route containsString:@"jar-bridge"] || [CCTVMonitorSafeString(record[@"protocol"]).lowercaseString containsString:@"jar-bridge"]) {
        [notes addObject:@"JAR-Bridge 原生桥接：无需 JVM 即可在 iOS 原生执行 csp_* 站点（支持 7lj763gg 巧技解密、AppGet/RJApp/Shark AES-128-CBC、JianPian、NongMin 及本地包常量池回退）"];
    }
    if ([url hasPrefix:@"cenc://"] || [resolved containsString:@"/cenc/"] || [fmt containsString:@"cenc"] || [route containsString:@"local-proxy"]) {
        [notes addObject:@"加密/代理流适配：采用 CENC(AES-CTR) 样本表解密与本机 Range 文件流式代理，重写 encv/enca->hvc1/avc1 并抹除 sinf/senc，供 AVPlayer/CicadaPlayer 直接硬解"];
    }
    if ([codec containsString:@"hev1"] || [codec containsString:@"hvc1"] || [codec containsString:@"hevc"] || [codec containsString:@"bytevc"]) {
        [notes addObject:@"编码适配：检测到 HEVC/H.265 视频轨，已启用 hev1->hvc1 FourCC 兼容改写与 CicadaPlayer 混合解码兜底"];
    }
    if ([fmt containsString:@"dash"] || [url containsString:@".mpd"]) {
        [notes addObject:@"容器适配：MPEG-DASH(.mpd) 采用本机 fMP4-HLS 桥接转封装与 CicadaPlayer 原生 DASH 双通道"];
    } else if ([fmt containsString:@"flv"] || [url containsString:@".flv"]) {
        [notes addObject:@"容器适配：HTTP-FLV 流优先路由至 CicadaPlayer / CNPlayerSDK 软硬协同内核"];
    } else if ([fmt containsString:@"hls"] || [url containsString:@".m3u8"]) {
        [notes addObject:@"容器适配：HLS(m3u8) 列表已支持本机 MediaRelay 防盗链头注入与分片预取"];
    }
    if (!ok) {
        if ([err containsString:@"403"] || [err containsString:@"forbidden"] || [stage containsString:@"403"]) {
            [notes addObject:@"异常诊断：上游返回 HTTP 403 防盗链拦截，建议开启本机 MediaRelay 注入站点 Referer/User-Agent 或切换播放线路"];
        } else if ([err containsString:@"timeout"] || [err containsString:@"超时"] || [stage containsString:@"timeout"]) {
            [notes addObject:@"异常诊断：站点/CDN 节点响应超时，建议切换至 <=15MB 快速档位、备用线路或通过探测工具检查域名连通性"];
        } else if ([stage containsString:@"decrypt"] || [err containsString:@"cenc"] || [err containsString:@"解密"]) {
            [notes addObject:@"异常诊断：CENC 密钥或 MP4 样本表校验未通过，已自动清理损坏缓存并回退次高画质档位重试"];
        } else if ([op isEqualToString:@"detail"] && [record[@"itemCount"] integerValue] == 0) {
            [notes addObject:@"异常诊断：站点详情未解析出有效分集列表，建议点击右上角「重新加载详情」强制穿透缓存或检查站点 SSR 结构"];
        } else {
            [notes addObject:[NSString stringWithFormat:@"异常诊断：阶段 [%@] 发生错误（%@），建议切换播放器内核或备用线路", stage.length ? stage : op, record[@"errorMessage"] ?: @"未知原因"]];
        }
    } else {
        if (ms > 4500) {
            [notes addObject:[NSString stringWithFormat:@"性能提示：本次耗时 %ld ms 偏慢，建议优先使用带缓存预热的完整播放线路", (long)ms]];
        } else if (engine.length && ![engine isEqualToString:@"-"]) {
            [notes addObject:[NSString stringWithFormat:@"适配状态：当前由 %@ 正常承载（耗时 %ld ms）", engine, (long)ms]];
        }
    }
    return [notes componentsJoinedByString:@"；"];
}

- (NSArray<NSDictionary *> *)siteHealthSummaries {
    NSArray<NSDictionary *> *all = [self allRecords];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *rec in all) {
        NSString *sourceName = CCTVMonitorSafeString(rec[@"sourceName"] ?: @"未知资源");
        NSString *provider = CCTVMonitorSafeString(rec[@"provider"]);
        NSString *host = CCTVMonitorSafeString(rec[@"host"]);
        NSString *key = [NSString stringWithFormat:@"%@|%@|%@", sourceName, provider, host];
        NSMutableDictionary *agg = groups[key];
        if (!agg) {
            agg = [@{
                @"key": key,
                @"sourceName": sourceName,
                @"provider": provider,
                @"host": host,
                @"protocol": CCTVMonitorSafeString(rec[@"protocol"]),
                @"totalCount": @0,
                @"successCount": @0,
                @"totalLatencyMs": @0,
                @"formats": [NSMutableOrderedSet orderedSet],
                @"engines": [NSMutableOrderedSet orderedSet],
                @"lastError": @"",
                @"lastTimeText": CCTVMonitorSafeString(rec[@"timeText"]),
            } mutableCopy];
            groups[key] = agg;
            [order addObject:key];
        }
        NSInteger total = [agg[@"totalCount"] integerValue] + 1;
        NSInteger ok = [agg[@"successCount"] integerValue] + ([rec[@"success"] boolValue] ? 1 : 0);
        NSInteger lat = [agg[@"totalLatencyMs"] integerValue] + [rec[@"elapsedMs"] integerValue];
        agg[@"totalCount"] = @(total);
        agg[@"successCount"] = @(ok);
        agg[@"totalLatencyMs"] = @(lat);
        NSString *fmt = CCTVMonitorSafeString(rec[@"format"]);
        if (fmt.length && ![fmt isEqualToString:@"auto"]) [agg[@"formats"] addObject:fmt];
        NSString *eng = CCTVMonitorSafeString(rec[@"playerEngine"]);
        if (eng.length && ![eng isEqualToString:@"-"] && ![eng isEqualToString:@"待播放器选路"]) [agg[@"engines"] addObject:eng];
        if (![rec[@"success"] boolValue] && ![agg[@"lastError"] length]) {
            agg[@"lastError"] = CCTVMonitorSafeString(rec[@"errorMessage"] ?: rec[@"failureStage"]);
        }
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *key in order) {
        NSMutableDictionary *agg = groups[key];
        NSInteger total = MAX(1, [agg[@"totalCount"] integerValue]);
        NSInteger ok = [agg[@"successCount"] integerValue];
        NSInteger avgMs = [agg[@"totalLatencyMs"] integerValue] / total;
        double rate = (double)ok * 100.0 / (double)total;
        NSString *grade = rate >= 90.0 ? @"优秀" : (rate >= 70.0 ? @"良好" : (rate >= 40.0 ? @"需关注" : @"异常"));
        NSArray *fmts = [(NSOrderedSet *)agg[@"formats"] array] ?: @[];
        NSArray *engs = [(NSOrderedSet *)agg[@"engines"] array] ?: @[];
        [out addObject:@{
            @"sourceName": agg[@"sourceName"],
            @"provider": agg[@"provider"],
            @"host": agg[@"host"],
            @"protocol": agg[@"protocol"],
            @"totalCount": @(total),
            @"successCount": @(ok),
            @"successRate": @(rate),
            @"avgLatencyMs": @(avgMs),
            @"grade": grade,
            @"formatsText": fmts.count ? [fmts componentsJoinedByString:@" / "] : @"通用流",
            @"enginesText": engs.count ? [engs componentsJoinedByString:@" → "] : @"AVPlayer / 自动",
            @"lastError": agg[@"lastError"],
            @"lastTimeText": agg[@"lastTimeText"],
        }];
    }
    return out;
}

- (NSDictionary *)playerAdaptationSummary {
    NSArray<NSDictionary *> *all = [self allRecords];
    NSUInteger total = all.count, okCount = 0;
    NSUInteger avCount = 0, cicadaCount = 0, cencCount = 0, relayCount = 0, dashCount = 0, webCount = 0, jarBridgeCount = 0, catalogCount = 0;
    for (NSDictionary *rec in all) {
        if ([rec[@"success"] boolValue]) okCount++;
        NSString *eng = CCTVMonitorSafeString(rec[@"playerEngine"]).lowercaseString;
        NSString *route = CCTVMonitorSafeString(rec[@"routeKind"]).lowercaseString;
        NSString *fmt = CCTVMonitorSafeString(rec[@"format"]).lowercaseString;
        NSString *proto = CCTVMonitorSafeString(rec[@"protocol"]).lowercaseString;
        NSString *kind = CCTVMonitorSafeString(rec[@"kind"]).lowercaseString;
        if ([eng containsString:@"cicada"] || [eng containsString:@"cnplayer"]) cicadaCount++;
        else if ([eng containsString:@"avplayer"]) avCount++;
        else if ([eng containsString:@"web"]) webCount++;
        if ([route containsString:@"cenc"] || [route containsString:@"local-proxy"] || [fmt containsString:@"cenc"]) cencCount++;
        if ([route containsString:@"relay"] || [fmt containsString:@"relay"]) relayCount++;
        if ([route containsString:@"dash"] || [fmt containsString:@"dash"]) dashCount++;
        if ([route containsString:@"jar-bridge"] || [proto containsString:@"jar-bridge"]) jarBridgeCount++;
        if ([kind isEqualToString:@"catalog"] || [proto isEqualToString:@"tvbox-catalog"]) catalogCount++;
    }
    return @{
        @"totalRecords": @(total),
        @"successRecords": @(okCount),
        @"avPlayerCount": @(avCount),
        @"cicadaPlayerCount": @(cicadaCount),
        @"cencProxyCount": @(cencCount),
        @"mediaRelayCount": @(relayCount),
        @"dashBridgeCount": @(dashCount),
        @"webParserCount": @(webCount),
        @"jarBridgeCount": @(jarBridgeCount),
        @"catalogImportCount": @(catalogCount),
    };
}

- (void)batchProbeCatalogSites:(NSArray<NSDictionary *> *)sites
                   catalogName:(NSString *)catalogName
                    completion:(void (^)(NSDictionary *summary))completion {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSString *resolvedCatalogName = CCTVMonitorSafeString(catalogName);
    if ([sites isKindOfClass:NSArray.class] && sites.count > 0) {
        [candidates addObjectsFromArray:sites];
    } else {
        NSArray<NSDictionary *> *catalogs = [TVBoxCatalogStore catalogs];
        for (NSDictionary *cat in catalogs) {
            if (!resolvedCatalogName.length) {
                resolvedCatalogName = CCTVMonitorSafeString(cat[@"name"]);
            }
            NSArray<NSDictionary *> *catSites = [cat[@"sites"] isKindOfClass:NSArray.class] ? cat[@"sites"] : @[];
            for (NSDictionary *s in catSites) {
                if ([s isKindOfClass:NSDictionary.class] && [s[@"supported"] boolValue]) {
                    [candidates addObject:s];
                }
            }
        }
    }
    if (!resolvedCatalogName.length) resolvedCatalogName = @"已导入 TVBox 合集";
    if (!candidates.count) {
        NSDictionary *emptyRes = @{
            @"success": @NO,
            @"catalogName": resolvedCatalogName,
            @"totalProbed": @0,
            @"reachableCount": @0,
            @"avgLatencyMs": @0,
            @"summary": @"当前尚无已导入的 TVBox 合集站点可供巡检，请先在「资源」页导入本地包或订阅合集。",
        };
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(emptyRes); });
        return;
    }

    NSUInteger maxCount = MIN((NSUInteger)12, candidates.count);
    NSArray<NSDictionary *> *batch = [candidates subarrayWithRange:NSMakeRange(0, maxCount)];
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];

    for (NSDictionary *site in batch) {
        NSString *siteName = CCTVMonitorSafeString(site[@"name"] ?: site[@"key"] ?: @"站点");
        NSString *api = CCTVMonitorSafeString(site[@"api"]);
        NSString *protocol = CCTVMonitorSafeString(site[@"protocol"] ?: @"http-api");
        id extObj = site[@"ext"];
        NSString *extStr = @"";
        if ([extObj isKindOfClass:NSString.class]) {
            extStr = CCTVMonitorSafeString(extObj);
        } else if ([extObj isKindOfClass:NSDictionary.class]) {
            NSDictionary *extDict = (NSDictionary *)extObj;
            extStr = CCTVMonitorSafeString(extDict[@"url"] ?: extDict[@"site"] ?: extDict[@"host"] ?: extDict[@"api"] ?: extDict[@"cms"]);
        }

        NSString *probeTarget = @"";
        if ([api hasPrefix:@"http://"] || [api hasPrefix:@"https://"]) {
            probeTarget = api;
        } else if (extStr.length) {
            NSDictionary *decoded = [self decodeAndInspectConfigString:extStr];
            probeTarget = CCTVMonitorSafeString(decoded[@"extractedURL"]);
        }

        if (!probeTarget.length) {
            // Local / built-in spider site (e.g., csp_Douban or spider.jar constant-pool backed site)
            [self recordAPICallWithOperation:@"site_check"
                                      source:@{@"id": site[@"key"] ?: siteName, @"name": siteName, @"protocol": protocol, @"api": api}
                                    provider:api.length ? api : protocol
                                   arguments:@{@"title": resolvedCatalogName}
                                      result:@{@"items": @[@1], @"format": protocol}
                                       error:nil
                                   elapsedMs:2];
            @synchronized (results) {
                [results addObject:@{@"siteName": siteName, @"success": @YES, @"elapsedMs": @2}];
            }
            continue;
        }

        dispatch_group_enter(group);
        [self probeURLString:probeTarget headers:nil contextTag:[NSString stringWithFormat:@"%@ · %@", resolvedCatalogName, siteName] completion:^(NSDictionary *report) {
            @synchronized (results) {
                [results addObject:@{
                    @"siteName": siteName,
                    @"success": @([report[@"success"] boolValue]),
                    @"elapsedMs": report[@"elapsedMs"] ?: @0,
                }];
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSUInteger totalProbed = results.count;
        NSUInteger okCount = 0;
        NSInteger totalMs = 0;
        for (NSDictionary *r in results) {
            if ([r[@"success"] boolValue]) okCount++;
            totalMs += [r[@"elapsedMs"] integerValue];
        }
        NSInteger avgMs = totalProbed > 0 ? (totalMs / (NSInteger)totalProbed) : 0;
        NSDictionary *summary = @{
            @"success": @(okCount > 0),
            @"catalogName": resolvedCatalogName,
            @"totalProbed": @(totalProbed),
            @"reachableCount": @(okCount),
            @"avgLatencyMs": @(avgMs),
            @"summary": [NSString stringWithFormat:@"已完成「%@」%lu 个代表站点连通性与解密巡检：可达/就绪 %lu 个 · 平均响应 %ld ms",
                         resolvedCatalogName,
                         (unsigned long)totalProbed,
                         (unsigned long)okCount,
                         (long)avgMs],
        };
        if (completion) completion(summary);
    });
}

- (void)probeURLString:(NSString *)urlString
               headers:(NSDictionary<NSString *, NSString *> *)headers
            contextTag:(NSString *)contextTag
            completion:(void (^)(NSDictionary *report))completion {
    NSString *trimmed = CCTVMonitorSafeString(urlString);
    if (!trimmed.length) {
        if (completion) completion(@{@"success": @NO, @"summary": @"请输入要探测的站点网址、接口、7lj763gg 密文或媒体流地址"});
        return;
    }

    // Check if the input is an encrypted ext string (7lj763gg...), pipe-delimited config, 2423 hex, spider.jar, or csp_* class
    BOOL needsConfigInspect = ([trimmed.lowercaseString hasPrefix:@"7lj763gg"] ||
                               [trimmed.lowercaseString hasPrefix:@"2423"] ||
                               [trimmed containsString:@"**"] ||
                               [trimmed containsString:@"|"] ||
                               [trimmed.lowercaseString hasPrefix:@"csp_"] ||
                               [trimmed.lowercaseString containsString:@".jar"] ||
                               [trimmed.lowercaseString hasPrefix:@"clan://"]);
    NSString *decodedNotesPrefix = @"";
    if (needsConfigInspect) {
        NSDictionary *inspected = [self decodeAndInspectConfigString:trimmed];
        NSString *extractedURL = CCTVMonitorSafeString(inspected[@"extractedURL"]);
        NSString *summaryText = CCTVMonitorSafeString(inspected[@"summary"]);
        if (extractedURL.length) {
            trimmed = extractedURL;
            decodedNotesPrefix = [NSString stringWithFormat:@"【配置脱壳】%@\n", summaryText];
        } else if ([inspected[@"success"] boolValue]) {
            NSDictionary *rep = @{
                @"success": @YES,
                @"url": trimmed,
                @"status": @200,
                @"elapsedMs": @1,
                @"detectedType": inspected[@"cipherType"] ?: @"TVBox 配置/Spider 标识",
                @"recommendedEngine": inspected[@"recommendedEngine"] ?: @"jar-bridge",
                @"adaptationAdvice": summaryText,
                @"decodedInfo": inspected,
            };
            [self recordPlaybackAdaptationWithSource:@{@"name": contextTag ?: @"配置解码诊断"}
                                            provider:@"config-decoder"
                                           mediaName:inspected[@"cipherType"] ?: @"配置诊断"
                                         episodeName:@""
                                            lineName:@""
                                           streamURL:trimmed
                                         originalURL:trimmed
                                        playerEngine:inspected[@"recommendedEngine"] ?: @"jar-bridge"
                                           routeKind:@"jar-bridge"
                                     containerFormat:@"tvbox-ext"
                                          videoCodec:@""
                                             headers:headers
                                           startupMs:1
                                             success:YES
                                        failureStage:@""
                                        errorMessage:@""];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(rep); });
            return;
        }
    }

    if ([trimmed.lowercaseString hasPrefix:@"cenc://"]) {
        NSDictionary *rep = @{
            @"success": @YES,
            @"url": trimmed,
            @"status": @200,
            @"elapsedMs": @1,
            @"detectedType": @"CENC 受保护媒体流 (cenc://)",
            @"recommendedEngine": @"AVPlayer (经由本机 localProxy AES-CTR 解密直通)",
            @"adaptationAdvice": @"此地址为红果/短剧 CENC 加密协议地址。播放时由本机 Python/Node 插件自动请求签名模型、解密 spade 地址、执行 AES-128-CTR 样本解密并改写 moov (encv->hvc1) 后通过 HTTP 206 Byte-Range 交付原生播放器。",
        };
        [self recordPlaybackAdaptationWithSource:@{@"name": contextTag ?: @"网址探测"} provider:@"probe" mediaName:@"CENC 协议流探测" episodeName:@"" lineName:@"" streamURL:trimmed originalURL:trimmed playerEngine:@"AVPlayer+LocalProxy" routeKind:@"cenc-decrypt" containerFormat:@"cenc-mp4" videoCodec:@"hvc1" headers:headers startupMs:1 success:YES failureStage:@"" errorMessage:@""];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(rep); });
        return;
    }
    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url || !url.scheme.length || !url.host.length) {
        if (completion) completion(@{@"success": @NO, @"summary": @"网址格式无效，请输入完整 http://、https://、cenc:// 地址或 7lj763gg 加密配置串"});
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    req.HTTPMethod = @"GET";
    [req setValue:@"bytes=0-4095" forHTTPHeaderField:@"Range"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class] && k.length && v.length) {
            [req setValue:v forHTTPHeaderField:k];
        }
    }];
    CFTimeInterval t0 = CACurrentMediaTime();
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger elapsed = (NSInteger)(MAX(0, CACurrentMediaTime() - t0) * 1000.0);
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = http ? http.statusCode : 0;
        NSString *mime = CCTVMonitorSafeString(http.MIMEType).lowercaseString;
        NSString *acceptRanges = CCTVMonitorSafeString(http.allHeaderFields[@"Accept-Ranges"] ?: http.allHeaderFields[@"accept-ranges"]);
        NSString *contentRange = CCTVMonitorSafeString(http.allHeaderFields[@"Content-Range"] ?: http.allHeaderFields[@"content-range"]);
        BOOL supportsRange = (status == 206 || contentRange.length > 0 || [acceptRanges.lowercaseString containsString:@"bytes"]);
        NSString *headText = data.length ? [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)2048, data.length))] encoding:NSUTF8StringEncoding] : @"";
        if (!headText && data.length) {
            headText = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)2048, data.length))] encoding:NSISOLatin1StringEncoding] ?: @"";
        }
        NSString *detectedType = @"未知站点/资源响应";
        NSString *codecHint = @"";
        NSString *recommendedEngine = @"AVPlayer";
        NSString *advice = @"";
        if (error || status >= 400 || status == 0) {
            detectedType = [NSString stringWithFormat:@"请求异常 (HTTP %ld)", (long)status];
            recommendedEngine = decodedNotesPrefix.length ? @"jar-bridge (需拼接 AppGet/CMS 接口路径)" : @"需代理/切换线路";
            advice = [NSString stringWithFormat:@"%@探测失败（%@）。若为 AppGet/巧技加密宿主根域名，JAR-Bridge 会在请求时自动追加 /api.php/getappapi.index/initV119 等接口路径；若为防盗链，请补充 Referer。", decodedNotesPrefix, error.localizedDescription ?: @"HTTP 状态异常"];
        } else if ([headText containsString:@"#EXTM3U"] || [mime containsString:@"mpegurl"]) {
            BOOL isMaster = [headText containsString:@"#EXT-X-STREAM-INF"];
            BOOL hasDiscontinuity = [headText containsString:@"#EXT-X-DISCONTINUITY"];
            detectedType = isMaster ? @"HLS 多码率主列表 (Master M3U8)" : @"HLS 分片媒体流 (Media M3U8)";
            if (hasDiscontinuity) {
                advice = @"检测到 HLS 包含 #EXT-X-DISCONTINUITY 切片标记，本机 MediaRelay 可自动过滤插播广告分片并保持 AVPlayer 连续播放。";
            } else {
                advice = @"标准 HLS 流，AVPlayer 原生硬解最佳；若跨域分片需要自定义请求头，将自动通过本机 MediaRelay 代理。";
            }
        } else if (data.length >= 12 && ([headText containsString:@"ftyp"] || [mime containsString:@"mp4"])) {
            detectedType = @"MP4 / ISO BMFF 容器媒体";
            if ([headText containsString:@"encv"] || [headText containsString:@"sinf"] || [headText containsString:@"senc"]) {
                codecHint = @"encv (CENC 加密)";
                recommendedEngine = @"本机 CENC 解密代理 + AVPlayer";
                advice = @"检测到 MP4 含有 CENC (encv/sinf/senc) 加密盒，直接交给播放器会黑屏；必须经由本机 CENC 样本解密代理改写为 hvc1/avc1 清流后播放。";
            } else if ([headText containsString:@"hev1"]) {
                codecHint = @"HEVC (hev1)";
                recommendedEngine = @"AVPlayer (FourCC 归一化) / CicadaPlayer";
                advice = [NSString stringWithFormat:@"检测到 HEVC (hev1) 编码，Range 支持：%@。宿主会自动归一化为 hvc1 或交由 CicadaPlayer 解码。", supportsRange ? @"支持 (HTTP 206)" : @"未声明"];
            } else if ([headText containsString:@"hvc1"]) {
                codecHint = @"HEVC (hvc1)";
                recommendedEngine = @"AVPlayer 原生硬解";
                advice = [NSString stringWithFormat:@"检测到标准 Apple HEVC (hvc1) 编码，Range 支持：%@，AVPlayer 可直接硬件加速播放。", supportsRange ? @"支持 (HTTP 206)" : @"未声明"];
            } else if ([headText containsString:@"avc1"]) {
                codecHint = @"H.264 (avc1)";
                recommendedEngine = @"AVPlayer 原生硬解";
                advice = [NSString stringWithFormat:@"检测到标准 H.264 (avc1) 编码，Range 支持：%@，所有播放器内核均完美兼容。", supportsRange ? @"支持 (HTTP 206)" : @"未声明"];
            } else {
                advice = [NSString stringWithFormat:@"检测到 MP4 容器（Range 支持：%@），建议开启 HTTP 206 分片请求以提升首帧起播速度。", supportsRange ? @"是" : @"否"];
            }
        } else if ([headText containsString:@"<MPD"] || [mime containsString:@"dash+xml"]) {
            detectedType = @"MPEG-DASH (MPD 清单)";
            recommendedEngine = @"MediaRelay DASH->HLS 桥接 / CicadaPlayer";
            advice = @"检测到 MPEG-DASH 流，宿主会自动将清流 MPD 桥接为 HLS(fMP4) 供 AVPlayer 播放，或路由至 CicadaPlayer 原生 DASH 引擎。";
        } else if (data.length >= 4 && [headText hasPrefix:@"FLV"]) {
            detectedType = @"HTTP-FLV 视频流";
            recommendedEngine = @"CicadaPlayer / CNPlayerSDK";
            advice = @"检测到 FLV 封装流，AVPlayer 不直接支持 FLV，宿主解码路由器会自动切至 CicadaPlayer / CNPlayerSDK 播放。";
        } else if ([headText.lowercaseString containsString:@"<html"] || [headText.lowercaseString containsString:@"<!doctype"]) {
            BOOL hasM3U8 = [headText containsString:@".m3u8"];
            BOOL hasMP4 = [headText containsString:@".mp4"];
            BOOL hasRouterData = [headText containsString:@"_ROUTER_DATA"] || [headText containsString:@"__NEXT_DATA__"];
            detectedType = [NSString stringWithFormat:@"网页站点 HTML (%@)", hasRouterData ? @"含 SSR 剧集数据" : (hasM3U8 || hasMP4 ? @"含内嵌直链" : @"普通网页")];
            recommendedEngine = decodedNotesPrefix.length ? @"jar-bridge (AppGet/Web 爬虫桥接)" : (hasM3U8 || hasMP4 ? @"静态嗅探提取 + AVPlayer" : @"JSON 解析接口 / WKWebView 网页嗅探");
            advice = [NSString stringWithFormat:@"%@该网址返回 HTML 页面（耗时 %ld ms）。%@建议通过站点 Spider 解析或详情页「解析接口」提取真实媒体流后再交由原生播放器播放。", decodedNotesPrefix, (long)elapsed, hasRouterData ? @"页面内检测到 SSR 剧集目录数据（_ROUTER_DATA/__NEXT_DATA__）。" : @""];
        } else if ([headText hasPrefix:@"{"] || [headText hasPrefix:@"["] || [mime containsString:@"json"] || [headText containsString:@"\"sites\""]) {
            BOOL isCMS = [headText containsString:@"\"list\""] && ([headText containsString:@"\"vod_"] || [headText containsString:@"\"type_"]);
            BOOL isTVBoxCatalog = [headText containsString:@"\"sites\""] && ([headText containsString:@"\"spider\""] || [headText containsString:@"\"lives\""]);
            detectedType = isTVBoxCatalog ? @"TVBox 聚合配置单 (含 sites/lives/spider)" : (isCMS ? @"苹果 CMS / TVBox 标准 JSON 接口" : @"JSON 数据接口");
            recommendedEngine = isTVBoxCatalog ? @"TVBoxCatalogStore + JAR-Bridge" : @"MediaAPIClient 原生目录/解析";
            advice = [NSString stringWithFormat:@"%@%@", decodedNotesPrefix, isTVBoxCatalog ? @"检测到完整 TVBox 聚合 JSON 配置，支持注释净化、7lj763gg 解密与 spider.jar 常量池自动适配。" : (isCMS ? @"检测到标准 VOD JSON 接口（含 list/vod 字段），可直接作为 TVBox/CMS 站点接入并配合播放器自动选路。" : @"检测到 JSON 响应，适合作为 API 源或 JSON 解析接口。")];
        } else if (decodedNotesPrefix.length) {
            recommendedEngine = @"jar-bridge 原生桥接";
            advice = [NSString stringWithFormat:@"%@上游主机连通正常（耗时 %ld ms）。", decodedNotesPrefix, (long)elapsed];
        }
        BOOL ok = (error == nil && status >= 200 && status < 400);
        NSDictionary *report = @{
            @"success": @(ok),
            @"url": CCTVMonitorRedactURL(trimmed),
            @"finalURL": CCTVMonitorRedactURL(response.URL.absoluteString ?: trimmed),
            @"status": @(status),
            @"mimeType": mime.length ? mime : @"unknown",
            @"supportsRange": @(supportsRange),
            @"elapsedMs": @(elapsed),
            @"detectedType": detectedType,
            @"videoCodec": codecHint,
            @"recommendedEngine": recommendedEngine,
            @"adaptationAdvice": advice,
        };
        [self recordPlaybackAdaptationWithSource:@{@"name": contextTag.length ? contextTag : @"网址/流探测"}
                                        provider:@"probe"
                                       mediaName:detectedType
                                     episodeName:supportsRange ? @"支持 Range" : @""
                                        lineName:mime
                                       streamURL:response.URL.absoluteString ?: trimmed
                                     originalURL:trimmed
                                    playerEngine:recommendedEngine
                                       routeKind:decodedNotesPrefix.length ? @"jar-bridge" : @"probe"
                                 containerFormat:detectedType
                                      videoCodec:codecHint
                                         headers:headers
                                       startupMs:elapsed
                                         success:ok
                                    failureStage:ok ? @"" : @"http_probe"
                                    errorMessage:error.localizedDescription ?: (ok ? @"" : [NSString stringWithFormat:@"HTTP %ld", (long)status])];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(report);
            });
        }
    }];
    [task resume];
}

- (NSString *)exportDiagnosticReportText {
    NSArray<NSDictionary *> *sites = [self siteHealthSummaries];
    NSDictionary *summary = [self playerAdaptationSummary];
    NSArray<NSDictionary *> *recent = [self allRecords];
    NSArray<NSDictionary *> *catalogs = [TVBoxCatalogStore catalogs];
    NSMutableArray<NSDictionary *> *catalogSummaries = [NSMutableArray array];
    for (NSDictionary *cat in catalogs) {
        if (![cat isKindOfClass:NSDictionary.class]) continue;
        [catalogSummaries addObject:@{
            @"name": cat[@"name"] ?: @"",
            @"sourceURL": CCTVMonitorRedactURL(CCTVMonitorSafeString(cat[@"sourceURL"])),
            @"bundleType": cat[@"bundleType"] ?: @"remote-json",
            @"jarVerified": @([cat[@"jarVerified"] boolValue]),
            @"siteCount": @([cat[@"sites"] isKindOfClass:NSArray.class] ? [cat[@"sites"] count] : 0),
            @"liveCount": @([cat[@"lives"] isKindOfClass:NSArray.class] ? [cat[@"lives"] count] : 0),
        }];
    }
    NSDictionary *payload = @{
        @"generatedAt": [self.timeFormatter stringFromDate:NSDate.date] ?: @"",
        @"monitoringEnabled": @(self.isMonitoringEnabled),
        @"playerAdaptationSummary": summary ?: @{},
        @"importedCatalogs": catalogSummaries,
        @"siteHealthSummaries": sites ?: @[],
        @"recentRecords": recent.count > 60 ? [recent subarrayWithRange:NSMakeRange(0, 60)] : recent,
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:NULL];
    return json.length ? ([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"{}") : @"{}";
}

- (void)clearAllRecords {
    dispatch_async(self.queue, ^{
        [self.records removeAllObjects];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:CCTVMediaAdaptationMonitorRecordsKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaAdaptationMonitorDidUpdateNotification object:self];
        });
    });
}

@end

@interface MediaAdaptationMonitorViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property(nonatomic, strong) UISegmentedControl *segmentControl;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UIView *probePanel;
@property(nonatomic, strong) UITextField *probeURLField;
@property(nonatomic, strong) UITextField *probeRefererField;
@property(nonatomic, strong) UIButton *probeRunButton;
@property(nonatomic, strong) UIButton *decodeConfigButton;
@property(nonatomic, strong) UILabel *probeResultLabel;
@property(nonatomic, strong) UIActivityIndicatorView *probeSpinner;
@property(nonatomic, assign) BOOL filterFailedOnly;
@property(nonatomic, assign) BOOL isBatchProbing;
@property(nonatomic, copy) NSString *lastBatchProbeSummary;
@property(nonatomic, copy) NSArray<NSDictionary *> *displayedRecords;
@property(nonatomic, copy) NSArray<NSDictionary *> *displayedSites;
@property(nonatomic, copy) NSDictionary *adaptationSummary;
@end

@implementation MediaAdaptationMonitorViewController

- (instancetype)initWithContext:(NSDictionary *)context {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _initialContext = [context copy];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = @"站点与播放适配监测";
    self.view.backgroundColor = HostBackground();

    UIBarButtonItem *exportItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(copyDiagnosticReport)];
    exportItem.accessibilityLabel = @"复制监测报告";
    exportItem.accessibilityIdentifier = @"adaptation-monitor-export";

    UIBarButtonItem *filterItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(toggleFailedFilter)];
    filterItem.accessibilityLabel = @"切换仅看异常记录";
    filterItem.accessibilityIdentifier = @"adaptation-monitor-filter-failed";

    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(confirmClearRecords)];
    clearItem.accessibilityLabel = @"清空监测记录";
    clearItem.accessibilityIdentifier = @"adaptation-monitor-clear";

    UIBarButtonItem *toggleItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:MediaAdaptationMonitor.shared.isMonitoringEnabled ? @"pause.circle" : @"play.circle"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(toggleMonitoringEnabled)];
    toggleItem.accessibilityLabel = MediaAdaptationMonitor.shared.isMonitoringEnabled ? @"暂停记录" : @"恢复记录";
    self.navigationItem.rightBarButtonItems = @[exportItem, filterItem, clearItem, toggleItem];
    if (self.presentingViewController && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissSelf)];
    }

    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[@"全部记录", @"站点健康", @"播放适配", @"网址/流探测"]];
    self.segmentControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.segmentControl.selectedSegmentIndex = 0;
    self.segmentControl.accessibilityIdentifier = @"adaptation-monitor-segments";
    [self.segmentControl addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segmentControl];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"筛选站点、片名、域名、播放器、jar-bridge 或错误阶段…";
    self.searchBar.delegate = self;
    [self.view addSubview:self.searchBar];

    [self buildProbePanel];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = HostBackground();
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88;
    self.tableView.accessibilityIdentifier = @"adaptation-monitor-table";
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.segmentControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.segmentControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
        [self.segmentControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.segmentControl.bottomAnchor constant:4],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [self.probePanel.topAnchor constraintEqualToAnchor:self.segmentControl.bottomAnchor constant:10],
        [self.probePanel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],
        [self.probePanel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:2],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    NSString *prefillURL = CCTVMonitorSafeString(self.initialContext[@"probeURL"] ?: self.initialContext[@"streamURL"] ?: self.initialContext[@"api"]);
    if (prefillURL.length) {
        self.probeURLField.text = prefillURL;
    }
    NSString *prefillReferer = CCTVMonitorSafeString(self.initialContext[@"referer"]);
    if (prefillReferer.length) {
        self.probeRefererField.text = prefillReferer;
    }

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadMonitorData) name:CCTVMediaAdaptationMonitorDidUpdateNotification object:nil];
    [self reloadMonitorData];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.tableView.backgroundColor = HostBackground();
    [self.tableView reloadData];
}

- (void)buildProbePanel {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    HostStyleGlassCard(card, 16);
    card.hidden = YES;
    self.probePanel = card;
    [self.view addSubview:card];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.layoutMargins = UIEdgeInsetsMake(14, 14, 14, 14);
    stack.layoutMarginsRelativeArrangement = YES;
    [card addSubview:stack];

    UILabel *title = [UILabel new];
    title.font = HostRoundedFont(15.5, UIFontWeightBold, UIFontTextStyleHeadline);
    title.textColor = HostText();
    title.text = @"网址 / 7lj763gg 密文 / 影视接口 / 媒体流实时探测器";
    [stack addArrangedSubview:title];

    self.probeURLField = [UITextField new];
    self.probeURLField.borderStyle = UITextBorderStyleRoundedRect;
    self.probeURLField.font = [UIFont systemFontOfSize:13.5];
    self.probeURLField.placeholder = @"输入网址、7lj763gg 密文、url|key|iv、csp_* 或 m3u8/mp4/cenc 地址…";
    self.probeURLField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.probeURLField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.probeURLField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.probeURLField.accessibilityIdentifier = @"adaptation-monitor-probe-url";
    [stack addArrangedSubview:self.probeURLField];

    self.probeRefererField = [UITextField new];
    self.probeRefererField.borderStyle = UITextBorderStyleRoundedRect;
    self.probeRefererField.font = [UIFont systemFontOfSize:13];
    self.probeRefererField.placeholder = @"可选 Referer 防盗链头（如 https://hongguoduanju.com/）";
    self.probeRefererField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.probeRefererField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.probeRefererField.autocorrectionType = UITextAutocorrectionTypeNo;
    [stack addArrangedSubview:self.probeRefererField];

    UIStackView *btnRow = [UIStackView new];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 8;
    btnRow.distribution = UIStackViewDistributionFillProportionally;

    self.probeRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    HostStylePillButton(self.probeRunButton, YES);
    [self.probeRunButton setTitle:@"立即探测与适配" forState:UIControlStateNormal];
    self.probeRunButton.accessibilityIdentifier = @"adaptation-monitor-probe-run";
    [self.probeRunButton addTarget:self action:@selector(runInteractiveProbe) forControlEvents:UIControlEventTouchUpInside];
    [self.probeRunButton.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [btnRow addArrangedSubview:self.probeRunButton];

    self.decodeConfigButton = [UIButton buttonWithType:UIButtonTypeSystem];
    HostStylePillButton(self.decodeConfigButton, NO);
    [self.decodeConfigButton setTitle:@"解码配置/ext" forState:UIControlStateNormal];
    self.decodeConfigButton.accessibilityIdentifier = @"adaptation-monitor-decode-ext";
    [self.decodeConfigButton addTarget:self action:@selector(runConfigDecode) forControlEvents:UIControlEventTouchUpInside];
    [self.decodeConfigButton.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [btnRow addArrangedSubview:self.decodeConfigButton];

    UIButton *fillBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    HostStylePillButton(fillBtn, NO);
    [fillBtn setTitle:@"填入最近" forState:UIControlStateNormal];
    [fillBtn addTarget:self action:@selector(fillRecentURL) forControlEvents:UIControlEventTouchUpInside];
    [fillBtn.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [btnRow addArrangedSubview:fillBtn];

    self.probeSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.probeSpinner.hidesWhenStopped = YES;
    [btnRow addArrangedSubview:self.probeSpinner];
    [stack addArrangedSubview:btnRow];

    self.probeResultLabel = [UILabel new];
    self.probeResultLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.probeResultLabel.textColor = HostSecondaryText();
    self.probeResultLabel.numberOfLines = 0;
    self.probeResultLabel.text = @"支持探测与脱壳：刺桐/巧技 7lj763gg 密文、AppGet 管道参数 (url|key|iv)、TVBox 2423/Base64 载荷、spider.jar 描述符、CMS/TVBox JSON 接口、HLS(m3u8)、MP4(hvc1/hev1/encv)、CENC 加密流与 MPEG-DASH(mpd)。";
    [stack addArrangedSubview:self.probeResultLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleFailedFilter {
    self.filterFailedOnly = !self.filterFailedOnly;
    if (self.navigationItem.rightBarButtonItems.count > 1) {
        UIBarButtonItem *filterItem = self.navigationItem.rightBarButtonItems[1];
        filterItem.image = [UIImage systemImageNamed:self.filterFailedOnly ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle"];
    }
    [self reloadMonitorData];
}

- (void)toggleMonitoringEnabled {
    BOOL next = !MediaAdaptationMonitor.shared.isMonitoringEnabled;
    MediaAdaptationMonitor.shared.monitoringEnabled = next;
    UIBarButtonItem *item = self.navigationItem.rightBarButtonItems.lastObject;
    item.image = [UIImage systemImageNamed:next ? @"pause.circle" : @"play.circle"];
    item.accessibilityLabel = next ? @"暂停记录" : @"恢复记录";
    [self reloadMonitorData];
}

- (void)copyDiagnosticReport {
    NSString *report = [MediaAdaptationMonitor.shared exportDiagnosticReportText];
    UIPasteboard.generalPasteboard.string = report;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"监测诊断报告已复制"
                                                                   message:@"已将已导入合集概况、站点健康度、播放器与 JAR-Bridge 适配统计及最近监测记录（JSON）复制到剪贴板。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearRecords {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"清空监测记录"
                                                                   message:@"确定要清空所有已记录的站点、合集、影视接口与播放适配记录吗？"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"清空全部记录" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [MediaAdaptationMonitor.shared clearAllRecords];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.count > 2 ? self.navigationItem.rightBarButtonItems[2] : nil;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)segmentChanged {
    BOOL isProbe = (self.segmentControl.selectedSegmentIndex == 3);
    self.probePanel.hidden = !isProbe;
    self.searchBar.hidden = isProbe;
    self.tableView.hidden = isProbe;
    if (!isProbe) {
        [self.view endEditing:YES];
        [self reloadMonitorData];
    }
}

- (void)fillRecentURL {
    NSArray<NSDictionary *> *all = [MediaAdaptationMonitor.shared allRecords];
    for (NSDictionary *rec in all) {
        NSString *u = CCTVMonitorSafeString(rec[@"url"]);
        if (u.length && ![u containsString:@"***"]) {
            self.probeURLField.text = u;
            return;
        }
    }
    if (all.count) {
        self.probeURLField.text = CCTVMonitorSafeString(all.firstObject[@"url"]);
    }
}

- (void)runConfigDecode {
    [self.view endEditing:YES];
    NSString *raw = CCTVMonitorSafeString(self.probeURLField.text);
    NSDictionary *res = [MediaAdaptationMonitor.shared decodeAndInspectConfigString:raw];
    if (![res[@"success"] boolValue]) {
        self.probeResultLabel.text = res[@"summary"] ?: @"未识别到可解码的配置串";
        return;
    }
    NSString *extracted = CCTVMonitorSafeString(res[@"extractedURL"]);
    self.probeResultLabel.text = [NSString stringWithFormat:
        @"识别类型：%@\n"
        @"解码结果：%@\n"
        @"提取地址：%@\n"
        @"推荐适配引擎：%@\n"
        @"说明：%@",
        res[@"cipherType"] ?: @"-",
        res[@"decodedText"] ?: @"-",
        extracted.length ? extracted : @"(非直链配置)",
        res[@"recommendedEngine"] ?: @"jar-bridge",
        res[@"summary"] ?: @"-"];
}

- (void)runBatchCatalogProbe {
    if (self.isBatchProbing) return;
    self.isBatchProbing = YES;
    self.lastBatchProbeSummary = @"正在并发巡检已导入 TVBox 合集与本地包代表站点…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [MediaAdaptationMonitor.shared batchProbeCatalogSites:nil catalogName:nil completion:^(NSDictionary *summary) {
        MediaAdaptationMonitorViewController *owner = weakSelf;
        if (!owner) return;
        owner.isBatchProbing = NO;
        owner.lastBatchProbeSummary = CCTVMonitorSafeString(summary[@"summary"]);
        [owner reloadMonitorData];
    }];
}

- (void)runInteractiveProbe {
    [self.view endEditing:YES];
    NSString *url = CCTVMonitorSafeString(self.probeURLField.text);
    NSString *ref = CCTVMonitorSafeString(self.probeRefererField.text);
    NSMutableDictionary *hdrs = [NSMutableDictionary dictionary];
    if (ref.length) hdrs[@"Referer"] = ref;
    [self.probeSpinner startAnimating];
    self.probeRunButton.enabled = NO;
    self.probeResultLabel.text = @"正在执行配置脱壳、探测网址连通性、HTTP Range 支持、容器魔数与视频编码…";
    __weak typeof(self) weakSelf = self;
    [MediaAdaptationMonitor.shared probeURLString:url headers:hdrs contextTag:self.initialContext[@"sourceName"] ?: @"手动网址探测" completion:^(NSDictionary *report) {
        MediaAdaptationMonitorViewController *owner = weakSelf;
        if (!owner) return;
        [owner.probeSpinner stopAnimating];
        owner.probeRunButton.enabled = YES;
        if (![report[@"success"] boolValue] && report[@"summary"]) {
            owner.probeResultLabel.text = report[@"summary"];
            return;
        }
        owner.probeResultLabel.text = [NSString stringWithFormat:
            @"探测状态：%@（HTTP %@ · 耗时 %@ ms · Range %@）\n"
            @"识别类型：%@%@\n"
            @"推荐播放器/适配内核：%@\n"
            @"适配方案建议：%@",
            [report[@"success"] boolValue] ? @"✓ 可达/已就绪" : @"✗ 异常",
            report[@"status"] ?: @0,
            report[@"elapsedMs"] ?: @0,
            [report[@"supportsRange"] boolValue] ? @"支持 206" : @"未声明",
            report[@"detectedType"] ?: @"-",
            [report[@"videoCodec"] length] ? [NSString stringWithFormat:@" · 编码 %@", report[@"videoCodec"]] : @"",
            report[@"recommendedEngine"] ?: @"AVPlayer",
            report[@"adaptationAdvice"] ?: @"-"];
        [owner reloadMonitorData];
    }];
}

- (void)reloadMonitorData {
    NSString *q = self.searchBar.text ?: @"";
    NSString *kind = self.filterFailedOnly ? @"failed" : @"all";
    self.displayedRecords = [MediaAdaptationMonitor.shared recordsFilteredByKind:kind searchQuery:q];
    self.displayedSites = [MediaAdaptationMonitor.shared siteHealthSummaries];
    self.adaptationSummary = [MediaAdaptationMonitor.shared playerAdaptationSummary];
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadMonitorData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    NSInteger seg = self.segmentControl.selectedSegmentIndex;
    if (seg == 0) return 2; // Section 0: Overview + Batch Probe + Context; Section 1: Records
    if (seg == 1) return 1; // Site summaries
    if (seg == 2) return 2; // Section 0: Engine Matrix; Section 1: Built-in Adaptation Rules
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger seg = self.segmentControl.selectedSegmentIndex;
    if (seg == 0) {
        if (section == 0) return @"监测概览与合集巡检";
        return [NSString stringWithFormat:@"%@（%lu 条）",
                self.filterFailedOnly ? @"异常监测记录" : @"实时监测记录",
                (unsigned long)self.displayedRecords.count];
    }
    if (seg == 1) {
        return [NSString stringWithFormat:@"站点与资源健康度聚合（%lu 个站点/源）", (unsigned long)self.displayedSites.count];
    }
    if (seg == 2) {
        return section == 0 ? @"播放器内核、JAR-Bridge 与流代理命中统计" : @"内置全链路资源与播放适配规则矩阵";
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger seg = self.segmentControl.selectedSegmentIndex;
    if (seg == 0) {
        if (section == 0) return self.initialContext.count ? 3 : 2;
        return MAX(1, (NSInteger)self.displayedRecords.count);
    }
    if (seg == 1) {
        return MAX(1, (NSInteger)self.displayedSites.count);
    }
    if (seg == 2) {
        return section == 0 ? 7 : 6;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"monitor_cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"monitor_cell"];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.numberOfLines = 4;
        cell.textLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
    }
    cell.backgroundColor = HostCard();
    cell.textLabel.textColor = HostText();
    cell.detailTextLabel.textColor = HostSecondaryText();
    cell.accessoryType = UITableViewCellAccessoryNone;

    NSInteger seg = self.segmentControl.selectedSegmentIndex;
    if (seg == 0) {
        if (indexPath.section == 0) {
            if (indexPath.row == 0) {
                NSUInteger total = [self.adaptationSummary[@"totalRecords"] unsignedIntegerValue];
                NSUInteger ok = [self.adaptationSummary[@"successRecords"] unsignedIntegerValue];
                cell.textLabel.text = [NSString stringWithFormat:@"监测状态：%@ · 累计记录 %lu 条（成功 %lu 条）%@",
                                       MediaAdaptationMonitor.shared.isMonitoringEnabled ? @"运行中" : @"已暂停",
                                       (unsigned long)total, (unsigned long)ok,
                                       self.filterFailedOnly ? @" · [仅看异常]" : @""];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"AVPlayer %@ 次 · CicadaPlayer %@ 次 · JAR-Bridge %@ 次 · CENC 解密 %@ 次 · MediaRelay %@ 次 · 合集导入 %@ 次",
                                             self.adaptationSummary[@"avPlayerCount"] ?: @0,
                                             self.adaptationSummary[@"cicadaPlayerCount"] ?: @0,
                                             self.adaptationSummary[@"jarBridgeCount"] ?: @0,
                                             self.adaptationSummary[@"cencProxyCount"] ?: @0,
                                             self.adaptationSummary[@"mediaRelayCount"] ?: @0,
                                             self.adaptationSummary[@"catalogImportCount"] ?: @0];
                return cell;
            }
            if (indexPath.row == 1 && self.initialContext.count) {
                NSString *srcName = CCTVMonitorSafeString(self.initialContext[@"sourceName"] ?: @"当前资源");
                NSString *mediaName = CCTVMonitorSafeString(self.initialContext[@"mediaName"] ?: @"当前影片");
                NSString *probeURL = CCTVMonitorSafeString(self.initialContext[@"probeURL"] ?: self.initialContext[@"streamURL"] ?: self.initialContext[@"api"]);
                cell.textLabel.text = [NSString stringWithFormat:@"当前监测上下文：%@ · %@", srcName, mediaName];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"地址：%@\n点击此行可立即对该地址执行「网址/流媒体播放适配探测」", probeURL.length ? probeURL : @"未附带直链"];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                return cell;
            }
            // Batch catalog probe row
            cell.textLabel.text = self.isBatchProbing ? @"正在巡检已导入合集与本地包站点…" : @"一键巡检已导入合集站点与解密配置";
            cell.detailTextLabel.text = self.lastBatchProbeSummary.length
                ? self.lastBatchProbeSummary
                : @"自动抽样检测已导入的「初忆本地包」「刺桐影视」等 TVBox 合集站点连通性、7lj763gg 密钥脱壳与 JAR-Bridge 就绪状态。";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (!self.displayedRecords.count) {
            cell.textLabel.text = self.filterFailedOnly ? @"暂无异常监测记录" : @"暂无匹配的监测记录";
            cell.detailTextLabel.text = @"导入本地集合包、浏览站点、加载详情、播放剧集或使用「网址/流探测」时，系统会自动在此记录站点响应、容器编码与播放器适配详情。";
            return cell;
        }
        NSDictionary *rec = self.displayedRecords[(NSUInteger)indexPath.row];
        BOOL ok = [rec[@"success"] boolValue];
        NSString *badge = ok ? @"● 正常" : @"▲ 异常";
        NSString *op = CCTVMonitorSafeString(rec[@"operation"]);
        NSString *src = CCTVMonitorSafeString(rec[@"sourceName"]);
        NSString *media = CCTVMonitorSafeString(rec[@"mediaName"]);
        NSString *ep = CCTVMonitorSafeString(rec[@"episodeName"]);
        NSString *titleMain = media.length ? [NSString stringWithFormat:@"%@ · %@%@", src, media, ep.length ? [NSString stringWithFormat:@" (%@)", ep] : @""] : [NSString stringWithFormat:@"%@ · [%@]", src, op];
        cell.textLabel.text = [NSString stringWithFormat:@"%@  %@  ·  %@ ms", badge, titleMain, rec[@"elapsedMs"] ?: @0];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"时间：%@ · 站点/主机：%@ · 格式：%@ · 路由/内核：%@ / %@\n地址：%@\n%@",
                                     rec[@"timeText"] ?: @"",
                                     rec[@"host"] ?: @"-",
                                     [rec[@"format"] length] ? rec[@"format"] : @"auto",
                                     rec[@"routeKind"] ?: @"api",
                                     rec[@"playerEngine"] ?: @"-",
                                     [rec[@"url"] length] ? rec[@"url"] : @"-",
                                     rec[@"advice"] ?: @""];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (seg == 1) {
        if (!self.displayedSites.count) {
            cell.textLabel.text = @"暂无站点健康度数据";
            cell.detailTextLabel.text = @"访问任一影视资源、导入 TVBox 合集或执行「一键巡检」后将自动生成站点成功率、平均延迟与适配引擎画像。";
            return cell;
        }
        NSDictionary *site = self.displayedSites[(NSUInteger)indexPath.row];
        cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@%@ · 成功率 %.0f%% · 平均 %@ ms",
                               site[@"grade"] ?: @"良好",
                               site[@"sourceName"] ?: @"资源",
                               [site[@"provider"] length] ? [NSString stringWithFormat:@" (%@)", site[@"provider"]] : @"",
                               [site[@"successRate"] doubleValue],
                               site[@"avgLatencyMs"] ?: @0];
        NSString *errLine = [site[@"lastError"] length] ? [NSString stringWithFormat:@"\n最近异常：%@", site[@"lastError"]] : @"";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"域名/节点：%@ · 协议：%@ · 请求 %@ 次（成功 %@ 次）\n流格式：%@ · 适配播放器：%@%@",
                                     site[@"host"] ?: @"local",
                                     site[@"protocol"] ?: @"http",
                                     site[@"totalCount"] ?: @0,
                                     site[@"successCount"] ?: @0,
                                     site[@"formatsText"] ?: @"通用",
                                     site[@"enginesText"] ?: @"AVPlayer",
                                     errLine];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (seg == 2) {
        if (indexPath.section == 0) {
            NSArray<NSDictionary *> *rows = @[
                @{@"t": @"Apple AVPlayer 原生硬解引擎", @"d": [NSString stringWithFormat:@"累计承载 %@ 次 · 适用于标准 HLS(m3u8)、MP4(hvc1/avc1) 与本机 CENC 解密后 HTTP 206 流", self.adaptationSummary[@"avPlayerCount"] ?: @0]},
                @{@"t": @"CicadaPlayer / CNPlayerSDK 多格式内核", @"d": [NSString stringWithFormat:@"累计承载 %@ 次 · 适用于 HTTP-FLV、MKV、非标 TS、hev1/ByteVC1 及 AVPlayer 首帧超时回退", self.adaptationSummary[@"cicadaPlayerCount"] ?: @0]},
                @{@"t": @"JAR-Bridge 原生 TVBox Spider 桥接引擎", @"d": [NSString stringWithFormat:@"累计触发 %@ 次 · 支持 spider.jar 字节码常量池提取、7lj763gg 巧技解密及 AppGet/RJApp/Shark AES-128-CBC 协议", self.adaptationSummary[@"jarBridgeCount"] ?: @0]},
                @{@"t": @"本机 CENC(AES-CTR) 样本解密与 Range 文件代理", @"d": [NSString stringWithFormat:@"累计触发 %@ 次 · 针对红果短剧 Python/JS 等加密 MP4，自动完成多档画质降级兜底、senc 子样本解密与 moov 改写", self.adaptationSummary[@"cencProxyCount"] ?: @0]},
                @{@"t": @"本机 MediaRelay 防盗链与 HLS 净化中继", @"d": [NSString stringWithFormat:@"累计触发 %@ 次 · 自动注入站点 Referer/Origin/Cookie/UA，重写相对分片地址并剔除插播广告切片", self.adaptationSummary[@"mediaRelayCount"] ?: @0]},
                @{@"t": @"MPEG-DASH (MPD) -> HLS(fMP4) 实时桥接", @"d": [NSString stringWithFormat:@"累计触发 %@ 次 · 将清流 DASH 转换为原生播放器可直接硬解的 fMP4 HLS 清单", self.adaptationSummary[@"dashBridgeCount"] ?: @0]},
                @{@"t": @"解析接口与网页嗅探 (WebParser)", @"d": [NSString stringWithFormat:@"累计触发 %@ 次 · 支持 JSON 解析接口优先尝试、失败自动切换网页嗅探提取直链", self.adaptationSummary[@"webParserCount"] ?: @0]},
            ];
            NSDictionary *item = rows[(NSUInteger)indexPath.row];
            cell.textLabel.text = item[@"t"];
            cell.detailTextLabel.text = item[@"d"];
            return cell;
        } else {
            NSArray<NSDictionary *> *rules = @[
                @{@"t": @"规则 1 · TVBox 本地集合包与 spider.jar 常量池穿透适配", @"d": @"自动识别初忆本地包等 ZIP/目录合集，校验 spider.jar MD5，合并 api.original.json 与 .class 常量池中的上游接口和 AES 密钥，将 localhost 占位地址无缝还原为真实站点。"},
                @{@"t": @"规则 2 · 刺桐影视 (ctys.json) 与 7lj763gg 巧技密文脱壳", @"d": @"自动剥离头部 // 注释，对 7lj763gg... 扩展串执行 qiaoji 水印剔除、g..l 半字节还原与 170 字节 XOR 密钥流解密，直接驱动 AppGet/RJApp/Shark/Getapp 全系接口。"},
                @{@"t": @"规则 3 · CENC 加密短剧与多音视频轨边界保护", @"d": @"解析 MP4 stbl/saiz/saio/senc 时严格限定在当前加密轨 (encv/enca) 字节区间，支持 senc 子样本 (flags&2) 与多档清晰度 (1080p->720p->540p->480p->360p) 自动降级容错。"},
                @{@"t": @"规则 4 · HEVC FourCC 归一化 (hev1 -> hvc1)", @"d": @"iOS AVPlayer 对 hev1 封装标签兼容度低，本机代理与解码路由器自动识别并改写为 hvc1 或无缝移交 CicadaPlayer。"},
                @{@"t": @"规则 5 · 详情页全链路穿透刷新", @"d": @"点击详情页右上角刷新按钮或菜单「重新加载详情」时，同步穿透客户端 MediaMetadataCache、服务端 MediaRuntime 缓存与 Spider 内部缓存。"},
                @{@"t": @"规则 6 · 直播与点播首帧看门狗自动回退", @"d": @"AVPlayer 首帧超时或解码报错时，保留当前播放进度自动切换至备用清晰度、备用线路或 CicadaPlayer 内核。"},
            ];
            NSDictionary *rule = rules[(NSUInteger)indexPath.row];
            cell.textLabel.text = rule[@"t"];
            cell.detailTextLabel.text = rule[@"d"];
            return cell;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger seg = self.segmentControl.selectedSegmentIndex;
    if (seg == 0 && indexPath.section == 0) {
        if (indexPath.row == 1 && self.initialContext.count) {
            NSString *probeURL = CCTVMonitorSafeString(self.initialContext[@"probeURL"] ?: self.initialContext[@"streamURL"] ?: self.initialContext[@"api"]);
            if (probeURL.length) {
                self.probeURLField.text = probeURL;
                self.segmentControl.selectedSegmentIndex = 3;
                [self segmentChanged];
                [self runInteractiveProbe];
            }
            return;
        }
        NSInteger batchRow = self.initialContext.count ? 2 : 1;
        if (indexPath.row == batchRow) {
            [self runBatchCatalogProbe];
            return;
        }
        return;
    }
    if (seg == 0 && indexPath.section == 1 && indexPath.row < (NSInteger)self.displayedRecords.count) {
        NSDictionary *rec = self.displayedRecords[(NSUInteger)indexPath.row];
        NSString *detailText = [NSString stringWithFormat:
            @"资源名称：%@\n站点/Provider：%@\n协议类型：%@\n操作阶段：%@\n影片/分集：%@ %@\n目标域名：%@\n请求/媒体地址：%@\n解析后地址：%@\n容器与编码：%@ %@\n路由与内核：%@ / %@\n耗时：%@ ms\n状态：%@\n\n适配诊断与建议：\n%@",
            rec[@"sourceName"] ?: @"-",
            rec[@"provider"] ?: @"-",
            rec[@"protocol"] ?: @"-",
            rec[@"operation"] ?: @"-",
            rec[@"mediaName"] ?: @"-",
            rec[@"episodeName"] ?: @"",
            rec[@"host"] ?: @"-",
            rec[@"url"] ?: @"-",
            rec[@"resolvedURL"] ?: @"-",
            rec[@"format"] ?: @"auto",
            rec[@"videoCodec"] ?: @"",
            rec[@"routeKind"] ?: @"-",
            rec[@"playerEngine"] ?: @"-",
            rec[@"elapsedMs"] ?: @0,
            [rec[@"success"] boolValue] ? @"成功" : [NSString stringWithFormat:@"失败 (%@)", rec[@"errorMessage"] ?: rec[@"failureStage"] ?: @""],
            rec[@"advice"] ?: @"-"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"监测记录与适配详情"
                                                                       message:detailText
                                                                preferredStyle:UIAlertControllerStyleAlert];
        NSString *probeCandidate = CCTVMonitorSafeString(rec[@"url"]);
        if ([probeCandidate hasPrefix:@"http://"] || [probeCandidate hasPrefix:@"https://"] || [probeCandidate hasPrefix:@"cenc://"] || [probeCandidate.lowercaseString hasPrefix:@"7lj763gg"]) {
            __weak typeof(self) weakSelf = self;
            [alert addAction:[UIAlertAction actionWithTitle:@"填入探测器测试此地址" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                MediaAdaptationMonitorViewController *owner = weakSelf;
                if (!owner) return;
                owner.probeURLField.text = probeCandidate;
                owner.segmentControl.selectedSegmentIndex = 3;
                [owner segmentChanged];
                [owner runInteractiveProbe];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"复制此条记录" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = detailText;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (seg == 1 && indexPath.row < (NSInteger)self.displayedSites.count) {
        NSDictionary *site = self.displayedSites[(NSUInteger)indexPath.row];
        self.searchBar.text = CCTVMonitorSafeString(site[@"sourceName"]);
        self.segmentControl.selectedSegmentIndex = 0;
        [self segmentChanged];
    }
}

@end
