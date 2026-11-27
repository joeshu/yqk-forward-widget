#import "HostSecureStore.h"
#import "HostLibraryStore.h"
#import "MediaEpisodeLayout.h"
#import "MediaAdaptationMonitor.h"
#import "HostBackup.h"
#import "MediaPackageImporter.h"
#import "RootViewController_Internal.h"
#import <UserNotifications/UserNotifications.h>

static BOOL CCTVBackupSafePath(NSString *path) {
    if(![path isKindOfClass:NSString.class]||!path.length||path.length>1024||[path hasPrefix:@"/"]||[path containsString:@"\\"]||[path containsString:@":"])return NO;
    for(NSString *part in path.pathComponents)if([part isEqual:@"."]||[part isEqual:@".."]||!part.length)return NO;
    return [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}
static BOOL CCTVBackupServiceID(NSString *identifier) {
    if(!CCTVBackupSafePath(identifier)||identifier.length>128||identifier.pathComponents.count!=1)return NO;
    return [identifier rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet]].location==NSNotFound;
}
static NSError *CCTVBackupResourceError(NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostBackup" code:3 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSArray *CCTVBackupServices(NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;NSMutableArray *result=[NSMutableArray array];NSUInteger total=0;
    NSString *serviceDirectory=[ServiceStore directory];
    for(NSDictionary *raw in [ServiceStore services]) {
        if([raw[@"builtin"] boolValue])continue;
        NSDictionary *service=[ServiceStore resolvedService:raw];NSString *identifier=service[@"id"];
        if(!CCTVBackupServiceID(identifier)){if(error)*error=CCTVBackupResourceError(@"存在无法安全备份的服务标识");return nil;}
        NSMutableDictionary *metadata=[service mutableCopy];[metadata removeObjectsForKeys:@[@"packageRoot",@"archivePath",@"archiveRelativePath"]];
        NSMutableDictionary *files=[NSMutableDictionary dictionary];BOOL packaged=[service[@"manifest"] isKindOfClass:NSDictionary.class];
        if(packaged){
            NSString *base=[[serviceDirectory stringByAppendingPathComponent:identifier] stringByStandardizingPath];
            NSString *package=[service[@"packageRoot"] isKindOfClass:NSString.class]?[service[@"packageRoot"] stringByStandardizingPath]:@"";
            if(![package hasPrefix:[base stringByAppendingString:@"/"]]||![[package stringByResolvingSymlinksInPath] hasPrefix:[[base stringByResolvingSymlinksInPath] stringByAppendingString:@"/"]]){if(error)*error=CCTVBackupResourceError(@"服务包路径不在对应资源目录，无法安全备份");return nil;}
            NSDirectoryEnumerator *enumerator=[fm enumeratorAtPath:package];if(!enumerator){if(error)*error=CCTVBackupResourceError(@"无法读取服务包");return nil;}
            for(NSString *relative in enumerator){
                if(!CCTVBackupSafePath(relative)){if(error)*error=CCTVBackupResourceError(@"服务包包含不支持的文件路径");return nil;}
                NSString *path=[package stringByAppendingPathComponent:relative];NSDictionary *attrs=[fm attributesOfItemAtPath:path error:error];NSString *type=attrs[NSFileType];
                if([type isEqual:NSFileTypeDirectory])continue;
                if(![type isEqual:NSFileTypeRegular]||files.count>=512){if(error)*error=CCTVBackupResourceError(@"服务包包含链接、特殊文件或过多文件");return nil;}
                unsigned long long size=[attrs[NSFileSize] unsignedLongLongValue];if(size>8*1024*1024||size>24*1024*1024-total){if(error)*error=CCTVBackupResourceError(@"脚本资源超过备份容量上限");return nil;}
                NSData *bytes=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];if(!bytes||bytes.length!=size)return nil;total+=bytes.length;files[relative]=[bytes base64EncodedStringWithOptions:0];
            }
            NSString *entry=service[@"manifest"][@"entry"];if(!CCTVBackupSafePath(entry)||!files[entry]){if(error)*error=CCTVBackupResourceError(@"服务入口文件缺失，无法生成完整备份");return nil;}
            metadata[@"packageRelativePath"]=@"package";
        } else {
            NSString *path=[[serviceDirectory stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"py"];NSDictionary *attrs=[fm attributesOfItemAtPath:path error:error];
            if(![attrs[NSFileType] isEqual:NSFileTypeRegular]||[attrs[NSFileSize] unsignedLongLongValue]>8*1024*1024){if(error)*error=CCTVBackupResourceError(@"服务代码不存在或超过备份上限");return nil;}
            NSData *bytes=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];if(!bytes||bytes.length>24*1024*1024-total)return nil;total+=bytes.length;files[@"service.py"]=[bytes base64EncodedStringWithOptions:0];
        }
        if(![NSJSONSerialization isValidJSONObject:metadata]){if(error)*error=CCTVBackupResourceError(@"服务配置无法序列化，请检查资源配置");return nil;}
        [result addObject:@{@"metadata":metadata,@"packaged":@(packaged),@"files":files}];
    }
    return result;
}

@implementation RootViewController (Services)
- (void)openPluginResource:(NSString *)source {
    if([source hasPrefix:@"tvbox:"]){[self openTVBoxCatalog:[source substringFromIndex:6]];return;}
    NSDictionary *service=[self resourceServiceForSource:source];if(!service)return;PluginResourceDetailViewController *page=[PluginResourceDetailViewController new];page.service=service;__weak typeof(self) weakSelf=self;
    page.onToggle=^(NSDictionary *item,BOOL enabled,void(^completion)(NSError *)){[weakSelf changeService:item enabled:enabled completion:completion];};
    page.onRestart=^(NSDictionary *item,void(^completion)(NSError *)){[weakSelf restartMediaService:item completion:completion];};
    page.onExport=^(NSDictionary *item){[weakSelf exportResource:[@"plugin:" stringByAppendingString:item[@"id"]?:@""] format:@"single"];};
    page.onPlaylistDiscovered=^(NSDictionary *item,NSString *url,NSUInteger channelCount){
        RootViewController *owner=weakSelf;if(!owner||![ProfileStore isHTTP:url])return;
        NSURLComponents *parts=[NSURLComponents componentsWithString:url];
        if(![parts.host.lowercaseString isEqual:@"127.0.0.1"]||parts.port.integerValue!=[item[@"port"] integerValue]||parts.query.length||parts.fragment.length)return;
        NSMutableDictionary *metadata=[@{@"managedServiceID":item[@"id"]?:@""} mutableCopy];
        if(![ProfileStore metadata:url][@"name"])metadata[@"name"]=item[@"name"]?:@"本机直播服务";
        [ProfileStore update:url values:metadata];
        if(!owner.subscriptionURLs)owner.subscriptionURLs=[NSMutableSet set];
        [owner.subscriptionURLs addObject:url];
        [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:owner.subscriptionURLs.allObjects] forKey:@"subscriptions"];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:url];
        [owner logPluginLine:[NSString stringWithFormat:@"已验证节目单并加入订阅 · %@ · %lu 个频道",parts.path?:@"/",(unsigned long)channelCount] identifier:item[@"id"] name:item[@"name"]];
        [owner refreshConfigurationPage];
        [owner fetchSubscription:url silent:YES];
    };
    page.onUse=^(NSDictionary *item,NSString *kind){[weakSelf usePluginService:item kind:kind];};
    page.onLog=^(NSDictionary *item){[weakSelf openDiagnosticLogForIdentifier:item[@"id"] name:item[@"name"]];};page.onEdit=^(NSDictionary *item){[weakSelf openServiceEditorForService:item];};page.onRemove=^(NSDictionary *item){RootViewController *owner=weakSelf;if([PyHost isManagedServiceIdentifier:item[@"id"]]){[owner showServiceError:@"请先停止此资源服务，再移除代码和配置。"];return;}[ServiceStore remove:item[@"id"]];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    page.onUpdate=^(NSDictionary *item){RootViewController *owner=weakSelf;if(!owner)return;NSURL *updateURL=CCTVURLFromPossiblyUnescapedString([item[@"url"] isKindOfClass:NSString.class]?item[@"url"]:@"");if(!updateURL){[owner showServiceError:@"此资源缺少有效的更新地址"];return;}[owner downloadPackageURL:updateURL headers:item[@"importHeaders"] completion:^(NSDictionary *value,NSError *error){[weakSelf acceptImportedMedia:value error:error];}];};
    __weak PluginResourceDetailViewController *weakPage=page;
    page.onRollback=^(NSDictionary *item){RootViewController *owner=weakSelf;dispatch_block_t rollback=^{NSError *error=nil;NSDictionary *restored=[ServiceStore rollbackImportedService:item error:&error];if(!restored){[owner showServiceError:error.localizedDescription];return;}weakPage.service=restored;[weakPage.tableView reloadData];[owner refreshConfigurationPage];};if([PyHost isManagedServiceIdentifier:item[@"id"]])[owner changeService:item enabled:NO completion:^(NSError *error){if(error)[owner showServiceError:error.localizedDescription];else rollback();}];else rollback();};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openServiceEditorForService:(NSDictionary *)service {
    ServiceEditorViewController *editor=[ServiceEditorViewController new];editor.service=service;__weak typeof(self) weakSelf=self;
    editor.onApplyService=^(NSDictionary *previous,NSDictionary *updated,void(^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previous to:updated completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    editor.onSave=^{[weakSelf refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)applyServiceConfigurationFrom:(NSDictionary *)previous to:(NSDictionary *)updated completion:(void (^)(NSError * _Nullable))completion {
    NSInteger requestedPort=[updated[@"port"] integerValue];
    for(NSDictionary *other in [ServiceStore services])if(![other[@"id"] isEqual:updated[@"id"]]&&[other[@"port"] integerValue]==requestedPort&&[PyHost isManagedServiceIdentifier:other[@"id"]]){
        NSString *message=[NSString stringWithFormat:@"端口 %ld 正由“%@”使用。已保留当前服务运行状态；请选择其他端口。",(long)requestedPort,other[@"name"]?:other[@"id"]];
        if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:6 userInfo:@{@"NSLocalizedDescriptionKey":message}]);return;
    }
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:previous];
    __weak typeof(self) weakSelf=self;
    [self changeService:previous enabled:NO completion:^(NSError *stopError){
        RootViewController *owner=weakSelf;if(!owner){if(completion)completion(stopError?:[NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);return;}
        if(stopError){if(completion)completion(stopError);return;}
        [ServiceStore save:updated];[owner refreshConfigurationPage];
        [owner changeService:updated enabled:YES completion:^(NSError *startError){
            NSError *reportedError=startError;
            if(startError){NSMutableDictionary *info=[startError.userInfo mutableCopy]?:[NSMutableDictionary dictionary];info[@"CCTVHostServiceConfigurationSaved"]=@YES;reportedError=[NSError errorWithDomain:startError.domain code:startError.code userInfo:info];}
            if(completion)completion(reportedError);
        }];
    }];
}
- (void)usePluginService:(NSDictionary *)item kind:(NSString *)kind {
    if(!item||!kind.length)return;
    NSString *liveURL=[ServiceStore subscriptionURLForService:item];
    if([kind isEqual:@"live"]&&!liveURL.length){for(NSString *candidate in self.subscriptionURLs){NSDictionary *provider=[self localServiceForURL:[NSURL URLWithString:candidate]];if([provider[@"id"] isEqual:item[@"id"]]){liveURL=candidate;break;}}if(!liveURL.length){[self openServiceEditorForService:item];return;}}
    [self changeService:item enabled:YES completion:^(NSError *error){if(error){[self showServiceError:error.localizedDescription];return;}if([kind isEqual:@"vod"]||[kind isEqual:@"configuration"]){[NSUserDefaults.standardUserDefaults setObject:item[@"id"] forKey:@"selectedMediaSource"];[self.navigationController popToViewController:self animated:NO];[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)self.tabPages[@2];if([kind isEqual:@"configuration"])[browser showConfigurationForSource:item];else [browser openSourceIdentifier:item[@"id"]?:@""];return;}NSString *url=[ServiceStore subscriptionURLForService:item]?:liveURL;if(!url.length){[self showServiceError:@"服务已启动，但尚未发现可读取的直播列表路径。请编辑此资源的直播列表路径后重试。"];return;}NSMutableDictionary *metadata=[@{@"managedServiceID":item[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:url][@"name"])[metadata addEntriesFromDictionary:@{@"name":item[@"name"]?:@"本机直播服务"}];[ProfileStore update:url values:metadata];if(![self.subscriptionURLs containsObject:url]){[self.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];}[self.navigationController popToViewController:self animated:NO];[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[1]];self.activeSource=url;self.title=@"订阅直播";[self fetchSubscription:url silent:NO];}];
}
- (void)subscribeLiveFromCatalog:(NSDictionary *)live catalogID:(NSString *)identifier {
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];NSString *url=[self stableURLKey:live[@"url"]];
    if(!catalog||!url.length||![live[@"supported"] boolValue]){[self showServiceError:@"这条直播清单无法从该资源合集中加载"];return;}
    BOOL belongs=NO;for(NSDictionary *entry in [TVBoxCatalogStore liveSourcesInCatalog:catalog])if([[self stableURLKey:entry[@"url"]] isEqual:url]){belongs=YES;break;}
    if(!belongs){[self showServiceError:@"直播清单与所选资源合集不匹配"];return;}

    NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"直播合集";NSString *liveName=[live[@"name"] isKindOfClass:NSString.class]?live[@"name"]:@"直播列表";
    NSMutableDictionary *metadata=[@{@"name":[NSString stringWithFormat:@"%@ · %@",catalogName,liveName],@"tvboxCatalogID":identifier,@"tvboxLiveEntryName":liveName,@"userAgent":live[@"ua"]?:@""} mutableCopy];
    if([live[@"inlinePlaylist"] isKindOfClass:NSString.class])metadata[@"inlinePlaylist"]=live[@"inlinePlaylist"];
    [ProfileStore update:url values:metadata];if(![self.subscriptionURLs containsObject:url])[self.subscriptionURLs addObject:url];
    [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"selectedMediaCatalogID"];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaSource"];
    [NSUserDefaults.standardUserDefaults setObject:url forKey:[NSString stringWithFormat:@"tvboxLiveSelection.%@",identifier]];
    [self refreshConfigurationPage];if(self.navigationController.topViewController!=self)[self.navigationController popToViewController:self animated:NO];
    [self selectBottomTab:(id)self.bottomBar.arrangedSubviews[1]];self.activeSource=url;self.title=@"订阅直播";[self fetchSubscription:url silent:NO];
}
- (void)openTVBoxCatalog:(NSString *)identifier {
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    TVBoxCatalogViewController *page=[TVBoxCatalogViewController new];page.catalog=catalog;__weak typeof(self) weakSelf=self;
    page.serviceForSite=^NSDictionary *(NSDictionary *site){
        NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
        NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
        NSDictionary *headers=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{};
        NSString *playURL=[site[@"playUrl"] isKindOfClass:NSString.class]?site[@"playUrl"]:@"";
        for(NSDictionary *service in [ServiceStore services]){
            NSString *serviceExt=[service[@"manifest"][@"options"] description]?:@"";
            NSDictionary *savedHeaders=service[@"tvboxSiteHeader"]?:service[@"importHeaders"]?:@{};
            NSString *savedPlayURL=[service[@"tvboxPlayURL"] isKindOfClass:NSString.class]?service[@"tvboxPlayURL"]:@"";
            if(api.length&&[service[@"url"] isEqual:api]&&[serviceExt isEqual:ext]&&[savedHeaders isEqual:headers]&&[savedPlayURL isEqual:playURL])return service;
        }
        return nil;
    };
    page.onUseImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[owner usePluginService:service kind:kind];};
    page.onOpenImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(owner)[owner openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]?:@""]];};
    page.onImportSite=^(NSDictionary *site,BOOL browseAfterImport){NSMutableDictionary *scoped=[site mutableCopy];scoped[@"tvboxCatalogID"]=identifier;[weakSelf importTVBoxSite:scoped browseAfterImport:browseAfterImport];};
    __weak TVBoxCatalogViewController *weakPage=page;page.onImportCompatibleContents=^{[weakSelf bulkImportTVBoxCatalog:identifier page:weakPage];};
     page.onUseNativeSite=^(NSDictionary *site){RootViewController *owner=weakSelf;if(!owner)return;NSString *apiKind=site[@"apiKind"]?:@"",*protocol=[apiKind isEqual:@"maccms-api"]?@"maccms-api":([apiKind isEqual:@"douban-index"]?@"douban-index":([apiKind isEqual:@"jar-bridge"]?@"jar-bridge":@"tvbox-api"));NSString *sourceID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalog[@"id"]?:@"",site[@"key"]?:@""];[NSUserDefaults.standardUserDefaults setObject:sourceID forKey:@"selectedMediaSource"];[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser openSourceIdentifier:sourceID];};
    page.onExportCatalog=^(NSString *format){RootViewController *owner=weakSelf;if(owner)[owner exportResource:[@"tvbox:" stringByAppendingString:identifier] format:[format isEqual:@"zip"]?@"catalog-zip":@"catalog-json"];};
    page.onExportSingleResource=^(NSDictionary *resource,NSString *kind,NSUInteger index){RootViewController *owner=weakSelf;if(!owner)return;NSString *scope=[@"tvbox:" stringByAppendingString:identifier];[owner exportCatalogSingleResource:scope resource:resource kind:kind index:index];};
    page.onSubscribeLive=^(NSDictionary *live){RootViewController *owner=weakSelf;if(owner)[owner subscribeLiveFromCatalog:live catalogID:identifier];};
    page.onRemove=^{RootViewController *owner=weakSelf;[TVBoxCatalogStore removeCatalog:identifier];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)bulkImportTVBoxCatalog:(NSString *)identifier page:(TVBoxCatalogViewController *)page {
    if(self.tvboxCatalogBulkImporter){[self showServiceError:@"这份合集的批量导入仍在进行中"];return;}
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
    NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];
    NSMutableArray *pending=[NSMutableArray array];NSUInteger alreadyImported=0,nativeCount=0;
    NSArray *services=[ServiceStore services];
    for(NSDictionary *site in sites){
        if(![site[@"supported"] boolValue])continue;
        if([site[@"apiKind"] isEqual:@"tvbox-api"]||[site[@"apiKind"] isEqual:@"maccms-api"]||[site[@"apiKind"] isEqual:@"douban-index"]||[site[@"apiKind"] isEqual:@"jar-bridge"]){nativeCount++;continue;}
        if(![site[@"apiKind"] isEqual:@"script"])continue;
        NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"",*ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
        BOOL exists=NO;
        for(NSDictionary *service in services){NSString *serviceExt=[service[@"manifest"][@"options"] description]?:@"";NSDictionary *siteHeaders=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{},*savedHeaders=service[@"tvboxSiteHeader"]?:service[@"importHeaders"]?:@{};NSString *playURL=[site[@"playUrl"] isKindOfClass:NSString.class]?site[@"playUrl"]:@"";if(api.length&&[service[@"url"] isEqual:api]&&[serviceExt isEqual:ext]&&[savedHeaders isEqual:siteHeaders]&&[(service[@"tvboxPlayURL"]?:@"") isEqual:playURL]){exists=YES;break;}}
        if(exists)alreadyImported++;else[pending addObject:site];
    }
    NSUInteger supportedLiveCount=0;for(NSDictionary *live in lives)if([live[@"supported"] boolValue])supportedLiveCount++;
     if(!pending.count){[self refreshConfigurationPage];[(MediaBrowserViewController *)self.tabPages[@2] refreshSources];if(page)[page.tableView reloadData];UIAlertController *done=[UIAlertController alertControllerWithTitle:@"合集内容已就绪" message:[NSString stringWithFormat:@"原生接口与索引：%lu 个可按需浏览\n已保存的脚本站点：%lu 个\n直播清单：%lu 个，仍留在合集内，按需选择后才加载",(unsigned long)nativeCount,(unsigned long)alreadyImported,(unsigned long)supportedLiveCount] preferredStyle:UIAlertControllerStyleAlert];[done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:done animated:YES completion:nil];return;}
    TVBoxCatalogBulkImporter *importer=[TVBoxCatalogBulkImporter new];self.tvboxCatalogBulkImporter=importer;
    NSUInteger total=pending.count;UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在整包导入影视站点" message:[NSString stringWithFormat:@"准备检查 %lu 个站点…\n%lu 个直播清单保留在合集内，不会整包订阅。导入不会启动脚本。",(unsigned long)total,(unsigned long)supportedLiveCount] preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakProgress=progress;__weak TVBoxCatalogViewController *weakPage=page;__weak TVBoxCatalogBulkImporter *weakImporter=importer;
    [progress addAction:[UIAlertAction actionWithTitle:@"取消批量导入" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;TVBoxCatalogBulkImporter *active=weakImporter;if(active&&owner.tvboxCatalogBulkImporter==active)[active cancel];weakProgress.message=@"正在停止当前下载并保留已完成项目…";}]];
    importer.onProgress=^(NSUInteger completed,NSUInteger totalCount,NSUInteger succeeded,NSUInteger failed,NSString *current){if(!weakProgress)return;if(weakImporter.downloadLimitReached){weakProgress.message=@"累计下载达到 512 MiB 上限，正在停止并保存已完成项目…";return;}weakProgress.message=[NSString stringWithFormat:@"%lu / %lu · 已识别 %lu · 失败 %lu\n当前：%@\n导入不会执行脚本。",(unsigned long)completed,(unsigned long)totalCount,(unsigned long)succeeded,(unsigned long)failed,current?:@"准备中"];};
    [self presentViewController:progress animated:YES completion:^{
        [importer importSites:pending catalogID:identifier completion:^(NSArray<NSDictionary *> *imported,NSArray<NSDictionary *> *failures,BOOL cancelled){
            RootViewController *owner=weakSelf;if(!owner)return;owner.tvboxCatalogBulkImporter=nil;
            NSMutableSet *ports=[NSMutableSet set];for(NSDictionary *service in [ServiceStore services]){NSInteger port=[service[@"port"] integerValue];if(port>0)[ports addObject:@(port)];}
            NSInteger nextPort=18780;
            for(NSDictionary *service in imported){NSMutableDictionary *saved=[service mutableCopy];while([ports containsObject:@(nextPort)]&&nextPort<65535)nextPort++;if(nextPort<65535){saved[@"port"]=@(nextPort);[ports addObject:@(nextPort)];nextPort++;}[ServiceStore save:saved];}
            [owner refreshConfigurationPage];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser refreshSources];if(weakPage)[weakPage.tableView reloadData];
            NSUInteger native=nativeCount,skipped=alreadyImported;
             NSMutableString *message=[NSMutableString stringWithFormat:@"原生接口与索引：%lu 个可按需浏览\n脚本站点加入：%lu 个\n已存在脚本：%lu 个\n直播清单：%lu 个继续保留在合集内，点选后才加载",(unsigned long)native,(unsigned long)imported.count,(unsigned long)skipped,(unsigned long)supportedLiveCount];
            if(failures.count)[message appendFormat:@"\n未识别或下载失败：%lu 个，仍保留在合集中。",(unsigned long)failures.count];
            if(cancelled)[message appendString:@"\n批量导入已取消；已经完成的项目已保存。"];
            if(importer.downloadLimitReached)[message appendString:@"\n累计下载达到 512 MiB 安全上限；已经完成的项目已保存。"];
            NSString *summaryTitle=importer.downloadLimitReached?@"已达到批量下载上限":(cancelled?@"批量导入已停止":@"整包内容已加入");
            UIAlertController *summary=[UIAlertController alertControllerWithTitle:summaryTitle message:message preferredStyle:UIAlertControllerStyleAlert];[summary addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            if(owner.presentedViewController==weakProgress)[weakProgress dismissViewControllerAnimated:YES completion:^{[owner presentViewController:summary animated:YES completion:nil];}];else[owner presentViewController:summary animated:YES completion:nil];
        }];
    }];
}
- (void)downloadPackageURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    [self downloadPackageURL:url headers:nil runtimeHint:nil completion:completion];
}
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary *,NSError *))completion {
    [self downloadPackageURL:url headers:headers runtimeHint:nil completion:completion];
}
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers runtimeHint:(NSString *)runtimeHint completion:(void (^)(NSDictionary *,NSError *))completion {
    if(self.packageDownloader){[self.packageDownloader cancel];self.pendingTVBoxSiteName=nil;self.pendingTVBoxExt=nil;}
    MediaPackageDownloader *downloader=[MediaPackageDownloader new];self.packageDownloader=downloader;
    NSString *title=[runtimeHint isEqual:@"node"]?@"导入 Node.js Mobile 资源":([runtimeHint isEqual:@"python"]?@"导入 Python Spider":@"导入影视 / 插件资源");UIAlertController *progress=[UIAlertController alertControllerWithTitle:title message:@"准备下载…" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakProgress=progress;__block BOOL delivered=NO;__block NSString *lastStage=nil;NSString *traceID=NSUUID.UUID.UUIDString.lowercaseString;
    [RuntimeDiagnostics.shared recordEvent:@"resource_import_started" category:@"import" fields:@{@"correlation_id":traceID, @"source_host":url.host?:@"", @"source_extension":url.pathExtension?:@""}];
    void(^finish)(NSDictionary *,NSError *)=^(NSDictionary *service,NSError *error){
        RootViewController *owner=weakSelf;if(delivered)return;delivered=YES;
        if(!owner||owner.packageDownloader!=downloader){if(service)[ServiceStore remove:service[@"id"]];return;}
        owner.packageDownloader=nil;owner.navigationItem.prompt=nil;
        [RuntimeDiagnostics.shared recordEvent:service?@"resource_import_succeeded":@"resource_import_failed" category:@"import" fields:@{@"correlation_id":traceID, @"service_id":service[@"id"]?:@"", @"stage":lastStage?:@"download", @"configuration_state":service[@"configurationState"]?:@"", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];
        dispatch_block_t done=^{
            if(error&&error.code!=NSURLErrorCancelled){
                if(owner.pendingTVBoxSiteName.length){
                    if(completion)completion(nil,error);
                    return;
                }
                UIAlertController *failure=[UIAlertController alertControllerWithTitle:@"资源导入失败" message:[NSString stringWithFormat:@"%@\n%@",lastStage?:@"下载阶段",error.localizedDescription?:@"请检查网络后重试"] preferredStyle:UIAlertControllerStyleAlert];
                [failure addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){if(completion)completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
                [failure addAction:[UIAlertAction actionWithTitle:@"重新下载并校验" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner downloadPackageURL:url headers:headers runtimeHint:runtimeHint completion:completion];}]];
                [owner presentViewController:failure animated:YES completion:nil];return;
            }
            if(completion)completion(service,error);
        };
        if(owner.presentedViewController==weakProgress)[weakProgress dismissViewControllerAnimated:YES completion:done];else done();
    };
    [progress addAction:[UIAlertAction actionWithTitle:@"取消下载" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[downloader cancel];finish(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
    downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){if(delivered||weakSelf.packageDownloader!=downloader)return;if(![lastStage isEqual:stage]){lastStage=stage;[RuntimeDiagnostics.shared recordEvent:@"resource_import_stage" category:@"import" fields:@{@"correlation_id":traceID, @"stage":stage, @"received_bytes":@(received), @"expected_bytes":@(expected)}];}NSString *amount=expected>0?[NSString stringWithFormat:@"%.2f / %.2f MB · %ld%%",received/1048576.0,expected/1048576.0,(long)MIN(100,received*100/expected)]:[NSString stringWithFormat:@"已接收 %.2f MB",received/1048576.0];weakProgress.message=[NSString stringWithFormat:@"%@\n%@\n导入完成后可选择启动，当前不会执行脚本。",stage,amount];};
    dispatch_block_t show=^{RootViewController *owner=weakSelf;if(!owner||owner.packageDownloader!=downloader||delivered)return;[owner presentViewController:progress animated:YES completion:^{if(!delivered)[downloader importURL:url headers:headers runtimeHint:runtimeHint completion:finish];}];};
    if(self.presentedViewController)[self.presentedViewController dismissViewControllerAnimated:YES completion:show];else show();
}
- (void)activateNativeFallbackForTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport {
    // 真实反馈站点打开情况：不再将失败或未下载的脚本站点静默伪装为统一采集源
    NSString *siteName=[site[@"name"] isKindOfClass:NSString.class]&&[site[@"name"] length]?site[@"name"]:(site[@"key"]?:@"影视站点");
    NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
    NSString *msg=[NSString stringWithFormat:@"站点「%@」未能加载真实脚本（%@），已禁用跨站点兜底界面以真实反馈站点状态。",siteName,api];
    [self showServiceError:msg];
}
- (void)promptSubscriptionTokenForTVBoxSite:(NSDictionary *)site rawAPI:(NSString *)rawAPI browseAfterImport:(BOOL)browseAfterImport reason:(NSString *)reason {
    NSString *siteName=[site[@"name"] isKindOfClass:NSString.class]&&[site[@"name"] length]?site[@"name"]:@"此站点";
    NSString *message=reason.length?[NSString stringWithFormat:@"%@\n\n站点「%@」需要有效的订阅令牌。粘贴 token 或完整订阅链接，令牌将保存到本机钥匙串。",reason,siteName]:[NSString stringWithFormat:@"站点「%@」需要订阅令牌。粘贴 token 或完整订阅链接；令牌会保存到本机钥匙串供后续站点使用。",siteName];
    UIAlertController *credential=[UIAlertController alertControllerWithTitle:@"Hawk iOS 资源访问令牌" message:message preferredStyle:UIAlertControllerStyleAlert];
    [credential addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"token 或完整订阅链接";field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.clearButtonMode=UITextFieldViewModeWhileEditing;}];
    [credential addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakCredential=credential;
    [credential addAction:[UIAlertAction actionWithTitle:@"保存并重试该站点" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(!owner)return;NSString *entered=CCTVTVBoxTokenFromInput(weakCredential.textFields.firstObject.text?:@"");if(!entered.length){[owner showServiceError:@"请输入有效的订阅令牌或完整订阅链接"];return;}if(!CCTVTVBoxSaveSubscriptionToken(entered)){[owner showServiceError:@"令牌未能保存到本机钥匙串，请检查设备设置后重试"];return;}NSString *resolvedURL=CCTVTVBoxURLByResolvingToken(rawAPI,entered);if(!resolvedURL.length){[owner showServiceError:@"无法将订阅令牌应用到此站点地址"];return;}NSMutableDictionary *resolvedSite=[site mutableCopy];resolvedSite[@"api"]=resolvedURL;dispatch_async(dispatch_get_main_queue(),^{[owner importTVBoxSite:resolvedSite browseAfterImport:browseAfterImport];});}]];
    [self presentViewController:credential animated:YES completion:nil];
}
- (void)reportAuthenticTVBoxSiteFailure:(NSDictionary *)site rawAPI:(NSString *)rawAPI url:(NSURL *)downloadURL error:(NSError *)error browseAfterImport:(BOOL)browseAfterImport {
    if(error.code==NSURLErrorCancelled)return;
    NSString *siteName=[site[@"name"] isKindOfClass:NSString.class]&&[site[@"name"] length]?site[@"name"]:(site[@"key"]?:@"影视站点");
    NSString *host=downloadURL.host?:@"远端站点";
    NSString *reason=error.localizedDescription?:@"远端未返回有效脚本内容";
    NSString *statusText=[NSString stringWithFormat:@"站点「%@」打开失败（%@）：%@",siteName,host,reason];
    NSString *alertMessage=[NSString stringWithFormat:@"%@\n\n请求地址：%@\n（已关闭统一兜底源，真实反馈该站点实际响应）",reason,[HostLogRedactor redactText:downloadURL.absoluteString?:rawAPI?:@""]];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ · 打开失败",siteName] message:alertMessage preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;
    if([host.lowercaseString containsString:@"lytvs.top"]&&([reason containsString:@"403"]||[reason containsString:@"401"])){
        NSString *templateAPI=[rawAPI containsString:CCTVTVBoxTokenPlaceholder]?rawAPI:[NSString stringWithFormat:@"%@?tk=%@",[[downloadURL.absoluteString componentsSeparatedByString:@"?"] firstObject]?:rawAPI,CCTVTVBoxTokenPlaceholder];
        [alert addAction:[UIAlertAction actionWithTitle:@"更换订阅令牌并重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[weakSelf promptSubscriptionTokenForTVBoxSite:site rawAPI:templateAPI browseAfterImport:browseAfterImport reason:statusText];}]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"重试该站点" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[weakSelf importTVBoxSite:site browseAfterImport:browseAfterImport];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importTVBoxSite:(NSDictionary *)site { [self importTVBoxSite:site browseAfterImport:NO]; }
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport {
    NSString *siteKey=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"";
    NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
    NSString *originalAPI=api;
    if(browseAfterImport&&(siteKey.length||api.length)){
        for(NSDictionary *existing in [ServiceStore services]){
            if(![ServiceStore isVODMediaService:existing])continue;
            NSArray *keys=[existing[@"tvboxSiteKeys"] isKindOfClass:NSArray.class]?existing[@"tvboxSiteKeys"]:@[];
            BOOL matchesKey=siteKey.length&&([existing[@"tvboxSiteKey"] isEqual:siteKey]||[keys containsObject:siteKey]);
            BOOL matchesURL=api.length&&[existing[@"url"] isKindOfClass:NSString.class]&&[existing[@"url"] isEqual:api];
            if((matchesKey&&[existing[@"tvboxCatalogID"] isEqual:site[@"tvboxCatalogID"]])||(matchesURL&&!siteKey.length)){
                [self usePluginService:existing kind:@"vod"];
                return;
            }
        }
    }
    NSString *catalogID=[site[@"tvboxCatalogID"] isKindOfClass:NSString.class]?site[@"tvboxCatalogID"]:@"";
    NSDictionary *catalog=catalogID.length?[TVBoxCatalogStore catalogForID:catalogID]:nil;
    NSString *bundle=catalog[@"bundleMetadata"][@"bundleDirectory"];
    NSString *local=[site[@"bundledScript"] isKindOfClass:NSString.class]?site[@"bundledScript"]:nil;
    if(bundle.length&&local.length&&[catalog[@"bundleMetadata"][@"companionFiles"] containsObject:local]){
        NSURL *file=[NSURL fileURLWithPath:[bundle stringByAppendingPathComponent:local]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
            NSError *error=nil;
            NSDictionary *service=[MediaPackageImporter importFile:file error:&error];
            NSMutableDictionary *updated=[service mutableCopy];
            if(updated){
                updated[@"tvboxCatalogID"]=catalogID;
                updated[@"tvboxSiteKey"]=siteKey;
                NSMutableDictionary *manifest=[updated[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];
                NSString *siteExt=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
                NSString *siteName=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";
                if(siteExt.length)manifest[@"options"]=siteExt;
                if(siteName.length){manifest[@"name"]=siteName;updated[@"name"]=siteName;}
                updated[@"manifest"]=manifest;
            }
            dispatch_async(dispatch_get_main_queue(), ^{[self acceptImportedMedia:updated error:error autoBrowse:browseAfterImport];});
        });
        return;
    }
    if([api containsString:CCTVTVBoxTokenPlaceholder]){
        NSString *token=CCTVTVBoxStoredSubscriptionToken();
        if(!token.length){
            [self promptSubscriptionTokenForTVBoxSite:site rawAPI:originalAPI browseAfterImport:browseAfterImport reason:nil];
            return;
        }
        api=CCTVTVBoxURLByResolvingToken(api,token);
        if(!api.length){
            [self showServiceError:[NSString stringWithFormat:@"站点「%@」无法解析订阅令牌地址",site[@"name"]?:@"未命名站点"]];
            return;
        }
        NSMutableDictionary *resolvedSite=[site mutableCopy];resolvedSite[@"api"]=api;site=resolvedSite;
    }
    if(!api.length){[self showServiceError:@"此 TVBox 站点没有可导入的脚本地址"];return;}
    NSURL *downloadURL=CCTVURLFromPossiblyUnescapedString(api);
    if(!downloadURL){
        [self showServiceError:[NSString stringWithFormat:@"站点「%@」脚本地址无效：%@",site[@"name"]?:@"未命名站点",api]];
        return;
    }
    self.pendingTVBoxExt=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";self.pendingTVBoxSiteName=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";
    __weak typeof(self) weakSelf=self;
    NSString *runtimeHint=[[downloadURL pathExtension].lowercaseString isEqual:@"py"]?@"python":nil;
    [self downloadPackageURL:downloadURL headers:site[@"header"] runtimeHint:runtimeHint completion:^(NSDictionary *service,NSError *error){RootViewController *owner=weakSelf;owner.navigationItem.prompt=nil;if(error||!service){owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;[owner reportAuthenticTVBoxSiteFailure:site rawAPI:originalAPI url:downloadURL error:error browseAfterImport:browseAfterImport];return;}NSMutableDictionary *updated=[service mutableCopy];NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"",*name=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";if(ext.length)manifest[@"options"]=ext;if(name.length){manifest[@"name"]=name;updated[@"name"]=name;}updated[@"manifest"]=manifest;updated[@"tvboxSiteKey"]=site[@"key"]?:@"";updated[@"tvboxSiteKeys"]=@[site[@"key"]?:@""];if(site[@"tvboxCatalogID"])updated[@"tvboxCatalogID"]=site[@"tvboxCatalogID"];if(site[@"playUrl"])updated[@"tvboxPlayURL"]=site[@"playUrl"];if(site[@"header"])updated[@"tvboxSiteHeader"]=site[@"header"];owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;[owner acceptImportedMedia:updated error:nil autoBrowse:browseAfterImport];}];
}
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error {
    [self acceptImportedMedia:service error:error autoBrowse:NO];
}
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error autoBrowse:(BOOL)autoBrowse {
    self.navigationItem.prompt=nil;if(error){if(error.code!=NSURLErrorCancelled)[self showServiceError:error.localizedDescription];return;}
    if(!service){[self showServiceError:@"资源导入失败"];return;}
    NSString *sourceURL=[service[@"url"] isKindOfClass:NSString.class]?service[@"url"]:@"";
    NSDictionary *existing=nil;
    if(sourceURL.length)for(NSDictionary *candidate in [ServiceStore services])if(![candidate[@"builtin"] boolValue]&&![candidate[@"id"] isEqual:service[@"id"]]&&[candidate[@"url"] isEqual:sourceURL]){existing=candidate;break;}
    if(existing){
        BOOL unchanged=[service[@"downloadChecksum"] length]&&[service[@"downloadChecksum"] isEqual:existing[@"downloadChecksum"]]&&[(service[@"configDownloadChecksum"]?:@"") isEqual:(existing[@"configDownloadChecksum"]?:@"")]&&[(service[@"configurationState"]?:@"") isEqual:(existing[@"configurationState"]?:@"")]&&[(service[@"configContentChecksum"]?:@"") isEqual:(existing[@"configContentChecksum"]?:@"")];
        for(NSString *key in @[@"runtime",@"protocol",@"moduleType",@"configEntry"])unchanged=unchanged&&[(service[@"manifest"][key]?:@"") isEqual:(existing[@"manifest"][key]?:@"")];
        if(unchanged){
            [ServiceStore remove:service[@"id"]];UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"未发现资源更新" message:@"本次主脚本、配套配置校验和运行类型与已有资源一致。" preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [notice addAction:[UIAlertAction actionWithTitle:autoBrowse?@"启动并浏览资源":@"打开已有资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:existing]?@"vod":([ServiceStore subscriptionURLForService:existing].length?@"live":@"configuration");[self usePluginService:existing kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existing[@"id"]]];}]];
            [self presentViewController:notice animated:YES completion:nil];return;
        }
        NSString *identifier=[service[@"id"] copy];NSString *existingID=[existing[@"id"] copy];
        UIAlertController *duplicate=[UIAlertController alertControllerWithTitle:@"发现相同来源" message:@"检测到已导入过这个完整资源地址（含查询参数）。更新会先停止该服务，保留服务 ID、账号数据、端口、配置和日志，并保留上一版代码供切回。也可打开原资源或另存副本。" preferredStyle:UIAlertControllerStyleAlert];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"更新已有资源（保留配置）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            dispatch_block_t update=^{NSError *error=nil;NSDictionary *updated=[ServiceStore replaceImportedService:existing withService:service error:&error];if(!updated){[ServiceStore remove:identifier];[self showServiceError:error.localizedDescription];return;}[self refreshConfigurationPage];if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:updated]?@"vod":([ServiceStore subscriptionURLForService:updated].length?@"live":@"configuration");[self usePluginService:updated kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existingID]];};
            if([PyHost isManagedServiceIdentifier:existingID])[self changeService:existing enabled:NO completion:^(NSError *error){if(error){[ServiceStore remove:identifier];[self showServiceError:error.localizedDescription];}else update();}];else update();
        }]];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"取消本次导入" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[ServiceStore remove:identifier];}]];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"保留为独立副本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self saveImportedMedia:service autoBrowse:autoBrowse];}]];
        [duplicate addAction:[UIAlertAction actionWithTitle:autoBrowse?@"启动并浏览已有资源":@"打开已有资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[ServiceStore remove:identifier];if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:existing]?@"vod":([ServiceStore subscriptionURLForService:existing].length?@"live":@"configuration");[self usePluginService:existing kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existingID]];}]];
        [self presentViewController:duplicate animated:YES completion:nil];return;
    }
    [self saveImportedMedia:service autoBrowse:autoBrowse];
}
- (void)saveImportedMedia:(NSDictionary *)service {
    [self saveImportedMedia:service autoBrowse:NO];
}
- (void)saveImportedMedia:(NSDictionary *)service autoBrowse:(BOOL)autoBrowse {
    [ServiceStore save:service];[self refreshConfigurationPage];
    NSArray *verifiedLocal=[service[@"manifest"][@"verifiedLocalChecksums"] isKindOfClass:NSArray.class]?service[@"manifest"][@"verifiedLocalChecksums"]:@[];
    NSString *verification=([service[@"downloadChecksum"] length]&&[service[@"configurationState"] isEqual:@"verified"])?@"主脚本与配套配置均已通过 MD5 校验。":(verifiedLocal.count?([service[@"downloadChecksum"] length]?[NSString stringWithFormat:@"下载资源及 ZIP 内 %@ 的 MD5 均已通过校验。",[verifiedLocal componentsJoinedByString:@"、"]]:[NSString stringWithFormat:@"ZIP 内已校验：%@。",[verifiedLocal componentsJoinedByString:@"、"]]):([service[@"downloadChecksum"] length]?@"下载资源 MD5 校验已通过。":@"可在资源详情查看校验与配套配置状态。"));
    if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[self usePluginService:service kind:kind];return;}
    NSDictionary *manifest=[service[@"manifest"] isKindOfClass:NSDictionary.class]?service[@"manifest"]:@{};NSString *runtime=[manifest[@"runtime"] isKindOfClass:NSString.class]?manifest[@"runtime"]:([service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"");NSString *protocol=[manifest[@"protocol"] isKindOfClass:NSString.class]?manifest[@"protocol"]:([service[@"protocol"] isKindOfClass:NSString.class]?service[@"protocol"]:@"");NSArray *capabilities=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:([manifest[@"capabilities"] isKindOfClass:NSArray.class]?manifest[@"capabilities"]:@[]);NSString *capabilityStatus=capabilities.count?[NSString stringWithFormat:@"声明能力：%@",[capabilities componentsJoinedByString:@"、"]]:@"能力待测：启动后查询插件的 capabilities()，导入阶段不会执行代码。";NSString *kind=([ServiceStore isVODMediaService:service]?@"影视":([ServiceStore subscriptionURLForService:service].length||[ServiceStore isLiveMediaService:service]?@"直播":@"待启动探测资源类型"));
    NSString *message=[NSString stringWithFormat:@"已检查并导入 %@。\n识别类型：%@ · %@\n资源分类：%@\n%@\n%@",service[@"name"],CCTVImportRuntimeLabel(runtime),CCTVImportProtocolLabel(protocol),kind,capabilityStatus,verification];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"资源已导入" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启动并浏览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[self usePluginService:service kind:kind];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]]];}]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)originForURL:(NSURL *)url {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];if(!c.host.length)return nil;
    c.path=@"";c.query=nil;c.fragment=nil;return c.URL.absoluteString;
}
- (NSDictionary *)localServiceForURL:(NSURL *)url {
    NSString *host=url.host.lowercaseString;
    if(![@[@"127.0.0.1",@"localhost",@"::1",@"[::1]"] containsObject:host])return nil;
    NSInteger port=url.port?url.port.integerValue:([url.scheme.lowercaseString isEqualToString:@"https"]?443:80);
    NSString *sourceKey=url.absoluteString?:@"";NSString *managedID=[ProfileStore metadata:sourceKey][@"managedServiceID"];
    NSArray<NSDictionary *> *services=[ServiceStore services];
    if([managedID isKindOfClass:NSString.class]&&managedID.length)for(NSDictionary *service in services)if([service[@"id"] isEqual:managedID]&&[service[@"port"] integerValue]==port)return service;
    NSMutableArray<NSDictionary *> *matches=[NSMutableArray array];for(NSDictionary *service in services)if([service[@"port"] integerValue]==port)[matches addObject:service];
    if(matches.count==1)return matches.firstObject;
    // A duplicated port is ambiguous. Prefer the only live owner; never start
    // whichever service happens to appear first in persisted configuration.
    NSDictionary *running=nil;for(NSDictionary *service in matches)if([PyHost isRunningServiceIdentifier:service[@"id"]]){if(running)return nil;running=service;}
    return running;
}
- (NSDictionary *)localServiceForChannel:(NSDictionary *)channel URL:(NSURL *)url {
    NSString *host=url.host.lowercaseString;if(![@[@"127.0.0.1",@"localhost",@"::1",@"[::1]"] containsObject:host])return nil;
    NSInteger port=url.port?url.port.integerValue:([url.scheme.lowercaseString isEqualToString:@"https"]?443:80);
    NSMutableDictionary<NSString *,NSDictionary *> *owners=[NSMutableDictionary dictionary];
    for(NSString *source in [ProfileStore orderedSources:CCTVStringArrayValue(channel[@"subscriptionSources"])]){NSString *identifier=[ProfileStore metadata:source][@"managedServiceID"];if(![identifier isKindOfClass:NSString.class]||!identifier.length)continue;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier]&&[service[@"port"] integerValue]==port)owners[identifier]=service;}
    if(owners.count==1)return owners.allValues.firstObject;
    if(owners.count>1){NSDictionary *running=nil;for(NSDictionary *service in owners.allValues)if([PyHost isRunningServiceIdentifier:service[@"id"]]){if(running)return nil;running=service;}if(running)return running;return nil;}
    return [self localServiceForURL:url];
}
- (NSArray<NSString *> *)managedSubscriptionSourcesForService:(NSDictionary *)service excludingURL:(NSString *)url {
    NSString *identifier=[service[@"id"] isKindOfClass:NSString.class]?service[@"id"]:@"";if(!identifier.length)return @[];
    NSMutableArray<NSString *> *matches=[NSMutableArray array];
    for(NSString *source in self.subscriptionURLs){if([source isEqual:url])continue;if([[ProfileStore metadata:source][@"managedServiceID"] isEqual:identifier])[matches addObject:source];}
    return matches;
}
- (LocalServiceReadiness *)readinessForURL:(NSURL *)url service:(NSDictionary *)service {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    BOOL health=[service[@"builtin"] boolValue] || [ServiceStore isMediaService:service];
    if(health)c.path=@"/health";else if(!c.path.length)c.path=[ServiceStore playlistPathForService:service]?:@"/";
    c.query=nil;c.fragment=nil;
    LocalServiceReadiness *readiness=[[LocalServiceReadiness alloc] initWithURL:c.URL timeout:20 requiresHealthJSON:health];readiness.diagnosticContext=@{@"service_id":service[@"id"]?:@"",@"trigger":@"local_channel_playback"};NSString *engine=[service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"python";if(service && [engine isEqualToString:@"python"]){NSString *identifier=[service[@"id"] copy];readiness.failureProvider=^NSError *{return [PyHost startupErrorForServiceIdentifier:identifier];};}return readiness;
}
- (BOOL)startService:(NSDictionary *)service error:(NSError **)error {
    service=[ServiceStore resolvedService:service];
    NSString *entryPath=[ServiceStore codePath:service];
    if([service[@"manifest"] isKindOfClass:NSDictionary.class] && (!entryPath.length || ![NSFileManager.defaultManager fileExistsAtPath:entryPath])){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:8 userInfo:@{NSLocalizedDescriptionKey:@"资源入口文件不存在。已检查当前 App 沙盒中的同一服务目录；请从“资源”重新导入原文件。原服务配置和日志会保留。"}];return NO;}
    NSString *serviceID=service[@"id"];
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:service];
    if([PyHost isRunningServiceIdentifier:serviceID])return YES;
    if([PyHost isManagedServiceIdentifier:serviceID]){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:7 userInfo:@{NSLocalizedDescriptionKey:@"该服务仍有启动中或状态待确认的会话，请先停止并确认清理后重试。"}];return NO;}
    NSInteger port=[service[@"port"] integerValue];if(port<1||port>65535){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:5 userInfo:@{NSLocalizedDescriptionKey:@"服务端口必须是 1 到 65535 之间的有效端口。"}];return NO;}
    if([ServiceStore isMediaService:service]){
        BOOL portBusy=NO;NSMutableSet *usedPorts=[NSMutableSet setWithObjects:@8767,@18770,nil];
        for(NSDictionary *other in [ServiceStore services]){if([other[@"id"] isEqual:serviceID])continue;NSInteger otherPort=[other[@"port"] integerValue];if(otherPort>0)[usedPorts addObject:@(otherPort)];if(otherPort==port)portBusy=YES;}
        if(portBusy||HostLocalPortState((int)port)==1){
            NSInteger nextPort=18780;while(([usedPorts containsObject:@(nextPort)]||HostLocalPortState((int)nextPort)==1)&&nextPort<65535)nextPort++;
            NSMutableDictionary *reassigned=[service mutableCopy];reassigned[@"port"]=@(nextPort);[ServiceStore save:reassigned];service=[ServiceStore resolvedService:reassigned];port=nextPort;
        }
    }
    for(NSDictionary *other in [ServiceStore services])if(![other[@"id"] isEqual:serviceID]&&[other[@"port"] integerValue]==port&&[PyHost isManagedServiceIdentifier:other[@"id"]]){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:6 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"端口 %ld 正由“%@”使用或待清理，请先停止该服务。",(long)port,other[@"name"]?:other[@"id"]]}];return NO;}
    NSString *dataDir=[ServiceStore dataDirectoryForService:service error:error];if(!dataDir.length)return NO;
    NSString *bind=[service[@"lan"] boolValue]?@"0.0.0.0":@"127.0.0.1";NSMutableArray *args=[NSMutableArray array];
    if([ServiceStore isMediaService:service]){
        NSMutableDictionary *runtimeManifest=[service[@"manifest"] mutableCopy];
        NSMutableDictionary *runtimeOptions=[runtimeManifest[@"options"] isKindOfClass:NSDictionary.class]?[runtimeManifest[@"options"] mutableCopy]:nil;
        if([runtimeOptions[@"credentialRef"] boolValue]){
            OSStatus status=errSecSuccess;
            NSData *secret=HostSecureStoreRead(@"media-server",serviceID,&status);
            NSDictionary *credentials=secret?[NSJSONSerialization JSONObjectWithData:secret options:0 error:NULL]:nil;
            if(![credentials isKindOfClass:NSDictionary.class]){
                if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:11 userInfo:@{NSLocalizedDescriptionKey:@"媒体服务器凭据不可用，请解锁设备或重新配置账号。"}];
                return NO;
            }
            [runtimeOptions removeObjectForKey:@"credentialRef"];
            [runtimeOptions addEntriesFromDictionary:credentials];runtimeManifest[@"options"]=runtimeOptions;
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:runtimeManifest options:0 error:error];if(!data)return NO;
        NSString *packageRoot=[service[@"packageRoot"] isKindOfClass:NSString.class]?service[@"packageRoot"]:@"";
        if(!packageRoot.length){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:5 userInfo:@{NSLocalizedDescriptionKey:@"媒体服务缺少有效的包目录配置"}];return NO;}
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%ld",(long)port],@"--bind",bind,@"--package",packageRoot,@"--manifest",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding],@"--data-dir",dataDir]];
    }else if([service[@"builtin"] boolValue]){
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%ld",(long)port],@"--bind",bind,@"--data-dir",dataDir]];
        if(![service[@"id"] isEqual:@"builtin-yangshipin-js"])[args addObjectsFromArray:@[@"--no-engine",@"--cache-mb",@"32",@"--links-per-device",@"2",@"--zap-debounce",@"15",@"--stable-playback"]];
    }else{
        for(NSString *part in [service[@"arguments"]?:@"" componentsSeparatedByString:@"|"]){if(!part.length)continue;NSString *arg=[part stringByReplacingOccurrencesOfString:@"{port}" withString:[NSString stringWithFormat:@"%ld",(long)port]];arg=[arg stringByReplacingOccurrencesOfString:@"{bind}" withString:bind];[args addObject:[arg stringByReplacingOccurrencesOfString:@"{dataDir}" withString:dataDir]];}
    }
    __weak typeof(self) w=self;serviceID=[serviceID copy];NSString *serviceName=[service[@"name"] copy];[PluginLogStore.shared beginRunForIdentifier:serviceID];void(^serviceLogger)(NSString *)=^(NSString *line){if(line.length)[w logPluginLine:line identifier:serviceID name:serviceName];};[PyHost setLogHandler:serviceLogger forServiceIdentifier:serviceID];[NodePluginRuntime.shared setLogHandler:serviceLogger forServiceIdentifier:serviceID];[JSPluginRuntime.shared setLogHandler:serviceLogger forServiceIdentifier:serviceID];
    [self logPluginLine:@"插件启动请求" identifier:serviceID name:serviceName];
    for(NSString *origin in self.readyLocalOrigins.allKeys.copy){NSURL *known=[NSURL URLWithString:origin];if(known.port.integerValue==port)[self.readyLocalOrigins removeObjectForKey:origin];} // This service must prove readiness again.
    if(![PyHost startScriptAtPath:[ServiceStore scriptPath:service] identifier:serviceID port:port dataDir:dataDir arguments:args error:error]){if(error&&*error)[self logPluginLine:(*error).localizedDescription identifier:serviceID name:serviceName];[PluginLogStore.shared finishRunForIdentifier:serviceID status:@"启动失败"];[self clearServiceLogHandlers:serviceID];return NO;}
    [PluginLogStore.shared markRunRunningForIdentifier:serviceID];
    [NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"activePythonService"];
    [self log:@"服务进程启动 %@ · %ld，等待 HTTP 就绪",service[@"name"],(long)port];
    NSString *playlistURL=[ServiceStore subscriptionURLForService:service];
    if(playlistURL.length){
        NSArray<NSString *> *previousSources=[self managedSubscriptionSourcesForService:service excludingURL:playlistURL];
        NSDictionary *newMetadata=[ProfileStore metadata:playlistURL];
        BOOL alreadySubscribed=[self.subscriptionURLs containsObject:playlistURL];
        if(!alreadySubscribed){[self.subscriptionURLs addObject:playlistURL];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];}
        NSMutableDictionary *sourceMetadata=[@{@"managedServiceID":serviceID} mutableCopy];
        if(![newMetadata[@"name"] isKindOfClass:NSString.class]||![newMetadata[@"name"] length]){NSString *previousName=nil;for(NSString *oldSource in previousSources){id candidate=[ProfileStore metadata:oldSource][@"name"];if([candidate isKindOfClass:NSString.class]&&[candidate length]){previousName=candidate;break;}}sourceMetadata[@"name"]=previousName?:serviceName?:@"本机直播服务";}
        if(![newMetadata[@"epgURL"] isKindOfClass:NSString.class]||![newMetadata[@"epgURL"] length])for(NSString *oldSource in previousSources){id configured=[ProfileStore metadata:oldSource][@"epgURL"];if([ProfileStore isHTTP:configured]){sourceMetadata[@"epgURL"]=[ServiceStore rewrittenLoopbackURL:configured forService:service];break;}}if(![newMetadata[@"detectedEPGURL"] isKindOfClass:NSString.class]||![newMetadata[@"detectedEPGURL"] length])for(NSString *oldSource in previousSources){id detected=[ProfileStore metadata:oldSource][@"detectedEPGURL"];if([ProfileStore isHTTP:detected]){sourceMetadata[@"detectedEPGURL"]=[ServiceStore rewrittenLoopbackURL:detected forService:service];break;}}
        [ProfileStore update:playlistURL values:sourceMetadata];
        for(NSString *oldSource in previousSources)[ProfileStore update:oldSource values:@{@"status":@"服务端口或列表路径已变更 · 等待新订阅验证，保留旧频道"}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:playlistURL];
        for(NSString *oldSource in previousSources)[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:oldSource];
        [self logPluginLine:[NSString stringWithFormat:@"服务订阅地址：%@",playlistURL] identifier:serviceID name:serviceName];
        NSString *epg=[ServiceStore epgURLForService:service];
        [self logPluginLine:epg.length?[NSString stringWithFormat:@"节目单地址：%@",CCTVServiceLogAddress(epg)]:@"节目单地址：等待读取订阅清单后识别" identifier:serviceID name:serviceName];
    }else if([service[@"protocol"] isEqual:@"python-http"]){
        [self logPluginLine:@"未发现可用的服务订阅地址：请在服务编辑页配置播放列表路径，启动不会添加猜测地址。" identifier:serviceID name:serviceName];
    }
    for(NSString *source in self.subscriptionURLs.allObjects){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:source]];if([owner[@"id"] isEqualToString:service[@"id"]])[self fetchSubscription:source silent:YES];}
    [self refreshConfigurationPage];
    [self.pluginPage updateRunning:[PyHost isRunningServiceIdentifier:@"builtin-ysp"] subscriptionCount:self.subscriptionURLs.count];return YES;
}
- (void)toggleService:(NSDictionary *)service enabled:(BOOL)enabled {
    [self changeService:service enabled:enabled completion:^(NSError *error){if(error)[self showServiceError:error.localizedDescription];}];
}
- (void)restartMediaService:(NSDictionary *)source completion:(void (^)(NSError *))completion {
    NSString *identifier=source[@"id"]?:@"";NSDictionary *snapshot=nil;
    for(NSDictionary *candidate in ServiceStore.services)if([candidate[@"id"] isEqual:identifier]){snapshot=candidate;break;}
    NSError *(^failure)(NSString *)=^NSError *(NSString *message){return [NSError errorWithDomain:@"CCTVHostServiceRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];};
    if(!snapshot||![snapshot[@"port"] isEqual:source[@"port"]]){if(completion)completion(failure(@"资源已移除或端口已修改，请重新选择来源。"));return;}
    if(!self.serviceOperations)self.serviceOperations=[NSMutableSet set];
    if([self.serviceOperations containsObject:identifier]){if(completion)completion(failure(@"该服务已有启停操作，请等待当前操作完成。"));return;}
    [self.serviceOperations addObject:identifier];
    [RuntimeDiagnostics.shared recordEvent:@"service_recovery_started" category:@"service" fields:@{@"service_id":identifier,@"port":snapshot[@"port"]?:@0,@"trigger":@"user_restart"}];
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        __block NSError *error=nil;BOOL stopped=[PyHost stopServiceIdentifier:identifier error:&error];
        int portState=stopped?HostLocalPortState([snapshot[@"port"] intValue]):-1;
        if(stopped&&portState!=0)error=failure(portState==1?@"旧服务停止后端口仍可访问，已阻止重复启动。请检查是否有其他服务占用该端口。":@"无法确认旧端口已释放，已阻止重复启动。请稍后重试。 ");
        if(!stopped&&!error)error=failure(@"服务停止未确认，已取消重新启动。请查看该服务日志。 ");
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;
            if(!owner){if(completion)completion(error?:failure(@"页面已关闭，重启未完成。"));return;}
            BOOL unchanged=NO;for(NSDictionary *candidate in ServiceStore.services)if([candidate[@"id"] isEqual:identifier]){unchanged=[candidate isEqualToDictionary:snapshot];break;}
            if(stopped){[owner logPluginLine:@"重启前旧服务已停止" identifier:identifier name:snapshot[@"name"]?:identifier];[PluginLogStore.shared finishRunForIdentifier:identifier status:@"重启前已停止"];}
            if(!error&&!unchanged)error=failure(@"重启期间资源配置已变更，已取消启动。请重新选择来源。 ");
            if(!error){[owner clearServiceLogHandlers:identifier];NSError *startError=nil;if(![owner startService:snapshot error:&startError])error=startError?:failure(@"重新启动请求失败，请查看服务日志。 ");}
            [owner.serviceOperations removeObject:identifier];
            [RuntimeDiagnostics.shared recordEvent:@"service_recovery_finished" category:@"service" fields:@{@"service_id":identifier,@"phase":@"start_request_finished",@"http_health_verified":@NO,@"stop_confirmed":@(stopped),@"port_released":@(stopped&&portState==0),@"start_accepted":@(!error),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];
            [owner refreshConfigurationPage];if(completion)completion(error);
        });
    });
}
- (void)changeService:(NSDictionary *)service enabled:(BOOL)enabled completion:(void (^)(NSError *))completion {
    NSString *serviceID=service[@"id"]?:@"";if(!self.serviceOperations)self.serviceOperations=[NSMutableSet set];
    if([self.serviceOperations containsObject:serviceID]){[self refreshConfigurationPage];if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:4 userInfo:@{NSLocalizedDescriptionKey:@"该服务正在启停，请稍候。"}]);return;}
    if(enabled && [PyHost isRunningServiceIdentifier:serviceID]){
        int port=[service[@"port"] intValue];
        if(port>0){
            [self.serviceOperations addObject:serviceID];
            __weak typeof(self) weakSelf=self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
                BOOL needsRestart=NO;
                if(HostLocalPortState(port)==0){
                    [PyHost refreshListenersAfterForeground];
                    [NSThread sleepForTimeInterval:0.12];
                    needsRestart=(HostLocalPortState(port)==0);
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    RootViewController *owner=weakSelf;
                    if(!owner){if(completion)completion(nil);return;}
                    [owner.serviceOperations removeObject:serviceID];
                    if(needsRestart){[owner restartMediaService:service completion:completion];return;}
                    [owner refreshConfigurationPage];if(completion)completion(nil);
                });
            });
            return;
        }
        [self refreshConfigurationPage];if(completion)completion(nil);return;
    }
    if(enabled){
        if(![PyHost isRunningServiceIdentifier:serviceID] && [PyHost isManagedServiceIdentifier:serviceID]){
            [self restartMediaService:service completion:completion];
            return;
        }
        NSError *error=nil;BOOL started=[self startService:service error:&error];
        [RuntimeDiagnostics.shared recordEvent:started?@"service_start_accepted":@"service_start_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"start_phase":started?@"request_accepted":@"rejected", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];
        if(started && ![service[@"builtin"] boolValue] && [ServiceStore isVODMediaService:service] && ![ServiceStore isLiveMediaService:service]){
            [self hibernateExcessBackgroundVODServicesKeepingID:serviceID];
        }
        [self refreshConfigurationPage];if(completion)completion(error);return;
    }
    [self.serviceOperations addObject:serviceID];
    [RuntimeDiagnostics.shared recordEvent:@"service_stop_requested" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0}];
    [self log:@"正在停止服务 %@",service[@"name"]];
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *stopError=nil;BOOL stopped=[PyHost stopServiceIdentifier:serviceID error:&stopError];
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;
            if(!owner){if(completion)completion(stopped?nil:stopError);return;}
            [owner.serviceOperations removeObject:serviceID];[RuntimeDiagnostics.shared recordEvent:stopped?@"service_stopped":@"service_stop_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"error_domain":stopError.domain?:@"", @"error_code":@(stopError.code), @"error_message":stopError.localizedDescription?:@""}];if(!stopped){if(completion)completion(stopError);[owner refreshConfigurationPage];return;}
            [owner completeServiceStopForIdentifier:serviceID];[owner refreshConfigurationPage];if(completion)completion(nil);
        });
    });
}
- (void)hibernateExcessBackgroundVODServicesKeepingID:(NSString *)activeServiceID {
    if(!activeServiceID.length)return;
    if(!self.recentVODServiceIDs)self.recentVODServiceIDs=[NSMutableArray array];
    [self.recentVODServiceIDs removeObject:activeServiceID];
    [self.recentVODServiceIDs addObject:activeServiceID];
    NSUInteger maxConcurrentVODServices=2;
    if(self.recentVODServiceIDs.count<=maxConcurrentVODServices)return;
    NSArray<NSDictionary *> *allServices=[ServiceStore services];
    while(self.recentVODServiceIDs.count>maxConcurrentVODServices){
        NSString *evictID=self.recentVODServiceIDs.firstObject;
        [self.recentVODServiceIDs removeObjectAtIndex:0];
        if([evictID isEqualToString:activeServiceID]||[self.serviceOperations containsObject:evictID])continue;
        NSDictionary *candidate=nil;
        for(NSDictionary *svc in allServices)if([svc[@"id"] isEqualToString:evictID]){candidate=svc;break;}
        if(!candidate||[candidate[@"builtin"] boolValue]||![ServiceStore isVODMediaService:candidate]||[ServiceStore isLiveMediaService:candidate]||[ServiceStore subscriptionURLForService:candidate].length)continue;
        if([PyHost isRunningServiceIdentifier:evictID]){
            [self changeService:candidate enabled:NO completion:nil];
        }
    }
}
- (void)completeServiceStopForIdentifier:(NSString *)serviceID {
    [(MediaBrowserViewController *)self.tabPages[@2] invalidateServiceIdentifier:serviceID];
    NSDictionary *stopped=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqualToString:serviceID]){stopped=service;break;}if(serviceID.length){[self logPluginLine:@"插件服务已停止" identifier:serviceID name:stopped[@"name"]?:@"插件"];[PluginLogStore.shared finishRunForIdentifier:serviceID status:@"已停止"];}
    for(NSString *source in self.subscriptionURLs.allObjects){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:source]];if([owner[@"id"] isEqual:serviceID]){[ProfileStore update:source values:@{@"status":@"服务已停止 · 保留最近一次频道清单"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:source];}}
    if(stopped[@"port"]){NSInteger stoppedPort=[stopped[@"port"] integerValue];for(NSString *origin in self.readyLocalOrigins.allKeys.copy)if([NSURL URLWithString:origin].port.integerValue==stoppedPort)[self.readyLocalOrigins removeObjectForKey:origin];for(NSString *key in self.subscriptionReadiness.allKeys.copy){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:key]];if([owner[@"id"] isEqualToString:serviceID]){[self.subscriptionReadiness[key] cancel];[self.subscriptionReadiness removeObjectForKey:key];}}}
    NSDictionary *currentService=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];
    if([currentService[@"id"] isEqualToString:serviceID]){
        self.playbackGeneration++;[self stopPlayback];[self.spinner stopAnimating];self.titleLabel.hidden=NO;self.titleLabel.text=@"本机服务已停止";
    }
    [self log:@"服务 %@ 已停止，保留订阅供下次启动续播",stopped[@"name"]?:serviceID];
    [self clearServiceLogHandlers:serviceID];
}
- (void)showServiceError:(NSString *)message {[self log:@"服务操作失败：%@",message?:@"未知错误"];UIAlertController *a=[UIAlertController alertControllerWithTitle:@"服务" message:message?:@"服务操作失败，请查看日志。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];UIViewController *top=self.navigationController.topViewController?:self;[top presentViewController:a animated:YES completion:nil];}
- (void)stopBuiltinPlugin {for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){[self toggleService:service enabled:NO];break;}}
- (void)startBuiltinPlugin {for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){[self toggleService:service enabled:YES];break;}}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;if(!url)return;
    BOOL scoped=[url startAccessingSecurityScopedResource];self.navigationItem.prompt=@"正在读取本机配置…";__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *readError=nil;NSData *data=nil;NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:&readError];
        @try{if(file)data=[file readDataUpToLength:32*1024*1024+1 error:&readError];}
        @catch(NSException *exception){NSLog(@"[CCTVHost] backup import read raised %@",exception.name);readError=[NSError errorWithDomain:@"CCTVHostBackup" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取所选配置文件"}];}
        @finally{[file closeAndReturnError:NULL];if(scoped)[url stopAccessingSecurityScopedResource];}
        if(data.length>32*1024*1024){data=nil;readError=[NSError errorWithDomain:@"CCTVHostBackup" code:2 userInfo:@{NSLocalizedDescriptionKey:@"配置文件超过 32 MiB 上限"}];}
        dispatch_async(dispatch_get_main_queue(),^{RootViewController *owner=weakSelf;if(!owner)return;owner.navigationItem.prompt=nil;if(readError)[owner showServiceError:readError.localizedDescription];else[owner finishConfigurationImport:data];});
    });
}

- (void)shareResourceFileAtURL:(NSURL *)url {
    UIViewController *presenter=self.navigationController.topViewController?:self;
    UIAlertController *confirmation=[UIAlertController alertControllerWithTitle:@"分享原始资源"
        message:@"文件可能包含完整地址、访问凭据或脚本。请先确认接收方。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }]];
    __weak typeof(self) weakSelf=self;
    [confirmation addAction:[UIAlertAction actionWithTitle:@"继续分享" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        dispatch_async(dispatch_get_main_queue(), ^{[weakSelf shareDiagnosticLogAtURL:url];});
    }]];
    [presenter presentViewController:confirmation animated:YES completion:nil];
}

- (void)exportLocalConfiguration {
    UIAlertController *confirmation=[UIAlertController alertControllerWithTitle:@"导出可恢复备份"
        message:@"包含订阅、收藏、历史、偏好和可保存的合集索引，可能含完整地址与访问凭据。脚本文件、服务配置、合集本地文件和钥匙串凭据需另行迁移。请仅保存到你信任的位置。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirmation addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [confirmation addAction:[UIAlertAction actionWithTitle:@"生成备份" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf shareLocalConfigurationBackup];}]];
    [self presentViewController:confirmation animated:YES completion:nil];
}
- (void)shareLocalConfigurationBackup {
    self.navigationItem.prompt=@"正在准备备份…";
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:[HostBackup snapshot] options:NSJSONWritingPrettyPrinted error:&error];
        if(data.length>32*1024*1024){data=nil;error=[NSError errorWithDomain:@"CCTVHostBackup" code:2 userInfo:@{NSLocalizedDescriptionKey:@"备份超过 32 MiB，无法导入。请减少订阅缓存后重试。"}];}
        if(data&&![HostBackup validatedBackup:data error:&error])data=nil;
        NSString *name=[NSString stringWithFormat:@"CCTVHost-configuration-%@.json",NSUUID.UUID.UUIDString];
        NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:name];
        if(data&&![data writeToFile:path options:NSDataWritingAtomic|NSDataWritingFileProtectionComplete error:&error])data=nil;
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;if(!owner){[NSFileManager.defaultManager removeItemAtPath:path error:NULL];return;}
            owner.navigationItem.prompt=nil;
            if(!data){[owner showServiceError:error.localizedDescription?:@"备份写入失败"];return;}
            UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];v.popoverPresentationController.sourceView=owner.bottomBar;v.popoverPresentationController.sourceRect=owner.bottomBar.bounds;v.completionWithItemsHandler=^(__unused UIActivityType activity,__unused BOOL completed,__unused NSArray *items,__unused NSError *shareError){[NSFileManager.defaultManager removeItemAtPath:path error:NULL];};[owner presentViewController:v animated:YES completion:nil];
        });
    });
}
- (void)importLocalConfiguration {UIDocumentPickerViewController *v=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];v.delegate=self;[self presentViewController:v animated:YES completion:nil];}
- (void)finishConfigurationImport:(NSData *)data {
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error=nil;
        NSDictionary *backup=[HostBackup validatedBackup:data error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if(backup)[weakSelf confirmConfigurationRestore:backup];
            else [weakSelf showServiceError:error.localizedDescription];
        });
    });
}
- (void)confirmConfigurationRestore:(NSDictionary *)backup {
    NSArray *dependencies=[backup[@"resourceDependencies"] isKindOfClass:NSArray.class]?backup[@"resourceDependencies"]:@[];
    NSMutableSet *existing=[NSMutableSet set];for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isKindOfClass:NSString.class])[existing addObject:service[@"id"]];for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if([catalog[@"id"] isKindOfClass:NSString.class])[existing addObject:catalog[@"id"]];
    NSMutableArray *missing=[NSMutableArray array];for(NSDictionary *dependency in dependencies)if(![existing containsObject:dependency[@"id"]])[missing addObject:dependency[@"name"]];
    NSString *preview=[NSString stringWithFormat:@"将替换 %lu 个订阅的配置及本机收藏、历史和偏好；备份含 %lu 个合集索引，已有同 ID 合集保留。脚本文件、服务配置、合集本地文件与钥匙串凭据需另行迁移。",(unsigned long)[backup[@"subscriptions"] count],(unsigned long)[backup[@"catalogs"] count]];
    if(missing.count)preview=[preview stringByAppendingFormat:@"\n\n缺少 %lu 个资源依赖：%@%@",(unsigned long)missing.count,[[missing subarrayWithRange:NSMakeRange(0,MIN(missing.count,5))] componentsJoinedByString:@"、"],missing.count>5?@"等":@""];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"导入本机配置" message:preview preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSDictionary *oldReminders=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.epgReminders.v1"]?:@{};
        NSError *restoreError=nil;if(![HostBackup restore:backup error:&restoreError]){[self showServiceError:restoreError.localizedDescription?:@"恢复配置失败"];return;}
        NSSet *restoredSources=[NSSet setWithArray:backup[@"subscriptions"]?:@[]];
        for(NSString *source in self.subscriptionURLs.allObjects){self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self.subscriptionTasks[source] cancel];[self.subscriptionTasks removeObjectForKey:source];[self.subscriptionEditTasks[source] cancel];[self.subscriptionEditTasks removeObjectForKey:source];if(![restoredSources containsObject:source])[self removeSubscriptionSource:source];}
        NSDictionary *versions=self.subscriptionRequestVersions.copy;[self loadChannels];[self.subscriptionRequestVersions addEntriesFromDictionary:versions];self.recents=[[HostLibraryStore.shared recents] mutableCopy]?:[NSMutableArray array];self.activeSource=nil;self.gridMode=CCTVBoolPreference(@"channelGridMode",YES);NSInteger restoredCols=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelGridColumns.v1"];self.gridColumns=(restoredCols==3)?3:4;self.channelSortMode=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelSortMode.v1"];if(self.channelSortMode<0||self.channelSortMode>2)self.channelSortMode=0;[RuntimeDiagnostics.shared setEnabled:CCTVBoolPreference(@"runtimeDiagnosticsEnabled",NO)];MediaAdaptationMonitor.shared.monitoringEnabled=CCTVBoolPreference(@"cctv.adaptationMonitor.enabled",YES);[self configureSDKLogging];for(NSString *source in self.subscriptionURLs.allObjects)[self fetchSubscription:source silent:YES];[self activateAudioSession];[self configureCatalogNavigation];[self applyFilter];[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews.firstObject];
        // 备份里的主题与字号刚恢复：立即应用到窗口并重刷可见页面，
        // 否则要等下次启动才生效。
        UIWindow *window=self.view.window;if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);HostRefreshAppearanceLayers(window);}[self reloadThemeAppearance];[self applyFontSizeOverride];MediaBrowserViewController *browser=(MediaBrowserViewController *)self.tabPages[@2];if(browser)[browser reloadMediaDisplayConfigurationIfLoaded];[NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];[self.table reloadData];[self.view setNeedsLayout];
        [self restoreEPGNotifications:[backup[@"epgReminders"] isKindOfClass:NSDictionary.class]?backup[@"epgReminders"]:@{} replacing:oldReminders];
    }]];[self presentViewController:a animated:YES completion:nil];
}

- (void)restoreEPGNotifications:(NSDictionary *)reminders replacing:(NSDictionary *)oldReminders {
    UNUserNotificationCenter *center=UNUserNotificationCenter.currentNotificationCenter;
    [center removePendingNotificationRequestsWithIdentifiers:oldReminders.allKeys];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSMutableArray *pending=[NSMutableArray array];
    for(NSString *key in reminders){NSDictionary *entry=reminders[key];if([entry[@"start"] doubleValue]>now)[pending addObject:key];}
    if(!pending.count)return;
    [pending sortUsingComparator:^NSComparisonResult(NSString *left,NSString *right){return [reminders[left][@"start"] compare:reminders[right][@"start"]];}];
    BOOL exceededSystemLimit=pending.count>64;
    if(exceededSystemLimit)[pending removeObjectsInRange:NSMakeRange(64,pending.count-64)];
    __weak typeof(self) weakSelf=self;
    [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted,NSError *error){
        if(!granted||error){dispatch_async(dispatch_get_main_queue(),^{[weakSelf showServiceError:@"节目提醒已恢复，但通知未开启；请在系统设置中允许通知后重新预约。"];});return;}
        dispatch_group_t group=dispatch_group_create();__block NSUInteger failed=0;
        for(NSString *key in pending){NSDictionary *entry=reminders[key];NSTimeInterval start=[entry[@"start"] doubleValue], current=NSDate.date.timeIntervalSince1970;if(start<=current)continue;
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];content.title=[entry[@"channelName"] length]?entry[@"channelName"]:@"CCTV";content.body=[NSString stringWithFormat:@"即将播出：%@",entry[@"title"]];content.sound=[UNNotificationSound defaultSound];NSTimeInterval fire=start-300>current?start-300:start;
            UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:key content:content trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:MAX(1,fire-current) repeats:NO]];
            dispatch_group_enter(group);[center addNotificationRequest:request withCompletionHandler:^(NSError *notificationError){if(notificationError)@synchronized(center){failed++;}dispatch_group_leave(group);}];
        }
        dispatch_group_notify(group,dispatch_get_main_queue(),^{if(failed||exceededSystemLimit){NSString *reason=exceededSystemLimit?@"系统最多保留 64 条待发送提醒，已优先安排最近的节目。":@"请检查通知设置后重新预约。";NSString *message=failed?[NSString stringWithFormat:@"%lu 个节目提醒未能重新安排。%@",(unsigned long)failed,reason]:reason;[weakSelf showServiceError:message];}});
    }];
}

@end
