#import "HostImageLoader.h"
#import <ImageIO/ImageIO.h>

static NSUInteger const ImageBodyLimit = 2 * 1024 * 1024;
static NSUInteger const ImageConcurrentLimit = 4;
static NSUInteger const ImageQueueLimit = 96;

@interface HostImageRequest : NSObject
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSHashTable<UIImageView *> *views;
@property(nonatomic, copy) NSString *url;
@property(nonatomic) NSUInteger generation;
@end
@implementation HostImageRequest
@end

@interface HostImageLoader () <NSURLSessionDataDelegate>
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *cache;
@property(nonatomic, strong) NSCache<NSString *, NSDate *> *failures;
@property(nonatomic, strong) NSMutableDictionary<NSString *, HostImageRequest *> *requests;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, HostImageRequest *> *tasks;
@property(nonatomic, strong) NSMutableArray<HostImageRequest *> *pending;
@property(atomic) NSUInteger generation;
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
    NSAssert(NSThread.isMainThread, @"Image views must be configured on the main thread");
    imageView.image=nil;imageView.accessibilityIdentifier=url;
    if(!url.length)return;
    NSURL *target=[NSURL URLWithString:url];
    if(!target.host.length || ![@[@"http",@"https"] containsObject:target.scheme.lowercaseString])return;
    UIImage *cached=[self.cache objectForKey:url];if(cached){imageView.image=cached;return;}
    NSUInteger generation=self.generation;__weak UIImageView *view=imageView;
    dispatch_async(self.queue, ^{@autoreleasepool {
        if(generation!=self.generation || !view)return;
        NSDate *failed=[self.failures objectForKey:url];if(failed && -failed.timeIntervalSinceNow<30)return;
        HostImageRequest *request=self.requests[url];
        if(!request) {
            if(self.requests.count>=ImageQueueLimit)return;
            request=[HostImageRequest new];request.url=url;request.generation=generation;
            request.views=[NSHashTable weakObjectsHashTable];self.requests[url]=request;[self.pending addObject:request];
        }
        [request.views addObject:view];[self startPending];
    }});
}
- (void)startPending {
    while(self.tasks.count<ImageConcurrentLimit && self.pending.count) {
        HostImageRequest *record=self.pending.firstObject;[self.pending removeObjectAtIndex:0];
        if(record.generation!=self.generation || !record.views.allObjects.count){[self.requests removeObjectForKey:record.url];continue;}
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:record.url]];
        [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
        record.data=[NSMutableData data];record.task=[self.session dataTaskWithRequest:request];
        record.task.priority=NSURLSessionTaskPriorityLow;self.tasks[@(record.task.taskIdentifier)]=record;[record.task resume];
    }
}
- (void)finish:(NSURLSessionTask *)task error:(NSError *)error {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    [self.tasks removeObjectForKey:@(task.taskIdentifier)];[self.requests removeObjectForKey:record.url];
    UIImage *image=nil;
    if(!error && record.generation==self.generation && record.data.length) {
        CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)record.data, NULL);
        if(source) {
            NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@192,
                (__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
            CGImageRef thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
            if(thumbnail){image=[UIImage imageWithCGImage:thumbnail];[self.cache setObject:image forKey:record.url cost:CGImageGetBytesPerRow(thumbnail)*CGImageGetHeight(thumbnail)];CGImageRelease(thumbnail);}
            CFRelease(source);
        }
    }
    if(!image && record.generation==self.generation && error.code!=NSURLErrorCancelled)[self.failures setObject:NSDate.date forKey:record.url];
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
    BOOL valid=record && [response isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)response).statusCode==200 && response.expectedContentLength<=(long long)ImageBodyLimit;
    completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid && record){[self.failures setObject:NSDate.date forKey:record.url];}
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    HostImageRequest *record=self.tasks[@(task.taskIdentifier)];if(!record)return;
    if(record.data.length+data.length>ImageBodyLimit){[self.failures setObject:NSDate.date forKey:record.url];[task cancel];return;}
    [record.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self finish:task error:error]; }
- (void)cancelPending {
    NSAssert(NSThread.isMainThread, @"Cancel on main thread");self.generation++;
    dispatch_async(self.queue, ^{
        for(HostImageRequest *record in self.tasks.allValues)[record.task cancel];
        [self.tasks removeAllObjects];[self.requests removeAllObjects];[self.pending removeAllObjects];
    });
}
- (void)clearCache { [self.cache removeAllObjects];[self.failures removeAllObjects]; }
@end
