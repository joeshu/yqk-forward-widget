#import "HostImageLoader.h"
#import "HostImageDecodePolicy.h"
#import "HostImageFailurePolicy.h"
#import "RuntimeDiagnostics.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static NSUInteger const ImageBodyLimit = 2 * 1024 * 1024;
static NSUInteger const PosterBodyLimit = 4 * 1024 * 1024;
static NSUInteger const ImageConcurrentLimit = 8;
static NSUInteger const ImageQueueLimit = 160;
// T18/PERF-01：磁盘 LRU——128 MiB 上限、30 天过期，超限清至 80%，后台分批清理。
static NSUInteger const ImageDiskCacheLimitBytes = 128 * 1024 * 1024;
static NSTimeInterval const ImageDiskCacheTTLSeconds = 30 * 24 * 3600;
static NSUInteger const ImageDiskCacheTrimTargetBytes = (NSUInteger)(128 * 1024 * 1024 * 0.8);
static NSUInteger const ImageDiskTrimBatchLimit = 50;
// T18/PERF-02：解码并发 1–2，与协调/网络/磁盘队列分离。
static NSInteger const ImageDecodeConcurrentLimit = 2;
// 前向声明（定义在 decodeImageData 之后，loadURL 与 completeDecodedRequest 先用）。
static NSUInteger HostImageBitmapCost(UIImage *image);

@interface HostImageRequest : NSObject
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSHashTable<UIImageView *> *views;
@property(nonatomic, strong) NSMutableArray *observers;
@property(nonatomic, copy) NSString *url;
@property(nonatomic, copy) NSString *cacheKey;
@property(nonatomic) NSUInteger maximumPixelSize;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic) NSInteger httpStatus;
@property(nonatomic) BOOL responseEncrypted;
@property(nonatomic) BOOL prefetch;
@property(nonatomic) double pixelWidth;
@property(nonatomic) double pixelHeight;
@property(nonatomic) long long expectedContentLength;
@property(nonatomic, copy) NSString *responseContentType;
@property(nonatomic, copy) NSString *failureStage;
// T18/PERF-04：统一终结——观察者至多完成一次（finish/取消/退避移除任一路径先到先得）。
@property(nonatomic) BOOL completionDelivered;
// T18/PERF-05：落盘时核对的磁盘 epoch——清盘后旧 epoch 的解码结果不得重新落盘。
@property(nonatomic) NSUInteger diskEpoch;
@end
@implementation HostImageRequest
@end

@interface HostImageObserver : NSObject
@property(nonatomic, weak) UIImageView *view;
@property(nonatomic, copy) HostImageLoadCompletion completion;
@end
@implementation HostImageObserver
@end

@interface HostImageLoader () <NSURLSessionDataDelegate, NSCacheDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
// T18/PERF-02：解码与磁盘写各走自己的队列，不再与协调/网络共用串行 _queue。
@property(nonatomic, strong) NSOperationQueue *decodeQueue;
@property(nonatomic, strong) dispatch_queue_t diskQueue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *cache;
@property(nonatomic, strong) NSCache<NSString *, NSDate *> *failures;
@property(nonatomic,strong) NSCache<NSString *,NSMutableData *> *domainFailures;
@property(nonatomic, strong) NSMutableDictionary<NSString *, HostImageRequest *> *requests;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HostImageRequest *> *tasks;
@property(nonatomic, strong) NSMutableArray<HostImageRequest *> *pending;
@property(nonatomic, strong) NSMapTable<UIImageView *, NSString *> *viewTargets;
@property(nonatomic, copy) NSString *diskCacheDirectory;
@property(atomic) NSUInteger generation;
// T18/PERF-05：磁盘 epoch——clearDiskCache 自增，旧 epoch 的写盘请求直接丢弃。
@property(atomic) NSUInteger diskEpoch;
// T18/PERF-03：分别计费的统计。内存/在途/命中计数只在 _queue 上读写，
// 快照经 _queue 同步取；磁盘三栏由 trimDiskCacheOnDiskQueue 在磁盘队列上写、
// 在 statisticsSnapshot（_queue）上读，故声明 atomic（与 diskEpoch 同款）。
@property(nonatomic) NSUInteger memoryCacheBytes;
@property(nonatomic) NSUInteger inFlightCompressedBytes;
@property(atomic) NSUInteger diskCacheBytes;
@property(nonatomic) NSUInteger cacheHitCount;
@property(nonatomic) NSUInteger cacheMissCount;
@property(nonatomic) NSUInteger diskHitCount;
@property(atomic) NSUInteger diskEvictionCount;
@property(atomic) NSUInteger diskTrimmedBytes;
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView maximumPixelSize:(NSUInteger)maximumPixelSize completion:(nullable HostImageLoadCompletion)completion;
- (void)startPending;
- (void)enqueueImageRequestForURL:(NSString *)url cacheKey:(NSString *)cacheKey maximumPixelSize:(NSUInteger)maximumPixelSize view:(UIImageView *)view completion:(nullable HostImageLoadCompletion)completion generation:(NSUInteger)generation;
- (void)decodeImageData:(NSData *)data maximumPixelSize:(NSUInteger)maximumPixelSize completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable failureStage, double pixelWidth, double pixelHeight))completion;
- (void)completeDecodedRequest:(HostImageRequest *)record error:(nullable NSError *)error image:(nullable UIImage *)image failureStage:(nullable NSString *)failureStage;
- (void)finishRequest:(HostImageRequest *)record image:(nullable UIImage *)image retryAfter:(NSTimeInterval)retryAfter;
- (void)scheduleDiskWriteForImage:(UIImage *)image cacheKey:(NSString *)cacheKey url:(NSString *)url maximumPixelSize:(NSUInteger)maximumPixelSize diskEpoch:(NSUInteger)diskEpoch;
- (void)trimDiskCacheOnDiskQueue;
@end

@implementation HostImageLoader
+ (instancetype)shared {
    static HostImageLoader *loader;static dispatch_once_t once;
    dispatch_once(&once, ^{loader=[[self alloc] initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];});
    return loader;
}
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if((self=[super init])) {
        _queue=dispatch_queue_create("cctvhost.images", DISPATCH_QUEUE_SERIAL);
        // T18/PERF-02：解码并发 1–2（NSOperationQueue 自带线程池，不占 _queue）；
        // 磁盘读写走独立串行队列，与协调/网络/解码互不阻塞。
        _decodeQueue=[NSOperationQueue new];_decodeQueue.name=@"cctvhost.images.decode";_decodeQueue.maxConcurrentOperationCount=ImageDecodeConcurrentLimit;
        _diskQueue=dispatch_queue_create("cctvhost.images.disk", DISPATCH_QUEUE_SERIAL);
        _cache=[NSCache new];_cache.countLimit=360;_cache.totalCostLimit=32*1024*1024;_cache.delegate=self;
        _failures=[NSCache new];_failures.countLimit=200;
        _domainFailures=[NSCache new];_domainFailures.countLimit=64;
        _requests=[NSMutableDictionary dictionary];_tasks=[NSMutableDictionary dictionary];_pending=[NSMutableArray array];
        _viewTargets=[NSMapTable weakToStrongObjectsMapTable];
        NSURL *cachesDir=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *thumbDir=[cachesDir URLByAppendingPathComponent:@"CCTVHostImageThumbnails" isDirectory:YES];
        if(thumbDir){[NSFileManager.defaultManager createDirectoryAtURL:thumbDir withIntermediateDirectories:YES attributes:nil error:NULL];_diskCacheDirectory=thumbDir.path;}
        // T18/PERF-01：启动时后台清一次上次运行遗留的过期/超限磁盘文件。
        dispatch_async(_diskQueue, ^{[self trimDiskCacheOnDiskQueue];});
        NSURLSessionConfiguration *config=configuration.copy;config.URLCache=nil;config.HTTPCookieStorage=nil;
        config.timeoutIntervalForRequest=6;config.timeoutIntervalForResource=10;config.HTTPMaximumConnectionsPerHost=8;config.HTTPShouldUsePipelining=YES;config.waitsForConnectivity=NO;
        NSOperationQueue *delegate=[NSOperationQueue new];delegate.maxConcurrentOperationCount=1;delegate.underlyingQueue=_queue;
        _session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegate];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clearCache) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}
- (NSString *)diskThumbnailPathForCacheKey:(NSString *)cacheKey url:(NSString *)url maximumPixelSize:(NSUInteger)maximumPixelSize {
    if(!self.diskCacheDirectory.length||maximumPixelSize<512||!cacheKey.length)return nil;
    NSURL *parsed=[NSURL URLWithString:url?:@""];
    NSString *host=parsed.host.lowercaseString?:@"";
    if(!host.length||[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:host]||[host hasSuffix:@".test"]||[host hasSuffix:@".example"])return nil;
    NSData *keyData=[cacheKey dataUsingEncoding:NSUTF8StringEncoding];
    if(!keyData.length)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(keyData.bytes,(CC_LONG)keyData.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return [self.diskCacheDirectory stringByAppendingPathComponent:[hex stringByAppendingString:@".jpg"]];
}
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView {
    [self loadURL:url intoImageView:imageView maximumPixelSize:192 completion:nil];
}
- (void)loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView {
    [self loadPosterURL:url intoImageView:imageView completion:nil];
}
- (void)loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView completion:(HostImageLoadCompletion)completion {
    NSAssert(NSThread.isMainThread, @"Image views must be configured on the main thread");
    NSString *normalizedURL=url?:@"";
    BOOL sameImage=[imageView.accessibilityIdentifier isEqualToString:normalizedURL];
    if(!sameImage){
        imageView.image=[UIImage systemImageNamed:@"film"];
        imageView.contentMode=UIViewContentModeCenter;
        imageView.tintColor=UIColor.secondaryLabelColor;
    }
    // Mark the fallback as belonging to this URL so the shared loader does not
    // clear it while the request is pending or after a transient failure.
    imageView.accessibilityIdentifier=normalizedURL;
    [self loadURL:url intoImageView:imageView maximumPixelSize:1024 completion:completion];
}
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView maximumPixelSize:(NSUInteger)maximumPixelSize completion:(HostImageLoadCompletion)completion {
    NSAssert(NSThread.isMainThread, @"Image views must be configured on the main thread");
    // Keep the current logo while a same-URL request is joined or retried.
    // Reused views still clear immediately when assigned to a different URL.
    BOOL sameImage=[imageView.accessibilityIdentifier isEqualToString:url ?: @""];
    if(!sameImage)imageView.image=nil;
    imageView.accessibilityIdentifier=url;
    if(!url.length){if(completion)completion(NO,0);return;}
    NSURL *target=[NSURL URLWithString:url];
    if(!target.host.length || ![@[@"http",@"https"] containsObject:target.scheme.lowercaseString]){if(completion)completion(NO,0);return;}
    maximumPixelSize=MIN(MAX(maximumPixelSize,64),2048);NSString *cacheKey=[NSString stringWithFormat:@"%lu|%@",(unsigned long)maximumPixelSize,url];
    UIImage *cached=[self.cache objectForKey:cacheKey];if(cached){imageView.image=cached;if(maximumPixelSize>512){imageView.contentMode=UIViewContentModeScaleAspectFill;imageView.tintColor=nil;}if(completion)completion(YES,0);return;}
    NSUInteger generation=self.generation;__weak UIImageView *view=imageView;
    dispatch_async(self.queue, ^{@autoreleasepool {
        if(generation!=self.generation || !view)return;
        NSString *previousKey=[self.viewTargets objectForKey:view];
        if(previousKey.length && ![previousKey isEqualToString:cacheKey]){
            HostImageRequest *oldReq=self.requests[previousKey];
            if(oldReq){
                [oldReq.views removeObject:view];
                if(!oldReq.task && !oldReq.views.allObjects.count && !oldReq.prefetch){
                    [self.pending removeObject:oldReq];
                    [self.requests removeObjectForKey:previousKey];
                }
            }
        }
        [self.viewTargets setObject:cacheKey forKey:view];
        UIImage *memCached=[self.cache objectForKey:cacheKey];
        if(memCached){self.cacheHitCount++;}
        else{
            self.cacheMissCount++;
            NSString *diskPath=[self diskThumbnailPathForCacheKey:cacheKey url:url maximumPixelSize:maximumPixelSize];
            NSData *diskData=(diskPath.length && [NSFileManager.defaultManager fileExistsAtPath:diskPath])?[NSData dataWithContentsOfFile:diskPath options:NSDataReadingMappedIfSafe error:NULL]:nil;
            if(diskData.length){
                // T18/PERF-02：磁盘命中也走解码队列，不占协调队列；回 _queue 再交付或转网络。
                __weak typeof(self) weakSelf=self;
                [self decodeImageData:diskData maximumPixelSize:maximumPixelSize completion:^(UIImage *decoded, NSString *failureStage, double pixelWidth, double pixelHeight){
                    __unused NSString *unusedStage=failureStage;__unused double unusedW=pixelWidth;__unused double unusedH=pixelHeight;
                    HostImageLoader *owner=weakSelf;if(!owner)return;
                    dispatch_async(owner.queue, ^{
                        if(generation!=owner.generation || !view)return;
                        if(decoded){
                            owner.diskHitCount++;
                            NSUInteger cost=HostImageBitmapCost(decoded);
                            [owner.cache setObject:decoded forKey:cacheKey cost:cost];owner.memoryCacheBytes+=cost;
                            dispatch_async(dispatch_get_main_queue(),^{
                                UIImageView *current=view;
                                if(!current||![current.accessibilityIdentifier isEqualToString:url])return;
                                current.image=decoded;
                                if(maximumPixelSize>512){current.contentMode=UIViewContentModeScaleAspectFill;current.tintColor=nil;}
                                if(completion)completion(YES,0);
                            });
                            return;
                        }
                        [owner enqueueImageRequestForURL:url cacheKey:cacheKey maximumPixelSize:maximumPixelSize view:view completion:completion generation:generation];
                    });
                }];
                return;
            }
        }
        if(memCached){
            dispatch_async(dispatch_get_main_queue(),^{
                UIImageView *current=view;
                if(!current||![current.accessibilityIdentifier isEqualToString:url])return;
                current.image=memCached;
                if(maximumPixelSize>512){current.contentMode=UIViewContentModeScaleAspectFill;current.tintColor=nil;}
                if(completion)completion(YES,0);
            });
            return;
        }
        [self enqueueImageRequestForURL:url cacheKey:cacheKey maximumPixelSize:maximumPixelSize view:view completion:completion generation:generation];
    }});
}
// T18/PERF-02：网络入队尾——只在 _queue 上调用。磁盘解码是异步回来的，这里重核
// generation 与视图归属，视图已换目标或全局已取消时不再建请求。
- (void)enqueueImageRequestForURL:(NSString *)url cacheKey:(NSString *)cacheKey maximumPixelSize:(NSUInteger)maximumPixelSize view:(UIImageView *)view completion:(nullable HostImageLoadCompletion)completion generation:(NSUInteger)generation {
    if(generation!=self.generation || !view)return;
    if(![[self.viewTargets objectForKey:view] isEqualToString:cacheKey])return;
        NSDate *failed=[self.failures objectForKey:cacheKey];if(failed && failed.timeIntervalSinceNow>0){NSTimeInterval retryAfter=MAX(0,failed.timeIntervalSinceNow);dispatch_async(dispatch_get_main_queue(),^{UIImageView *current=view;if(current&&[current.accessibilityIdentifier isEqualToString:url]&&completion)completion(NO,retryAfter);});return;}
        HostImageRequest *request=self.requests[cacheKey];
        if(!request) {
            if(self.requests.count>=ImageQueueLimit){
                for(NSInteger i=(NSInteger)self.pending.count-1;i>=0;i--){
                    HostImageRequest *queued=self.pending[(NSUInteger)i];
                    if(!queued.views.allObjects.count){[self.requests removeObjectForKey:queued.cacheKey];[self.pending removeObjectAtIndex:(NSUInteger)i];}
                }
            }
            if(self.requests.count>=ImageQueueLimit){dispatch_async(dispatch_get_main_queue(),^{UIImageView *current=view;if(current&&[current.accessibilityIdentifier isEqualToString:url]&&completion)completion(NO,30);});return;}
            request=[HostImageRequest new];request.url=url;request.cacheKey=cacheKey;request.maximumPixelSize=maximumPixelSize;request.generation=generation;
            request.views=[NSHashTable weakObjectsHashTable];request.observers=[NSMutableArray array];self.requests[cacheKey]=request;[self.pending addObject:request];
        } else if(!request.task && self.pending.count>1 && [self.pending containsObject:request]){
            request.prefetch=NO;
            [self.pending removeObject:request];
            [self.pending insertObject:request atIndex:0];
        }
        [request.views addObject:view];if(completion){HostImageObserver *observer=[HostImageObserver new];observer.view=view;observer.completion=completion;[request.observers addObject:observer];}[self startPending];
}
// T18/PERF-02：解码（ImageIO 缩略图）在解码队列做，不占协调队列；完成回调也在解码队列，
// 调用方负责回 _queue。failureStage 为 nil 表示解码成功。
- (void)decodeImageData:(NSData *)data maximumPixelSize:(NSUInteger)maximumPixelSize completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable failureStage, double pixelWidth, double pixelHeight))completion {
    NSData *body=data;
    [self.decodeQueue addOperationWithBlock:^{
        UIImage *image=nil;NSString *failureStage=nil;double pixelWidth=0,pixelHeight=0;
        CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)body, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
        if(source){
            NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
            id width=properties[(__bridge NSString *)kCGImagePropertyPixelWidth],height=properties[(__bridge NSString *)kCGImagePropertyPixelHeight];
            pixelWidth=[width isKindOfClass:NSNumber.class]?[width doubleValue]:0;pixelHeight=[height isKindOfClass:NSNumber.class]?[height doubleValue]:0;
            if(!isfinite(pixelWidth)||!isfinite(pixelHeight)||pixelWidth<=0||pixelHeight<=0)failureStage=@"image_metadata_invalid";
            else if(!HostImageDimensionsAllowed(pixelWidth,pixelHeight))failureStage=@"image_dimensions_exceeded";
            else{
                NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                    (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                    (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(maximumPixelSize),
                    (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
                CGImageRef thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
                if(thumbnail){image=[UIImage imageWithCGImage:thumbnail];CGImageRelease(thumbnail);}
            }
            CFRelease(source);
        }
        if(completion)completion(image,failureStage,pixelWidth,pixelHeight);
    }];
}
// T18/PERF-03：位图内存成本（bytesPerRow × height），内存缓存与在途压缩体分别计费时共用。
static NSUInteger HostImageBitmapCost(UIImage *image) {
    CGImageRef cg=image.CGImage;
    return cg?(NSUInteger)(CGImageGetBytesPerRow(cg)*CGImageGetHeight(cg)):0;
}
- (void)prefetchPosterURLs:(NSArray<NSString *> *)urls {
    if(!urls.count)return;
    NSArray<NSString *> *snapshot=[urls copy];
    NSUInteger generation=self.generation;
    dispatch_async(self.queue, ^{@autoreleasepool {
        if(generation!=self.generation)return;
        NSUInteger scheduled=0;
        for(id raw in snapshot){
            if(scheduled>=6 || (self.tasks.count+self.pending.count)>=ImageConcurrentLimit)break;
            if(![raw isKindOfClass:NSString.class])continue;
            NSString *url=[(NSString *)raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if(!url.length)continue;
            NSURL *target=[NSURL URLWithString:url];
            if(!target.host.length || ![@[@"http",@"https"] containsObject:target.scheme.lowercaseString])continue;
            NSString *cacheKey=[NSString stringWithFormat:@"1024|%@",url];
            if([self.cache objectForKey:cacheKey] || self.requests[cacheKey] || [self.failures objectForKey:cacheKey])continue;
            NSString *diskPath=[self diskThumbnailPathForCacheKey:cacheKey url:url maximumPixelSize:1024];
            if(diskPath.length && [NSFileManager.defaultManager fileExistsAtPath:diskPath])continue;
            HostImageRequest *request=[HostImageRequest new];
            request.url=url;request.cacheKey=cacheKey;request.maximumPixelSize=1024;request.generation=generation;request.prefetch=YES;
            request.views=[NSHashTable weakObjectsHashTable];request.observers=[NSMutableArray array];
            self.requests[cacheKey]=request;[self.pending addObject:request];
            scheduled++;
        }
        if(scheduled)[self startPending];
    }});
}
- (NSUInteger)maximumBodyLengthForRequest:(HostImageRequest *)record {
    // Movie artwork is decoded to at most 1024 px and often arrives as a
    // multi-megabyte JPEG. Keep generic logos at 2 MiB while allowing bounded
    // poster payloads up to 4 MiB.
    return record.maximumPixelSize>512?PosterBodyLimit:ImageBodyLimit;
}
- (NSMutableData *)domainStateForURL:(NSString *)url {
    NSURL *target=[NSURL URLWithString:url];NSString *key=[NSString stringWithFormat:@"%@://%@:%@",target.scheme.lowercaseString,target.host.lowercaseString,target.port?:([target.scheme.lowercaseString isEqual:@"https"]?@443:@80)];
    NSMutableData *state=[self.domainFailures objectForKey:key];if(!state){state=[NSMutableData dataWithLength:sizeof(HostImageDomainState)];[self.domainFailures setObject:state forKey:key];}return state;
}
- (void)startPending {
    while(self.tasks.count<ImageConcurrentLimit && self.pending.count) {
        HostImageRequest *record=self.pending.firstObject;[self.pending removeObjectAtIndex:0];
        if(record.generation!=self.generation || (!record.views.allObjects.count && !record.prefetch)){[self.requests removeObjectForKey:record.cacheKey];continue;}
        NSMutableData *domain=[self domainStateForURL:record.url];
        if(!HostImageDomainAllows(domain.mutableBytes,CACurrentMediaTime())){[self.requests removeObjectForKey:record.cacheKey];continue;}
        NSURL *targetURL=[NSURL URLWithString:record.url];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:targetURL];
        [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
        NSString *host=targetURL.host.lowercaseString?:@"";
        if([host hasSuffix:@"doubanio.com"])[request setValue:@"https://movie.douban.com/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"hdslb.com"])[request setValue:@"https://www.bilibili.com/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"67c6c7a.com"]||[host containsString:@"4kvm"])[request setValue:@"https://www.4kvm.org/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"ykimg.com"])[request setValue:@"https://v.youku.com/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"gtimg.cn"]||[host hasSuffix:@"qpic.cn"])[request setValue:@"https://v.qq.com/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"iqiyipic.com"]||[host hasSuffix:@"qiyipic.com"])[request setValue:@"https://www.iqiyi.com/" forHTTPHeaderField:@"Referer"];
        else if([host hasSuffix:@"hitv.com"]||[host hasSuffix:@"mgtv.com"])[request setValue:@"https://www.mgtv.com/" forHTTPHeaderField:@"Referer"];
        else if(host.length&&![host isEqualToString:@"127.0.0.1"]&&![host isEqualToString:@"localhost"]&&![host hasSuffix:@".test"]&&![host hasSuffix:@".example"])[request setValue:[NSString stringWithFormat:@"%@://%@/",targetURL.scheme.lowercaseString?:@"https",host] forHTTPHeaderField:@"Referer"];
        record.data=[NSMutableData data];record.startedAt=CACurrentMediaTime();record.httpStatus=0;record.expectedContentLength=-1;record.responseContentType=@"";record.responseEncrypted=NO;record.failureStage=nil;record.task=[self.session dataTaskWithRequest:request];
        record.task.priority=record.prefetch?NSURLSessionTaskPriorityLow:NSURLSessionTaskPriorityDefault;self.tasks[@(record.task.taskIdentifier)]=record;[record.task resume];
    }
}
- (void)finish:(NSURLSessionTask *)task error:(NSError *)error {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    [self.tasks removeObjectForKey:@(task.taskIdentifier)];
    NSMutableData *domain=[self domainStateForURL:record.url];
    BOOL truncatedBody=(!error && record.expectedContentLength>0 && (long long)record.data.length<record.expectedContentLength);
    if(truncatedBody && !record.failureStage.length)record.failureStage=@"response_truncated";
    if(record.generation==self.generation){
        HostImageDomainState *state=domain.mutableBytes;unsigned previous=state->timeouts;BOOL probe=state->probe;
        NSString *recordHost=[NSURL URLWithString:record.url].host.lowercaseString?:@"";
        BOOL isLoopbackHost=([recordHost isEqualToString:@"127.0.0.1"]||[recordHost isEqualToString:@"localhost"]||[recordHost isEqualToString:@"::1"]);
        BOOL isDomainTimeout=!isLoopbackHost&&(truncatedBody||([error.domain isEqual:NSURLErrorDomain]&&(error.code==NSURLErrorTimedOut||error.code==NSURLErrorSecureConnectionFailed||error.code==NSURLErrorCannotFindHost||error.code==NSURLErrorCannotConnectToHost)));
        BOOL ignoreForDomainReset=(error.code==NSURLErrorCancelled)||(!isDomainTimeout&&(error!=nil||record.httpStatus!=200||record.failureStage.length>0));
        HostImageDomainFinish(state,CACurrentMediaTime(),isDomainTimeout,ignoreForDomainReset);
        if((previous<3&&state->timeouts>=3)||probe){
            NSString *backedOffHost=recordHost;
            [RuntimeDiagnostics.shared recordEvent:probe?@"image_domain_probe_finished":@"image_domain_backoff_started" category:@"media_api" fields:@{@"image_host":backedOffHost,@"http_status":@(record.httpStatus),@"error_code":@(error.code),@"remaining_backoff_seconds":@(MAX(0,state->until-CACurrentMediaTime())),@"timeout_streak":@(state->timeouts)}];
            if(state->timeouts>=3 && backedOffHost.length && !isLoopbackHost){
                NSTimeInterval backoffRemaining=MAX(0,state->until-CACurrentMediaTime());
                NSMutableArray<HostImageRequest *> *dropped=[NSMutableArray array];
                for(NSInteger i=(NSInteger)self.pending.count-1;i>=0;i--){
                    HostImageRequest *queued=self.pending[(NSUInteger)i];
                    if([self domainStateForURL:queued.url]==domain){
                        [self.requests removeObjectForKey:queued.cacheKey];
                        [self.pending removeObjectAtIndex:(NSUInteger)i];
                        [dropped addObject:queued];
                    }
                }
                // T18/PERF-04：退避移除的排队请求也要终结观察者（带剩余退避秒数，
                // 重试回调按退避到期再试），而不是静默丢弃。
                for(HostImageRequest *queued in dropped)[self finishRequest:queued image:nil retryAfter:backoffRemaining];
                for(HostImageRequest *inflight in self.tasks.allValues.copy){
                    if([self domainStateForURL:inflight.url]==domain && inflight.httpStatus!=200){
                        inflight.failureStage=@"domain_backoff_fast_fail";
                        [inflight.task cancel];
                    }
                }
            }
        }
    }
    if(!error && record.generation==self.generation && record.data.length && !record.responseEncrypted) {
        // T18/PERF-02：解码走解码队列；请求留在 requests 里继续合并同 key 到达者，
        // 解码完成（completeDecodedRequest）时才终结。磁盘 epoch 在解码开始时抓取。
        record.diskEpoch=self.diskEpoch;
        NSData *body=record.data;
        __weak typeof(self) weakSelf=self;
        [self decodeImageData:body maximumPixelSize:record.maximumPixelSize completion:^(UIImage *decoded, NSString *failureStage, double pixelWidth, double pixelHeight){
            HostImageLoader *owner=weakSelf;if(!owner)return;
            dispatch_async(owner.queue, ^{
                record.pixelWidth=pixelWidth;record.pixelHeight=pixelHeight;
                [owner completeDecodedRequest:record error:error image:decoded failureStage:failureStage];
            });
        }];
        [self startPending];
        return;
    }
    [self completeDecodedRequest:record error:error image:nil failureStage:record.failureStage];
}
// T18/PERF-02/03/04：解码完成终结（只在 _queue 上调用）。装内存缓存、排磁盘写、
// 记失败与诊断、终结观察者、放行下一批待办。
- (void)completeDecodedRequest:(HostImageRequest *)record error:(nullable NSError *)error image:(nullable UIImage *)image failureStage:(nullable NSString *)failureStage {
    [self.requests removeObjectForKey:record.cacheKey];
    self.inFlightCompressedBytes-=MIN(self.inFlightCompressedBytes,record.data.length);
    if(image && record.generation==self.generation){
        NSUInteger cost=HostImageBitmapCost(image);
        [self.cache setObject:image forKey:record.cacheKey cost:cost];self.memoryCacheBytes+=cost;
        [self scheduleDiskWriteForImage:image cacheKey:record.cacheKey url:record.url maximumPixelSize:record.maximumPixelSize diskEpoch:record.diskEpoch];
    }
    if(!image)record.failureStage=failureStage?:record.failureStage;
    if(!image && record.generation==self.generation && (error.code!=NSURLErrorCancelled||record.failureStage.length)){
        [self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];
        NSString *stage=record.failureStage;
        if(!stage.length)stage=error?@"network_error":(record.data.length?@"image_decode_failed":@"empty_body");
        if(RuntimeDiagnostics.shared.enabled){
            NSURL *imageURL=[NSURL URLWithString:record.url];
            [RuntimeDiagnostics.shared recordEvent:@"poster_image_failed" category:@"media_api" fields:@{
                @"failure_stage":stage,@"image_host":imageURL.host.lowercaseString?:@"",
                @"image_extension":imageURL.pathExtension.lowercaseString?:@"",@"http_status":@(record.httpStatus),
                @"content_type":record.responseContentType?:@"",@"encrypted_response":@(record.responseEncrypted),@"response_bytes":@(record.data.length),
                @"expected_content_length_known":@(record.expectedContentLength>=0),@"expected_response_bytes":@(MAX(0,record.expectedContentLength)),
                @"response_length_matches_expected":@(record.expectedContentLength>=0&&(long long)record.data.length==record.expectedContentLength),
                @"image_pixel_width":@(isfinite(record.pixelWidth)?record.pixelWidth:0),@"image_pixel_height":@(isfinite(record.pixelHeight)?record.pixelHeight:0),
                @"elapsed_ms":@((NSInteger)(MAX(0,CACurrentMediaTime()-record.startedAt)*1000)),
                @"transport_cancelled_for_validation":@(error.code==NSURLErrorCancelled&&record.failureStage.length>0),
                @"negative_cache_seconds":@(HostImageFailureBackoff(record.httpStatus)),
                @"error_domain":error.domain?:@"",@"error_code":@(error.code)
            }];
        }
    }
    // Never carry a potentially 2 MB network body onto the UI queue.
    record.data=nil;record.task=nil;
    [self finishRequest:record image:(image&&record.generation==self.generation)?image:nil retryAfter:HostImageFailureBackoff(record.httpStatus)];
    [self startPending];
}
// T18/PERF-04：统一终结路径（只在 _queue 上调用）。观察者至多完成一次；
// 取消（generation 已变）也终结，但图片不赋值、retryAfter 强制为 0——重试回调以
// retryAfter>0 为重试信号，取消后带退避秒数会复活已取消的请求。
- (void)finishRequest:(HostImageRequest *)record image:(nullable UIImage *)image retryAfter:(NSTimeInterval)retryAfter {
    if(record.completionDelivered)return;record.completionDelivered=YES;
    NSArray<HostImageObserver *> *observers=record.observers.copy?:@[];
    NSArray<UIImageView *> *views=record.views.allObjects?:@[];
    if(record.generation!=self.generation){image=nil;retryAfter=0;}
    if(image||observers.count)dispatch_async(dispatch_get_main_queue(), ^{
        for(UIImageView *view in views)if([view.accessibilityIdentifier isEqualToString:record.url]){if(image)view.image=image;if(image&&record.maximumPixelSize>512){view.contentMode=UIViewContentModeScaleAspectFill;view.tintColor=nil;}}
        for(HostImageObserver *observer in observers){UIImageView *view=observer.view;if(!view||![view.accessibilityIdentifier isEqualToString:record.url])continue;if(observer.completion)observer.completion(image!=nil,image?0:retryAfter);}
    });
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
    NSUInteger bodyLimit=record?[self maximumBodyLengthForRequest:record]:ImageBodyLimit;
    if(record){record.httpStatus=status;record.expectedContentLength=response.expectedContentLength;NSString *contentType=response.MIMEType.lowercaseString?:@"";record.responseContentType=[contentType substringToIndex:MIN((NSUInteger)96,contentType.length)];NSDictionary *headers=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response allHeaderFields]:@{};for(id key in headers)if([[key description].lowercaseString isEqual:@"encrypted"]&&[[headers[key] description] isEqual:@"1"]){record.responseEncrypted=YES;break;}if(status!=200)record.failureStage=@"http_status";else if(response.expectedContentLength>(long long)bodyLimit)record.failureStage=@"response_too_large";else if(record.responseEncrypted)record.failureStage=@"encrypted_image_requires_decryption_or_clear_mirror";}
    BOOL valid=record && status==200 && response.expectedContentLength<=(long long)bodyLimit && !record.responseEncrypted;
    completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid && record){[self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    if(record.data.length+data.length>[self maximumBodyLengthForRequest:record]){record.failureStage=@"response_too_large";[self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];[task cancel];return;}
    // T18/PERF-03：在途压缩体单独计费（与内存缓存分开），finish/取消时扣减。
    self.inFlightCompressedBytes+=data.length;
    [record.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self finish:task error:error]; }
- (void)cancelPending {
    NSAssert(NSThread.isMainThread, @"Cancel on main thread");self.generation++;
    dispatch_async(self.queue, ^{
        // T18/PERF-04：取消的任务也要终结观察者（retryAfter=0，不触发重试），
        // 否则调用方永远等不到结果；在途压缩字节随任务一起扣减。
        for(HostImageRequest *record in self.tasks.allValues){
            self.inFlightCompressedBytes-=MIN(self.inFlightCompressedBytes,record.data.length);
            NSMutableData *domain=[self domainStateForURL:record.url];HostImageDomainFinish(domain.mutableBytes,CACurrentMediaTime(),0,1);
            [self finishRequest:record image:nil retryAfter:0];
            [record.task cancel];
        }
        // T18/PERF-04：排队未开始的请求同样终结（无 task、无 body，不扣在途字节）。
        for(HostImageRequest *record in self.pending)[self finishRequest:record image:nil retryAfter:0];
        [self.tasks removeAllObjects];[self.requests removeAllObjects];[self.pending removeAllObjects];[self.viewTargets removeAllObjects];
    });
}
- (void)clearCache { [self.cache removeAllObjects];[self.failures removeAllObjects];[self.domainFailures removeAllObjects];dispatch_async(self.queue, ^{self.memoryCacheBytes=0;}); }
- (void)clearDiskCache {
    [self clearCache];
    // T18/PERF-05：清盘自增磁盘 epoch（旧 epoch 的写盘请求直接丢弃），目录删除走
    // 磁盘队列，与写盘串行——清盘后旧任务不再回写。
    self.diskEpoch++;
    NSString *dir = self.diskCacheDirectory;
    if (!dir.length) return;
    dispatch_async(self.diskQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:dir error:NULL];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
}
// T18/PERF-01：写盘（JPEG 编码也在磁盘队列做）+ 写后触发 LRU 清理；epoch 不符直接丢弃。
- (void)scheduleDiskWriteForImage:(UIImage *)image cacheKey:(NSString *)cacheKey url:(NSString *)url maximumPixelSize:(NSUInteger)maximumPixelSize diskEpoch:(NSUInteger)diskEpoch {
    NSString *diskPath=[self diskThumbnailPathForCacheKey:cacheKey url:url maximumPixelSize:maximumPixelSize];
    if(!diskPath.length)return;
    dispatch_async(self.diskQueue, ^{
        if(diskEpoch!=self.diskEpoch)return;
        NSData *jpegData=UIImageJPEGRepresentation(image,0.82);
        if(jpegData.length && jpegData.length<=512*1024)[jpegData writeToFile:diskPath options:NSDataWritingAtomic error:NULL];
        [self trimDiskCacheOnDiskQueue];
    });
}
// T18/PERF-01：磁盘 LRU（只在磁盘队列上调用）。删过期（30 天）文件；总量超 128 MiB
// 时按修改时间从旧到新删至 80%；每遍最多删 50 个，仍超限则再排一遍。统计随清理更新。
- (void)trimDiskCacheOnDiskQueue {
    NSString *dir=self.diskCacheDirectory;if(!dir.length)return;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray<NSString *> *names=[fm contentsOfDirectoryAtPath:dir error:NULL]?:@[];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSMutableArray<NSDictionary *> *entries=[NSMutableArray array];
    NSUInteger totalBytes=0;
    for(NSString *name in names){
        if(![name hasSuffix:@".jpg"])continue;
        NSString *path=[dir stringByAppendingPathComponent:name];
        NSDictionary *attrs=[fm attributesOfItemAtPath:path error:NULL];
        if(!attrs)continue;
        NSUInteger size=[attrs[NSFileSize] unsignedIntegerValue];
        NSTimeInterval mtime=[attrs[NSFileModificationDate] timeIntervalSince1970];
        totalBytes+=size;
        [entries addObject:@{@"path":path,@"size":@(size),@"mtime":@(mtime)}];
    }
    self.diskCacheBytes=totalBytes;
    NSUInteger deleted=0;NSUInteger freed=0;
    for(NSDictionary *entry in entries.copy){
        if(deleted>=ImageDiskTrimBatchLimit)break;
        if(now-[entry[@"mtime"] doubleValue]>ImageDiskCacheTTLSeconds){
            if([fm removeItemAtPath:entry[@"path"] error:NULL]){deleted++;freed+=[entry[@"size"] unsignedIntegerValue];totalBytes-=[entry[@"size"] unsignedIntegerValue];[entries removeObject:entry];}
        }
    }
    if(totalBytes>ImageDiskCacheLimitBytes){
        NSArray *oldest=[entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){return [a[@"mtime"] compare:b[@"mtime"]];}];
        for(NSDictionary *entry in oldest){
            if(deleted>=ImageDiskTrimBatchLimit||totalBytes<=ImageDiskCacheTrimTargetBytes)break;
            if([fm removeItemAtPath:entry[@"path"] error:NULL]){deleted++;freed+=[entry[@"size"] unsignedIntegerValue];totalBytes-=[entry[@"size"] unsignedIntegerValue];}
        }
    }
    if(deleted){self.diskEvictionCount+=deleted;self.diskTrimmedBytes+=freed;self.diskCacheBytes=totalBytes;}
    // 删满一批说明扫描没做完（可能还有过期文件或仍超限），再排一遍；每遍文件数
    // 严格减少，不会无限循环。
    if(deleted>=ImageDiskTrimBatchLimit){
        __weak typeof(self) weakSelf=self;
        dispatch_async(self.diskQueue, ^{HostImageLoader *owner=weakSelf;if(owner)[owner trimDiskCacheOnDiskQueue];});
    }
}
// T18/PERF-03：分别计费的快照——内存缓存、在途压缩体、磁盘缓存各一栏，外加命中/淘汰计数。
// 主线程调用（经 _queue 同步取数）。
- (NSDictionary<NSString *, id> *)statisticsSnapshot {
    __block NSDictionary *snapshot=nil;
    dispatch_sync(self.queue, ^{
        snapshot=@{@"memoryCacheBytes":@(self.memoryCacheBytes),
                   @"inFlightCompressedBytes":@(self.inFlightCompressedBytes),
                   @"diskCacheBytes":@(self.diskCacheBytes),
                   @"cacheHits":@(self.cacheHitCount),
                   @"cacheMisses":@(self.cacheMissCount),
                   @"diskHits":@(self.diskHitCount),
                   @"diskEvictions":@(self.diskEvictionCount),
                   @"diskTrimmedBytes":@(self.diskTrimmedBytes),
                   @"decodeQueueDepth":@(self.decodeQueue.operationCount),
                   @"pendingCount":@(self.pending.count),
                   @"inFlightCount":@(self.tasks.count)};
    });
    return snapshot;
}
// T18/PERF-03：NSCache 淘汰时扣减内存缓存计费（回调线程不定，转 _queue 再扣，下限 0）。
- (void)cache:(NSCache *)cache willEvictObject:(id)obj {
    if(cache!=self.cache||![obj isKindOfClass:UIImage.class])return;
    NSUInteger cost=HostImageBitmapCost((UIImage *)obj);
    if(!cost)return;
    dispatch_async(self.queue, ^{self.memoryCacheBytes-=MIN(self.memoryCacheBytes,cost);});
}
@end
