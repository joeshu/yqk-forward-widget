#import "LocalMediaStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSNotificationName const LocalMediaStoreDidChangeNotification = @"LocalMediaStoreDidChangeNotification";

@interface LocalMediaStore ()
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic) BOOL importing;
@property(nonatomic) BOOL stopRequested;
@property(nonatomic) NSUInteger completedCount;
@property(nonatomic) NSUInteger totalCount;
@property(nonatomic) NSUInteger lastFailureCount;
@property(nonatomic) NSUInteger lastDuplicateCount;
@property(nonatomic,copy) NSString *currentFileName;
@property(nonatomic,copy) NSArray<NSURL *> *cachedFiles;
@property(nonatomic,copy) NSDictionary<NSString *,id> *cachedState;
-  (NSArray<NSURL *> *)readFilesFromDisk;
-  (void)refreshCachedFiles;
@end

@implementation LocalMediaStore
+ (instancetype)shared {static LocalMediaStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[self new];});return store;}
- (instancetype)init {
    if((self=[super init])){
        _queue=dispatch_queue_create("com.cctvhost.local-media-store",DISPATCH_QUEUE_SERIAL);
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _directory=[[support URLByAppendingPathComponent:@"CCTVHost/LocalMedia" isDirectory:YES] URLByStandardizingPath];
        [NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES attributes:nil error:nil];
        _cachedFiles=[self readFilesFromDisk];_cachedState=@{@"importing":@NO,@"stopRequested":@NO,@"completed":@0,@"total":@0,@"currentFileName":@"",@"failureCount":@0,@"duplicateCount":@0};
        dispatch_async(_queue,^{for(NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:0 error:nil])if([entry.lastPathComponent hasPrefix:@".staging-"]) [NSFileManager.defaultManager removeItemAtURL:entry error:nil];[self refreshCachedFiles];});
    }
    return self;
}
- (NSArray<NSURL *> *)readFilesFromDisk {NSMutableArray *valid=[NSMutableArray array];for(NSURL *entry in [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]){if([entry.lastPathComponent hasPrefix:@"."])continue;NSNumber *regular=nil,*symbolic=nil;[entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];[entry getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];if(regular.boolValue&&!symbolic.boolValue)[valid addObject:entry];}return [valid sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];}];}
- (NSArray<NSURL *> *)filesSnapshot {@synchronized(self){return self.cachedFiles?:@[];}}
- (NSDictionary<NSString *,id> *)stateSnapshot {@synchronized(self){return self.cachedState?:@{};}}
- (void)refreshCachedFiles {NSArray *files=[self readFilesFromDisk];@synchronized(self){self.cachedFiles=files;}}
- (void)notifyChange {@synchronized(self){self.cachedState=@{@"importing":@(self.importing),@"stopRequested":@(self.stopRequested),@"completed":@(self.completedCount),@"total":@(self.totalCount),@"currentFileName":self.currentFileName?:@"",@"failureCount":@(self.lastFailureCount),@"duplicateCount":@(self.lastDuplicateCount)};}dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:LocalMediaStoreDidChangeNotification object:self];});}
+ (NSString *)displayNameForFileURL:(NSURL *)url {NSString *name=url.lastPathComponent?:@"媒体文件";if(name.length>37&&[name characterAtIndex:36]=='-')return [name substringFromIndex:37];return name;}
- (BOOL)isCopiedFileURL:(NSURL *)url {NSURL *candidate=url.URLByStandardizingPath;if(!candidate.isFileURL)return NO;return [candidate.URLByDeletingLastPathComponent.path isEqualToString:self.directory.path];}
- (BOOL)stopWasRequested {@synchronized(self){return self.stopRequested;}}
- (NSString *)safeNameForURL:(NSURL *)url {
    NSString *name=url.lastPathComponent.length?url.lastPathComponent:@"media";NSString *stem=name.stringByDeletingPathExtension,*extension=name.pathExtension;
    NSMutableString *bounded=[NSMutableString string];NSUInteger bytes=0;for(NSUInteger i=0;i<stem.length;){NSRange range=[stem rangeOfComposedCharacterSequenceAtIndex:i];NSString *part=[stem substringWithRange:range];NSUInteger size=[part lengthOfBytesUsingEncoding:NSUTF8StringEncoding];if(bytes+size>100)break;[bounded appendString:part];bytes+=size;i=NSMaxRange(range);}if(!bounded.length)[bounded appendString:@"media"];
    NSMutableString *boundedExtension=[NSMutableString string];bytes=0;for(NSUInteger i=0;i<extension.length;){NSRange range=[extension rangeOfComposedCharacterSequenceAtIndex:i];NSString *part=[extension substringWithRange:range];NSUInteger size=[part lengthOfBytesUsingEncoding:NSUTF8StringEncoding];if(bytes+size>20)break;[boundedExtension appendString:part];bytes+=size;i=NSMaxRange(range);}
    return [NSString stringWithFormat:@"%@-%@%@%@",NSUUID.UUID.UUIDString,bounded,boundedExtension.length?@".":@"",boundedExtension];
}
- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *,NSArray<NSDictionary<NSString *,NSString *> *> *))completion {
    NSArray<NSURL *> *items=[[NSArray alloc] initWithArray:urls copyItems:NO];
    dispatch_async(self.queue,^{
        if(self.importing){NSError *error=[NSError errorWithDomain:@"LocalMediaStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"本机媒体导入仍在进行"}];if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(@[],@[@{@"fileName":@"",@"error":error.localizedDescription}]);});return;}
        @synchronized(self){self.importing=YES;self.stopRequested=NO;self.completedCount=0;self.totalCount=items.count;self.currentFileName=@"";self.lastFailureCount=0;self.lastDuplicateCount=0;}NSMutableArray<NSURL *> *imported=[NSMutableArray array];NSMutableArray<NSDictionary<NSString *,NSString *> *> *failures=[NSMutableArray array];[self notifyChange];
        for(NSURL *url in items){
            if([self stopWasRequested])break;
            @synchronized(self){self.currentFileName=url.lastPathComponent?:@"media";}[self notifyChange];
            // T17：重复文件——同展示名且同大小的已在库文件不再重复复制，记为跳过（不占失败数）。
            NSString *displayName=[LocalMediaStore displayNameForFileURL:url];
            NSNumber *sourceSize=nil;[url getResourceValue:&sourceSize forKey:NSURLFileSizeKey error:nil];
            BOOL duplicate=NO;
            if(displayName.length&&sourceSize){for(NSURL *existing in [self readFilesFromDisk]){NSNumber *existingSize=nil;[existing getResourceValue:&existingSize forKey:NSURLFileSizeKey error:nil];if([[LocalMediaStore displayNameForFileURL:existing] isEqualToString:displayName]&&[existingSize isEqualToNumber:sourceSize]){duplicate=YES;break;}}}
            if(duplicate){@synchronized(self){self.lastDuplicateCount++;self.completedCount++;}[self notifyChange];continue;}
            BOOL scoped=[url startAccessingSecurityScopedResource];__block NSError *error=nil;NSURL *staging=[self.directory URLByAppendingPathComponent:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];NSURL *target=[self.directory URLByAppendingPathComponent:[self safeNameForURL:url]];__block BOOL copied=NO;
            NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];[coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *source){copied=[NSFileManager.defaultManager copyItemAtURL:source toURL:staging error:&error];}];
            NSNumber *regular=nil;if(copied)[staging getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&error];if(copied&&!regular.boolValue){error=[NSError errorWithDomain:@"LocalMediaStore" code:2 userInfo:@{NSLocalizedDescriptionKey:@"所选项目不是普通媒体文件"}];copied=NO;}
            if(scoped)[url stopAccessingSecurityScopedResource];
            if(copied&&[NSFileManager.defaultManager moveItemAtURL:staging toURL:target error:&error]){[imported addObject:target];[self refreshCachedFiles];}
            else {if(!error)error=[NSError errorWithDomain:@"LocalMediaStore" code:3 userInfo:@{NSLocalizedDescriptionKey:@"文件复制失败"}];
                // T17：磁盘不足时明确报错，而不是笼统的“文件复制失败”。
                NSNumber *freeBytes=[NSFileManager.defaultManager attributesOfFileSystemForPath:self.directory.path error:nil][NSFileSystemFreeSize];
                if(sourceSize&&freeBytes&&freeBytes.longLongValue<sourceSize.longLongValue)error=[NSError errorWithDomain:@"LocalMediaStore" code:5 userInfo:@{NSLocalizedDescriptionKey:@"可用空间不足，无法保存此文件"}];
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];[failures addObject:@{@"fileName":url.lastPathComponent?:@"media",@"error":error.localizedDescription?:@"文件复制失败"}];}
            @synchronized(self){self.completedCount++;} [self notifyChange];
        }
        @synchronized(self){self.importing=NO;self.currentFileName=@"";self.lastFailureCount=failures.count;}NSArray *done=[imported copy],*failed=[failures copy];[self notifyChange];if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(done,failed);});
    });
}
- (void)stopAfterCurrentFile {@synchronized(self){if(!self.importing||self.stopRequested)return;self.stopRequested=YES;self.cachedState=@{@"importing":@YES,@"stopRequested":@YES,@"completed":@(self.completedCount),@"total":@(self.totalCount),@"currentFileName":self.currentFileName?:@"",@"failureCount":@(self.lastFailureCount),@"duplicateCount":@(self.lastDuplicateCount)};}dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:LocalMediaStoreDidChangeNotification object:self];});}
- (void)deleteFileAtURL:(NSURL *)url completion:(void (^)(BOOL,NSError *))completion {
    dispatch_async(self.queue,^{NSURL *candidate=url.URLByStandardizingPath;NSNumber *symbolic=nil,*regular=nil;[candidate getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];[candidate getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];NSError *failure=nil;BOOL removed=NO;if(!candidate.isFileURL||![candidate.URLByDeletingLastPathComponent.path isEqualToString:self.directory.path]||symbolic.boolValue||!regular.boolValue)failure=[NSError errorWithDomain:@"LocalMediaStore" code:4 userInfo:@{NSLocalizedDescriptionKey:@"只能删除本机媒体库中的完整文件"}];else removed=[NSFileManager.defaultManager removeItemAtURL:candidate error:&failure];if(removed)[self refreshCachedFiles];[self notifyChange];if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(removed,failure);});});
}
- (NSURL *)bookmarksFileURL {
    return [self.directory URLByAppendingPathComponent:@".bookmarks.plist"];
}
- (void)mountExternalURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *, NSArray<NSDictionary<NSString *, NSString *> *> *))completion {
    NSArray<NSURL *> *items=[[NSArray alloc] initWithArray:urls copyItems:NO];
    dispatch_async(self.queue,^{
        NSURL *plistURL=[self bookmarksFileURL];
        NSMutableArray<NSData *> *bookmarks=[NSMutableArray arrayWithContentsOfURL:plistURL]?:[NSMutableArray array];
        NSMutableArray<NSURL *> *mounted=[NSMutableArray array];
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *failures=[NSMutableArray array];
        for(NSURL *url in items){
            BOOL scoped=[url startAccessingSecurityScopedResource];
            NSError *err=nil;
            NSData *data=[url bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark includingResourceValuesForKeys:nil relativeToURL:nil error:&err];
            if(scoped)[url stopAccessingSecurityScopedResource];
            if(data.length){[bookmarks addObject:data];[mounted addObject:url];}
            else {[failures addObject:@{@"fileName":url.lastPathComponent?:@"media",@"error":err.localizedDescription?:@"无法创建外部引用书签"}];}
        }
        [bookmarks writeToURL:plistURL atomically:YES];
        [self notifyChange];
        if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(mounted.copy,failures.copy);});
    });
}
- (NSArray<NSURL *> *)mountedBookmarkURLsSnapshot {
    NSArray<NSData *> *bookmarks=[NSArray arrayWithContentsOfURL:[self bookmarksFileURL]]?:@[];
    NSMutableArray<NSURL *> *resolved=[NSMutableArray array];
    for(NSData *data in bookmarks){
        if(![data isKindOfClass:NSData.class])continue;
        BOOL stale=NO;
        NSURL *u=[NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
        if(u)[resolved addObject:u];
    }
    return resolved.copy;
}
- (void)removeBookmarkForURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    NSURL *target=url.URLByStandardizingPath;
    dispatch_async(self.queue,^{
        NSURL *plistURL=[self bookmarksFileURL];
        NSMutableArray<NSData *> *bookmarks=[NSMutableArray arrayWithContentsOfURL:plistURL]?:[NSMutableArray array];
        BOOL removed=NO;
        NSMutableArray<NSData *> *kept=[NSMutableArray array];
        for(NSData *data in bookmarks){
            BOOL stale=NO;
            NSURL *resolved=[NSURL URLByResolvingBookmarkData:data options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            if(resolved&&[resolved.URLByStandardizingPath.path isEqualToString:target.path]){removed=YES;continue;}
            [kept addObject:data];
        }
        if(removed){[kept writeToURL:plistURL atomically:YES];[self notifyChange];}
        if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(removed);});
    });
}
@end
