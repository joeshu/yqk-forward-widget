#import "PluginLogStore.h"
#import "HostLogBuffer.h"
#import "HostLogRedactor.h"
#import <CommonCrypto/CommonDigest.h>

static const unsigned long long PluginRunMaximumBytes = 256 * 1024;
static const unsigned long long PluginRunRetainedBytes = 128 * 1024;
static const NSUInteger PluginRunMaximumCount = 20;

@interface PluginLogStore ()
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) NSMutableDictionary<NSString *,HostLogBuffer *> *pending;
@property(nonatomic,strong) NSMutableSet<NSString *> *scheduled;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *generations;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *activeRunIDs;
@property(nonatomic,strong) NSLock *lock;
- (void)flushPath:(NSString *)path generation:(NSUInteger)generation;
@end

@implementation PluginLogStore
+ (instancetype)shared {static PluginLogStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[PluginLogStore new];});return store;}
- (instancetype)init {
    if((self=[super init])){
        NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
        self.directory=[[support stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"plugin-logs"];
        self.queue=dispatch_queue_create("com.cctvhost.plugin-logs",DISPATCH_QUEUE_SERIAL);
        self.pending=[NSMutableDictionary dictionary];self.scheduled=[NSMutableSet set];self.generations=[NSMutableDictionary dictionary];self.activeRunIDs=[NSMutableDictionary dictionary];self.lock=[NSLock new];
    }
    return self;
}
- (NSString *)digestForIdentifier:(NSString *)identifier {
    NSData *data=[(identifier.length?identifier:@"unknown") dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *name=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[name appendFormat:@"%02x",digest[i]];return name;
}
- (NSString *)legacyPathForIdentifier:(NSString *)identifier {return [self.directory stringByAppendingPathComponent:[[self digestForIdentifier:identifier] stringByAppendingPathExtension:@"log"]];}
- (NSString *)runDirectoryForIdentifier:(NSString *)identifier {return [self.directory stringByAppendingPathComponent:[self digestForIdentifier:identifier]];}
- (NSString *)runPathForIdentifier:(NSString *)identifier runID:(NSString *)runID {return [[self runDirectoryForIdentifier:identifier] stringByAppendingPathComponent:[runID stringByAppendingPathExtension:@"log"]];}
- (NSString *)metadataPathForIdentifier:(NSString *)identifier runID:(NSString *)runID {return [[self runDirectoryForIdentifier:identifier] stringByAppendingPathComponent:[runID stringByAppendingPathExtension:@"json"]];}
- (BOOL)isValidRunID:(NSString *)runID {return [runID isEqual:@"legacy"]||([[NSUUID alloc] initWithUUIDString:runID]!=nil);}
- (NSString *)safeText:(NSString *)text {
    NSString *safe=[HostLogRedactor redactText:text?:@""];if(safe.length>4096){NSUInteger end=4096;unichar last=[safe characterAtIndex:end-1];if(last>=0xd800&&last<=0xdbff)end--;safe=[[safe substringToIndex:end] stringByAppendingString:@"… [日志已截断]"];}return safe;
}
- (void)enqueueEntry:(NSString *)entry atPath:(NSString *)path {
    NSUInteger generation=0;BOOL schedule=NO;[self.lock lock];HostLogBuffer *buffer=self.pending[path];if(!buffer){buffer=[[HostLogBuffer alloc] initWithMaximumCharacters:65536];self.pending[path]=buffer;}[buffer append:entry];generation=[self.generations[path] unsignedIntegerValue];if(![self.scheduled containsObject:path]){[self.scheduled addObject:path];schedule=YES;}[self.lock unlock];
    if(schedule)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),self.queue,^{[self flushPath:path generation:generation];});
}
- (void)appendText:(NSString *)text toPath:(NSString *)path {if(!text.length||!path.length)return;[self enqueueEntry:[NSString stringWithFormat:@"[%@] %@\n",NSDate.date.description,[self safeText:text]] atPath:path];}
- (void)appendLine:(NSString *)line forIdentifier:(NSString *)identifier {
    if(!line.length||!identifier.length)return;[self.lock lock];NSString *runID=self.activeRunIDs[identifier];[self.lock unlock];NSString *path=runID?[self runPathForIdentifier:identifier runID:runID]:[self legacyPathForIdentifier:identifier];[self appendText:line toPath:path];
}
- (void)flushPath:(NSString *)path generation:(NSUInteger)generation {
    [self.lock lock];if([self.generations[path] unsignedIntegerValue]!=generation){[self.lock unlock];return;}[self.scheduled removeObject:path];NSString *batch=[self.pending[path] drain];[self.lock unlock];if(!batch.length)return;
    NSString *parent=path.stringByDeletingLastPathComponent;NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:NULL];if(![fm fileExistsAtPath:path])[fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:path];@try{[file seekToEndOfFile];[file writeData:[batch dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];file=nil;}@catch(NSException *exception){@try{[file closeFile];}@catch(NSException *ignored){};return;}
    unsigned long long size=[[fm attributesOfItemAtPath:path error:NULL][NSFileSize] unsignedLongLongValue];
    // Keep pre-session logs at their historical 512 KiB budget; each new run
    // is independently bounded so one noisy invocation cannot evict another.
    unsigned long long maximum=[path.stringByDeletingLastPathComponent isEqualToString:self.directory]?512*1024:PluginRunMaximumBytes;
    if(size>maximum){unsigned long long retained=maximum==512*1024?256*1024:PluginRunRetainedBytes;NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:path];[reader seekToFileOffset:size-retained];NSData *tail=[reader readDataOfLength:(NSUInteger)retained];[reader closeFile];NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];NSRange boundary=[tail rangeOfData:newline options:0 range:NSMakeRange(0,tail.length)];if(boundary.location!=NSNotFound)[[tail subdataWithRange:NSMakeRange(NSMaxRange(boundary),tail.length-NSMaxRange(boundary))] writeToFile:path atomically:YES];}
}
- (void)flushPathNow:(NSString *)path { [self.lock lock];NSUInteger generation=[self.generations[path] unsignedIntegerValue];[self.lock unlock];[self flushPath:path generation:generation]; }
- (void)flushPathsForIdentifier:(NSString *)identifier {
    NSMutableArray<NSString *> *paths=[NSMutableArray arrayWithObject:[self legacyPathForIdentifier:identifier]];NSString *runDirectory=[self runDirectoryForIdentifier:identifier];NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:runDirectory error:NULL]?:@[];for(NSString *file in files)if([file.pathExtension isEqualToString:@"log"])[paths addObject:[runDirectory stringByAppendingPathComponent:file]];for(NSString *path in paths)[self flushPathNow:path];
}
- (NSDictionary *)metadataAtPath:(NSString *)path {
    NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];id value=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL]:nil;return [value isKindOfClass:NSDictionary.class]?value:nil;
}
- (void)writeMetadata:(NSDictionary *)metadata forIdentifier:(NSString *)identifier runID:(NSString *)runID {
    NSString *path=[self metadataPathForIdentifier:identifier runID:runID];[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];NSData *data=[NSJSONSerialization dataWithJSONObject:metadata options:0 error:NULL];if(data)[data writeToFile:path options:NSDataWritingAtomic error:NULL];
}
- (NSArray<NSDictionary *> *)runRecordsForIdentifier:(NSString *)identifier {
    NSMutableArray<NSDictionary *> *records=[NSMutableArray array];NSString *legacy=[self legacyPathForIdentifier:identifier];NSDictionary *legacyAttributes=[NSFileManager.defaultManager attributesOfItemAtPath:legacy error:NULL];if([legacyAttributes[NSFileSize] unsignedLongLongValue]>0){[records addObject:@{@"runID":@"legacy",@"startedAt":@([legacyAttributes[NSFileModificationDate] timeIntervalSince1970]),@"status":@"更新前历史日志",@"size":legacyAttributes[NSFileSize]?:@0,@"legacy":@YES}];}
    NSString *directory=[self runDirectoryForIdentifier:identifier];NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]?:@[];for(NSString *file in files){if(![file.pathExtension isEqualToString:@"json"])continue;NSString *runID=file.stringByDeletingPathExtension;if(![[NSUUID alloc] initWithUUIDString:runID])continue;NSDictionary *metadata=[self metadataAtPath:[directory stringByAppendingPathComponent:file]];if(!metadata)continue;NSString *logPath=[self runPathForIdentifier:identifier runID:runID];NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:logPath error:NULL];NSMutableDictionary *record=[metadata mutableCopy];record[@"runID"]=runID;record[@"size"]=attributes[NSFileSize]?:@0;record[@"legacy"]=@NO;[records addObject:record];}
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){double left=[a[@"startedAt"] doubleValue],right=[b[@"startedAt"] doubleValue];return left>right?NSOrderedAscending:(left<right?NSOrderedDescending:NSOrderedSame);}];return records;
}
- (void)markRun:(NSString *)runID identifier:(NSString *)identifier status:(NSString *)status ended:(BOOL)ended {
    if(!runID.length)return;NSString *metadataPath=[self metadataPathForIdentifier:identifier runID:runID];NSMutableDictionary *metadata=[[self metadataAtPath:metadataPath] mutableCopy]?:[NSMutableDictionary dictionary];metadata[@"runID"]=runID;metadata[@"status"]=status?:@"已结束";if(ended)metadata[@"endedAt"]=@([NSDate.date timeIntervalSince1970]);[self writeMetadata:metadata forIdentifier:identifier runID:runID];
}
- (void)markOpenRunsInterrupted:(NSString *)identifier {
    for(NSDictionary *record in [self runRecordsForIdentifier:identifier]){if([record[@"legacy"] boolValue])continue;NSString *status=record[@"status"];if(![status isEqual:@"启动中"]&&![status isEqual:@"运行中"])continue;NSString *runID=record[@"runID"];NSString *path=[self runPathForIdentifier:identifier runID:runID];[self appendText:@"上次运行未正常结束；可能是 App 崩溃或被系统终止。" toPath:path];[self flushPathNow:path];[self markRun:runID identifier:identifier status:@"未正常结束" ended:YES];[self.lock lock];if([self.activeRunIDs[identifier] isEqual:runID])[self.activeRunIDs removeObjectForKey:identifier];[self.lock unlock];}
}
- (NSString *)beginRunForIdentifier:(NSString *)identifier {
    if(!identifier.length)return @"";__block NSString *runID=@"";dispatch_sync(self.queue,^{[self flushPathsForIdentifier:identifier];[self markOpenRunsInterrupted:identifier];runID=NSUUID.UUID.UUIDString.lowercaseString;[NSFileManager.defaultManager createDirectoryAtPath:[self runDirectoryForIdentifier:identifier] withIntermediateDirectories:YES attributes:nil error:NULL];[self writeMetadata:@{@"runID":runID,@"startedAt":@([NSDate.date timeIntervalSince1970]),@"status":@"启动中"} forIdentifier:identifier runID:runID];[self.lock lock];self.activeRunIDs[identifier]=runID;[self.lock unlock];[self appendLine:@"本次运行开始" forIdentifier:identifier];[self flushPathNow:[self runPathForIdentifier:identifier runID:runID]];[self pruneRunsForIdentifier:identifier];});return runID;
}
- (void)markRunRunningForIdentifier:(NSString *)identifier {
    if(!identifier.length)return;dispatch_sync(self.queue,^{[self.lock lock];NSString *runID=self.activeRunIDs[identifier];[self.lock unlock];if(runID.length)[self markRun:runID identifier:identifier status:@"运行中" ended:NO];});
}
- (void)finishRunForIdentifier:(NSString *)identifier status:(NSString *)status {
    if(!identifier.length)return;dispatch_sync(self.queue,^{[self.lock lock];NSString *runID=self.activeRunIDs[identifier];[self.lock unlock];if(!runID.length)return;NSString *path=[self runPathForIdentifier:identifier runID:runID];[self appendText:[NSString stringWithFormat:@"本次运行结束 · %@",status.length?status:@"已结束"] toPath:path];[self flushPathNow:path];[self markRun:runID identifier:identifier status:status.length?status:@"已结束" ended:YES];[self.lock lock];if([self.activeRunIDs[identifier] isEqual:runID])[self.activeRunIDs removeObjectForKey:identifier];[self.lock unlock];});
}
- (void)markUnmanagedRunsInterruptedForIdentifier:(NSString *)identifier {
    if(!identifier.length)return;dispatch_sync(self.queue,^{[self flushPathsForIdentifier:identifier];[self markOpenRunsInterrupted:identifier];});
}
- (void)pruneRunsForIdentifier:(NSString *)identifier {
    NSArray<NSDictionary *> *records=[self runRecordsForIdentifier:identifier];NSUInteger retained=0;for(NSDictionary *record in records){if([record[@"legacy"] boolValue])continue;NSString *runID=record[@"runID"];[self.lock lock];BOOL active=[self.activeRunIDs[identifier] isEqual:runID];[self.lock unlock];if(active){retained++;continue;}retained++;if(retained>PluginRunMaximumCount){[NSFileManager.defaultManager removeItemAtPath:[self runPathForIdentifier:identifier runID:runID] error:NULL];[NSFileManager.defaultManager removeItemAtPath:[self metadataPathForIdentifier:identifier runID:runID] error:NULL];}}
}
- (NSArray<NSDictionary *> *)runsForIdentifier:(NSString *)identifier {
    if(!identifier.length)return @[];__block NSArray *records=@[];dispatch_sync(self.queue,^{[self flushPathsForIdentifier:identifier];records=[self runRecordsForIdentifier:identifier];});return records;
}
- (NSString *)readPath:(NSString *)path {return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]?:@"";}
- (NSString *)logForIdentifier:(NSString *)identifier runID:(NSString *)runID {
    if(!identifier.length||![self isValidRunID:runID])return @"";__block NSString *text=@"";dispatch_sync(self.queue,^{NSString *path=[runID isEqual:@"legacy"]?[self legacyPathForIdentifier:identifier]:[self runPathForIdentifier:identifier runID:runID];[self flushPathNow:path];text=[self readPath:path];});return [HostLogRedactor redactText:text];
}
- (NSString *)aggregateForIdentifier:(NSString *)identifier {
    NSMutableArray *chunks=[NSMutableArray array];NSString *legacy=[self logForIdentifier:identifier runID:@"legacy"];if(legacy.length)[chunks addObject:[NSString stringWithFormat:@"—— 更新前历史日志 ——\n%@",legacy]];NSArray *records=[[self runsForIdentifier:identifier] reverseObjectEnumerator].allObjects;for(NSDictionary *record in records){if([record[@"legacy"] boolValue])continue;NSString *runID=record[@"runID"];NSString *text=[self logForIdentifier:identifier runID:runID];if(text.length)[chunks addObject:[NSString stringWithFormat:@"—— %@ · %@ ——\n%@",record[@"startedAt"]?:@"",record[@"status"]?:@"运行记录",text]];}return [chunks componentsJoinedByString:@"\n"];
}
- (NSString *)logForIdentifier:(NSString *)identifier {if(!identifier.length)return @"";return [self aggregateForIdentifier:identifier];}
- (void)clearRunForIdentifier:(NSString *)identifier runID:(NSString *)runID completion:(dispatch_block_t)completion {
    if(!identifier.length||![self isValidRunID:runID]){if(completion)completion();return;}dispatch_async(self.queue,^{[self flushPathsForIdentifier:identifier];NSString *path=[runID isEqual:@"legacy"]?[self legacyPathForIdentifier:identifier]:[self runPathForIdentifier:identifier runID:runID];[self.lock lock];BOOL active=[self.activeRunIDs[identifier] isEqual:runID];self.generations[path]=@([self.generations[path] unsignedIntegerValue]+1);[self.pending[path] clear];[self.scheduled removeObject:path];[self.lock unlock];if(active){[@"本次运行日志已清空；后续日志仍记录在本次运行中。\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];}else{[NSFileManager.defaultManager removeItemAtPath:path error:NULL];if(![runID isEqual:@"legacy"])[NSFileManager.defaultManager removeItemAtPath:[self metadataPathForIdentifier:identifier runID:runID] error:NULL];}if(completion)dispatch_async(dispatch_get_main_queue(),completion);});
}
- (void)clearLogForIdentifier:(NSString *)identifier completion:(dispatch_block_t)completion {
    if(!identifier.length){if(completion)completion();return;}dispatch_async(self.queue,^{[self flushPathsForIdentifier:identifier];NSString *legacy=[self legacyPathForIdentifier:identifier];[self.lock lock];NSString *activeRunID=self.activeRunIDs[identifier];NSMutableArray *paths=[NSMutableArray arrayWithObject:legacy];NSString *directory=[self runDirectoryForIdentifier:identifier];for(NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]?:@[])if([file.pathExtension isEqual:@"log"])[paths addObject:[directory stringByAppendingPathComponent:file]];for(NSString *path in paths){self.generations[path]=@([self.generations[path] unsignedIntegerValue]+1);[self.pending[path] clear];[self.scheduled removeObject:path];}[self.lock unlock];[@"" writeToFile:legacy atomically:YES encoding:NSUTF8StringEncoding error:NULL];for(NSDictionary *record in [self runRecordsForIdentifier:identifier]){if([record[@"legacy"] boolValue])continue;NSString *runID=record[@"runID"];NSString *path=[self runPathForIdentifier:identifier runID:runID];if([runID isEqual:activeRunID]){[@"当前运行日志已清空；后续日志仍记录在本次运行中。\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];}else{[NSFileManager.defaultManager removeItemAtPath:path error:NULL];[NSFileManager.defaultManager removeItemAtPath:[self metadataPathForIdentifier:identifier runID:runID] error:NULL];}}if(completion)dispatch_async(dispatch_get_main_queue(),completion);});
}
- (NSString *)safeDisplayName:(NSString *)displayName {NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r"];NSArray *parts=[(displayName.length?displayName:@"插件") componentsSeparatedByCharactersInSet:invalid];NSString *safe=[parts componentsJoinedByString:@"-"];return safe.length>48?[safe substringToIndex:48]:safe;}
- (void)prepareExportContent:(NSString *)content displayName:(NSString *)displayName suffix:(NSString *)suffix completion:(void (^)(NSURL *,NSError *))completion {
    NSError *error=nil;NSData *data=content.length?[[HostLogRedactor redactText:content] dataUsingEncoding:NSUTF8StringEncoding]:nil;if(!data)error=[NSError errorWithDomain:@"PluginLogStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"该脚本还没有日志记录。"}];NSString *destination=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CCTVHost-%@-%@-日志.txt",[self safeDisplayName:displayName],suffix?:@"plugin"]];if(data&&![data writeToFile:destination options:NSDataWritingAtomic error:&error])data=nil;dispatch_async(dispatch_get_main_queue(),^{completion(data?[NSURL fileURLWithPath:destination]:nil,error);});
}
- (void)prepareExportForIdentifier:(NSString *)identifier runID:(NSString *)runID displayName:(NSString *)displayName completion:(void (^)(NSURL *,NSError *))completion {
    if(!identifier.length||![self isValidRunID:runID]){dispatch_async(dispatch_get_main_queue(),^{completion(nil,[NSError errorWithDomain:@"PluginLogStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"没有可导出的运行日志。"}]);});return;}dispatch_async(self.queue,^{NSString *path=[runID isEqual:@"legacy"]?[self legacyPathForIdentifier:identifier]:[self runPathForIdentifier:identifier runID:runID];[self flushPathNow:path];NSString *text=[self readPath:path];NSString *serviceSuffix=[[self digestForIdentifier:identifier] substringToIndex:8];NSString *runSuffix=[runID isEqual:@"legacy"]?@"legacy":[runID substringToIndex:MIN((NSUInteger)8,runID.length)];[self prepareExportContent:text displayName:displayName suffix:[NSString stringWithFormat:@"%@-%@",serviceSuffix,runSuffix] completion:completion];});
}
- (void)prepareExportForIdentifier:(NSString *)identifier displayName:(NSString *)displayName completion:(void (^)(NSURL *,NSError *))completion {
    if(!identifier.length){dispatch_async(dispatch_get_main_queue(),^{completion(nil,[NSError errorWithDomain:@"PluginLogStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"该脚本还没有日志记录。"}]);});return;}dispatch_async(self.queue,^{[self flushPathsForIdentifier:identifier];NSMutableArray *chunks=[NSMutableArray array];NSString *legacy=[self readPath:[self legacyPathForIdentifier:identifier]];if(legacy.length)[chunks addObject:[NSString stringWithFormat:@"—— 更新前历史日志 ——\n%@",legacy]];for(NSDictionary *record in [[self runRecordsForIdentifier:identifier] reverseObjectEnumerator]){if([record[@"legacy"] boolValue])continue;NSString *text=[self readPath:[self runPathForIdentifier:identifier runID:record[@"runID"]]];if(text.length)[chunks addObject:[NSString stringWithFormat:@"—— %@ · %@ ——\n%@",record[@"startedAt"]?:@"",record[@"status"]?:@"运行记录",text]];}NSString *suffix=[[self digestForIdentifier:identifier] substringToIndex:8];[self prepareExportContent:[chunks componentsJoinedByString:@"\n"] displayName:displayName suffix:suffix completion:completion];});
}
@end
