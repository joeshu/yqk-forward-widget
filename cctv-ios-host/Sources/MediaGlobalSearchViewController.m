#import "MediaGlobalSearchViewController.h"
#import "MediaAPIClient.h"
#import "LocalServiceReadiness.h"
#import "HostTheme.h"
#import "PyHost.h"
#import "MediaSourceHealthStore.h"
#import <math.h>

static const NSUInteger MediaGlobalSearchMaximumResults = 100;
static const NSUInteger MediaGlobalSearchMaximumConcurrentSources = 3;

@interface MediaGlobalSearchJob : NSObject
@property(nonatomic) NSUInteger section;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,strong) LocalServiceReadiness *readiness;
@property(nonatomic,copy) NSArray<NSDictionary *> *providers;
@property(nonatomic) NSUInteger providerIndex;
@property(nonatomic) NSUInteger successfulProviderCount;
@property(nonatomic,copy) NSArray<NSDictionary *> *failedProviders;
@property(nonatomic,copy) NSString *providerFailure;
@end
@implementation MediaGlobalSearchJob @end

@interface MediaGlobalSearchViewController () <UISearchBarDelegate>
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,strong) UIButton *historyButton;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *rows;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,MediaGlobalSearchJob *> *jobs;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *pendingSections;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *retrySections;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger resultCount;
@property(nonatomic) NSUInteger completedCount;
@property(nonatomic) NSUInteger scheduledCount;
@property(nonatomic) BOOL searching;
@property(nonatomic) BOOL resultLimitReached;
@property(nonatomic,copy) NSString *keyword;
@property(nonatomic,copy) NSArray<NSString *> *searchHistory;
- (void)sortPendingSectionsByHealth;
- (void)showSearchHistory;
- (void)rememberSearchKeyword:(NSString *)keyword;
@end

@implementation MediaGlobalSearchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"跨来源搜索";
    self.view.backgroundColor = HostBackground();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.tableFooterView = [UIView new];
    self.rows = [NSMutableArray array];
    self.jobs = [NSMutableDictionary dictionary];
    self.pendingSections = [NSMutableArray array];
    self.retrySections = [NSMutableSet set];
    self.keyword = @"";
    NSArray *history=[NSUserDefaults.standardUserDefaults arrayForKey:@"media.globalSearchHistory.v1"];
    self.searchHistory=[history isKindOfClass:NSArray.class]?history:@[];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(1, self.tableView.bounds.size.width), 104)];
    header.backgroundColor = HostBackground();
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索所有已导入影视来源";
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [header addSubview:self.searchBar];
    self.historyButton=[UIButton buttonWithType:UIButtonTypeSystem];
    self.historyButton.translatesAutoresizingMaskIntoConstraints=NO;
    [self.historyButton setTitle:@"历史" forState:UIControlStateNormal];
    self.historyButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.historyButton.accessibilityLabel=@"搜索历史设置";
    [self.historyButton addTarget:self action:@selector(showSearchHistory) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.historyButton];
    self.progressLabel = [UILabel new];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.progressLabel.adjustsFontForContentSizeCategory = YES;
    self.progressLabel.textColor = HostSecondaryText();
    self.progressLabel.numberOfLines = 0;
    self.progressLabel.text = @"各来源独立显示搜索进度；未运行的插件不会自动启动。";
    [header addSubview:self.progressLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.historyButton.leadingAnchor constant:-4],
        [self.searchBar.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [self.historyButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
        [self.historyButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.historyButton.widthAnchor constraintEqualToConstant:48],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:2],
        [self.progressLabel.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8]
    ]];
    self.tableView.tableHeaderView = header;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"搜索" style:UIBarButtonItemStyleDone target:self action:@selector(submitSearch)];
    [self.tableView reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (fabs(header.frame.size.width - width) > 0.5) {
        header.frame = CGRectMake(0, 0, width, 104);
        self.tableView.tableHeaderView = header;
    }
}

- (BOOL)sourceAvailableForSearch:(NSDictionary *)source {
    if (MediaSourceUsesNativeCatalogAPI(source)) return YES;
    NSString *identifier = [source[@"id"] isKindOfClass:NSString.class] ? source[@"id"] : @"";
    return identifier.length && [PyHost isRunningServiceIdentifier:identifier];
}

- (void)submitSearch {
    [self.searchBar resignFirstResponder];
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        self.progressLabel.text = @"请输入关键词。各来源将分别显示进度和结果。";
        return;
    }
    self.keyword = query;
    [self rememberSearchKeyword:query];
    [self cancelJobsAndAdvanceGeneration];
    [self.rows removeAllObjects];
    for (NSUInteger index = 0; index < self.sources.count; index++) {
        NSDictionary *source = self.sources[index];
        BOOL available = [self sourceAvailableForSearch:source];
        [self.rows addObject:[@{@"state":available?@"等待搜索":@"服务未运行 · 点按启动", @"results":[NSMutableArray array], @"error":@"", @"provider":@"", @"providerError":@"", @"failedProviders":@[]} mutableCopy]];
        if (available) [self.pendingSections addObject:@(index)];
    }
    [self sortPendingSectionsByHealth];
    self.resultCount = 0;
    self.completedCount = 0;
    self.scheduledCount = self.pendingSections.count;
    self.resultLimitReached = NO;
    self.searching = self.pendingSections.count > 0;
    self.retrySections = [NSMutableSet set];
    self.navigationItem.rightBarButtonItem.title = self.searching ? @"停止" : @"重试失败";
    self.navigationItem.rightBarButtonItem.action = self.searching ? @selector(cancelSearch) : @selector(retryFailedSources);
    [self updateProgress];
    [self.tableView reloadData];
    [self scheduleSources];
}

- (void)rememberSearchKeyword:(NSString *)keyword {
    if(![NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]||!keyword.length||keyword.length>256)return;
    NSMutableArray *values=[self.searchHistory mutableCopy]?:[NSMutableArray array];[values removeObject:keyword];[values insertObject:keyword atIndex:0];if(values.count>20)[values removeObjectsInRange:NSMakeRange(20,values.count-20)];self.searchHistory=values.copy;[NSUserDefaults.standardUserDefaults setObject:self.searchHistory forKey:@"media.globalSearchHistory.v1"];
}

- (void)showSearchHistory {
    BOOL enabled=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"];
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"搜索历史" message:enabled?(self.searchHistory.count?@"选择关键词重新搜索。历史只保存在本机，可随时清除。":@"还没有保存搜索词。"):@"搜索历史默认关闭；开启后最多保留 20 条关键词，仅保存在本机。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for(NSString *term in self.searchHistory){if(![term isKindOfClass:NSString.class]||!term.length)continue;[menu addAction:[UIAlertAction actionWithTitle:term style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;owner.searchBar.text=term;[owner submitSearch];}]];}
    if(enabled&&self.searchHistory.count)[menu addAction:[UIAlertAction actionWithTitle:@"清空搜索历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;owner.searchHistory=@[];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];[owner showSearchHistory];}]];
    [menu addAction:[UIAlertAction actionWithTitle:enabled?@"关闭搜索历史":@"开启搜索历史" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;[NSUserDefaults.standardUserDefaults setBool:!enabled forKey:@"media.globalSearchHistoryEnabled.v1"];if(enabled){owner.searchHistory=@[];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];id rawBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];NSMutableDictionary *browse=[rawBrowse isKindOfClass:NSDictionary.class]?[rawBrowse mutableCopy]:[NSMutableDictionary dictionary];[browse enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSDictionary *state,BOOL *stop){if(![state isKindOfClass:NSDictionary.class])return;NSMutableDictionary *clean=[state mutableCopy];clean[@"keyword"]=@"";browse[key]=clean.copy;}];[NSUserDefaults.standardUserDefaults setObject:browse forKey:@"media.browseStates.v1"];}[NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(!enabled)}];[owner showSearchHistory];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(menu.popoverPresentationController){menu.popoverPresentationController.sourceView=self.historyButton;menu.popoverPresentationController.sourceRect=self.historyButton.bounds;}
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)cancelJobsAndAdvanceGeneration {
    self.generation++;
    for (MediaGlobalSearchJob *job in self.jobs.allValues) {
        [job.readiness cancel];
        [job.client cancel];
    }
    [self.jobs removeAllObjects];
    [self.pendingSections removeAllObjects];
}

- (void)sortPendingSectionsByHealth {
    [self.pendingSections sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){
        NSDictionary *sourceA=a.unsignedIntegerValue<self.sources.count?self.sources[a.unsignedIntegerValue]:@{};
        NSDictionary *sourceB=b.unsignedIntegerValue<self.sources.count?self.sources[b.unsignedIntegerValue]:@{};
        BOOL downA=[MediaSourceHealthStore.shared isDeprioritizedSourceID:sourceA[@"id"]?:@""];
        BOOL downB=[MediaSourceHealthStore.shared isDeprioritizedSourceID:sourceB[@"id"]?:@""];
        if(downA!=downB)return downA?NSOrderedDescending:NSOrderedAscending;
        return [a compare:b];
    }];
}

- (void)cancelSearch {
    if (!self.searching) return;
    [self cancelJobsAndAdvanceGeneration];
    for (NSMutableDictionary *row in self.rows) {
        if ([row[@"state"] isEqual:@"搜索中"] || [row[@"state"] isEqual:@"等待搜索"]) row[@"state"] = @"已取消";
        else if ([[row[@"state"] description] containsString:@"正在请求启动"]) row[@"state"] = @"启动请求仍在处理 · 点按此来源继续检查";
    }
    self.searching = NO;
    self.navigationItem.rightBarButtonItem.title = @"重试失败";
    self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    self.progressLabel.text = [NSString stringWithFormat:@"搜索已停止 · 已保留 %lu 条已读取结果。", (unsigned long)self.resultCount];
    [self.tableView reloadData];
}

- (void)scheduleSources {
    if (!self.searching) return;
    while (self.jobs.count < MediaGlobalSearchMaximumConcurrentSources && self.pendingSections.count) {
        NSNumber *number = self.pendingSections.firstObject;
        [self.pendingSections removeObjectAtIndex:0];
        NSUInteger section = number.unsignedIntegerValue;
        if (section >= self.sources.count || section >= self.rows.count) continue;
        [self startSourceAtSection:section];
    }
    [self updateProgress];
    if (!self.jobs.count && !self.pendingSections.count) {
        self.searching = NO;
        self.navigationItem.rightBarButtonItem.title = @"重试失败";
        self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    }
}

- (void)startSourceAtSection:(NSUInteger)section {
    NSDictionary *source = self.sources[section];
    MediaGlobalSearchJob *job = [MediaGlobalSearchJob new];
    job.section = section;
    job.generation = self.generation;
    job.source = source;
    job.startedAt = CACurrentMediaTime();
    self.jobs[@(section)] = job;
    self.rows[section][@"state"] = @"搜索中";
    self.rows[section][@"error"] = @"";
    [self reloadSection:section];

    if (MediaSourceUsesNativeCatalogAPI(source)) {
        job.client = [[MediaAPIClient alloc] initWithTVBoxSource:source];
        job.providers = @[@{@"id":@"", @"name":source[@"name"]?:@"TVBox 站点"}];
        [self searchNextProviderForJob:job];
        return;
    }

    id rawPort = source[@"port"];
    NSInteger port = [rawPort respondsToSelector:@selector(integerValue)] ? [rawPort integerValue] : 0;
    job.client = [[MediaAPIClient alloc] initWithPort:port requestTimeout:15];
    NSURL *healthURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/health", (long)port]];
    if (!healthURL || port < 1 || port > 65535) {
        [self finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:1 userInfo:@{NSLocalizedDescriptionKey:@"本机影视服务端口无效。"}]];
        return;
    }
    job.readiness = [[LocalServiceReadiness alloc] initWithURL:healthURL timeout:12 requiresHealthJSON:YES];
    __weak typeof(self) weakSelf = self;
    [job.readiness start:^(NSError *error, NSTimeInterval elapsed) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) { [owner finishJob:job error:error]; return; }
        [owner loadCapabilitiesForJob:job];
    }];
}

- (BOOL)isCurrentJob:(MediaGlobalSearchJob *)job {
    return job && job.generation == self.generation && self.jobs[@(job.section)] == job;
}

- (void)loadCapabilitiesForJob:(MediaGlobalSearchJob *)job {
    __weak typeof(self) weakSelf = self;
    [job.client call:@"capabilities" arguments:@{} completion:^(id result, NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) { [owner finishJob:job error:error]; return; }
        NSDictionary *capabilityPayload = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSArray *capabilities = [capabilityPayload[@"capabilities"] isKindOfClass:NSArray.class] ? capabilityPayload[@"capabilities"] : @[];
        if (![capabilities containsObject:@"search"]) {
            [owner finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:2 userInfo:@{NSLocalizedDescriptionKey:@"此资源未声明影视搜索能力。"}]];
            return;
        }
        if (![capabilities containsObject:@"providers"]) {
            job.providers = @[@{@"id":@"", @"name":job.source[@"name"]?:@"默认站点"}];
            [owner searchNextProviderForJob:job];
            return;
        }
        [job.client call:@"providers" arguments:@{} completion:^(id providers, NSError *providerError) {
            MediaGlobalSearchViewController *page = weakSelf;
            if (!page || ![page isCurrentJob:job]) return;
            if (providerError) { [page finishJob:job error:providerError]; return; }
            NSMutableArray *valid = [NSMutableArray array];
            if ([providers isKindOfClass:NSArray.class]) for (id candidate in providers) {
                if (![candidate isKindOfClass:NSDictionary.class]) continue;
                NSString *identifier = [candidate[@"id"] isKindOfClass:NSString.class] ? candidate[@"id"] : @"";
                NSString *name = [candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : identifier;
                if (name.length) [valid addObject:@{@"id":identifier, @"name":name}];
            }
            if (!valid.count) { [page finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源没有可搜索的影视站点。"}]]; return; }
            NSArray *retryTargets=[page.rows[job.section][@"retryProviders"] isKindOfClass:NSArray.class]?page.rows[job.section][@"retryProviders"]:@[];
            if(retryTargets.count){NSMutableArray *retry=[NSMutableArray array];for(NSDictionary *target in retryTargets)for(NSDictionary *candidate in valid)if([candidate[@"id"] isEqual:target[@"id"]]){[retry addObject:candidate];break;}job.providers=retry.count?retry:valid;}else job.providers=valid;
            job.failedProviders=@[];page.rows[job.section][@"retryProviders"]=@[];
            [page searchNextProviderForJob:job];
        }];
    }];
}

- (void)searchNextProviderForJob:(MediaGlobalSearchJob *)job {
    if (![self isCurrentJob:job]) return;
    if (self.resultCount >= MediaGlobalSearchMaximumResults) { [self stopAtResultLimit]; return; }
    if (job.providerIndex >= job.providers.count) {
        NSError *providerError = (!job.successfulProviderCount&&job.failedProviders.count) ? [NSError errorWithDomain:@"CCTVHostSearch" code:4 userInfo:@{NSLocalizedDescriptionKey:job.providerFailure.length?job.providerFailure:@"所有影视站点都搜索失败。"}] : nil;
        [self finishJob:job error:providerError];
        return;
    }
    NSDictionary *provider = job.providers[job.providerIndex++];
    NSString *providerID = [provider[@"id"] isKindOfClass:NSString.class] ? provider[@"id"] : @"";
    NSString *providerName = [provider[@"name"] isKindOfClass:NSString.class] ? provider[@"name"] : @"影视站点";
    self.rows[job.section][@"provider"] = providerName;
    [self reloadSection:job.section];
    NSMutableDictionary *arguments = [@{@"keyword":self.keyword?:@"", @"page":@1} mutableCopy];
    if (providerID.length) arguments[@"provider"] = providerID;
    __weak typeof(self) weakSelf = self;
    [job.client call:@"search" arguments:arguments completion:^(id result, NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) {
            NSString *message = error.localizedDescription.length ? error.localizedDescription : @"影视搜索失败。";
            NSMutableDictionary *row = owner.rows[job.section];
            NSDictionary *failedProvider=@{@"id":providerID,@"name":providerName};NSMutableArray *failed=[job.failedProviders mutableCopy]?:[NSMutableArray array];[failed addObject:failedProvider];job.failedProviders=failed;
            NSMutableArray *rowFailures=[row[@"failedProviders"] mutableCopy]?:[NSMutableArray array];[rowFailures addObject:failedProvider];row[@"failedProviders"]=rowFailures;
            row[@"providerError"] = [NSString stringWithFormat:@"%@：%@", providerName, message];
            if (!job.providerFailure.length) job.providerFailure = row[@"providerError"];
            [owner reloadSection:job.section];
            [owner searchNextProviderForJob:job];
            return;
        }
        job.successfulProviderCount++;
        NSDictionary *searchPayload = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSArray *items = [searchPayload[@"items"] isKindOfClass:NSArray.class] ? searchPayload[@"items"] : @[];
        NSMutableArray *stored = owner.rows[job.section][@"results"];
        NSMutableSet *existing = [NSMutableSet set];
        for (NSDictionary *entry in stored) {
            id identifier = entry[@"item"][@"id"];
            if (identifier) [existing addObject:[NSString stringWithFormat:@"%@|%@", providerID, identifier]];
        }
        for (id candidate in items) {
            if (owner.resultCount >= MediaGlobalSearchMaximumResults) break;
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *item = candidate;
            NSString *name = [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : @"";
            if (!name.length) continue;
            id identifier = item[@"id"] ?: name;
            NSString *dedupeKey = [NSString stringWithFormat:@"%@|%@", providerID, identifier];
            if ([existing containsObject:dedupeKey]) continue;
            [existing addObject:dedupeKey];
            [stored addObject:@{@"item":item, @"provider":providerID, @"providerName":providerName}];
            owner.resultCount++;
        }
        [owner reloadSection:job.section];
        [owner updateProgress];
        if (owner.resultCount >= MediaGlobalSearchMaximumResults) { [owner stopAtResultLimit]; return; }
        [owner searchNextProviderForJob:job];
    }];
}

- (void)finishJob:(MediaGlobalSearchJob *)job error:(NSError *)error {
    if (![self isCurrentJob:job]) return;
    BOOL partial=job.successfulProviderCount>0&&job.failedProviders.count>0;
    [MediaSourceHealthStore.shared recordSourceID:job.source[@"id"]?:@"" success:(error==nil||job.successfulProviderCount>0) elapsed:MAX(0,CACurrentMediaTime()-job.startedAt)];
    [job.readiness cancel];
    if (error) {
        self.rows[job.section][@"state"] = @"搜索失败";
        self.rows[job.section][@"error"] = error.localizedDescription ?: @"未知错误";
        self.rows[job.section][@"failedProviders"] = job.failedProviders ?: @[];
    } else if(partial) {
        self.rows[job.section][@"state"] = @"部分完成";
        NSMutableArray *names=[NSMutableArray array];for(NSDictionary *provider in [job.failedProviders subarrayWithRange:NSMakeRange(0,MIN(job.failedProviders.count,5))])if([provider[@"name"] length])[names addObject:provider[@"name"]];if(job.failedProviders.count>5)[names addObject:@"…"];
        self.rows[job.section][@"error"] = [NSString stringWithFormat:@"%lu 个影视站点失败：%@ · 点按只重试失败站点",(unsigned long)job.failedProviders.count,[names componentsJoinedByString:@"、"]];
        self.rows[job.section][@"failedProviders"] = job.failedProviders;
    } else {
        self.rows[job.section][@"state"] = @"搜索完成";
        self.rows[job.section][@"error"] = @"";
        self.rows[job.section][@"failedProviders"] = @[];
    }
    [self.jobs removeObjectForKey:@(job.section)];
    self.completedCount++;
    [self reloadSection:job.section];
    [self scheduleSources];
}

- (void)stopAtResultLimit {
    if (self.resultLimitReached) return;
    self.resultLimitReached = YES;
    self.searching = NO;
    self.generation++;
    for (MediaGlobalSearchJob *job in self.jobs.allValues) {
        [job.readiness cancel];
        [job.client cancel];
        if (job.section < self.rows.count) self.rows[job.section][@"state"] = @"已达结果上限";
    }
    [self.jobs removeAllObjects];
    for (NSNumber *number in self.pendingSections) self.rows[number.unsignedIntegerValue][@"state"] = @"未搜索 · 已达结果上限";
    [self.pendingSections removeAllObjects];
    self.navigationItem.rightBarButtonItem.title = @"重试失败";
    self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    self.progressLabel.text = [NSString stringWithFormat:@"结果达到 %lu 条上限 · 可滚动查看已找到的结果。", (unsigned long)MediaGlobalSearchMaximumResults];
    [self.tableView reloadData];
}

- (void)retryFailedSources {
    NSMutableArray<NSNumber *> *failed = [NSMutableArray array];
    for (NSUInteger section = 0; section < self.rows.count; section++) {
        NSDictionary *row = self.rows[section];
        if (![row[@"state"] isEqual:@"搜索失败"]&&![row[@"state"] isEqual:@"部分完成"]) continue;
        if ([self sourceAvailableForSearch:self.sources[section]]) [failed addObject:@(section)];
    }
    if (!failed.count) {
        self.progressLabel.text = @"没有可重试的失败来源。未运行的插件需要点按对应来源后单独启动。";
        return;
    }
    [self cancelJobsAndAdvanceGeneration];
    self.pendingSections = [failed mutableCopy];
    [self sortPendingSectionsByHealth];
    self.retrySections = [NSMutableSet setWithArray:failed];
    self.completedCount = 0;
    self.scheduledCount = failed.count;
    self.searching = YES;
    self.resultLimitReached = NO;
    for (NSNumber *number in failed) {
        NSMutableDictionary *row = self.rows[number.unsignedIntegerValue];
        row[@"state"] = @"等待重试";
        row[@"error"] = @"";
        row[@"providerError"] = @"";
        row[@"retryProviders"] = [row[@"failedProviders"] isKindOfClass:NSArray.class]?[row[@"failedProviders"] copy]:@[];
        row[@"failedProviders"] = @[];
    }
    self.navigationItem.rightBarButtonItem.title = @"停止";
    self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
    self.progressLabel.text = [NSString stringWithFormat:@"正在重试 %lu 个失败来源。", (unsigned long)failed.count];
    [self.tableView reloadData];
    [self scheduleSources];
}

- (void)startStoppedSourceAtSection:(NSUInteger)section {
    if (section >= self.sources.count) return;
    NSDictionary *source = self.sources[section];
    if (MediaSourceUsesNativeCatalogAPI(source)) return;
    if (!self.onActivateService) {
        self.rows[section][@"error"] = @"当前页面无法启动该插件，请到资源页单独启动。";
        [self reloadSection:section];
        return;
    }
    NSUInteger requestGeneration = self.generation;
    self.rows[section][@"state"] = @"正在请求启动此插件…";
    self.rows[section][@"error"] = @"";
    [self reloadSection:section];
    __weak typeof(self) weakSelf = self;
    self.onActivateService(source, ^(NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || owner.generation != requestGeneration || section >= owner.rows.count) return;
        if (error) {
            owner.rows[section][@"state"] = @"启动失败";
            owner.rows[section][@"error"] = error.localizedDescription ?: @"插件启动失败。";
            [owner reloadSection:section];
            return;
        }
        owner.rows[section][@"state"] = @"启动请求已接受 · 正在检查服务";
        [owner enqueueStartedSection:section];
    });
}

- (void)enqueueStartedSection:(NSUInteger)section {
    NSNumber *number = @(section);
    if (self.jobs[number] || [self.pendingSections containsObject:number]) return;
    if (!self.searching) {
        self.searching = YES;
        self.completedCount = 0;
        self.scheduledCount = 0;
        self.resultLimitReached = NO;
        self.navigationItem.rightBarButtonItem.title = @"停止";
        self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
    }
    self.scheduledCount++;
    [self.pendingSections addObject:number];
    self.rows[section][@"state"] = @"等待健康检查";
    self.rows[section][@"providerError"] = @"";
    self.searching = YES;
    [self updateProgress];
    [self reloadSection:section];
    [self scheduleSources];
}

- (void)updateProgress {
    NSUInteger denominator = self.scheduledCount;
    if (!denominator) {
        self.progressLabel.text = [NSString stringWithFormat:@"%lu 个影视来源 · 搜索中来源上限 %lu；不会自动启动其他插件。", (unsigned long)self.sources.count, (unsigned long)MediaGlobalSearchMaximumConcurrentSources];
        return;
    }
    NSUInteger active = self.jobs.count;
    NSUInteger queued = self.pendingSections.count;
    NSString *mode = self.retrySections.count ? @"重试失败来源 · " : @"";
    self.progressLabel.text = [NSString stringWithFormat:@"%@已完成 %lu / %lu 个资源 · 同时搜索 %lu 个 · 排队 %lu 个 · 找到 %lu 条", mode, (unsigned long)self.completedCount, (unsigned long)denominator, (unsigned long)active, (unsigned long)queued, (unsigned long)self.resultCount];
}

- (void)reloadSection:(NSUInteger)section {
    if (section >= self.rows.count || section >= [self numberOfSectionsInTableView:self.tableView]) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.sources.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section >= self.rows.count) return 1;
    return 1 + [self.rows[section][@"results"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section >= self.sources.count) return nil;
    return self.sources[section][@"name"] ?: @"影视来源";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *statusReuse = @"media-search-status";
    static NSString *resultReuse = @"media-search-result";
    BOOL statusRow = indexPath.row == 0;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:statusRow ? statusReuse : resultReuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:statusRow ? statusReuse : resultReuse];
    cell.backgroundColor = HostCard();
    cell.textLabel.textColor = HostText();
    cell.detailTextLabel.textColor = HostSecondaryText();
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    NSDictionary *source = indexPath.section < self.sources.count ? self.sources[indexPath.section] : @{};
    NSDictionary *row = indexPath.section < self.rows.count ? self.rows[indexPath.section] : @{};
    if (statusRow) {
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.text = row[@"state"] ?: @"待搜索";
        NSString *error = [row[@"error"] isKindOfClass:NSString.class] ? row[@"error"] : @"";
        NSString *providerError = [row[@"providerError"] isKindOfClass:NSString.class] ? row[@"providerError"] : @"";
        cell.detailTextLabel.text = error.length&&providerError.length?[NSString stringWithFormat:@"%@\n最近失败：%@",error,providerError]:(error.length?error:(providerError.length?providerError:([row[@"provider"] length]?[NSString stringWithFormat:@"当前站点：%@",row[@"provider"]]:@"")));
        BOOL stopped = [[row[@"state"] description] containsString:@"未运行"];
        BOOL failed = [row[@"state"] isEqual:@"搜索失败"] || [row[@"state"] isEqual:@"部分完成"] || [row[@"state"] isEqual:@"启动失败"];
        cell.accessoryType = (stopped || failed) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = (stopped || failed) ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessibilityHint = stopped ? @"点按后只启动此插件，然后检查健康状态和影视接口" : (failed ? ([row[@"state"] isEqual:@"部分完成"]?@"点按只重试失败站点":@"点按重试此来源") : nil);
    } else {
        NSDictionary *entry = row[@"results"][indexPath.row - 1];
        NSDictionary *item = entry[@"item"];
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.textLabel.text = item[@"name"] ?: @"未命名影片";
        NSMutableArray *parts = [NSMutableArray array];
        if ([entry[@"providerName"] length]) [parts addObject:entry[@"providerName"]];
        if ([item[@"remarks"] length]) [parts addObject:item[@"remarks"]];
        if ([item[@"year"] length]) [parts addObject:item[@"year"]];
        cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", item[@"name"] ?: @"影片", entry[@"providerName"] ?: @"影视来源"];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section >= self.sources.count || indexPath.section >= self.rows.count) return;
    if (indexPath.row == 0) {
        NSDictionary *row = self.rows[indexPath.section];
        if ([[row[@"state"] description] containsString:@"未运行"]) { [self startStoppedSourceAtSection:indexPath.section]; return; }
        if ([row[@"state"] isEqual:@"搜索失败"] || [row[@"state"] isEqual:@"部分完成"] || [row[@"state"] isEqual:@"启动失败"]) {
            if (self.searching) { self.progressLabel.text = @"其他来源仍在搜索；当前失败来源可在本轮结束后重试。"; return; }
            if ([self sourceAvailableForSearch:self.sources[indexPath.section]]) {
                self.pendingSections = [NSMutableArray arrayWithObject:@(indexPath.section)];
                self.scheduledCount = 1; self.completedCount = 0; self.searching = YES;
                self.retrySections = [NSMutableSet setWithObject:@(indexPath.section)];
                self.rows[indexPath.section][@"state"] = @"等待重试"; self.rows[indexPath.section][@"error"] = @""; self.rows[indexPath.section][@"providerError"] = @"";self.rows[indexPath.section][@"retryProviders"]=[self.rows[indexPath.section][@"failedProviders"] isKindOfClass:NSArray.class]?[self.rows[indexPath.section][@"failedProviders"] copy]:@[];self.rows[indexPath.section][@"failedProviders"]=@[];
                self.navigationItem.rightBarButtonItem.title = @"停止"; self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
                [self scheduleSources];
            } else [self startStoppedSourceAtSection:indexPath.section];
        }
        return;
    }
    NSDictionary *entry = self.rows[indexPath.section][@"results"][indexPath.row - 1];
    if (self.onSelectResult) self.onSelectResult(entry[@"item"] ?: @{}, self.sources[indexPath.section], entry[@"provider"] ?: @"");
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [self submitSearch]; }
- (void)dealloc { [self cancelJobsAndAdvanceGeneration]; }
@end
