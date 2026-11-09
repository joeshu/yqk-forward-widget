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
@end
@implementation HostImageRequest
@end

@interface HostImageObserver : NSObject
@property(nonatomic, weak) UIImageView *view;
@property(nonatomic, copy) HostImageLoadCompletion completion;
@end
@implementation HostImageObserver
@end

@interface HostImageLoader () <NSURLSessionDataDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
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
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView maximumPixelSize:(NSUInteger)maximumPixelSize completion:(nullable HostImageLoadCompletion)completion;
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
        _cache=[NSCache new];_cache.countLimit=360;_cache.totalCostLimit=32*1024*1024;
        _failures=[NSCache new];_failures.countLimit=200;
        _domainFailures=[NSCache new];_domainFailures.countLimit=64;
        _requests=[NSMutableDictionary dictionary];_tasks=[NSMutableDictionary dictionary];_pending=[NSMutableArray array];
        _viewTargets=[NSMapTable weakToStrongObjectsMapTable];
        NSURL *cachesDir=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *thumbDir=[cachesDir URLByAppendingPathComponent:@"CCTVHostImageThumbnails" isDirectory:YES];
        if(thumbDir){[NSFileManager.defaultManager createDirectoryAtURL:thumbDir withIntermediateDirectories:YES attributes:nil error:NULL];_diskCacheDirectory=thumbDir.path;}
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
        if(!memCached){
            NSString *diskPath=[self diskThumbnailPathForCacheKey:cacheKey url:url maximumPixelSize:maximumPixelSize];
            if(diskPath.length && [NSFileManager.defaultManager fileExistsAtPath:diskPath]){
                NSData *diskData=[NSData dataWithContentsOfFile:diskPath options:NSDataReadingMappedIfSafe error:NULL];
                if(diskData.length){
                    CGImageSourceRef src=CGImageSourceCreateWithData((__bridge CFDataRef)diskData,NULL);
                    if(src){
                        CGImageRef cg=CGImageSourceCreateImageAtIndex(src,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES});
                        if(cg){memCached=[UIImage imageWithCGImage:cg];[self.cache setObject:memCached forKey:cacheKey cost:CGImageGetBytesPerRow(cg)*CGImageGetHeight(cg)];CGImageRelease(cg);}
                        CFRelease(src);
                    }
                }
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
    }});
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
    [self.tasks removeObjectForKey:@(task.taskIdentifier)];[self.requests removeObjectForKey:record.cacheKey];
    NSMutableData *domain=[self domainStateForURL:record.url];
    BOOL truncatedBody=(!error && record.expectedContentLength>0 && (long long)record.data.length<record.expectedContentLength);
    if(truncatedBody && !record.failureStage.length)record.failureStage=@"response_truncated";
    if(record.generation==self.generation){
        HostImageDomainState *state=domain.mutableBytes;unsigned previous=state->timeouts;BOOL probe=state->probe;
        BOOL isDomainTimeout=truncatedBody||([error.domain isEqual:NSURLErrorDomain]&&(error.code==NSURLErrorTimedOut||error.code==NSURLErrorSecureConnectionFailed||error.code==NSURLErrorCannotFindHost||error.code==NSURLErrorCannotConnectToHost));
        BOOL ignoreForDomainReset=(error.code==NSURLErrorCancelled)||(!isDomainTimeout&&(error!=nil||record.httpStatus!=200||record.failureStage.length>0));
        HostImageDomainFinish(state,CACurrentMediaTime(),isDomainTimeout,ignoreForDomainReset);
        if((previous<3&&state->timeouts>=3)||probe){
            NSString *backedOffHost=[NSURL URLWithString:record.url].host.lowercaseString?:@"";
            [RuntimeDiagnostics.shared recordEvent:probe?@"image_domain_probe_finished":@"image_domain_backoff_started" category:@"media_api" fields:@{@"image_host":backedOffHost,@"http_status":@(record.httpStatus),@"error_code":@(error.code),@"remaining_backoff_seconds":@(MAX(0,state->until-CACurrentMediaTime())),@"timeout_streak":@(state->timeouts)}];
            if(state->timeouts>=3 && backedOffHost.length){
                for(NSInteger i=(NSInteger)self.pending.count-1;i>=0;i--){
                    HostImageRequest *queued=self.pending[(NSUInteger)i];
                    if([([NSURL URLWithString:queued.url].host.lowercaseString?:@"") isEqualToString:backedOffHost]){
                        [self.requests removeObjectForKey:queued.cacheKey];
                        [self.pending removeObjectAtIndex:(NSUInteger)i];
                    }
                }
                for(HostImageRequest *inflight in self.tasks.allValues.copy){
                    if([([NSURL URLWithString:inflight.url].host.lowercaseString?:@"") isEqualToString:backedOffHost] && inflight.httpStatus!=200){
                        inflight.failureStage=@"domain_backoff_fast_fail";
                        [inflight.task cancel];
                    }
                }
            }
        }
    }
    UIImage *image=nil;
    if(!error && record.generation==self.generation && record.data.length && !record.responseEncrypted) {
        CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)record.data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
        if(source) {
            NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
            id width=properties[(__bridge NSString *)kCGImagePropertyPixelWidth],height=properties[(__bridge NSString *)kCGImagePropertyPixelHeight];
            record.pixelWidth=[width isKindOfClass:NSNumber.class]?[width doubleValue]:0;record.pixelHeight=[height isKindOfClass:NSNumber.class]?[height doubleValue]:0;
            if(!isfinite(record.pixelWidth)||!isfinite(record.pixelHeight)||record.pixelWidth<=0||record.pixelHeight<=0)record.failureStage=@"image_metadata_invalid";
            else if(!HostImageDimensionsAllowed(record.pixelWidth,record.pixelHeight))record.failureStage=@"image_dimensions_exceeded";
            NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@(record.maximumPixelSize),
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
            CGImageRef thumbnail=record.failureStage.length?NULL:CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
            if(thumbnail){
                image=[UIImage imageWithCGImage:thumbnail];
                [self.cache setObject:image forKey:record.cacheKey cost:CGImageGetBytesPerRow(thumbnail)*CGImageGetHeight(thumbnail)];
                NSString *diskPath=[self diskThumbnailPathForCacheKey:record.cacheKey url:record.url maximumPixelSize:record.maximumPixelSize];
                if(diskPath.length){
                    NSData *jpegData=UIImageJPEGRepresentation(image,0.82);
                    if(jpegData.length && jpegData.length<=512*1024)[jpegData writeToFile:diskPath options:NSDataWritingAtomic error:NULL];
                }
                CGImageRelease(thumbnail);
            }
            CFRelease(source);
        }
    }
    if(!image && record.generation==self.generation && (error.code!=NSURLErrorCancelled||record.failureStage.length)){
        [self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];
        NSString *failureStage=record.failureStage;
        if(!failureStage.length)failureStage=error?@"network_error":(record.data.length?@"image_decode_failed":@"empty_body");
        if(RuntimeDiagnostics.shared.enabled){
            NSURL *imageURL=[NSURL URLWithString:record.url];
            [RuntimeDiagnostics.shared recordEvent:@"poster_image_failed" category:@"media_api" fields:@{
                @"failure_stage":failureStage,@"image_host":imageURL.host.lowercaseString?:@"",
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
    NSArray<HostImageObserver *> *observers=record.observers.copy?:@[];
    NSArray<UIImageView *> *views=record.views.allObjects?:@[];
    NSTimeInterval retryAfter=HostImageFailureBackoff(record.httpStatus);
    if(image||observers.count)dispatch_async(dispatch_get_main_queue(), ^{
        if(record.generation!=self.generation)return;
        for(UIImageView *view in views)if([view.accessibilityIdentifier isEqualToString:record.url]){if(image)view.image=image;if(image&&record.maximumPixelSize>512){view.contentMode=UIViewContentModeScaleAspectFill;view.tintColor=nil;}}
        for(HostImageObserver *observer in observers){UIImageView *view=observer.view;if(!view||![view.accessibilityIdentifier isEqualToString:record.url])continue;if(observer.completion)observer.completion(image!=nil,image?0:retryAfter);}
    });
    [self startPending];
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
    [record.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler {
    if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]&&challenge.protectionSpace.serverTrust){
        NSString *h=challenge.protectionSpace.host.lowercaseString?:@"";
        if(h.length&&![h isEqualToString:@"127.0.0.1"]&&![h isEqualToString:@"localhost"]&&![h hasSuffix:@".test"]&&![h hasSuffix:@".example"]){
            completionHandler(NSURLSessionAuthChallengeUseCredential,[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]);
            return;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling,nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self finish:task error:error]; }
- (void)cancelPending {
    NSAssert(NSThread.isMainThread, @"Cancel on main thread");self.generation++;
    dispatch_async(self.queue, ^{
        for(HostImageRequest *record in self.tasks.allValues){NSMutableData *domain=[self domainStateForURL:record.url];HostImageDomainFinish(domain.mutableBytes,CACurrentMediaTime(),0,1);[record.task cancel];}
        [self.tasks removeAllObjects];[self.requests removeAllObjects];[self.pending removeAllObjects];[self.viewTargets removeAllObjects];
    });
}
- (void)clearCache { [self.cache removeAllObjects];[self.failures removeAllObjects];[self.domainFailures removeAllObjects]; }
@end
