#import "TVBoxCatalogBulkImporter.h"
#import "MediaPackageDownloader.h"
#import "ServiceStore.h"

@interface TVBoxCatalogBulkImporter ()
@property(nonatomic,copy) NSArray<NSDictionary *> *jobs;
@property(nonatomic,copy) NSString *catalogID;
@property(nonatomic) NSUInteger nextIndex;
@property(nonatomic) NSUInteger completedCount;
@property(nonatomic) NSUInteger failedCount;
@property(nonatomic) NSUInteger succeededCount;
@property(nonatomic) NSUInteger maximumConcurrentDownloads;
@property(nonatomic,strong) NSMutableDictionary<NSUUID *,MediaPackageDownloader *> *active;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *imported;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *failures;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *receivedBytesByStage;
@property(nonatomic) NSUInteger totalReceivedBytes;
@property(nonatomic,copy) void (^completion)(NSArray<NSDictionary *> *,NSArray<NSDictionary *> *,BOOL);
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL finished;
@property(nonatomic,readwrite) BOOL downloadLimitReached;
@end

@implementation TVBoxCatalogBulkImporter
- (NSUInteger)maximumDownloadBytes { return 512*1024*1024; }
- (instancetype)init {
    self=[super init];
    if(self){
        _maximumConcurrentDownloads=3;
        _active=[NSMutableDictionary dictionary];
        _imported=[NSMutableArray array];
        _failures=[NSMutableArray array];
        _receivedBytesByStage=[NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)identityForSite:(NSDictionary *)site {
    NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
    NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
    NSDictionary *headers=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{};
    NSData *headerData=[NSJSONSerialization dataWithJSONObject:headers options:NSJSONWritingSortedKeys error:NULL];
    NSString *headerKey=[headerData base64EncodedStringWithOptions:0]?:@"";
    NSString *playURL=[site[@"playUrl"] isKindOfClass:NSString.class]?site[@"playUrl"]:@"";
    return [NSString stringWithFormat:@"%@\n%@\n%@\n%@",api,ext,headerKey,playURL];
}

- (void)importSites:(NSArray<NSDictionary *> *)sites catalogID:(NSString *)catalogID completion:(void (^)(NSArray<NSDictionary *> *,NSArray<NSDictionary *> *,BOOL))completion {
    NSAssert(NSThread.isMainThread,@"TVBox bulk imports are coordinated on the main thread");
    NSAssert(!self.completion&&self.active.count==0,@"A TVBox bulk importer handles one batch");
    self.cancelled=NO;self.finished=NO;self.downloadLimitReached=NO;self.nextIndex=0;self.completedCount=0;self.failedCount=0;self.succeededCount=0;self.totalReceivedBytes=0;self.receivedBytesByStage=[NSMutableDictionary dictionary];
    self.imported=[NSMutableArray array];self.failures=[NSMutableArray array];self.active=[NSMutableDictionary dictionary];
    self.catalogID=[catalogID copy]?:@"";self.completion=[completion copy];

    // Repeated pointers to one script with identical options are common in
    // large community collections. Download each distinct configuration once
    // and let the catalog map all of its keys back to the imported resource.
    NSMutableArray *jobs=[NSMutableArray array];NSMutableDictionary<NSString *,NSMutableDictionary *> *byIdentity=[NSMutableDictionary dictionary];
    for(id value in sites){
        if(![value isKindOfClass:NSDictionary.class]||![value[@"supported"] boolValue]||![value[@"apiKind"] isEqual:@"script"])continue;
        NSString *api=[value[@"api"] isKindOfClass:NSString.class]?value[@"api"]:@"";NSURLComponents *parts=[NSURLComponents componentsWithString:api];
        if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length)continue;
        NSString *identity=[self identityForSite:value];NSMutableDictionary *job=byIdentity[identity];
        if(!job){job=[@{@"site":value,@"siteKeys":[NSMutableArray array]} mutableCopy];byIdentity[identity]=job;[jobs addObject:job];}
        NSString *key=[value[@"key"] isKindOfClass:NSString.class]?value[@"key"]:@"";if(key.length&&![(NSMutableArray *)job[@"siteKeys"] containsObject:key])[(NSMutableArray *)job[@"siteKeys"] addObject:key];
    }
    self.jobs=jobs.copy;
    if(!self.jobs.count){[self finish];return;}
    [self pump];
}

- (void)pump {
    NSAssert(NSThread.isMainThread,@"TVBox bulk importer state is main-thread confined");
    while(!self.cancelled&&self.active.count<self.maximumConcurrentDownloads&&self.nextIndex<self.jobs.count){
        NSUInteger index=self.nextIndex++;NSDictionary *job=self.jobs[index],*site=job[@"site"];
        NSString *api=site[@"api"],*name=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"TVBox 站点";
        MediaPackageDownloader *downloader=[MediaPackageDownloader new];NSUUID *jobID=NSUUID.UUID;self.active[jobID]=downloader;
        __weak typeof(self) weakSelf=self;
        downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){
            TVBoxCatalogBulkImporter *owner=weakSelf;if(!owner||owner.cancelled||received<=0)return;
            NSString *stageKey=[NSString stringWithFormat:@"%@:%@",jobID.UUIDString,stage?:@""];
            NSUInteger previous=[owner.receivedBytesByStage[stageKey] unsignedIntegerValue],current=(NSUInteger)received;
            if(current<=previous)return;NSUInteger delta=current-previous;owner.receivedBytesByStage[stageKey]=@(current);
            if(delta>[owner maximumDownloadBytes]||owner.totalReceivedBytes>[owner maximumDownloadBytes]-delta){owner.downloadLimitReached=YES;[owner cancel];return;}
            owner.totalReceivedBytes+=delta;
        };
        [downloader importURL:[NSURL URLWithString:api] headers:site[@"header"] runtimeHint:nil completion:^(NSDictionary *service,NSError *error){
            TVBoxCatalogBulkImporter *owner=weakSelf;if(!owner)return;[owner.active removeObjectForKey:jobID];owner.completedCount++;
            if(owner.cancelled){if(service)[ServiceStore remove:service[@"id"]];}
            else if(error||!service){owner.failedCount++;[owner.failures addObject:@{@"name":name,@"message":error.localizedDescription?:@"站点脚本无法识别"}];}
            else{
                NSMutableDictionary *updated=[service mutableCopy],*manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];
                NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";if(ext.length)manifest[@"options"]=ext;
                manifest[@"name"]=name;updated[@"manifest"]=manifest;updated[@"name"]=name;
                updated[@"tvboxSiteKey"]=((NSArray *)job[@"siteKeys"]).firstObject?:@"";updated[@"tvboxSiteKeys"]=job[@"siteKeys"]?:@[];updated[@"tvboxCatalogID"]=owner.catalogID;
                if(site[@"playUrl"])updated[@"tvboxPlayURL"]=site[@"playUrl"];if(site[@"header"])updated[@"tvboxSiteHeader"]=site[@"header"];
                [owner.imported addObject:updated];owner.succeededCount++;
            }
            if(owner.onProgress)owner.onProgress(owner.completedCount,owner.jobs.count,owner.succeededCount,owner.failedCount,name);
            [owner pump];
        }];
    }
    if((self.cancelled||self.nextIndex>=self.jobs.count)&&!self.active.count)[self finish];
}

- (void)cancel {
    if(self.finished||!self.completion)return;
    NSAssert(NSThread.isMainThread,@"TVBox bulk importer cancellation runs on the main thread");
    self.cancelled=YES;self.nextIndex=self.jobs.count;
    for(MediaPackageDownloader *downloader in self.active.allValues.copy)[downloader cancel];
    if(!self.active.count)[self finish];
}

- (void)finish {
    if(self.finished)return;self.finished=YES;
    void(^completion)(NSArray *,NSArray *,BOOL)=self.completion;self.completion=nil;self.onProgress=nil;
    if(completion)completion(self.imported.copy,self.failures.copy,self.cancelled);
}
@end
