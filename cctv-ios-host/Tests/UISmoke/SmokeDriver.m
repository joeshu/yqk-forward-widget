#import "AppDelegate.h"
#import "CNPlayerSDK.h"
#import "EPGViewController.h"
#import "PlaybackStartupTrace.h"
#import "NativeChannelPreloader.h"
#import "PyHost.h"
#import "RootViewController.h"
#import "ConfigCenterViewController.h"
#import "ServiceEditorViewController.h"
#import "ServiceStore.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"
#import "ServicesViewController.h"
#import "HostImageLoader.h"
#import "NodePluginRuntime.h"
#import "MediaBrowserViewController.h"
#import "MediaGlobalSearchViewController.h"
#import "MediaAPIClient.h"
#import "MediaSearchResults.h"
#import "LocalServiceReadiness.h"
#import "RuntimeDiagnostics.h"
#import "MediaPlaybackViewController.h"
#import "MediaWebViewController.h"
#import <WebKit/WebKit.h>
#import "MediaEpisodeSelectionViewController.h"
#import "TVBoxCatalogStore.h"
#import "TVBoxCatalogViewController.h"
#import "CNPlayerCrashGuard.h"
#import "ResourceImportSheetViewController.h"
#import "LogCenterViewController.h"
#import "PluginRunHistoryViewController.h"
#import "PluginLogStore.h"
#import "HostLogRedactor.h"
#import "HostTheme.h"
#import "SettingsViewController.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

@interface RootViewController (Smoke)
- (void)selectBottomTab:(UIButton *)button;
- (void)openServicesPage;
- (void)openDiagnosticLogForIdentifier:(NSString *)identifier name:(NSString *)name;
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name;
- (void)applyFilter;
- (void)selectChannel:(NSDictionary *)channel;
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end;
- (void)returnToNativeLive;
- (void)fetchSubscription:(NSString *)url silent:(BOOL)silent;
- (void)beginPlaybackPriority;
- (void)togglePlayPause;
- (void)avItemStalled:(NSNotification *)notification;
- (void)playRemote:(NSDictionary *)channel;
- (void)tryAlternateSource;
- (void)stopPlayback;
- (void)updateSearchResultsForSearchController:(UISearchController *)controller;
- (void)playChannel:(NSDictionary *)channel route:(NSDictionary *)route;
- (void)importPlaylistData:(NSData *)data name:(NSString *)name;
- (void)previewChannel:(NSDictionary *)channel;
- (void)stopPreview;
- (NSDictionary *)channelWithID:(NSString *)identifier;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
- (void)player:(id)player playbackFailed:(NSError *)error;
- (void)playMediaResult:(NSDictionary *)result name:(NSString *)name;
- (void)addSubscription;
@end

@interface MediaGlobalSearchViewController (SmokeSearch)
- (void)updateFilters;
- (void)selectSearchFilter:(UIButton *)sender;
- (void)reloadSection:(NSUInteger)section;
- (BOOL)isCurrentJob:(id)job;
- (void)searchNextProviderForJob:(id)job;
@end
// Deliberately delivers even after cancellation: an already-enqueued completion
// must still be rejected by the controller generation/job guards.
@interface SmokeDelayedSearchClient : MediaAPIClient @end
@implementation SmokeDelayedSearchClient
- (void)call:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(id,NSError *))completion {
    NSString *keyword=[arguments[@"keyword"] copy];NSTimeInterval delay=[keyword isEqual:@"旧关键词"]?0.7:0.02;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{completion(@{@"items":@[@{@"id":keyword?:@"",@"name":keyword?:@""}]},nil);});
}
@end
@interface RuntimeDiagnostics (SmokeMarker)
- (NSDictionary *)readSessionMarker;
@end
@interface MediaBrowserViewController (SmokeRecovery)
- (void)restartCurrentService;
- (void)appendHomeModule:(NSString *)key signature:(id)signature build:(dispatch_block_t)build;
- (void)refreshHomeModules;
@end
@interface MediaPlaybackViewController (SmokeEpisodePicker)
- (void)openEpisodeSelection;
- (void)recordPlaybackAttemptOutcome:(NSString *)outcome failureKind:(NSString *)kind httpStatus:(NSInteger)status terminal:(BOOL)terminal;
@end
@interface MediaWebViewController (SmokeConfiguration)
- (void)close;
@end
@interface MediaBrowserViewController (Smoke)
- (void)loadMore;
- (void)chooseResource;
- (void)chooseProvider;
- (void)openSourceConfiguration;
- (void)updateSearchResultsForSearchController:(UISearchController *)controller;
@end
@interface EPGViewController (Smoke)
- (void)rebuildDates;
@end
@interface CNPlayer (SmokeMetrics)
+ (NSInteger)smokeResetCount;
+ (NSInteger)smokePlayCount;
+ (NSInteger)smokeConfigureCount;
@end
@interface PyHost (SmokeMetrics)
+ (NSInteger)smokeStartCount;
@end
static NSMutableArray *failures;
static NSDictionary *nodeCall(NSString *operation,NSDictionary *payload){
    NSString *input=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL] encoding:NSUTF8StringEncoding];NSError *error=nil;
    NSString *reply=[NodePluginRuntime.shared callOperation:operation json:input error:&error];
    return reply?[NSJSONSerialization JSONObjectWithData:[reply dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL]:@{@"ok":@NO,@"error":error.localizedDescription?:@"Node bridge failed"};
}
static NSString *outputDir;
static NSURL *pluginLogExportURL;
static void check(BOOL value, NSString *message) {
    if (!value)
        [failures addObject:message];
}
static void capture(UIWindow *window, NSString *name) {
    [window layoutIfNeeded];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
    UIImage *image = [r imageWithActions:^(UIGraphicsImageRendererContext *context) {
      [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    [UIImagePNGRepresentation(image)
        writeToFile:[outputDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]]
         atomically:YES];
}
static UIViewController *SmokePresentedController(NSArray<UIViewController *> *owners) {
    for (UIViewController *owner in owners) {
        UIViewController *presented=owner;
        while(presented.presentedViewController)presented=presented.presentedViewController;
        if(presented!=owner)return presented;
    }
    return nil;
}
static UINavigationController *SmokePresentedNavigation(NSArray<UIViewController *> *owners, NSString *context) {
    UIViewController *presented=SmokePresentedController(owners);
    if([presented isKindOfClass:UINavigationController.class])return (UINavigationController *)presented;
    if([presented isKindOfClass:UIAlertController.class]){
        UIAlertController *alert=(UIAlertController *)presented;
        check(NO,[NSString stringWithFormat:@"%@ expected a navigation sheet but found alert %@ · %@",context,alert.title?:@"(no title)",alert.message?:@""]);
        [alert dismissViewControllerAnimated:NO completion:nil];
    }else if(presented){
        check(NO,[NSString stringWithFormat:@"%@ expected a navigation sheet but found %@",context,NSStringFromClass(presented.class)]);
    }else{
        check(NO,[NSString stringWithFormat:@"%@ expected a presented navigation sheet but found none",context]);
    }
    return nil;
}
static NSUInteger waitingIndex=NSNotFound;
static NSDate *waitingDeadline;
static void next(NSArray *steps, NSUInteger index) {
    if (index >= steps.count) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{
            @"failures" : failures,
            @"passed" : @(failures.count == 0)
        }
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:NULL];
        [data writeToFile:[outputDir stringByAppendingPathComponent:@"results.json"] atomically:YES];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      @try {
          NSData *progress=[NSJSONSerialization dataWithJSONObject:@{@"step":@(index),@"total_steps":@(steps.count),@"failures":failures.copy?:@[]} options:NSJSONWritingPrettyPrinted error:NULL];
          [progress writeToFile:[outputDir stringByAppendingPathComponent:@"smoke-progress.json"] atomically:YES];
          id step=steps[index];
          if([step isKindOfClass:NSDictionary.class]){
              BOOL (^ready)(void)=step[@"until"];
              if(waitingIndex!=index){waitingIndex=index;waitingDeadline=[NSDate dateWithTimeIntervalSinceNow:[step[@"timeout"] doubleValue]?:12];}
              if(!ready()&&[waitingDeadline timeIntervalSinceNow]>0){next(steps,index);return;}
              ((dispatch_block_t)step[@"run"])();
          }else ((dispatch_block_t)step)();
      } @catch (NSException *e) {
          [failures addObject:e.reason ?: e.name];
      }
      next(steps, index + 1);
    });
}
@interface AppDelegate (SmokeDriver)
@end
@implementation AppDelegate (SmokeDriver)
+ (void)load {
    method_exchangeImplementations(
        class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:)),
        class_getInstanceMethod(self, @selector(smokeApplication:didFinishLaunchingWithOptions:)));
}
- (BOOL)smokeApplication:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"preloadNativeChannel"];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"resumeLastChannel"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.lastBottomTab.v1"];
    [NSUserDefaults.standardUserDefaults setObject:@[@"recommendations",@"catalog",@"continue",@"favorites",@"sources"] forKey:@"cctv.mediaHome.modules.v1"];
    [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"cctv.mediaHome.modules.schemaVersion"];
    [RuntimeDiagnostics.shared setEnabled:YES];
    BOOL ok = [self smokeApplication:app didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [UIView setAnimationsEnabled:NO];
      failures = [NSMutableArray array];
      check([CNPlayerCrashGuard install], @"CNPlayer thumbnail exception guard installs");
      UIImage *guardedThumbnail=[[NSClassFromString(@"IJKFFMoviePlayerController") new]
          performSelector:NSSelectorFromString(@"thumbnailImageAtCurrentTime")];
      check(guardedThumbnail==nil, @"invalid SDK teardown thumbnail exception is contained");
      outputDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ui-smoke"];
      [NSFileManager.defaultManager createDirectoryAtPath:outputDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
      UINavigationController *nav = (id)self.window.rootViewController;
      RootViewController *root = (id)nav.viewControllers.firstObject;
      UIStackView *tabs = [root valueForKey:@"bottomBar"];
      __block id retainedWrapper = nil;
      __block id oldWrapper = nil;
      __block NSInteger playCount = 0;
      __block AVPlayer *hlsPlayer;
      __block NSInteger configuredBeforeHandoff;
      __block id preparedWrapper;
      __block NativeChannelPreloader *nativePreloader;
      __block UIImageView *logoA, *logoB, *staleLogo, *oversizeLogo;
      __block NSDictionary *imageStats;
      __block NSDictionary *nodeChecks;
      __block MediaBrowserViewController *mediaPage;
      __block MediaGlobalSearchViewController *searchPage;
      __block CGPoint searchReturnOffset;
      __block id staleSearchJob;
      __block NSString *selectedSearchID;
      __block NSDate *staleSearchDeadline;
      __block UIViewController *mediaDetail;
      __block UIViewController *navigationProbe;
      __block MediaEpisodeSelectionViewController *mediaEpisodes;
      __block MediaPlaybackViewController *mediaPlayback;
      __block NSDate *stalePlaybackDeadline;
      NSArray *steps = @[
          ^{
            UICollectionView *grid = [root valueForKey:@"channelGrid"];
            check([grid numberOfItemsInSection:0] > 20, @"home catalog populated");
            check(!grid.hidden, @"grid visible by default");
            capture(self.window, @"01-live-grid");
            check(root.navigationItem.rightBarButtonItems.count==1, @"catalog uses one compact toolbar");
            UIStackView *toolbar=(id)root.navigationItem.rightBarButtonItems.firstObject.customView;
            check(toolbar.arrangedSubviews.count==3,@"catalog exposes three page actions");

            check(tabs.arrangedSubviews.count==5, @"five navigation pages");
            NSString *source=@"https://example.com/smoke.m3u";
            NSDictionary *remote=@{@"id":@"remote-smoke",@"name":@"CCTV-1 M3U8",@"group":@"央视",@"remoteURL":@"https://example.com/live.m3u8",@"subscriptionSources":@[source]};
            NSArray *original=[root valueForKey:@"allChannels"];
            [root setValue:[original arrayByAddingObject:remote] forKey:@"allChannels"];
            [root applyFilter];
            for(NSDictionary *c in [root valueForKey:@"shownChannels"])
                check(![c[@"remoteURL"] length], @"CCTV page excludes subscription channels even with CCTV names");
            [root selectBottomTab:(id)tabs.arrangedSubviews[1]];
            NSArray *subscriptionRows=[root valueForKey:@"shownChannels"];
            check(subscriptionRows.count==1&&[subscriptionRows.firstObject[@"id"] isEqualToString:@"remote-smoke"], @"channel page contains only subscription entries");
            check([root.title isEqualToString:@"频道"], @"subscription page has its own navigation title");
            capture(self.window, @"01b-subscription-channels");
            [root setValue:original forKey:@"allChannels"];
            [root applyFilter];
            check([[root valueForKey:@"shownChannels"] count]==0, @"empty subscriptions never fall back to native SDK channels");
            [root selectBottomTab:(id)tabs.arrangedSubviews[0]];

          },
          ^{
            [root setValue:[NSMutableArray arrayWithObject:@"cctv1"] forKey:@"favorites"];
            [root setValue:@YES forKey:@"favoritesOnly"];
            [root applyFilter];
          },
          ^{
            NSArray *shown = [root valueForKey:@"shownChannels"];
            check(shown.count == 1, @"favorite filter returns only saved channel");
            capture(self.window, @"02-favorites");
            [root selectBottomTab:(id)tabs.arrangedSubviews[2]];
            [root.view layoutIfNeeded];
            MediaBrowserViewController *mediaHome=(id)[root valueForKey:@"tabPage"];
            check([mediaHome isKindOfClass:MediaBrowserViewController.class]&&mediaHome.isHomeMode&&root.title.length==0, @"media tab opens the compact untitled home");
            check(mediaHome!=nil, @"media page embedded");
            check(nav.delegate==root&&nav.navigationBarHidden,@"navigation bar is hidden only while the home tab is visible");
            [mediaHome.view layoutIfNeeded];UIStackView *homeSelectors=[mediaHome valueForKey:@"selectionRow"];UIButton *homeSource=(id)[mediaHome valueForKey:@"sourceSelectButton"];UIButton *homeProvider=(id)[mediaHome valueForKey:@"providerSelectButton"];UIButton *homeMenu=(id)[mediaHome valueForKey:@"homeMenuButton"];UIButton *homeMode=(id)[mediaHome valueForKey:@"homeModeButton"];UIButton *homeSearch=(id)[mediaHome valueForKey:@"homeSearchButton"];UIScrollView *homeScroll=(id)[mediaHome valueForKey:@"homeScroll"];CGFloat safeTop=mediaHome.view.safeAreaInsets.top+4;CGRect searchInRoot=[mediaHome.view convertRect:homeSearch.frame toView:root.view];check(fabs(CGRectGetMinY(homeSelectors.frame)-safeTop)<1.5&&fabs(CGRectGetMinX(homeSelectors.frame)-14)<1.5&&fabs(CGRectGetMaxX(homeSelectors.frame)-(CGRectGetWidth(mediaHome.view.bounds)-14))<1.5&&fabs(homeSelectors.spacing-10)<0.1,@"home selectors align 4 pt below the safe area with 14 pt side margins and 10 pt spacing");BOOL selectorsAccessible=homeSource.isAccessibilityElement&&homeProvider.isAccessibilityElement;BOOL menuAccessible=[homeMenu.accessibilityLabel isEqual:@"更多影视操作"]&&homeMenu.menu.children.count==9;check(selectorsAccessible&&menuAccessible,[NSString stringWithFormat:@"home exposes accessible selectors and the complete floating menu (source=%d site=%d label=%@ actions=%lu)",homeSource.isAccessibilityElement,homeProvider.isAccessibilityElement,homeMenu.accessibilityLabel?:@"",(unsigned long)homeMenu.menu.children.count]);check(fabs(CGRectGetMinY(homeMode.frame)-CGRectGetMaxY(homeMenu.frame)-12)<1.5&&fabs(CGRectGetMinY(homeSearch.frame)-CGRectGetMaxY(homeMode.frame)-12)<1.5&&CGRectGetMaxY(searchInRoot)<=CGRectGetMinY(tabs.frame)-12,@"floating actions stack menu/library/search 12 pt apart above the bottom navigation");check(homeSource.titleLabel.lineBreakMode==NSLineBreakByTruncatingTail&&homeScroll.contentInset.bottom>=184,@"top names truncate visually, remain accessible, and home scroll reserves the floating-control area");
            UIButton *modeButton=[mediaHome valueForKey:@"homeModeButton"];[modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(!mediaHome.isHomeMode&&!nav.navigationBarHidden&&homeMenu.hidden&&homeSearch.hidden,@"opening the media library restores navigation and hides home-only floating actions");[modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaHome.isHomeMode&&nav.navigationBarHidden&&!homeMenu.hidden&&!homeSearch.hidden,@"returning from the library hides navigation and restores home floating actions");
            navigationProbe=[UIViewController new];navigationProbe.title=@"交互返回取消测试";[nav pushViewController:navigationProbe animated:NO];
          },
          @{ @"timeout":@8, @"until":^BOOL{return nav.topViewController==navigationProbe&&!nav.navigationBarHidden;}, @"run":^{check(nav.topViewController==navigationProbe&&!nav.navigationBarHidden,@"pushing a detail page restores the navigation bar");[(id)root navigationController:nav didShowViewController:navigationProbe animated:YES];check(!nav.navigationBarHidden,@"a cancelled interactive return keeps the visible detail navigation bar restored");[nav popViewControllerAnimated:NO];} },
          @{ @"timeout":@8, @"until":^BOOL{return nav.topViewController==root&&nav.navigationBarHidden;}, @"run":^{check(nav.topViewController==root&&nav.navigationBarHidden,@"a completed return to the media home hides the navigation bar");check([[root valueForKey:@"channelGrid"] isHidden], @"media page hides live channel grid");capture(self.window, @"02-media");[root selectBottomTab:(id)tabs.arrangedSubviews[3]];UIButton *resourceActions=[root valueForKey:@"resourceActionsButton"];ConfigCenterViewController *resourcePage=(id)[root valueForKey:@"tabPage"];UIStackView *toolbar=[resourcePage valueForKey:@"topActionsStack"];UIButton *more=toolbar.arrangedSubviews.lastObject;UILabel *title=[resourcePage valueForKey:@"resourceTitleLabel"];UITextField *search=[resourcePage valueForKey:@"resourceSearchField"];check(nav.navigationBarHidden,@"resource tab keeps the title/navigation region hidden");check(root.title.length==0,@"resource tab has no large title");check(resourcePage.view.frame.origin.y==0,@"resource page keeps a stable full-root origin while navigation visibility changes");check(fabs(CGRectGetMinY(toolbar.frame)-resourcePage.view.safeAreaInsets.top-8)<1.5,@"resource toolbar remains 8 pt below the safe area after returning from a child page");check(resourceActions.hidden&&toolbar.arrangedSubviews.count==4&&more.menu.children.count==2,@"resource page exposes the four-button top toolbar and services menu");check([title.text isEqual:@"资源"]&&[search.placeholder isEqual:@"搜索资源"],@"resource page shows its title and inline search field");check(resourcePage.navigationItem.searchController==nil,@"resource page uses inline search rather than a navigation search controller");} },
          ^{
            check([[root valueForKey:@"tabPage"]
                      isKindOfClass:NSClassFromString(@"ConfigCenterViewController")],
                  @"configuration tab embedded");
            UIStackView *resourceFilters=[[root valueForKey:@"tabPage"] valueForKey:@"kindStack"];
            check(resourceFilters.arrangedSubviews.count==6, @"resources page exposes counted filters for all, VOD, live, catalogs, scripts and attention");
            capture(self.window, @"03-configuration");
            [root addSubscription];
          },
          ^{
            ResourceImportSheetViewController *sheet=(id)nav.presentedViewController;
            check([sheet isKindOfClass:ResourceImportSheetViewController.class], @"resource add opens the grouped import sheet");
            UITableView *options=[sheet valueForKey:@"tableView"];
            check([options numberOfSections]==3 && [options numberOfRowsInSection:0]==4 && [options numberOfRowsInSection:1]==3,
                  @"resource sheet exposes supported online, local and service actions");
            capture(self.window, @"03b-add-resource");
            [sheet dismissViewControllerAnimated:NO completion:nil];
            [root openServicesPage];
          },
          ^{
            check([nav.topViewController isKindOfClass:ServicesViewController.class],
                  @"service directory opened");
            capture(self.window, @"04-services");
            ServicesViewController *v = (id)nav.topViewController;
            UITableView *table = [v valueForKey:@"table"];
            [v.view layoutIfNeeded];
            check(table.contentInsetAdjustmentBehavior==UIScrollViewContentInsetAdjustmentNever&&UIEdgeInsetsEqualToEdgeInsets(table.adjustedContentInset,table.contentInset),@"service directory applies scroll insets only once");
            check(fabs(CGRectGetMinY(table.frame)-CGRectGetMinY(v.view.safeAreaLayoutGuide.layoutFrame))<1.5&&fabs(CGRectGetMaxY(table.frame)-CGRectGetMaxY(v.view.safeAreaLayoutGuide.layoutFrame))<1.5,@"service list fills the safe area without a top or bottom blank band");
            NSIndexPath *firstService = nil;
            for (NSInteger section = 0; section < table.numberOfSections && !firstService; section++)
                if ([table numberOfRowsInSection:section] > 0)
                    firstService = [NSIndexPath indexPathForRow:0 inSection:section];
            check(firstService != nil, @"service directory contains a selectable service row");
            if (firstService)
                [table.delegate tableView:table didSelectRowAtIndexPath:firstService];
          },
          ^{
            check([NSStringFromClass(nav.topViewController.class)
                      isEqualToString:@"ServiceDetailViewController"],
                  @"service detail opened");
            capture(self.window, @"05-service-detail");
            ServiceEditorViewController *edit = [ServiceEditorViewController new];
            UITraitCollection *largeType=[UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge];
            [nav pushViewController:edit animated:NO];
            [nav setOverrideTraitCollection:largeType forChildViewController:edit];
            [edit.view setNeedsLayout];
          },
          ^{
            ServiceEditorViewController *edit = (id)nav.topViewController;
            [edit.tableView layoutIfNeeded];
            NSDictionary *fieldRows=@{@"nameField":[NSIndexPath indexPathForRow:0 inSection:0],
                                      @"portField":[NSIndexPath indexPathForRow:1 inSection:0],
                                      @"urlField":[NSIndexPath indexPathForRow:1 inSection:1],
                                      @"argsField":[NSIndexPath indexPathForRow:1 inSection:2],
                                      @"playlistPathField":[NSIndexPath indexPathForRow:2 inSection:2]};
            for(NSString *key in fieldRows){
                NSIndexPath *path=fieldRows[key];
                [edit.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                [edit.tableView layoutIfNeeded];
                UITableViewCell *cell=[edit.tableView cellForRowAtIndexPath:path];
                UITextField *field=[edit valueForKey:key];
                if(!cell){check(NO,[NSString stringWithFormat:@"%@ editor row is available at large text size",key]);continue;}
                CGRect fieldFrame=[field convertRect:field.bounds toView:cell.contentView];
                check(CGRectGetMinX(fieldFrame)>=-1&&CGRectGetMaxX(fieldFrame)<=CGRectGetWidth(cell.contentView.bounds)+1,
                      [NSString stringWithFormat:@"%@ stays inside its large-type editor row",key]);
                UIStackView *stack=nil;for(UIView *subview in cell.contentView.subviews)if([subview isKindOfClass:UIStackView.class]){stack=(id)subview;break;}
                if(stack.arrangedSubviews.count>1){UILabel *label=(id)stack.arrangedSubviews.firstObject;CGRect labelFrame=[label convertRect:label.bounds toView:cell.contentView];check(CGRectGetMaxY(labelFrame)<=CGRectGetMinY(fieldFrame)+1,[NSString stringWithFormat:@"%@ label does not overlap its input at large text size",key]);}
            }
            [edit.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
            [edit.tableView layoutIfNeeded];capture(self.window, @"06-service-editor-large-type");
            [(UITextField *)[edit valueForKey:@"nameField"] setText:@"UI Smoke Service"];
            [edit setValue:@"print('service smoke test')\n" forKey:@"code"];
            [edit performSelector:NSSelectorFromString(@"save")];
          },
          ^{
            BOOL saved = NO;
            for (NSDictionary *s in [ServiceStore services])
                if ([s[@"name"] isEqualToString:@"UI Smoke Service"])
                    saved = YES;
            check(saved, @"custom service editor saves code and metadata");
            [nav popToRootViewControllerAnimated:NO];
            [root selectBottomTab:(id)tabs.arrangedSubviews[4]];
          },
          ^{
            capture(self.window, @"07-settings");
            [root selectBottomTab:(id)tabs.arrangedSubviews[0]];
            [root setValue:@NO forKey:@"gridMode"];
            [root.view setNeedsLayout];
          },
          ^{
            UITableView *table = [root valueForKey:@"table"];
            check(!table.hidden, @"list mode visible");
            capture(self.window, @"08-live-list");
            EPGViewController *epg = [[EPGViewController alloc] initWithChannelID:@"cctv1"
                                                                             name:@"CCTV-1 综合"];
            [nav pushViewController:epg animated:NO];
          },
          ^{
            EPGViewController *epg = (id)nav.topViewController;
            [[epg valueForKey:@"task"] cancel];
            NSTimeInterval t = NSDate.date.timeIntervalSince1970;
            [epg setValue:@[
                @{@"start" : @(t - 900),
                  @"end" : @(t + 900),
                  @"title" : @"当前节目 · UI 测试数据"},
                @{@"start" : @(t + 900),
                  @"end" : @(t + 2700),
                  @"title" : @"接下来 · UI 测试数据"}
            ]
                   forKey:@"allRows"];
            [epg rebuildDates];
          },
          ^{
            capture(self.window, @"09-epg-fixture");
            [nav popToRootViewControllerAnimated:NO];
            NSString *redacted=[HostLogRedactor redactText:@"GET https://example.test/live.m3u8?access_token=abc123&channel=1\nAuthorization: Bearer header-secret\nCookie: sid=cookie-secret"];
            check(![redacted containsString:@"abc123"] && ![redacted containsString:@"header-secret"] && ![redacted containsString:@"cookie-secret"], @"diagnostic logs redact URL credentials, authorization and cookies");
            [PluginLogStore.shared beginRunForIdentifier:@"ui-smoke-plugin"];
            [root logPluginLine:@"第一次运行日志" identifier:@"ui-smoke-plugin" name:@"UI Smoke Plugin"];
            [PluginLogStore.shared finishRunForIdentifier:@"ui-smoke-plugin" status:@"已停止"];
            [PluginLogStore.shared beginRunForIdentifier:@"ui-smoke-plugin"];
            [root logPluginLine:@"第二次独立运行日志 access_token=plugin-secret" identifier:@"ui-smoke-plugin" name:@"UI Smoke Plugin"];
            [PluginLogStore.shared finishRunForIdentifier:@"ui-smoke-plugin" status:@"已停止"];
            [root openDiagnosticLogForIdentifier:@"ui-smoke-plugin" name:@"UI Smoke Plugin"];
            [PluginLogStore.shared prepareExportForIdentifier:@"ui-smoke-plugin" displayName:@"UI Smoke Plugin" completion:^(NSURL *url,NSError *error){pluginLogExportURL=url;}];
          },
          ^{
            PluginRunHistoryViewController *history=(id)nav.topViewController;
            check([history isKindOfClass:PluginRunHistoryViewController.class], @"service logs first show independent run records");
            NSArray *runs=history.runRecordsProvider();
            check(runs.count==2, @"two service starts appear as two separate log entries");
            [history tableView:history.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            LogCenterViewController *logs=(id)nav.topViewController;
            check([logs isKindOfClass:LogCenterViewController.class], @"selecting a run opens its own searchable log page");
            [logs loadViewIfNeeded];
            check([logs.logSnapshotProvider() containsString:@"第二次独立运行日志"] && ![logs.logSnapshotProvider() containsString:@"第一次运行日志"], @"a run log contains only the selected invocation");
            check(![logs.logSnapshotProvider() containsString:@"plugin-secret"], @"plugin log view redacts sensitive values before display");
            check(logs.onExportLog!=nil && logs.onClearLog!=nil, @"plugin log page exposes independent export and clear actions");
            check([[logs valueForKey:@"categories"] numberOfSegments]==4, @"log center supports all, playback, plugin and error filters");
            NSString *pluginExport=pluginLogExportURL?[NSString stringWithContentsOfURL:pluginLogExportURL encoding:NSUTF8StringEncoding error:NULL]:nil;
            check(pluginLogExportURL && [[NSFileManager defaultManager] fileExistsAtPath:pluginLogExportURL.path] && ![pluginExport containsString:@"plugin-secret"], @"per-plugin log export creates a separate redacted text file");
            capture(self.window, @"10-diagnostic-log");
            [nav popToRootViewControllerAnimated:NO];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"legacyNativePlayback"];
            [root selectChannel:[root channelWithID:@"cctv1"]];
          },
          ^{
            check([[root valueForKey:@"firstRender"] boolValue], @"legacy native first frame received");
            check([[root valueForKey:@"activeTab"] integerValue]==0, @"native playback opens CCTV page");
            check([root.title isEqual:@"CCTV-1 综合"], @"expanded live player promotes the playing channel into the navigation title");
            UIStackView *liveActions=(id)root.navigationItem.rightBarButtonItems.firstObject.customView;
            check(liveActions.arrangedSubviews.count==3, @"expanded live player exposes favorite, route and playback info actions");
            retainedWrapper = [root valueForKey:@"currentPlayer"];
            playCount = [CNPlayer smokePlayCount];
            [root selectChannel:[root channelWithID:@"cctv1"]];
          },
          ^{
            check([CNPlayer smokePlayCount]==playCount && [root valueForKey:@"currentPlayer"]==retainedWrapper,
                  @"same-channel tap preserves active session");
            [root player:retainedWrapper playbackFailed:[NSError errorWithDomain:@"fixture" code:4012 userInfo:nil]];
            check([[[root valueForKey:@"playPauseBtn"] titleForState:UIControlStateNormal] isEqual:@"重试"],
                  @"terminal playback error exposes an explicit retry action");
            [root togglePlayPause];
          },
          ^{
            check([CNPlayer smokePlayCount]==playCount+1,@"failed channel can be selected again");
            playCount=[CNPlayer smokePlayCount];
            [root playChannel:[root channelWithID:@"cctv2"] route:nil];
            check([root valueForKey:@"currentPlayer"] == retainedWrapper,
                  @"0.12 compatible mode reuses wrapper");
            check([CNPlayer smokeResetCount] > 0, @"legacy reset retained");
          },
          ^{
            check([CNPlayer smokePlayCount] == playCount + 1,
                  @"PrepareDone cannot play again after auto first frame");
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"legacyNativePlayback"];
            oldWrapper = [root valueForKey:@"currentPlayer"];
            [root playChannel:[root channelWithID:@"cctv3"] route:nil];
            check([root valueForKey:@"currentPlayer"] != oldWrapper, @"fresh mode uses a distinct wrapper");
            [root player:oldWrapper statEvent:3 value:nil];
            check(![[root valueForKey:@"firstRender"] boolValue],
                  @"stale old player cannot set new first frame");
          },
          ^{
            check([[root valueForKey:@"firstRender"] boolValue], @"fresh-mode first frame received");
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"legacyNativePlayback"];
            NSArray *arguments = NSProcessInfo.processInfo.arguments;
            NSUInteger at = [arguments indexOfObject:@"--smoke-port"];
            NSString *port = at != NSNotFound && at + 1 < arguments.count ? arguments[at + 1] : @"0";
            [ServiceStore save:@{
                @"id" : @"builtin-ysp",
                @"name" : @"YSP Live",
                @"builtin" : @YES,
                @"port" : @([port integerValue])
            }];
            NSString *url = [NSString stringWithFormat:@"http://127.0.0.1:%@/video.mp4", port];
            [root playRemote:@{@"id" : url, @"name" : @"Local startup test", @"remoteURL" : url}];
            check([PyHost smokeStartCount] == 1, @"resume starts built-in service exactly once");
            check([[root valueForKey:@"activeTab"] integerValue]==1, @"remote playback opens subscription page");
            check([root valueForKey:@"avPlayer"] == nil, @"AVPlayer waits until HTTP health is ready");
          },
          @{@"until":^BOOL{PlaybackStartupTrace *t=[root valueForKey:@"startupTrace"];return t.stages[@"service"]!=nil&&[root valueForKey:@"avPlayer"]!=nil;},@"run":^{
            PlaybackStartupTrace *trace = [root valueForKey:@"startupTrace"];
            check(trace.stages[@"service"] != nil, @"service readiness recorded before AVPlayer startup");
            check([root valueForKey:@"avPlayer"] != nil, @"playback begins after successful readiness probe");
          }},
          @{@"until":^BOOL{PlaybackStartupTrace *t=[root valueForKey:@"startupTrace"];return t.stages[@"itemReady"]!=nil&&t.stages[@"frame"]!=nil;},@"run":^{
            PlaybackStartupTrace *trace = [root valueForKey:@"startupTrace"];
            check(trace.stages[@"itemReady"] != nil, @"real AVPlayer item readiness observed");
            check(trace.stages[@"frame"] != nil && [[root valueForKey:@"firstRender"] boolValue],
                  @"real AVPlayerLayer video frame observed separately");
            check([trace.stages[@"frame"] doubleValue] > 0 && [trace.stages[@"itemReady"] doubleValue] > 0,
                  @"item and video callbacks are measured independently without assuming delivery order");
            NSString *url=[root valueForKey:@"currentRemoteURL"];
            [root playRemote:@{@"id":url,@"name":@"Warm local startup",@"remoteURL":url}];
            check([root valueForKey:@"avPlayer"]!=nil,@"recent successful local health avoids another readiness wait");
            check(((PlaybackStartupTrace *)[root valueForKey:@"startupTrace"]).stages[@"serviceCached"]!=nil,@"warm health reuse is recorded separately");
            AVPlayer *previous = [root valueForKey:@"avPlayer"];
            NSDictionary *native=[root channelWithID:@"cctv1"];
            check(native!=nil,@"native channel lookup succeeds after subscription playback");
            [root playChannel:native route:nil];
            check([previous currentItem] == nil, [NSString stringWithFormat:@"switching to native detaches old subscription item (item=%@ selected=%@ player=%@)",previous.currentItem?@"attached":@"nil",[root valueForKey:@"channelID"]?:@"nil",NSStringFromClass([[root valueForKey:@"currentPlayer"] class]?:NSObject.class)]);
            check([root valueForKey:@"pip"] == nil, @"switching releases old picture-in-picture controller");
          }},
          ^{
            playCount=[CNPlayer smokePlayCount];
            [root selectChannel:[root channelWithID:@"cctv1"]];
            [root selectChannel:[root channelWithID:@"cctv2"]];
            [root selectChannel:[root channelWithID:@"cctv3"]];
          },
          ^{
            check([[root valueForKey:@"channelID"] isEqual:@"cctv3"],[NSString stringWithFormat:@"rapid selections end on final channel (actual %@)",[root valueForKey:@"channelID"]?:@"nil"]);
            check([CNPlayer smokePlayCount]==playCount+1,[NSString stringWithFormat:@"rapid taps start only the final SDK session (before %ld after %ld)",(long)playCount,(long)[CNPlayer smokePlayCount]]);
            NSString *playlist=@"#EXTM3U x-tvg-url=\"https://example.com/guide.xml.gz\"\n#EXTINF:-1 tvg-id=\"guide-one\" group-title=\"测试\",Imported channel\nhttps://example.com/imported.m3u8\n";
            [root importPlaylistData:[playlist dataUsingEncoding:NSUTF8StringEncoding] name:@"本地测试配置"];
            [root selectBottomTab:(id)tabs.arrangedSubviews[3]];
            NSArray *profiles=[NSUserDefaults.standardUserDefaults arrayForKey:@"subscriptions"];
            BOOL imported=NO;for(NSString *source in profiles)if([source hasPrefix:@"local-playlist:"]){imported=YES;check([[ProfileStore metadata:source][@"cachedChannels"] count]==1,@"import stores last-good channels");check([[ProfileStore metadata:source][@"detectedEPGURL"] isEqual:@"https://example.com/guide.xml.gz"],@"file import discovers XMLTV");}
            check(imported,@"file profile persisted");
            capture(self.window,@"11-configuration-imported");
          },
          ^{
            NSArray *arguments=NSProcessInfo.processInfo.arguments;NSUInteger at=[arguments indexOfObject:@"--smoke-port"];NSString *port=arguments[at+1];NSString *url=[NSString stringWithFormat:@"http://127.0.0.1:%@/video.mp4",port];
            playCount=[CNPlayer smokePlayCount];
            [root playChannel:@{@"id":url,@"name":@"Misrouted subscription",@"remoteURL":url} route:nil];
            check([CNPlayer smokePlayCount]==playCount,@"M3U address never reaches native SDK even through native entry");
            check([[root valueForKey:@"activeTab"] integerValue]==1,@"misrouted subscription returns to channel page");
          },
          ^{
            NSArray *args=NSProcessInfo.processInfo.arguments;NSString *port=args[[args indexOfObject:@"--smoke-port"]+1];
            NSString *feed=[NSString stringWithFormat:@"http://127.0.0.1:%@/all.m3u",port];
            [ProfileStore update:feed values:@{@"cachedChannels":@[]}];
            [root beginPlaybackPriority];[root setValue:@NO forKey:@"firstRender"];
            [root fetchSubscription:feed silent:NO];
            check([root valueForKey:@"subscriptionReadiness"]!=nil,@"manual refresh remains available during startup");
          },
          @{@"until":^BOOL{
            NSArray *args=NSProcessInfo.processInfo.arguments;NSString *port=args[[args indexOfObject:@"--smoke-port"]+1];
            return [[ProfileStore metadata:[NSString stringWithFormat:@"http://127.0.0.1:%@/all.m3u",port]][@"cachedChannels"] count]>0;
          },@"run":^{
            NSArray *args=NSProcessInfo.processInfo.arguments;NSString *port=args[[args indexOfObject:@"--smoke-port"]+1];
            NSString *feed=[NSString stringWithFormat:@"http://127.0.0.1:%@/all.m3u",port];
            check([[ProfileStore metadata:feed][@"cachedChannels"] count]>0,@"manual playlist refresh succeeds without a first frame");
            NSString *url=[NSString stringWithFormat:@"http://127.0.0.1:%@/hls/live.m3u8",port];
            [root playRemote:@{@"id":url,@"name":@"HLS delayed segment test",@"remoteURL":url}];
          }},
          @{@"timeout":@30,@"until":^BOOL{
            AVPlayer *p=[root valueForKey:@"avPlayer"];
            return [[root valueForKey:@"firstRender"] boolValue] && CMTimeGetSeconds(p.currentTime)>=8;
          },@"run":^{
            hlsPlayer=[root valueForKey:@"avPlayer"];
            check(CMTimeGetSeconds(hlsPlayer.currentTime)>=8,@"HLS timeline advances past delayed segment after first frame");
            check(hlsPlayer.automaticallyWaitsToMinimizeStalling,@"AVPlayer handles rebuffering automatically");
            [root togglePlayPause];
            [root avItemStalled:[NSNotification notificationWithName:AVPlayerItemPlaybackStalledNotification object:hlsPlayer.currentItem]];
          }},
          ^{
            check(![[root valueForKey:@"remotePlaybackWanted"] boolValue] && hlsPlayer.rate==0,@"buffer recovery cannot undo user pause");
            [root togglePlayPause];
          },
          ^{
            check([[root valueForKey:@"remotePlaybackWanted"] boolValue],@"user can resume same item after buffering");
            [root performSelector:NSSelectorFromString(@"stopPlayback")];
            check(hlsPlayer.currentItem==nil,@"switch/stop detaches HLS observers and item");
            NSArray *arguments=NSProcessInfo.processInfo.arguments;NSUInteger at=[arguments indexOfObject:@"--smoke-port"];NSString *port=arguments[at+1];NSString *url=[NSString stringWithFormat:@"http://127.0.0.1:%@/video.mp4",port];
            [root previewChannel:@{@"remoteURL":url}];
            check([root valueForKey:@"previewPlayer"]!=nil,@"manual preview starts without a formal playback session");
            check([[root valueForKey:@"previewPlayer"] isMuted],@"preview is muted");
            [root selectBottomTab:(id)tabs.arrangedSubviews[0]];
            check([root valueForKey:@"previewPlayer"]==nil,@"navigation releases preview player");
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"preloadNativeChannel"];
            nativePreloader=[root valueForKey:@"nativePreloader"];
            [nativePreloader prepareChannel:@"cctv2" title:@"CCTV-2"];
            preparedWrapper=[nativePreloader valueForKey:@"player"];
            configuredBeforeHandoff=[CNPlayer smokeConfigureCount];
          },
          @{ @"timeout":@20, @"until":^BOOL{
              return nativePreloader && [[nativePreloader valueForKey:@"ready"] boolValue];
            }, @"run":^{
            [root playChannel:[root channelWithID:@"cctv2"] route:nil];
            check([root valueForKey:@"currentPlayer"]==preparedWrapper,[NSString stringWithFormat:@"selected channel adopts metadata-prepared wrapper (ready=%d channel=%@ wrapper=%@ current=%@)",[[nativePreloader valueForKey:@"ready"] boolValue],[nativePreloader valueForKey:@"channel"]?:@"nil",preparedWrapper?:@"nil",[root valueForKey:@"currentPlayer"]?:@"nil"]);
            check([CNPlayer smokeConfigureCount]==configuredBeforeHandoff,@"metadata handoff does not call playLIVE a second time");
            PlaybackStartupTrace *trace=[root valueForKey:@"startupTrace"];
            check(trace.stages[@"preloadedVDN"]!=nil,@"metadata hit is explicitly recorded");
          }},
          ^{
            check([[root valueForKey:@"firstRender"] boolValue],@"metadata handoff reaches first render");
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"preloadNativeChannel"];
            preparedWrapper=[root valueForKey:@"currentPlayer"];configuredBeforeHandoff=[CNPlayer smokeConfigureCount];
            [root seekNativeStart:NSDate.date.timeIntervalSince1970-60 end:0];
          },
          ^{
            check([[root valueForKey:@"firstRender"] boolValue] && [[root valueForKey:@"nativeTimeShiftActive"] boolValue],[NSString stringWithFormat:@"native timeshift reaches a new frame (frame=%d active=%d failed=%d transition=%@)",[[root valueForKey:@"firstRender"] boolValue],[[root valueForKey:@"nativeTimeShiftActive"] boolValue],[[root valueForKey:@"nativePlaybackFailed"] boolValue],[root valueForKey:@"nativeTransitionKind"]?:@"none"]);
            check([root valueForKey:@"currentPlayer"]==preparedWrapper && [CNPlayer smokeConfigureCount]==configuredBeforeHandoff,@"timeshift keeps SDK session without playLIVE reconfiguration");
            [root returnToNativeLive];
          },
          ^{
            check([[root valueForKey:@"firstRender"] boolValue] && ![[root valueForKey:@"nativeTimeShiftActive"] boolValue],@"return-to-live reaches a new frame");
            EPGViewController *page=[[EPGViewController alloc] initWithChannelID:@"cctv2" name:@"fixture"];
            __block NSUInteger replays=0;page.onReplay=^(NSDictionary *program){replays++;};
            NSTimeInterval now=NSDate.date.timeIntervalSince1970;
            [page setValue:@[@{@"start":@(now-120),@"end":@(now-60)},@{@"start":@(now+60),@"end":@(now+120)}] forKey:@"rows"];
            [(id<UITableViewDelegate>)page tableView:nil didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
            check(replays==0,@"future EPG programme cannot replay");
            [(id<UITableViewDelegate>)page tableView:nil didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            check(replays==1,@"past EPG programme invokes replay callback");
          },
          ^{
            NSArray *arguments=NSProcessInfo.processInfo.arguments;NSUInteger at=[arguments indexOfObject:@"--smoke-port"];
            NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%@",arguments[at+1]];
            NSArray *original=[root valueForKey:@"allChannels"];NSMutableArray *channels=[original mutableCopy];
            for(NSUInteger i=0;i<6;i++){NSString *url=[@"http://127.0.0.1:1" stringByAppendingFormat:@"/failure%lu.m3u8",(unsigned long)i];[channels addObject:@{@"id":url,@"remoteURL":url,@"name":@"Fallback fixture",@"subscriptionSources":@[i==1?@"disabled-fallback":@"enabled-fallback"]}];}
            [NSUserDefaults.standardUserDefaults setObject:@[@"disabled-fallback"] forKey:@"disabledSubscriptions"];
            [root setValue:channels forKey:@"allChannels"];
            [root playRemote:channels[original.count]];
            [root tryAlternateSource];
            check([[root valueForKey:@"currentRemoteURL"] hasSuffix:@"failure2.m3u8"],@"fallback skips disabled subscriptions");
            [root tryAlternateSource];[root tryAlternateSource];
            check([[root valueForKey:@"remoteAttemptedURLs"] count]==4,@"fallback is bounded to four distinct URLs");
            NSUInteger generation=[[root valueForKey:@"playbackGeneration"] unsignedIntegerValue];
            [root tryAlternateSource];
            check(generation==[[root valueForKey:@"playbackGeneration"] unsignedIntegerValue],@"failed URLs cannot ping-pong indefinitely");
            [root playRemote:channels[original.count]];
            check([[root valueForKey:@"remoteAttemptedURLs"] count]==1,@"manual selection resets retry budget");
            [root stopPlayback];[root setValue:original forKey:@"allChannels"];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"disabledSubscriptions"];
            HostImageLoader *loader=HostImageLoader.shared;
            [loader cancelPending];[loader clearCache];
            logoA=[UIImageView new];logoB=[UIImageView new];staleLogo=[UIImageView new];oversizeLogo=[UIImageView new];
            [loader loadURL:[base stringByAppendingString:@"/logo.png"] intoImageView:logoA];
            [loader loadURL:[base stringByAppendingString:@"/logo.png"] intoImageView:logoB];
            [loader loadURL:[base stringByAppendingString:@"/slow-logo.png"] intoImageView:staleLogo];
            staleLogo.accessibilityIdentifier=@"reused-for-another-channel";
            [loader loadURL:[base stringByAppendingString:@"/oversize.png"] intoImageView:oversizeLogo];
          },
          @{@"until":^BOOL{return logoA.image!=nil && logoB.image!=nil;},@"run":^{
            check(logoA.image && logoB.image,@"coalesced logo request updates both views");
            check(logoA.image.size.width<=192 && logoA.image.size.height<=192,@"large logo is downsampled off main thread");
            check(staleLogo.image==nil,@"reused image view ignores stale logo completion");
            check(oversizeLogo.image==nil,@"oversized logo response is rejected");
            NSArray *arguments=NSProcessInfo.processInfo.arguments;NSUInteger at=[arguments indexOfObject:@"--smoke-port"];
            NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%@",arguments[at+1]];
            [HostImageLoader.shared loadURL:[base stringByAppendingString:@"/logo.png"] intoImageView:logoA];
            [HostImageLoader.shared loadURL:[base stringByAppendingString:@"/oversize.png"] intoImageView:oversizeLogo];
            [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/image-stats"]] completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){NSDictionary *stats=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;dispatch_async(dispatch_get_main_queue(),^{imageStats=stats;});}] resume];
          }},
          @{@"until":^BOOL{return imageStats!=nil;},@"run":^{
            check([imageStats[@"/logo.png"] integerValue]==1,@"duplicate and cached logos cause only one network request");
            check([imageStats[@"/oversize.png"] integerValue]==1,@"failed logo is not immediately retried");
            check(staleLogo.image==nil,@"late logo result cannot overwrite reused cell");
            [HostImageLoader.shared cancelPending];
            [root selectBottomTab:(id)tabs.arrangedSubviews[0]];
            UISearchController *search=[root valueForKey:@"searchController"];
            search.searchBar.text=@"CCTV";[root updateSearchResultsForSearchController:search];
            search.searchBar.text=@"no-such-final-channel";[root updateSearchResultsForSearchController:search];
          }},
          @{@"until":^BOOL{return [[root valueForKey:@"shownChannels"] count]==0;},@"run":^{
            check([[root valueForKey:@"query"] isEqualToString:@"no-such-final-channel"],@"debounced search keeps final input");
            check([[root valueForKey:@"shownChannels"] count]==0,@"stale search cannot overwrite final results");
            UISearchController *search=[root valueForKey:@"searchController"];search.searchBar.text=@"";[root updateSearchResultsForSearchController:search];
            check([[root valueForKey:@"shownChannels"] count]>20,@"clearing search restores catalog immediately");
            NSString *folder=[[ServiceStore directory] stringByAppendingPathComponent:[@"node-ui-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *script=@"const fs=require('fs');module.exports={init(){fs.writeFileSync('owned.txt','start');setInterval(()=>{},100)},home(){return {class:[{type_id:'movie',type_name:'Film'}]}},search(key){return {list:[{vod_id:key,vod_name:'Original Node JS'}]}},detail(ids){return {list:[{vod_id:ids[0]}]}},play(flag,id){return {parse:0,url:'https://fixture.test/'+id}},close(){fs.appendFileSync('owned.txt','-closed')}}";
            [script writeToFile:[folder stringByAppendingPathComponent:@"index.cjs"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
                NSDictionary *start=nodeCall(@"start",@{@"session":@"node-ui",@"packageRoot":folder,@"dataDirectory":folder,@"entry":@"index.cjs",@"moduleType":@"commonjs",@"protocol":@"catvod-js"});
                NSArray *confirmedNodeSessions=NodePluginRuntime.shared.activeSessionIdentifiers.copy;
                NSDictionary *search=[start[@"ok"] boolValue]?nodeCall(@"search",@{@"session":@"node-ui",@"keyword":@"opaque-node-id"}):@{};
                NSDictionary *stop=nodeCall(@"stop",@{@"session":@"node-ui"});
                NSString *saved=[NSString stringWithContentsOfFile:[folder stringByAppendingPathComponent:@"owned.txt"] encoding:NSUTF8StringEncoding error:NULL];
                [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle pathForResource:@"catpaw-ui" ofType:@"cjs"] toPath:[folder stringByAppendingPathComponent:@"catpaw.cjs"] error:NULL];
                NSDictionary *catpaw=nodeCall(@"start",@{@"session":@"catpaw-ui",@"packageRoot":folder,@"dataDirectory":folder,@"entry":@"catpaw.cjs",@"moduleType":@"commonjs",@"protocol":@"catpaw-http"});
                NSDictionary *providers=[catpaw[@"ok"] boolValue]?nodeCall(@"providers",@{@"session":@"catpaw-ui"}):@{};
                NSDictionary *catpawStop=nodeCall(@"stop",@{@"session":@"catpaw-ui"});
                NSDictionary *checks=@{@"start":start,@"confirmedNodeSessions":confirmedNodeSessions?:@[],@"search":search,@"stop":stop,@"saved":saved?:@"",@"catpaw":catpaw,@"providers":providers,@"catpawStop":catpawStop};
                [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];dispatch_async(dispatch_get_main_queue(),^{nodeChecks=checks;});
            }});
          }},
          @{@"until":^BOOL{return nodeChecks!=nil;},@"timeout":@70,@"run":^{
            check([nodeChecks[@"start"][@"ok"] boolValue],@"actual Node.js Mobile framework starts on iOS simulator");
            check([nodeChecks[@"start"][@"result"][@"version"] hasPrefix:@"18."],@"Node mobile version is measured from the embedded runtime");
            check([nodeChecks[@"search"][@"result"][@"list"][0][@"vod_id"] isEqual:@"opaque-node-id"],@"original CommonJS executes through native Node bridge");
            check([nodeChecks[@"stop"][@"ok"] boolValue] && !NodePluginRuntime.shared.hasActivePlugin,@"Node plugin closes without destroying the reusable engine");
            check([nodeChecks[@"saved"] isEqual:@"start-closed"],@"plugin relative data path is isolated and close hook finishes");
            check([nodeChecks[@"catpaw"][@"ok"] boolValue],@"original 4 MB Catpaw bundle starts inside actual iOS Node Mobile framework");
            check([nodeChecks[@"providers"][@"result"] count]>50,@"original Catpaw configuration exposes its real film providers");
            check([nodeChecks[@"catpawStop"][@"ok"] boolValue],@"original Catpaw HTTP listener and handles stop on iOS");
            NSData *diagnostic=[NSJSONSerialization dataWithJSONObject:nodeChecks options:NSJSONWritingPrettyPrinted error:NULL];[diagnostic writeToFile:[outputDir stringByAppendingPathComponent:@"node-runtime.json"] atomically:YES];
            mediaPage=[MediaBrowserViewController new];
            NSInteger port=[NSProcessInfo.processInfo.arguments[([NSProcessInfo.processInfo.arguments indexOfObject:@"--smoke-port"]+1)] integerValue];
            NSString *mediaSourceID=[NSString stringWithFormat:@"media-ui-%@",NSUUID.UUID.UUIDString];
            mediaPage.sourcesProvider=^NSArray *{return @[@{@"id":mediaSourceID,@"name":@"本机影视测试",@"port":@(port),@"engine":@"node",@"url":[NSString stringWithFormat:@"http://127.0.0.1:%ld/media.js?token=visible",(long)port]}];};
            mediaPage.onActivateService=^(NSDictionary *service,void (^done)(NSError *)){done(nil);};
            mediaPage.onPlay=^(NSDictionary *result,NSDictionary *context){mediaPlayback=[MediaPlaybackViewController new];mediaPlayback.result=result;mediaPlayback.context=context;[nav pushViewController:mediaPlayback animated:NO];};
            [nav pushViewController:mediaPage animated:NO];
          }},
          @{ @"until":^BOOL{return mediaPage!=nil&&[[mediaPage valueForKey:@"homeMode"] boolValue];},@"run":^{
            UIScrollView *home=[mediaPage valueForKey:@"homeScroll"];UIStackView *homeStack=[mediaPage valueForKey:@"homeStack"];UIButton *browseButton=[mediaPage valueForKey:@"homeModeButton"];UIButton *homeSearch=[mediaPage valueForKey:@"homeSearchButton"];UIButton *homeSource=[mediaPage valueForKey:@"sourceSelectButton"];UIButton *homeProvider=[mediaPage valueForKey:@"providerSelectButton"];
            UIStackView *homeSelectors=[mediaPage valueForKey:@"selectionRow"];
            UIView *statusCard=nil;for(UIView *view in homeStack.arrangedSubviews)if([view.accessibilityIdentifier isEqual:@"media-home-status-card"]){statusCard=view;break;}UIButton *start=[mediaPage valueForKey:@"homeStatusActionButton"];
            BOOL homeLoading=[[mediaPage valueForKey:@"homeStatusLoading"] boolValue];NSString *statusAction=start.currentTitle?:@"";BOOL statusActionReady=[@[@"启动并加载",@"重试启动",@"重试",@"打开影视库"] containsObject:statusAction];BOOL inlineStatusReady=homeLoading?start.hidden:statusActionReady;
            check(mediaPage.isHomeMode&&!home.hidden&&browseButton!=nil&&homeSearch!=nil,@"media tab presents a compact resource home with floating browse and search actions");check(homeStack.arrangedSubviews.count>0,@"media home renders configured modules");check(!homeSelectors.hidden&&homeSource!=nil&&!homeSource.hidden&&homeProvider!=nil&&!homeProvider.hidden,@"home keeps independent resource and site selectors side by side at the top");check([browseButton.accessibilityLabel isEqual:@"打开影视库"]&&[homeSearch.accessibilityLabel isEqual:@"全站搜索影视"]&&[homeSource.accessibilityLabel containsString:@"影视资源"]&&[homeProvider.accessibilityLabel containsString:@"影视站点"],@"home selectors expose resource-list and selected-resource site-list actions");check(CGRectGetMinY(home.frame)>CGRectGetMaxY(homeSelectors.frame),@"home content starts below the top resource and site selector row");check(statusCard!=nil&&inlineStatusReady,[NSString stringWithFormat:@"home shows inline readiness or an actionable status (loading=%d, action=%@, card=%@)",homeLoading,statusAction,statusCard?@"visible":@"missing"]);
            UIButton *homeMenu=[mediaPage valueForKey:@"homeMenuButton"];[mediaPage.view layoutIfNeeded];CGFloat expectedSelectorTop=mediaPage.view.safeAreaInsets.top+4;check(fabs(CGRectGetMinY(homeSelectors.frame)-expectedSelectorTop)<1.5&&fabs(CGRectGetMinX(homeSelectors.frame)-14)<1.5&&fabs(CGRectGetMaxX(homeSelectors.frame)-(CGRectGetWidth(mediaPage.view.bounds)-14))<1.5&&fabs(homeSelectors.spacing-10)<0.1,@"home source and site selectors sit 4 pt below the safe area with 14 pt side margins and 10 pt spacing");check([homeMenu.accessibilityLabel isEqual:@"更多影视操作"]&&homeMenu.menu.children.count==9&&homeMenu.currentImage!=nil,@"floating line menu keeps all nine original home actions and an accessible label");check(fabs(CGRectGetMinY(browseButton.frame)-CGRectGetMaxY(homeMenu.frame)-12)<1.5&&fabs(CGRectGetMinY(homeSearch.frame)-CGRectGetMaxY(browseButton.frame)-12)<1.5,@"floating controls are ordered menu, library, search with 12 pt gaps");check(home.contentInset.bottom>=180&&homeSearch.frame.size.height==56,@"home scrolling reserves space for final content above the floating controls");check(homeSource.titleLabel.lineBreakMode==NSLineBreakByTruncatingTail&&[homeSource.accessibilityLabel containsString:@"本机影视测试"],@"long resource names truncate visually while the complete name remains accessible");capture(self.window,@"16-media-home");
            // The test source is not registered in PyHost. Always drive its activation
            // action even when a stale loading state is visible.
            check(homeProvider.enabled,@"film site selector can prepare an unstarted source on demand");if(homeProvider.enabled)[homeProvider sendActionsForControlEvents:UIControlEventTouchUpInside];else if(start&&![statusAction isEqualToString:@"打开影视库"])[start sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"timeout":@100,@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"provider selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];NSIndexPath *selected=nil;for(NSInteger row=0;row<[picker.tableView numberOfRowsInSection:0];row++){UITableViewCell *cell=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];if(cell.accessoryType==UITableViewCellAccessoryCheckmark){selected=[NSIndexPath indexPathForRow:row inSection:0];break;}}
            check([picker.tableView numberOfRowsInSection:0]==2&&selected!=nil,@"tapping the top site selector prepares the resource and opens its real site list");capture(self.window,@"16a-home-site-selector");NSInteger nextRow=selected.row==0?1:0;[picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:nextRow inSection:0]];
          }},
          // The Node runtime has completed its cold start before this fixture
          // source is inserted. Keep a bounded readiness window and fail
          // promptly if the home request becomes wedged.
          @{ @"until":^BOOL{return [[mediaPage valueForKey:@"items"] count]>0&&mediaPage.isHomeMode&&![[mediaPage valueForKey:@"loading"] boolValue];},@"timeout":@100,@"run":^{
            check(mediaPage.isHomeMode,@"home start action waits through health and capability readiness while retaining the home");[mediaPage.view layoutIfNeeded];UIScrollView *carousel=[mediaPage valueForKey:@"homeCarousel"];UIPageControl *pages=[mediaPage valueForKey:@"homeCarouselPageControl"];NSDictionary *activeSource=[mediaPage valueForKey:@"source"]?:@{};UILabel *statusLabel=[mediaPage valueForKey:@"status"];UILabel *stageLabel=[mediaPage valueForKey:@"readinessStageLabel"];NSDictionary *probe=[[[mediaPage valueForKey:@"readiness"] diagnosticSummary] isKindOfClass:NSDictionary.class]?[[mediaPage valueForKey:@"readiness"] diagnosticSummary]:@{};id apiClient=[mediaPage valueForKey:@"client"];NSString *activeOperation=[apiClient valueForKey:@"activeOperation"]?:@"";NSString *activeRequestID=[apiClient valueForKey:@"activeRequestID"]?:@"";check(carousel.isPagingEnabled&&pages.numberOfPages==3,[NSString stringWithFormat:@"home renders a swipeable featured carousel from its source response (scroll=%@, paging=%d, pages=%ld, items=%lu, source=%@, provider=%@, source_id=%@, status=%@, stage=%@, loading=%@, generation=%@, active_operation=%@, active_request=%@, probe=%@)",carousel?NSStringFromCGRect(carousel.frame):@"missing",carousel.isPagingEnabled,(long)pages.numberOfPages,(unsigned long)[[mediaPage valueForKey:@"items"] count],[mediaPage valueForKey:@"homeResultSourceID"]?:@"",[mediaPage valueForKey:@"homeResultProvider"]?:@"",activeSource[@"id"]?:@"",statusLabel.text?:@"",stageLabel.text?:@"",[mediaPage valueForKey:@"loading"]?:@NO,[mediaPage valueForKey:@"generation"]?:@0,activeOperation,activeRequestID,probe]);[carousel setContentOffset:CGPointMake(carousel.bounds.size.width,0) animated:NO];check(pages.currentPage==1,[NSString stringWithFormat:@"featured carousel page indicator follows horizontal navigation (page=%ld, width=%.1f)",(long)pages.currentPage,carousel.bounds.size.width]);[carousel setContentOffset:CGPointZero animated:NO];UIButton *browse=[mediaPage valueForKey:@"homeModeButton"];[browse sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"until":^BOOL{return [[mediaPage valueForKey:@"items"] count]>0&&!mediaPage.isHomeMode;},@"run":^{
            check([[mediaPage valueForKey:@"items"] count]==3,@"media library preserves the source's real home recommendations");
            UIStackView *selectionRow=[mediaPage valueForKey:@"selectionRow"];UIButton *sourceSelector=[mediaPage valueForKey:@"sourceSelectButton"];UIButton *providerSelector=[mediaPage valueForKey:@"providerSelectButton"];NSString *activeProviderID=[mediaPage valueForKey:@"provider"]?:@"";NSArray *loadedProviders=[mediaPage valueForKey:@"providers"]?:@[];NSString *activeProviderName=nil;for(NSDictionary *candidate in loadedProviders)if([candidate[@"id"] isEqual:activeProviderID]){activeProviderName=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:candidate[@"id"];break;}check(CGRectGetMinY(selectionRow.frame)>=mediaPage.view.safeAreaInsets.top,@"two-level resource selectors stay inside the media safe area");check([sourceSelector.currentTitle containsString:@"本机影视测试"]&&activeProviderName.length&&[providerSelector.currentTitle containsString:activeProviderName],[NSString stringWithFormat:@"top selectors show the active resource and its selected site (provider=%@, button=%@)",activeProviderName?:@"unresolved",providerSelector.currentTitle?:@""]);check(providerSelector.enabled,@"second-level selector becomes available after providers load");
            UIScrollView *categories=[mediaPage valueForKey:@"categoryScroll"];check([mediaPage.title isEqual:@"影视库"]&&!mediaPage.isHomeMode&&!selectionRow.hidden,@"opening a selected source from home enters the separate resource library");check(CGRectGetMinY(categories.frame)>CGRectGetMaxY(selectionRow.frame),@"film categories appear below the two-level resource selectors");capture(self.window,@"16-media-library");[sourceSelector sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"resource selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];UITableViewCell *current=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            UIStackView *scopeStack=[picker valueForKey:@"scopeStack"];check(sheet.modalPresentationStyle==UIModalPresentationPageSheet,@"resource selection uses a native bottom sheet");check([picker.tableView numberOfRowsInSection:0]==1&&current.accessoryType==UITableViewCellAccessoryCheckmark,@"resource sheet shows its current selection");check(scopeStack.arrangedSubviews.count==2,@"resource sheet groups resources by runtime and keeps all resources visible");capture(self.window,@"16b-media-resource-sheet");
            [picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])==nil&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==3;},@"run":^{UIButton *providerSelector=[mediaPage valueForKey:@"providerSelectButton"];[providerSelector sendActionsForControlEvents:UIControlEventTouchUpInside];}},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"provider selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];NSIndexPath *current=nil;for(NSInteger row=0;row<[picker.tableView numberOfRowsInSection:0];row++){UITableViewCell *cell=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];if(cell.accessoryType==UITableViewCellAccessoryCheckmark){current=[NSIndexPath indexPathForRow:row inSection:0];break;}}
            check(sheet.modalPresentationStyle==UIModalPresentationPageSheet,@"platform selection uses a separate bottom sheet");check([picker.tableView numberOfRowsInSection:0]==2&&current!=nil,@"platform sheet lists choices and marks the current platform");capture(self.window,@"16c-media-platform-sheet");
            NSInteger nextRow=current.row==0?1:0;[picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:nextRow inSection:0]];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])==nil&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==3;},@"run":^{[mediaPage openSourceConfiguration];}},
          @{@"until":^BOOL{UIViewController *presented=SmokePresentedController(@[mediaPage,nav,root]);if(![presented isKindOfClass:UINavigationController.class])return NO;UINavigationController *sheet=(UINavigationController *)presented;WKWebView *web=[sheet.topViewController isKindOfClass:MediaWebViewController.class]?[sheet.topViewController valueForKey:@"web"]:nil;return [sheet isKindOfClass:UINavigationController.class]&&[sheet.topViewController isKindOfClass:MediaWebViewController.class]&&[web.URL.path isEqual:@"/source-config"];},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"source configuration");if(!sheet)return;MediaWebViewController *page=(id)sheet.topViewController;WKWebView *web=[page valueForKey:@"web"];
            check([web.URL.path isEqual:@"/source-config"],[NSString stringWithFormat:@"source configuration opens the real local service page (url=%@)",web.URL.absoluteString?:@"nil"]);check(!web.configuration.websiteDataStore.persistent,@"source configuration uses an isolated ephemeral cookie store");check(sheet.modalInPresentation,@"configuration has an explicit close-and-refresh action");capture(self.window,@"16d-media-source-configuration");[page close];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])==nil&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==3;},@"run":^{
            UISearchController *search=[mediaPage valueForKey:@"search"];search.searchBar.text=@"中文";[mediaPage updateSearchResultsForSearchController:search];
          }},
          @{@"until":^BOOL{return [[[mediaPage valueForKey:@"items"] firstObject][@"id"] isEqual:@"中文1"];},@"run":^{
            check([[[mediaPage valueForKey:@"items"] firstObject][@"id"] isEqual:@"中文1"],@"media search keeps source IDs and unicode");[mediaPage loadMore];
          }},
          @{@"until":^BOOL{return [[mediaPage valueForKey:@"items"] count]==2;},@"run":^{
            check([[mediaPage valueForKey:@"items"] count]==2,@"media pagination appends without losing previous page");capture(self.window,@"17-media-search");
            UICollectionView *grid=[mediaPage valueForKey:@"grid"];[grid.delegate collectionView:grid didSelectItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];mediaDetail=(id)nav.topViewController;
          }},
          @{@"until":^BOOL{return mediaDetail&&[[mediaDetail valueForKey:@"episodeButtons"] count]==3;},@"run":^{
            UIStackView *routes=[mediaDetail valueForKey:@"routeButtons"];UIStackView *episodeGrid=[mediaDetail valueForKey:@"episodeGrid"];NSArray *episodeButtons=[mediaDetail valueForKey:@"episodeButtons"];
            NSUInteger expectedEpisodeRows=(episodeButtons.count+3)/4;check(routes.arrangedSubviews.count==2,@"film detail exposes each real playback route as a chip");check(episodeGrid.arrangedSubviews.count==expectedEpisodeRows&&episodeButtons.count==3,@"film detail renders only the needed rows in a paged four-column grid");
            check([mediaDetail valueForKey:@"heroTitle"] && [mediaDetail valueForKey:@"playButton"] && [mediaDetail valueForKey:@"favoriteButton"] && [mediaDetail valueForKey:@"posterPlaceholder"],@"film detail shows compact poster fallback and actionable play/favorite controls without a cast strip");capture(self.window,@"18-media-detail");
            UIButton *favorite=[mediaDetail valueForKey:@"favoriteButton"];[favorite sendActionsForControlEvents:UIControlEventTouchUpInside];check([favorite.accessibilityLabel isEqual:@"取消收藏影片"]&&[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] count]>0,@"film favorite is visibly updated and persisted");[favorite sendActionsForControlEvents:UIControlEventTouchUpInside];
            [(UIButton *)episodeButtons[0] sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{@"until":^BOOL{mediaPlayback=(id)[mediaDetail valueForKey:@"inlinePlaybackController"];AVPlayer *player=[mediaPlayback valueForKey:@"player"];return mediaPlayback&&player.currentItem.status==AVPlayerItemStatusReadyToPlay;},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];UIStackView *qualityButtons=[mediaPlayback valueForKey:@"qualityButtons"];NSArray *inlineEpisodeButtons=[mediaDetail valueForKey:@"episodeButtons"];NSUInteger expectedInlineRows=(inlineEpisodeButtons.count+3)/4;check(player.currentItem.status==AVPlayerItemStatusReadyToPlay,@"selected plugin episode reaches AVPlayer ready state embedded in film detail");check(nav.topViewController==mediaDetail,@"starting playback keeps the user on the same detail page");check([[mediaDetail valueForKey:@"heroView"] isHidden]&&((UIStackView *)[mediaDetail valueForKey:@"episodeGrid"]).arrangedSubviews.count==expectedInlineRows,@"inline video replaces the poster while detail episodes remain in the same scroll page");check([[mediaPlayback valueForKey:@"embeddedMode"] boolValue],@"the existing diagnostic player runs in inline mode");check(qualityButtons.arrangedSubviews.count==2,@"inline player exposes the source's actual alternate quality choices");capture(self.window,@"19-media-inline-playback");[(UIButton *)qualityButtons.arrangedSubviews[1] sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"timeout":@12,@"until":^BOOL{UILabel *status=[mediaPlayback valueForKey:@"status"];return [status.text containsString:@"视频首帧已就绪"];},@"run":^{
            UILabel *status=[mediaPlayback valueForKey:@"status"];AVPlayer *qualityPlayer=[mediaPlayback valueForKey:@"player"];AVURLAsset *qualityAsset=(AVURLAsset *)qualityPlayer.currentItem.asset;check([status.text containsString:@"视频首帧已就绪"],@"AVPlayerLayer displays a header-protected frame from the selected film resource");check([qualityAsset.URL.absoluteString containsString:@"quality=low"],@"choosing a quality option replaces the active AVPlayer item with that stream");
            NSArray *playbackLines=[mediaPlayback valueForKey:@"lines"];check(playbackLines.count==2,[NSString stringWithFormat:@"playback retains both detail routes before opening selector (actual %lu)",(unsigned long)playbackLines.count]);
            [mediaPlayback openEpisodeSelection];UIViewController *selectorPage=nav.topViewController;check([selectorPage isKindOfClass:MediaEpisodeSelectionViewController.class],[NSString stringWithFormat:@"player opens shared episode selector (top page %@)",NSStringFromClass(selectorPage.class)]);
            if([selectorPage isKindOfClass:MediaEpisodeSelectionViewController.class]){mediaEpisodes=(id)selectorPage;[mediaEpisodes loadViewIfNeeded];check(mediaEpisodes.selectionUpdatesPlayer,@"episode selector keeps playback context");NSArray *selectorLines=[mediaEpisodes valueForKey:@"lines"];check(selectorLines.count==2,[NSString stringWithFormat:@"episode selector receives both playback routes (actual %lu)",(unsigned long)selectorLines.count]);UIStackView *routes=[mediaEpisodes valueForKey:@"routeButtons"];NSArray *episodeButtons=[mediaEpisodes valueForKey:@"episodeButtons"];check(routes.arrangedSubviews.count==2,@"playback episode picker renders both route chips");check(episodeButtons.count==3,@"playback episode picker renders the three-column episode grid");capture(self.window,@"18-media-episodes");
              if(episodeButtons.count>1){UIButton *slowButton=episodeButtons[1];[slowButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaEpisodes.selectedEpisodeIndex==1,[NSString stringWithFormat:@"slow episode request updates selector immediately (selected %ld, tag %ld)",(long)mediaEpisodes.selectedEpisodeIndex,(long)slowButton.tag]);}else check(NO,@"player episode picker exposes a second episode");
              episodeButtons=[mediaEpisodes valueForKey:@"episodeButtons"];if(episodeButtons.count>2){UIButton *fastButton=episodeButtons[2];[fastButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaEpisodes.selectedEpisodeIndex==2,[NSString stringWithFormat:@"player episode selector stays responsive (selected %ld, tag %ld)",(long)mediaEpisodes.selectedEpisodeIndex,(long)fastButton.tag]);}else check(NO,@"player episode picker exposes a third episode");}
            stalePlaybackDeadline=[NSDate dateWithTimeIntervalSinceNow:4.0];
          }},
          @{ @"timeout":@12,@"until":^BOOL{AVPlayer *player=[mediaPlayback valueForKey:@"player"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;return player.currentItem.status==AVPlayerItemStatusReadyToPlay&&[asset.URL.absoluteString containsString:@"play=fast"]&&[stalePlaybackDeadline timeIntervalSinceNow]<=0;},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;check([asset.URL.absoluteString containsString:@"play=fast"],@"late slow parse cannot replace the latest selected episode");capture(self.window,@"20-media-fast-switch");UIStackView *routes=[mediaPlayback valueForKey:@"lineButtons"];if(routes.arrangedSubviews.count>1)[(UIButton *)routes.arrangedSubviews[1] sendActionsForControlEvents:UIControlEventTouchUpInside];else check(NO,@"film player offers the second source route for HLS compatibility check");
          }},
          @{ @"timeout":@16,@"until":^BOOL{AVPlayer *player=[mediaPlayback valueForKey:@"player"];UILabel *status=[mediaPlayback valueForKey:@"status"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;return player.currentItem.status==AVPlayerItemStatusReadyToPlay&&[asset.URL.pathExtension.lowercaseString isEqual:@"m3u8"]&&[status.text containsString:@"视频首帧已就绪"];},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];UILabel *status=[mediaPlayback valueForKey:@"status"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;NSDictionary *result=[mediaPlayback valueForKey:@"result"];check([result[@"parse"] boolValue]&&[result[@"format"] isEqual:@"hls"],@"legacy parse=1 HLS media result is routed to AVPlayer when the returned URL is a real HLS manifest");check([asset.URL.pathExtension.lowercaseString isEqual:@"m3u8"],@"plugin HLS route remains a native HLS asset");check([status.text containsString:@"视频首帧已就绪"],@"AVPlayer decodes and displays a real frame from the imported-source HLS fixture");capture(self.window,@"20b-media-hls-first-frame");[nav popToViewController:mediaPage animated:NO];
            NSInteger port=[NSProcessInfo.processInfo.arguments[([NSProcessInfo.processInfo.arguments indexOfObject:@"--smoke-port"]+1)] integerValue];
            NSDictionary *fixture=@{@"name":@"TVBox Fixture",@"sites":@[@{@"key":@"js-site",@"name":@"查询参数脚本",@"api":@"https://provider.test/index.js?token=kept",@"ext":@{@"home":@"fixture"}},@{@"key":@"jar-site",@"name":@"JAR API",@"api":@"https://provider.test/jar?type=3"}],@"lives":@[@{@"name":@"本机直播列表",@"url":[NSString stringWithFormat:@"http://127.0.0.1:%ld/all.m3u",(long)port]}]};
            NSData *fixtureData=[NSJSONSerialization dataWithJSONObject:fixture options:0 error:NULL];NSError *catalogError=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:fixtureData sourceURL:@"https://provider.test/tvbox.json" error:&catalogError];
            check(catalog!=nil&&catalogError==nil,@"TVBox JSON parses under bounded schema validation");
            check([catalog[@"sites"][0][@"supported"] boolValue]&&[catalog[@"sites"][0][@"api"] isEqual:@"https://provider.test/index.js?token=kept"],@"TVBox direct script retains its complete source URL");
            check(![catalog[@"sites"][1][@"supported"] boolValue],@"unsupported TVBox JAR API is shown as unavailable");
            check([catalog[@"lives"] count]==1,@"TVBox live-list URL remains a separate subscription entry");
            if(catalog)[TVBoxCatalogStore saveCatalog:catalog];
            TVBoxCatalogViewController *catalogPage=[TVBoxCatalogViewController new];catalogPage.catalog=[TVBoxCatalogStore catalogForID:catalog[@"id"]]?:catalog;[nav pushViewController:catalogPage animated:NO];
            check([catalogPage.tableView numberOfSections]==2&&[catalogPage.tableView numberOfRowsInSection:0]==2,@"resource collection separates script sites from live lists");
            UISearchController *catalogSearch=[catalogPage valueForKey:@"searchController"];catalogSearch.searchBar.text=@"index.js";[catalogSearch.searchResultsUpdater updateSearchResultsForSearchController:catalogSearch];check([catalogPage.tableView numberOfRowsInSection:0]==1,@"large resource collections can find one script by URL");catalogSearch.searchBar.text=@"";[catalogSearch.searchResultsUpdater updateSearchResultsForSearchController:catalogSearch];
            catalogPage.serviceForSite=^NSDictionary *(NSDictionary *site){return [site[@"key"] isEqual:@"js-site"]?@{@"id":@"fixture-js",@"name":@"Fixture JS",@"enabled":@YES}:nil;};
            NSIndexPath *siteIndex=[NSIndexPath indexPathForRow:0 inSection:0];UITableViewCell *siteCell=[catalogPage tableView:catalogPage.tableView cellForRowAtIndexPath:siteIndex];check([siteCell.detailTextLabel.text containsString:@"服务运行中"]&&[siteCell.detailTextLabel.text containsString:@"点按打开资源"],@"collection reflects an already imported script runtime");check([siteCell.detailTextLabel.text containsString:@"?token=kept"],@"collection keeps source query parameters visible");
            [catalogPage.tableView.delegate tableView:catalogPage.tableView didSelectRowAtIndexPath:siteIndex];UIViewController *presented=SmokePresentedController(@[catalogPage,nav,root]);UIAlertController *existingActions=[presented isKindOfClass:UIAlertController.class]?(UIAlertController *)presented:nil;NSArray *existingTitles=[existingActions.actions valueForKey:@"title"]?:@[];check([existingTitles containsObject:@"启动并打开资源"],[NSString stringWithFormat:@"an imported collection script offers direct browse (presented=%@ actions=%@)",presented?NSStringFromClass(presented.class):@"none",existingTitles]);[catalogPage dismissViewControllerAnimated:NO completion:nil];capture(self.window,@"21-tvbox-catalog");
          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[(UIViewController *)nav.topViewController,nav,root])==nil;}, @"run":^{
            TVBoxCatalogViewController *catalogPage=(id)nav.topViewController;catalogPage.serviceForSite=nil;NSIndexPath *siteIndex=[NSIndexPath indexPathForRow:0 inSection:0];[catalogPage.tableView.delegate tableView:catalogPage.tableView didSelectRowAtIndexPath:siteIndex];
          }},
          @{ @"until":^BOOL{return [SmokePresentedController(@[(UIViewController *)nav.topViewController,nav,root]) isKindOfClass:UIAlertController.class];}, @"run":^{
            TVBoxCatalogViewController *catalogPage=(id)nav.topViewController;UIAlertController *newActions=(id)SmokePresentedController(@[catalogPage,nav,root]);NSArray *newTitles=[newActions.actions valueForKey:@"title"];check([newTitles containsObject:@"导入并打开资源"]&&[newTitles containsObject:@"仅导入到资源页"],@"an unimported script offers explicit import-and-browse or import-only flow");[catalogPage dismissViewControllerAnimated:NO completion:nil];[TVBoxCatalogStore removeCatalog:catalogPage.catalog[@"id"]];[nav popViewControllerAnimated:NO];
          }},
          ^{
            searchPage=[MediaGlobalSearchViewController new];searchPage.sources=@[@{@"id":@"search-a",@"name":@"影视合集"},@{@"id":@"search-stopped",@"name":@"未启动插件"},@{@"id":@"search-failed",@"name":@"失败来源"},@{@"id":@"search-empty",@"name":@"空结果来源"}];
            [nav pushViewController:searchPage animated:NO];[searchPage loadViewIfNeeded];
            NSMutableArray *entries=[NSMutableArray array];NSMutableArray *items=[NSMutableArray array];for(NSUInteger i=0;i<10;i++)[items addObject:@{@"id":[NSString stringWithFormat:@"film-%lu",(unsigned long)i],@"name":[NSString stringWithFormat:@"测试影片 %lu",(unsigned long)i+1],@"year":@2026,@"remarks":@"本机交互测试"}];
            MediaSearchAppend(entries,items,@"a",@"站点甲",100);MediaSearchAppend(entries,items,@"b",@"站点乙",100);
            NSMutableArray *rows=[NSMutableArray arrayWithArray:@[[ @{@"state":@"搜索中",@"results":entries,@"error":@"",@"providerStates":[@{@"a":@{@"name":@"站点甲",@"state":@"搜索中"},@"b":@{@"name":@"站点乙",@"state":@"搜索完成"}} mutableCopy]} mutableCopy],[@{@"state":@"服务未运行 · 点按启动",@"results":[NSMutableArray array],@"providerStates":[NSMutableDictionary dictionary]} mutableCopy],[@{@"state":@"搜索失败",@"error":@"测试健康检查失败",@"results":[NSMutableArray array],@"providerStates":[NSMutableDictionary dictionary]} mutableCopy],[@{@"state":@"无结果",@"results":[NSMutableArray array],@"providerStates":[NSMutableDictionary dictionary]} mutableCopy]]];
            [searchPage setValue:rows forKey:@"rows"];[searchPage setValue:@20 forKey:@"resultCount"];[searchPage setValue:@"测试" forKey:@"keyword"];UISearchBar *bar=[searchPage valueForKey:@"searchBar"];bar.text=@"测试";
            [searchPage updateFilters];[searchPage.tableView reloadData];[searchPage.view layoutIfNeeded];capture(self.window,@"21a-global-search-all");
            NSArray *choices=[searchPage valueForKey:@"filterChoices"];NSUInteger filter=[choices indexOfObjectPassingTest:^BOOL(NSDictionary *choice,NSUInteger index,BOOL *stop){return [choice[@"provider"] isEqual:@"a"];}];
            check(filter!=NSNotFound,@"global search exposes a station filter");if(filter!=NSNotFound){UIStackView *stack=[searchPage valueForKey:@"filterStack"];[searchPage selectSearchFilter:(UIButton *)stack.arrangedSubviews[filter]];check((((UIButton *)stack.arrangedSubviews[filter]).accessibilityTraits&UIAccessibilityTraitSelected)!=0,@"station selection updates the visible chip selected state");}
            check([searchPage.tableView numberOfRowsInSection:0]==11&&[searchPage.tableView numberOfRowsInSection:1]==0,@"station filter shows only its ten real fixture results");
            searchPage.onSelectResult=^(NSDictionary *item,NSDictionary *source,NSString *provider){selectedSearchID=MediaSearchText(item[@"id"]);check([provider isEqual:@"a"],@"filtered tap keeps the correct provider");UIViewController *detail=[UIViewController new];detail.view.backgroundColor=HostBackground();detail.title=@"搜索返回测试";[nav pushViewController:detail animated:NO];};
            [searchPage.tableView setContentOffset:CGPointMake(0,320) animated:NO];[searchPage.tableView layoutIfNeeded];searchReturnOffset=searchPage.tableView.contentOffset;
            [searchPage tableView:searchPage.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
            check([selectedSearchID isEqual:@"film-1"],@"filtered result opens its own film");
          },
          ^{
            NSMutableArray *rows=[searchPage valueForKey:@"rows"];MediaSearchAppend(rows[0][@"results"],@[@{@"id":@"late",@"name":@"稍后返回的测试结果"}],@"a",@"站点甲",100);[searchPage setValue:@21 forKey:@"resultCount"];[searchPage reloadSection:0];[nav popViewControllerAnimated:NO];
          },
          @{ @"until":^BOOL{return nav.topViewController==searchPage&&searchPage.view.window!=nil;},@"run":^{
            check([[[searchPage valueForKey:@"searchBar"] text] isEqual:@"测试"]&&[[searchPage valueForKey:@"selectedProvider"] isEqual:@"a"],@"returning from detail preserves keyword and station filter");
            check(fabs(searchPage.tableView.contentOffset.y-searchReturnOffset.y)<2,[NSString stringWithFormat:@"returning from detail preserves the reading offset (expected=%.2f actual=%.2f anchor=%@)",searchReturnOffset.y,searchPage.tableView.contentOffset.y,[searchPage valueForKey:@"savedReadingPosition"]]);check([searchPage.tableView numberOfRowsInSection:0]==12,@"results received while reading detail are available on return");capture(self.window,@"21b-global-search-station");
            staleSearchJob=[NSClassFromString(@"MediaGlobalSearchJob") new];[staleSearchJob setValue:@0 forKey:@"section"];[staleSearchJob setValue:[searchPage valueForKey:@"generation"] forKey:@"generation"];NSMutableDictionary *jobs=[searchPage valueForKey:@"jobs"];jobs[@0]=staleSearchJob;[searchPage setValue:@YES forKey:@"searching"];check([searchPage isCurrentJob:staleSearchJob],@"current search job is recognized before editing");
            UISearchBar *bar=[searchPage valueForKey:@"searchBar"];bar.text=@"新关键词";[bar.delegate searchBar:bar textDidChange:bar.text];check(![searchPage isCurrentJob:staleSearchJob]&&jobs.count==0,@"editing a keyword invalidates and cancels all previous jobs");
            // Exercise the actual controller completion path with out-of-order
            // old/new responses, not just the isCurrentJob predicate.
            NSMutableArray *rows=[searchPage valueForKey:@"rows"];[rows[0][@"results"] removeAllObjects];[searchPage setValue:@0 forKey:@"resultCount"];
            for(NSString *term in @[@"旧关键词",@"新关键词"]){
                if([term isEqual:@"新关键词"]){bar.text=term;[bar.delegate searchBar:bar textDidChange:term];}
                [searchPage setValue:term forKey:@"keyword"];bar.text=term;[searchPage setValue:@YES forKey:@"searching"];
                id job=[NSClassFromString(@"MediaGlobalSearchJob") new];[job setValue:@0 forKey:@"section"];[job setValue:[searchPage valueForKey:@"generation"] forKey:@"generation"];[job setValue:@(CACurrentMediaTime()) forKey:@"startedAt"];[job setValue:searchPage.sources[0] forKey:@"source"];[job setValue:@[@{@"id":@"a",@"name":@"站点甲"}] forKey:@"providers"];[job setValue:[[SmokeDelayedSearchClient alloc] initWithPort:1 requestTimeout:1] forKey:@"client"];
                jobs[@0]=job;[searchPage searchNextProviderForJob:job];
            }
            staleSearchDeadline=[NSDate dateWithTimeIntervalSinceNow:1.0];
          }},
          @{ @"until":^BOOL{return [staleSearchDeadline timeIntervalSinceNow]<=0;},@"run":^{
            NSArray *rows=[searchPage valueForKey:@"rows"];NSArray *results=rows[0][@"results"];
            check(results.count==1&&[results.firstObject[@"item"][@"id"] isEqual:@"新关键词"],@"a late old-query completion cannot overwrite or append to the new query");
            check([[searchPage valueForKey:@"resultCount"] unsignedIntegerValue]==1,@"late callbacks cannot inflate station result counts");
            UISearchBar *bar=[searchPage valueForKey:@"searchBar"];bar.text=@"";[bar.delegate searchBar:bar textDidChange:bar.text];check([[searchPage valueForKey:@"rows"] count]==0&&[[searchPage valueForKey:@"resultCount"] unsignedIntegerValue]==0,@"clearing the keyword clears old results and counts");[nav popViewControllerAnimated:NO];
          }},
          ^{
            MediaBrowserViewController *recoveryProbe=[MediaBrowserViewController new];[recoveryProbe loadViewIfNeeded];
            __block NSUInteger moduleBuilds=0;__block UIView *moduleView=nil;
            dispatch_block_t buildModule=^{moduleBuilds++;moduleView=[UILabel new];[(UIStackView *)[recoveryProbe valueForKey:@"homeStack"] addArrangedSubview:moduleView];};
            [recoveryProbe appendHomeModule:@"fixture" signature:@[@"same"] build:buildModule];UIView *firstModule=moduleView;
            UIStackView *moduleStack=[recoveryProbe valueForKey:@"homeStack"];[moduleStack removeArrangedSubview:firstModule];[firstModule removeFromSuperview];
            [recoveryProbe appendHomeModule:@"fixture" signature:@[@"same"] build:buildModule];check(moduleBuilds==1&&moduleStack.arrangedSubviews.lastObject==firstModule,@"unchanged home modules reuse their actual views");
            [moduleStack removeArrangedSubview:firstModule];[firstModule removeFromSuperview];
            [recoveryProbe appendHomeModule:@"fixture" signature:@[@"changed"] build:buildModule];check(moduleBuilds==2&&moduleView!=firstModule,@"changed home module content invalidates its cached views");
            NSDictionary *recoverySource=@{@"id":@"recover-only-this-id",@"port":@18788,@"engine":@"python"};[recoveryProbe setValue:recoverySource forKey:@"source"];
            __block NSUInteger restarts=0,activations=0;__block void (^finishRestart)(NSError *);
            recoveryProbe.onRestartService=^(NSDictionary *source,void (^done)(NSError *)){restarts++;check([source[@"id"] isEqual:@"recover-only-this-id"],@"restart targets only the selected service ID");finishRestart=[done copy];};
            recoveryProbe.onActivateService=^(NSDictionary *source,void (^done)(NSError *)){activations++;done(nil);};
            [recoveryProbe restartCurrentService];[recoveryProbe restartCurrentService];check(restarts==1,@"repeated restart taps cannot create duplicate recovery operations");
            [recoveryProbe invalidateServiceIdentifier:@"recover-only-this-id"];finishRestart(nil);finishRestart=nil;
            check(activations==0&&![[recoveryProbe valueForKey:@"restartInProgress"] boolValue],@"a cancelled recovery completion cannot reactivate an invalidated source");
            LocalServiceReadiness *cancelledProbe=[[LocalServiceReadiness alloc] initWithURL:[NSURL URLWithString:@"http://127.0.0.1:1/health"] timeout:1 requiresHealthJSON:YES];
            [cancelledProbe start:^(NSError *error,NSTimeInterval elapsed){check(NO,@"cancelled health probe must not deliver a completion");}];[cancelledProbe cancelWithReason:@"smoke_backgrounded"];check(cancelledProbe.attemptCount==1,@"health cancellation retains its actual attempt count");
            MediaPlaybackViewController *outcomeProbe=[MediaPlaybackViewController new];outcomeProbe.result=@{@"url":@"https://fixture.test/video.m3u8"};outcomeProbe.context=@{@"source":@{@"id":@"diagnostic-fixture"}};[outcomeProbe setValue:NSUUID.UUID.UUIDString forKey:@"playbackAttemptID"];
            [outcomeProbe recordPlaybackAttemptOutcome:@"failed" failureKind:@"media_not_found" httpStatus:404 terminal:YES];[outcomeProbe recordPlaybackAttemptOutcome:@"screen_closed" failureKind:nil httpStatus:0 terminal:YES];
            NSDictionary *marker=[RuntimeDiagnostics.shared readSessionMarker];check([marker[@"last_playback_outcome"] isEqual:@"failed"]&&[marker[@"last_playback_failure_kind"] isEqual:@"media_not_found"]&&[marker[@"last_playback_http_status"] integerValue]==404,@"closing a failed playback preserves its terminal failure evidence");
            [nav popToRootViewControllerAnimated:NO];
            [root selectBottomTab:(id)tabs.arrangedSubviews[4]];
            [root.view layoutIfNeeded];
          },
          @{@"until":^BOOL{
                SettingsViewController *settings=(id)[root valueForKey:@"tabPage"];
                return nav.topViewController==root&&settings&&settings.view.window==self.window;
              }, @"run":^{
            SettingsViewController *settings=(id)[root valueForKey:@"tabPage"];
            UITableView *settingsTable=[settings valueForKey:@"table"];
            [settingsTable layoutIfNeeded];
            UITableViewCell *themeCell=[settingsTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            UISegmentedControl *theme=(id)themeCell.accessoryView;
            check(settings.view.window==self.window, @"settings selector is attached to the visible app window");
            check(theme!=nil&&[theme.accessibilityIdentifier isEqualToString:HostThemeModePreferenceKey], @"settings exposes the persisted system/light/dark theme selector");
            if(theme){
                theme.selectedSegmentIndex=1;
                [theme sendActionsForControlEvents:UIControlEventValueChanged];
            }
            check([HostThemeMode() isEqual:@"light"]&&!HostIsDarkThemeSelected(), @"light theme selection persists in user preferences");
            check(self.window.overrideUserInterfaceStyle==UIUserInterfaceStyleLight, @"light theme selection changes the app window style");
            UIColor *lightBackground=[HostBackground() resolvedColorWithTraitCollection:self.window.traitCollection];
            CGFloat lr=0,lg=0,lb=0,la=0;[lightBackground getRed:&lr green:&lg blue:&lb alpha:&la];
            check(lr>0.8&&lg>0.8&&lb>0.8, @"light theme resolves a light global page background");
            capture(self.window,@"22-global-light-theme");
            if(theme){theme.selectedSegmentIndex=0;[theme sendActionsForControlEvents:UIControlEventValueChanged];}
            check([HostThemeMode() isEqual:@"system"]&&self.window.overrideUserInterfaceStyle==UIUserInterfaceStyleUnspecified, @"system appearance is persisted and leaves appearance control to iOS");
            check(HostIsDarkThemeSelected()==(HostSystemInterfaceStyle()==UIUserInterfaceStyleDark), @"system theme follows the active iOS window appearance");
            if(theme){theme.selectedSegmentIndex=2;[theme sendActionsForControlEvents:UIControlEventValueChanged];}
            check(self.window.overrideUserInterfaceStyle==UIUserInterfaceStyleDark&&[HostThemeMode() isEqual:@"dark"]&&HostIsDarkThemeSelected(), @"dark theme selection restores and persists the dark appearance");
            UIColor *darkBackground=[HostBackground() resolvedColorWithTraitCollection:self.window.traitCollection];
            CGFloat dr=0,dg=0,db=0,da=0;[darkBackground getRed:&dr green:&dg blue:&db alpha:&da];
            check(dr<0.1&&dg<0.1&&db<0.1, @"dark theme resolves a dark global page background");
            capture(self.window,@"23-global-dark-theme");
          }}
      ];
      next(steps, 0);
    });
    return ok;
}
@end
