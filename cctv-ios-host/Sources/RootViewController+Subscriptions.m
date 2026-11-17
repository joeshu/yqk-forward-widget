#import "RootViewController_Internal.h"

@implementation RootViewController (Subscriptions)
- (NSDictionary *)resourceServiceForSource:(NSString *)source {if(![source hasPrefix:@"plugin:"])return nil;NSString *identifier=[source substringFromIndex:7];for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier])return service;return nil;}
- (NSArray *)configurationProfiles {
    NSMutableArray *rows=[NSMutableArray array];NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];NSUInteger native=0;
    for(NSDictionary *channel in self.allChannels){if(![channel[@"remoteURL"] length])native++;for(NSString *source in [NSSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])])counts[source]=@([counts[source] unsignedIntegerValue]+1);}
    NSDictionary *nativeMeta=[ProfileStore metadata:@""];
    NSMutableDictionary *nativeRow=[@{@"name":nativeMeta[@"name"]?:@"央视直播 · 官方频道",@"source":@"",@"status":nativeMeta[@"status"]?:@"内置官方 · 实时就绪",@"resourceKind":@"live",@"native":@YES,@"current":@(!self.activeSource.length),@"epgStatus":@"官方",@"count":@(native),@"enabled":@(CCTVBoolPreference(@"nativeChannelsEnabled",YES)),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:@""]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:@""]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:@""]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:@""])} mutableCopy];
    if(nativeMeta[@"updatedAt"])nativeRow[@"updatedAt"]=nativeMeta[@"updatedAt"];
    [rows addObject:nativeRow];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSString *selectedMedia=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"]?:@"";
    NSString *selectedMediaCatalog=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaCatalogID"]?:@"";
    NSMutableSet<NSString *> *catalogIDs=[NSMutableSet set];for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if([catalog[@"id"] isKindOfClass:NSString.class])[catalogIDs addObject:catalog[@"id"]];
    for(NSString *u in [ProfileStore orderedSources:self.subscriptionURLs.allObjects]){NSDictionary *metadata=[ProfileStore metadata:u];NSString *catalogID=[metadata[@"tvboxCatalogID"] isKindOfClass:NSString.class]?metadata[@"tvboxCatalogID"]:@"";if(catalogID.length&&[catalogIDs containsObject:catalogID])continue;NSMutableDictionary *row=[@{@"name":metadata[@"name"]?:[NSURL URLWithString:u].host?:@"本地播放列表",@"status":metadata[@"status"]?:@"等待刷新",@"resourceKind":@"live",@"current":@([self.activeSource isEqual:u]),@"epgStatus":(metadata[@"epgURL"]?:metadata[@"detectedEPGURL"])?@"已配置":@"自动匹配",@"source":u,@"count":counts[u]?:@0,@"enabled":@(![disabled containsObject:u]),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:u]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:u]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:u]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:u])} mutableCopy];if(metadata[@"updatedAt"])row[@"updatedAt"]=metadata[@"updatedAt"];if(metadata[@"importSourceFilename"])row[@"sourceFilename"]=metadata[@"importSourceFilename"];if(metadata[@"importFingerprint"])row[@"fingerprint"]=metadata[@"importFingerprint"];[rows addObject:row];}
    for(NSDictionary *service in [ServiceStore services])if(![service[@"builtin"] boolValue]){
        NSString *catalogID=[service[@"tvboxCatalogID"] isKindOfClass:NSString.class]?service[@"tvboxCatalogID"]:@"";if(catalogID.length&&[catalogIDs containsObject:catalogID])continue;
        BOOL enabled=[PyHost isRunningServiceIdentifier:service[@"id"]];NSArray *caps=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:@[];
        NSString *subscriptionURL=[ServiceStore subscriptionURLForService:service]?:@"",*epgURL=[ServiceStore epgURLForService:service]?:@"";
        NSDictionary *playlistMetadata=subscriptionURL.length?[ProfileStore metadata:subscriptionURL]:@{};NSArray *cachedChannels=[playlistMetadata[@"cachedChannels"] isKindOfClass:NSArray.class]?playlistMetadata[@"cachedChannels"]:@[];
        NSString *kind=[ServiceStore resourceKindForService:service subscriptionURL:subscriptionURL];
        NSString *playlistStatus=[playlistMetadata[@"status"] isKindOfClass:NSString.class]?playlistMetadata[@"status"]:(subscriptionURL.length?(enabled?@"等待读取订阅清单":@"服务已停止 · 保留最近频道"):@"未配置播放列表");
        NSDictionary *health=[ServiceStore healthSnapshotForServiceIdentifier:service[@"id"]];NSMutableDictionary *profile=[@{@"name":service[@"name"]?:@"本机脚本",@"type":@"plugin",@"resourceKind":kind,@"capabilities":caps,@"engine":service[@"engine"]?:@"python",@"runtime":service[@"engine"]?:@"python",@"protocol":service[@"protocol"]?:@"未知协议",@"playlistPath":[ServiceStore playlistPathForService:service]?:@"",@"subscriptionURL":subscriptionURL,@"epgURL":epgURL,@"subscriptionStatus":playlistStatus,@"channelCount":@(cachedChannels.count),@"playlistUpdatedAt":playlistMetadata[@"updatedAt"]?:@0,@"updatedAt":service[@"updated"]?:@0,@"port":service[@"port"]?:@0,@"url":service[@"url"]?:@"",@"current":@([service[@"id"] isEqual:selectedMedia]),@"source":[@"plugin:" stringByAppendingString:service[@"id"]],@"status":[PyHost runtimeStatusDescriptionForServiceIdentifier:service[@"id"]],@"enabled":@(enabled),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:[@"plugin:" stringByAppendingString:service[@"id"]]]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:[@"plugin:" stringByAppendingString:service[@"id"]]]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:[@"plugin:" stringByAppendingString:service[@"id"]]]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:[@"plugin:" stringByAppendingString:service[@"id"]]])} mutableCopy];if(service[@"importSourceFilename"])profile[@"sourceFilename"]=service[@"importSourceFilename"];if(service[@"importFingerprint"])profile[@"fingerprint"]=service[@"importFingerprint"];if([health[@"result"] isKindOfClass:NSString.class])profile[@"healthResult"]=health[@"result"];if(health[@"checkedAt"])profile[@"healthCheckedAt"]=health[@"checkedAt"];if(health[@"httpStatus"])profile[@"healthHTTPStatus"]=health[@"httpStatus"];[rows addObject:profile];
    }
    for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
        NSString *identifier=catalog[@"id"]?:@"";NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"";if(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])catalogName=@"资源合集";NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSUInteger supported=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])supported++;
        NSUInteger liveCount=[catalog[@"lives"] count];NSString *kind=supported&&liveCount?@"both":(supported?@"vod":(liveCount?@"live":@"unknown"));NSString *catalogKind=[catalog[@"catalogKind"] isKindOfClass:NSString.class]?catalog[@"catalogKind"]:@"tvbox";
        BOOL current=[selectedMediaCatalog isEqual:identifier]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"tvbox-api:%@:",identifier]]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"maccms-api:%@:",identifier]]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"jar-bridge:%@:",identifier]];
        BOOL liveEnabled=NO;for(NSString *owner in self.subscriptionURLs){NSDictionary *ownerMetadata=[ProfileStore metadata:owner];if([ownerMetadata[@"tvboxCatalogID"] isEqual:identifier]&&![disabled containsObject:owner]&&[counts[owner] unsignedIntegerValue]){liveEnabled=YES;break;}}
        NSMutableDictionary *profile=[@{@"name":catalogName,@"type":@"tvbox",@"catalogKind":catalogKind,@"resourceKind":kind,@"source":[@"tvbox:" stringByAppendingString:identifier],@"url":catalog[@"url"]?:@"",@"updatedAt":catalog[@"updatedAt"]?:@0,@"siteCount":@(sites.count),@"supportedCount":@(supported),@"liveCount":@(liveCount),@"enabled":@(liveEnabled),@"current":@(current),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:[@"tvbox:" stringByAppendingString:identifier]]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:[@"tvbox:" stringByAppendingString:identifier]]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:[@"tvbox:" stringByAppendingString:identifier]]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:[@"tvbox:" stringByAppendingString:identifier]])} mutableCopy];if(catalog[@"importSourceFilename"])profile[@"sourceFilename"]=catalog[@"importSourceFilename"];if(catalog[@"importFingerprint"])profile[@"fingerprint"]=catalog[@"importFingerprint"];[rows addObject:profile];
    }
    NSArray *unifiedOrder=[NSUserDefaults.standardUserDefaults arrayForKey:@"resourceUnifiedOrder"];
    if([unifiedOrder isKindOfClass:NSArray.class]&&unifiedOrder.count){
        NSMutableDictionary<NSString *,NSNumber *> *orderMap=[NSMutableDictionary dictionaryWithCapacity:unifiedOrder.count];
        for(NSUInteger idx=0;idx<unifiedOrder.count;idx++){id key=unifiedOrder[idx];if([key isKindOfClass:NSString.class]&&!orderMap[key])orderMap[key]=@(idx);}
        [rows sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSString *ka=[a[@"source"] isKindOfClass:NSString.class]&&[a[@"source"] length]?a[@"source"]:([a[@"native"] boolValue]?@"__native_cctv__":@"");
            NSString *kb=[b[@"source"] isKindOfClass:NSString.class]&&[b[@"source"] length]?b[@"source"]:([b[@"native"] boolValue]?@"__native_cctv__":@"");
            NSNumber *ia=orderMap[ka],*ib=orderMap[kb];
            if(ia&&ib)return [ia compare:ib];
            if(ia)return NSOrderedAscending;
            if(ib)return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    return rows;
}
- (NSDictionary *)configurationProfileForSource:(NSString *)source {
    NSString *key=source?:@"";
    if(!key.length){
        NSUInteger native=0;
        for(NSDictionary *channel in self.allChannels)if(![channel[@"remoteURL"] length])native++;
        NSDictionary *nativeMeta=[ProfileStore metadata:@""];
        NSMutableDictionary *row=[@{@"name":nativeMeta[@"name"]?:@"央视直播 · 官方频道",@"source":@"",@"status":nativeMeta[@"status"]?:@"内置官方 · 实时就绪",@"resourceKind":@"live",@"native":@YES,@"current":@(!self.activeSource.length),@"epgStatus":@"官方",@"count":@(native),@"enabled":@(CCTVBoolPreference(@"nativeChannelsEnabled",YES)),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:@""]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:@""]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:@""]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:@""])} mutableCopy];
        if(nativeMeta[@"updatedAt"])row[@"updatedAt"]=nativeMeta[@"updatedAt"];
        return row;
    }
    if(![key hasPrefix:@"plugin:"]&&![key hasPrefix:@"tvbox:"]){
        NSUInteger count=0;
        for(NSDictionary *channel in self.allChannels){
            NSArray *subs=[channel[@"subscriptionSources"] isKindOfClass:NSArray.class]?channel[@"subscriptionSources"]:@[];
            if([subs containsObject:key])count++;
        }
        NSDictionary *metadata=[ProfileStore metadata:key];
        NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
        NSMutableDictionary *row=[@{@"name":metadata[@"name"]?:[NSURL URLWithString:key].host?:@"本地播放列表",@"status":metadata[@"status"]?:@"等待刷新",@"resourceKind":@"live",@"current":@([self.activeSource isEqual:key]),@"epgStatus":(metadata[@"epgURL"]?:metadata[@"detectedEPGURL"])?@"已配置":@"自动匹配",@"source":key,@"count":@(count),@"enabled":@(![disabled containsObject:key]),@"showChannelLogo":@([ProfileStore isChannelLogoEnabledForSource:key]),@"showPlayerCornerLogo":@([ProfileStore isPlayerCornerLogoEnabledForSource:key]),@"showChannelPreview":@([ProfileStore isChannelPreviewEnabledForSource:key]),@"showChannelTelemetry":@([ProfileStore isChannelTelemetryEnabledForSource:key])} mutableCopy];
        if(metadata[@"updatedAt"])row[@"updatedAt"]=metadata[@"updatedAt"];
        if(metadata[@"importSourceFilename"])row[@"sourceFilename"]=metadata[@"importSourceFilename"];
        if(metadata[@"importFingerprint"])row[@"fingerprint"]=metadata[@"importFingerprint"];
        return row;
    }
    for(NSDictionary *profile in [self configurationProfiles])if([profile[@"source"] isEqual:key])return profile;
    return @{};
}
- (void)updateLiveResourceCapsule {
    UIButton *capsule=self.liveResourceCapsule;if(!capsule)return;
    BOOL visible=[self isExpandedLivePlayerVisible];capsule.hidden=!visible;
    if(!visible)return;
    NSString *title=self.activeTab==0?@"央视直播":@"全部直播资源";
    UIMenu *menu=nil;
    if(self.activeTab==1){
        __weak typeof(self) weakSelf=self;NSMutableArray<UIMenuElement *> *actions=[NSMutableArray array];
        BOOL allSelected=!self.activeSource.length;NSString *allTitle=allSelected?@"✓ 全部直播资源":@"全部直播资源";
        [actions addObject:[UIAction actionWithTitle:allTitle image:[UIImage systemImageNamed:allSelected?@"checkmark.circle.fill":@"dot.radiowaves.left.and.right"] identifier:@"live.resource.all" handler:^(UIAction *action){[weakSelf selectLiveResourceSource:nil];}]];
        NSString *selectedName=nil;
        for(NSDictionary *profile in [self configurationProfiles]){
            NSString *kind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"";
            if(!([kind isEqual:@"live"]||[kind isEqual:@"both"])||[profile[@"native"] boolValue]||(profile[@"enabled"]&&![profile[@"enabled"] boolValue]))continue;
            NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
            if(!source.length)continue;
            if([profile[@"type"] isEqual:@"tvbox"]&&![profile[@"liveCount"] unsignedIntegerValue])continue;
            if([profile[@"type"] isEqual:@"plugin"]&&![[profile[@"subscriptionURL"] description] length]&&![profile[@"channelCount"] unsignedIntegerValue])continue;
            NSString *name=[profile[@"name"] isKindOfClass:NSString.class]?profile[@"name"]:source;
            NSUInteger count=[profile[@"count"] unsignedIntegerValue];if(!count)count=[profile[@"channelCount"] unsignedIntegerValue];if(!count)count=[profile[@"liveCount"] unsignedIntegerValue];
            NSString *menuTitle=count?[NSString stringWithFormat:@"%@ · %lu",name,(unsigned long)count]:name;
            BOOL selected=[source isEqual:self.activeSource];if(selected){selectedName=name;menuTitle=[@"✓ " stringByAppendingString:menuTitle];}
            NSString *capturedSource=[source copy];
            [actions addObject:[UIAction actionWithTitle:menuTitle image:[UIImage systemImageNamed:selected?@"checkmark.circle.fill":@"dot.radiowaves.left.and.right"] identifier:nil handler:^(UIAction *action){[weakSelf selectLiveResourceSource:capturedSource];}]];
        }
        if(actions.count==1){UIAction *empty=[UIAction actionWithTitle:@"资源页暂无可选直播源" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *action){}];[actions addObject:empty];}
        if(selectedName.length)title=selectedName;
        title=[title stringByAppendingString:@"  ▾"];
        menu=[UIMenu menuWithTitle:@"选择直播资源" children:actions];
    }
    UIButtonConfiguration *configuration=[UIButtonConfiguration plainButtonConfiguration];configuration.title=title;configuration.image=[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"];configuration.imagePlacement=NSDirectionalRectEdgeLeading;configuration.imagePadding=7;configuration.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];configuration.baseForegroundColor=HostText();configuration.background.backgroundColor=HostGlassTint();configuration.background.strokeColor=HostBorder();configuration.background.strokeWidth=.7;configuration.background.cornerRadius=18;configuration.contentInsets=NSDirectionalEdgeInsetsMake(6,12,6,12);configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];return result;};capsule.configuration=configuration;capsule.menu=menu;capsule.showsMenuAsPrimaryAction=self.activeTab==1;capsule.accessibilityLabel=self.activeTab==1?([title stringByReplacingOccurrencesOfString:@"  ▾" withString:@""]):@"央视直播";capsule.accessibilityHint=self.activeTab==1?@"下拉切换资源页中的直播资源":@"当前为央视官方频道";
}
- (void)selectLiveResourceSource:(NSString *)source {
    self.activeSource=source.length?[source copy]:nil;self.favoritesOnly=NO;
    [self applyFilter];[self updateLiveResourceCapsule];
    CGFloat top=-self.channelGrid.contentInset.top;self.channelGrid.contentOffset=CGPointMake(0,top);self.table.contentOffset=CGPointMake(0,-self.table.contentInset.top);
    [self.view setNeedsLayout];
}
- (BOOL)subscriptionOwner:(NSString *)owner matchesLiveResourceSource:(NSString *)source {
    if(!source.length||[owner isEqual:source])return YES;
    NSDictionary *metadata=[ProfileStore metadata:owner]?:@{};
    if([source hasPrefix:@"tvbox:"]){
        NSString *catalogID=[source substringFromIndex:6];if([metadata[@"tvboxCatalogID"] isEqual:catalogID])return YES;
        NSDictionary *service=[self localServiceForURL:[NSURL URLWithString:owner]];return [service[@"tvboxCatalogID"] isEqual:catalogID];
    }
    if([source hasPrefix:@"plugin:"]){
        NSString *serviceID=[source substringFromIndex:7];if([metadata[@"managedServiceID"] isEqual:serviceID])return YES;
        NSDictionary *service=[self resourceServiceForSource:source];NSString *playlist=[ServiceStore subscriptionURLForService:service]?:@"";if(playlist.length&&[[self stableURLKey:playlist] isEqual:[self stableURLKey:owner]])return YES;
        NSDictionary *ownerService=[self localServiceForURL:[NSURL URLWithString:owner]];return [ownerService[@"id"] isEqual:serviceID];
    }
    return NO;
}
- (void)deleteSubscription:(NSString *)source {
    [self.subscriptionTasks[source] cancel];[self.subscriptionTasks removeObjectForKey:source];[self.subscriptionTraceIDs removeObjectForKey:source];[ProfileStore remove:source];
    [self.subscriptionURLs removeObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
}

#pragma mark - 订阅管理

- (void)manageSubscriptions {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"订阅源" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (!self.subscriptionURLs.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"暂无订阅" style:UIAlertActionStyleDefault handler:nil]];
    }
    for (NSString *u in self.subscriptionURLs.allObjects) {
        NSString *sourceName=[ProfileStore metadata:u][@"name"];
        if(![sourceName isKindOfClass:NSString.class]||!sourceName.length)sourceName=[NSURL URLWithString:u].host;
        NSString *title = sourceName.length?sourceName:(u.length > 42 ? [[u substringToIndex:42] stringByAppendingString:@"…"] : u);
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIAlertController *op = [UIAlertController alertControllerWithTitle:u message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            [op addAction:[UIAlertAction actionWithTitle:@"刷新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *y) {
                [self fetchSubscription:u silent:NO];
            }]];
            [op addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *y) {
                NSString *sourceKey = [self stableURLKey:u];
                [self.subscriptionURLs removeObject:sourceKey ?: u];
                NSString *deletedKey = sourceKey ?: u;
                self.subscriptionRequestVersions[deletedKey] = @([self.subscriptionRequestVersions[deletedKey] unsignedIntegerValue] + 1);
                [self removeSubscriptionSource:deletedKey];
                [[NSUserDefaults standardUserDefaults] setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
                [self log:@"已删除订阅 %@", CCTVServiceLogAddress(u)];
            }]];
            [op addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:op animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 订阅（m3u 源 / 本地插件）

- (void)addSubscription {
    if(!self.resourceImportWorkflow){
        ResourceImportWorkflowViewController *workflow=[ResourceImportWorkflowViewController new];self.resourceImportWorkflow=workflow;__weak typeof(self) weakSelf=self;
        workflow.onStateChanged=^{[weakSelf refreshConfigurationPage];};
        workflow.onOpenServices=^{[weakSelf openServicesPage];};
        workflow.existingImportTargetsProvider=^NSArray<NSDictionary *> *{RootViewController *owner=weakSelf;if(!owner)return @[];NSMutableArray<NSDictionary *> *targets=[NSMutableArray array];for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if(!catalog[@"bundledResourceID"]){[targets addObject:@{@"kind":@"catalog",@"kindLabel":@"影视合集",@"id":catalog[@"id"]?:@"",@"name":catalog[@"name"]?:@"资源合集",@"url":catalog[@"url"]?:@"",@"fingerprint":catalog[@"importFingerprint"]?:@"",@"sourceFilename":catalog[@"importSourceFilename"]?:@""}];}for(NSDictionary *service in [ServiceStore services])if(![service[@"builtin"] boolValue]&&![service[@"bundledResourceID"] length]){[targets addObject:@{@"kind":@"service",@"kindLabel":@"脚本资源",@"id":service[@"id"]?:@"",@"name":service[@"name"]?:@"脚本资源",@"url":service[@"url"]?:@"",@"fingerprint":service[@"importFingerprint"]?:@"",@"sourceFilename":service[@"importSourceFilename"]?:@""}];}for(NSString *source in owner.subscriptionURLs)if([source hasPrefix:@"local-playlist:"]){NSDictionary *metadata=[ProfileStore metadata:source];[targets addObject:@{@"kind":@"playlist",@"kindLabel":@"本地直播列表",@"id":source,@"name":metadata[@"name"]?:@"本地播放列表",@"url":source,@"fingerprint":metadata[@"importFingerprint"]?:@"",@"sourceFilename":metadata[@"importSourceFilename"]?:@""}];}return targets.copy;};
        workflow.onSaveCandidate=^(NSDictionary *candidate,BOOL update,void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner saveImportCandidate:candidate update:update completion:completion];else completion([NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源页面已关闭"}]);};
        [workflow refreshExistingResourceMatches];
    }
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:self.resourceImportWorkflow];navigation.modalPresentationStyle=UIModalPresentationFullScreen;HostStyleNavigation(navigation);[self.navigationController.topViewController presentViewController:navigation animated:YES completion:nil];
}
- (void)saveImportCandidate:(NSDictionary *)candidate update:(BOOL)update completion:(void (^)(NSError *error))completion {
    NSError *failure=nil;NSString *kind=candidate[@"kind"],*sourceFilename=[candidate[@"localFileName"] isKindOfClass:NSString.class]?candidate[@"localFileName"]:@"";
    BOOL activateAfterSave=[candidate[@"activateAfterSave"] boolValue];
    BOOL customRenamed=[candidate[@"customNameAssigned"] boolValue]&&[candidate[@"name"] isKindOfClass:NSString.class]&&[candidate[@"name"] length]>0;
    if([kind isEqual:@"catalog"]){
        NSMutableDictionary *incoming=[candidate[@"catalog"] mutableCopy];if(sourceFilename.length)incoming[@"importSourceFilename"]=sourceFilename;
        if(customRenamed)incoming[@"name"]=candidate[@"name"];
        NSString *catOrigin=[candidate[@"origin"] isKindOfClass:NSString.class]?candidate[@"origin"]:([incoming[@"url"] isKindOfClass:NSString.class]?incoming[@"url"]:@"");
        if([catOrigin.lowercaseString containsString:@"sub.lytvs.top"]){NSString *tk=CCTVTVBoxTokenFromInput(catOrigin);if(tk.length)CCTVTVBoxSaveSubscriptionToken(tk);}NSDictionary *existing=nil;NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"catalog"]?candidate[@"existingResourceID"]:@"";
        for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){BOOL target=targetID.length&&[targetID isEqual:catalog[@"id"]];BOOL automatic=!targetID.length&&(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:catalog[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:catalog[@"importFingerprint"]]));if(target||automatic){existing=catalog;break;}}
        NSString *savedCatalogID=nil;
        if(targetID.length&&!existing)failure=[NSError errorWithDomain:@"ResourceImport" code:7 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧合集已被移除，请重新识别后再保存"}];
        else if(existing&&update){NSMutableDictionary *merged=[existing mutableCopy];[merged addEntriesFromDictionary:incoming];merged[@"id"]=existing[@"id"];merged[@"name"]=customRenamed?candidate[@"name"]:(existing[@"name"]?:incoming[@"name"]?:@"资源合集");[TVBoxCatalogStore saveCatalog:merged];savedCatalogID=merged[@"id"];}
        else if([TVBoxCatalogStore catalogs].count>=50)failure=[NSError errorWithDomain:@"ResourceImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"已达到 50 个合集上限"}];else {[TVBoxCatalogStore saveCatalog:incoming];savedCatalogID=incoming[@"id"];}
        if(!failure&&activateAfterSave&&savedCatalogID.length){
            [NSUserDefaults.standardUserDefaults setObject:savedCatalogID forKey:@"selectedMediaCatalogID"];
            MediaBrowserViewController *browser=(MediaBrowserViewController *)self.tabPages[@2];
            if(browser)[browser refreshSources];
        }
    }else if([kind isEqual:@"service"]){
        NSMutableDictionary *incoming=[candidate[@"service"] mutableCopy];if(sourceFilename.length)incoming[@"importSourceFilename"]=sourceFilename;
        if(customRenamed)incoming[@"name"]=candidate[@"name"];
        NSDictionary *existing=nil;NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"service"]?candidate[@"existingResourceID"]:@"";
        for(NSDictionary *service in [ServiceStore services]){if([service[@"builtin"] boolValue])continue;BOOL target=targetID.length&&[service[@"id"] isEqual:targetID];BOOL automatic=!targetID.length&&![service[@"id"] isEqual:incoming[@"id"]]&&(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:service[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:service[@"importFingerprint"]]));if(target||automatic){existing=service;break;}}
        NSDictionary *finalService=nil;
        if(targetID.length&&!existing)failure=[NSError errorWithDomain:@"ResourceImport" code:8 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧脚本资源已被移除，请重新识别后再保存"}];
        else if(existing&&update){if([PyHost isManagedServiceIdentifier:existing[@"id"]])failure=[NSError errorWithDomain:@"ResourceImport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"已有资源正在运行或清理，请先停止该资源，再重试保存"}];else{NSDictionary *saved=[ServiceStore replaceImportedService:existing withService:incoming error:&failure];if(saved){NSMutableDictionary *metadata=[saved mutableCopy];if(customRenamed)metadata[@"name"]=candidate[@"name"];if(incoming[@"importFingerprint"])metadata[@"importFingerprint"]=incoming[@"importFingerprint"];if(sourceFilename.length)metadata[@"importSourceFilename"]=sourceFilename;[ServiceStore save:metadata];finalService=metadata;}}}
        else {[ServiceStore save:incoming];finalService=incoming;}
        if(!failure&&activateAfterSave&&finalService[@"id"]){
            [NSUserDefaults.standardUserDefaults setObject:finalService[@"id"] forKey:@"selectedMediaSource"];
            [self changeService:finalService enabled:YES completion:nil];
            MediaBrowserViewController *browser=(MediaBrowserViewController *)self.tabPages[@2];
            if(browser)[browser refreshSources];
        }
    }else if([kind isEqual:@"playlist"]){
        NSString *origin=[self stableURLKey:candidate[@"origin"]],*text=candidate[@"text"]?:@"";NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"playlist"]?candidate[@"existingResourceID"]:@"";NSURL *base=origin.length?[NSURL URLWithString:candidate[@"resolvedURL"]?:origin]:nil;NSArray *parsed=[M3UParser parse:text baseURL:base];
        NSString *savedPlaylistSource=nil;
        if(!parsed.count)failure=[NSError errorWithDomain:@"ResourceImport" code:6 userInfo:@{NSLocalizedDescriptionKey:@"新播放列表没有有效 HTTP/HTTPS 频道，旧资源保持不变"}];
        else if(targetID.length){if([targetID hasPrefix:@"local-playlist:"]&&[self.subscriptionURLs containsObject:targetID]){NSMutableDictionary *values=[@{@"name":candidate[@"name"]?:@"本地播放列表",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,targetID)} mutableCopy];if(candidate[@"importFingerprint"])values[@"importFingerprint"]=candidate[@"importFingerprint"];if(sourceFilename.length)values[@"importSourceFilename"]=sourceFilename;[ProfileStore update:targetID values:values];[self installPlaylist:parsed source:targetID];savedPlaylistSource=targetID;}else if([self.subscriptionURLs containsObject:targetID]){[ProfileStore update:targetID values:@{@"name":candidate[@"name"]?:@"直播订阅",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,targetID)}];[self installPlaylist:parsed source:targetID];savedPlaylistSource=targetID;}else failure=[NSError errorWithDomain:@"ResourceImport" code:9 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧直播资源已被移除，请重新识别后再保存"}];}
        else if(origin.length&&[self.subscriptionURLs containsObject:origin]&&!update)failure=[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"相同在线订阅只能更新；如需独立副本，请导出后作为本地文件导入"}];
        else if(origin.length){NSMutableDictionary *values=[@{@"name":candidate[@"name"]?:@"直播订阅",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,origin)} mutableCopy];if(candidate[@"importFingerprint"])values[@"importFingerprint"]=candidate[@"importFingerprint"];if(sourceFilename.length)values[@"importSourceFilename"]=sourceFilename;[ProfileStore update:origin values:values];[self.subscriptionURLs addObject:origin];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];NSString *detected=[M3UParser epgURL:text baseURL:base];if(detected.length)[ProfileStore update:origin values:@{@"detectedEPGURL":detected}];[self installPlaylist:parsed source:origin];savedPlaylistSource=origin;}
        else {NSMutableDictionary *metadata=[NSMutableDictionary dictionary];if(sourceFilename.length)metadata[@"importSourceFilename"]=sourceFilename;if(candidate[@"importFingerprint"])metadata[@"importFingerprint"]=candidate[@"importFingerprint"];savedPlaylistSource=[self importPlaylistData:[text dataUsingEncoding:NSUTF8StringEncoding] name:candidate[@"name"]?:@"本地播放列表" metadata:metadata];}
        if(!failure&&activateAfterSave&&savedPlaylistSource.length){
            NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];
            [disabled removeObject:savedPlaylistSource];
            [NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];
            self.activeSource=savedPlaylistSource;
            [self applyFilter];
            [self updateLiveResourceCapsule];
        }
    }else failure=[NSError errorWithDomain:@"ResourceImport" code:5 userInfo:@{NSLocalizedDescriptionKey:@"资源类型尚未识别"}];
    [self refreshConfigurationPage];completion(failure);
}
- (NSString *)stableURLKey:(id)value {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *urlString = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!urlString.length || urlString.length > 8192) return nil;
    @try {
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        if (!components) return nil;
        NSString *scheme = components.scheme.lowercaseString;
        if (![MediaCapabilityNetworkTransports() containsObject:scheme]) return nil;
        if (!components.host.length || !components.URL) return nil;
        components.scheme = scheme;
        components.host = components.host.lowercaseString;
        components.fragment = nil;
        if (([scheme isEqualToString:@"http"] && components.port.integerValue == 80) ||
            ([scheme isEqualToString:@"https"] && components.port.integerValue == 443)) components.port = nil;
        return components.URL.absoluteString;
    } @catch (NSException *exception) {
        // M3U is untrusted input. One malformed percent escape must never abort the UI process.
        return nil;
    }
}

- (void)removeSubscriptionSource:(NSString *)sourceKey {
    [self.subscriptionReadiness[sourceKey] cancel];[self.subscriptionReadiness removeObjectForKey:sourceKey];[self.deferredLocalSubscriptions removeObject:sourceKey];
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *channel in self.allChannels ?: @[]) {
        NSMutableSet *sources = [NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];
        if ([sources containsObject:sourceKey]) {
            [sources removeObject:sourceKey];
            if (!sources.count) continue;
            NSMutableDictionary *copy = [channel mutableCopy];
            copy[@"subscriptionSources"] = sources.allObjects;
            [kept addObject:copy];
        } else {
            [kept addObject:channel];
        }
    }
    self.allChannels = kept;
    self.shownChannels = kept;
    [self applyFilter];
}

- (void)fetchSubscription:(NSString *)urlString silent:(BOOL)silent {
    NSString *inlinePlaylist=[ProfileStore metadata:urlString][@"inlinePlaylist"];
    if([inlinePlaylist isKindOfClass:NSString.class]&&inlinePlaylist.length){[self applyPlaylistText:inlinePlaylist source:urlString];return;}

    NSString *sourceKey=[ProfileStore isHTTP:urlString]?[self stableURLKey:urlString]:([ProfileStore isSource:urlString]?urlString:nil);
    if (!sourceKey.length) return;
    BOOL isHTTPSource=[ProfileStore isHTTP:sourceKey];
    if(silent && CACurrentMediaTime()<self.playbackPriorityUntil){[self.deferredLocalSubscriptions addObject:sourceKey];[ProfileStore update:sourceKey values:@{@"status":@"起播中，稍后自动刷新"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];return;}
    NSString *traceID=nil;if(isHTTPSource){traceID=self.subscriptionTraceIDs[sourceKey];if(!traceID.length){traceID=NSUUID.UUID.UUIDString.lowercaseString;self.subscriptionTraceIDs[sourceKey]=traceID;}}
    // Exact normalized source URLs, including query parameters, are independent
    // request identities. A repeat of the same URL joins the work already in flight.
    if(self.subscriptionTasks[sourceKey]){NSMutableDictionary *fields=[@{@"source_type":isHTTPSource?@"http":@"imported_text", @"correlation_id":traceID?:@""} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:sourceKey])];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_joined_existing" category:@"subscription" fields:fields];[ProfileStore update:sourceKey values:@{@"status":@"刷新已合并 · 当前请求仍在进行"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];return;}
    [ProfileStore update:sourceKey values:@{@"status":@"刷新中…"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];
    if(![ProfileStore isHTTP:sourceKey]){NSString *text=[ProfileStore metadata:sourceKey][@"text"];[self applyPlaylistText:text source:sourceKey];return;}
    NSURL *sourceURL=[NSURL URLWithString:sourceKey];NSDictionary *localService=[self localServiceForURL:sourceURL];
    if(localService){
        if(![PyHost isRunningServiceIdentifier:localService[@"id"]]){
            if(![self.deferredLocalSubscriptions containsObject:sourceKey])[self log:@"本机订阅暂缓加载，等待服务启动 %@",CCTVServiceLogAddress(sourceKey)];
            [self.deferredLocalSubscriptions addObject:sourceKey];[ProfileStore update:sourceKey values:@{@"status":@"等待本机服务启动"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];return;
        }
        NSString *origin=[self originForURL:sourceURL];NSNumber *readyAt=self.readyLocalOrigins[origin];
        if(!readyAt||CACurrentMediaTime()-readyAt.doubleValue>2){
            // 就绪检查进行中时不要静默丢弃用户的刷新请求：登记一次待处理，
            // 待本次探测结束（失败分支）再重调一次；成功分支本身就会重调，
            // 故只在失败分支消费，避免重复与死循环。
            if(self.subscriptionReadiness[sourceKey]){if(!self.pendingSubscriptionRefresh)self.pendingSubscriptionRefresh=[NSMutableSet set];[self.pendingSubscriptionRefresh addObject:sourceKey];return;}
            NSUInteger readinessVersion=[self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]+1;self.subscriptionRequestVersions[sourceKey]=@(readinessVersion);
            LocalServiceReadiness *probe=[self readinessForURL:sourceURL service:localService];self.subscriptionReadiness[sourceKey]=probe;__weak typeof(self) w=self;
            [probe start:^(NSError *error,NSTimeInterval elapsed){
                if(w.subscriptionReadiness[sourceKey]!=probe)return;[w.subscriptionReadiness removeObjectForKey:sourceKey];
                if([w.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]!=readinessVersion||![w.subscriptionURLs containsObject:sourceKey])return;
                NSMutableDictionary *probeFields=[@{@"correlation_id":traceID?:@"", @"service_id":localService[@"id"]?:@"", @"service_name":localService[@"name"]?:@"", @"engine":localService[@"engine"]?:@"python", @"port":localService[@"port"]?:@0, @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:probe.diagnosticSummary];[probeFields addEntriesFromDictionary:CCTVDiagnosticURLFields(sourceURL)];
                if(error){probeFields[@"error_domain"]=error.domain?:@"";probeFields[@"error_code"]=@(error.code);probeFields[@"error_message"]=error.localizedDescription?:@"";[RuntimeDiagnostics.shared recordEvent:@"local_service_health_failed" category:@"service" fields:probeFields];[ProfileStore update:sourceKey values:@{@"status":error.localizedDescription?:@"服务未就绪"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[w refreshConfigurationPage];[w logPluginLine:[NSString stringWithFormat:@"订阅接口健康检查失败 · %@",[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"]] identifier:localService[@"id"] name:localService[@"name"]];[w log:@"本机订阅等待服务失败 %@",error.localizedDescription];if([w.pendingSubscriptionRefresh containsObject:sourceKey]){[w.pendingSubscriptionRefresh removeObject:sourceKey];[w fetchSubscription:sourceKey silent:silent];}return;}
                [RuntimeDiagnostics.shared recordEvent:@"local_service_health_ready" category:@"service" fields:probeFields];[w logPluginLine:[NSString stringWithFormat:@"订阅接口健康检查通过 · %.2f 秒",elapsed] identifier:localService[@"id"] name:localService[@"name"]];
                w.readyLocalOrigins[origin]=@(CACurrentMediaTime());[w.deferredLocalSubscriptions removeObject:sourceKey];[w fetchSubscription:sourceKey silent:silent];
            }];return;
        }
    }
    NSUInteger requestVersion = [self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] + 1;
    self.subscriptionRequestVersions[sourceKey] = @(requestVersion);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    NSString *playlistUserAgent=[ProfileStore metadata:sourceKey][@"userAgent"];
    if([playlistUserAgent isKindOfClass:NSString.class]&&playlistUserAgent.length<=1024&&[playlistUserAgent rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location==NSNotFound)[req setValue:playlistUserAgent forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) weakSelf = self;NSTimeInterval requestStartedAt=CACurrentMediaTime();
    NSMutableDictionary *subscriptionFields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"timeout_seconds":@12} mutableCopy];[subscriptionFields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];
    [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_started" category:@"subscription" fields:subscriptionFields];
    NSURLSessionDataTask *subscriptionTask=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status=[resp isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)resp statusCode]:0;
        NSUInteger receivedBytes=data.length;NSString *mimeType=resp.MIMEType?:@"";
        if(status<200||status>=300||data.length>10*1024*1024)data=nil;
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSError *parseError=nil;
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:resp.URL?:url error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] != requestVersion) return;
            [weakSelf.subscriptionTasks removeObjectForKey:sourceKey];
            if (!list.count) {
                NSString *failureStage=err?@"network_or_timeout":(parseError?@"parse_limit":((status<200||status>=300)?@"http_status":(receivedBytes>10*1024*1024?@"response_too_large":(receivedBytes==0?@"empty_response":(text.length?@"no_valid_channels":@"invalid_utf8")))));
                NSMutableDictionary *fields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"http_status":@(status), @"response_mime_type":mimeType, @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-requestStartedAt)*1000)), @"error_domain":err.domain?:@"", @"error_code":@(err.code), @"error_message":err.localizedDescription?:@"", @"received_bytes":@(receivedBytes), @"failure_stage":failureStage} mutableCopy];
                [fields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];
                [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:fields];
                [weakSelf.subscriptionTraceIDs removeObjectForKey:sourceKey];
                NSDictionary *sourceMetadata=[ProfileStore metadata:sourceKey];id cachedChannels=sourceMetadata[@"cachedChannels"];
                NSUInteger retainedCount=[cachedChannels isKindOfClass:NSArray.class]?[(NSArray *)cachedChannels count]:0;
                if(!retainedCount)for(NSDictionary *channel in weakSelf.allChannels)if([CCTVStringArrayValue(channel[@"subscriptionSources"]) containsObject:sourceKey])retainedCount++;
                NSString *reason=err.localizedDescription?:parseError.localizedDescription?:[NSString stringWithFormat:@"HTTP %ld / 无有效 M3U",(long)status];
                NSString *statusText=retainedCount?[NSString stringWithFormat:@"刷新失败 · 保留上次 %lu 个频道 · %@",(unsigned long)retainedCount,reason]:[NSString stringWithFormat:@"刷新失败 · %@",reason];
                [ProfileStore update:sourceKey values:@{@"status":statusText}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[weakSelf refreshConfigurationPage];
                if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅地址读取失败 · %@",[HostLogRedactor redactText:reason]] identifier:localService[@"id"] name:localService[@"name"]];
                [weakSelf log:@"订阅失败 %@ %@", CCTVServiceLogAddress(urlString), [HostLogRedactor redactText:err.localizedDescription ?: @"无有效条目"]];
                return;
            }
            NSMutableDictionary *fields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"http_status":@(status), @"response_mime_type":mimeType, @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-requestStartedAt)*1000)), @"channel_count":@(list.count), @"received_bytes":@(receivedBytes)} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_succeeded" category:@"subscription" fields:fields];[weakSelf.subscriptionTraceIDs removeObjectForKey:sourceKey];
            NSString *detected=[M3UParser epgURL:text baseURL:resp.URL?:url];if(detected.length){NSString *prior=[ProfileStore metadata:sourceKey][@"detectedEPGURL"]?:[ProfileStore metadata:sourceKey][@"epgURL"];[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];if(![prior isEqual:detected])[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];if(localService&&![prior isEqual:detected])[weakSelf logPluginLine:[NSString stringWithFormat:@"节目单地址：%@",CCTVServiceLogAddress(detected)] identifier:localService[@"id"] name:localService[@"name"]];}
            // 新清单不再提供节目单地址时清掉过期推导值，否则行上永远显示
            // “已配置”，且 EPG 页会继续用旧地址。失败路径不碰它。
            else if([ProfileStore metadata:sourceKey][@"detectedEPGURL"]){[ProfileStore removeValueForKey:@"detectedEPGURL" source:sourceKey];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];if(localService)[weakSelf logPluginLine:@"节目单地址已清除 · 新订阅清单未提供节目单" identifier:localService[@"id"] name:localService[@"name"]];}
            if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅清单可读取 · %lu 个频道",(unsigned long)list.count] identifier:localService[@"id"] name:localService[@"name"]];
            [weakSelf installPlaylist:list source:sourceKey];
        });
    }];self.subscriptionTasks[sourceKey]=subscriptionTask;[subscriptionTask resume];
}
// 资源页单条目刷新：行里的 source 可能是订阅 URL，也可能是 plugin:<id>。
// 插件行先解析到它自己的订阅清单地址，再走同一条刷新链路。
- (void)refreshSubscriptionForProfile:(NSString *)source {
    if(!source.length){
        [self.epgCache removeAllObjects];
        [self applyFilter];
        [self refreshChannelPreviewSnapshotsForChannels:self.shownChannels force:YES];
        if(self.firstRender)[self refreshNowNext];
        [ProfileStore update:@"" values:@{@"status":@"内置官方 · 节目单已同步",@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:@""];
        [self refreshConfigurationPage];
        return;
    }
    NSString *url=source;
    NSDictionary *service=[self resourceServiceForSource:source];
    if(service)url=[ServiceStore subscriptionURLForService:service]?:@"";
    if(!url.length){[self showServiceError:@"此资源没有可刷新的订阅清单"];return;}
    [self fetchSubscription:url silent:NO];
}
// 单条目健康重查：有订阅清单的走一次带就绪探测的刷新（先丢弃该源
// 2 秒内的就绪缓存，强制重新探测）；无清单的插件直接对服务做一次
// 就绪探测，成功只写日志并刷新本行，失败弹明确提示。
- (void)recheckProfileHealth:(NSString *)source {
    if(!source.length){
        [ProfileStore update:@"" values:@{@"status":@"内置官方 · 健康检测通过",@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:@""];
        [self refreshConfigurationPage];
        return;
    }
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *url=service?[ServiceStore subscriptionURLForService:service]?:@"":source;
    if(url.length){NSURL *u=[NSURL URLWithString:url];if(u&&[self localServiceForURL:u])[self.readyLocalOrigins removeObjectForKey:[self originForURL:u]];[self fetchSubscription:url silent:NO];return;}
    if(!service){[self showServiceError:@"找不到此资源，无法检测健康状态"];return;}
    if(![PyHost isRunningServiceIdentifier:service[@"id"]]){[self showServiceError:@"服务未运行，无法检测健康状态。请先启动服务。"];return;}
    NSURL *base=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@",service[@"port"]?:@0]];
    LocalServiceReadiness *probe=[self readinessForURL:base service:service];
    if(!self.subscriptionReadiness)self.subscriptionReadiness=[NSMutableDictionary dictionary];
    [self.subscriptionReadiness[source] cancel];self.subscriptionReadiness[source]=probe;
    __weak typeof(self) weakSelf=self;
    [probe start:^(NSError *error,NSTimeInterval elapsed){
        RootViewController *owner=weakSelf;if(!owner||owner.subscriptionReadiness[source]!=probe)return;
        [owner.subscriptionReadiness removeObjectForKey:source];
        // 探测完成前服务已被停掉：停服务本身已刷新页面，不再弹失败提示。
        if(![PyHost isRunningServiceIdentifier:service[@"id"]])return;
        if(error){[owner showServiceError:error.localizedDescription?:@"服务未就绪"];return;}
        [owner logPluginLine:[NSString stringWithFormat:@"健康检查通过 · %.2f 秒",elapsed] identifier:service[@"id"] name:service[@"name"]];
        NSString *origin=[owner originForURL:base];if(origin.length)owner.readyLocalOrigins[origin]=@(CACurrentMediaTime());
        [owner refreshConfigurationPage];
    }];
}
// 单条目 EPG 重匹配：复用订阅刷新链路，新清单重新推导 detectedEPGURL；
// 若新清单不再提供节目单地址，成功路径会清掉过期值（见 fetchSubscription）。
- (void)rematchEPGForProfile:(NSString *)source {
    if(!source.length){
        [self matchOfficialStationLogosAndEPGForSource:@""];
        return;
    }
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *url=service?[ServiceStore subscriptionURLForService:service]?:@"":source;
    if(!url.length){[self showServiceError:@"此资源没有订阅清单，无法重新匹配节目单"];return;}
    [self fetchSubscription:url silent:NO];
}
// 单条目合集刷新：按原地址重新下载并解析，解析出的新 id 换回原合集 id
// 后保存——saveCatalog 按 id 合并，行不会重复，站点/直播数就地更新。
// MacCMS 行的 url 是接口地址，不走 JSON 下载；空合集不覆盖原合集。
- (void)refreshTVBoxCatalogProfile:(NSString *)source {
    NSString *identifier=[source hasPrefix:@"tvbox:"]?[source substringFromIndex:6]:@"";
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];
    if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    if([[catalog[@"catalogKind"] isKindOfClass:NSString.class]?catalog[@"catalogKind"]:@"" isEqual:@"maccms"]){[self showServiceError:@"MacCMS 影视接口按接口配置使用，无需下载刷新"];return;}
    NSURL *url=[NSURL URLWithString:[catalog[@"url"] isKindOfClass:NSString.class]?catalog[@"url"]:@""];
    if(!url||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]){[self showServiceError:@"此合集没有可重新下载的配置地址"];return;}
    [self.tvboxCatalogDownloader cancel];self.tvboxCatalogDownloader=[TVBoxCatalogDownloader new];
    self.navigationItem.prompt=@"正在重新下载资源合集…";
    __weak typeof(self) weakSelf=self;
    [self.tvboxCatalogDownloader loadURL:url completion:^(NSDictionary *fresh,NSError *error){
        RootViewController *owner=weakSelf;if(!owner)return;owner.navigationItem.prompt=nil;
        if(error||!fresh){[owner showServiceError:error.localizedDescription?:@"资源合集下载失败"];return;}
        NSArray *sites=[fresh[@"sites"] isKindOfClass:NSArray.class]?fresh[@"sites"]:@[];
        NSArray *lives=[fresh[@"lives"] isKindOfClass:NSArray.class]?fresh[@"lives"]:@[];
        if(!sites.count&&!lives.count){[owner showServiceError:@"重新下载的合集为空，已保留原合集"];return;}
        NSMutableDictionary *updated=[fresh mutableCopy];updated[@"id"]=identifier;
        [TVBoxCatalogStore saveCatalog:updated];
        [owner refreshConfigurationPage];
        [owner log:@"资源合集已刷新 · %@ · %lu 个站点",(fresh[@"name"]?:catalog[@"name"]?:@"资源合集"),(unsigned long)sites.count];
    }];
}
- (void)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey {
            NSDictionary *managedService=[self localServiceForURL:[NSURL URLWithString:sourceKey]];
            NSArray<NSString *> *retiredManagedSources=managedService?[self managedSubscriptionSourcesForService:managedService excludingURL:sourceKey]:@[];
            NSSet<NSString *> *retiredSourceSet=[NSSet setWithArray:retiredManagedSources];
            NSMutableArray *merged = [NSMutableArray array];
            for (NSDictionary *existing in self.allChannels ?: @[]) {
                NSArray *originalOwners=CCTVStringArrayValue(existing[@"subscriptionSources"]);NSMutableSet *owners = [NSMutableSet setWithArray:originalOwners];
                [owners minusSet:retiredSourceSet];
                if ([owners containsObject:sourceKey]) {
                    [owners removeObject:sourceKey];
                    if (!owners.count) continue;
                    NSMutableDictionary *copy = [existing mutableCopy];
                    copy[@"subscriptionSources"] = owners.allObjects;
                    [merged addObject:copy];
                } else if(!owners.count) {
                    // Built-in SDK channels have no subscription owner. Keep them
                    // when replacing a playlist; only discard channels that were
                    // owned by a subscription and became orphaned above.
                    if (!originalOwners.count) [merged addObject:existing];
                } else if(owners.count!=originalOwners.count) {
                    NSMutableDictionary *copy=[existing mutableCopy];copy[@"subscriptionSources"]=owners.allObjects;[merged addObject:copy];
                } else {
                    [merged addObject:existing];
                }
            }
            NSMutableDictionary<NSString *, NSNumber *> *urlIndexes = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < merged.count; i++) {
                NSString *stable = [self stableURLKey:merged[i][@"remoteURL"]];
                if (stable.length) urlIndexes[stable] = @(i);
            }
            NSUInteger added = 0;
            NSUInteger skippedInvalidURLs = 0;
            for (M3UChannel *c in list) {
                if (!c.name.length || !c.url.length) { skippedInvalidURLs++; continue; }
                NSString *stable = [self stableURLKey:c.url];
                if (!stable.length) { skippedInvalidURLs++; continue; }
                NSNumber *existingIndex = urlIndexes[stable];
                if (existingIndex) {
                    NSMutableDictionary *entry = [merged[existingIndex.unsignedIntegerValue] mutableCopy];
                    NSMutableSet *owners = [NSMutableSet setWithArray:CCTVStringArrayValue(entry[@"subscriptionSources"])];
                    [owners addObject:sourceKey];
                    entry[@"subscriptionSources"] = owners.allObjects;
                    entry[@"name"] = c.name;
                    entry[@"group"] = c.group ?: @"订阅";
                    if (c.epgID.length) entry[@"epgID"]=c.epgID;
                    if (c.tvgName.length) entry[@"tvgName"]=c.tvgName; else [entry removeObjectForKey:@"tvgName"];
                    if (c.logo.length) entry[@"logo"] = c.logo; else [entry removeObjectForKey:@"logo"];
                    if (c.headers.count) entry[@"headers"] = c.headers; else [entry removeObjectForKey:@"headers"];
                    for(NSString *key in @[@"catchupSource",@"catchupMode",@"catchupDays",@"tvgShift"])[entry removeObjectForKey:key];
                    if(c.catchupSource.length){entry[@"catchupSource"]=c.catchupSource;entry[@"catchupMode"]=c.catchupMode?:@"default";entry[@"catchupDays"]=@(c.catchupDays);entry[@"tvgShift"]=@(c.tvgShift);}
                    entry[@"remoteURL"] = c.url;
                    if(c.epgID.length)entry[@"epgID"]=c.epgID;else[entry removeObjectForKey:@"epgID"];
                    merged[existingIndex.unsignedIntegerValue] = entry;
                } else {
                    NSMutableDictionary *entry = [@{@"id": stable,
                                                    @"name": c.name,
                                                    @"group": c.group ?: @"订阅",
                                                    @"verified": @NO,
                                                    @"remoteURL": c.url,
                                                    @"subscriptionSources": @[sourceKey]} mutableCopy];
                    if (c.epgID.length) entry[@"epgID"]=c.epgID;
                    if (c.tvgName.length) entry[@"tvgName"]=c.tvgName;
                    if (c.logo.length) entry[@"logo"] = c.logo;
                    if (c.headers.count) entry[@"headers"] = c.headers;
                    if(c.catchupSource.length){entry[@"catchupSource"]=c.catchupSource;entry[@"catchupMode"]=c.catchupMode?:@"default";entry[@"catchupDays"]=@(c.catchupDays);entry[@"tvgShift"]=@(c.tvgShift);}
                    urlIndexes[stable] = @(merged.count);
                    [merged addObject:entry];
                    added++;
                }
            }
            if(merged.count>20000){NSString *message=@"合并后频道数量超过 20000 条安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"merged_channel_limit",@"channel_count":@(merged.count)}];[self refreshConfigurationPage];[self log:@"%@",message];return;}
            NSArray *owned=[merged filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *b){return [CCTVStringArrayValue(c[@"subscriptionSources"]) containsObject:sourceKey];}]];
            NSData *snapshot=[NSJSONSerialization dataWithJSONObject:owned options:0 error:NULL];
            if(!snapshot.length||snapshot.length>4*1024*1024){NSString *message=@"频道快照超过 4 MiB 安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"snapshot_size_limit",@"snapshot_bytes":@(snapshot.length)}];[self refreshConfigurationPage];[self log:@"%@",message];return;}
            NSArray *disabledBefore=[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[];BOOL migratedDisabled=NO;NSMutableArray *profileOrder=[[NSUserDefaults.standardUserDefaults arrayForKey:@"profileOrder"]?:@[] mutableCopy];NSUInteger replacementOrderIndex=NSNotFound;
            for(NSString *retiredSource in retiredManagedSources){if([disabledBefore containsObject:retiredSource])migratedDisabled=YES;NSUInteger position=[profileOrder indexOfObject:retiredSource];if(position!=NSNotFound&&position<replacementOrderIndex)replacementOrderIndex=position;[profileOrder removeObject:retiredSource];}
            if(replacementOrderIndex!=NSNotFound){[profileOrder removeObject:sourceKey];[profileOrder insertObject:sourceKey atIndex:MIN(replacementOrderIndex,profileOrder.count)];[NSUserDefaults.standardUserDefaults setObject:profileOrder forKey:@"profileOrder"];}
            for(NSString *retiredSource in retiredManagedSources){
                [ProfileStore migrateResourceDisplaySettingsFromSource:retiredSource toSource:sourceKey];
                self.subscriptionRequestVersions[retiredSource]=@([self.subscriptionRequestVersions[retiredSource] unsignedIntegerValue]+1);
                [self.subscriptionTasks[retiredSource] cancel];[self.subscriptionTasks removeObjectForKey:retiredSource];
                [self.subscriptionReadiness[retiredSource] cancel];[self.subscriptionReadiness removeObjectForKey:retiredSource];[self.deferredLocalSubscriptions removeObject:retiredSource];
                NSString *oldOrigin=[self originForURL:[NSURL URLWithString:retiredSource]];if(oldOrigin.length)[self.readyLocalOrigins removeObjectForKey:oldOrigin];
                [self.subscriptionTraceIDs removeObjectForKey:retiredSource];[self.subscriptionURLs removeObject:retiredSource];[ProfileStore remove:retiredSource];
            }
            if(migratedDisabled){NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];if(![disabled containsObject:sourceKey])[disabled addObject:sourceKey];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}
            if(retiredManagedSources.count){[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];[self logPluginLine:[NSString stringWithFormat:@"新订阅地址已验证，已替换 %lu 个旧服务地址",(unsigned long)retiredManagedSources.count] identifier:managedService[@"id"] name:managedService[@"name"]];}
            self.allChannels = merged;
            [self.altSources removeAllObjects];for(NSDictionary *c in merged){NSString *url=c[@"remoteURL"],*groupKey=CCTVRouteGroupKey(c);if(!url.length||!groupKey.length)continue;if(!self.altSources[groupKey])self.altSources[groupKey]=[NSMutableArray array];if(![self.altSources[groupKey] containsObject:url])[self.altSources[groupKey] addObject:url];}
            [ProfileStore update:sourceKey values:@{@"cachedChannels":owned,@"status":@"已更新",@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
            [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];
            [self applyFilter];
            [self refreshChannelPreviewSnapshotsForChannels:owned force:YES];
            if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];
            if (skippedInvalidURLs) [self log:@"订阅跳过 %lu 条无效地址（仅允许有效 HTTP/HTTPS URL）", (unsigned long)skippedInvalidURLs];
            [self log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", CCTVServiceLogAddress(sourceKey), (unsigned long)added, (unsigned long)list.count];
}
- (void)applyPlaylistText:(NSString *)text source:(NSString *)sourceKey {
    NSString *traceID=NSUUID.UUID.UUIDString.lowercaseString;
    NSUInteger byteCount=[[text dataUsingEncoding:NSUTF8StringEncoding] length];
    [RuntimeDiagnostics.shared recordEvent:@"subscription_text_parse_started" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount)}];
    NSDictionary *report=[M3UParser reportForText:text baseURL:nil];NSArray *list=report[@"channels"];[ProfileStore update:sourceKey values:@{@"unsupportedProtocols":report[@"unsupportedProtocols"]?:@{}}];
    if(!list.count){
        [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount), @"channel_count":@0, @"failure_stage":text.length?@"no_valid_channels":@"empty_input"}];
        [ProfileStore update:sourceKey values:@{@"status":@"无有效 HTTP/HTTPS 频道，保留上次频道"}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];
        [self refreshConfigurationPage];
        return;
    }
    [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_succeeded" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount), @"channel_count":@(list.count)}];
    NSString *detected=[M3UParser epgURL:text baseURL:nil];
    if(detected.length)[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];
    else if([ProfileStore metadata:sourceKey][@"detectedEPGURL"]){[ProfileStore removeValueForKey:@"detectedEPGURL" source:sourceKey];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];}
    [self installPlaylist:list source:sourceKey];
}
- (void)refreshConfigurationPage {if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];[self updateLiveResourceCapsule];}
- (void)importPlaylistData:(NSData *)data name:(NSString *)name {
    if(![self importPlaylistData:data name:name metadata:@{}])[self showServiceError:@"文件须为 UTF-8 M3U 播放列表，包含有效 HTTP/HTTPS 频道，且不超过 10MB。"];
}
- (NSString *)importPlaylistData:(NSData *)data name:(NSString *)name metadata:(NSDictionary *)metadata {
    NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;if(!text.length)return nil;NSArray *channels=[M3UParser parse:text baseURL:nil];if(!channels.count)return nil;
    NSString *source=[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString];NSArray *snapshot=CCTVPlaylistSnapshotRows(channels,source);NSMutableDictionary *values=[@{@"name":name?:@"本地播放列表",@"text":text,@"cachedChannels":snapshot} mutableCopy];if([metadata isKindOfClass:NSDictionary.class])[values addEntriesFromDictionary:metadata];[ProfileStore update:source values:values];[self.subscriptionURLs addObject:source];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];[self applyPlaylistText:text source:source];return source;
}
- (void)replaceSubscription:(NSString *)source URL:(NSString *)url values:(NSDictionary *)values disabled:(BOOL)disabled completion:(void (^)(NSError *error))completion {
    if([self.subscriptionURLs containsObject:url]){completion([NSError errorWithDomain:@"SubscriptionEdit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"该地址已存在，请编辑已有订阅"}]);return;}
    if(!self.subscriptionEditTasks)self.subscriptionEditTasks=[NSMutableDictionary dictionary];
    [self.subscriptionEditTasks[source] cancel];
    UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在验证新订阅" message:@"验证成功后替换；原订阅和频道暂时保留。" preferredStyle:UIAlertControllerStyleAlert];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    __weak typeof(self) weakSelf=self;__block NSURLSessionDownloadTask *task=nil;
    task=[NSURLSession.sharedSession downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *error){
        NSNumber *size=nil;[location getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        NSData *data=(location.path.length&&size&&!error&&status>=200&&status<300&&size.unsignedLongLongValue<=10*1024*1024)?[NSData dataWithContentsOfFile:location.path options:NSDataReadingMappedIfSafe error:NULL]:nil;
        NSString *text=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
        NSArray *channels=text.length?[M3UParser parse:text baseURL:response.URL?:[NSURL URLWithString:url]]:nil;
        dispatch_async(dispatch_get_main_queue(),^{RootViewController *owner=weakSelf;if(!owner||owner.subscriptionEditTasks[source]!=(id)task)return;[owner.subscriptionEditTasks removeObjectForKey:source];
            [progress dismissViewControllerAnimated:YES completion:^{
                if(!channels.count){completion(error?:[NSError errorWithDomain:@"SubscriptionEdit" code:2 userInfo:@{NSLocalizedDescriptionKey:@"新地址没有返回有效频道，已保留原订阅"}]);return;}
                if(![owner.subscriptionURLs containsObject:source]){completion([NSError errorWithDomain:@"SubscriptionEdit" code:3 userInfo:@{NSLocalizedDescriptionKey:@"原订阅已被移除，未保存此次编辑"}]);return;}
                NSArray *ordered=[ProfileStore orderedSources:owner.subscriptionURLs.allObjects];NSMutableArray *replacement=[ordered mutableCopy];NSUInteger index=[replacement indexOfObject:source];if(index!=NSNotFound)replacement[index]=url;
                BOOL selected=[owner.activeSource isEqual:source];NSMutableDictionary *metadata=[values mutableCopy];[metadata removeObjectForKey:@"cachedChannels"];[metadata removeObjectForKey:@"detectedEPGURL"];
                NSString *epg=[M3UParser epgURL:text baseURL:response.URL?:[NSURL URLWithString:url]];if(epg.length)metadata[@"detectedEPGURL"]=epg;
                [ProfileStore migrateResourceDisplaySettingsFromSource:source toSource:url];[owner deleteSubscription:source];[owner.subscriptionURLs addObject:url];[ProfileStore update:url values:metadata];
                NSMutableArray *disabledSources=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabledSources removeObject:source];[disabledSources removeObject:url];if(disabled)[disabledSources addObject:url];[NSUserDefaults.standardUserDefaults setObject:disabledSources forKey:@"disabledSubscriptions"];
                [NSUserDefaults.standardUserDefaults setObject:replacement forKey:@"subscriptions"];
                if(selected)owner.activeSource=url;[owner.epgCache removeAllObjects];[owner installPlaylist:channels source:url];[owner refreshConfigurationPage];completion(nil);
            }];
        });
    }];
    self.subscriptionEditTasks[source]=(id)task;
    [progress addAction:[UIAlertAction actionWithTitle:@"取消验证" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(owner.subscriptionEditTasks[source]==(id)task)[owner.subscriptionEditTasks removeObjectForKey:source];[task cancel];completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
    [self.navigationController.topViewController presentViewController:progress animated:YES completion:^{[task resume];}];
}
- (void)editProfile:(NSString *)source {[self openSubscriptionProfile:source editing:YES];}
- (void)openSubscriptionProfile:(NSString *)source editing:(BOOL)editing {
    SubscriptionResourceViewController *page=[SubscriptionResourceViewController new];page.source=source;page.initiallyEditing=editing;__weak typeof(self) weakSelf=self;__weak SubscriptionResourceViewController *weakPage=page;
    page.profileProvider=^{RootViewController *owner=weakSelf;NSString *current=weakPage.source?:source;return [owner configurationProfileForSource:current]?:@{};};
    page.onCommit=^(NSString *name,NSString *url,NSString *epg,void (^completion)(NSError *error)){
        RootViewController *owner=weakSelf;NSString *current=weakPage.source?:source;if(!owner){completion([NSError errorWithDomain:@"SubscriptionEdit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"页面已关闭"}]);return;}
        NSMutableDictionary *values=[[ProfileStore metadata:current] mutableCopy];values[@"name"]=name;values[@"epgURL"]=epg;
        if(![url isEqual:current]){BOOL disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] containsObject:current];[owner replaceSubscription:current URL:url values:values disabled:disabled completion:completion];return;}
        [ProfileStore update:current values:values];[owner.epgCache removeAllObjects];[owner applyFilter];[owner refreshConfigurationPage];completion(nil);
    };
    page.onOpen=^{RootViewController *owner=weakSelf;if(!owner)return;NSString *current=weakPage.source?:source;[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[current.length?1:0]];owner.activeSource=current;[owner applyFilter];[owner updateLiveResourceCapsule];};
    page.onRefresh=^{[weakSelf refreshSubscriptionForProfile:weakPage.source?:source];};page.onExport=^{[weakSelf exportResource:weakPage.source?:source format:@"single"];};page.onRecheckHealth=^{[weakSelf recheckProfileHealth:weakPage.source?:source];};page.onRematchEPG=^{[weakSelf rematchEPGForProfile:weakPage.source?:source];};page.onMatchStationLogos=^{[weakSelf matchOfficialStationLogosAndEPGForSource:weakPage.source?:source];};page.onDelete=^{[weakSelf deleteSubscription:weakPage.source?:source];[weakSelf refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];[self.navigationController pushViewController:page animated:YES];
}
- (void)editEPGMapping:(NSDictionary *)ch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EPG 手动匹配" message:@"输入 XMLTV channel ID 或央视官方频道 ID；留空恢复自动匹配。" preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *t){t.text=[ProfileStore epgIDForChannel:ch];t.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *m=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{} mutableCopy];NSString *key=ch[@"id"];NSString *value=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length)m[key]=value;else[m removeObjectForKey:key];[NSUserDefaults.standardUserDefaults setObject:m forKey:@"epgMappings"];[self.epgCache removeObjectForKey:key];[self saveEPGCache];[self applyFilter];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)showRemoteTools:(NSDictionary *)ch {
    BOOL supportsCatchup = [self channelSupportsCatchup:ch];
    NSString *subtitle = supportsCatchup ? @"订阅频道 · 支持节目回看" : @"订阅频道 · AVPlayer";
    UIAlertController *a=[UIAlertController alertControllerWithTitle:ch[@"name"] message:subtitle preferredStyle:UIAlertControllerStyleActionSheet];
    if ([ch[@"id"] isEqualToString:self.channelID] && self.remoteCatchupActive) {
        [a addAction:[UIAlertAction actionWithTitle:@"返回实时直播" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self returnToLivePlayback];}]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"重新播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self routePlayback:ch];}]];
    for(NSString *url in self.altSources[CCTVRouteGroupKey(ch)]){if([url isEqual:ch[@"remoteURL"]])continue;[a addAction:[UIAlertAction actionWithTitle:[NSURL URLWithString:url].host?:@"备用源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *other=[ch mutableCopy];other[@"remoteURL"]=url;[self routePlayback:other];}]];}
    [a addAction:[UIAlertAction actionWithTitle:supportsCatchup?@"节目单与回看":@"节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self openEPGforChannel:ch[@"id"] name:ch[@"name"]];}]];
    if ([ch[@"id"] isEqualToString:self.channelID] && (supportsCatchup || [self nativeFallbackChannelForChannel:ch])) {
        [a addAction:[UIAlertAction actionWithTitle:@"时移 / 快速回退" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self showNativeTimeshiftActions];}]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"EPG 手动匹配" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self editEPGMapping:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"静音预览（30 秒）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self previewChannel:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)previewChannel:(NSDictionary *)ch {
    if(self.currentPlayer||self.avPlayer||self.playbackReadiness){[self showServiceError:@"为保证正式播放，预览仅在没有频道播放时启动。"];return;}
    NSString *url=[self stableURLKey:ch[@"remoteURL"]];if(!url.length)return;
    NSDictionary *localService=[self localServiceForChannel:ch URL:[NSURL URLWithString:url]];if(localService&&![PyHost isRunningServiceIdentifier:localService[@"id"]]){[self showServiceError:@"请先启动该频道的本机服务。"];return;}
    [self stopPreview];NSURL *previewURL=[NSURL URLWithString:url];NSDictionary *rawHeaders=[ch[@"headers"] isKindOfClass:NSDictionary.class]?ch[@"headers"]:nil;NSDictionary *scopedHeaders=rawHeaders.count?MediaPlaybackHeadersScopedToURL(rawHeaders,previewURL,previewURL):nil;AVURLAsset *previewAsset=[AVURLAsset URLAssetWithURL:previewURL options:scopedHeaders.count?@{@"AVURLAssetHTTPHeaderFieldsKey":scopedHeaders}:nil];self.previewPlayer=[AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:previewAsset]];self.previewPlayer.muted=YES;self.previewLayer=[AVPlayerLayer playerLayerWithPlayer:self.previewPlayer];
    CGFloat previewWidth=MIN(280,self.view.bounds.size.width-32);
    UIView *box=[[UIView alloc] initWithFrame:CGRectMake(16,self.view.safeAreaInsets.top+12,previewWidth,158)];box.backgroundColor=UIColor.blackColor;box.layer.cornerRadius=14;box.clipsToBounds=YES;self.previewBox=box;[self.view addSubview:box];self.previewLayer.frame=box.bounds;self.previewLayer.videoGravity=AVLayerVideoGravityResizeAspect;[box.layer addSublayer:self.previewLayer];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];[close setTitle:@"关闭预览" forState:UIControlStateNormal];close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];close.frame=CGRectMake(MAX(0,previewWidth-100),0,MIN(100,previewWidth),44);[close addTarget:self action:@selector(stopPreview) forControlEvents:UIControlEventTouchUpInside];[box addSubview:close];[self.previewPlayer play];__weak typeof(self) w=self;self.previewTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){[w stopPreview];}];
}
- (void)stopPreview {[self.previewTimer invalidate];self.previewTimer=nil;[self.previewPlayer pause];[self.previewPlayer.currentItem.asset cancelLoading];[self.previewPlayer replaceCurrentItemWithPlayerItem:nil];self.previewPlayer=nil;self.previewLayer.player=nil;[self.previewLayer removeFromSuperlayer];self.previewLayer=nil;[self.previewBox removeFromSuperview];self.previewBox=nil;}
- (void)showHistory {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"最近观看" message:self.recents.count?nil:@"还没有观看记录" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *r in self.recents){NSString *title=[r[@"name"] isKindOfClass:NSString.class]?r[@"name"]:([r[@"id"] isKindOfClass:NSString.class]?r[@"id"]:@"");if(!title.length)title=@"未知频道";[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSDictionary *ch=[self channelWithID:r[@"id"]];if(ch)[self selectChannel:ch];else[self showServiceError:@"该频道已不在配置中，请刷新或重新导入原配置。"];}]];}
    if(self.recents.count)[a addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[self applyFilter];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)showFavoriteManager {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"整理收藏" message:self.favorites.count?@"点选频道可移到收藏首位；频道列表左滑可取消收藏。":@"还没有收藏频道，长按频道即可收藏。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSString *cid in self.favorites){NSDictionary *ch=[self channelWithID:cid];NSString *title=([ch[@"name"] isKindOfClass:NSString.class]&&[ch[@"name"] length])?ch[@"name"]:cid;[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.favorites removeObject:cid];[self.favorites insertObject:cid atIndex:0];[NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];[self applyFilter];}]];}
    if(self.favorites.count)[a addAction:[UIAlertAction actionWithTitle:@"清空收藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self.favorites removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"favorites"];[self configureCatalogNavigation];[self applyFilter];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
@end
