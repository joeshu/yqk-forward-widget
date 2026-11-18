#import "RootViewController_Internal.h"

@implementation RootViewController (Catalog)

- (void)loadChannels {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"channels" ofType:@"json"];
    NSArray *arr = nil;
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    }
    self.allChannels = [arr isKindOfClass:NSArray.class] ? arr : @[];
    self.shownChannels = self.allChannels;
    self.favorites = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"favorites"] ?: @[]];
    self.altSources = [NSMutableDictionary dictionary];
    self.epgCache = [NSMutableDictionary dictionary];
    [self loadEPGCache];
    self.epgInflight = [NSMutableSet set];
    self.recents = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"recents"] ?: @[]];
    self.subscriptions = [NSMutableArray array];
    self.subscriptionURLs = [NSMutableSet set];
    self.subscriptionRequestVersions = [NSMutableDictionary dictionary];
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"subscriptions"];
    for (NSString *u in saved) {
        NSString *key=[ProfileStore isHTTP:u]?[self stableURLKey:u]:([ProfileStore isSource:u]?u:nil);
        if(!key.length)continue;[self.subscriptionURLs addObject:key];
        NSArray *cache=[ProfileStore metadata:key][@"cachedChannels"];
        if([cache isKindOfClass:NSArray.class])self.allChannels=[self.allChannels arrayByAddingObjectsFromArray:cache];
        [self.deferredLocalSubscriptions addObject:key];
    }
    NSMutableDictionary *unique=[NSMutableDictionary dictionary];NSMutableArray *dedup=[NSMutableArray array];for(id rawChannel in self.allChannels){if(![rawChannel isKindOfClass:NSDictionary.class])continue;NSDictionary *c=rawChannel;NSString *cid=[c[@"id"] isKindOfClass:NSString.class]?c[@"id"]:nil;if(!cid.length){[dedup addObject:c];continue;}NSNumber *index=unique[cid];if(index){NSMutableDictionary *existing=[dedup[index.unsignedIntegerValue] mutableCopy];NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(existing[@"subscriptionSources"])];[owners addObjectsFromArray:CCTVStringArrayValue(c[@"subscriptionSources"])];if(owners.count)existing[@"subscriptionSources"]=owners.allObjects;dedup[index.unsignedIntegerValue]=existing;}else{unique[cid]=@(dedup.count);[dedup addObject:c];}}self.allChannels=dedup;
    [self.altSources removeAllObjects];
    for(NSDictionary *c in self.allChannels){
        NSString *url=[c[@"remoteURL"] isKindOfClass:NSString.class]?c[@"remoteURL"]:@"";
        NSString *groupKey=CCTVRouteGroupKey(c);
        if(!url.length||!groupKey.length)continue;
        if(!self.altSources[groupKey])self.altSources[groupKey]=[NSMutableArray array];
        if(![self.altSources[groupKey] containsObject:url])[self.altSources[groupKey] addObject:url];
    }
    self.shownChannels=self.allChannels;
    [self applyFilter];
    [self log:@"频道 %lu 个 / 线路 %lu 条",
         (unsigned long)self.allChannels.count,
         (unsigned long)[[self.allChannels valueForKeyPath:@"@sum.routes.@count"] integerValue]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)t contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSArray *rows=[self channelsForSection:ip.section tableView:t];
    if(ip.row<0||ip.row>=(NSInteger)rows.count)return nil;
    NSDictionary *ch=rows[(NSUInteger)ip.row];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ch[@"id"] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        BOOL favorite=[w.favorites containsObject:ch[@"id"]];
        UIAction *fav=[UIAction actionWithTitle:favorite?@"取消收藏":@"收藏频道" image:[UIImage systemImageNamed:favorite?@"heart.slash":@"heart"] identifier:nil handler:^(UIAction *a){if(favorite)[w.favorites removeObject:ch[@"id"]];else[w.favorites addObject:ch[@"id"]];[NSUserDefaults.standardUserDefaults setObject:w.favorites forKey:@"favorites"];[w configureCatalogNavigation];[w applyFilter];}];
        UIAction *route=[UIAction actionWithTitle:@"线路与节目单" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(UIAction *a){if([ch[@"remoteURL"] length])[w openEPGforChannel:ch[@"id"] name:ch[@"name"]];else[w presentRouteSheetForChannel:ch fromIndexPath:ip];}];
        NSMutableArray *actions=[NSMutableArray arrayWithObjects:fav,route,nil];
        if([ch[@"remoteURL"] length]){
            [actions addObject:[UIAction actionWithTitle:@"静音预览（30 秒）" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){[w previewChannel:ch];}]];
            [actions addObject:[UIAction actionWithTitle:@"EPG 手动匹配" image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(UIAction *a){[w editEPGMapping:ch];}]];
        }
        [actions addObject:[UIAction actionWithTitle:@"电视台增强与同台多源" image:[UIImage systemImageNamed:@"sparkles.tv"] identifier:nil handler:^(UIAction *a){[w presentStationEnhancementSheetForChannel:ch sourceView:t];}]];
        return [UIMenu menuWithTitle:ch[@"name"]?:@"频道操作" children:actions];
    }];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *rows = [self channelsForSection:ip.section tableView:t];
    if (ip.row >= rows.count) return nil;
    NSDictionary *ch = rows[ip.row];
    NSString *cid = ch[@"id"] ?: @"";
    BOOL fav = [self.favorites containsObject:cid];
    NSString *label = fav ? @"取消收藏" : @"收藏";
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:label
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        RootViewController *owner = weakSelf;
        if (!owner) { done(NO); return; }
        if (fav) [owner.favorites removeObject:cid];
        else [owner.favorites addObject:cid];
        [[NSUserDefaults standardUserDefaults] setObject:owner.favorites forKey:@"favorites"];
        [owner applyFilter];
        done(YES);
    }];
    action.backgroundColor = fav ? HostRaisedSurface() : [UIColor systemOrangeColor];
    UIContextualAction *epgAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"节目单"
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        RootViewController *owner = weakSelf;
        if (owner) [owner openEPGforChannel:cid name:ch[@"name"] ?: cid];
        done(YES);
    }];
    epgAction.backgroundColor = HostAccent();
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray arrayWithObjects:action, epgAction, nil];
    if (self.recentsOnly) {
        UIContextualAction *removeRecent = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除记录"
                                                                                 handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            RootViewController *owner = weakSelf;
            if (!owner) { done(NO); return; }
            NSIndexSet *toRemove = [owner.recents indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger idx, BOOL *stop) {
                return [r[@"id"] isEqualToString:cid];
            }];
            if (toRemove.count) [owner.recents removeObjectsAtIndexes:toRemove];
            [[NSUserDefaults standardUserDefaults] setObject:owner.recents forKey:@"recents"];
            [owner applyFilter];
            done(YES);
        }];
        [actions addObject:removeRecent];
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (NSArray<NSString *> *)currentCatalogGroupTitles {
    return self.subscriptionCatalog
        ? @[@"全部", @"央视", @"卫视", @"地方", @"其他", @"收藏", @"最近"]
        : @[@"全部", @"央视", @"卫视", @"地方", @"教育", @"收藏", @"最近"];
}

- (void)syncGroupControlSegments {
    if (!self.groupControl) return;
    NSArray<NSString *> *titles = [self currentCatalogGroupTitles];
    NSInteger previous = self.groupControl.selectedSegmentIndex;
    if (self.groupControl.numberOfSegments != (NSInteger)titles.count) {
        [self.groupControl removeAllSegments];
        for (NSUInteger i = 0; i < titles.count; i++) {
            [self.groupControl insertSegmentWithTitle:titles[i] atIndex:i animated:NO];
        }
    } else {
        for (NSUInteger i = 0; i < titles.count; i++) {
            if (![[self.groupControl titleForSegmentAtIndex:i] isEqualToString:titles[i]]) {
                [self.groupControl setTitle:titles[i] forSegmentAtIndex:i];
            }
        }
    }
    self.groupControl.selectedSegmentIndex = (previous >= 0 && previous < (NSInteger)titles.count) ? previous : 0;
}

- (void)onGroupChanged {
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSArray<NSString *> *titles = [self currentCatalogGroupTitles];
    NSString *selectedTitle = (idx >= 0 && idx < (NSInteger)titles.count) ? titles[idx] : @"全部";
    self.favoritesOnly = [selectedTitle isEqualToString:@"收藏"];
    self.recentsOnly = [selectedTitle isEqualToString:@"最近"];
    [self updateBottomBarSelection];
    [self configureCatalogNavigation];[self applyFilter];
}

- (void)configureCatalogNavigation {
    [self syncGroupControlSegments];
    BOOL expandedLive=[self isExpandedLivePlayerVisible];
    self.title=expandedLive?(self.channelName?:@"直播"):(self.recentsOnly?@"最近观看":(self.favoritesOnly?@"收藏频道":(self.subscriptionCatalog?@"频道":@"CCTV")));
    self.navigationItem.largeTitleDisplayMode=expandedLive?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.searchController=self.searchController; self.navigationItem.hidesSearchBarWhenScrolling=NO;
    // Keep the live pages' transport and catalog controls independent of the
    // navigation bar so they remain visible when the top chrome collapses.
    self.navigationItem.leftBarButtonItem=nil;self.navigationItem.rightBarButtonItems=nil;
    BOOL hideNavigation=self.fullscreen||expandedLive;
    if(self.navigationController.topViewController==self){
        self.navigationController.navigationBar.prefersLargeTitles=!hideNavigation;
        if(self.navigationController.navigationBarHidden!=hideNavigation)
            [self.navigationController setNavigationBarHidden:hideNavigation animated:NO];
    }
    [self setNeedsStatusBarAppearanceUpdate];
    [self updateLiveResourceCapsule];
    if(self.catalogLayoutButton){self.catalogLayoutButton.accessibilityLabel=self.gridMode?@"切换列表布局":@"切换网格布局";UIButtonConfiguration *configuration=self.catalogLayoutButton.configuration;configuration.image=[UIImage systemImageNamed:self.gridMode?@"list.bullet":@"square.grid.2x2"];self.catalogLayoutButton.configuration=configuration;}
    self.catalogMoreButton.menu=[self catalogMenu];
    // Page actions live in the floating catalog controls (layout, AirPlay,
    // more menu) and never in the navigation bar — the bar items were
    // cleared above and stay cleared (ui-preview: 'CCTV catalog keeps page
    // actions out of the top navigation bar').
}
- (void)toggleCatalogLayout {
    CGPoint listOffset=self.table.contentOffset,gridOffset=self.channelGrid.contentOffset;
    self.gridMode=!self.gridMode;
    [NSUserDefaults.standardUserDefaults setBool:self.gridMode forKey:@"channelGridMode"];
    [self configureCatalogNavigation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.table.contentOffset=listOffset;
    self.channelGrid.contentOffset=gridOffset;
}
- (void)toggleCatalogColumns {
    CGPoint gridOffset=self.channelGrid.contentOffset;
    self.gridColumns=self.gridColumns==4?3:4;
    [NSUserDefaults.standardUserDefaults setInteger:self.gridColumns forKey:@"cctv.channelGridColumns.v1"];
    [self.channelGrid.collectionViewLayout invalidateLayout];
    [self.channelGrid reloadData];
    [self configureCatalogNavigation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.channelGrid.contentOffset=gridOffset;
}
- (void)toggleCurrentFavorite {
    if(!self.channelID.length)return;
    if([self.favorites containsObject:self.channelID])[self.favorites removeObject:self.channelID];
    else [self.favorites addObject:self.channelID];
    [NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];
    [self configureCatalogNavigation];[self applyFilter];
}
- (void)playAdjacentChannel:(NSInteger)direction {
    // 上 / 下一个频道：在当前可见列表内循环换台（到头绕回另一端），
    // 未选台时从第一条开始；列表为空时不操作。
    if(!self.shownChannels.count)return;
    NSInteger current=[self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *c,NSUInteger idx,BOOL *stop){return [c[@"id"] isEqualToString:self.channelID];}];
    NSInteger next=current==NSNotFound?0:(current+direction+(NSInteger)self.shownChannels.count)%(NSInteger)self.shownChannels.count;
    if(next<0||next>=(NSInteger)self.shownChannels.count)return;
    [self selectChannel:self.shownChannels[next]];
}
- (void)scrollCatalogToPlayingChannel {
    // 回到正在播放：把列表滚到当前频道所在行；未选台或频道不在当前列表时不操作。
    if(!self.channelID.length)return;
    NSIndexPath *ip=[self indexPathForChannelID:self.channelID];
    if(!ip)return;
    if(!self.gridMode&&self.table&&!self.table.hidden)[self.table scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    else if(self.gridMode&&self.channelGrid&&!self.channelGrid.hidden){NSInteger gridIndex=[self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *c,NSUInteger idx,BOOL *stop){return [c[@"id"] isEqualToString:self.channelID];}];if(gridIndex!=NSNotFound)[self.channelGrid scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:gridIndex inSection:0] atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:YES];}
}
- (UIMenu *)catalogMenu {
    __weak typeof(self) w=self;
    NSInteger groupIndex=self.groupControl.selectedSegmentIndex;NSString *groupName=groupIndex>=0&&groupIndex<self.groupControl.numberOfSegments?[self.groupControl titleForSegmentAtIndex:groupIndex]:@"全部";
    UIAction *search=[UIAction actionWithTitle:@"搜索频道" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:@"channel.catalog.search" handler:^(UIAction *a){[w showCatalogSearch];}];
    UIAction *group=[UIAction actionWithTitle:[NSString stringWithFormat:@"频道分组 · %@",groupName] image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(UIAction *a){[w showGroupMenu];}];
    NSInteger nextColumns=self.gridColumns==4?3:4;
    UIAction *columns=[UIAction actionWithTitle:[NSString stringWithFormat:@"每行 %ld 列 · 切换为 %ld 列",(long)self.gridColumns,(long)nextColumns] image:[UIImage systemImageNamed:@"square.grid.3x3"] identifier:@"channel.grid.columns.toggle" handler:^(UIAction *a){[w toggleCatalogColumns];}];
    UIAction *refresh=[UIAction actionWithTitle:self.subscriptionCatalog?@"刷新播放列表":@"刷新当前列表" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[w onPullRefresh];}];
    UIAction *add=[UIAction actionWithTitle:@"添加订阅" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[w addSubscription];}];
    UIAction *hide=[UIAction actionWithTitle:self.playerExpanded?@"收起播放器":@"展开播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){w.playerExpanded=!w.playerExpanded;[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *history=[UIAction actionWithTitle:@"最近观看" image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *a){[w showHistory];}];
    UIAction *playing=[UIAction actionWithTitle:@"返回正在播放" image:[UIImage systemImageNamed:@"play.circle"] identifier:nil handler:^(UIAction *a){if(!w.channelID.length)return;[w selectBottomTab:(id)w.bottomBar.arrangedSubviews[w.currentRemoteURL.length?1:0]];w.playerExpanded=YES;[w configureCatalogNavigation];[w.view setNeedsLayout];dispatch_async(dispatch_get_main_queue(),^{[w scrollCatalogToPlayingChannel];});}];
    UIAction *manage=[UIAction actionWithTitle:@"整理收藏" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){[w showFavoriteManager];}];
    UIAction *favorites=[UIAction actionWithTitle:self.favoritesOnly?@"显示全部频道":@"查看收藏频道" image:[UIImage systemImageNamed:@"heart.fill"] identifier:nil handler:^(UIAction *a){w.recentsOnly=NO;w.favoritesOnly=!w.favoritesOnly;w.groupControl.selectedSegmentIndex=w.favoritesOnly?5:0;[w configureCatalogNavigation];[w applyFilter];}];
    UIAction *castCenter=[UIAction actionWithTitle:@"投屏中心 · AirPlay / 电视投屏" image:[UIImage systemImageNamed:@"airplayvideo"] identifier:@"channel.catalog.cast.center" handler:^(UIAction *a){[w showCastingCenter];}];
    UIAction *sort=[UIAction actionWithTitle:self.channelSortMode==1?@"按默认顺序排列":@"按名称排序" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil handler:^(UIAction *a){w.channelSortMode=w.channelSortMode==1?0:1;[NSUserDefaults.standardUserDefaults setInteger:w.channelSortMode forKey:@"cctv.channelSortMode.v1"];[w applyFilter];}];
    NSMutableArray *actions=[NSMutableArray arrayWithObjects:search,group,columns,castCenter,refresh,hide,playing,history,favorites,manage,sort,nil];
    if(self.recentsOnly&&self.recents.count){UIAction *clearRecents=[UIAction actionWithTitle:@"清空最近观看记录" image:[UIImage systemImageNamed:@"trash"] identifier:@"channel.catalog.recents.clear" handler:^(UIAction *a){[w.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[w applyFilter];}];clearRecents.attributes=UIMenuElementAttributesDestructive;[actions insertObject:clearRecents atIndex:0];}
    if(self.subscriptionCatalog)[actions insertObject:add atIndex:2];
    if(self.channelID.length){BOOL favorite=[self.favorites containsObject:self.channelID];UIAction *currentFavorite=[UIAction actionWithTitle:favorite?@"取消收藏当前频道":@"收藏当前频道" image:[UIImage systemImageNamed:favorite?@"heart.fill":@"heart"] identifier:nil handler:^(UIAction *a){[w toggleCurrentFavorite];}];UIAction *playbackInfo=[UIAction actionWithTitle:@"播放信息" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a){[w showPlaybackInfo];}];[actions insertObjects:@[currentFavorite,playbackInfo] atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,2)]];}
    return [UIMenu menuWithTitle:@"" children:actions];
}
- (void)showCatalogSearch {
    NSString *message=self.subscriptionCatalog?@"按频道名称或编号筛选订阅频道。":@"按频道名称或编号筛选 CCTV。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"搜索频道" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=self.query?:@"";field.placeholder=@"频道名称或编号";field.clearButtonMode=UITextFieldViewModeWhileEditing;field.returnKeyType=UIReturnKeySearch;}];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(!owner)return;owner.query=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";owner.searchController.searchBar.text=owner.query;[owner applyFilter];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showGroupMenu {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"频道分组" message:@"按频道类型筛选当前列表" preferredStyle:UIAlertControllerStyleActionSheet];NSInteger selected=self.groupControl.selectedSegmentIndex;
    for(NSUInteger i=0;i<self.groupControl.numberOfSegments;i++){NSString *group=[self.groupControl titleForSegmentAtIndex:i]?:@"全部";NSString *title=(NSInteger)i==selected?[NSString stringWithFormat:@"✓  %@",group]:group;[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.groupControl.selectedSegmentIndex=i;[self onGroupChanged];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];UIPopoverPresentationController *popover=a.popoverPresentationController;if(popover){if(self.catalogMoreButton){popover.sourceView=self.catalogMoreButton;popover.sourceRect=self.catalogMoreButton.bounds;}else{popover.sourceView=self.view;popover.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);}}[self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.shownChannels.count;}
- (CGFloat)catalogTextHeight:(NSString *)text font:(UIFont *)font width:(CGFloat)width maximumLines:(NSUInteger)maximumLines {
    if(!text.length||width<=0)return ceil(font.lineHeight);
    CGFloat maximumHeight=ceil(font.lineHeight*MAX(1,maximumLines));
    CGRect measured=[text boundingRectWithSize:CGSizeMake(width,maximumHeight) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:font} context:nil];
    return MIN(maximumHeight,MAX(ceil(font.lineHeight),ceil(measured.size.height)));
}
- (NSUInteger)sourceCountForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return 0;
    if ([channel[@"remoteURL"] length]) {
        NSMutableSet<NSString *> *urls = [NSMutableSet set];
        NSString *primary = [self stableURLKey:channel[@"remoteURL"]];
        if (primary.length) [urls addObject:primary];
        NSString *groupKey = CCTVRouteGroupKey(channel);
        for (NSString *alt in self.altSources[groupKey]) {
            NSString *k = [self stableURLKey:alt];
            if (k.length) [urls addObject:k];
        }
        NSArray *owners = CCTVStringArrayValue(channel[@"subscriptionSources"]);
        return MAX(urls.count, owners.count);
    }
    return [channel[@"routes"] isKindOfClass:NSArray.class] ? [channel[@"routes"] count] : 0;
}
- (NSDictionary *)catchupChannelForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return nil;
    if ([channel[@"catchupSource"] isKindOfClass:NSString.class] && [channel[@"catchupSource"] length] > 0) return channel;
    if (![channel[@"remoteURL"] length]) return nil;
    return [self anyCatchupChannelForStation:channel];
}
- (NSDictionary *)anyCatchupChannelForStation:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return nil;
    if ([channel[@"catchupSource"] isKindOfClass:NSString.class] && [channel[@"catchupSource"] length] > 0 && [channel[@"remoteURL"] length]) return channel;
    NSString *groupKey = CCTVRouteGroupKey(channel);
    NSString *canonical = [ProfileStore canonicalStationIDForChannel:channel];
    for (NSDictionary *cand in self.allChannels) {
        if (![cand isKindOfClass:NSDictionary.class] || ![cand[@"remoteURL"] length]) continue;
        if (![cand[@"catchupSource"] isKindOfClass:NSString.class] || ![cand[@"catchupSource"] length]) continue;
        if ((groupKey.length && [CCTVRouteGroupKey(cand) isEqualToString:groupKey]) ||
            (canonical.length && [[ProfileStore canonicalStationIDForChannel:cand] isEqualToString:canonical])) {
            return cand;
        }
    }
    return nil;
}
- (NSDictionary *)nativeFallbackChannelForChannel:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class] || !CCTVBoolPreference(@"nativeChannelsEnabled", YES)) return nil;
    if (![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:channel[@"id"]]) return channel;
    NSString *officialID = [self epgIDForChannel:channel];
    if (officialID.length) {
        NSDictionary *matched = [self channelWithID:officialID];
        if (matched && ![matched[@"remoteURL"] length] && ![ProfileStore isHTTP:matched[@"id"]]) return matched;
    }
    NSString *canonical = [ProfileStore canonicalStationIDForChannel:channel];
    if (canonical.length) {
        NSDictionary *matched = [self channelWithID:canonical];
        if (matched && ![matched[@"remoteURL"] length] && ![ProfileStore isHTTP:matched[@"id"]]) return matched;
    }
    return nil;
}
- (BOOL)channelSupportsCatchup:(NSDictionary *)channel {
    if (![channel isKindOfClass:NSDictionary.class]) return NO;
    if ([self catchupChannelForChannel:channel] != nil) return YES;
    return ![channel[@"remoteURL"] length];
}
- (NSString *)catalogSubtitleForChannel:(NSDictionary *)channel {
    NSString *cached=self.epgCache[channel[@"id"]][@"now"];
    NSString *base=[cached isKindOfClass:NSString.class]&&cached.length?cached:([channel[@"group"] isKindOfClass:NSString.class]?channel[@"group"]:@"");
    NSMutableArray<NSString *> *tags=[NSMutableArray array];
    if(base.length)[tags addObject:base];
    NSUInteger sourceCount=[self sourceCountForChannel:channel];
    if(sourceCount>1)[tags addObject:[NSString stringWithFormat:@"%lu源",(unsigned long)sourceCount]];
    if([channel[@"remoteURL"] length] && [self channelSupportsCatchup:channel])[tags addObject:@"回看"];
    else if(![channel[@"remoteURL"] length] && [self channelSupportsCatchup:channel])[tags addObject:@"时移回看"];
    return [tags componentsJoinedByString:@" · "];
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewFlowLayout *flow=[layout isKindOfClass:UICollectionViewFlowLayout.class]?(id)layout:nil;
    NSInteger columns=self.gridColumns==3?3:4;
    UIEdgeInsets inset=flow?flow.sectionInset:UIEdgeInsetsZero;
    CGFloat spacing=flow?flow.minimumInteritemSpacing:6;
    CGFloat itemWidth=floor(MAX(1,(collectionView.bounds.size.width-inset.left-inset.right-(columns-1)*spacing)/columns));
    UIFont *titleFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];
    UIFont *subtitleFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];
    NSDictionary *channel=ip.item>=0&&ip.item<self.shownChannels.count?self.shownChannels[ip.item]:@{};
    NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:([channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"");
    if([self.favorites containsObject:channel[@"id"]])name=[@"♥ " stringByAppendingString:name];
    CGFloat labelWidth=MAX(1,itemWidth-4);
    CGFloat titleHeight=[self catalogTextHeight:name font:titleFont width:labelWidth maximumLines:2];
    CGFloat subtitleHeight=[self catalogTextHeight:[self catalogSubtitleForChannel:channel] font:subtitleFont width:labelWidth maximumLines:2];
    CGFloat posterHeight=MIN(78,MAX(44,floor(itemWidth*.68)));
    CGFloat height=posterHeight+5+titleHeight+1+subtitleHeight+4;
    return CGSizeMake(itemWidth,height);
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"channel.card" forIndexPath:ip];
    if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return cell;
    NSDictionary *ch=self.shownChannels[ip.item];
    HostStyleGlassCard(cell.contentView,11);
    const NSInteger posterTag=4101,logoTag=4102,brandTag=4103,numberTag=4104,titleTag=4105,subtitleTag=4106,selectedTag=4107,previewTag=4108,telemetryTag=4109;
    UIView *poster=[cell.contentView viewWithTag:posterTag];UIImageView *logo=(UIImageView *)[cell.contentView viewWithTag:logoTag];UILabel *brand=(UILabel *)[cell.contentView viewWithTag:brandTag];UILabel *number=(UILabel *)[cell.contentView viewWithTag:numberTag];UILabel *title=(UILabel *)[cell.contentView viewWithTag:titleTag];UILabel *subtitle=(UILabel *)[cell.contentView viewWithTag:subtitleTag];UIImageView *selectedMark=(UIImageView *)[cell.contentView viewWithTag:selectedTag];UIImageView *previewView=(UIImageView *)[cell.contentView viewWithTag:previewTag];UILabel *telemetryBadge=(UILabel *)[cell.contentView viewWithTag:telemetryTag];
    if(!poster){poster=[[UIView alloc] initWithFrame:CGRectZero];poster.tag=posterTag;poster.autoresizingMask=UIViewAutoresizingFlexibleWidth;poster.backgroundColor=HostCard();poster.layer.cornerRadius=11;poster.layer.cornerCurve=kCACornerCurveContinuous;poster.clipsToBounds=YES;[cell.contentView addSubview:poster];
        previewView=[UIImageView new];previewView.tag=previewTag;previewView.contentMode=UIViewContentModeScaleAspectFill;previewView.clipsToBounds=YES;previewView.alpha=0.40;previewView.hidden=YES;previewView.accessibilityIdentifier=@"channel.card.preview";[poster addSubview:previewView];
        logo=[UIImageView new];logo.tag=logoTag;logo.autoresizingMask=UIViewAutoresizingFlexibleWidth;logo.contentMode=UIViewContentModeScaleAspectFit;[poster addSubview:logo];
        brand=[UILabel new];brand.tag=brandTag;brand.textAlignment=NSTextAlignmentCenter;brand.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont italicSystemFontOfSize:14]];brand.adjustsFontForContentSizeCategory=YES;brand.textColor=HostText();brand.autoresizingMask=UIViewAutoresizingFlexibleWidth;brand.numberOfLines=2;[poster addSubview:brand];
        number=[UILabel new];number.tag=numberTag;number.font=[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];number.textColor=HostSecondaryText();[poster addSubview:number];
        telemetryBadge=[UILabel new];telemetryBadge.tag=telemetryTag;telemetryBadge.font=[UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightSemibold];telemetryBadge.textAlignment=NSTextAlignmentRight;telemetryBadge.textColor=HostSecondaryText();telemetryBadge.hidden=YES;telemetryBadge.accessibilityIdentifier=@"channel.card.telemetry";[poster addSubview:telemetryBadge];
        title=[UILabel new];title.tag=titleTag;title.autoresizingMask=UIViewAutoresizingFlexibleWidth;title.adjustsFontForContentSizeCategory=YES;title.numberOfLines=2;title.lineBreakMode=NSLineBreakByTruncatingTail;[cell.contentView addSubview:title];
        subtitle=[UILabel new];subtitle.tag=subtitleTag;subtitle.autoresizingMask=UIViewAutoresizingFlexibleWidth;subtitle.adjustsFontForContentSizeCategory=YES;subtitle.numberOfLines=2;subtitle.lineBreakMode=NSLineBreakByTruncatingTail;subtitle.textColor=HostSecondaryText();[cell.contentView addSubview:subtitle];
        selectedMark=[UIImageView new];selectedMark.tag=selectedTag;selectedMark.contentMode=UIViewContentModeScaleAspectFit;selectedMark.image=[UIImage systemImageNamed:@"checkmark.circle.fill"];selectedMark.tintColor=HostAccent();selectedMark.backgroundColor=[UIColor colorWithWhite:0 alpha:.42];selectedMark.layer.cornerRadius=9;selectedMark.clipsToBounds=YES;[poster addSubview:selectedMark];}
    title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];subtitle.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];
    CGFloat width=cell.contentView.bounds.size.width;
    CGFloat posterHeight=MIN(78,MAX(44,floor(width*.68)));
    NSString *channelID=[ch[@"id"] isKindOfClass:NSString.class]?ch[@"id"]:@"";
    NSString *name=[ch[@"name"] isKindOfClass:NSString.class]?ch[@"name"]:([ch[@"id"] isKindOfClass:NSString.class]?ch[@"id"]:@"");
    BOOL selected=[channelID isEqualToString:self.channelID];
    NSString *titleText=[NSString stringWithFormat:@"%@%@",[self.favorites containsObject:channelID]?@"♥ ":@"",name];
    title.text=titleText;subtitle.text=[self catalogSubtitleForChannel:ch];
    CGFloat labelWidth=MAX(1,width-4),titleHeight=[self catalogTextHeight:titleText font:title.font width:labelWidth maximumLines:2],subtitleHeight=[self catalogTextHeight:subtitle.text font:subtitle.font width:labelWidth maximumLines:2];
    CGFloat titleTop=posterHeight+5,subtitleTop=titleTop+titleHeight+1;
    poster.frame=CGRectMake(0,0,width,posterHeight);poster.layer.borderWidth=selected?1.8:.5;HostSetLayerBorderColor(poster,selected?HostAccent():HostBorder());
    CGFloat logoInset=MAX(8,floor(width*.15)),logoHeight=MIN(30,MAX(20,floor(posterHeight*.44)));logo.frame=CGRectMake(logoInset,floor((posterHeight-logoHeight)/2),MAX(1,width-logoInset*2),logoHeight);brand.frame=CGRectMake(5,MAX(4,floor((posterHeight-34)/2)),MAX(1,width-10),34);number.frame=CGRectMake(6,posterHeight-15,62,12);selectedMark.frame=CGRectMake(MAX(2,width-22),5,16,16);selectedMark.hidden=!selected;
    title.frame=CGRectMake(2,titleTop,labelWidth,titleHeight);subtitle.frame=CGRectMake(2,subtitleTop,labelWidth,subtitleHeight);
    NSString *logoURL=[ch[@"logo"] isKindOfClass:NSString.class]?ch[@"logo"]:@"";BOOL showChannelLogo=[ProfileStore isChannelLogoEnabledForChannel:ch];logo.hidden=!showChannelLogo;brand.hidden=showChannelLogo;brand.text=name;
    if(!showChannelLogo){logo.image=nil;logo.backgroundColor=UIColor.clearColor;logo.layer.cornerRadius=0;logo.clipsToBounds=NO;}
    else if(logoURL.length){logo.image=nil;logo.backgroundColor=UIColor.clearColor;logo.layer.cornerRadius=0;logo.clipsToBounds=NO;[self loadLogo:logoURL into:logo];}
    else{logo.image=CCTVChannelLogoImage(ch);logo.accessibilityIdentifier=[@"channel-logo:" stringByAppendingString:channelID];BOOL dark=CCTVChannelNeedsDarkLogoBacking(ch,channelID);logo.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;logo.layer.cornerRadius=dark?5:0;logo.clipsToBounds=dark;}
    BOOL showPreview=[ProfileStore isChannelPreviewEnabledForChannel:ch];
    UIImage *previewImg=showPreview?[self previewImageForChannel:ch]:nil;
    previewView.hidden=(previewImg==nil);previewView.frame=poster.bounds;
    previewView.image=previewImg;
    BOOL showTelemetry=[ProfileStore isChannelTelemetryEnabledForChannel:ch];
    telemetryBadge.hidden=!showTelemetry;
    if(showTelemetry){
        UIColor *tColor=nil;NSString *tText=[self telemetryBadgeTextForChannel:ch color:&tColor];
        telemetryBadge.text=tText;telemetryBadge.textColor=tColor?:HostSecondaryText();
        telemetryBadge.frame=CGRectMake(34,posterHeight-15,MAX(1,width-39),12);
        [self probeTelemetryForChannel:ch];
    }else{
        telemetryBadge.text=nil;
    }
    number.text=[NSString stringWithFormat:@"%03lu",(unsigned long)ip.item+1];title.textColor=selected?HostAccent():HostText();cell.contentView.backgroundColor=selected?HostSelectedSurface():UIColor.clearColor;
    cell.accessibilityIdentifier=[@"channel-card-" stringByAppendingString:channelID];cell.accessibilityLabel=name;cell.accessibilityValue=[self telemetryAccessibilityValueForChannel:ch selected:selected];cell.accessibilityHint=@"轻点播放，长按选择线路与节目单";
    NSString *xmlSource=[ProfileStore epgSourceForChannel:ch];if(xmlSource.length && !self.epgCache[channelID])[self cacheXMLRows:[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:ch]] channel:channelID];if(!self.epgCache[channelID] && !collectionView.isDragging && !collectionView.isDecelerating){[self loadEPGForChannel:channelID channel:ch section:ip];}subtitle.text=[self catalogSubtitleForChannel:ch];return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didHighlightItemAtIndexPath:(NSIndexPath *)ip { UICollectionViewCell *c=[collectionView cellForItemAtIndexPath:ip]; if(!c||UIAccessibilityIsReduceMotionEnabled())return; [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformMakeScale(0.968,0.968);} completion:nil]; }
- (void)collectionView:(UICollectionView *)collectionView didUnhighlightItemAtIndexPath:(NSIndexPath *)ip { UICollectionViewCell *c=[collectionView cellForItemAtIndexPath:ip]; if(!c)return; [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformIdentity;} completion:nil]; }
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip { if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return;HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);[self selectChannel:self.shownChannels[ip.item]]; }
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return nil;
    NSDictionary *ch=self.shownChannels[ip.item];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ch[@"id"] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){BOOL favorite=[w.favorites containsObject:ch[@"id"]];UIAction *fav=[UIAction actionWithTitle:favorite?@"取消收藏":@"收藏频道" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){if(favorite)[w.favorites removeObject:ch[@"id"]];else[w.favorites addObject:ch[@"id"]];[NSUserDefaults.standardUserDefaults setObject:w.favorites forKey:@"favorites"];[w configureCatalogNavigation];[w applyFilter];}];UIAction *route=[UIAction actionWithTitle:@"线路与节目单" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(UIAction *a){if([ch[@"remoteURL"] length])[w openEPGforChannel:ch[@"id"] name:ch[@"name"]];else[w presentRouteSheetForChannel:ch fromIndexPath:nil];}];NSMutableArray *actions=[NSMutableArray arrayWithObjects:fav,route,nil];
        if([ch[@"remoteURL"] length]){[actions addObject:[UIAction actionWithTitle:@"静音预览（30 秒）" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){[w previewChannel:ch];}]];[actions addObject:[UIAction actionWithTitle:@"EPG 手动匹配" image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(UIAction *a){[w editEPGMapping:ch];}]];}
        [actions addObject:[UIAction actionWithTitle:@"电视台增强与同台多源" image:[UIImage systemImageNamed:@"sparkles.tv"] identifier:nil handler:^(UIAction *a){[w presentStationEnhancementSheetForChannel:ch sourceView:collectionView];}]];
        return [UIMenu menuWithTitle:ch[@"name"] children:actions];}];
}
- (void)selectChannel:(NSDictionary *)ch {
    // Repeated taps on an active/connecting channel must not restart VDN/DRM.
    BOOL sameChannel=[ch[@"id"] isEqualToString:self.channelID];
    BOOL activeNative=self.currentPlayer && !self.nativePlaybackFailed && ![ch[@"remoteURL"] length] && (self.firstRender || self.watchdog.isValid);
    BOOL activeRemote=([ch[@"remoteURL"] isEqualToString:self.currentRemoteURL]) && (self.remotePlaybackWanted || self.playbackReadiness);
    if(sameChannel && (activeNative || activeRemote)) {
        self.selectionVersion++;self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];self.playerExpanded=YES;[self configureCatalogNavigation];[self.view setNeedsLayout];return;
    }
    // Coalesce rapid taps without the previous fixed 80 ms delay.
    NSTimeInterval selectedAt=CACurrentMediaTime();NSUInteger selection=++self.selectionVersion;NSString *selectionTraceID=NSUUID.UUID.UUIDString.lowercaseString;self.currentPlaybackTraceID=selectionTraceID;self.playbackIntentVersion++;[self.playbackReadiness cancel];[self stopPreview];
    BOOL remote=[ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]];
    NSMutableDictionary *selectionFields=[@{@"input_type":remote?@"subscription":@"cctv", @"selection_generation":@(selection), @"channel_id_kind":remote?@"http_url":@"sdk_channel_id", @"correlation_id":selectionTraceID} mutableCopy];
    if(remote)[selectionFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:ch[@"remoteURL"]?:ch[@"id"]?:@""])];
    else if([ch[@"id"] isKindOfClass:NSString.class]&&[ch[@"id"] length]<=128)selectionFields[@"sdk_channel_id"]=ch[@"id"];
    if(RuntimeDiagnostics.shared.enabled){
        NSArray *subscriptionSources=[ch[@"subscriptionSources"] isKindOfClass:NSArray.class]?ch[@"subscriptionSources"]:@[];
        selectionFields[@"subscription_source_count"]=@(subscriptionSources.count);
        NSMutableArray *sourceFingerprints=[NSMutableArray array];
        for(id source in subscriptionSources){if(sourceFingerprints.count>=8)break;if([source isKindOfClass:NSString.class]){NSDictionary *fields=CCTVDiagnosticURLFields([NSURL URLWithString:source]);NSString *fingerprint=fields[@"source_route_fingerprint"];if(fingerprint.length)[sourceFingerprints addObject:fingerprint];}}
        if(sourceFingerprints.count)selectionFields[@"subscription_source_fingerprints"]=sourceFingerprints;
    }
    [RuntimeDiagnostics.shared recordEvent:@"channel_selected" category:@"playback" fields:selectionFields];
    self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];self.playerExpanded=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        if(selection!=self.selectionVersion){[RuntimeDiagnostics.shared recordEvent:@"channel_selection_superseded" category:@"playback" fields:@{@"correlation_id":selectionTraceID, @"selection_generation":@(selection), @"current_selection_generation":@(self.selectionVersion)}];return;}
        [self rememberChannel:ch];if(CCTVBoolPreference(@"rememberLastChannel",YES))[NSUserDefaults.standardUserDefaults setObject:ch forKey:@"lastChannel"];
        self.selectionRequestedAt=selectedAt;[self routePlayback:ch];[self configureCatalogNavigation];[self.view setNeedsLayout];
    });
}
- (void)routePlayback:(NSDictionary *)ch {
    if([ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]]){NSMutableDictionary *remote=[ch mutableCopy];if(![remote[@"remoteURL"] length])remote[@"remoteURL"]=remote[@"id"];[self playRemote:remote];}
    else [self playChannel:ch route:nil];
}

- (NSArray *)visibleRecents {NSSet *ids=[NSSet setWithArray:[self.allChannels valueForKey:@"id"]?:@[]];return [self.recents filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r,NSDictionary *b){return [ids containsObject:r[@"id"]];}]];}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    (void)t;
    return 1;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    (void)t; (void)s;
    return nil;
}
- (void)tableView:(UITableView *)t willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    HostStyleSectionHeaderView(view);
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t; (void)s;
    return (NSInteger)self.shownChannels.count;
}

- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t {
    (void)section; (void)t;
    return self.shownChannels;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse = @"channel.list";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[CCTVChannelListCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        cell.backgroundColor = HostCard();
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=1;cell.textLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=2;cell.detailTextLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.detailTextLabel.textColor = HostSecondaryText();
        cell.imageView.contentMode=UIViewContentModeScaleAspectFit;cell.separatorInset=UIEdgeInsetsMake(0,80,0,0);cell.preservesSuperviewLayoutMargins=NO;
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = HostSelectedSurface();
        cell.selectedBackgroundView = selected;
    }
    NSArray<NSDictionary *> *rows = [self channelsForSection:ip.section tableView:t];
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return cell;
    NSDictionary *ch = rows[(NSUInteger)ip.row];
    NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
    BOOL playing = [cid isEqualToString:self.channelID];
    NSString *title = [ch[@"name"] isKindOfClass:NSString.class] ? ch[@"name"] : cid;
    if ([self.favorites containsObject:cid]) title = [@"★ " stringByAppendingString:title];
    cell.textLabel.text = playing ? [NSString stringWithFormat:@"● %@", title] : title;
    cell.textLabel.textColor = playing ? HostAccent() : HostText();
    cell.backgroundColor=playing?HostSelectedSurface():HostCard();
    cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous; cell.clipsToBounds=YES;
    cell.layer.borderWidth=playing?1.1:0.6; HostSetLayerBorderColor(cell,playing?HostAccent():HostBorder());
    if(playing){UIImageView *check=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];check.tintColor=HostAccent();check.accessibilityLabel=@"正在播放";cell.accessoryView=check;cell.accessoryType=UITableViewCellAccessoryNone;}
    else {cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    cell.accessibilityIdentifier=[@"channel-row-" stringByAppendingString:cid];
    cell.accessibilityLabel=[ch[@"name"] isKindOfClass:NSString.class]?ch[@"name"]:cid;
    cell.accessibilityValue=[self telemetryAccessibilityValueForChannel:ch selected:playing];
    cell.accessibilityHint=@"轻点播放，长按选择线路与节目单";
    NSString *logo = [ch[@"logo"] isKindOfClass:NSString.class] ? ch[@"logo"] : @"";
    BOOL showChannelLogo = [ProfileStore isChannelLogoEnabledForChannel:ch];
    cell.imageView.hidden = !showChannelLogo;
    cell.separatorInset = UIEdgeInsetsMake(0, showChannelLogo ? 80 : 16, 0, 0);
    if (!showChannelLogo) {cell.imageView.image=nil;cell.imageView.backgroundColor=UIColor.clearColor;cell.imageView.layer.cornerRadius=0;cell.imageView.clipsToBounds=NO;}
    else if (logo.length) {cell.imageView.image=nil;cell.imageView.backgroundColor=UIColor.clearColor;cell.imageView.layer.cornerRadius=0;cell.imageView.clipsToBounds=NO;[self loadLogo:logo into:cell.imageView];}
    else {cell.imageView.image=CCTVChannelLogoImage(ch);cell.imageView.accessibilityIdentifier=[@"channel-logo:" stringByAppendingString:cid];BOOL dark=CCTVChannelNeedsDarkLogoBacking(ch,cid);cell.imageView.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;cell.imageView.layer.cornerRadius=dark?5:0;cell.imageView.clipsToBounds=dark;}
    cell.imageView.tintColor=HostAccent();
    NSDictionary *epg = self.epgCache[cid];
    NSString *nowTitle = [epg[@"now"] isKindOfClass:NSString.class] && [epg[@"now"] length] ? epg[@"now"] : nil;
    NSString *nextTitle = [epg[@"next"] isKindOfClass:NSString.class] && [epg[@"next"] length] ? epg[@"next"] : nil;
    NSUInteger sourceCount = [self sourceCountForChannel:ch];
    BOOL catchup = [ch[@"remoteURL"] length] && [self channelSupportsCatchup:ch];
    NSMutableArray<NSString *> *extraMeta = [NSMutableArray array];
    if (sourceCount > 1 && [ch[@"remoteURL"] length]) [extraMeta addObject:[NSString stringWithFormat:@"%lu 源", (unsigned long)sourceCount]];
    if (catchup) [extraMeta addObject:@"回看"];
    NSString *extraSuffix = extraMeta.count ? [@" · " stringByAppendingString:[extraMeta componentsJoinedByString:@" · "]] : @"";
    if (nowTitle) {
        NSString *epgLine = nextTitle ? [NSString stringWithFormat:@"正在播：%@ · 稍后：%@", nowTitle, nextTitle] : [NSString stringWithFormat:@"正在播：%@", nowTitle];
        cell.detailTextLabel.text = [epgLine stringByAppendingString:extraSuffix];
    } else if ([ch[@"remoteURL"] length]) {
        NSString *groupName=[ch[@"group"] isKindOfClass:NSString.class]&&[ch[@"group"] length]?ch[@"group"]:@"订阅源";
        NSString *baseSub = [groupName isEqualToString:@"订阅"] ? @"订阅源" : [NSString stringWithFormat:@"%@ · 订阅源", groupName];
        cell.detailTextLabel.text = [baseSub stringByAppendingString:extraSuffix];
    } else {
        NSUInteger routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? [ch[@"routes"] count] : 0;
        NSString *groupName=[ch[@"group"] isKindOfClass:NSString.class]?ch[@"group"]:@"直播";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu 线路 · 时移回看", groupName, (unsigned long)routes];
    }
    if (self.recentsOnly) {
        for (NSDictionary *rec in self.recents) {
            if ([rec[@"id"] isEqualToString:cid] && [rec[@"watchedAt"] respondsToSelector:@selector(doubleValue)]) {
                NSTimeInterval elapsed = MAX(0, NSDate.date.timeIntervalSince1970 - [rec[@"watchedAt"] doubleValue]);
                NSString *timeTag = elapsed < 60 ? @"刚刚观看" : (elapsed < 3600 ? [NSString stringWithFormat:@"%.0f 分钟前观看", floor(elapsed / 60.0)] : (elapsed < 86400 ? [NSString stringWithFormat:@"%.0f 小时前观看", floor(elapsed / 3600.0)] : @"最近观看"));
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", timeTag, cell.detailTextLabel.text ?: @""];
                break;
            }
        }
    }
    if([cell isKindOfClass:CCTVChannelListCell.class]){
        CCTVChannelListCell *listCell=(CCTVChannelListCell *)cell;
        BOOL showPreview=[ProfileStore isChannelPreviewEnabledForChannel:ch];
        UIImage *previewImg=showPreview?[self previewImageForChannel:ch]:nil;
        listCell.previewThumbView.hidden=(previewImg==nil);
        listCell.previewThumbView.image=previewImg;
        BOOL showTelemetry=[ProfileStore isChannelTelemetryEnabledForChannel:ch];
        listCell.telemetryBadgeLabel.hidden=!showTelemetry;
        if(showTelemetry){
            UIColor *tColor=nil;NSString *tText=[self telemetryBadgeTextForChannel:ch color:&tColor];
            listCell.telemetryBadgeLabel.text=[NSString stringWithFormat:@" %@ ",tText?:@""];
            listCell.telemetryBadgeLabel.textColor=tColor?:HostSecondaryText();
            listCell.telemetryBadgeLabel.backgroundColor=[HostRaisedSurface() colorWithAlphaComponent:0.88];
            cell.accessibilityValue=[self telemetryAccessibilityValueForChannel:ch selected:[cid isEqualToString:self.channelID]];
            if(tText.length&&![cell.detailTextLabel.text containsString:tText]){
                cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",cell.detailTextLabel.text?:@"",tText];
            }
            [self probeTelemetryForChannel:ch];
        }else{
            listCell.telemetryBadgeLabel.text=nil;
        }
    }
    [self loadEPGForChannel:cid channel:ch section:ip];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];NSArray *rows=[self channelsForSection:ip.section tableView:t];if(ip.row>=rows.count)return;[self selectChannel:rows[ip.row]];
}
- (void)loadEPGForVisibleGridItems {
    if (!self.channelGrid || self.channelGrid.hidden) return;
    for (NSIndexPath *ip in self.channelGrid.indexPathsForVisibleItems) {
        if (ip.item < 0 || ip.item >= (NSInteger)self.shownChannels.count) continue;
        NSDictionary *ch = self.shownChannels[(NSUInteger)ip.item];
        NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
        if (cid.length && !self.epgCache[cid]) {
            [self loadEPGForChannel:cid channel:ch section:ip];
        }
    }
}
- (void)loadDeferredMetadataForVisibleTableRows {
    if (!self.table || self.table.hidden) return;
    for (NSIndexPath *ip in self.table.indexPathsForVisibleRows) {
        if (ip.row < 0 || ip.row >= (NSInteger)self.shownChannels.count) continue;
        NSDictionary *ch = self.shownChannels[(NSUInteger)ip.row];
        NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
        if (cid.length && !self.epgCache[cid]) [self loadEPGForChannel:cid channel:ch section:ip];
        if ([ProfileStore isChannelTelemetryEnabledForChannel:ch]) [self probeTelemetryForChannel:ch];
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == self.channelGrid) [self loadEPGForVisibleGridItems];
    else if (scrollView == self.table) [self loadDeferredMetadataForVisibleTableRows];
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        if (scrollView == self.channelGrid) [self loadEPGForVisibleGridItems];
        else if (scrollView == self.table) [self loadDeferredMetadataForVisibleTableRows];
    }
}
- (void)reloadVisibleCatalogItemForChannelID:(NSString *)cid {
    if (!cid.length || !self.isViewLoaded) return;
    NSIndexPath *matchPath = [self indexPathForChannelID:cid];
    if (!matchPath) return;
    [UIView performWithoutAnimation:^{
        if (self.table && !self.table.hidden) {
            for (NSIndexPath *visibleRow in self.table.indexPathsForVisibleRows) {
                if (visibleRow.section == matchPath.section && visibleRow.row == matchPath.row) {
                    [self.table reloadRowsAtIndexPaths:@[visibleRow] withRowAnimation:UITableViewRowAnimationNone];
                    break;
                }
            }
        }
        if (self.channelGrid && !self.channelGrid.hidden) {
            for (NSIndexPath *visibleItem in self.channelGrid.indexPathsForVisibleItems) {
                if (visibleItem.section == matchPath.section && visibleItem.item == matchPath.row) {
                    [self.channelGrid reloadItemsAtIndexPaths:@[visibleItem]];
                    break;
                }
            }
        }
    }];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSDictionary *ch = nil;
    NSIndexPath *ip = nil;
    UIView *source = g.view;
    if (g.view == self.table) {
        CGPoint point = [g locationInView:self.table];
        ip = [self.table indexPathForRowAtPoint:point];
        if (!ip) return;
        NSArray<NSDictionary *> *rows = [self channelsForSection:ip.section tableView:self.table];
        if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return;
        ch = rows[(NSUInteger)ip.row];
        source = [self.table cellForRowAtIndexPath:ip] ?: self.table;
    } else {
        ch = objc_getAssociatedObject(g.view, @selector(onChannelCardTap:));
        if (!ch) return;
        ip = [self indexPathForChannelID:ch[@"id"]];
    }
    if ([ch[@"remoteURL"] length]) { [self presentSubscriptionActions:ch sourceView:source]; return; }
    [self presentRouteSheetForChannel:ch fromIndexPath:ip];
}

#pragma mark - 线路

- (void)showRoutes {
    if (!self.channelID.length) { [self log:@"请先选择频道"]; return; }
    NSDictionary *ch = [self channelWithID:self.channelID];
    if (!ch) return;
    [self presentRouteSheetForChannel:ch fromIndexPath:nil];
}

- (NSDictionary *)channelWithID:(NSString *)cid {
    if (!cid.length) return nil;
    NSArray<NSDictionary *> *currentAll = self.allChannels;
    if (self.channelIndexSourceArray != currentAll || !self.channelIndexByID) {
        NSMutableDictionary<NSString *, NSDictionary *> *map = [NSMutableDictionary dictionaryWithCapacity:currentAll.count];
        for (NSDictionary *c in currentAll) {
            NSString *k = [c[@"id"] isKindOfClass:NSString.class] ? c[@"id"] : @"";
            if (k.length && !map[k]) map[k] = c;
        }
        self.channelIndexByID = map.copy;
        self.channelIndexSourceArray = currentAll;
    }
    return self.channelIndexByID[cid];
}

- (void)presentRouteSheetForChannel:(NSDictionary *)ch fromIndexPath:(NSIndexPath *)ip {
    if([ch[@"remoteURL"] length]){[self showRemoteTools:ch];return;}
    NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ch[@"name"]
                                                                  message:[NSString stringWithFormat:@"当前线路：%@ · %lu 个地址\n自选地址交给央视 SDK 播放；许可及版权仍由 SDK 处理。",
                                                                           [ch[@"id"] isEqual:self.channelID]?(self.routeName?:@"自动"):@"未选择", (unsigned long)routes.count]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"SDK 自动选线" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self playChannel:ch route:nil];
    }]];
    for (NSDictionary *r in routes) {
        NSString *res = [r[@"w"] intValue] > 0 ? [NSString stringWithFormat:@"%dx%d", [r[@"w"] intValue], [r[@"h"] intValue]] : @"";
        NSString *title = [NSString stringWithFormat:@"自选地址 %@ · 源标注 %@", [r[@"provider"] uppercaseString], res.length?res:@"未知"];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playChannel:ch route:r];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"节目单与回看" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self openEPGforChannel:ch[@"id"] name:ch[@"name"]];
    }]];
    if ([ch[@"id"] isEqual:self.channelID] && self.currentPlayer && !self.avPlayer) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"时移 / 回看" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self showNativeTimeshiftActions];
        }]];
        if (self.nativeTimeShiftActive) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"返回直播" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                [self returnToLivePlayback];
            }]];
        }
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ip && self.table && !self.table.hidden) {
        sheet.popoverPresentationController.sourceView = self.table;
        sheet.popoverPresentationController.sourceRect = [self.table rectForRowAtIndexPath:ip];
    }
    if(!sheet.popoverPresentationController.sourceView&&!sheet.popoverPresentationController.barButtonItem){sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);}
    [self presentViewController:sheet animated:YES completion:nil];
}
- (NSArray<NSDictionary *> *)playerCategoryRows {
    NSArray *groups=[self currentCatalogGroupTitles];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSSet *favoriteIDs=[NSSet setWithArray:self.favorites?:@[]];
    NSSet *recentIDs=[NSSet setWithArray:[self.recents valueForKey:@"id"]?:@[]];
    NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];
    for(NSDictionary *channel in self.allChannels){
        BOOL remote=[channel[@"remoteURL"] length]>0;
        if(!remote&&(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)||self.activeSource.length))continue;
        if(remote){NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];[owners minusSet:disabled];if(!owners.count||(self.activeSource.length&&![owners containsObject:self.activeSource]))continue;}
        NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
        if([favoriteIDs containsObject:cid])counts[@"收藏"]=@([counts[@"收藏"] unsignedIntegerValue]+1);
        if([recentIDs containsObject:cid])counts[@"最近"]=@([counts[@"最近"] unsignedIntegerValue]+1);
        if(remote!=self.subscriptionCatalog)continue;
        NSString *query=self.query.lowercaseString;NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"";
        if(query.length){
            NSString *groupStr=[channel[@"group"] isKindOfClass:NSString.class]?channel[@"group"]:@"";
            NSString *epgNow=[self.epgCache[cid][@"now"] isKindOfClass:NSString.class]?self.epgCache[cid][@"now"]:@"";
            NSString *canonical=[ProfileStore canonicalStationIDForChannel:channel]?:@"";
            BOOL matched=[name.lowercaseString containsString:query] || [cid.lowercaseString containsString:query] || [groupStr.lowercaseString containsString:query] || [epgNow.lowercaseString containsString:query] || [canonical.lowercaseString containsString:query];
            if(!matched)continue;
        }
        counts[@"全部"]=@([counts[@"全部"] unsignedIntegerValue]+1);
        NSString *group=[channel[@"group"] isKindOfClass:NSString.class]?channel[@"group"]:@"其他";
        if([group isEqualToString:@"熊猫"])group=@"央视";
        if(self.subscriptionCatalog&&![@[@"央视",@"卫视",@"地方"] containsObject:group])group=@"其他";
        counts[group]=@([counts[group] unsignedIntegerValue]+1);
    }
    NSDictionary<NSString *,NSString *> *groupIcons=@{@"全部":@"square.grid.2x2",@"央视":@"tv.fill",@"卫视":@"sparkles.tv",@"地方":@"map.fill",@"教育":@"book.fill",@"其他":@"rectangle.stack.fill",@"收藏":@"heart.fill",@"最近":@"clock.arrow.circlepath"};
    NSMutableArray *rows=[NSMutableArray array];for(NSUInteger i=0;i<groups.count;i++){NSString *group=groups[i];[rows addObject:@{@"index":@(i),@"title":group,@"detail":[NSString stringWithFormat:@"%lu 个频道",(unsigned long)[counts[group] unsignedIntegerValue]],@"selected":@(self.groupControl.selectedSegmentIndex==(NSInteger)i),@"symbol":groupIcons[group]?:@"folder"}];}return rows;
}
- (CCTVPlaybackListPanelController *)categoryPanel {
    CCTVPlaybackListPanelController *panel=[CCTVPlaybackListPanelController new];panel.items=[self playerCategoryRows];panel.emptyMessage=@"当前没有可显示的频道分组";__weak typeof(self) weakSelf=self;
    panel.selectionHandler=^(NSDictionary *item){RootViewController *owner=weakSelf;if(!owner)return;owner.groupControl.selectedSegmentIndex=[item[@"index"] integerValue];[owner onGroupChanged];owner.playerTabs.selectedSegmentIndex=1;[owner selectPlayerPanel];};return panel;
}
- (CCTVPlaybackListPanelController *)routesPanel {
    CCTVPlaybackListPanelController *panel=[CCTVPlaybackListPanelController new];NSMutableArray *rows=[NSMutableArray array];NSDictionary *channel=[self channelWithID:self.channelID];
    if(self.currentRemoteURL.length){
        NSString *name=channel[@"name"]?:self.channelName?:@"订阅频道";NSArray *alternates=self.altSources[CCTVRouteGroupKey(channel)]?:@[self.currentRemoteURL];NSMutableSet *seen=[NSMutableSet set];NSUInteger index=0;
        for(NSString *url in alternates){NSString *stable=[self stableURLKey:url];if(!stable.length||[seen containsObject:stable])continue;[seen addObject:stable];index++;BOOL selected=[stable isEqualToString:self.currentRemoteURL];NSURL *target=[NSURL URLWithString:url];NSString *host=target.host?:@"播放源";NSString *title=alternates.count>1?[NSString stringWithFormat:@"播放源 %lu · %@",(unsigned long)index,host]:name;NSString *detail=[NSString stringWithFormat:@"%@ · %@",selected?@"当前播放":@"点按切换",[self displaySafeSourceURL:url]];[rows addObject:@{@"kind":@"remote",@"url":url,@"title":title,@"detail":detail,@"selected":@(selected),@"symbol":@"dot.radiowaves.left.and.right"}];}
    }else if(channel){
        NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];BOOL automatic=self.requestedNativeRoute==nil;
        [rows addObject:@{@"kind":@"automatic",@"title":@"SDK 自动选择",@"detail":@"由央视 SDK 调度并处理版权；节点未主动探测",@"selected":@(automatic),@"symbol":@"sparkles"}];
        for(NSDictionary *route in routes){NSString *provider=[route[@"provider"] isKindOfClass:NSString.class]?route[@"provider"]:@"线路";NSInteger width=[route[@"w"] integerValue],height=[route[@"h"] integerValue];NSString *resolution=width>0&&height>0?[NSString stringWithFormat:@"源标注 %ld × %ld",(long)width,(long)height]:@"源标注分辨率未知";NSString *url=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";BOOL selected=[provider caseInsensitiveCompare:self.requestedNativeRoute[@"provider"]?:@""]==NSOrderedSame;[rows addObject:@{@"kind":@"native",@"route":route,@"title":[NSString stringWithFormat:@"自选地址 %@",provider.uppercaseString],@"detail":[NSString stringWithFormat:@"%@ · 明文用 AVPlayer，其余交给央视 SDK\n%@",resolution,[self displaySafeSourceURL:url]],@"selected":@(selected),@"symbol":@"antenna.radiowaves.left.and.right"}];}
    }
    panel.items=rows;panel.emptyMessage=self.channelID.length?@"此频道没有可用的线路信息。可以使用顶部线路菜单或检查频道来源。":@"请先选择频道";__weak typeof(self) weakSelf=self;
    NSString *panelChannelID=self.channelID.copy;
    panel.selectionHandler=^(NSDictionary *item){RootViewController *owner=weakSelf;if(!owner||![owner.channelID isEqual:panelChannelID])return;NSDictionary *active=[owner channelWithID:owner.channelID];if([item[@"kind"] isEqual:@"remote"]){NSMutableDictionary *next=[(active?:@{@"id":owner.channelID?:@"",@"name":owner.channelName?:@"直播"}) mutableCopy];next[@"remoteURL"]=item[@"url"];[owner routePlayback:next];[owner configureCatalogNavigation];return;}if(!active)return;[owner playChannel:active route:[item[@"kind"] isEqual:@"native"]?item[@"route"]:nil];[owner configureCatalogNavigation];};return panel;
}
- (void)selectPlayerPanel {
    if(self.playbackPanel){[self.playbackPanel willMoveToParentViewController:nil];[self.playbackPanel.view removeFromSuperview];[self.playbackPanel removeFromParentViewController];self.playbackPanel=nil;}
    NSInteger index=self.playerTabs.selectedSegmentIndex;UIViewController *v=nil;
    if(index==0)v=[self categoryPanel];else if(index==2)v=[self epgPageForChannel:self.channelID name:self.channelName];else if(index==3)v=[self routesPanel];
    if(v){self.playbackPanel=v;[self addChildViewController:v];[self.view addSubview:v.view];[v didMoveToParentViewController:self];}[self.view setNeedsLayout];
}

- (void)presentSubscriptionActions:(NSDictionary *)channel sourceView:(UIView *)source {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:channel[@"name"]?:@"订阅频道" message:channel[@"remoteURL"] preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"节目单与回看" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self openEPGforChannel:channel[@"id"] name:channel[@"name"]]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"从列表移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ NSMutableArray *m=[self.allChannels mutableCopy]; [m removeObject:channel]; self.allChannels=m; [self applyFilter]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=source; a.popoverPresentationController.sourceRect=source.bounds; [self presentViewController:a animated:YES completion:nil];
}

- (NSIndexPath *)indexPathForChannelID:(NSString *)cid {
    if (!cid.length) return nil;
    NSArray<NSDictionary *> *currentShown = self.shownChannels;
    if (self.shownChannelIndexSourceArray != currentShown || !self.shownChannelIndexByID) {
        NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:currentShown.count];
        for (NSUInteger i = 0; i < currentShown.count; i++) {
            NSString *k = [currentShown[i][@"id"] isKindOfClass:NSString.class] ? currentShown[i][@"id"] : @"";
            if (k.length && !map[k]) map[k] = @(i);
        }
        self.shownChannelIndexByID = map.copy;
        self.shownChannelIndexSourceArray = currentShown;
    }
    NSNumber *idx = self.shownChannelIndexByID[cid];
    return idx ? [NSIndexPath indexPathForRow:idx.integerValue inSection:0] : nil;
}

#pragma mark - 台标

- (void)loadLogo:(NSString *)url into:(UIImageView *)iv {
    [[HostImageLoader shared] loadURL:url intoImageView:iv];
}

#pragma mark - 搜索 / 最近 / 节目单缓存

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    if(self.activeTab>=2)return;
    self.query = sc.searchBar.text;
    NSUInteger generation=++self.catalogSearchGeneration;
    if(!self.query.length){[self applyFilter];return;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation==weakSelf.catalogSearchGeneration && weakSelf.activeTab<2)[weakSelf applyFilter];
    });
}

- (void)enableNativeChannelsFromEmptyState {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"nativeChannelsEnabled"];
    self.activeSource = nil;
    self.favoritesOnly = NO;
    self.recentsOnly = NO;
    self.groupControl.selectedSegmentIndex = 0;
    [self configureCatalogNavigation];
    [self applyFilter];
    [self updateLiveResourceCapsule];
}

- (void)resetCatalogFilterToAll {
    self.favoritesOnly = NO;
    self.recentsOnly = NO;
    self.query = @"";
    self.searchController.searchBar.text = @"";
    self.groupControl.selectedSegmentIndex = 0;
    [self configureCatalogNavigation];
    [self applyFilter];
}

- (UIView *)buildCatalogEmptyBackgroundViewWithMessage:(NSString *)message {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 260)];
    container.backgroundColor = UIColor.clearColor;
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-12],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:28],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-28]
    ]];
    NSString *symbolName = self.query.length ? @"magnifyingglass" : (self.recentsOnly ? @"clock.arrow.circlepath" : (self.favoritesOnly ? @"heart.slash" : (self.subscriptionCatalog ? @"dot.radiowaves.left.and.right" : @"tv.slash")));
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]]];
    iconView.tintColor = HostMutedText();
    [stack addArrangedSubview:iconView];
    UILabel *hint = [UILabel new];
    hint.text = message;
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = HostSecondaryText();
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    hint.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:hint];
    UIButton *actionButton = nil;
    if (!self.subscriptionCatalog && !CCTVBoolPreference(@"nativeChannelsEnabled", YES)) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  立即启用官方频道  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, YES);
        actionButton.accessibilityIdentifier = @"catalog.empty.enable-native";
        [actionButton addTarget:self action:@selector(enableNativeChannelsFromEmptyState) forControlEvents:UIControlEventTouchUpInside];
    } else if (self.favoritesOnly || self.recentsOnly || self.query.length || self.groupControl.selectedSegmentIndex > 0) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  查看全部频道  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, NO);
        actionButton.accessibilityIdentifier = @"catalog.empty.reset-filter";
        [actionButton addTarget:self action:@selector(resetCatalogFilterToAll) forControlEvents:UIControlEventTouchUpInside];
    } else if (self.subscriptionCatalog) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  添加直播订阅  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, YES);
        actionButton.accessibilityIdentifier = @"catalog.empty.add-subscription";
        [actionButton addTarget:self action:@selector(addSubscription) forControlEvents:UIControlEventTouchUpInside];
    }
    if (actionButton) {
        [actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:38].active = YES;
        [stack addArrangedSubview:actionButton];
    }
    return container;
}

- (void)applyFilter {
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSArray *groups = [self currentCatalogGroupTitles];
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSString *selectedGroup = (idx >= 0 && idx < (NSInteger)groups.count) ? groups[idx] : @"全部";
    BOOL isRecentsSegment = self.recentsOnly || [selectedGroup isEqualToString:@"最近"];
    BOOL isFavoritesSegment = !isRecentsSegment && (self.favoritesOnly || [selectedGroup isEqualToString:@"收藏"]);
    NSArray *base=[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *bindings){
        BOOL remote=[c[@"remoteURL"] length]>0;
        if(!self.favoritesOnly && !isFavoritesSegment && !isRecentsSegment && remote!=self.subscriptionCatalog)return NO;
        if(!remote)return CCTVBoolPreference(@"nativeChannelsEnabled",YES) && (!self.activeSource || !self.activeSource.length);
        NSSet *owners=[NSSet setWithArray:CCTVStringArrayValue(c[@"subscriptionSources"])];NSMutableSet *enabled=[owners mutableCopy];[enabled minusSet:disabled];
        if(!enabled.count)return NO;
        if(!self.activeSource.length)return YES;
        for(NSString *owner in enabled)if([self subscriptionOwner:owner matchesLiveResourceSource:self.activeSource])return YES;
        return NO;
    }]];
    if (self.favoritesOnly) {
        NSSet *ids=[NSSet setWithArray:self.favorites ?: @[]];
        base=[base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b){ return [ids containsObject:o[@"id"] ?: @""]; }]];
    } else if (isRecentsSegment) {
        NSMutableDictionary<NSString *, NSDictionary *> *byID = [NSMutableDictionary dictionary];
        for (NSDictionary *ch in base) {
            NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
            if (cid.length && !byID[cid]) byID[cid] = ch;
        }
        NSMutableArray<NSDictionary *> *orderedRecents = [NSMutableArray array];
        for (NSDictionary *r in self.recents) {
            NSString *rid = [r[@"id"] isKindOfClass:NSString.class] ? r[@"id"] : @"";
            NSDictionary *matched = rid.length ? byID[rid] : nil;
            if (matched) [orderedRecents addObject:matched];
        }
        base = orderedRecents;
    } else if (idx > 0 && idx < (NSInteger)groups.count) {
        NSString *g = groups[idx];
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            BOOL exact = [o[@"group"] isKindOfClass:NSString.class] && [o[@"group"] isEqualToString:g];
            if (exact) return YES;
            if ([g isEqualToString:@"央视"] && [o[@"group"] isKindOfClass:NSString.class] && [o[@"group"] isEqualToString:@"熊猫"]) return YES;
            if ([g isEqualToString:@"其他"] && [o[@"group"] isKindOfClass:NSString.class] && ![@[@"央视", @"卫视", @"地方"] containsObject:o[@"group"]]) return YES;
            return NO;
        }]];
    }
    if (self.query.length) {
        NSString *q = self.query.lowercaseString;
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            // name/id 可能来自外部订阅缓存，非字符串时直接调 lowercaseString 会
            // 抛 unrecognized selector；用 description 归一为字符串再比较。
            NSString *name=[(o[@"name"]?:@"") description];
            NSString *cid=[(o[@"id"]?:@"") description];
            NSString *groupStr=[(o[@"group"]?:@"") description];
            NSString *epgNow=[self.epgCache[cid][@"now"] isKindOfClass:NSString.class]?self.epgCache[cid][@"now"]:@"";
            NSString *canonical=[ProfileStore canonicalStationIDForChannel:o]?:@"";
            return [[name lowercaseString] containsString:q] || [[cid lowercaseString] containsString:q] || [[groupStr lowercaseString] containsString:q] || [[epgNow lowercaseString] containsString:q] || [[canonical lowercaseString] containsString:q];
        }]];
    }
    NSArray *sorted = base;
    if (!isRecentsSegment) {
        NSMutableDictionary<NSString *,NSNumber *> *ranks=[NSMutableDictionary dictionary];
        for(NSUInteger index=0;index<self.favorites.count;index++){id fav=self.favorites[index];if([fav isKindOfClass:NSString.class]&&!ranks[fav])ranks[fav]=@(index);}
        sorted = [base sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSNumber *left=ranks[a[@"id"]?:@""],*right=ranks[b[@"id"]?:@""];
            if(left && right)return [left compare:right];
            if(left || right)return left?NSOrderedAscending:NSOrderedDescending;
            // 按名称排序：收藏仍置顶（按收藏顺序），其余按名称排序；默认模式保持订阅原始顺序。
            if(self.channelSortMode==1){NSString *an=[(a[@"name"]?:@"") description],*bn=[(b[@"name"]?:@"") description];return [an localizedCaseInsensitiveCompare:bn];}
            return NSOrderedSame;
        }];
    }
    self.shownChannels = sorted;
    [self.table reloadData];
    [self.channelGrid reloadData];
    NSString *empty=self.query.length?@"没有找到匹配频道":(isRecentsSegment?@"暂无最近观看记录\n点选任意频道即可自动记录上次播放":(self.favoritesOnly?@"还没有收藏频道\n长按或左滑任意频道即可加入收藏":(self.subscriptionCatalog?@"暂无订阅频道\n点击下方按钮或右下角更多 → 添加直播订阅":(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)?@"官方频道已关闭\n点击下方按钮可立即启用央视与卫视频道":@"当前分组下暂无可用频道"))));
    self.channelGrid.backgroundView=sorted.count?nil:[self buildCatalogEmptyBackgroundViewWithMessage:empty];
    self.table.backgroundView=sorted.count?nil:[self buildCatalogEmptyBackgroundViewWithMessage:empty];
}

- (void)rememberChannel:(NSDictionary *)ch {
    if (!ch[@"id"]) return;
    NSMutableDictionary *entry = [@{@"id": ch[@"id"],
                                    @"name": ch[@"name"] ?: ch[@"id"],
                                    @"group": ch[@"group"] ?: @"",
                                    @"watchedAt": @(floor(NSDate.date.timeIntervalSince1970))} mutableCopy];
    if ([ch[@"remoteURL"] length]) entry[@"remoteURL"] = ch[@"remoteURL"];
    if ([ch[@"logo"] isKindOfClass:NSString.class] && [ch[@"logo"] length]) entry[@"logo"] = ch[@"logo"];
    NSMutableArray *m = [NSMutableArray arrayWithObject:entry];
    for (NSDictionary *r in self.recents) {
        if (![r[@"id"] isEqualToString:ch[@"id"]] && m.count < 24) [m addObject:r];
    }
    self.recents = m;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"recents"];
}

- (void)onPullRefresh {
    if(self.subscriptionCatalog||self.activeTab==3){for(NSString *u in self.subscriptionURLs.allObjects)[self fetchSubscription:u silent:NO];}
    else{self.epgListGeneration++;[self.epgCache removeAllObjects];[self saveEPGCache];if(self.firstRender)[self refreshNowNext];[self applyFilter];[self refreshChannelPreviewSnapshotsForChannels:self.shownChannels force:YES];}
    [self.table.refreshControl endRefreshing];[self.channelGrid.refreshControl endRefreshing];
}
@end
