#import "ResourceContentInspection.h"
#import "ResourceImportFetcher.h"
#import "ResourceImportWorkflowViewController.h"
#import "HostTheme.h"
#import "HostGlassActionSheetViewController.h"
#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import "ResourceImportSheetViewController.h"
#import "TVBoxCatalogStore.h"
#import "ServiceStore.h"
#import "M3UParser.h"
#import "RuntimeDiagnostics.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const ResourceImportRecentURLsPreferenceKey = @"cctv.resourceImport.recentURLs.v1";

static NSData *ResourceImportReadBounded(NSURL *url,NSUInteger limit) {
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:NULL];NSData *data=nil;
    @try{data=[file readDataUpToLength:limit+1 error:NULL];if(data.length>limit)data=nil;}@catch(NSException *exception){NSLog(@"[CCTVHost] resource import read raised %@",exception.name);data=nil;}@finally{[file closeAndReturnError:NULL];}return data;
}

static NSURL *ResourceImportNormalizedURL(NSString *raw) {
    if(![raw isKindOfClass:NSString.class])return nil;
    NSString *trimmed=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!trimmed.length)return nil;
    if([[trimmed lowercaseString] hasPrefix:@"https://"]&&![trimmed hasPrefix:@"https://"])trimmed=[@"https://" stringByAppendingString:[trimmed substringFromIndex:8]];
    else if([[trimmed lowercaseString] hasPrefix:@"http://"]&&![trimmed hasPrefix:@"http://"])trimmed=[@"http://" stringByAppendingString:[trimmed substringFromIndex:7]];
    NSURL *direct=[NSURL URLWithString:trimmed];
    if(direct&&direct.host.length&&[@[@"http",@"https"] containsObject:direct.scheme.lowercaseString])return direct;
    NSMutableCharacterSet *allowed=[NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed addCharactersInString:@"#%/:?@[]!$&'()*+,;="];
    NSString *encoded=[trimmed stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *fallback=encoded.length?[NSURL URLWithString:encoded]:nil;
    if(fallback&&fallback.host.length&&[@[@"http",@"https"] containsObject:fallback.scheme.lowercaseString])return fallback;
    return nil;
}

// 自动切分粘连在一起的多条 HTTP/HTTPS 链接（例如 a.hawkhttps://b.hawk 或 a.jsonhttps://b.js）并提取全部有效地址
static NSString *ResourceImportSplitConcatenatedURLs(NSString *text) {
    if(![text isKindOfClass:NSString.class]||!text.length)return @"";
    static NSRegularExpression *concatRe=nil;
    static NSRegularExpression *boundaryRe=nil;
    static dispatch_once_t splitOnce;
    dispatch_once(&splitOnce,^{
        concatRe=[NSRegularExpression regularExpressionWithPattern:@"(\\.(?:json|hawk|js|hjs|mjs|cjs|py|m3u8|m3u|txt|zip|php|xml|webox|jar|md5))(https?://)" options:NSRegularExpressionCaseInsensitive error:NULL];
        boundaryRe=[NSRegularExpression regularExpressionWithPattern:@"(?<![=?&/])([^\\s=\"'<>?&])(https?://sub\\.lytvs\\.top/)" options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSString *step=[concatRe stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"$1\n$2"];
    return [boundaryRe stringByReplacingMatchesInString:step options:0 range:NSMakeRange(0,step.length) withTemplate:@"$1\n$2"];
}

static NSArray<NSString *> *ResourceImportExtractURLStrings(NSString *text) {
    if(![text isKindOfClass:NSString.class]||!text.length)return @[];
    NSString *prepared=ResourceImportSplitConcatenatedURLs(text);
    static NSRegularExpression *re=nil;
    static dispatch_once_t extractOnce;
    dispatch_once(&extractOnce,^{
        re=[NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>\\u3000]+" options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    NSArray<NSTextCheckingResult *> *matches=[re matchesInString:prepared options:0 range:NSMakeRange(0,prepared.length)];
    NSMutableOrderedSet<NSString *> *results=[NSMutableOrderedSet orderedSet];
    for(NSTextCheckingResult *match in matches){
        NSString *candidate=[prepared substringWithRange:match.range];
        while(candidate.length>0){
            unichar last=[candidate characterAtIndex:candidate.length-1];
            if(last==','||last==';'||last==')'||last==']'||last=='}'||last==0xFF0C||last==0x3002||last==0xFF09||last==0x3011){
                candidate=[candidate substringToIndex:candidate.length-1];
            }else break;
        }
        NSURL *normalized=ResourceImportNormalizedURL(candidate);
        if(normalized)[results addObject:normalized.absoluteString];
    }
    return results.array;
}

static NSData *ResourceImportBundledFallbackForURL(NSURL *url) {
    if(!url)return nil;
    NSString *abs=(url.absoluteString.stringByRemovingPercentEncoding?:url.absoluteString).lowercaseString;
    if([abs containsString:@"ddgksf2013.top/webox/index.json"]||[abs hasSuffix:@"/webox/index.json"]){
        NSString *p=[NSBundle.mainBundle pathForResource:@"webox-index" ofType:@"json" inDirectory:@"BuiltinMedia"];
        if(p.length)return [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:NULL];
        if([NSFileManager.defaultManager fileExistsAtPath:@"Resources/BuiltinMedia/webox-index.json"])return [NSData dataWithContentsOfFile:@"Resources/BuiltinMedia/webox-index.json" options:NSDataReadingMappedIfSafe error:NULL];
    }
    if([abs containsString:@"gitee.com/cycod/tvbox"]||[abs containsString:@"cycod/tvbox/raw/master/api.json"]){
        NSString *p=[NSBundle.mainBundle pathForResource:@"cycod-tvbox" ofType:@"json" inDirectory:@"BuiltinMedia"];
        if(p.length)return [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:NULL];
        if([NSFileManager.defaultManager fileExistsAtPath:@"Resources/BuiltinMedia/cycod-tvbox.json"])return [NSData dataWithContentsOfFile:@"Resources/BuiltinMedia/cycod-tvbox.json" options:NSDataReadingMappedIfSafe error:NULL];
    }
    if([abs containsString:@"cttv.vip/app/json/ctys.json"]||[abs containsString:@"cttv.vip/ys/json/ctys.json"]||[abs hasSuffix:@"/ctys.json"]){
        NSString *p=[NSBundle.mainBundle pathForResource:@"cttv-ctys" ofType:@"json" inDirectory:@"BuiltinMedia"];
        if(p.length)return [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:NULL];
        if([NSFileManager.defaultManager fileExistsAtPath:@"Resources/BuiltinMedia/cttv-ctys.json"])return [NSData dataWithContentsOfFile:@"Resources/BuiltinMedia/cttv-ctys.json" options:NSDataReadingMappedIfSafe error:NULL];
    }
    NSString *last=(url.lastPathComponent.stringByRemovingPercentEncoding?:url.lastPathComponent).lowercaseString;
    NSDictionary<NSString *,NSString *> *weboxScripts=@{
        @"4k影视.webox.js":@"webox-4kvm",
        @"hstream.webox.js":@"webox-hstream",
        @"瓜子.webox.js":@"webox-guazi",
        @"肉.webox.js":@"webox-rou",
        @"one一个.webox.js":@"webox-one",
    };
    NSString *res=weboxScripts[last];
    if(res.length){
        NSString *p=[NSBundle.mainBundle pathForResource:res ofType:@"js" inDirectory:@"BuiltinMedia"];
        return p.length?[NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:NULL]:nil;
    }
    return nil;
}

static void ResourceImportRecordRecentURL(NSString *urlString) {
    if(![urlString isKindOfClass:NSString.class]||!urlString.length)return;
    NSURL *u=ResourceImportNormalizedURL(urlString);
    if(!u)return;
    NSString *canonical=u.absoluteString;
    NSArray *existing=[NSUserDefaults.standardUserDefaults arrayForKey:ResourceImportRecentURLsPreferenceKey];
    NSMutableArray<NSString *> *updated=[NSMutableArray arrayWithObject:canonical];
    if([existing isKindOfClass:NSArray.class]){
        for(id item in existing){
            if([item isKindOfClass:NSString.class]&&![item isEqualToString:canonical]&&updated.count<6){
                [updated addObject:item];
            }
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:updated.copy forKey:ResourceImportRecentURLsPreferenceKey];
}

static NSURL *ResourceImportSnapshotURL(void) {
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory=[support stringByAppendingPathComponent:@"CCTVHost/ImportTasks"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"workflow-v1.plist"]];
}
static dispatch_queue_t ResourceImportSnapshotQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("com.cctvhost.resource-import-snapshot",DISPATCH_QUEUE_SERIAL);});return queue;
}
static id ResourceImportFrozenPropertyList(id value) {
    if(!value||value==NSNull.null)return nil;
    if([value isKindOfClass:NSString.class]||[value isKindOfClass:NSNumber.class]||[value isKindOfClass:NSData.class]||[value isKindOfClass:NSDate.class])return [value copy];
    if([value isKindOfClass:NSURL.class])return [value absoluteString];
    if([value isKindOfClass:NSArray.class]){NSMutableArray *rows=[NSMutableArray array];for(id item in value){id frozen=ResourceImportFrozenPropertyList(item);if(frozen)[rows addObject:frozen];}return rows.copy;}
    if([value isKindOfClass:NSDictionary.class]){NSMutableDictionary *rows=[NSMutableDictionary dictionary];for(id key in value){if(![key isKindOfClass:NSString.class])continue;id frozen=ResourceImportFrozenPropertyList(value[key]);if(frozen)rows[key]=frozen;}return rows.copy;}
    return nil;
}
static NSArray *ResourceImportSnapshotCandidates(NSArray *candidates) {
    NSMutableArray *safe=[NSMutableArray array];
    NSArray *transientKeys=@[@"retryData",@"retryCompanions",@"retryBookmark",@"retryOrigin"];
    for(NSDictionary *candidate in candidates){
        if(![candidate isKindOfClass:NSDictionary.class])continue;
        NSMutableDictionary *row=[candidate mutableCopy];
        [row removeObjectsForKeys:transientKeys];
        [safe addObject:row.copy];
    }
    return safe.copy;
}
static NSURL *ResourceImportBlobDirectory(void) {
    NSURL *directory=[[ResourceImportSnapshotURL() URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"blobs" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];return directory;
}
static id ResourceImportSnapshotBlobs(id value,BOOL storing,NSMutableSet *referenced,NSUInteger *byteCount,NSError **error) {
    if([value isKindOfClass:NSData.class]){
        *byteCount+=[value length];if(*byteCount>80*1024*1024){if(error)*error=[NSError errorWithDomain:@"ImportSnapshot" code:1 userInfo:nil];return nil;}
        if(!storing||[value length]<=256*1024)return value;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256([value bytes],(CC_LONG)[value length],digest);NSMutableString *name=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[name appendFormat:@"%02x",digest[i]];[name appendString:@".blob"];
        NSURL *file=[ResourceImportBlobDirectory() URLByAppendingPathComponent:name];if(![NSFileManager.defaultManager fileExistsAtPath:file.path]&&![value writeToURL:file options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:error])return nil;
        [referenced addObject:name];return @{@"__cctvhostBlob":name};
    }
    if([value isKindOfClass:NSDictionary.class]){
        NSString *blob=value[@"__cctvhostBlob"];
        if(!storing&&[value count]==1&&[blob isKindOfClass:NSString.class]){
            if(blob.length!=69||[blob rangeOfString:@"^[a-f0-9]{64}\\.blob$" options:NSRegularExpressionSearch].location==NSNotFound){if(error)*error=[NSError errorWithDomain:@"ImportSnapshot" code:2 userInfo:nil];return nil;}
            [referenced addObject:blob];
            NSData *data=[NSData dataWithContentsOfURL:[ResourceImportBlobDirectory() URLByAppendingPathComponent:blob] options:NSDataReadingMappedIfSafe error:error];if(!data)return nil;
            return ResourceImportSnapshotBlobs(data,NO,referenced,byteCount,error);
        }
        NSMutableDictionary *copy=[NSMutableDictionary dictionary];for(id key in value){id item=ResourceImportSnapshotBlobs(value[key],storing,referenced,byteCount,error);if(!item)return nil;copy[key]=item;}return copy.copy;
    }
    if([value isKindOfClass:NSArray.class]){NSMutableArray *copy=[NSMutableArray array];for(id raw in value){id item=ResourceImportSnapshotBlobs(raw,storing,referenced,byteCount,error);if(!item)return nil;[copy addObject:item];}return copy.copy;}
    return value;
}
static NSDictionary *ResourceImportReadSnapshot(void) {
    const NSUInteger maximumBytes=80*1024*1024;NSData *data=[NSData dataWithContentsOfURL:ResourceImportSnapshotURL() options:NSDataReadingMappedIfSafe error:NULL];if(!data.length||data.length>maximumBytes)return nil;
    id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if(![value isKindOfClass:NSDictionary.class]||![@[@1,@2] containsObject:value[@"version"]])return nil;
    NSUInteger bytes=0,total=data.length;NSError *error=nil;NSMutableSet *references=[NSMutableSet set];id restored=ResourceImportSnapshotBlobs(value,NO,references,&bytes,&error);if(error||!restored)return nil;
    for(NSString *name in references){NSNumber *size=nil;NSURL *blob=[ResourceImportBlobDirectory() URLByAppendingPathComponent:name];[blob getResourceValue:&size forKey:NSURLFileSizeKey error:&error];if(error||NSUIntegerMax-total<size.unsignedIntegerValue)return nil;total+=size.unsignedIntegerValue;if(total>maximumBytes)return nil;}
    return total<=maximumBytes?restored:nil;
}
static BOOL ResourceImportWriteSnapshot(NSDictionary *snapshot,NSError **writeError) {
    const NSUInteger maximumBytes=80*1024*1024;NSURL *url=ResourceImportSnapshotURL(),*blobDirectory=ResourceImportBlobDirectory();NSMutableSet *references=[NSMutableSet set];NSUInteger bytes=0;NSError *error=nil;
    NSMutableSet *preexisting=[NSMutableSet set];for(NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:blobDirectory includingPropertiesForKeys:nil options:0 error:NULL])if([file.pathExtension isEqual:@"blob"])[preexisting addObject:file.lastPathComponent];
    BOOL success=NO;
    if(!snapshot.count)success=![NSFileManager.defaultManager fileExistsAtPath:url.path]||[NSFileManager.defaultManager removeItemAtURL:url error:&error];
    else {
        id external=ResourceImportSnapshotBlobs(snapshot,YES,references,&bytes,&error);
        NSData *data=external&&!error?[NSPropertyListSerialization dataWithPropertyList:external format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error]:nil;
        NSUInteger total=data.length;
        if(data.length){for(NSString *name in references){NSNumber *size=nil;NSURL *blob=[blobDirectory URLByAppendingPathComponent:name];[blob getResourceValue:&size forKey:NSURLFileSizeKey error:&error];if(error||NSUIntegerMax-total<size.unsignedIntegerValue){total=NSUIntegerMax;break;}total+=size.unsignedIntegerValue;}}
        if(!error&&data.length&&total<=maximumBytes)success=[data writeToURL:url options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error];
        else if(!error)error=[NSError errorWithDomain:@"ImportSnapshot" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Import snapshot exceeds the combined 80 MiB limit"}];
    }
    if(success){for(NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:blobDirectory includingPropertiesForKeys:nil options:0 error:NULL])if([file.pathExtension isEqual:@"blob"]&&![references containsObject:file.lastPathComponent])[NSFileManager.defaultManager removeItemAtURL:file error:NULL];}
    else {for(NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:blobDirectory includingPropertiesForKeys:nil options:0 error:NULL])if([file.pathExtension isEqual:@"blob"]&&![preexisting containsObject:file.lastPathComponent])[NSFileManager.defaultManager removeItemAtURL:file error:NULL];if(writeError)*writeError=error?:[NSError errorWithDomain:@"ImportSnapshot" code:4 userInfo:nil];}
    return success;
}

@interface ResourceImportBackgroundTaskToken : NSObject
@property(nonatomic) UIBackgroundTaskIdentifier identifier;
@property(nonatomic) BOOL ended;
- (void)endIfNeeded;
@end
@implementation ResourceImportBackgroundTaskToken
- (void)endIfNeeded {UIBackgroundTaskIdentifier identifier;@synchronized(self){if(self.ended||self.identifier==UIBackgroundTaskInvalid)return;self.ended=YES;identifier=self.identifier;}dispatch_block_t end=^{[UIApplication.sharedApplication endBackgroundTask:identifier];};if(NSThread.isMainThread)end();else dispatch_async(dispatch_get_main_queue(),end);}
@end
static NSObject *ResourceImportSnapshotLock(void) {static NSObject *lock;static dispatch_once_t once;dispatch_once(&once,^{lock=[NSObject new];});return lock;}
static void ResourceImportEnqueueSnapshot(NSDictionary *snapshot,ResourceImportBackgroundTaskToken *task,void (^completion)(BOOL)) {
    static NSDictionary *pending;static NSMutableArray<ResourceImportBackgroundTaskToken *> *tasks;static NSMutableArray *completions;static BOOL writing;
    @synchronized(ResourceImportSnapshotLock()){
        pending=snapshot;if(!tasks)tasks=[NSMutableArray array];if(!completions)completions=[NSMutableArray array];if(task)[tasks addObject:task];if(completion)[completions addObject:[completion copy]];if(writing)return;writing=YES;
    }
    dispatch_async(ResourceImportSnapshotQueue(),^{
        for(;;){NSDictionary *latest;NSArray *finishedTasks,*finishedCompletions;
            @synchronized(ResourceImportSnapshotLock()){latest=pending;pending=nil;finishedCompletions=completions.copy;[completions removeAllObjects];if(!latest){writing=NO;finishedTasks=tasks.copy;[tasks removeAllObjects];}}
            if(!latest){if(finishedTasks.count)dispatch_async(dispatch_get_main_queue(),^{for(ResourceImportBackgroundTaskToken *token in finishedTasks)[token endIfNeeded];});break;}
            NSError *error=nil;BOOL success=ResourceImportWriteSnapshot(latest,&error);dispatch_async(dispatch_get_main_queue(),^{for(void (^callback)(BOOL) in finishedCompletions)callback(success);});
        }
    });
}

static NSDictionary *ResourceCatalogDiff(NSArray *oldRows,NSArray *newRows,NSArray<NSString *> *identityFields,NSArray<NSString *> *compareFields) {
    NSMutableDictionary *oldByID=[NSMutableDictionary dictionary],*newByID=[NSMutableDictionary dictionary];NSMutableDictionary *oldCounts=[NSMutableDictionary dictionary],*newCounts=[NSMutableDictionary dictionary];
    for(NSDictionary *row in oldRows){NSString *base=nil;for(NSString *field in identityFields)if([row[field] isKindOfClass:NSString.class]&&[row[field] length]){base=[NSString stringWithFormat:@"%@:%@",field,row[field]];break;}if(!base)base=[NSString stringWithFormat:@"row:%@",row[@"sourceIndex"]?:@(oldByID.count)];NSUInteger n=[oldCounts[base] unsignedIntegerValue];oldCounts[base]=@(n+1);oldByID[[NSString stringWithFormat:@"%@#%lu",base,(unsigned long)n]]=row;}
    for(NSDictionary *row in newRows){NSString *base=nil;for(NSString *field in identityFields)if([row[field] isKindOfClass:NSString.class]&&[row[field] length]){base=[NSString stringWithFormat:@"%@:%@",field,row[field]];break;}if(!base)base=[NSString stringWithFormat:@"row:%@",row[@"sourceIndex"]?:@(newByID.count)];NSUInteger n=[newCounts[base] unsignedIntegerValue];newCounts[base]=@(n+1);newByID[[NSString stringWithFormat:@"%@#%lu",base,(unsigned long)n]]=row;}
    NSUInteger added=0,removed=0,changed=0;for(NSString *key in newByID){NSDictionary *old=oldByID[key],*new=newByID[key];if(!old){added++;continue;}for(NSString *field in compareFields){id a=old[field]?:NSNull.null,b=new[field]?:NSNull.null;if(![a isEqual:b]){changed++;break;}}}for(NSString *key in oldByID)if(!newByID[key])removed++;
    return @{@"added":@(added),@"changed":@(changed),@"removed":@(removed)};
}

// Metadata probing is bounded independently of package downloads.
@interface ResourceImportWorkflowViewController () <UIDocumentPickerDelegate,UITextViewDelegate,UIAdaptivePresentationControllerDelegate>
@property(nonatomic) BOOL restoringSnapshot;
@property(nonatomic) NSUInteger snapshotRevision;
@property(nonatomic) NSUInteger editRevision;
@property(nonatomic,strong) UITextView *address;
@property(nonatomic,strong) UILabel *addressPlaceholder;
@property(nonatomic,strong) UIButton *smartClipboardButton;
@property(nonatomic,copy) NSString *lastAnnouncedStage;
@property(nonatomic,copy) NSString *detectedClipboardPayload;
@property(nonatomic,strong) UIScrollView *quickPresetsScroll;
@property(nonatomic,strong) UIStackView *quickPresetsStack;
@property(nonatomic,strong) UIButton *pasteAddressButton;
@property(nonatomic,strong) UIButton *pasteAndRecognizeButton;
@property(nonatomic,strong) UIButton *clearAddressButton;
@property(nonatomic,strong) UISegmentedControl *runtime;
@property(nonatomic,strong) UISegmentedControl *duplicatePolicy;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *candidates;
@property(nonatomic,strong) ResourceImportFetcher *fetcher;
@property(nonatomic,strong) MediaPackageDownloader *downloader;
@property(nonatomic,readwrite) BOOL busy;
@property(nonatomic,copy) NSString *stage;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL pickingFolder;
@property(nonatomic) BOOL finished;
@property(nonatomic,copy) NSString *taskKind;
@property(nonatomic,copy) NSString *restoredAddress;
@property(nonatomic) NSInteger restoredDuplicatePolicy;
@property(nonatomic) NSInteger restoredRuntimeSelection;
@property(nonatomic) NSInteger selectedImportCategory;
@property(nonatomic) BOOL advancedOptionsExpanded;
@property(nonatomic) NSInteger retryCandidateIndex;
@property(nonatomic) NSTimeInterval lastSnapshotPersistAt;
@property(nonatomic) BOOL persistentSnapshotAvailable;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *batchRetryIndices;
@property(nonatomic) BOOL batchRetrying;
@property(nonatomic) BOOL activateAfterSaveRequested;
- (void)persistSnapshot;
- (void)decorateCandidate:(NSMutableDictionary *)row file:(NSURL *)file origin:(NSString *)origin;
- (void)retryCandidateAtIndex:(NSUInteger)index;
- (void)retrySaveCandidateAtIndex:(NSUInteger)index;
- (NSUInteger)failedCandidateCount;
- (NSUInteger)selectedUnsavedCandidateCount;
- (void)discardUncommittedCandidatesForFreshRecognition;
- (void)retryFailedCandidates;
- (void)advanceBatchRetry;
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation;
- (void)showCategorizedImportOptions;
- (void)applyImportCategory:(ResourceImportOption)option;
- (void)refreshSmartClipboardAndPresets;
- (void)recognizeBatchURLs:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index generation:(NSUInteger)generation hint:(nullable NSString *)hint;
- (void)restoreSnapshot:(NSDictionary *)snapshot;
- (void)writeCurrentSnapshot;
- (NSMutableDictionary *)candidateForData:(NSData *)data file:(NSURL *)file origin:(NSString *)origin companions:(NSDictionary *)companions hint:(NSString *)hint;
-  (void)updateView;
-  (void)textViewDidChange:(UITextView *)textView;
-  (void)recognizeURL;
-  (NSString *)runtimeHint;
-  (void)cancelWork;
-  (void)reset;
- (BOOL)hasUnsavedImportWork;
- (void)presentExitDecisionSheet;
-  (void)pickFiles:(BOOL)folder;
-  (void)chooseExistingResourceForCandidate:(NSMutableDictionary *)row;
-  (void)saveSelected;
-  (void)configureMediaServer:(NSString *)type;
@end

@implementation ResourceImportWorkflowViewController
- (instancetype)init {
    if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){
        self.candidates=[NSMutableArray array];self.batchRetryIndices=[NSMutableArray array];self.stage=@"粘贴地址，或选择本地文件";self.retryCandidateIndex=NSNotFound;self.selectedImportCategory=-1;self.restoringSnapshot=YES;
        __weak typeof(self) weakSelf=self;NSUInteger restoreEditRevision=self.editRevision;BOOL smoke=[NSProcessInfo.processInfo.arguments containsObject:@"--smoke-port"];NSTimeInterval restoreStarted=NSProcessInfo.processInfo.systemUptime;
        if(smoke)NSLog(@"IMPORT_RESTORE_QUEUED controller=%p",self);
        dispatch_async(ResourceImportSnapshotQueue(),^{NSDictionary *snapshot=ResourceImportReadSnapshot();
            if(smoke)NSLog(@"IMPORT_RESTORE_READ controller=%p snapshot=%d elapsed=%.2f",weakSelf,snapshot!=nil,NSProcessInfo.processInfo.systemUptime-restoreStarted);
            dispatch_async(dispatch_get_main_queue(),^{
            ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;
            BOOL untouched=owner.editRevision==restoreEditRevision&&owner.generation==0&&!owner.busy&&!owner.address.text.length&&!owner.candidates.count;
            owner.restoringSnapshot=NO;
            if(smoke)NSLog(@"IMPORT_RESTORE_FINISHED controller=%p snapshot=%d untouched=%d elapsed=%.2f",owner,snapshot!=nil,untouched,NSProcessInfo.processInfo.systemUptime-restoreStarted);
            if(snapshot&&untouched)[owner restoreSnapshot:snapshot];
            else if(owner.editRevision!=restoreEditRevision)[owner persistSnapshot];
        });});
    }return self;
}
- (void)restoreSnapshot:(NSDictionary *)snapshot {
    self.restoringSnapshot=YES;NSArray *rows=[snapshot[@"candidates"] isKindOfClass:NSArray.class]?snapshot[@"candidates"]:@[];for(NSDictionary *row in rows)if([row isKindOfClass:NSDictionary.class])[self.candidates addObject:[row mutableCopy]];self.restoredAddress=[snapshot[@"address"] isKindOfClass:NSString.class]?snapshot[@"address"]:@"";self.taskKind=[snapshot[@"taskKind"] isKindOfClass:NSString.class]?snapshot[@"taskKind"]:@"";self.finished=[snapshot[@"finished"] boolValue];NSInteger dup=[snapshot[@"duplicatePolicy"] respondsToSelector:@selector(integerValue)]?[snapshot[@"duplicatePolicy"] integerValue]:0;NSInteger rt=[snapshot[@"runtimeSelection"] respondsToSelector:@selector(integerValue)]?[snapshot[@"runtimeSelection"] integerValue]:0;self.restoredDuplicatePolicy=MAX((NSInteger)0,MIN((NSInteger)1,dup));self.restoredRuntimeSelection=MAX((NSInteger)0,MIN((NSInteger)2,rt));self.selectedImportCategory=[snapshot[@"importCategory"] respondsToSelector:@selector(integerValue)]?[snapshot[@"importCategory"] integerValue]:-1;if([snapshot[@"busy"] boolValue])self.stage=[self.taskKind isEqual:@"save"]?@"上次保存中断 · 可重试未保存项目":([self.taskKind isEqual:@"url"]?@"上次链接识别中断 · 点按识别链接重试":@"上次本地识别中断 · 重新选择文件，或重试单项");else self.stage=[snapshot[@"stage"] isKindOfClass:NSString.class]?snapshot[@"stage"]:@"已恢复上次导入任务";
    if(self.isViewLoaded){self.address.text=self.restoredAddress;self.addressPlaceholder.hidden=self.address.text.length>0;if(self.runtime.numberOfSegments>0)self.runtime.selectedSegmentIndex=MIN(self.restoredRuntimeSelection,(NSInteger)self.runtime.numberOfSegments-1);if(self.duplicatePolicy.numberOfSegments>0)self.duplicatePolicy.selectedSegmentIndex=MIN(self.restoredDuplicatePolicy,(NSInteger)self.duplicatePolicy.numberOfSegments-1);[self updateView];}self.restoringSnapshot=NO;[self persistSnapshot];
}

- (NSString *)taskSummary {if(!self.candidates.count&&!self.restoredAddress.length&&([self.stage isEqual:@"粘贴地址，或选择本地文件"]||!self.stage.length))return nil;return self.stage?:@"添加资源";}

- (NSArray<NSDictionary *> *)quickPresetDefinitions {
    NSMutableArray<NSDictionary *> *items=[NSMutableArray arrayWithArray:@[
        @{@"title":@"🦋 蝴蝶影视",@"url":@"https://sub.lytvs.top/hamo/tk_95f9cbf6.hawk"},
        @{@"title":@"🎭 短剧专区",@"url":@"https://sub.lytvs.top/hamo/duanju_tk_95f9cbf6.hawk"},
        @{@"title":@"🍉 吃瓜专区",@"url":@"https://sub.lytvs.top/hamo/chigua_tk_95f9cbf6.hawk"},
        @{@"title":@"🌸 初忆合集",@"url":@"https://gitee.com/cycod/tvbox/raw/master/api.json"},
        @{@"title":@"🏮 刺桐影视",@"url":@"https://www.cttv.vip/app/json/ctys.json"},
        @{@"title":@"⚡ WeBox 合集",@"url":@"https://ddgksf2013.top/webox/index.json"},
        @{@"title":@"🎬 4K影视",@"url":@"https://ddgksf2013.top/webox/js/4k%E5%BD%B1%E8%A7%86.webox.js"},
        @{@"title":@"📺 瓜子影视",@"url":@"https://ddgksf2013.top/webox/js/%E7%93%9C%E5%AD%90.webox.js"},
        @{@"title":@"🎞️ HStream",@"url":@"https://ddgksf2013.top/webox/js/HStream.webox.js"},
        @{@"title":@"📖 ONE一个",@"url":@"https://ddgksf2013.top/webox/js/one%E4%B8%80%E4%B8%AA.webox.js"}
    ]];
    NSArray *recents=[NSUserDefaults.standardUserDefaults arrayForKey:ResourceImportRecentURLsPreferenceKey];
    if([recents isKindOfClass:NSArray.class]){
        for(id raw in recents){
            if(![raw isKindOfClass:NSString.class])continue;
            NSURL *u=ResourceImportNormalizedURL(raw);
            if(!u)continue;
            BOOL duplicate=NO;
            for(NSDictionary *existing in items){
                if([existing[@"url"] isEqualToString:u.absoluteString]){duplicate=YES;break;}
            }
            if(duplicate)continue;
            NSString *last=(u.lastPathComponent.stringByRemovingPercentEncoding?:u.lastPathComponent);
            NSString *label=last.length>1&&![last isEqualToString:@"/"]?last:(u.host?:@"历史链接");
            [items addObject:@{@"title":[NSString stringWithFormat:@"🕒 %@",label],@"url":u.absoluteString}];
        }
    }
    return items.copy;
}

- (void)rebuildQuickPresetsBar {
    if(!self.quickPresetsStack)return;
    for(UIView *sub in self.quickPresetsStack.arrangedSubviews.copy){
        [self.quickPresetsStack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }
    NSArray<NSDictionary *> *presets=[self quickPresetDefinitions];
    for(NSUInteger idx=0;idx<presets.count;idx++){
        NSDictionary *preset=presets[idx];
        UIButton *pill=[UIButton buttonWithType:UIButtonTypeSystem];
        pill.tag=(NSInteger)idx;
        [pill setTitle:preset[@"title"] forState:UIControlStateNormal];
        pill.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold]];
        pill.titleLabel.adjustsFontForContentSizeCategory=YES;
        pill.tintColor=HostText();
        [pill setTitleColor:HostText() forState:UIControlStateNormal];
        pill.backgroundColor=HostCard();
        pill.layer.cornerRadius=11;
        pill.layer.cornerCurve=kCACornerCurveContinuous;
        pill.layer.borderWidth=0.6;
        HostSetLayerBorderColor(pill,HostBorder());
        pill.contentEdgeInsets=UIEdgeInsetsMake(4,10,4,10);
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
        HostInstallPressFeedback(pill);
        [pill addTarget:self action:@selector(quickPresetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.quickPresetsStack addArrangedSubview:pill];
    }
}

- (void)quickPresetTapped:(UIButton *)sender {
    if(self.busy)return;
    NSArray<NSDictionary *> *presets=[self quickPresetDefinitions];
    if(sender.tag<0||(NSUInteger)sender.tag>=presets.count)return;
    NSString *url=presets[(NSUInteger)sender.tag][@"url"];
    if(!url.length)return;
    self.address.text=url;
    [self textViewDidChange:self.address];
    [self recognizeURL];
}

- (void)refreshSmartClipboardAndPresets {
    [self rebuildQuickPresetsBar];
    if(!self.smartClipboardButton)return;
    self.detectedClipboardPayload=nil;
    [self.smartClipboardButton setTitle:@"粘贴并识别资源" forState:UIControlStateNormal];
    self.smartClipboardButton.hidden=YES;
}

- (void)applySmartClipboardAndRecognize {
    if(self.busy)return;
    NSString *payload=self.detectedClipboardPayload?:[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!payload.length)return;
    self.address.text=payload;
    self.detectedClipboardPayload=nil;
    self.smartClipboardButton.hidden=YES;
    [self textViewDidChange:self.address];
    [self recognizeURL];
}

- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=@"添加资源";UISheetPresentationController *sheet=self.navigationController.sheetPresentationController?:self.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=26;sheet.prefersEdgeAttachedInCompactHeight=YES;}self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentAutomatic;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"收起" style:UIBarButtonItemStylePlain target:self action:@selector(minimize)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(saveSelected)];
    self.smartClipboardButton=[UIButton buttonWithType:UIButtonTypeSystem];
    self.smartClipboardButton.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    self.smartClipboardButton.titleLabel.adjustsFontForContentSizeCategory=YES;
    self.smartClipboardButton.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    self.smartClipboardButton.tintColor=HostAccent();
    [self.smartClipboardButton setTitleColor:HostAccent() forState:UIControlStateNormal];
    self.smartClipboardButton.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];
    self.smartClipboardButton.layer.cornerRadius=10;
    self.smartClipboardButton.layer.cornerCurve=kCACornerCurveContinuous;
    self.smartClipboardButton.layer.borderWidth=0.6;
    HostSetLayerBorderColor(self.smartClipboardButton,[HostAccent() colorWithAlphaComponent:0.35]);
    self.smartClipboardButton.contentEdgeInsets=UIEdgeInsetsMake(6,10,6,10);
    self.smartClipboardButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    self.smartClipboardButton.accessibilityIdentifier=@"resource-import-smart-clipboard";
    self.smartClipboardButton.hidden=YES;
    HostInstallPressFeedback(self.smartClipboardButton);
    [self.smartClipboardButton addTarget:self action:@selector(applySmartClipboardAndRecognize) forControlEvents:UIControlEventTouchUpInside];

    self.quickPresetsScroll=[UIScrollView new];
    self.quickPresetsScroll.showsHorizontalScrollIndicator=NO;
    self.quickPresetsScroll.accessibilityIdentifier=@"resource-import-presets-scroll";
    self.quickPresetsStack=[UIStackView new];
    self.quickPresetsStack.axis=UILayoutConstraintAxisHorizontal;
    self.quickPresetsStack.spacing=6;
    self.quickPresetsStack.alignment=UIStackViewAlignmentCenter;
    self.quickPresetsStack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.quickPresetsScroll addSubview:self.quickPresetsStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.quickPresetsStack.leadingAnchor constraintEqualToAnchor:self.quickPresetsScroll.contentLayoutGuide.leadingAnchor],
        [self.quickPresetsStack.trailingAnchor constraintEqualToAnchor:self.quickPresetsScroll.contentLayoutGuide.trailingAnchor],
        [self.quickPresetsStack.topAnchor constraintEqualToAnchor:self.quickPresetsScroll.contentLayoutGuide.topAnchor],
        [self.quickPresetsStack.bottomAnchor constraintEqualToAnchor:self.quickPresetsScroll.contentLayoutGuide.bottomAnchor],
        [self.quickPresetsStack.heightAnchor constraintEqualToAnchor:self.quickPresetsScroll.frameLayoutGuide.heightAnchor],
        [self.quickPresetsScroll.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];

    self.address=[UITextView new];self.address.delegate=self;self.address.text=self.restoredAddress?:@"";self.address.backgroundColor=HostRaisedSurface();self.address.textColor=HostText();self.address.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.address.adjustsFontForContentSizeCategory=YES;self.address.autocapitalizationType=UITextAutocapitalizationTypeNone;self.address.autocorrectionType=UITextAutocorrectionTypeNo;self.address.smartQuotesType=UITextSmartQuotesTypeNo;self.address.smartDashesType=UITextSmartDashesTypeNo;self.address.smartInsertDeleteType=UITextSmartInsertDeleteTypeNo;self.address.keyboardType=UIKeyboardTypeURL;self.address.layer.cornerRadius=14;self.address.textContainerInset=UIEdgeInsetsMake(10,6,10,6);self.address.accessibilityLabel=@"资源链接";self.address.accessibilityHint=@"影视、直播或资源合集链接";self.address.accessibilityIdentifier=@"resource-import-url";
    self.addressPlaceholder=[UILabel new];self.addressPlaceholder.text=@"粘贴单条或多条影视/WeBox/TVBox/直播链接，或直接粘贴源码";self.addressPlaceholder.font=self.address.font;self.addressPlaceholder.textColor=HostSecondaryText();self.addressPlaceholder.numberOfLines=0;self.addressPlaceholder.lineBreakMode=NSLineBreakByWordWrapping;self.addressPlaceholder.userInteractionEnabled=NO;self.addressPlaceholder.translatesAutoresizingMaskIntoConstraints=NO;[self.address addSubview:self.addressPlaceholder];[NSLayoutConstraint activateConstraints:@[[self.addressPlaceholder.leadingAnchor constraintEqualToAnchor:self.address.frameLayoutGuide.leadingAnchor constant:10],[self.addressPlaceholder.trailingAnchor constraintEqualToAnchor:self.address.frameLayoutGuide.trailingAnchor constant:-10],[self.addressPlaceholder.topAnchor constraintEqualToAnchor:self.address.topAnchor constant:10]]];self.addressPlaceholder.hidden=self.address.text.length>0;
    self.address.layer.cornerCurve=kCACornerCurveContinuous;self.address.layer.borderWidth=0.65;HostSetLayerBorderColor(self.address,HostBorder());
    self.pasteAddressButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.pasteAddressButton setTitle:@"粘贴剪贴板" forState:UIControlStateNormal];self.pasteAddressButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.pasteAddressButton.tintColor=HostAccent();self.pasteAddressButton.backgroundColor=HostSelectedSurface();self.pasteAddressButton.layer.cornerRadius=10;self.pasteAddressButton.layer.cornerCurve=kCACornerCurveContinuous;self.pasteAddressButton.contentEdgeInsets=UIEdgeInsetsMake(4,10,4,10);HostInstallPressFeedback(self.pasteAddressButton);self.pasteAddressButton.accessibilityIdentifier=@"resource-import-paste";[self.pasteAddressButton addTarget:self action:@selector(pasteClipboardAddress) forControlEvents:UIControlEventTouchUpInside];
    self.pasteAndRecognizeButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.pasteAndRecognizeButton setTitle:@"粘贴并识别" forState:UIControlStateNormal];self.pasteAndRecognizeButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.pasteAndRecognizeButton.tintColor=UIColor.whiteColor;self.pasteAndRecognizeButton.backgroundColor=HostAccent();self.pasteAndRecognizeButton.layer.cornerRadius=10;self.pasteAndRecognizeButton.layer.cornerCurve=kCACornerCurveContinuous;self.pasteAndRecognizeButton.contentEdgeInsets=UIEdgeInsetsMake(4,10,4,10);HostInstallPressFeedback(self.pasteAndRecognizeButton);self.pasteAndRecognizeButton.accessibilityIdentifier=@"resource-import-paste-recognize";[self.pasteAndRecognizeButton addTarget:self action:@selector(pasteAndRecognizeAddress) forControlEvents:UIControlEventTouchUpInside];
    self.clearAddressButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.clearAddressButton setTitle:@"清空" forState:UIControlStateNormal];self.clearAddressButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.clearAddressButton.tintColor=HostSecondaryText();self.clearAddressButton.backgroundColor=HostNeutralSurface();self.clearAddressButton.layer.cornerRadius=10;self.clearAddressButton.layer.cornerCurve=kCACornerCurveContinuous;self.clearAddressButton.contentEdgeInsets=UIEdgeInsetsMake(4,10,4,10);HostInstallPressFeedback(self.clearAddressButton);self.clearAddressButton.accessibilityIdentifier=@"resource-import-clear";[self.clearAddressButton addTarget:self action:@selector(clearAddressText) forControlEvents:UIControlEventTouchUpInside];
    for(UIButton *button in @[self.pasteAddressButton,self.pasteAndRecognizeButton,self.clearAddressButton,self.smartClipboardButton]){
        button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
        button.titleLabel.adjustsFontForContentSizeCategory=YES;
        button.titleLabel.numberOfLines=0;
        button.titleLabel.textAlignment=NSTextAlignmentCenter;
        NSLayoutConstraint *minimumHeight=[button.heightAnchor constraintGreaterThanOrEqualToConstant:44];
        minimumHeight.priority=UILayoutPriorityDefaultHigh;
        minimumHeight.active=YES;
    }
    self.runtime=[[UISegmentedControl alloc] initWithItems:@[@"自动识别",@"Python",@"Node.js"]];self.runtime.selectedSegmentIndex=MIN(2,MAX(0,self.restoredRuntimeSelection));self.runtime.selectedSegmentTintColor=HostAccent();[self.runtime addTarget:self action:@selector(runtimeChanged:) forControlEvents:UIControlEventValueChanged];
    self.duplicatePolicy=[[UISegmentedControl alloc] initWithItems:@[@"更新已有",@"保存副本"]];self.duplicatePolicy.selectedSegmentIndex=MIN(1,MAX(0,self.restoredDuplicatePolicy));self.duplicatePolicy.selectedSegmentTintColor=HostAccent();
    [self.duplicatePolicy addTarget:self action:@selector(duplicatePolicyChanged:) forControlEvents:UIControlEventValueChanged];
    [self refreshSmartClipboardAndPresets];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];[self updateView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSmartClipboardAndPresets];
    [self.tableView reloadData];
}

- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.address.backgroundColor=HostRaisedSurface();
    self.address.textColor=HostText();
    HostSetLayerBorderColor(self.address,HostBorder());
    self.addressPlaceholder.textColor=HostSecondaryText();
    self.smartClipboardButton.tintColor=HostAccent();
    [self.smartClipboardButton setTitleColor:HostAccent() forState:UIControlStateNormal];
    self.smartClipboardButton.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];
    HostSetLayerBorderColor(self.smartClipboardButton,[HostAccent() colorWithAlphaComponent:0.35]);
    self.pasteAddressButton.tintColor=HostAccent();
    self.pasteAddressButton.backgroundColor=HostSelectedSurface();
    self.pasteAndRecognizeButton.backgroundColor=HostAccent();
    self.clearAddressButton.tintColor=HostSecondaryText();
    self.clearAddressButton.backgroundColor=HostNeutralSurface();
    self.runtime.selectedSegmentTintColor=HostAccent();
    self.duplicatePolicy.selectedSegmentTintColor=HostAccent();
    [self rebuildQuickPresetsBar];
    HostRefreshAppearanceLayers(self.view);
    [self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])[self reloadThemeAppearance];
    if(previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory] && self.isViewLoaded){
        self.addressPlaceholder.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        [self rebuildQuickPresetsBar];
        [self.tableView reloadData];
    }
}

- (void)discardUncommittedCandidatesForFreshRecognition {
    if(!self.candidates.count)return;
    for(NSDictionary *row in self.candidates){
        if(row[@"service"]&&![row[@"saved"] boolValue])[ServiceStore remove:row[@"service"][@"id"]];
    }
    [self.candidates removeAllObjects];
    self.finished=NO;
}
- (void)pasteClipboardAddress {
    if(self.busy)return;
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clip.length)return;
    self.address.text=clip;
    [self textViewDidChange:self.address];
}
- (void)pasteAndRecognizeAddress {
    if(self.busy)return;
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(clip.length){
        self.address.text=clip;
        [self textViewDidChange:self.address];
    }
    if(self.address.text.length)[self recognizeURL];
}
- (void)clearAddressText {
    if(self.busy)return;
    self.address.text=@"";
    if(self.candidates.count&&[self selectedUnsavedCandidateCount]==0){
        [self discardUncommittedCandidatesForFreshRecognition];
        self.stage=@"粘贴地址，或选择本地文件";
    }
    [self textViewDidChange:self.address];
    [self updateView];
}
- (void)toggleSelectAllCandidates {
    if(self.busy||!self.candidates.count)return;
    self.editRevision++;
    BOOL anyUnselected=NO;
    for(NSDictionary *row in self.candidates){
        if(![row[@"kind"] isEqual:@"page"]&&![row[@"unsupportedOnly"] boolValue]&&!row[@"error"]&&!row[@"saveError"]&&![row[@"saved"] boolValue]&&![row[@"selected"] boolValue]){anyUnselected=YES;break;}
    }
    for(NSMutableDictionary *row in self.candidates){
        if(![row[@"kind"] isEqual:@"page"]&&![row[@"unsupportedOnly"] boolValue]&&!row[@"error"]&&!row[@"saveError"]&&![row[@"saved"] boolValue])row[@"selected"]=@(anyUnselected);
    }
    self.finished=NO;
    [self updateView];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.fetcher cancel];[self.downloader cancel];}
- (NSUInteger)selectedUnsavedCandidateCount {
    NSUInteger count=0;
    for(NSDictionary *row in self.candidates){
        if(![row[@"kind"] isEqual:@"page"]&&![row[@"unsupportedOnly"] boolValue]&&[row[@"selected"] boolValue]&&!row[@"error"]&&!row[@"saveError"]&&![row[@"saved"] boolValue])count++;
    }
    return count;
}
- (void)applyModalDismissProtection {
    // 防误关闭（Phase-C UI 审计 §6/§9）：导入进行中时禁止手势/外部 dismiss，
    // 对齐 MediaWebViewController。full-screen 演示下为兜底保险；一旦以 sheet
    // 呈现即阻止下拉关闭，进度不被误中断。显式取消仍走 cancelWork，语义不变。
    BOOL modal=(self.busy&&!self.finished)||[self hasUnsavedImportWork];
    self.modalInPresentation=modal;
    if(self.navigationController){self.navigationController.modalInPresentation=modal;self.navigationController.presentationController.delegate=self;}
}
- (void)updateView {
    for(NSMutableDictionary *row in self.candidates)if([row[@"needsDecoration"] boolValue])[self decorateCandidate:row file:nil origin:row[@"origin"]];
    NSUInteger readyCount=[self selectedUnsavedCandidateCount];
    self.navigationItem.rightBarButtonItem.enabled=!self.busy&&!self.finished&&readyCount>0;
    self.navigationItem.leftBarButtonItem.enabled=!self.busy;
    self.navigationItem.rightBarButtonItem.title=readyCount>1?[NSString stringWithFormat:@"保存(%lu)",(unsigned long)readyCount]:@"保存";
    [self applyModalDismissProtection];
    self.address.editable=!self.busy;self.pasteAddressButton.enabled=!self.busy;self.pasteAndRecognizeButton.enabled=!self.busy;self.clearAddressButton.enabled=!self.busy;self.clearAddressButton.hidden=self.address.text.length==0&&self.candidates.count==0;self.runtime.enabled=!self.busy;self.duplicatePolicy.enabled=!self.busy;[self refreshSmartClipboardAndPresets];[self.tableView reloadData];
    if(self.viewIfLoaded.window && self.stage.length && ![self.stage isEqualToString:self.lastAnnouncedStage]){
        self.lastAnnouncedStage=self.stage;
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.stage);
    }
    [self persistSnapshot];if(self.onStateChanged)self.onStateChanged();
}
- (void)persistSnapshot {
    if(self.restoringSnapshot)return;
    NSUInteger revision=++self.snapshotRevision;
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){[self writeCurrentSnapshot];return;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(owner&&owner.snapshotRevision==revision)[owner writeCurrentSnapshot];});
}
- (void)writeCurrentSnapshot {
    NSString *address=self.address.text?:self.restoredAddress?:@"";BOOL blank=!self.busy&&!self.candidates.count&&!address.length&&[self.stage isEqual:@"粘贴地址，或选择本地文件"];
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];if(!blank){snapshot[@"version"]=@2;snapshot[@"candidates"]=ResourceImportFrozenPropertyList(ResourceImportSnapshotCandidates(self.candidates))?:@[];snapshot[@"address"]=address;snapshot[@"taskKind"]=self.taskKind?:@"";snapshot[@"stage"]=self.stage?:@"添加资源";snapshot[@"busy"]=@(self.busy);snapshot[@"finished"]=@(self.finished);snapshot[@"duplicatePolicy"]=@(self.duplicatePolicy?self.duplicatePolicy.selectedSegmentIndex:self.restoredDuplicatePolicy);snapshot[@"runtimeSelection"]=@(self.runtime?self.runtime.selectedSegmentIndex:self.restoredRuntimeSelection);snapshot[@"importCategory"]=@(self.selectedImportCategory);}
    NSDictionary *immutable=snapshot.copy;NSUInteger revision=self.snapshotRevision;ResourceImportBackgroundTaskToken *task=nil;if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){task=[ResourceImportBackgroundTaskToken new];__block ResourceImportBackgroundTaskToken *taskToken=task;task.identifier=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"cctv.resourceImport.snapshot" expirationHandler:^{[taskToken endIfNeeded];}];}__weak typeof(self) weakSelf=self;ResourceImportEnqueueSnapshot(immutable,task,^(BOOL success){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.snapshotRevision!=revision)return;owner.persistentSnapshotAvailable=success&&!blank;if(!success){[RuntimeDiagnostics.shared recordEvent:@"resource_import_snapshot_write_failed" category:@"resource_import" fields:@{@"revision":@(revision)}];}});
}
- (void)applicationDidEnterBackground:(NSNotification *)notification {[self persistSnapshot];}
- (void)textViewDidChange:(UITextView *)textView {
    if(textView.markedTextRange!=nil)return;
    self.editRevision++;
    self.restoredAddress=textView.text?:@"";
    self.addressPlaceholder.hidden=textView.text.length>0;
    self.clearAddressButton.hidden=textView.text.length==0&&self.candidates.count==0;
    if(self.detectedClipboardPayload.length){
        NSString *trimmed=[self.restoredAddress stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([trimmed isEqualToString:self.detectedClipboardPayload]){self.detectedClipboardPayload=nil;self.smartClipboardButton.hidden=YES;}
    }
    [self persistSnapshot];
}
- (void)runtimeChanged:(UISegmentedControl *)sender {self.editRevision++;self.restoredRuntimeSelection=sender.selectedSegmentIndex;[self persistSnapshot];}
- (void)duplicatePolicyChanged:(UISegmentedControl *)sender {self.editRevision++;self.finished=NO;[self updateView];}
- (BOOL)hasUnsavedImportWork {
    if(self.finished)return NO;
    if(self.candidates.count>0)return YES;
    return self.address.text.length>0;
}
- (void)presentExitDecisionSheet {
    NSUInteger unsaved=[self selectedUnsavedCandidateCount];
    NSUInteger failed=[self failedCandidateCount];
    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    if(unsaved>0)[parts addObject:[NSString stringWithFormat:@"已选 %lu 项未保存",(unsigned long)unsaved]];
    if(failed>0)[parts addObject:[NSString stringWithFormat:@"%lu 项失败",(unsigned long)failed]];
    if(!parts.count&&self.candidates.count>0)[parts addObject:[NSString stringWithFormat:@"%lu 个候选尚未保存",(unsigned long)self.candidates.count]];
    if(!parts.count&&self.address.text.length>0)[parts addObject:@"地址栏有未识别的内容"];
    NSString *subtitle=[[parts componentsJoinedByString:@"，"] stringByAppendingString:@"。保留任务可在资源主页摘要中继续；放弃将删除未保存的候选，不影响已保存的项目。"];
    __weak typeof(self) weakSelf=self;
    HostGlassSheetAction *keep=[HostGlassSheetAction actionWithTitle:@"保留任务，稍后继续" subtitle:@"候选、选择与失败原因已存快照，重新进入可恢复" value:nil icon:@"clock.arrow.circlepath" tint:HostAccent() destructive:NO selected:NO handler:^{ResourceImportWorkflowViewController *owner=weakSelf;if(owner)[owner.navigationController dismissViewControllerAnimated:YES completion:nil];}];
    HostGlassSheetAction *abandon=[HostGlassSheetAction actionWithTitle:@"放弃未保存并关闭" subtitle:@"删除未保存的候选与本次新建的未保存服务" value:nil icon:@"trash" tint:UIColor.systemRedColor destructive:YES selected:NO handler:^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;[owner reset];[owner.navigationController dismissViewControllerAnimated:YES completion:nil];}];
    HostGlassSheetAction *stay=[HostGlassSheetAction actionWithTitle:@"取消" subtitle:nil value:nil icon:nil tint:nil destructive:NO selected:NO handler:nil];
    [HostGlassActionSheetViewController presentOn:self title:@"退出导入？" subtitle:subtitle badgeText:nil badgeColor:nil sections:@[[HostGlassSheetSection sectionWithTitle:nil actions:@[keep,abandon,stay]]] sourceView:self.view];
}
- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)presentationController {if(self.busy)return;[self presentExitDecisionSheet];}
- (void)minimize {
    [self.view endEditing:YES];
    if(self.busy)return;
    if(![self hasUnsavedImportWork]){[self.navigationController dismissViewControllerAnimated:YES completion:nil];return;}
    [self presentExitDecisionSheet];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(section==0)return self.advancedOptionsExpanded?7:5;
    if(section==1)return 1+self.candidates.count;
    NSUInteger failed=[self failedCandidateCount];
    NSUInteger ready=[self selectedUnsavedCandidateCount];
    return 1+(failed>0?1:0)+(ready>0?2:0);
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)ip { if(ip.section==0&&ip.row==0)return; UITableViewCell *c=[tableView cellForRowAtIndexPath:ip]; if(!c||UIAccessibilityIsReduceMotionEnabled())return; [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformMakeScale(0.982,0.982);} completion:nil]; }
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)ip { UITableViewCell *c=[tableView cellForRowAtIndexPath:ip]; if(!c)return; [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformIdentity;} completion:nil]; }
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.section!=1||ip.row<=0||ip.row-1>=(NSInteger)self.candidates.count)return nil;
    NSUInteger index=(NSUInteger)(ip.row-1);
    NSMutableDictionary *row=self.candidates[index];
    NSString *name=row[@"name"]?:@"资源";
    NSString *summary=row[@"saveError"]?:row[@"error"]?:row[@"summary"]?:@"";
    __weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        NSMutableArray<UIMenuElement *> *actions=[NSMutableArray array];
        BOOL selectable=!row[@"saved"]&&!row[@"error"]&&!row[@"saveError"]&&![row[@"kind"] isEqual:@"page"]&&![row[@"unsupportedOnly"] boolValue];
        if(selectable){
            BOOL sel=[row[@"selected"] boolValue];
            [actions addObject:[UIAction actionWithTitle:sel?@"取消勾选此项":@"勾选此项" image:[UIImage systemImageNamed:sel?@"circle":@"checkmark.circle.fill"] identifier:nil handler:^(__unused UIAction *a){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.busy)return;owner.editRevision++;row[@"selected"]=@(!sel);owner.finished=NO;[owner updateView];}]];
        }
        if(!row[@"saved"]&&!row[@"error"]){
            [actions addObject:[UIAction actionWithTitle:@"重命名此资源" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(__unused UIAction *a){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.busy)return;[owner promptRenameCandidateAtIndex:index];}]];
        }
        if(row[@"error"]||row[@"saveError"]){
            [actions addObject:[UIAction actionWithTitle:@"重试此项" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(__unused UIAction *a){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.busy)return;[owner retryCandidateAtIndex:index];}]];
        }
        [actions addObject:[UIAction actionWithTitle:@"复制名称与识别摘要" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=summary.length?[NSString stringWithFormat:@"%@ · %@",name,summary]:name;}]];
        if(!weakSelf.busy){
            UIAction *remove=[UIAction actionWithTitle:@"从预览列表移除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *a){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.busy||index>=owner.candidates.count)return;NSDictionary *r=owner.candidates[index];if(r[@"service"]&&![r[@"saved"] boolValue])[ServiceStore remove:r[@"service"][@"id"]];[owner.candidates removeObjectAtIndex:index];[owner updateView];}];
            remove.attributes=UIMenuElementAttributesDestructive;
            [actions addObject:remove];
        }
        return [UIMenu menuWithTitle:name children:actions];
    }];
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"选择导入方式",self.stage?:@"识别预览",@"任务操作"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return @"支持单条或多条 TVBox / WeBox JSON、直播列表、PY / JS / .webox.js 和 ZIP 批量识别，也支持直接粘贴源码文本。默认自动识别；识别阶段不会执行脚本。";
    if(section==1)return @"合集仅保存一份索引，内部站点按需加载；含子脚本的 WeBox 合集可展开独立挑选。点按右侧按钮可在保存前改名。";
    return @"失败项可逐条重试，或只重试失败项；支持「保存并立即启用」一键激活并收起面板。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {return UITableViewAutomaticDimension;}

- (NSString *)protocolBadgePrefixForCandidate:(NSDictionary *)row {
    if(row[@"error"]||row[@"saveError"])return @"[识别异常]";
    NSString *kind=row[@"kind"]?:@"";
    if([kind isEqual:@"catalog"]){
        NSDictionary *cat=row[@"catalog"]?:@{};
        if([cat[@"catalogKind"] isEqual:@"tvbox-local-bundle"])return @"[TVBox 本地包]";
        if([cat[@"catalogKind"] isEqual:@"webox"]||[row[@"weboxScripts"] count]>0)return @"[WeBox 合集]";
        return @"[TVBox 合集]";
    }
    if([kind isEqual:@"page"])return @"[资源网页]";
    if([kind isEqual:@"playlist"])return @"[M3U 直播源]";
    if([kind isEqual:@"service"]){
        NSDictionary *svc=row[@"service"]?:@{};
        NSString *proto=[svc[@"protocol"] description]?:@"";
        NSString *engine=[svc[@"engine"] description]?:@"";
        if([proto containsString:@"webox"])return @"[WeBox 脚本]";
        if([engine isEqual:@"python"])return @"[Python 脚本]";
        if([engine isEqual:@"node"])return @"[Node 脚本]";
        return @"[JS 脚本]";
    }
    return @"[资源]";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    BOOL isCandidateRow=(ip.section==1&&ip.row>0);
    UITableViewCell *cell=isCandidateRow?[tableView dequeueReusableCellWithIdentifier:@"resource.import.candidate"]:nil;
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:isCandidateRow?@"resource.import.candidate":nil];
    cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryNone;cell.imageView.image=nil;cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    UIView *control=nil;
    if(ip.section==0){
        if(ip.row==0){
            for(UIView *sharedView in @[self.address,self.pasteAndRecognizeButton,self.pasteAddressButton,self.clearAddressButton,self.smartClipboardButton,self.quickPresetsScroll]){
                if([sharedView.superview isKindOfClass:UIStackView.class])[(UIStackView *)sharedView.superview removeArrangedSubview:sharedView];
                [sharedView removeFromSuperview];
            }
            UIView *editorBox=[UIView new];
            editorBox.translatesAutoresizingMaskIntoConstraints=NO;
            [editorBox addSubview:self.address];
            self.address.translatesAutoresizingMaskIntoConstraints=NO;
            [NSLayoutConstraint activateConstraints:@[
                [self.address.topAnchor constraintEqualToAnchor:editorBox.topAnchor],
                [self.address.bottomAnchor constraintEqualToAnchor:editorBox.bottomAnchor],
                [self.address.leadingAnchor constraintEqualToAnchor:editorBox.leadingAnchor],
                [self.address.trailingAnchor constraintEqualToAnchor:editorBox.trailingAnchor],
                [editorBox.heightAnchor constraintGreaterThanOrEqualToConstant:MAX(112,self.address.font.lineHeight*3+20)]
            ]];
            NSArray<UIButton *> *actionButtons=@[self.clearAddressButton,self.pasteAddressButton,self.pasteAndRecognizeButton];
            CGFloat requiredWidth=12;
            for(UIButton *button in actionButtons)if(!button.hidden)requiredWidth+=button.intrinsicContentSize.width;
            CGFloat availableWidth=CGRectGetWidth(tableView.bounds)>0?CGRectGetWidth(tableView.bounds)-48:342;
            BOOL vertical=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)||requiredWidth>availableWidth;
            UIStackView *actions=[[UIStackView alloc] initWithArrangedSubviews:actionButtons];
            actions.axis=vertical?UILayoutConstraintAxisVertical:UILayoutConstraintAxisHorizontal;
            actions.distribution=UIStackViewDistributionFillEqually;
            actions.spacing=6;
            actions.accessibilityIdentifier=@"resource-import-address-actions";
            NSMutableArray<UIView *> *podViews=[NSMutableArray array];
            if(self.smartClipboardButton&&!self.smartClipboardButton.hidden)[podViews addObject:self.smartClipboardButton];
            [podViews addObject:editorBox];
            [podViews addObject:actions];
            if(self.quickPresetsScroll)[podViews addObject:self.quickPresetsScroll];
            UIStackView *podStack=[[UIStackView alloc] initWithArrangedSubviews:podViews];
            podStack.axis=UILayoutConstraintAxisVertical;
            podStack.spacing=6;
            control=podStack;cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }
        else if(ip.row==1){cell.textLabel.text=[self.taskKind isEqual:@"url"]&&self.restoredAddress.length?@"识别链接 / 文本内容 · 可重试上次地址":@"识别链接 / 文本内容";cell.textLabel.textColor=HostAccent();cell.imageView.image=[UIImage systemImageNamed:@"link.badge.plus"];cell.imageView.tintColor=HostAccent();}
        else if(ip.row==2){cell.textLabel.text=@"选择文件（多选）";cell.textLabel.textColor=HostAccent();cell.imageView.image=[UIImage systemImageNamed:@"doc.badge.plus"];cell.imageView.tintColor=HostAccent();}
        else if(ip.row==3){cell.textLabel.text=@"选择文件夹";cell.textLabel.textColor=HostAccent();cell.imageView.image=[UIImage systemImageNamed:@"folder.badge.plus"];cell.imageView.tintColor=HostAccent();}
        else if(ip.row==4){cell.textLabel.text=self.advancedOptionsExpanded?@"收起高级选项":@"高级选项";cell.detailTextLabel.text=@"指定运行环境 · 分类导入入口";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.textLabel.textColor=HostAccent();cell.imageView.image=[UIImage systemImageNamed:@"slider.horizontal.3"];cell.imageView.tintColor=HostAccent();}
        else if(ip.row==5){if([self.runtime.superview isKindOfClass:UIStackView.class])[(UIStackView *)self.runtime.superview removeArrangedSubview:self.runtime];[self.runtime removeFromSuperview];UILabel *label=[UILabel new];label.text=@"运行环境";label.textColor=HostText();label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,self.runtime]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;control=stack;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
        else {cell.textLabel.text=@"按类型选择导入方式";cell.detailTextLabel.text=@"TVBox、直播、Python、JS、ZIP 与文件夹";cell.textLabel.textColor=HostAccent();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.imageView.image=[UIImage systemImageNamed:@"square.grid.2x2"];cell.imageView.tintColor=HostAccent();}
    }
    else if(ip.section==1){if(ip.row==0){
        if([self.duplicatePolicy.superview isKindOfClass:UIStackView.class])[(UIStackView *)self.duplicatePolicy.superview removeArrangedSubview:self.duplicatePolicy];
        [self.duplicatePolicy removeFromSuperview];
        if(self.candidates.count>1){
            UIButton *toggleAll=[UIButton buttonWithType:UIButtonTypeSystem];
            [toggleAll setTitle:@"全选 / 反选" forState:UIControlStateNormal];
            toggleAll.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            toggleAll.tintColor=HostAccent();
            [toggleAll addTarget:self action:@selector(toggleSelectAllCandidates) forControlEvents:UIControlEventTouchUpInside];
            [toggleAll.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
            UIStackView *policyRow=[[UIStackView alloc] initWithArrangedSubviews:@[self.duplicatePolicy,toggleAll]];
            policyRow.axis=UILayoutConstraintAxisHorizontal;
            policyRow.spacing=10;
            control=policyRow;
        }else{
            control=self.duplicatePolicy;
        }
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }else{
        NSDictionary *row=self.candidates[ip.row-1];
        cell.textLabel.text=row[@"name"]?:@"资源";
        NSString *badgePrefix=[self protocolBadgePrefixForCandidate:row];
        NSString *baseDetail=row[@"saved"]?@"已保存":(row[@"saveError"]?:row[@"error"]?:row[@"summary"]);
        NSString *detail=[NSString stringWithFormat:@"%@ %@",badgePrefix,baseDetail?:@""];
        if(!row[@"saved"]&&row[@"updatePreview"]){
            NSString *preview=self.duplicatePolicy.selectedSegmentIndex==0?row[@"updatePreview"]:@"将另存为独立副本 · 原资源保持不变";
            detail=[NSString stringWithFormat:@"%@\n%@",detail,preview];
        }
        cell.detailTextLabel.text=detail;
        cell.accessoryType=[row[@"selected"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        cell.tintColor=HostAccent();
        if(row[@"error"]||row[@"saveError"]){
            UIButton *retry=[UIButton buttonWithType:UIButtonTypeSystem];retry.tag=ip.row-1;[retry setTitle:@"重试" forState:UIControlStateNormal];retry.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];retry.tintColor=HostAccent();[retry sizeToFit];retry.frame=CGRectMake(0,0,52,44);[retry addTarget:self action:@selector(retryButtonTapped:) forControlEvents:UIControlEventTouchUpInside];cell.accessoryView=retry;
        }else if(![row[@"saved"] boolValue]){
            NSArray *subScripts=[row[@"weboxScripts"] isKindOfClass:NSArray.class]?row[@"weboxScripts"]:nil;
            UIButton *editBtn=[UIButton buttonWithType:UIButtonTypeSystem];
            editBtn.tag=ip.row-1;
            NSString *btnTitle=subScripts.count?[NSString stringWithFormat:@"%@ 展开(%lu)/改名",[row[@"selected"] boolValue]?@"✓":@"○",(unsigned long)subScripts.count]:[NSString stringWithFormat:@"%@ 改名",[row[@"selected"] boolValue]?@"✓":@"○"];
            if([row[@"kind"] isEqual:@"page"])btnTitle=subScripts.count?@"展开链接":@"已检查";
            [editBtn setTitle:btnTitle forState:UIControlStateNormal];
            editBtn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
            editBtn.tintColor=[row[@"selected"] boolValue]?HostAccent():HostSecondaryText();
            [editBtn sizeToFit];
            editBtn.frame=CGRectMake(0,0,MAX(62,CGRectGetWidth(editBtn.bounds)+10),44);
            [editBtn addTarget:self action:@selector(candidateActionButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            cell.accessoryView=editBtn;
        }
    }}
    else {
        NSUInteger failed=[self failedCandidateCount];
        NSUInteger ready=[self selectedUnsavedCandidateCount];
        if(ip.row==0){
            cell.textLabel.text=self.busy?@"取消当前任务":@"清空并开始新的导入";
            cell.textLabel.textColor=HostAccent();
        }else if(failed>0&&ip.row==1){
            cell.textLabel.text=[NSString stringWithFormat:@"仅重试失败项（%lu）",(unsigned long)failed];
            cell.textLabel.textColor=HostAccent();
            cell.imageView.image=[UIImage systemImageNamed:@"arrow.clockwise.circle"];
            cell.imageView.tintColor=HostAccent();
        }else if(ready>0&&ip.row==(failed>0?2:1)){
            cell.textLabel.text=[NSString stringWithFormat:@"保存并立即启用（%lu 项）",(unsigned long)ready];
            cell.textLabel.textColor=HostAccent();
            cell.imageView.image=[UIImage systemImageNamed:@"bolt.circle.fill"];
            cell.imageView.tintColor=HostAccent();
        }else if(ready>0){
            cell.textLabel.text=[NSString stringWithFormat:@"保存已勾选资源（%lu 项）",(unsigned long)ready];
            cell.textLabel.textColor=HostAccent();
            cell.imageView.image=[UIImage systemImageNamed:@"checkmark.circle.fill"];
            cell.imageView.tintColor=HostAccent();
        }
    }
    if(control){[cell.contentView addSubview:control];control.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[control.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],[control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],[control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],[control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12]]];}
    return cell;
}

- (void)candidateActionButtonTapped:(UIButton *)sender {
    if(self.busy||sender.tag<0||(NSUInteger)sender.tag>=self.candidates.count)return;
    NSUInteger index=(NSUInteger)sender.tag;
    NSMutableDictionary *row=self.candidates[index];
    NSArray *subScripts=[row[@"weboxScripts"] isKindOfClass:NSArray.class]?row[@"weboxScripts"]:nil;
    if([row[@"kind"] isEqual:@"page"]){[self expandSubScriptsForCandidateAtIndex:index];return;}
    if(subScripts.count){
        __weak typeof(self) weakSelf=self;
        NSArray<HostGlassSheetAction *> *acts=@[
            [HostGlassSheetAction actionWithTitle:[NSString stringWithFormat:@"展开 %lu 个独立子脚本",(unsigned long)subScripts.count] subtitle:@"拆分为独立条目逐个勾选导入" value:[NSString stringWithFormat:@"%lu 项",(unsigned long)subScripts.count] icon:@"square.stack.3d.down.right" tint:HostAccent() destructive:NO selected:NO handler:^{[weakSelf expandSubScriptsForCandidateAtIndex:index];}],
            [HostGlassSheetAction actionWithTitle:@"重命名此资源" subtitle:@"保存前自定义合集显示名称" value:nil icon:@"pencil" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{[weakSelf promptRenameCandidateAtIndex:index];}]
        ];
        [HostGlassActionSheetViewController presentOn:self
                                                title:(row[@"name"]?:@"合集操作")
                                             subtitle:@"你可以将此索引拆分为独立子脚本逐个勾选，或修改合集名称。"
                                            badgeText:@"资源合集"
                                           badgeColor:HostAccent()
                                             sections:@[[HostGlassSheetSection sectionWithTitle:@"合集操作" actions:acts]]
                                           sourceView:(sender?:self.view)];
        return;
    }
    [self promptRenameCandidateAtIndex:index];
}

- (void)promptRenameCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count)return;
    NSMutableDictionary *row=self.candidates[index];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"重命名资源" message:@"保存前自定义该资源在列表中的显示名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.text=row[@"name"]?:@"";
        field.placeholder=@"输入资源名称";
        field.clearButtonMode=UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf=self;
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        ResourceImportWorkflowViewController *owner=weakSelf;
        if(!owner||index>=owner.candidates.count)return;
        NSString *newName=[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!newName.length)return;
        NSMutableDictionary *target=owner.candidates[index];
        owner.editRevision++;target[@"name"]=newName;
        target[@"customNameAssigned"]=@YES;
        if([target[@"catalog"] isKindOfClass:NSDictionary.class]){
            NSMutableDictionary *cat=[target[@"catalog"] mutableCopy];
            cat[@"name"]=newName;
            target[@"catalog"]=cat.copy;
        }
        if([target[@"service"] isKindOfClass:NSDictionary.class]){
            NSMutableDictionary *svc=[target[@"service"] mutableCopy];
            svc[@"name"]=newName;
            target[@"service"]=svc.copy;
        }
        [owner updateView];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)expandSubScriptsForCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count)return;
    NSMutableDictionary *row=self.candidates[index];
    NSArray *scripts=[row[@"weboxScripts"] isKindOfClass:NSArray.class]?row[@"weboxScripts"]:@[];
    if(!scripts.count)return;
    NSMutableArray<NSString *> *scriptURLs=[NSMutableArray array];
    for(NSDictionary *entry in scripts){
        if(![entry isKindOfClass:NSDictionary.class])continue;
        NSString *u=[entry[@"url"] isKindOfClass:NSString.class]?entry[@"url"]:([entry[@"api"] isKindOfClass:NSString.class]?entry[@"api"]:@"");
        if(u.length)[scriptURLs addObject:u];
    }
    if(!scriptURLs.count)return;
    [row removeObjectForKey:@"weboxScripts"];
    if([row[@"kind"] isEqual:@"page"])row[@"summary"]=@"网页链接已展开 · 请选择下方识别结果";
    self.busy=YES;
    self.taskKind=@"url";
    self.stage=[NSString stringWithFormat:@"正在展开 %lu 个子脚本…",(unsigned long)scriptURLs.count];
    NSUInteger generation=++self.generation;
    [self updateView];
    [self recognizeBatchURLs:scriptURLs index:0 generation:generation hint:[self runtimeHint]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if(ip.section==2&&ip.row==0){if(self.busy)[self cancelWork];else[self reset];return;}
    if(self.busy)return;
    if(ip.section==0){if(ip.row==1)[self recognizeURL];else if(ip.row==2||ip.row==3)[self pickFiles:ip.row==3];else if(ip.row==4){self.advancedOptionsExpanded=!self.advancedOptionsExpanded;[tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];}else if(ip.row==6)[self showCategorizedImportOptions];}
    else if(ip.section==1&&ip.row>0){NSMutableDictionary *row=self.candidates[ip.row-1];if([row[@"kind"] isEqual:@"page"]){[self expandSubScriptsForCandidateAtIndex:(NSUInteger)(ip.row-1)];return;}if([row[@"unsupportedOnly"] boolValue]){self.navigationItem.prompt=@"已识别清单，但其中没有 iOS 支持的可导入频道";return;}if(row[@"error"])[self retryCandidateAtIndex:(NSUInteger)(ip.row-1)];else if([row[@"matchTargets"] count]>1&&![row[@"saved"] boolValue])[self chooseExistingResourceForCandidate:row];else if(!row[@"saved"]){self.editRevision++;row[@"selected"]=@(![row[@"selected"] boolValue]);self.finished=NO;}[self updateView];}
    else if(ip.section==2){
        NSUInteger failed=[self failedCandidateCount];
        NSUInteger ready=[self selectedUnsavedCandidateCount];
        if(failed>0&&ip.row==1){[self retryFailedCandidates];return;}
        if(ready>0&&ip.row==(failed>0?2:1)){[self saveAndActivateSelected];return;}
        if(ready>0){[self saveSelected];return;}
    }
}
- (void)showCategorizedImportOptions {
    [self discardUncommittedCandidatesForFreshRecognition];
    ResourceImportSheetViewController *chooser=[ResourceImportSheetViewController new];chooser.modalPresentationStyle=UIModalPresentationFullScreen;__weak typeof(self) weakSelf=self;
    chooser.onSelect=^(ResourceImportOption option){ResourceImportWorkflowViewController *owner=weakSelf;if(owner)[owner applyImportCategory:option];};
    [self presentViewController:chooser animated:YES completion:nil];
}
- (void)chooseMediaServer {
    __weak typeof(self) weakSelf=self;
    NSArray<NSDictionary *> *types=@[
        @{@"id":@"emby",@"sub":@"个人 Emby 媒体库（支持账号或 API Key）",@"icon":@"play.rectangle.on.rectangle"},
        @{@"id":@"jellyfin",@"sub":@"开源 Jellyfin 媒体服务器",@"icon":@"film.stack"},
        @{@"id":@"xtream",@"sub":@"Xtream Codes 直播与点播接口",@"icon":@"antenna.radiowaves.left.and.right"},
        @{@"id":@"webdav",@"sub":@"WebDAV 网盘与局域网共享目录",@"icon":@"externaldrive.connected.to.line.below"}
    ];
    NSMutableArray<HostGlassSheetAction *> *acts=[NSMutableArray array];
    for(NSDictionary *item in types){
        NSString *type=item[@"id"];
        [acts addObject:[HostGlassSheetAction actionWithTitle:type.capitalizedString subtitle:item[@"sub"] value:nil icon:item[@"icon"] tint:HostAccent() destructive:NO selected:NO handler:^{[weakSelf configureMediaServer:type];}]];
    }
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"媒体服务器类型"
                                         subtitle:@"选择要接入的私有媒体服务器或网盘协议"
                                        badgeText:@"媒体服务器"
                                       badgeColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"支持的协议" actions:acts]]
                                       sourceView:self.view];
}
- (void)configureMediaServer:(NSString *)type {
    UIAlertController *form=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"添加 %@",type.capitalizedString] message:@"保存后由你手动启用；媒体是否可播放取决于格式与来源权限。" preferredStyle:UIAlertControllerStyleAlert];
    NSArray *labels=@[@"名称",@"服务器地址（http/https）",@"用户名",@"密码",@"API Key（Emby/Jellyfin，可选）",@"用户 ID（API Key 方式，可选）"];
    for(NSUInteger i=0;i<labels.count;i++){NSUInteger index=i;[form addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=labels[index];field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.secureTextEntry=index==3||index==4;if(index==1)field.keyboardType=UIKeyboardTypeURL;}];}
    [form addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    __weak UIAlertController *weakForm=form;
    [form addAction:[UIAlertAction actionWithTitle:@"识别并预览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;
        NSMutableDictionary *config=[@{@"cctvhostServer":@1,@"type":type} mutableCopy];NSArray *keys=@[@"name",@"url",@"username",@"password",@"apiKey",@"userId"];
        NSArray<UITextField *> *fields=weakForm.textFields;
        for(NSUInteger i=0;i<keys.count&&i<fields.count;i++)config[keys[i]]=fields[i].text?:@"";
        NSData *data=[NSJSONSerialization dataWithJSONObject:config options:0 error:NULL];NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"server-%@.json",NSUUID.UUID.UUIDString]]];
        NSError *writeError=nil;
        if(![data writeToURL:file options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&writeError]){owner.stage=@"服务器配置写入失败，请重试";[owner updateView];return;}
        NSMutableDictionary *row=[owner candidateForData:data file:file origin:nil companions:@{} hint:nil];
        [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
        if(row)[owner.candidates addObject:row];owner.stage=row[@"error"]?@"服务器配置识别失败，请检查账号并重试":@"服务器配置已识别 · 选择保存后再启用";[owner updateView];
    }]];[self presentViewController:form animated:YES completion:nil];
}
- (void)applyImportCategory:(ResourceImportOption)option {
    if(option==ResourceImportOptionMediaServer){[self chooseMediaServer];return;}
    if(option==ResourceImportOptionServices){dispatch_block_t open=self.onOpenServices;[self.navigationController dismissViewControllerAnimated:YES completion:^{if(open)open();}];return;}
    if(option==ResourceImportOptionHostCapabilities){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"宿主运行能力" message:@"资源导入阶段只做静态识别，不会执行脚本。Python 资源使用内置 CPython；JavaScript 资源可自动识别，必要时在高级选项指定 Node.js。启动后的实际能力与健康状态可在服务页查看。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];return;}
    self.editRevision++;self.selectedImportCategory=option;NSInteger runtimeIndex=0;BOOL chooseFile=NO,chooseFolder=NO;NSString *category=nil;
    switch(option){
        case ResourceImportOptionLiveURL:category=@"直播列表链接 · M3U / TXT";break;
        case ResourceImportOptionMediaURL:category=@"影视、合集或脚本链接";break;
        case ResourceImportOptionTVBox:category=@"TVBox 配置链接 · JSON";break;
        case ResourceImportOptionMacCMS:category=@"MacCMS 影视接口 · JSON / XML";break;
        case ResourceImportOptionPythonURL:category=@"Python Spider 链接";runtimeIndex=1;break;
        case ResourceImportOptionCatVodURL:category=@"CatVod / TVBox JavaScript 链接";break;
        case ResourceImportOptionNodeURL:category=@"Node.js Mobile 链接";runtimeIndex=2;break;
        case ResourceImportOptionLiveFile:category=@"直播列表文件 · M3U / M3U8 / TXT";chooseFile=YES;break;
        case ResourceImportOptionMediaFile:category=@"影视脚本或 ZIP 文件";chooseFile=YES;break;
        case ResourceImportOptionPythonFile:category=@"Python Spider 文件";runtimeIndex=1;chooseFile=YES;break;
        case ResourceImportOptionNodeFile:category=@"Node.js Mobile 脚本 / ZIP";runtimeIndex=2;chooseFile=YES;break;
        case ResourceImportOptionTVBoxFile:category=@"TVBox 配置文件 · JSON";chooseFile=YES;break;
        case ResourceImportOptionFolder:category=@"资源文件夹";chooseFolder=YES;break;
        default:category=@"资源链接";break;
    }
    [self.runtime setSelectedSegmentIndex:runtimeIndex];[self runtimeChanged:self.runtime];
    self.addressPlaceholder.text=[category stringByAppendingString:chooseFolder?@"":(chooseFile?@" · 选择文件后自动识别":@" · 粘贴链接后点识别")];self.addressPlaceholder.hidden=self.address.text.length>0;self.address.accessibilityHint=category;
    if(chooseFile||chooseFolder){[self pickFiles:chooseFolder];return;}
    self.navigationItem.prompt=category;[self.address becomeFirstResponder];
}
- (void)reset {
    self.generation++;[self.fetcher cancel];[self.downloader cancel];self.batchRetrying=NO;self.activateAfterSaveRequested=NO;[self.batchRetryIndices removeAllObjects];for(NSDictionary *row in self.candidates)if(row[@"service"]&&![row[@"saved"] boolValue])[ServiceStore remove:row[@"service"][@"id"]];[self.candidates removeAllObjects];self.finished=NO;self.taskKind=@"";self.selectedImportCategory=-1;self.restoredAddress=@"";self.address.text=@"";self.addressPlaceholder.hidden=NO;self.addressPlaceholder.text=@"粘贴单条或多条影视/WeBox/TVBox/直播链接，或直接粘贴源码";self.stage=@"粘贴地址，或选择本地文件";[self updateView];
}
- (void)cancelWork {self.generation++;[self.fetcher cancel];[self.downloader cancel];self.batchRetrying=NO;self.activateAfterSaveRequested=NO;[self.batchRetryIndices removeAllObjects];self.retryCandidateIndex=NSNotFound;self.busy=NO;self.stage=@"任务已取消 · 已保存项目保留，可重试未保存项";[self updateView];}
- (NSString *)runtimeHint {return self.runtime.selectedSegmentIndex==1?@"python":(self.runtime.selectedSegmentIndex==2?@"node":nil);}
- (void)showFailure:(NSString *)message {self.busy=NO;self.stage=message?:@"识别失败，请重试";[self updateView];}
- (void)retryButtonTapped:(UIButton *)sender {if(sender.tag>=0&&(NSUInteger)sender.tag<self.candidates.count)[self retryCandidateAtIndex:(NSUInteger)sender.tag];}
- (NSUInteger)failedCandidateCount {NSUInteger count=0;for(NSDictionary *row in self.candidates)if((row[@"error"]||row[@"saveError"])&&![row[@"saved"] boolValue])count++;return count;}
- (void)retryFailedCandidates {
    if(self.busy||self.batchRetrying)return;[self.batchRetryIndices removeAllObjects];for(NSUInteger index=0;index<self.candidates.count;index++){NSDictionary *row=self.candidates[index];if((row[@"error"]||row[@"saveError"])&&![row[@"saved"] boolValue])[self.batchRetryIndices addObject:@(index)];}
    if(!self.batchRetryIndices.count)return;self.batchRetrying=YES;self.stage=[NSString stringWithFormat:@"正在重试 %lu 个失败项目…",(unsigned long)self.batchRetryIndices.count];[self advanceBatchRetry];
}
- (void)advanceBatchRetry {
    if(!self.batchRetrying||self.busy)return;
    if(self.batchRetryIndices.count){NSUInteger index=self.batchRetryIndices.firstObject.unsignedIntegerValue;[self.batchRetryIndices removeObjectAtIndex:0];[self retryCandidateAtIndex:index];return;}
    self.batchRetrying=NO;self.stage=@"失败项目重试完成 · 可查看仍失败的项目";[self updateView];
}
- (void)retryCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count)return;NSMutableDictionary *row=self.candidates[index];
    if(row[@"saveError"]){[self retrySaveCandidateAtIndex:index];return;}
    NSString *retryOrigin=[row[@"retryOrigin"] isKindOfClass:NSString.class]?row[@"retryOrigin"]:([row[@"origin"] isKindOfClass:NSString.class]?row[@"origin"]:@"");
    NSString *retryHint=[row[@"retryHint"] isKindOfClass:NSString.class]?row[@"retryHint"]:[self runtimeHint];
    NSData *data=[row[@"retryData"] isKindOfClass:NSData.class]?row[@"retryData"]:nil;NSString *filename=row[@"retryFileName"]?:row[@"localFileName"]?:row[@"name"]?:@"resource.json";NSURL *sourceURL=nil;
    if(!data&&retryOrigin.length&&[ProfileStore isHTTP:retryOrigin]){
        NSURL *url=ResourceImportNormalizedURL(retryOrigin);
        if(url){
            self.busy=YES;self.taskKind=@"url";self.stage=[NSString stringWithFormat:@"正在重试 %@…",row[@"name"]?:url.host?:@"链接"];NSUInteger generation=++self.generation;[self updateView];__weak typeof(self) weakSelf=self;
            if([@[@"py",@"js",@"hjs",@"mjs",@"cjs",@"zip",@"md5"] containsObject:url.pathExtension.lowercaseString]){
                self.downloader=[MediaPackageDownloader new];
                [self.downloader importURL:url headers:nil runtimeHint:retryHint completion:^(NSDictionary *service,NSError *error){
                    ResourceImportWorkflowViewController *owner=weakSelf;
                    if(!owner||owner.generation!=generation){if(service)[ServiceStore remove:service[@"id"]];return;}
                    if(service&&index<owner.candidates.count){
                        ResourceImportRecordRecentURL(url.absoluteString);
                        NSMutableDictionary *candidate=[@{@"kind":@"service",@"service":service,@"name":service[@"name"]?:@"脚本资源",@"summary":[NSString stringWithFormat:@"已识别 · %@ · %@",service[@"engine"]?:@"",service[@"protocol"]?:@""],@"selected":@YES} mutableCopy];
                        [owner decorateCandidate:candidate file:nil origin:url.absoluteString];
                        [owner.candidates replaceObjectAtIndex:index withObject:candidate];
                        owner.stage=@"单项识别成功 · 已更新预览";
                    }else{
                        row[@"error"]=error.localizedDescription?:@"下载或识别失败";
                        owner.stage=@"单项重试失败 · 可再次重试";
                    }
                    owner.busy=NO;[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];
                }];
                return;
            }
            self.fetcher=[ResourceImportFetcher new];self.fetcher.fallbackDataProvider=^NSData *(NSURL *u){return ResourceImportBundledFallbackForURL(u);};
            self.fetcher.completion=^(NSData *fetched,NSURLResponse *response,NSError *error){
                ResourceImportWorkflowViewController *owner=weakSelf;
                if(!owner||owner.generation!=generation)return;
                if(error||!fetched.length){
                    row[@"error"]=error.localizedDescription?:@"无法读取链接内容";
                    owner.busy=NO;owner.stage=@"单项重试失败 · 可再次重试";[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];return;
                }
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                    NSString *ext=ResourceContentExtension(fetched,response.suggestedFilename?:response.URL.lastPathComponent);
                    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"retry-url-%@.%@",NSUUID.UUID.UUIDString,ext]];
                    [fetched writeToFile:path atomically:YES];
                    NSMutableDictionary *candidate=[owner candidateForData:fetched file:[NSURL fileURLWithPath:path] origin:response.URL.absoluteString?:url.absoluteString companions:@{} hint:retryHint];
                    if([candidate[@"kind"] isEqual:@"catalog"]){NSMutableDictionary *catalog=[candidate[@"catalog"] mutableCopy];catalog[@"url"]=url.absoluteString;candidate[@"catalog"]=catalog;}
                    else if([candidate[@"kind"] isEqual:@"playlist"]){candidate[@"origin"]=url.absoluteString;candidate[@"resolvedURL"]=response.URL.absoluteString?:url.absoluteString;}
                    else if(candidate[@"service"]){NSMutableDictionary *service=[candidate[@"service"] mutableCopy];service[@"url"]=url.absoluteString;candidate[@"service"]=service;}
                    [owner decorateCandidate:candidate file:nil origin:url.absoluteString];
                    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                    dispatch_async(dispatch_get_main_queue(),^{
                        if(owner.generation!=generation){if(candidate[@"service"])[ServiceStore remove:candidate[@"service"][@"id"]];return;}
                        if(!candidate[@"error"]&&index<owner.candidates.count){ResourceImportRecordRecentURL(url.absoluteString);candidate[@"selected"]=@YES;[owner.candidates replaceObjectAtIndex:index withObject:candidate];owner.stage=@"单项识别成功 · 已更新预览";}
                        else{row[@"error"]=candidate[@"error"]?:@"重新识别失败";owner.stage=@"单项重试失败 · 可再次重试";}
                        owner.busy=NO;[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];
                    });
                });
            };
            [self.fetcher load:url];
            return;
        }
    }
    if(!data&&[row[@"retryBookmark"] isKindOfClass:NSData.class])sourceURL=[NSURL URLByResolvingBookmarkData:row[@"retryBookmark"] options:0 relativeToURL:nil bookmarkDataIsStale:nil error:NULL];
    if(!data&&sourceURL){BOOL scope=[sourceURL startAccessingSecurityScopedResource];data=ResourceImportReadBounded(sourceURL,32*1024*1024);if(scope)[sourceURL stopAccessingSecurityScopedResource];}
    if(!data){self.retryCandidateIndex=(NSInteger)index;if(self.batchRetrying){self.busy=YES;self.stage=[NSString stringWithFormat:@"请重新选择 %@",filename];[self updateView];}UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];picker.allowsMultipleSelection=NO;picker.delegate=self;self.pickingFolder=NO;[self presentViewController:picker animated:YES completion:nil];return;}
    self.busy=YES;self.taskKind=@"file-retry";self.stage=[NSString stringWithFormat:@"正在重试 %@…",filename];NSUInteger generation=++self.generation;[self updateView];NSDictionary *companions=[row[@"retryCompanions"] isKindOfClass:NSDictionary.class]?row[@"retryCompanions"]:@{};NSString *origin=row[@"retryOrigin"]?:@"",*hint=row[@"retryHint"]?:@"";__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"retry-%@",NSUUID.UUID.UUIDString]];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];NSString *path=[directory stringByAppendingPathComponent:filename.lastPathComponent.length?filename.lastPathComponent:@"resource.json"];[data writeToFile:path atomically:YES];NSMutableDictionary *candidate=[weakSelf candidateForData:data file:[NSURL fileURLWithPath:path] origin:origin companions:companions hint:hint];[NSFileManager.defaultManager removeItemAtPath:directory error:NULL];dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){if(candidate[@"service"])[ServiceStore remove:candidate[@"service"][@"id"]];return;}if(!candidate[@"error"]){candidate[@"selected"]=@YES;[owner.candidates replaceObjectAtIndex:index withObject:candidate];}else{row[@"error"]=candidate[@"error"];row[@"retryData"]=data;if(candidate[@"localFileName"])row[@"localFileName"]=candidate[@"localFileName"];}owner.busy=NO;owner.stage=candidate[@"error"]?@"单项重试失败 · 可再次重试或重新选择文件":@"单项识别成功 · 已更新预览";[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];});});
}
- (void)retrySaveCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count||!self.onSaveCandidate)return;NSMutableDictionary *row=self.candidates[index];self.busy=YES;self.taskKind=@"save";self.stage=[NSString stringWithFormat:@"正在重试保存 %@…",row[@"name"]?:@"资源"];NSUInteger generation=++self.generation;[self updateView];__weak typeof(self) weakSelf=self;
    self.onSaveCandidate(row,self.duplicatePolicy.selectedSegmentIndex==0,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.busy=NO;if(error){row[@"saveError"]=error.localizedDescription?:@"保存失败";owner.stage=@"单项保存失败 · 可再次重试";}else{row[@"saved"]=@YES;[row removeObjectForKey:@"saveError"];[row removeObjectForKey:@"retryData"];owner.stage=@"单项资源已保存";}[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];});});
}
- (void)attachUpdatePreviewToCandidate:(NSMutableDictionary *)row {
    if(![row[@"kind"] isEqual:@"catalog"])return;NSDictionary *incoming=row[@"catalog"]?:@{};NSDictionary *existing=nil;
    for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:catalog[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:catalog[@"importFingerprint"]])){existing=catalog;break;}
    if(!existing)return;
    NSDictionary *sites=ResourceCatalogDiff([existing[@"sites"] isKindOfClass:NSArray.class]?existing[@"sites"]:@[],[incoming[@"sites"] isKindOfClass:NSArray.class]?incoming[@"sites"]:@[],@[@"key",@"api"],@[@"name",@"api",@"type",@"ext",@"header",@"playUrl"]);
    NSDictionary *lives=ResourceCatalogDiff([existing[@"lives"] isKindOfClass:NSArray.class]?existing[@"lives"]:@[],[incoming[@"lives"] isKindOfClass:NSArray.class]?incoming[@"lives"]:@[],@[@"url",@"name"],@[@"name",@"url",@"type",@"ua"]);
    NSUInteger added=[sites[@"added"] unsignedIntegerValue]+[lives[@"added"] unsignedIntegerValue],changed=[sites[@"changed"] unsignedIntegerValue]+[lives[@"changed"] unsignedIntegerValue],removed=[sites[@"removed"] unsignedIntegerValue]+[lives[@"removed"] unsignedIntegerValue];if(![(existing[@"tvboxConfig"]?:@{}) isEqual:(incoming[@"tvboxConfig"]?:@{})])changed++;
    row[@"existingCatalogID"]=existing[@"id"]?:@"";row[@"updatePreview"]=[NSString stringWithFormat:@"更新「%@」：新增 %lu · 变更 %lu · 移除 %lu",existing[@"name"]?:@"资源合集",(unsigned long)added,(unsigned long)changed,(unsigned long)removed];
}
- (void)decorateCandidate:(NSMutableDictionary *)row file:(NSURL *)file origin:(NSString *)origin {
    if(!origin.length&&file.isFileURL){NSString *filename=file.lastPathComponent?:@"";if(filename.length)row[@"localFileName"]=filename;}
    if(!NSThread.isMainThread){row[@"needsDecoration"]=@YES;return;}
    [row removeObjectForKey:@"needsDecoration"];
    [self attachUpdatePreviewToCandidate:row];
    if(!self.existingImportTargetsProvider)return;
    NSString *kind=row[@"kind"]?:@"",*filename=row[@"localFileName"]?:@"";NSDictionary *catalog=row[@"catalog"]?:@{},*service=row[@"service"]?:@{};
    NSString *url=catalog[@"url"]?:service[@"url"]?:row[@"origin"]?:@"",*fingerprint=catalog[@"importFingerprint"]?:service[@"importFingerprint"]?:row[@"importFingerprint"]?:@"";
    NSMutableArray *matches=[NSMutableArray array];
    for(NSDictionary *target in self.existingImportTargetsProvider()?:@[]){if(![target[@"kind"] isEqual:kind])continue;BOOL sameURL=url.length&&[url isEqual:target[@"url"]];BOOL sameFingerprint=fingerprint.length&&[fingerprint isEqual:target[@"fingerprint"]];BOOL sameFile=filename.length&&[filename caseInsensitiveCompare:target[@"sourceFilename"]?:@""]==NSOrderedSame;if(sameURL||sameFingerprint||sameFile)[matches addObject:target];}
    if(!matches.count){[row removeObjectForKey:@"existingResourceID"];[row removeObjectForKey:@"existingResourceKind"];[row removeObjectForKey:@"existingCatalogID"];return;}row[@"matchTargets"]=matches.copy;
    if(matches.count>1){NSString *selectedID=row[@"existingResourceID"];for(NSDictionary *candidate in matches)if(selectedID.length&&[candidate[@"id"] isEqual:selectedID]){row[@"updatePreview"]=[NSString stringWithFormat:@"已选择更新「%@」并保留资源身份",candidate[@"name"]?:@"资源"];return;}[row removeObjectForKey:@"existingResourceID"];[row removeObjectForKey:@"existingResourceKind"];row[@"updatePreview"]=[NSString stringWithFormat:@"有 %lu 个同名旧资源 · 点按选择要更新的资源",(unsigned long)matches.count];return;}
    NSDictionary *target=matches.firstObject;row[@"existingResourceID"]=target[@"id"]?:@"";row[@"existingResourceKind"]=kind;
    if([kind isEqual:@"catalog"]){row[@"existingCatalogID"]=target[@"id"]?:@"";if(!row[@"updatePreview"])row[@"updatePreview"]=[NSString stringWithFormat:@"本地文件名匹配旧合集「%@」 · 更新将保留资源身份",target[@"name"]?:@"资源合集"];}
    else row[@"updatePreview"]=[NSString stringWithFormat:@"%@匹配旧资源「%@」 · 更新将保留资源身份",filename.length?@"本地文件名":@"内容或地址",target[@"name"]?:@"资源"];
}
- (void)refreshExistingResourceMatches {
    for(NSMutableDictionary *row in self.candidates){NSString *filename=row[@"localFileName"];if(!filename.length)continue;[row removeObjectForKey:@"matchTargets"];[self decorateCandidate:row file:[NSURL fileURLWithPath:filename] origin:nil];}
    [self updateView];
}
- (void)chooseExistingResourceForCandidate:(NSMutableDictionary *)row {
    NSArray *targets=[row[@"matchTargets"] isKindOfClass:NSArray.class]?row[@"matchTargets"]:@[];if(targets.count<2)return;
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetAction *> *acts=[NSMutableArray array];
    for(NSDictionary *target in targets){
        NSString *name=target[@"name"]?:@"未命名资源";
        NSString *kindLabel=target[@"kindLabel"]?:@"资源";
        BOOL selected=[row[@"existingResourceID"] isEqual:target[@"id"]];
        [acts addObject:[HostGlassSheetAction actionWithTitle:name subtitle:@"更新内容并保留原资源 ID 与个人设置" value:kindLabel icon:@"arrow.triangle.2.circlepath" tint:HostAccent() destructive:NO selected:selected handler:^{
            ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;
            owner.editRevision++;
            row[@"existingResourceID"]=target[@"id"]?:@"";
            row[@"existingResourceKind"]=target[@"kind"]?:@"";
            row[@"updatePreview"]=[NSString stringWithFormat:@"将更新「%@」并保留资源身份",target[@"name"]?:@"资源"];
            [owner updateView];
        }]];
    }
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"选择要更新的旧资源"
                                         subtitle:@"确认后会保留所选资源的 ID 和个人设置。"
                                        badgeText:[NSString stringWithFormat:@"%lu 个匹配",(unsigned long)targets.count]
                                       badgeColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"匹配到的已有资源" actions:acts]]
                                       sourceView:self.view];
}
- (NSMutableDictionary *)candidateForData:(NSData *)data file:(NSURL *)file origin:(NSString *)origin companions:(NSDictionary *)companions hint:(NSString *)hint {
    ResourceDetectionResult *detection=[ResourceDetectionResult inspectData:data filename:file.lastPathComponent?:@""];
    NSMutableDictionary *(^annotate)(NSMutableDictionary *)=^NSMutableDictionary *(NSMutableDictionary *row){row[@"detectionKind"]=detection.kind;row[@"detectionEvidence"]=detection.evidence;row[@"networkStatus"]=@"unchecked";row[@"playbackStatus"]=@"unverified";if([row[@"summary"] isKindOfClass:NSString.class]&&![detection.kind isEqual:@"unknown"])row[@"summary"]=[row[@"summary"] stringByAppendingFormat:@" · 识别依据：%@",detection.evidence.firstObject?:detection.kind];return row;};
    if(ResourceContentIsHTML(data)){
        NSArray *links=ResourceContentPageLinks(data,[NSURL URLWithString:origin?:@""]);
        NSMutableDictionary *page=[@{@"kind":@"page",@"name":@"资源网页",@"summary":links.count?[NSString stringWithFormat:@"发现 %lu 条资源链接 · 点按展开后选择导入",(unsigned long)links.count]:@"网页中未发现可静态识别的资源直链",@"selected":@NO,@"weboxScripts":links,@"origin":origin?:@""} mutableCopy];
        return annotate(page);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *fingerprint=[NSMutableString string];for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[fingerprint appendFormat:@"%02x",digest[i]];
    NSError *error=nil;NSMutableDictionary *catalog=[[TVBoxCatalogStore parseData:data sourceURL:origin error:&error] mutableCopy];if(catalog)catalog[@"importFingerprint"]=fingerprint;
    if(catalog){
        if([catalog[@"catalogKind"] isEqual:@"tvbox-local-bundle"]&&file.isFileURL){
            NSString *fileTitle=file.lastPathComponent.stringByDeletingPathExtension;
            if(fileTitle.length&&![fileTitle hasPrefix:@"pasted-resource-"]&&![fileTitle hasPrefix:@"resource-"]&&![fileTitle hasPrefix:@"batch-"]&&![fileTitle hasPrefix:@"retry-"]&&([catalog[@"name"] isEqualToString:@"资源合集"]||[catalog[@"name"] hasSuffix:@"· TVBox 合集"])){
                catalog[@"name"]=fileTitle;
            }
        }
        NSArray *sites=catalog[@"sites"]?:@[];NSUInteger recognized=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])recognized++;
        NSDictionary *bMeta=[catalog[@"bundleMetadata"] isKindOfClass:NSDictionary.class]?catalog[@"bundleMetadata"]:nil;
        NSString *summary=[bMeta[@"isLocalBundle"] boolValue]?[NSString stringWithFormat:@"本地集合包 · %lu 个站点 · %lu 个已识别 · JAR 校验%@", (unsigned long)sites.count, (unsigned long)recognized, [bMeta[@"jarMD5Verified"] boolValue]?@"通过":@"就绪"]:[NSString stringWithFormat:@"合集 · %lu 个站点 · %lu 个已识别 · %lu 个直播列表",(unsigned long)sites.count,(unsigned long)recognized,(unsigned long)[catalog[@"lives"] count]];
        NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":catalog,@"name":catalog[@"name"]?:file.lastPathComponent?:@"资源合集",@"summary":summary,@"selected":@YES} mutableCopy];
        id rawJSON=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if([rawJSON isKindOfClass:NSDictionary.class]&&[rawJSON[@"scripts"] isKindOfClass:NSArray.class]&&[rawJSON[@"scripts"] count]>0){
            row[@"weboxScripts"]=rawJSON[@"scripts"];
        }else if([catalog[@"depots"] isKindOfClass:NSArray.class]&&[catalog[@"depots"] count]>0){
            row[@"weboxScripts"]=catalog[@"depots"];
        }
        [self decorateCandidate:row file:file origin:origin];return annotate(row);
    }
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];NSString *detectedExtension=ResourceContentExtension(data,file.lastPathComponent?:@"");BOOL scriptContent=[@[@"py",@"js",@"mjs",@"cjs",@"hjs"] containsObject:detectedExtension]||hint.length>0;NSDictionary *report=text.length&&!scriptContent?[M3UParser reportForText:text baseURL:origin.length?[NSURL URLWithString:origin]:nil]:nil;NSArray *channels=[report[@"channels"] isKindOfClass:NSArray.class]?report[@"channels"]:@[];NSDictionary *unsupported=[report[@"unsupportedProtocols"] isKindOfClass:NSDictionary.class]?report[@"unsupportedProtocols"]:@{};
    if(channels.count||unsupported.count){BOOL unsupportedOnly=!channels.count&&unsupported.count>0;NSString *summary=unsupportedOnly?[NSString stringWithFormat:@"已识别直播清单 · 无可导入协议 · 不支持：%@",[[unsupported allKeys] componentsJoinedByString:@"、"]]:[NSString stringWithFormat:@"直播列表 · %lu 个可导入频道",(unsigned long)channels.count];if(!unsupportedOnly&&unsupported.count)summary=[summary stringByAppendingFormat:@" · 跳过不支持的协议：%@",[[unsupported allKeys] componentsJoinedByString:@"、"]];NSMutableDictionary *row=[@{@"kind":@"playlist",@"text":text,@"origin":origin?:@"",@"importFingerprint":fingerprint,@"name":file.lastPathComponent?:@"直播订阅",@"summary":summary,@"selected":@(!unsupportedOnly),@"unsupportedOnly":@(unsupportedOnly)} mutableCopy];row[@"unsupportedProtocols"]=unsupported;[self decorateCandidate:row file:file origin:origin];return annotate(row);}
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if(origin.length&&[json isKindOfClass:NSDictionary.class]&&[json[@"list"] isKindOfClass:NSArray.class]){NSDictionary *api=[TVBoxCatalogStore catalogWithMacCMSAPIURL:origin name:nil error:&error];if(api){NSMutableDictionary *catalog=[api mutableCopy];catalog[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":catalog,@"name":catalog[@"name"]?:@"影视接口",@"summary":@"MacCMS 影视接口 · 按需连接",@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return annotate(row);}}
    NSDictionary *service=[MediaPackageImporter importFile:file companionFiles:companions runtimeHint:hint error:&error];
    if(service){NSMutableDictionary *imported=[service mutableCopy];if(origin.length)imported[@"url"]=origin;imported[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"service",@"service":imported,@"name":service[@"name"]?:file.lastPathComponent,@"summary":[NSString stringWithFormat:@"脚本资源 · %@ · %@",service[@"engine"]?:@"自动识别",service[@"protocol"]?:@"启动后验证能力"],@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return annotate(row);}
    NSMutableDictionary *failed=[@{@"name":file.lastPathComponent?:@"资源",@"error":error.localizedDescription?:@"不支持或无法识别此文件",@"selected":@NO} mutableCopy];BOOL isServerCredentials=[json isKindOfClass:NSDictionary.class]&&[json[@"cctvhostServer"] integerValue]==1;if(data.length<=32*1024*1024&&!isServerCredentials)failed[@"retryData"]=data;if(file.isFileURL&&!isServerCredentials)failed[@"retryFileName"]=file.lastPathComponent?:@"";failed[@"retryOrigin"]=origin?:@"";failed[@"retryCompanions"]=companions?:@{};failed[@"retryHint"]=hint?:@"";[self decorateCandidate:failed file:file origin:origin];return annotate(failed);
}

- (void)recognizeBatchURLs:(NSArray<NSString *> *)urlStrings index:(NSUInteger)index generation:(NSUInteger)generation hint:(NSString *)hint {
    if(self.generation!=generation)return;
    if(index>=urlStrings.count){
        self.busy=NO;
        NSUInteger okCount=0,failCount=0;
        for(NSDictionary *row in self.candidates){
            if(row[@"error"])failCount++;
            else okCount++;
        }
        self.stage=[NSString stringWithFormat:@"批量识别完成 · 成功 %lu 项 · 失败 %lu 项",(unsigned long)okCount,(unsigned long)failCount];
        [self updateView];
        return;
    }
    NSString *raw=urlStrings[index];
    NSURL *url=ResourceImportNormalizedURL(raw);
    if(!url){
        [self recognizeBatchURLs:urlStrings index:index+1 generation:generation hint:hint];
        return;
    }
    self.stage=[NSString stringWithFormat:@"正在批量识别 (%lu/%lu)…",(unsigned long)(index+1),(unsigned long)urlStrings.count];
    [self updateView];
    __weak typeof(self) weakSelf=self;
    if([@[@"py",@"js",@"hjs",@"mjs",@"cjs",@"zip",@"md5"] containsObject:url.pathExtension.lowercaseString]){
        self.downloader=[MediaPackageDownloader new];
        [self.downloader importURL:url headers:nil runtimeHint:hint completion:^(NSDictionary *service,NSError *error){
            ResourceImportWorkflowViewController *owner=weakSelf;
            if(!owner||owner.generation!=generation){if(service)[ServiceStore remove:service[@"id"]];return;}
            if(service){
                ResourceImportRecordRecentURL(url.absoluteString);
                NSMutableDictionary *row=[@{@"kind":@"service",@"service":service,@"name":service[@"name"]?:@"脚本资源",@"summary":[NSString stringWithFormat:@"已识别 · %@ · %@",service[@"engine"]?:@"",service[@"protocol"]?:@""],@"selected":@YES} mutableCopy];
                [owner decorateCandidate:row file:nil origin:url.absoluteString];
                [owner.candidates addObject:row];
            }else{
                NSMutableDictionary *failed=[@{@"name":(url.lastPathComponent.stringByRemovingPercentEncoding?:url.lastPathComponent)?:@"脚本资源",@"error":error.localizedDescription?:@"下载或识别失败",@"selected":@NO,@"retryOrigin":url.absoluteString?:@"",@"retryHint":hint?:@""} mutableCopy];
                [owner.candidates addObject:failed];
            }
            [owner recognizeBatchURLs:urlStrings index:index+1 generation:generation hint:hint];
        }];
        return;
    }
    self.fetcher=[ResourceImportFetcher new];self.fetcher.fallbackDataProvider=^NSData *(NSURL *url){return ResourceImportBundledFallbackForURL(url);};
    self.fetcher.completion=^(NSData *data,NSURLResponse *response,NSError *error){
        ResourceImportWorkflowViewController *owner=weakSelf;
        if(!owner||owner.generation!=generation)return;
        if(error||!data.length){
            NSMutableDictionary *failed=[@{@"name":(url.lastPathComponent.stringByRemovingPercentEncoding?:url.host)?:@"资源",@"error":error.localizedDescription?:@"无法读取链接内容",@"selected":@NO,@"retryOrigin":url.absoluteString?:@"",@"retryHint":hint?:@""} mutableCopy];
            [owner.candidates addObject:failed];
            [owner recognizeBatchURLs:urlStrings index:index+1 generation:generation hint:hint];
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *ext=ResourceContentExtension(data,response.suggestedFilename?:response.URL.lastPathComponent);
            NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"batch-%@.%@",NSUUID.UUID.UUIDString,ext]];
            [data writeToFile:path atomically:YES];
            NSMutableDictionary *row=[owner candidateForData:data file:[NSURL fileURLWithPath:path] origin:response.URL.absoluteString?:url.absoluteString companions:@{} hint:hint];
            if([row[@"kind"] isEqual:@"catalog"]){NSMutableDictionary *catalog=[row[@"catalog"] mutableCopy];catalog[@"url"]=url.absoluteString;row[@"catalog"]=catalog;}
            else if([row[@"kind"] isEqual:@"playlist"]){row[@"origin"]=url.absoluteString;row[@"resolvedURL"]=response.URL.absoluteString?:url.absoluteString;}
            else if(row[@"service"]){NSMutableDictionary *service=[row[@"service"] mutableCopy];service[@"url"]=url.absoluteString;row[@"service"]=service;}
            [owner decorateCandidate:row file:nil origin:url.absoluteString];
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{
                if(owner.generation!=generation){if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}
                if(!row[@"error"])ResourceImportRecordRecentURL(url.absoluteString);
                [owner.candidates addObject:row];
                [owner recognizeBatchURLs:urlStrings index:index+1 generation:generation hint:hint];
            });
        });
    };
    [self.fetcher load:url];
}

- (void)recognizeURL {
    [self discardUncommittedCandidatesForFreshRecognition];
    NSString *raw=[self.address.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!raw.length){[self showFailure:@"请先输入或粘贴资源链接、JSON 配置或脚本内容"];return;}

    // Support direct paste of raw JSON / M3U / WeBox / JS / Python content
    BOOL looksLikeRawContent=ResourceContentIsHTML([raw dataUsingEncoding:NSUTF8StringEncoding])||([raw hasPrefix:@"{"]&&[raw hasSuffix:@"}"])||([raw hasPrefix:@"["]&&[raw hasSuffix:@"]"])||(([raw hasPrefix:@"//"]||[raw hasPrefix:@"/*"])&&[raw containsString:@"\"sites\""]&&[raw hasSuffix:@"}"])||[raw hasPrefix:@"#EXTM3U"]||[raw containsString:@"#EXTINF:"]||[raw containsString:@"WeBox.define("]||[raw containsString:@"class Spider"]||[raw containsString:@"module.exports"]||[raw containsString:@"export default"];
    if(looksLikeRawContent){
        [self.view endEditing:YES];self.restoredAddress=raw;self.taskKind=@"url";self.busy=YES;self.stage=@"正在识别粘贴内容…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];
        NSData *rawData=[raw dataUsingEncoding:NSUTF8StringEncoding];
        NSString *ext=([raw hasPrefix:@"{"]||[raw hasPrefix:@"["])?@"json":(([raw hasPrefix:@"#EXTM3U"]||[raw containsString:@"#EXTINF:"])?@"m3u":(([raw containsString:@"class Spider"]||[raw containsString:@"def init("])?@"py":@"js"));
        NSString *tempPath=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"pasted-resource-%@.%@",NSUUID.UUID.UUIDString,ext]];
        __weak typeof(self) weakSelf=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            [rawData writeToFile:tempPath atomically:YES];
            NSMutableDictionary *row=[weakSelf candidateForData:rawData file:[NSURL fileURLWithPath:tempPath] origin:nil companions:@{} hint:hint];
            [NSFileManager.defaultManager removeItemAtPath:tempPath error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;
                if(!owner||owner.generation!=generation){if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}
                if(row)[owner.candidates addObject:row];owner.busy=NO;owner.stage=row[@"error"]?(row[@"error"]?:@"识别失败"):@"识别完成 · 请选择要保存的资源";[owner updateView];
            });
        });
        return;
    }

    NSArray<NSString *> *extracted=ResourceImportExtractURLStrings(raw);
    if(extracted.count>1){
        NSArray<NSString *> *bounded=[extracted subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)32,extracted.count))];
        [self.view endEditing:YES];self.restoredAddress=[bounded componentsJoinedByString:@"\n"];self.address.text=self.restoredAddress;self.taskKind=@"url";self.busy=YES;NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];
        [self recognizeBatchURLs:bounded index:0 generation:generation hint:hint];
        return;
    }

    NSURL *url=ResourceImportNormalizedURL(raw);
    if(!url&&extracted.count==1){
        raw=extracted.firstObject;
        url=ResourceImportNormalizedURL(raw);
        self.address.text=raw;
    }
    if(!url||!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]){[self showFailure:@"请输入 HTTP / HTTPS 链接，或直接粘贴 JSON / M3U / 脚本内容"];return;}
    raw=url.absoluteString;
    [self.view endEditing:YES];self.restoredAddress=raw;self.taskKind=@"url";self.busy=YES;self.stage=@"正在下载与识别…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    if(self.selectedImportCategory==ResourceImportOptionMacCMS){NSError *error=nil;NSDictionary *catalog=[TVBoxCatalogStore catalogWithMacCMSAPIURL:raw name:nil error:&error];if(!catalog){[self showFailure:error.localizedDescription?:@"MacCMS 接口地址无效"];return;}ResourceImportRecordRecentURL(raw);unsigned char digest[CC_SHA256_DIGEST_LENGTH];NSData *sourceData=[raw dataUsingEncoding:NSUTF8StringEncoding];CC_SHA256(sourceData.bytes,(CC_LONG)sourceData.length,digest);NSMutableString *fingerprint=[NSMutableString string];for(NSUInteger index=0;index<CC_SHA256_DIGEST_LENGTH;index++)[fingerprint appendFormat:@"%02x",digest[index]];NSMutableDictionary *prepared=[catalog mutableCopy];prepared[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":prepared,@"name":prepared[@"name"]?:@"MacCMS 影视接口",@"summary":@"MacCMS API · 保存接口索引，选中后请求 JSON / XML",@"selected":@YES} mutableCopy];[self decorateCandidate:row file:nil origin:raw];[self.candidates addObject:row];self.busy=NO;self.stage=@"MacCMS 接口已识别 · 尚未验证网络";[self updateView];return;}
    if([@[@"py",@"js",@"hjs",@"mjs",@"cjs",@"zip",@"md5"] containsObject:url.pathExtension.lowercaseString]){
        self.downloader=[MediaPackageDownloader new];self.downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.stage=expected>0?[NSString stringWithFormat:@"%@ · %.1f / %.1f MiB",stage,received/1048576.0,expected/1048576.0]:[NSString stringWithFormat:@"%@ · %.1f MiB",stage,received/1048576.0];if(owner.onStateChanged)owner.onStateChanged();[owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];};
        [self.downloader importURL:url headers:nil runtimeHint:hint completion:^(NSDictionary *service,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){if(service)[ServiceStore remove:service[@"id"]];return;}if(!service){[owner showFailure:error.localizedDescription];return;}ResourceImportRecordRecentURL(url.absoluteString);NSMutableDictionary *row=[@{@"kind":@"service",@"service":service,@"name":service[@"name"]?:@"脚本资源",@"summary":[NSString stringWithFormat:@"已识别 · %@ · %@",service[@"engine"]?:@"",service[@"protocol"]?:@""],@"selected":@YES} mutableCopy];[owner decorateCandidate:row file:nil origin:url.absoluteString];[owner.candidates addObject:row];owner.busy=NO;owner.stage=@"识别完成 · 尚未保存";[owner updateView];}];return;
    }
    self.fetcher=[ResourceImportFetcher new];self.fetcher.fallbackDataProvider=^NSData *(NSURL *url){return ResourceImportBundledFallbackForURL(url);};self.fetcher.completion=^(NSData *data,NSURLResponse *response,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;if(error||!data.length){[owner showFailure:error.localizedDescription?:@"无法读取链接内容"];return;}
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *ext=ResourceContentExtension(data,response.suggestedFilename?:response.URL.lastPathComponent);NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"resource-%@.%@",NSUUID.UUID.UUIDString,ext]];[data writeToFile:path atomically:YES];NSMutableDictionary *row=[owner candidateForData:data file:[NSURL fileURLWithPath:path] origin:response.URL.absoluteString?:raw companions:@{} hint:hint];if([row[@"kind"] isEqual:@"catalog"]){NSMutableDictionary *catalog=[row[@"catalog"] mutableCopy];catalog[@"url"]=raw;row[@"catalog"]=catalog;}else if([row[@"kind"] isEqual:@"playlist"]){row[@"origin"]=raw;row[@"resolvedURL"]=response.URL.absoluteString?:raw;}else if(row[@"service"]){NSMutableDictionary *service=[row[@"service"] mutableCopy];service[@"url"]=raw;row[@"service"]=service;}[owner decorateCandidate:row file:nil origin:raw];[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{if(owner.generation!=generation){if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}if(!row[@"error"])ResourceImportRecordRecentURL(raw);[owner.candidates addObject:row];owner.busy=NO;owner.stage=@"识别完成 · 请选择要保存的资源";[owner updateView];});
        });
    };[self.fetcher load:url];
}
- (void)pickFiles:(BOOL)folder {
    [self discardUncommittedCandidatesForFreshRecognition];
    self.pickingFolder=folder;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder?UTTypeFolder:UTTypeData] asCopy:!folder];picker.allowsMultipleSelection=!folder;picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {self.retryCandidateIndex=NSNotFound;if(self.batchRetrying){self.busy=NO;self.stage=@"已跳过需要重新选择的失败文件";[self updateView];[self advanceBatchRetry];}}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count){self.retryCandidateIndex=NSNotFound;self.busy=NO;if(self.batchRetrying){[self updateView];[self advanceBatchRetry];}return;}BOOL folder=self.pickingFolder;NSInteger retryIndex=self.retryCandidateIndex;self.retryCandidateIndex=NSNotFound;self.busy=YES;self.taskKind=retryIndex!=NSNotFound?@"file-retry":@"file";self.stage=retryIndex!=NSNotFound?@"正在重新识别此文件…":@"正在检查本地文件…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSURL *root=folder?urls.firstObject:nil;BOOL scoped=[root startAccessingSecurityScopedResource];NSMutableArray *files=[NSMutableArray array];BOOL truncated=NO;
        NSMutableDictionary *folderBundleCandidate=nil;
        if(folder&&root){
            NSError *bundleErr=nil;
            NSMutableDictionary *bundleCat=[[TVBoxCatalogStore parseBundleDirectoryAtURL:root error:&bundleErr] mutableCopy];
            if(bundleCat){
                NSArray *bSites=bundleCat[@"sites"]?:@[];NSUInteger bRec=0;for(NSDictionary *s in bSites)if([s[@"supported"] boolValue])bRec++;
                NSDictionary *bMeta=[bundleCat[@"bundleMetadata"] isKindOfClass:NSDictionary.class]?bundleCat[@"bundleMetadata"]:nil;
                NSString *bSummary=[NSString stringWithFormat:@"本地集合包 · %lu 个站点 · %lu 个已识别 · JAR 校验%@", (unsigned long)bSites.count, (unsigned long)bRec, [bMeta[@"jarMD5Verified"] boolValue]?@"通过":@"就绪"];
                folderBundleCandidate=[@{@"kind":@"catalog",@"catalog":bundleCat,@"name":bundleCat[@"name"]?:root.lastPathComponent?:@"本地合集包",@"summary":bSummary,@"selected":@YES} mutableCopy];
                [weakSelf decorateCandidate:folderBundleCandidate file:root origin:nil];
            }
        }
        if(folder&&!folderBundleCandidate){NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url,NSError *error){return NO;}];NSUInteger scanned=0;for(NSURL *url in enumerator){if(++scanned>4096||weakSelf.generation!=generation){truncated=YES;break;}NSNumber *regular=nil,*link=nil;[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];if(link.boolValue){[enumerator skipDescendants];continue;}if(!regular.boolValue)continue;if(![@[@"json",@"hawk",@"js",@"hjs",@"mjs",@"cjs",@"py",@"zip",@"txt",@"m3u",@"m3u8",@"php"] containsObject:url.pathExtension.lowercaseString])continue;if(files.count==128){truncated=YES;break;}[files addObject:url];}}
        else if(!folder) {truncated=urls.count>128;[files addObjectsFromArray:[urls subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)128,urls.count))]];}
        NSMutableArray *rows=[NSMutableArray array];if(folderBundleCandidate)[rows addObject:folderBundleCandidate];NSUInteger total=0;NSMutableSet *batchPorts=[NSMutableSet set];for(NSDictionary *s in [ServiceStore services])if(s[@"port"])[batchPorts addObject:s[@"port"]];
        for(NSURL *file in files){if([file.lastPathComponent isEqual:@"index.config.js"]){BOOL companion=NO;for(NSURL *main in files)if(![main isEqual:file]&&[@[@"js",@"hjs",@"mjs",@"cjs"] containsObject:main.pathExtension.lowercaseString]&&[main.URLByDeletingLastPathComponent isEqual:file.URLByDeletingLastPathComponent]){companion=YES;break;}if(companion)continue;}ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)break;BOOL childScope=[file startAccessingSecurityScopedResource];NSNumber *size=nil;[file getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];NSData *data=nil;if(size.unsignedLongLongValue<=32*1024*1024&&total+size.unsignedLongLongValue<=64*1024*1024)data=ResourceImportReadBounded(file,MIN((NSUInteger)32*1024*1024,(NSUInteger)64*1024*1024-total));if(data)total+=data.length;
            NSMutableDictionary *companions=[NSMutableDictionary dictionary];if([@[@"js",@"hjs",@"mjs",@"cjs"] containsObject:file.pathExtension.lowercaseString]&&![file.lastPathComponent isEqual:@"index.config.js"]){for(NSURL *other in files)if([other.lastPathComponent isEqual:@"index.config.js"]&&[other.URLByDeletingLastPathComponent isEqual:file.URLByDeletingLastPathComponent]){BOOL access=[other startAccessingSecurityScopedResource];NSNumber *bytes=nil;[other getResourceValue:&bytes forKey:NSURLFileSizeKey error:NULL];if(bytes.unsignedLongLongValue<=65536){NSData *configuration=ResourceImportReadBounded(other,65536);if(configuration)companions[@"index.config.js"]=configuration;}if(access)[other stopAccessingSecurityScopedResource];break;}}
            NSMutableDictionary *row=data?[owner candidateForData:data file:file origin:nil companions:companions hint:hint]:[@{@"name":file.lastPathComponent,@"error":@"无法读取或超过本次导入大小上限",@"selected":@NO,@"localFileName":file.lastPathComponent?:@""} mutableCopy];if(!data){NSData *bookmark=[file bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(bookmark)row[@"retryBookmark"]=bookmark;row[@"retryFileName"]=file.lastPathComponent?:@"";row[@"retryHint"]=hint?:@"";}if([row[@"service"] isKindOfClass:NSDictionary.class]){NSMutableDictionary *svc=[row[@"service"] mutableCopy];NSInteger p=[svc[@"port"] integerValue];if(p<1024||[batchPorts containsObject:@(p)]){NSInteger nextP=18780;while([batchPorts containsObject:@(nextP)]&&nextP<65535)nextP++;svc[@"port"]=@(nextP);p=nextP;}[batchPorts addObject:@(p)];row[@"service"]=svc.copy;}[rows addObject:row];if(childScope)[file stopAccessingSecurityScopedResource];
        }
        if(scoped)[root stopAccessingSecurityScopedResource];dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){for(NSDictionary *row in rows)if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}if(retryIndex!=NSNotFound&&retryIndex>=0&&(NSUInteger)retryIndex<owner.candidates.count){NSMutableDictionary *prior=owner.candidates[(NSUInteger)retryIndex];NSMutableDictionary *replacement=rows.firstObject;if(replacement&&!replacement[@"error"]){replacement[@"selected"]=@YES;[owner.candidates replaceObjectAtIndex:(NSUInteger)retryIndex withObject:replacement];owner.stage=@"单项识别成功 · 已更新预览";}else{if(replacement)prior[@"error"]=replacement[@"error"]?:@"重新识别失败";prior[@"retryFileName"]=urls.firstObject.lastPathComponent?:prior[@"retryFileName"]?:@"";NSData *bookmark=[urls.firstObject bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(bookmark)prior[@"retryBookmark"]=bookmark;owner.stage=@"单项重试失败 · 可再次重试";}}else{[owner.candidates addObjectsFromArray:rows];owner.stage=truncated?@"扫描达到数量上限 · 部分文件未处理":(rows.count?@"本地文件识别完成 · 尚未保存":@"未发现支持的资源文件");}owner.busy=NO;[owner updateView];if(owner.batchRetrying&&retryIndex!=NSNotFound)[owner advanceBatchRetry];});
    }});
}
- (void)saveSelected {if(self.busy||!self.onSaveCandidate)return;self.activateAfterSaveRequested=NO;self.taskKind=@"save";self.busy=YES;self.stage=@"正在保存资源…";NSUInteger generation=++self.generation;[self updateView];[self saveNext:0 generation:generation];}
- (void)saveAndActivateSelected {if(self.busy||!self.onSaveCandidate)return;self.activateAfterSaveRequested=YES;self.taskKind=@"save";self.busy=YES;self.stage=@"正在保存并启用资源…";NSUInteger generation=++self.generation;[self updateView];[self saveNext:0 generation:generation];}
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation {
    if(self.generation!=generation)return;
    if(index>=self.candidates.count){
        self.busy=NO;NSUInteger saved=0,failed=0,pending=0;
        for(NSMutableDictionary *row in self.candidates){if([row[@"saved"] boolValue]){saved++;[row removeObjectForKey:@"retryData"];}else if(row[@"error"]||row[@"saveError"])failed++;else if([row[@"selected"] boolValue])pending++;}
        self.finished=failed==0&&pending==0;
        BOOL shouldDismiss=self.activateAfterSaveRequested&&self.finished&&saved>0&&(self.view.window!=nil||self.navigationController.presentingViewController!=nil);
        self.activateAfterSaveRequested=NO;
        self.stage=[NSString stringWithFormat:@"已保存 %lu 项 · 失败 / 不支持 %lu 项",(unsigned long)saved,(unsigned long)failed];
        [self updateView];
        if(shouldDismiss){[self minimize];}
        return;
    }
    NSMutableDictionary *row=self.candidates[index];if([row[@"kind"] isEqual:@"page"]||[row[@"unsupportedOnly"] boolValue]||![row[@"selected"] boolValue]||row[@"error"]||[row[@"saved"] boolValue]){[self saveNext:index+1 generation:generation];return;}
    if(self.activateAfterSaveRequested)row[@"activateAfterSave"]=@YES;
    else [row removeObjectForKey:@"activateAfterSave"];
    __weak typeof(self) weakSelf=self;self.onSaveCandidate(row,self.duplicatePolicy.selectedSegmentIndex==0,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;if(error)row[@"saveError"]=error.localizedDescription?:@"保存失败";else{row[@"saved"]=@YES;[row removeObjectForKey:@"saveError"];[row removeObjectForKey:@"retryData"];}[owner updateView];[owner saveNext:index+1 generation:generation];});});
}
@end
