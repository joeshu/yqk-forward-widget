#import "HLSRouteProbe.h"

static NSOperationQueue *HLSRouteProbeQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"cctvhost.hls.route.probe";
        queue.maxConcurrentOperationCount = 2;
        queue.underlyingQueue = dispatch_queue_create("cctvhost.hls.route.probe", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableDictionary<NSString *, NSDictionary *> *HLSRouteProbeCacheStore(void) {
    static NSMutableDictionary<NSString *, NSDictionary *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    return cache;
}

@interface HLSRouteProbe () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,copy) void (^completion)(BOOL);
@property(nonatomic,copy) NSString *initialURLKey;
@property(nonatomic) NSUInteger depth;
@property(atomic) BOOL cancelled;
@end

@implementation HLSRouteProbe

+ (NSString *)sniffContainerMagic:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || data.length < 4) return nil;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    if (bytes[0] == 'F' && bytes[1] == 'L' && bytes[2] == 'V' && bytes[3] == 0x01) return @"flv";
    if (bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) return @"mkv";
    if (len >= 8 && (memcmp(bytes + 4, "ftyp", 4) == 0 || memcmp(bytes + 4, "styp", 4) == 0 ||
                     memcmp(bytes + 4, "moof", 4) == 0 || memcmp(bytes + 4, "moov", 4) == 0)) return @"mp4";
    if (bytes[0] == 0x47 && (len < 189 || bytes[188] == 0x47)) return @"mpegts";
    NSUInteger offset = 0;
    if (len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) offset = 3;
    while (offset < len && (bytes[offset] == ' ' || bytes[offset] == '	' || bytes[offset] == '
' || bytes[offset] == '
')) offset++;
    if (len - offset >= 7 && memcmp(bytes + offset, "#EXTM3U", 7) == 0) return @"hls";
    if (len - offset >= 4 && (memcmp(bytes + offset, "<MPD", 4) == 0 || memcmp(bytes + offset, "<?xm", 4) == 0)) return @"dash";
    return nil;
}

+ (void)clearCache {
    @synchronized(HLSRouteProbeCacheStore()) {
        [HLSRouteProbeCacheStore() removeAllObjects];
    }
}

- (void)startURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    [self cancel];
    self.cancelled = NO;
    self.depth = 0;
    self.completion = completion;
    self.initialURLKey = url.absoluteString ?: @"";
    if (self.initialURLKey.length && [self validURL:url]) {
        BOOL cachedHit = NO;
        @synchronized(HLSRouteProbeCacheStore()) {
            NSMutableDictionary *store = HLSRouteProbeCacheStore();
            NSDictionary *entry = store[self.initialURLKey];
            if (entry) {
                NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [entry[@"at"] doubleValue];
                if (age >= 0 && age < 60.0 && [entry[@"plain"] boolValue]) {
                    cachedHit = YES;
                } else {
                    [store removeObjectForKey:self.initialURLKey];
                }
            }
        }
        if (cachedHit) {
            [self finish:YES];
            return;
        }
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.timeoutIntervalForRequest = 2.0;
    config.timeoutIntervalForResource = 3.0;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:HLSRouteProbeQueue()];
    [self fetch:url];
}

- (BOOL)validURL:(NSURL *)url {
    return url.host.length && [@[@"http", @"https"] containsObject:url.scheme.lowercaseString] && !url.user.length && !url.password.length;
}

- (void)fetch:(NSURL *)url {
    if (self.cancelled) return;
    if (![self validURL:url]) { [self finish:NO]; return; }
    self.body = [NSMutableData data];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"qqlive" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://live.cctv.cn/" forHTTPHeaderField:@"Referer"];
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)finish:(BOOL)plain {
    if (self.cancelled) return;
    if (plain && self.initialURLKey.length) {
        @synchronized(HLSRouteProbeCacheStore()) {
            NSMutableDictionary *store = HLSRouteProbeCacheStore();
            if (store.count >= 64) [store removeAllObjects];
            store[self.initialURLKey] = @{@"plain": @(plain), @"at": @(NSDate.date.timeIntervalSince1970)};
        }
    }
    void (^done)(BOOL) = self.completion;
    self.completion = nil;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    if (!done) return;
    if (NSThread.isMainThread) {
        if (!self.cancelled) done(plain);
    } else {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            HLSRouteProbe *owner = weakSelf;
            if ((!owner || !owner.cancelled) && done) done(plain);
        });
    }
}

- (void)cancel {
    self.cancelled = YES;
    self.completion = nil;
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.body = nil;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BOOL valid = task == self.task && !self.cancelled && [(NSHTTPURLResponse *)response statusCode] == 200 && response.expectedContentLength <= 256 * 1024;
    completionHandler(valid ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    if (!valid && task == self.task) [self finish:NO];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (task != self.task || self.cancelled) return;
    if (data.length > 256 * 1024 - self.body.length) { [self finish:NO]; return; }
    [self.body appendData:data];
    // Fast-abort non-HLS binary streams or HTML pages on the first >= 16 bytes
    // instead of downloading up to 256 KiB of live video before rejecting.
    if (self.body.length >= 16) {
        NSString *magic = [HLSRouteProbe sniffContainerMagic:[self.body subdataWithRange:NSMakeRange(0, MIN(self.body.length, (NSUInteger)64))]];
        if (![magic isEqualToString:@"hls"]) {
            [self finish:NO];
            return;
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(task == self.task && [self validURL:request.URL] ? request : nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task != self.task || self.cancelled) return;
    if (error) { [self finish:NO]; return; }
    NSString *text = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    if ([text hasPrefix:@"\uFEFF"]) text = [text substringFromIndex:1];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![text hasPrefix:@"#EXTM3U"]) { [self finish:NO]; return; }
    NSString *child = nil;
    BOOL master = NO, media = NO;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([line hasPrefix:@"#EXT-X-KEY:"] && ![line containsString:@"METHOD=NONE"]) { [self finish:NO]; return; }
        if ([line hasPrefix:@"#EXT-X-SESSION-KEY:"]) { [self finish:NO]; return; }
        if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) master = YES;
        if ([line hasPrefix:@"#EXTINF:"] || [line hasPrefix:@"#EXT-X-PART:"]) media = YES;
        if (!child && line.length && ![line hasPrefix:@"#"]) child = line;
    }
    if (master) {
        if (!child.length || self.depth++ >= 2) { [self finish:NO]; return; }
        NSURL *url = [NSURL URLWithString:child relativeToURL:task.response.URL].absoluteURL;
        [self fetch:url];
        return;
    }
    [self finish:media && child.length > 0];
}
@end
