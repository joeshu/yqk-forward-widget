#import "HostSyncRequest.h"
#import "RootViewController_Internal.h"
#import "HostGlassActionSheetViewController.h"

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
    BOOL filteredSpecificSource=NO;
    if(self.activeTab==1){
        __weak typeof(self) weakSelf=self;
        NSMutableArray<UIMenuElement *> *sourceActions=[NSMutableArray array];
        NSUInteger totalLiveCount=0;
        NSString *selectedName=nil;
        NSUInteger selectedCount=0;
        for(NSDictionary *profile in [self configurationProfiles]){
            NSString *kind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"";
            if(!([kind isEqual:@"live"]||[kind isEqual:@"both"])||[profile[@"native"] boolValue]||(profile[@"enabled"]&&![profile[@"enabled"] boolValue]))continue;
            NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
            if(!source.length)continue;
            if([profile[@"type"] isEqual:@"tvbox"]&&![profile[@"liveCount"] unsignedIntegerValue])continue;
            if([profile[@"type"] isEqual:@"plugin"]&&![[profile[@"subscriptionURL"] description] length]&&![profile[@"channelCount"] unsignedIntegerValue])continue;
            NSString *name=[profile[@"name"] isKindOfClass:NSString.class]?profile[@"name"]:source;
            NSUInteger count=[profile[@"count"] unsignedIntegerValue];if(!count)count=[profile[@"channelCount"] unsignedIntegerValue];if(!count)count=[profile[@"liveCount"] unsignedIntegerValue];
            totalLiveCount+=count;
            NSString *typeTag=[profile[@"type"] isEqual:@"plugin"]?@"脚本":([profile[@"type"] isEqual:@"tvbox"]?@"合集":@"订阅");
            NSString *menuTitle=count?[NSString stringWithFormat:@"%@ · %lu 台 (%@)",name,(unsigned long)count,typeTag]:[NSString stringWithFormat:@"%@ (%@)",name,typeTag];
            BOOL selected=[source isEqual:self.activeSource];
            if(selected){selectedName=name;selectedCount=count;filteredSpecificSource=YES;menuTitle=[@"✓ " stringByAppendingString:menuTitle];}
            NSString *iconName=selected?@"checkmark.circle.fill":([profile[@"type"] isEqual:@"plugin"]?@"terminal":([profile[@"type"] isEqual:@"tvbox"]?@"shippingbox":@"dot.radiowaves.left.and.right"));
            NSString *capturedSource=[source copy];
            [sourceActions addObject:[UIAction actionWithTitle:menuTitle image:[UIImage systemImageNamed:iconName] identifier:nil handler:^(UIAction *action){[weakSelf selectLiveResourceSource:capturedSource];}]];
        }
        BOOL allSelected=!self.activeSource.length;
        NSString *allLabel=totalLiveCount?[NSString stringWithFormat:@"全部直播资源 · %lu 台",(unsigned long)totalLiveCount]:@"全部直播资源";
        NSString *allTitle=allSelected?[@"✓ " stringByAppendingString:allLabel]:allLabel;
        UIAction *allAction=[UIAction actionWithTitle:allTitle image:[UIImage systemImageNamed:allSelected?@"checkmark.circle.fill":@"square.stack.3d.up"] identifier:@"live.resource.all" handler:^(UIAction *action){[weakSelf selectLiveResourceSource:nil];}];
        if(!sourceActions.count){
            UIAction *empty=[UIAction actionWithTitle:@"资源页暂无可选直播源" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *action){}];
            empty.attributes=UIMenuElementAttributesDisabled;
            [sourceActions addObject:empty];
        }
        UIAction *addAct=[UIAction actionWithTitle:@"添加直播订阅" image:[UIImage systemImageNamed:@"plus.circle"] identifier:@"live.resource.add" handler:^(UIAction *action){[weakSelf addSubscription];}];
        UIAction *manageAct=[UIAction actionWithTitle:@"管理订阅源" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:@"live.resource.manage" handler:^(UIAction *action){[weakSelf manageSubscriptions];}];
        UIAction *refreshAct=[UIAction actionWithTitle:@"刷新当前订阅" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:@"live.resource.refresh" handler:^(UIAction *action){[weakSelf onPullRefresh];}];
        UIMenu *scopeSection=[UIMenu menuWithTitle:@"" image:nil identifier:@"live.resource.section.scope" options:UIMenuOptionsDisplayInline children:@[allAction]];
        UIMenu *sourcesSection=[UIMenu menuWithTitle:@"" image:nil identifier:@"live.resource.section.sources" options:UIMenuOptionsDisplayInline children:sourceActions];
        UIMenu *actionsSection=[UIMenu menuWithTitle:@"" image:nil identifier:@"live.resource.section.actions" options:UIMenuOptionsDisplayInline children:@[addAct,manageAct,refreshAct]];
        if(selectedName.length)title=selectedCount?[NSString stringWithFormat:@"%@ · %lu",selectedName,(unsigned long)selectedCount]:selectedName;
        else if(totalLiveCount)title=[NSString stringWithFormat:@"全部直播 · %lu",(unsigned long)totalLiveCount];
        title=[title stringByAppendingString:@"  ▾"];
        menu=[UIMenu menuWithTitle:@"切换直播资源" children:@[scopeSection,sourcesSection,actionsSection]];
    }
    UIButtonConfiguration *configuration=[UIButtonConfiguration plainButtonConfiguration];configuration.title=title;configuration.image=[UIImage systemImageNamed:filteredSpecificSource?@"line.3.horizontal.decrease.circle.fill":@"dot.radiowaves.left.and.right"];configuration.imagePlacement=NSDirectionalRectEdgeLeading;configuration.imagePadding=7;configuration.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];configuration.baseForegroundColor=filteredSpecificSource?HostAccent():HostText();configuration.background.backgroundColor=filteredSpecificSource?HostSelectedSurface():HostGlassTint();configuration.background.strokeColor=filteredSpecificSource?[HostAccent() colorWithAlphaComponent:0.55]:HostBorder();configuration.background.strokeWidth=filteredSpecificSource?1.0:0.7;configuration.background.cornerRadius=18;configuration.contentInsets=NSDirectionalEdgeInsetsMake(6,12,6,12);configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];return result;};capsule.configuration=configuration;capsule.menu=menu;capsule.showsMenuAsPrimaryAction=self.activeTab==1;capsule.accessibilityLabel=self.activeTab==1?([title stringByReplacingOccurrencesOfString:@"  ▾" withString:@""]):@"央视直播";capsule.accessibilityHint=self.activeTab==1?@"下拉切换资源页中的直播资源":@"当前为央视官方频道";
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
    NSArray<NSString *> *orderedSources = [ProfileStore orderedSources:self.subscriptionURLs.allObjects];
    NSString *summaryMsg = orderedSources.count
        ? [NSString stringWithFormat:@"共 %lu 个直播订阅源 · 点选管理配置、刷新或匹配台标",(unsigned long)orderedSources.count]
        : @"尚未添加直播订阅源，点下方按钮可立即导入 M3U / TXT 列表。";
    __weak typeof(self) weakSelf = self;
    NSMutableArray<HostGlassSheetSection *> *sections = [NSMutableArray array];
    NSMutableArray<HostGlassSheetAction *> *sourceRows = [NSMutableArray array];
    for (NSString *u in orderedSources) {
        NSDictionary *profile = [self configurationProfileForSource:u] ?: @{};
        NSString *sourceName=[ProfileStore metadata:u][@"name"];
        if(![sourceName isKindOfClass:NSString.class]||!sourceName.length)sourceName=[NSURL URLWithString:u].host;
        NSString *baseTitle = sourceName.length?sourceName:(u.length > 42 ? [[u substringToIndex:42] stringByAppendingString:@"…"] : u);
        NSUInteger count = [profile[@"count"] unsignedIntegerValue];
        BOOL active = [self.activeSource isEqualToString:u];
        NSString *val = count ? [NSString stringWithFormat:@"%lu 台", (unsigned long)count] : nil;
        NSString *statusLine = [profile[@"status"] isKindOfClass:NSString.class] ? profile[@"status"] : @"";
        [sourceRows addObject:[HostGlassSheetAction actionWithTitle:baseTitle subtitle:(statusLine.length ? statusLine : CCTVServiceLogAddress(u)) value:val icon:@"antenna.radiowaves.left.and.right" tint:(active ? HostAccent() : UIColor.systemBlueColor) destructive:NO selected:active handler:^{
            RootViewController *owner = weakSelf;
            if (!owner) return;
            NSString *opMsg = statusLine.length ? [NSString stringWithFormat:@"%@\n%@", statusLine, CCTVServiceLogAddress(u)] : CCTVServiceLogAddress(u);
            NSArray<HostGlassSheetAction *> *viewOps = @[
                [HostGlassSheetAction actionWithTitle:@"仅查看此订阅频道" subtitle:@"在频道列表中筛选显示本订阅源" value:nil icon:@"tv" tint:HostAccent() destructive:NO selected:active handler:^{[owner selectLiveResourceSource:u];}],
                [HostGlassSheetAction actionWithTitle:@"查看与编辑资源详情" subtitle:@"查看地址、编辑名称与 EPG 配置" value:nil icon:@"slider.horizontal.3" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{[owner openSubscriptionProfile:u editing:NO];}]
            ];
            NSArray<HostGlassSheetAction *> *maintOps = @[
                [HostGlassSheetAction actionWithTitle:@"刷新" subtitle:@"重新拉取此订阅频道列表" value:nil icon:@"arrow.clockwise" tint:HostAccent() destructive:NO selected:NO handler:^{[owner fetchSubscription:u silent:NO];}],
                [HostGlassSheetAction actionWithTitle:@"重新检测健康" subtitle:@"测试订阅接口可达性与状态" value:nil icon:@"waveform.path.ecg" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{[owner recheckProfileHealth:u];}],
                [HostGlassSheetAction actionWithTitle:@"智能匹配官方台标与 EPG" subtitle:@"自动关联官方高清台标与节目预告" value:nil icon:@"wand.and.stars" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{[owner matchOfficialStationLogosAndEPGForSource:u];}]
            ];
            NSArray<HostGlassSheetAction *> *dangerOps = @[
                [HostGlassSheetAction actionWithTitle:@"删除" subtitle:@"从本地移除此直播订阅源" value:nil icon:@"trash" tint:UIColor.systemRedColor destructive:YES selected:NO handler:^{
                    NSString *sourceKey = [owner stableURLKey:u];
                    [owner.subscriptionURLs removeObject:sourceKey ?: u];
                    NSString *deletedKey = sourceKey ?: u;
                    owner.subscriptionRequestVersions[deletedKey] = @([owner.subscriptionRequestVersions[deletedKey] unsignedIntegerValue] + 1);
                    [owner removeSubscriptionSource:deletedKey];
                    [[NSUserDefaults standardUserDefaults] setObject:owner.subscriptionURLs.allObjects forKey:@"subscriptions"];
                    [owner log:@"已删除订阅 %@", CCTVServiceLogAddress(u)];
                }]
            ];
            [HostGlassActionSheetViewController presentOn:owner
                                                    title:baseTitle
                                                 subtitle:opMsg
                                                badgeText:(val ?: @"直播订阅")
                                               badgeColor:(active ? HostAccent() : UIColor.systemBlueColor)
                                                 sections:@[
                                                     [HostGlassSheetSection sectionWithTitle:@"频道与配置" actions:viewOps],
                                                     [HostGlassSheetSection sectionWithTitle:@"刷新与增强" actions:maintOps],
                                                     [HostGlassSheetSection sectionWithTitle:@"管理" actions:dangerOps]
                                                 ]
                                               sourceView:(owner.catalogMoreButton ?: owner.bottomBar)];
        }]];
    }
    if (sourceRows.count) {
        [sections addObject:[HostGlassSheetSection sectionWithTitle:@"已添加的订阅源" actions:sourceRows]];
    }
    [sections addObject:[HostGlassSheetSection sectionWithTitle:@"新增" actions:@[
        [HostGlassSheetAction actionWithTitle:@"添加新订阅源" subtitle:@"通过 URL、本地文件或文件夹导入 M3U / TXT" value:nil icon:@"plus.circle.fill" tint:HostAccent() destructive:NO selected:NO handler:^{[weakSelf addSubscription];}]
    ]]];
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"订阅源管理"
                                         subtitle:summaryMsg
                                        badgeText:[NSString stringWithFormat:@"%lu 个订阅", (unsigned long)orderedSources.count]
                                       badgeColor:HostAccent()
                                         sections:sections
                                       sourceView:(self.catalogMoreButton ?: self.bottomBar)];
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
        NSString *origin=[self stableURLKey:candidate[@"origin"]];
        NSString *text=[candidate[@"text"] isKindOfClass:NSString.class]?candidate[@"text"]:@"";
        NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"playlist"]?candidate[@"existingResourceID"]:@"";
        NSString *savedPlaylistSource=nil;
        NSString *message=nil;
        if([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>10*1024*1024)message=@"播放列表超过 10 MiB";
        else if(targetID.length&&![self.subscriptionURLs containsObject:targetID])message=@"旧直播资源已被移除，请重新识别";
        else if(origin.length&&[self.subscriptionURLs containsObject:origin]&&!update)message=@"相同在线订阅只能更新";
        else{
            NSURL *base=origin.length?[NSURL URLWithString:candidate[@"resolvedURL"]?:origin]:nil;
            NSArray *parsed=[M3UParser parse:text baseURL:base];
            NSString *source=targetID.length?targetID:(origin.length?origin:[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString]);
            if(!parsed.count)message=@"播放列表没有有效频道";
            else if(![self installPlaylist:parsed source:source])message=@"频道清单超过容量限制，已保留原资源";
            else{
                NSMutableDictionary *values=[@{@"name":candidate[@"name"]?:@"播放列表",@"text":text} mutableCopy];
                if(candidate[@"importFingerprint"])values[@"importFingerprint"]=candidate[@"importFingerprint"];
                if(sourceFilename.length)values[@"importSourceFilename"]=sourceFilename;
                NSString *detected=[M3UParser epgURL:text baseURL:base];
                if(detected.length)values[@"detectedEPGURL"]=detected;
                [ProfileStore update:source values:values];
                [self.subscriptionURLs addObject:source];
                [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];
                savedPlaylistSource=source;
            }
        }
        if(message)failure=[NSError errorWithDomain:@"ResourceImport" code:10 userInfo:@{NSLocalizedDescriptionKey:message}];
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
    if(silent&&self.subscriptionTasks.count>=3){[self.deferredLocalSubscriptions addObject:sourceKey];return;}
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
    NSURLSessionDataTask *subscriptionTask=HostBoundedDataTask(req, 10*1024*1024, ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status=[resp isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)resp statusCode]:0;
        NSUInteger receivedBytes=data.length;NSString *mimeType=resp.MIMEType?:@"";
        if(status<200||status>=300||data.length>10*1024*1024)data=nil;
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSError *parseError=nil;
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:resp.URL?:url error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] != requestVersion) return;
            [weakSelf.subscriptionTasks removeObjectForKey:sourceKey];
            [weakSelf refreshSubscriptionsWhenIdle];
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
    });self.subscriptionTasks[sourceKey]=subscriptionTask;[subscriptionTask resume];
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
    [self.tvboxCatalogDownloader cancel];
    TVBoxCatalogDownloader *downloader=[TVBoxCatalogDownloader new];
    self.tvboxCatalogDownloader=downloader;
    self.navigationItem.prompt=@"正在重新下载资源合集…";
    __weak typeof(self) weakSelf=self;
    __weak TVBoxCatalogDownloader *weakDownloader=downloader;
    [downloader loadURL:url completion:^(NSDictionary *fresh,NSError *error){
        RootViewController *owner=weakSelf;
        TVBoxCatalogDownloader *completedDownloader=weakDownloader;
        if(!owner||!completedDownloader||owner.tvboxCatalogDownloader!=completedDownloader)return;
        owner.tvboxCatalogDownloader=nil;
        owner.navigationItem.prompt=nil;
        if([error.domain isEqualToString:NSURLErrorDomain]&&error.code==NSURLErrorCancelled)return;
        if(error||!fresh){[owner showServiceError:[NSString stringWithFormat:@"刷新失败 · %@。已保留原合集。",error.localizedDescription?:@"未取得有效配置"]];return;}
        NSArray *sites=[fresh[@"sites"] isKindOfClass:NSArray.class]?fresh[@"sites"]:@[];
        NSArray *lives=[fresh[@"lives"] isKindOfClass:NSArray.class]?fresh[@"lives"]:@[];
        if(!sites.count&&!lives.count){[owner showServiceError:@"重新下载的合集为空，已保留原合集"];return;}
        if(![TVBoxCatalogStore catalogForID:identifier])return;
        NSMutableDictionary *updated=[fresh mutableCopy];updated[@"id"]=identifier;
        // The downloader uses the effective URL to resolve relative entries.
        // Keep the configured address for the next refresh, including after short-lived redirects.
        updated[@"url"]=catalog[@"url"];
        [TVBoxCatalogStore saveCatalog:updated];
        [owner refreshConfigurationPage];
        [owner log:@"资源合集已刷新 · %@ · %lu 个站点",(fresh[@"name"]?:catalog[@"name"]?:@"资源合集"),(unsigned long)sites.count];
    }];
}
- (BOOL)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey {
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
                    NSMutableDictionary *entry = [@{@"id": CCTVSubscriptionChannelID(sourceKey,stable),
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
            if(merged.count>20000){NSString *message=@"合并后频道数量超过 20000 条安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"merged_channel_limit",@"channel_count":@(merged.count)}];[self refreshConfigurationPage];[self log:@"%@",message];return NO;}
            NSArray *owned=[merged filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *b){return [CCTVStringArrayValue(c[@"subscriptionSources"]) containsObject:sourceKey];}]];
            NSData *snapshot=[NSJSONSerialization dataWithJSONObject:owned options:0 error:NULL];
            if(!snapshot.length||snapshot.length>4*1024*1024){NSString *message=@"频道快照超过 4 MiB 安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"snapshot_size_limit",@"snapshot_bytes":@(snapshot.length)}];[self refreshConfigurationPage];[self log:@"%@",message];return NO;}
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
            NSArray *ownedSnapshot = [owned copy];
            NSString *persistKey = [sourceKey copy];
            NSTimeInterval updatedAt = NSDate.date.timeIntervalSince1970;
            [ProfileStore update:persistKey values:@{@"updatedAt":@(updatedAt)}];
            static dispatch_queue_t playlistPersistQueue = nil;
            static dispatch_once_t playlistPersistOnce;
            dispatch_once(&playlistPersistOnce, ^{
                playlistPersistQueue = dispatch_queue_create("com.cctvhost.subscription.persist", DISPATCH_QUEUE_SERIAL);
            });
            dispatch_async(playlistPersistQueue, ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if(![self.subscriptionURLs containsObject:persistKey]||![[ProfileStore metadata:persistKey][@"updatedAt"] isEqual:@(updatedAt)])return;
                    [ProfileStore update:persistKey values:@{@"cachedChannels":ownedSnapshot,@"status":@"已更新",@"updatedAt":@(updatedAt)}];
                    [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:persistKey];
                });
            });
            [self applyFilter];
            [self refreshChannelPreviewSnapshotsForChannels:owned force:YES];
            if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];
            if (skippedInvalidURLs) [self log:@"订阅跳过 %lu 条无效地址（仅允许有效 HTTP/HTTPS URL）", (unsigned long)skippedInvalidURLs];
            [self log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", CCTVServiceLogAddress(sourceKey), (unsigned long)added, (unsigned long)list.count];
    return YES;
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
    NSString *source=[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString];
    if(![self installPlaylist:channels source:source])return nil;
    NSMutableDictionary *values=[@{@"name":name?:@"本地播放列表",@"text":text} mutableCopy];
    if([metadata isKindOfClass:NSDictionary.class])[values addEntriesFromDictionary:metadata];
    NSString *epg=[M3UParser epgURL:text baseURL:nil];
    if(epg.length)values[@"detectedEPGURL"]=epg;
    [ProfileStore update:source values:values];
    [self.subscriptionURLs addObject:source];
    [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];
    return source;
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
                if(![owner installPlaylist:channels source:url]){
                    completion([NSError errorWithDomain:@"SubscriptionEdit" code:4 userInfo:@{NSLocalizedDescriptionKey:@"新订阅超过频道容量限制，原订阅已保留"}]);
                    return;
                }
                [ProfileStore migrateResourceDisplaySettingsFromSource:source toSource:url];
                if([owner.subscriptionURLs containsObject:source])[owner deleteSubscription:source];
                [owner.subscriptionURLs addObject:url];[ProfileStore update:url values:metadata];
                NSMutableArray *disabledSources=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabledSources removeObject:source];[disabledSources removeObject:url];if(disabled)[disabledSources addObject:url];[NSUserDefaults.standardUserDefaults setObject:disabledSources forKey:@"disabledSubscriptions"];
                [NSUserDefaults.standardUserDefaults setObject:replacement forKey:@"subscriptions"];
                if(selected)owner.activeSource=url;[owner.epgCache removeAllObjects];[owner refreshConfigurationPage];completion(nil);
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
    NSString *chName = [ch[@"name"] isKindOfClass:NSString.class] && [ch[@"name"] length] ? ch[@"name"] : @"当前频道";
    NSString *currentID = [ProfileStore epgIDForChannel:ch] ?: @"";
    NSString *nowProg = [self.epgCache[ch[@"id"] ?: @""][@"now"] isKindOfClass:NSString.class] ? self.epgCache[ch[@"id"] ?: @""][@"now"] : @"";
    NSString *msg = [NSString stringWithFormat:@"输入 XMLTV channel ID 或央视官方频道 ID；留空恢复自动匹配。%@",
                     (nowProg.length ? [NSString stringWithFormat:@"\n当前在播：%@", nowProg] : (currentID.length ? [NSString stringWithFormat:@"\n当前映射：%@", currentID] : @""))];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"EPG 手动匹配 · %@", chName] message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){
        t.text=currentID;
        t.placeholder=@"例如 cctv1 或 XMLTV 频道标识";
        t.clearButtonMode=UITextFieldViewModeWhileEditing;
        t.autocapitalizationType=UITextAutocapitalizationTypeNone;
        t.autocorrectionType=UITextAutocorrectionTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (currentID.length) {
        [a addAction:[UIAlertAction actionWithTitle:@"恢复自动匹配" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            NSMutableDictionary *m=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{} mutableCopy];
            NSString *key=ch[@"id"];
            if(key.length)[m removeObjectForKey:key];
            [NSUserDefaults.standardUserDefaults setObject:m forKey:@"epgMappings"];
            if(key.length)[self.epgCache removeObjectForKey:key];
            [self saveEPGCache];[self applyFilter];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *m=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{} mutableCopy];NSString *key=ch[@"id"];NSString *value=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length)m[key]=value;else[m removeObjectForKey:key];[NSUserDefaults.standardUserDefaults setObject:m forKey:@"epgMappings"];[self.epgCache removeObjectForKey:key];[self saveEPGCache];[self applyFilter];}]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)showRemoteTools:(NSDictionary *)ch {
    BOOL supportsCatchup = [self channelSupportsCatchup:ch];
    NSArray<NSString *> *alts = self.altSources[CCTVRouteGroupKey(ch)] ?: @[];
    NSUInteger altCount = 0;
    for (NSString *url in alts) if (![url isEqual:ch[@"remoteURL"]]) altCount++;
    NSString *sourceHost = [NSURL URLWithString:ch[@"remoteURL"] ?: @""].host ?: @"订阅源";
    NSString *baseSubtitle = supportsCatchup ? @"订阅频道 · 支持节目回看" : @"订阅频道 · AVPlayer";
    NSString *subtitle = [NSString stringWithFormat:@"%@ · %@%@",
                          baseSubtitle,
                          sourceHost,
                          altCount ? [NSString stringWithFormat:@" · %lu 条备用源", (unsigned long)altCount] : @""];
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetSection *> *sections=[NSMutableArray array];
    NSMutableArray<HostGlassSheetAction *> *playRows=[NSMutableArray array];
    if ([ch[@"id"] isEqualToString:self.channelID] && self.remoteCatchupActive) {
        [playRows addObject:[HostGlassSheetAction actionWithTitle:@"返回实时直播" subtitle:@"结束回看并回到最新直播流" value:nil icon:@"dot.radiowaves.left.and.right" tint:UIColor.systemGreenColor destructive:NO selected:NO handler:^{[weakSelf returnToLivePlayback];}]];
    }
    [playRows addObject:[HostGlassSheetAction actionWithTitle:@"重新播放" subtitle:@"重新连接当前频道信号" value:nil icon:@"play.circle.fill" tint:HostAccent() destructive:NO selected:NO handler:^{[weakSelf routePlayback:ch];}]];
    [playRows addObject:[HostGlassSheetAction actionWithTitle:@"静音预览（30 秒）" subtitle:@"小窗静音试看画面，不影响正式播放" value:@"30s" icon:@"speaker.slash.fill" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{[weakSelf previewChannel:ch];}]];
    [sections addObject:[HostGlassSheetSection sectionWithTitle:@"播放与预览" actions:playRows]];
    NSMutableArray<HostGlassSheetAction *> *altRows=[NSMutableArray array];
    NSUInteger altIdx = 0;
    for(NSString *url in alts){
        if([url isEqual:ch[@"remoteURL"]])continue;
        altIdx++;
        NSString *host = [NSURL URLWithString:url].host ?: @"备用源";
        NSString *proto = [url.lowercaseString containsString:@".m3u8"] ? @"HLS" : @"直链";
        NSString *altTitle = [NSString stringWithFormat:@"备用源 %lu · %@ (%@)", (unsigned long)altIdx, host, proto];
        [altRows addObject:[HostGlassSheetAction actionWithTitle:altTitle subtitle:nil value:proto icon:@"antenna.radiowaves.left.and.right" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{NSDictionary *other=[weakSelf alternateChannelForURL:url matching:ch];if(other)[weakSelf routePlayback:other];}]];
    }
    if(altRows.count)[sections addObject:[HostGlassSheetSection sectionWithTitle:@"备用信号源" actions:altRows]];
    NSMutableArray<HostGlassSheetAction *> *epgRows=[NSMutableArray array];
    [epgRows addObject:[HostGlassSheetAction actionWithTitle:supportsCatchup?@"节目单与回看":@"节目单" subtitle:@"浏览频道预告并支持点播回看" value:nil icon:@"calendar.badge.clock" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{[weakSelf openEPGforChannel:ch[@"id"] name:ch[@"name"]];}]];
    if ([ch[@"id"] isEqualToString:self.channelID] && (supportsCatchup || [self nativeFallbackChannelForChannel:ch])) {
        [epgRows addObject:[HostGlassSheetAction actionWithTitle:@"时移 / 快速回退" subtitle:@"快速回退 5/15/30/60 分钟" value:nil icon:@"clock.arrow.circlepath" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{[weakSelf showNativeTimeshiftActions];}]];
    }
    [epgRows addObject:[HostGlassSheetAction actionWithTitle:@"EPG 手动匹配" subtitle:@"自定义该频道关联的节目单 ID" value:nil icon:@"link" tint:HostSecondaryText() destructive:NO selected:NO handler:^{[weakSelf editEPGMapping:ch];}]];
    [sections addObject:[HostGlassSheetSection sectionWithTitle:@"节目单与时移" actions:epgRows]];
    [HostGlassActionSheetViewController presentOn:self
                                            title:(ch[@"name"] ?: @"频道操作")
                                         subtitle:subtitle
                                        badgeText:(supportsCatchup ? @"支持回看" : @"订阅频道")
                                       badgeColor:(supportsCatchup ? UIColor.systemOrangeColor : HostAccent())
                                         sections:sections
                                       sourceView:self.bottomBar];
}
- (void)previewChannel:(NSDictionary *)ch {
    if(self.currentPlayer||self.avPlayer||self.playbackReadiness){[self showServiceError:@"为保证正式播放，预览仅在没有频道播放时启动。"];return;}
    NSString *url=[self stableURLKey:ch[@"remoteURL"]];if(!url.length)return;
    NSDictionary *localService=[self localServiceForChannel:ch URL:[NSURL URLWithString:url]];if(localService&&![PyHost isRunningServiceIdentifier:localService[@"id"]]){[self showServiceError:@"请先启动该频道的本机服务。"];return;}
    [self stopPreview];NSURL *previewURL=[NSURL URLWithString:url];NSDictionary *rawHeaders=[ch[@"headers"] isKindOfClass:NSDictionary.class]?ch[@"headers"]:nil;NSDictionary *scopedHeaders=rawHeaders.count?MediaPlaybackHeadersScopedToURL(rawHeaders,previewURL,previewURL):nil;AVURLAsset *previewAsset=[AVURLAsset URLAssetWithURL:previewURL options:scopedHeaders.count?@{@"AVURLAssetHTTPHeaderFieldsKey":scopedHeaders}:nil];self.previewPlayer=[AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:previewAsset]];self.previewPlayer.muted=YES;self.previewLayer=[AVPlayerLayer playerLayerWithPlayer:self.previewPlayer];
    CGFloat previewWidth=MIN(280,self.view.bounds.size.width-32);
    UIView *box=[[UIView alloc] initWithFrame:CGRectMake(16,self.view.safeAreaInsets.top+12,previewWidth,158)];box.backgroundColor=UIColor.blackColor;box.layer.cornerRadius=16;box.layer.cornerCurve=kCACornerCurveContinuous;box.layer.borderWidth=0.9;HostSetLayerBorderColor(box,HostBorder());box.clipsToBounds=YES;box.accessibilityIdentifier=@"channel.preview.box";self.previewBox=box;[self.view addSubview:box];self.previewLayer.frame=box.bounds;self.previewLayer.videoGravity=AVLayerVideoGravityResizeAspect;[box.layer addSublayer:self.previewLayer];
    CAGradientLayer *topScrim=[CAGradientLayer layer];topScrim.frame=CGRectMake(0,0,previewWidth,48);topScrim.colors=@[(id)[UIColor colorWithWhite:0 alpha:0.72].CGColor,(id)UIColor.clearColor.CGColor];[box.layer addSublayer:topScrim];
    UILabel *badge=[[UILabel alloc] initWithFrame:CGRectMake(10,10,MAX(40,previewWidth-114),24)];badge.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];badge.textColor=[UIColor colorWithWhite:1.0 alpha:0.95];badge.backgroundColor=[UIColor colorWithWhite:0 alpha:0.48];badge.layer.cornerRadius=8;badge.layer.cornerCurve=kCACornerCurveContinuous;badge.clipsToBounds=YES;badge.textAlignment=NSTextAlignmentCenter;badge.accessibilityIdentifier=@"channel.preview.badge";NSString *chTitle=[ch[@"name"] isKindOfClass:NSString.class]&&[ch[@"name"] length]?ch[@"name"]:@"频道";badge.text=[NSString stringWithFormat:@"  🔇 预览 · %@  ",chTitle];[box addSubview:badge];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];[close setTitle:@"关闭预览" forState:UIControlStateNormal];close.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];close.tintColor=[UIColor colorWithWhite:1.0 alpha:0.95];close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];close.frame=CGRectMake(MAX(0,previewWidth-100),0,MIN(100,previewWidth),44);close.accessibilityIdentifier=@"channel.preview.close";[close addTarget:self action:@selector(stopPreview) forControlEvents:UIControlEventTouchUpInside];[box addSubview:close];[self.previewPlayer play];__weak typeof(self) w=self;self.previewTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){[w stopPreview];}];
}
- (void)stopPreview {[self.previewTimer invalidate];self.previewTimer=nil;[self.previewPlayer pause];[self.previewPlayer.currentItem.asset cancelLoading];[self.previewPlayer replaceCurrentItemWithPlayerItem:nil];self.previewPlayer=nil;self.previewLayer.player=nil;[self.previewLayer removeFromSuperlayer];self.previewLayer=nil;[self.previewBox removeFromSuperview];self.previewBox=nil;}
- (void)showHistory {
    NSString *msg = self.recents.count
        ? [NSString stringWithFormat:@"共 %lu 条观看记录 · 点选频道立即续播", (unsigned long)self.recents.count]
        : @"还没有观看记录";
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetSection *> *sections=[NSMutableArray array];
    NSMutableArray<HostGlassSheetAction *> *rows=[NSMutableArray array];
    for(NSDictionary *r in self.recents){
        NSString *cid=[r[@"id"] isKindOfClass:NSString.class]?r[@"id"]:@"";
        NSDictionary *ch=cid.length?[self channelWithID:cid]:nil;
        NSString *base=[r[@"name"] isKindOfClass:NSString.class]?r[@"name"]:(cid.length?cid:@"未知频道");
        if(!base.length)base=@"未知频道";
        NSString *tag=ch?([ch[@"remoteURL"] length]?@"订阅":@"官方"):@"已下线";
        NSString *prog=(cid.length&&[self.epgCache[cid][@"now"] isKindOfClass:NSString.class])?self.epgCache[cid][@"now"]:nil;
        [rows addObject:[HostGlassSheetAction actionWithTitle:base subtitle:(prog.length?[NSString stringWithFormat:@"正在播：%@",prog]:nil) value:tag icon:@"clock.arrow.circlepath" tint:(ch?HostAccent():HostMutedText()) destructive:NO selected:[cid isEqualToString:self.channelID] handler:^{
            RootViewController *owner=weakSelf;if(!owner)return;
            NSDictionary *target=[owner channelWithID:r[@"id"]];
            if(target)[owner selectChannel:target];
            else [owner showServiceError:@"该频道已不在配置中，请刷新或重新导入原配置。"];
        }]];
    }
    if(rows.count)[sections addObject:[HostGlassSheetSection sectionWithTitle:@"最近续播" actions:rows]];
    if(self.recents.count){
        [sections addObject:[HostGlassSheetSection sectionWithTitle:@"管理" actions:@[
            [HostGlassSheetAction actionWithTitle:@"清空历史" subtitle:@"移除全部最近观看记录" value:nil icon:@"trash" tint:UIColor.systemRedColor destructive:YES selected:NO handler:^{[weakSelf confirmClearRecentChannels];}]
        ]]];
    }
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"最近观看"
                                         subtitle:msg
                                        badgeText:[NSString stringWithFormat:@"%lu 条记录",(unsigned long)self.recents.count]
                                       badgeColor:HostAccent()
                                         sections:sections
                                       sourceView:self.bottomBar];
}
- (void)showFavoriteManager {
    NSString *msg = self.favorites.count
        ? [NSString stringWithFormat:@"共 %lu 个收藏频道 · 点选移到首位，列表左滑可取消收藏。", (unsigned long)self.favorites.count]
        : @"还没有收藏频道，长按频道即可收藏。";
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetSection *> *sections=[NSMutableArray array];
    NSMutableArray<HostGlassSheetAction *> *rows=[NSMutableArray array];
    for(NSUInteger idx=0;idx<self.favorites.count;idx++){
        NSString *cid=self.favorites[idx];
        NSDictionary *ch=[self channelWithID:cid];
        NSString *base=([ch[@"name"] isKindOfClass:NSString.class]&&[ch[@"name"] length])?ch[@"name"]:cid;
        NSString *tag=ch?([ch[@"remoteURL"] length]?@"订阅":@"官方"):@"未加载";
        [rows addObject:[HostGlassSheetAction actionWithTitle:base subtitle:(idx==0?@"已在首位":@"点选置顶到首位") value:tag icon:(idx==0?@"star.fill":@"arrow.up.to.line") tint:(idx==0?UIColor.systemYellowColor:HostAccent()) destructive:NO selected:(idx==0) handler:^{
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.favorites removeObject:cid];[owner.favorites insertObject:cid atIndex:0];
            [NSUserDefaults.standardUserDefaults setObject:owner.favorites forKey:@"favorites"];[owner applyFilter];
        }]];
    }
    if(rows.count)[sections addObject:[HostGlassSheetSection sectionWithTitle:@"收藏排序（点选置顶）" actions:rows]];
    if(self.favorites.count){
        [sections addObject:[HostGlassSheetSection sectionWithTitle:@"管理" actions:@[
            [HostGlassSheetAction actionWithTitle:@"清空收藏" subtitle:@"移除全部已收藏频道" value:nil icon:@"trash" tint:UIColor.systemRedColor destructive:YES selected:NO handler:^{
                RootViewController *owner=weakSelf;if(!owner)return;
                UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"清空收藏？" message:@"将移除全部收藏频道，此操作无法撤销。" preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"清空收藏" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *x){
                    [self.favorites removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"favorites"];[self configureCatalogNavigation];[self applyFilter];
                }]];
                [owner presentViewController:confirm animated:YES completion:nil];
            }]
        ]]];
    }
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"整理收藏"
                                         subtitle:msg
                                        badgeText:[NSString stringWithFormat:@"%lu 个收藏",(unsigned long)self.favorites.count]
                                       badgeColor:UIColor.systemYellowColor
                                         sections:sections
                                       sourceView:self.bottomBar];
}
@end
