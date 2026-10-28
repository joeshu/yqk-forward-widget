#import "HostImageLoader.h"
#import "HostImageDecodePolicy.h"
#import "HostImageFailurePolicy.h"
#import "RuntimeDiagnostics.h"
#import <ImageIO/ImageIO.h>

static NSUInteger const ImageBodyLimit = 2 * 1024 * 1024;
static NSUInteger const PosterBodyLimit = 4 * 1024 * 1024;
static NSUInteger const ImageConcurrentLimit = 4;
static NSUInteger const ImageQueueLimit = 96;

@interface HostImageRequest : NSObject
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSHashTable<UIImageView *> *views;
@property(nonatomic, copy) NSString *url;
@property(nonatomic, copy) NSString *cacheKey;
@property(nonatomic) NSUInteger maximumPixelSize;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic) NSInteger httpStatus;
@property(nonatomic) double pixelWidth;
@property(nonatomic) double pixelHeight;
@property(nonatomic) long long expectedContentLength;
@property(nonatomic, copy) NSString *responseContentType;
@property(nonatomic, copy) NSString *failureStage;
@end
@implementation HostImageRequest
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
@property(atomic) NSUInteger generation;
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView maximumPixelSize:(NSUInteger)maximumPixelSize;
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
        _cache=[NSCache new];_cache.countLimit=200;_cache.totalCostLimit=16*1024*1024;
        _failures=[NSCache new];_failures.countLimit=200;
        _domainFailures=[NSCache new];_domainFailures.countLimit=64;
        _requests=[NSMutableDictionary dictionary];_tasks=[NSMutableDictionary dictionary];_pending=[NSMutableArray array];
        NSURLSessionConfiguration *config=configuration.copy;config.URLCache=nil;config.HTTPCookieStorage=nil;
        config.timeoutIntervalForRequest=6;config.timeoutIntervalForResource=10;config.HTTPMaximumConnectionsPerHost=4;
        NSOperationQueue *delegate=[NSOperationQueue new];delegate.maxConcurrentOperationCount=1;delegate.underlyingQueue=_queue;
        _session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegate];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(clearCache) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView {
    [self loadURL:url intoImageView:imageView maximumPixelSize:192];
}
- (void)loadPosterURL:(NSString *)url intoImageView:(UIImageView *)imageView {
    [self loadURL:url intoImageView:imageView maximumPixelSize:1024];
}
- (void)loadURL:(NSString *)url intoImageView:(UIImageView *)imageView maximumPixelSize:(NSUInteger)maximumPixelSize {
    NSAssert(NSThread.isMainThread, @"Image views must be configured on the main thread");
    imageView.image=nil;imageView.accessibilityIdentifier=url;
    if(!url.length)return;
    NSURL *target=[NSURL URLWithString:url];
    if(!target.host.length || ![@[@"http",@"https"] containsObject:target.scheme.lowercaseString])return;
    maximumPixelSize=MIN(MAX(maximumPixelSize,64),2048);NSString *cacheKey=[NSString stringWithFormat:@"%lu|%@",(unsigned long)maximumPixelSize,url];
    UIImage *cached=[self.cache objectForKey:cacheKey];if(cached){imageView.image=cached;return;}
    NSUInteger generation=self.generation;__weak UIImageView *view=imageView;
    dispatch_async(self.queue, ^{@autoreleasepool {
        if(generation!=self.generation || !view)return;
        NSDate *failed=[self.failures objectForKey:cacheKey];if(failed && failed.timeIntervalSinceNow>0)return;
        HostImageRequest *request=self.requests[cacheKey];
        if(!request) {
            if(self.requests.count>=ImageQueueLimit)return;
            request=[HostImageRequest new];request.url=url;request.cacheKey=cacheKey;request.maximumPixelSize=maximumPixelSize;request.generation=generation;
            request.views=[NSHashTable weakObjectsHashTable];self.requests[cacheKey]=request;[self.pending addObject:request];
        }
        [request.views addObject:view];[self startPending];
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
        if(record.generation!=self.generation || !record.views.allObjects.count){[self.requests removeObjectForKey:record.cacheKey];continue;}
        NSMutableData *domain=[self domainStateForURL:record.url];
        if(!HostImageDomainAllows(domain.mutableBytes,CACurrentMediaTime())){[self.requests removeObjectForKey:record.cacheKey];continue;}
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:record.url]];
        [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
        record.data=[NSMutableData data];record.startedAt=CACurrentMediaTime();record.httpStatus=0;record.expectedContentLength=-1;record.responseContentType=@"";record.failureStage=nil;record.task=[self.session dataTaskWithRequest:request];
        record.task.priority=NSURLSessionTaskPriorityLow;self.tasks[@(record.task.taskIdentifier)]=record;[record.task resume];
    }
}
- (void)finish:(NSURLSessionTask *)task error:(NSError *)error {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    [self.tasks removeObjectForKey:@(task.taskIdentifier)];[self.requests removeObjectForKey:record.cacheKey];
    NSMutableData *domain=[self domainStateForURL:record.url];
    if(record.generation==self.generation){
        HostImageDomainState *state=domain.mutableBytes;unsigned previous=state->timeouts;BOOL probe=state->probe;
        HostImageDomainFinish(state,CACurrentMediaTime(),[error.domain isEqual:NSURLErrorDomain]&&error.code==NSURLErrorTimedOut,error.code==NSURLErrorCancelled&&!record.failureStage.length);
        if((previous<3&&state->timeouts>=3)||probe)[RuntimeDiagnostics.shared recordEvent:probe?@"image_domain_probe_finished":@"image_domain_backoff_started" category:@"media_api" fields:@{@"image_host":[NSURL URLWithString:record.url].host?:@"",@"http_status":@(record.httpStatus),@"error_code":@(error.code),@"remaining_backoff_seconds":@(MAX(0,state->until-CACurrentMediaTime())),@"timeout_streak":@(state->timeouts)}];
    }
    UIImage *image=nil;
    if(!error && record.generation==self.generation && record.data.length) {
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
            if(thumbnail){image=[UIImage imageWithCGImage:thumbnail];[self.cache setObject:image forKey:record.cacheKey cost:CGImageGetBytesPerRow(thumbnail)*CGImageGetHeight(thumbnail)];CGImageRelease(thumbnail);}
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
                @"content_type":record.responseContentType?:@"",@"response_bytes":@(record.data.length),
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
    if(image)dispatch_async(dispatch_get_main_queue(), ^{
        if(record.generation!=self.generation)return;
        for(UIImageView *view in record.views.allObjects)if([view.accessibilityIdentifier isEqualToString:record.url])view.image=image;
    });
    [self startPending];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
    NSUInteger bodyLimit=record?[self maximumBodyLengthForRequest:record]:ImageBodyLimit;
    if(record){record.httpStatus=status;record.expectedContentLength=response.expectedContentLength;NSString *contentType=response.MIMEType.lowercaseString?:@"";record.responseContentType=[contentType substringToIndex:MIN((NSUInteger)96,contentType.length)];if(status!=200)record.failureStage=@"http_status";else if(response.expectedContentLength>(long long)bodyLimit)record.failureStage=@"response_too_large";}
    BOOL valid=record && status==200 && response.expectedContentLength<=(long long)bodyLimit;
    completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid && record){[self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    if(record.data.length+data.length>[self maximumBodyLengthForRequest:record]){record.failureStage=@"response_too_large";[self.failures setObject:[NSDate dateWithTimeIntervalSinceNow:HostImageFailureBackoff(record.httpStatus)] forKey:record.cacheKey];[task cancel];return;}
    [record.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self finish:task error:error]; }
- (void)cancelPending {
    NSAssert(NSThread.isMainThread, @"Cancel on main thread");self.generation++;
    dispatch_async(self.queue, ^{
        for(HostImageRequest *record in self.tasks.allValues){NSMutableData *domain=[self domainStateForURL:record.url];HostImageDomainFinish(domain.mutableBytes,CACurrentMediaTime(),0,1);[record.task cancel];}
        [self.tasks removeAllObjects];[self.requests removeAllObjects];[self.pending removeAllObjects];
    });
}
- (void)clearCache { [self.cache removeAllObjects];[self.failures removeAllObjects]; }
@end
