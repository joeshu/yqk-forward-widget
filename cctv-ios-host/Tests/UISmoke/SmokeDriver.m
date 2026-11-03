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
#import <AVKit/AVKit.h>
#import <objc/runtime.h>

@interface MediaBrowserViewController (UISmokeLayoutHooks)
- (void)addHomeCards:(NSArray<UIButton *> *)cards emptyText:(NSString *)emptyText identifier:(NSString *)identifier;
- (void)showMessage:(NSString *)message loading:(BOOL)loading;
- (void)openHomeConfiguration;
@end

@interface RootViewController (Smoke)
- (void)selectBottomTab:(UIButton *)button;
- (void)openServicesPage;
- (void)openDiagnosticLogForIdentifier:(NSString *)identifier name:(NSString *)name;
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name;
- (void)applyFilter;
- (void)selectChannel:(NSDictionary *)channel;
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath;
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
- (void)toggleCatalogColumns;
- (void)toggleCatalogLayout;
- (void)importPlaylistData:(NSData *)data name:(NSString *)name;
- (void)previewChannel:(NSDictionary *)channel;
- (void)stopPreview;
- (NSDictionary *)channelWithID:(NSString *)identifier;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
- (void)player:(id)player playbackFailed:(NSError *)error;
- (void)playMediaResult:(NSDictionary *)result name:(NSString *)name;
- (void)addSubscription;
- (NSIndexPath *)indexPathForChannelID:(NSString *)channelID;
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
- (void)updatePlaybackLayoutForSize:(CGSize)size;
- (void)setPlaybackRate:(double)rate;
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
static UIView *SmokeViewWithAccessibilityIdentifier(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *match=SmokeViewWithAccessibilityIdentifier(child,identifier);
        if (match) return match;
    }
    return nil;
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
    [NSUserDefaults.standardUserDefaults setInteger:4 forKey:@"cctv.channelGridColumns.v1"];
    [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"cctv.mediaGridColumns.v1"];
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
      __block UIImageView *logoA, *logoB, *staleLogo, *preservedLogo, *oversizeLogo;
      __block NSDictionary *imageStats;
      __block NSDictionary *nodeChecks;
      __block MediaBrowserViewController *mediaPage;
      __block NSString *mediaSourceID;
      __block BOOL catalogSiteSelectedFromMediaSelector=NO;
      __block UICollectionViewCell *selectedLiveCard;
      __block UIImageView *selectedLiveMark;
      __block MediaGlobalSearchViewController *searchPage;
      __block CGPoint searchReturnOffset;
      __block id staleSearchJob;
      __block NSString *selectedSearchID;
      __block NSDate *staleSearchDeadline;
      __block UIViewController *mediaDetail;
      __block UIViewController *navigationProbe;
      __block CGFloat resourceScrollOffset=0;
      __block NSArray<NSDictionary *> *(^resourceProfilesProvider)(void);
      __block MediaEpisodeSelectionViewController *mediaEpisodes;
      __block MediaPlaybackViewController *mediaPlayback;
      __block NSDate *stalePlaybackDeadline;
      NSArray *steps = @[
          ^{
            UICollectionView *grid = [root valueForKey:@"channelGrid"];
            check([grid numberOfItemsInSection:0] > 20, @"home catalog populated");
            check(!grid.hidden, @"grid visible by default");
            CGFloat expectedGridTop=root.view.safeAreaInsets.top+42;
            check(fabs(CGRectGetMinY(grid.frame))<1.5&&grid.contentInset.top>=expectedGridTop&&fabs(grid.contentOffset.y+grid.contentInset.top)<1.5,[NSString stringWithFormat:@"live grid extends behind the top controls and starts content below the safe area (inset=%.1f expected=%.1f)",grid.contentInset.top,expectedGridTop]);
            check(CGRectGetMaxY(grid.frame)>=CGRectGetHeight(root.view.bounds)-1&&grid.contentInset.bottom>=CGRectGetHeight(root.view.bounds)-CGRectGetMinY(tabs.frame)+7,@"live grid scrolls under the transparent bottom navigation while keeping its last row reachable");
            capture(self.window, @"01-live-grid");
            check(root.navigationItem.leftBarButtonItem==nil&&root.navigationItem.rightBarButtonItems.count==0,@"CCTV catalog keeps page actions out of the top navigation bar");
            UIView *floating=(id)[root valueForKey:@"catalogFloatingControls"];
            UIButton *layoutButton=(id)[root valueForKey:@"catalogLayoutButton"];
            AVRoutePickerView *airplay=(id)[root valueForKey:@"catalogFloatingAirPlayPicker"];
            UIButton *moreButton=(id)[root valueForKey:@"catalogMoreButton"];
            check(floating&&!floating.hidden&&[floating.accessibilityIdentifier isEqual:@"channel.catalog.floating-controls"]&&[layoutButton.accessibilityIdentifier isEqual:@"channel.catalog.layout.toggle"]&&[airplay.accessibilityIdentifier isEqual:@"channel.catalog.airplay"]&&[moreButton.accessibilityIdentifier isEqual:@"channel.catalog.more"],@"CCTV catalog exposes layout, AirPlay and more controls in the floating group");
            CGRect floatingFrame=floating.frame;
            check(CGRectGetMaxX(floatingFrame)<=CGRectGetWidth(root.view.bounds)-root.view.safeAreaInsets.right-12&&CGRectGetMaxY(floatingFrame)<=CGRectGetMinY(tabs.frame)-8&&CGRectGetMinY(floatingFrame)>CGRectGetMinY(tabs.frame)-90,@"catalog action group floats at the lower right above the tab bar");
            check([layoutButton.accessibilityLabel isEqual:@"切换列表布局"],@"grid floating control clearly offers the live list-row layout");
            UIAction *columnsAction=nil;for(id child in moreButton.menu.children)if([child isKindOfClass:UIAction.class]&&[((UIAction *)child).identifier isEqual:@"channel.grid.columns.toggle"]){columnsAction=child;break;}
            check(columnsAction!=nil&&[columnsAction.title containsString:@"每行 4 列"],@"catalog more menu exposes the current four-column density action");
            [root toggleCatalogColumns];
            NSInteger columns=[[root valueForKey:@"gridColumns"] integerValue];
            CGSize threeColumnSize=[(id<UICollectionViewDelegateFlowLayout>)root collectionView:grid layout:grid.collectionViewLayout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
            CGFloat expectedThreeColumnWidth=floor((grid.bounds.size.width-20-2*6)/3);
            check(columns==3&&[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelGridColumns.v1"]==3&&fabs(threeColumnSize.width-expectedThreeColumnWidth)<1.0,@"density control switches to and persists exactly three compact columns");
            moreButton=(id)[root valueForKey:@"catalogMoreButton"];columnsAction=nil;for(id child in moreButton.menu.children)if([child isKindOfClass:UIAction.class]&&[((UIAction *)child).identifier isEqual:@"channel.grid.columns.toggle"]){columnsAction=child;break;}
            [root toggleCatalogColumns];
            CGSize fourColumnSize=[(id<UICollectionViewDelegateFlowLayout>)root collectionView:grid layout:grid.collectionViewLayout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
            CGFloat expectedFourColumnWidth=floor((grid.bounds.size.width-20-3*6)/4);
            check([[root valueForKey:@"gridColumns"] integerValue]==4&&[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.channelGridColumns.v1"]==4&&fabs(fourColumnSize.width-expectedFourColumnWidth)<1.0,@"density control restores four columns and persists the shared catalog setting");
            [layoutButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            [root.view layoutIfNeeded];
            UITableView *liveList=[root valueForKey:@"table"];
            check(!liveList.hidden&&grid.hidden,@"layout action opens live channels as a vertical list");
            NSIndexPath *liveRow=[liveList numberOfRowsInSection:0]>0?[NSIndexPath indexPathForRow:0 inSection:0]:nil;
            UITableViewCell *liveCell=liveRow?[liveList cellForRowAtIndexPath:liveRow]:nil;
            check(liveCell.textLabel.text.length>0&&liveCell.detailTextLabel.text.length>0&&liveCell.accessoryType==UITableViewCellAccessoryDisclosureIndicator,@"live list row shows channel name, secondary details and a clear play affordance");
            NSIndexPath *cctv1LogoPath=[root indexPathForChannelID:@"cctv1"],*cctv2LogoPath=[root indexPathForChannelID:@"cctv2"];
            UITableViewCell *cctv1LogoCell=cctv1LogoPath?[root tableView:liveList cellForRowAtIndexPath:cctv1LogoPath]:nil,*cctv2LogoCell=cctv2LogoPath?[root tableView:liveList cellForRowAtIndexPath:cctv2LogoPath]:nil;
            check([cctv1LogoCell.imageView.accessibilityIdentifier isEqual:@"channel-logo:cctv1"]&&[cctv2LogoCell.imageView.accessibilityIdentifier isEqual:@"channel-logo:cctv2"]&&cctv1LogoCell.imageView.image&&cctv2LogoCell.imageView.image,@"CCTV list rows display each station's own bundled logo instead of repeating the generic broadcast glyph");
            [liveCell layoutIfNeeded];CGRect channelLogoFrame=liveCell.imageView.frame;UIImageView *playerLogo=[root valueForKey:@"playerChannelLogo"];check(channelLogoFrame.size.width>=55&&channelLogoFrame.size.width<=56.5&&channelLogoFrame.size.height>=35&&channelLogoFrame.size.height<=36.5&&playerLogo.frame.size.width>=47&&playerLogo.frame.size.width<=48.5&&playerLogo.frame.size.height>=26&&playerLogo.frame.size.height<=27.5,[NSString stringWithFormat:@"channel list and player logos stay within compact bounds (list=%.1fx%.1f player=%.1fx%.1f)",channelLogoFrame.size.width,channelLogoFrame.size.height,playerLogo.frame.size.width,playerLogo.frame.size.height]);
            capture(self.window,@"01-live-list");
            check([layoutButton.accessibilityLabel isEqual:@"切换网格布局"],@"list floating control offers the reverse grid-layout action");
            [layoutButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            [root.view layoutIfNeeded];
            check(liveList.hidden&&!grid.hidden,@"switching back restores the live grid");

            check(tabs.arrangedSubviews.count==5, @"five navigation pages");
            UIButton *activeTab=(UIButton *)tabs.arrangedSubviews[0];UIView *tabBackdrop=[root valueForKey:@"bottomBarBackdrop"];CGFloat expectedTabTop=CGRectGetHeight(root.view.bounds)-root.view.safeAreaInsets.bottom-58;check([activeTab.accessibilityValue isEqual:@"已选中"]&&(activeTab.accessibilityTraits&UIAccessibilityTraitSelected)!=0,[NSString stringWithFormat:@"bottom navigation marks its active page for accessibility (value=%@)",activeTab.accessibilityValue?:@""]);UIView *channelTable=[root valueForKey:@"table"];check([tabBackdrop.backgroundColor isEqual:UIColor.clearColor]&&!tabBackdrop.isOpaque&&fabs(CGRectGetMinX(tabs.frame))<1&&fabs(CGRectGetWidth(tabs.frame)-CGRectGetWidth(root.view.bounds))<1&&fabs(CGRectGetMinY(tabs.frame)-expectedTabTop)<1.5&&CGRectGetMaxY(tabBackdrop.frame)>=CGRectGetHeight(root.view.bounds)-1&&CGRectGetMaxY(channelTable.frame)>=CGRectGetHeight(root.view.bounds)-1, @"five-tab navigation stays fully transparent over content that extends behind it");
            NSString *source=@"https://example.com/smoke.m3u";
            NSDictionary *remote=@{@"id":@"remote-smoke",@"name":@"CCTV-1 M3U8",@"group":@"央视",@"remoteURL":@"https://example.com/live.m3u8",@"subscriptionSources":@[source]};
            NSArray *original=[root valueForKey:@"allChannels"];
            [root setValue:[original arrayByAddingObject:remote] forKey:@"allChannels"];
            [root applyFilter];
            for(NSDictionary *c in [root valueForKey:@"shownChannels"])
                check(![c[@"remoteURL"] length], @"CCTV page excludes subscription channels even with CCTV names");
            [root selectBottomTab:(id)tabs.arrangedSubviews[1]];
            [root.view layoutIfNeeded];
            NSArray *subscriptionRows=[root valueForKey:@"shownChannels"];
            check(subscriptionRows.count==1&&[subscriptionRows.firstObject[@"id"] isEqualToString:@"remote-smoke"], @"channel page contains only subscription entries");
            check([root.title isEqualToString:@"频道"], @"subscription page has its own navigation title");
            check(fabs(CGRectGetMinY(grid.frame))<1.5&&grid.contentInset.top>=root.view.safeAreaInsets.top+42&&fabs(grid.contentOffset.y+grid.contentInset.top)<1.5,@"channel catalog extends behind the native navigation while keeping rows below safe-area controls");
            UIView *channelFloating=(id)[root valueForKey:@"catalogFloatingControls"];AVRoutePickerView *channelAirplay=(id)[root valueForKey:@"catalogFloatingAirPlayPicker"];
            check(!channelFloating.hidden&&[channelAirplay.accessibilityIdentifier isEqual:@"channel.catalog.airplay"]&&root.navigationItem.rightBarButtonItems.count==0,@"subscription channel page keeps AirPlay and catalog actions at the lower right");
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
            CGFloat expectedMediaOverlayInset=MAX(8,CGRectGetHeight(root.view.bounds)-CGRectGetMinY(tabs.frame)+8);CGFloat actualMediaOverlayInset=[[mediaHome valueForKey:@"bottomOverlayInset"] doubleValue];check(fabs(actualMediaOverlayInset-expectedMediaOverlayInset)<1.5,[NSString stringWithFormat:@"root passes the tab overlay inset to the media page (actual=%.1f expected=%.1f)",actualMediaOverlayInset,expectedMediaOverlayInset]);[mediaHome setValue:@(actualMediaOverlayInset) forKey:@"bottomOverlayInset"];
            check([mediaHome isKindOfClass:MediaBrowserViewController.class]&&mediaHome.isHomeMode&&root.title.length==0, @"media tab opens the compact untitled home");
            check(mediaHome!=nil, @"media page embedded");
            check(nav.delegate==root&&nav.navigationBarHidden,@"navigation bar is hidden only while the home tab is visible");
            [mediaHome.view layoutIfNeeded];UIStackView *homeSelectors=[mediaHome valueForKey:@"selectionRow"];UIButton *homeSource=(id)[mediaHome valueForKey:@"sourceSelectButton"];UIButton *homeProvider=(id)[mediaHome valueForKey:@"providerSelectButton"];UIButton *homeMenu=(id)[mediaHome valueForKey:@"homeMenuButton"];UIButton *homeMode=(id)[mediaHome valueForKey:@"homeModeButton"];UIButton *homeSearch=(id)[mediaHome valueForKey:@"homeSearchButton"];UIScrollView *homeScroll=(id)[mediaHome valueForKey:@"homeScroll"];CGFloat safeTop=mediaHome.view.safeAreaInsets.top+4;check(fabs(CGRectGetMinY(homeSelectors.frame)-safeTop)<1.5&&fabs(CGRectGetMinX(homeSelectors.frame)-14)<1.5&&fabs(CGRectGetMaxX(homeSelectors.frame)-(CGRectGetWidth(mediaHome.view.bounds)-14))<1.5&&fabs(homeSelectors.spacing-10)<0.1,@"home selectors align 4 pt below the safe area with compact 10 pt spacing");BOOL selectorsAccessible=homeSource.isAccessibilityElement&&homeProvider.isAccessibilityElement;BOOL menuAccessible=[homeMenu.accessibilityLabel isEqual:@"更多影视操作"]&&homeMenu.menu.children.count==9;check(selectorsAccessible&&menuAccessible,@"home exposes accessible selectors and preserves all nine home menu actions");CGRect menuInRoot=[mediaHome.view convertRect:homeMenu.frame toView:root.view];check(CGRectGetMinY(homeMode.frame)==CGRectGetMinY(homeMenu.frame)&&CGRectGetMinY(homeSearch.frame)==CGRectGetMinY(homeMenu.frame)&&CGRectGetMaxY(menuInRoot)<CGRectGetMinY(tabs.frame)-8,@"library, search and menu tools share the compact top toolbar above bottom navigation");check(homeSource.titleLabel.lineBreakMode==NSLineBreakByTruncatingTail&&homeSource.accessibilityLabel.length>0&&homeScroll.contentInset.bottom>=CGRectGetHeight(root.view.bounds)-CGRectGetMinY(tabs.frame)+7,@"top selector labels remain accessible and the discovery feed scrolls behind navigation with a safe bottom inset");
            UIButton *modeButton=[mediaHome valueForKey:@"homeModeButton"];[modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(!mediaHome.isHomeMode&&!nav.navigationBarHidden&&homeMenu.hidden&&homeSearch.hidden,@"opening the media library restores navigation and hides home-only tools");[modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaHome.isHomeMode&&nav.navigationBarHidden&&!homeMenu.hidden&&!homeSearch.hidden,@"returning from the library hides navigation and restores home tools");
            [modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];[mediaHome.view layoutIfNeeded];UICollectionView *libraryGrid=[mediaHome valueForKey:@"grid"];NSInteger savedHomeColumns=[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.mediaGridColumns.v1"];for(NSNumber *homeColumns in @[@3,@4]){[NSUserDefaults.standardUserDefaults setInteger:homeColumns.integerValue forKey:@"cctv.mediaGridColumns.v1"];CGSize libraryCard=[(id<UICollectionViewDelegateFlowLayout>)mediaHome collectionView:libraryGrid layout:libraryGrid.collectionViewLayout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];CGFloat expectedLibraryWidth=floor((CGRectGetWidth(libraryGrid.bounds)-28-20)/3);check(fabs(libraryCard.width-expectedLibraryWidth)<1,[NSString stringWithFormat:@"media library remains three columns when the home poster setting is %@ (card width %.1f expected %.1f)",homeColumns,libraryCard.width,expectedLibraryWidth]);}[NSUserDefaults.standardUserDefaults setInteger:savedHomeColumns forKey:@"cctv.mediaGridColumns.v1"];[modeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            navigationProbe=[UIViewController new];navigationProbe.title=@"交互返回取消测试";[nav pushViewController:navigationProbe animated:NO];
          },
          @{ @"timeout":@8, @"until":^BOOL{return nav.topViewController==navigationProbe&&!nav.navigationBarHidden;}, @"run":^{check(nav.topViewController==navigationProbe&&!nav.navigationBarHidden,@"pushing a detail page restores the navigation bar");[(id)root navigationController:nav didShowViewController:navigationProbe animated:YES];check(!nav.navigationBarHidden,@"a cancelled interactive return keeps the visible detail navigation bar restored");[nav popViewControllerAnimated:NO];} },
          @{ @"timeout":@8, @"until":^BOOL{return nav.topViewController==root&&nav.navigationBarHidden;}, @"run":^{check(nav.topViewController==root&&nav.navigationBarHidden,@"a completed return to the media home hides the navigation bar");check([[root valueForKey:@"channelGrid"] isHidden], @"media page hides live channel grid");capture(self.window, @"02-media");[root selectBottomTab:(id)tabs.arrangedSubviews[3]];UIButton *resourceActions=[root valueForKey:@"resourceActionsButton"];ConfigCenterViewController *resourcePage=(id)[root valueForKey:@"tabPage"];UIStackView *toolbar=[resourcePage valueForKey:@"topActionsStack"];UIButton *more=toolbar.arrangedSubviews.lastObject;UILabel *title=[resourcePage valueForKey:@"resourceTitleLabel"];UITextField *search=[resourcePage valueForKey:@"resourceSearchField"];check(nav.navigationBarHidden,@"resource tab keeps the title/navigation region hidden");check(root.title.length==0,@"resource tab has no large title");check(resourcePage.view.frame.origin.y==0,@"resource page keeps a stable full-root origin while navigation visibility changes");[root.view layoutIfNeeded];[resourcePage.view layoutIfNeeded];CGFloat toolbarTop=CGRectGetMinY(toolbar.frame),rootSafeTop=root.view.window.safeAreaInsets.top;check(fabs(toolbarTop-rootSafeTop-4)<1.5,[NSString stringWithFormat:@"resource toolbar remains 4 pt below the window safe area after return (toolbar=%.1f safe=%.1f)",toolbarTop,rootSafeTop]);check(fabs(CGRectGetMaxY(resourcePage.view.frame)-CGRectGetHeight(root.view.bounds))<1.5&&resourcePage.tableView.contentInset.bottom>=CGRectGetHeight(root.view.bounds)-CGRectGetMinY(tabs.frame)+7,@"resource page scrolls behind the transparent tab overlay while reserving room for the final row");check(resourceActions.hidden&&toolbar.arrangedSubviews.count==5&&more.menu.children.count==3,@"resource page exposes its five-button toolbar and additional services menu");check([title.text isEqual:@"资源"]&&[search.placeholder isEqual:@"搜索资源"],@"resource page shows its title and inline search field");check(resourcePage.navigationItem.searchController==nil,@"resource page uses inline search rather than a navigation search controller");} },
          ^{
            check([[root valueForKey:@"tabPage"]
                      isKindOfClass:NSClassFromString(@"ConfigCenterViewController")],
                  @"configuration tab embedded");
            UIStackView *resourceFilters=[[root valueForKey:@"tabPage"] valueForKey:@"kindStack"];
            check(resourceFilters.arrangedSubviews.count>=6, @"resources page exposes counted type filters and dynamic source-domain filters");
            capture(self.window, @"03-configuration");
            ConfigCenterViewController *resourcePage=(id)[root valueForKey:@"tabPage"];
            resourceProfilesProvider=resourcePage.profilesProvider;
            NSArray<NSDictionary *> *(^originalProvider)(void)=resourceProfilesProvider;
            resourcePage.profilesProvider=^NSArray<NSDictionary *> *{
                NSMutableArray<NSDictionary *> *profiles=[NSMutableArray arrayWithArray:originalProvider?originalProvider():@[]];
                for(NSUInteger index=0;index<12;index++){
                    [profiles addObject:@{@"name":[NSString stringWithFormat:@"UI Smoke Resource %02lu",(unsigned long)index+1],@"type":@"subscription",@"source":[NSString stringWithFormat:@"https://example.test/smoke-%lu.m3u",(unsigned long)index+1],@"count":@12,@"epgStatus":@"自动匹配",@"enabled":@NO}];
                }
                NSString *longEndpoint=[@"https://example.test/long-resource/" stringByPaddingToLength:420 withString:@"segment/" startingAtIndex:0];
                [profiles addObject:@{@"name":@"",@"type":@"subscription",@"source":longEndpoint,@"count":@63,@"epgStatus":@"已配置",@"enabled":@NO,@"status":@"HTTP 健康状态正常 · 最近成功 11-01 16:27"}];
                return profiles;
            };
            [resourcePage setValue:@"" forKey:@"searchQuery"];
            [resourcePage setValue:@"all" forKey:@"selectedKind"];
            [resourcePage reloadProfiles];
            [resourcePage.tableView layoutIfNeeded];
            NSArray<NSDictionary *> *resourceItems=[resourcePage valueForKey:@"profiles"];
            NSUInteger longResourceIndex=[resourceItems indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger index,BOOL *stop){return [item[@"source"] hasPrefix:@"https://example.test/long-resource/"];}];
            BOOL longResourceFits=NO,resourceFieldsVisible=NO;NSString *longResourceTitle=@"";CGFloat longResourceRowHeight=0;
            if(longResourceIndex!=NSNotFound){NSIndexPath *longResourcePath=[NSIndexPath indexPathForRow:(NSInteger)longResourceIndex inSection:0];[resourcePage.tableView scrollToRowAtIndexPath:longResourcePath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];[resourcePage.tableView layoutIfNeeded];UITableViewCell *longCell=[resourcePage.tableView cellForRowAtIndexPath:longResourcePath];CGRect longRow=[resourcePage.tableView rectForRowAtIndexPath:longResourcePath];CGRect titleRect=[longCell.textLabel convertRect:longCell.textLabel.bounds toView:resourcePage.tableView],detailRect=[longCell.detailTextLabel convertRect:longCell.detailTextLabel.bounds toView:resourcePage.tableView];NSString *summary=longCell.detailTextLabel.text?:@"";longResourceFits=CGRectGetMinY(titleRect)>=CGRectGetMinY(longRow)-1&&CGRectGetMaxY(detailRect)<=CGRectGetMaxY(longRow)+1;longResourceTitle=longCell.textLabel.text?:@"";longResourceRowHeight=CGRectGetHeight(longRow);resourceFieldsVisible=[summary containsString:@"63 个频道"]&&[summary containsString:@"EPG 已配置"]&&[summary containsString:@"https://example.test/long-resource/"]&&[summary containsString:@"最近成功"]&&[summary containsString:@"HTTP 健康状态正常"];}
            check(longResourceIndex!=NSNotFound&&longResourceFits&&longResourceRowHeight>=112&&resourceFieldsVisible&&[longResourceTitle isEqual:@"example.test"],[NSString stringWithFormat:@"resource rows preserve count, EPG, endpoint, refresh time and health within a padded expanded row (index=%lu title=%@ height=%.1f fits=%d fields=%d)",(unsigned long)longResourceIndex,longResourceTitle,longResourceRowHeight,longResourceFits,resourceFieldsVisible]);
            if(longResourceIndex!=NSNotFound){UITableViewCell *longCell=[resourcePage.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)longResourceIndex inSection:0]];check(longCell.detailTextLabel.numberOfLines==0&&CGRectGetHeight(longCell.detailTextLabel.bounds)>=longCell.detailTextLabel.font.lineHeight*3,[NSString stringWithFormat:@"expanded resource row keeps multiple detail lines visible (lines=%.1f)",CGRectGetHeight(longCell.detailTextLabel.bounds)/longCell.detailTextLabel.font.lineHeight]);}
            CGFloat resourceMaximumOffset=MAX(-resourcePage.tableView.adjustedContentInset.top,resourcePage.tableView.contentSize.height-resourcePage.tableView.bounds.size.height+resourcePage.tableView.adjustedContentInset.bottom);
            check(resourceMaximumOffset>=48,[NSString stringWithFormat:@"resource navigation fixture has a legal scroll range (max=%.1f)",resourceMaximumOffset]);
            [resourcePage.tableView setContentOffset:CGPointMake(0,48) animated:NO];
            resourceScrollOffset=resourcePage.tableView.contentOffset.y;
            [root addSubscription];
          },
          ^{
            ResourceImportSheetViewController *sheet=(id)nav.presentedViewController;
            check([sheet isKindOfClass:ResourceImportSheetViewController.class], @"resource add opens the grouped import sheet");
            UITableView *options=[sheet valueForKey:@"tableView"];
            check([options numberOfSections]==3 && [options numberOfRowsInSection:0]==1 && [options numberOfRowsInSection:1]==7 && [options numberOfRowsInSection:2]==7,
                  @"resource sheet exposes only implemented service, TVBox, script, playlist, folder, local-file and capability-guide actions");
            capture(self.window, @"03b-add-resource");
            [sheet dismissViewControllerAnimated:NO completion:nil];
            [root openServicesPage];
          },
          ^{
            check([nav.topViewController isKindOfClass:ServicesViewController.class],
                  @"service directory opened");
            ConfigCenterViewController *resourcePage=(id)[root valueForKey:@"tabPages"][@3];
            CGPoint capturedOffset=[[resourcePage valueForKey:@"navigationReturnContentOffset"] CGPointValue];
            check([[resourcePage valueForKey:@"hasNavigationReturnPosition"] boolValue]&&fabs(capturedOffset.y-resourceScrollOffset)<1.5,
                  @"resource source action snapshots its scroll position before navigation changes the layout");
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
          },
          ^{
            ConfigCenterViewController *resourcePage=(id)[root valueForKey:@"tabPage"];
            check(nav.topViewController==root&&nav.navigationBarHidden&&[resourcePage isKindOfClass:ConfigCenterViewController.class],@"returning from service editing restores the resource page and its hidden navigation bar");
            UIStackView *filters=[resourcePage valueForKey:@"kindStack"];
            CGFloat returnedOffset=resourcePage.tableView.contentOffset.y;
            CGFloat minimumOffset=-resourcePage.tableView.adjustedContentInset.top;
            CGFloat maximumOffset=MAX(minimumOffset,resourcePage.tableView.contentSize.height-resourcePage.tableView.bounds.size.height+resourcePage.tableView.adjustedContentInset.bottom);
            CGFloat savedHeaderHeight=[[resourcePage valueForKey:@"navigationReturnHeaderHeight"] doubleValue];
            CGFloat currentHeaderHeight=CGRectGetHeight(resourcePage.tableView.tableHeaderView.frame);
            BOOL returnSnapshotPending=[[resourcePage valueForKey:@"hasNavigationReturnPosition"] boolValue];
            check(fabs(returnedOffset-resourceScrollOffset)<1.5,[NSString stringWithFormat:@"resource scroll position survives service/editor round trip (before=%.1f after=%.1f pending=%d savedHeader=%.1f currentHeader=%.1f content=%.1f viewport=%.1f bottomInset=%.1f max=%.1f)",resourceScrollOffset,returnedOffset,returnSnapshotPending,savedHeaderHeight,currentHeaderHeight,resourcePage.tableView.contentSize.height,resourcePage.tableView.bounds.size.height,resourcePage.tableView.adjustedContentInset.bottom,maximumOffset]);
            resourcePage.profilesProvider=resourceProfilesProvider;
            [resourcePage reloadProfiles];
            NSArray<UIView *> *filterInstances=[filters.arrangedSubviews copy];
            [resourcePage reloadProfiles];
            [resourcePage.view layoutIfNeeded];
            [resourcePage.tableView layoutIfNeeded];
            [resourcePage refreshHeaderAfterNavigationTransition];
            CGRect toolbarFrame=[(UIStackView *)[resourcePage valueForKey:@"topActionsStack"] frame];
            CGFloat safeTop=root.view.window.safeAreaInsets.top;
            check(fabs(CGRectGetMinY(toolbarFrame)-safeTop-4)<1.5&&fabs(CGRectGetWidth(resourcePage.tableView.tableHeaderView.frame)-CGRectGetWidth(resourcePage.tableView.bounds))<1.5,[NSString stringWithFormat:@"resource header is reattached 4 pt below the safe area with the current table width (top=%.1f safe=%.1f width=%.1f/%.1f)",CGRectGetMinY(toolbarFrame),safeTop,CGRectGetWidth(resourcePage.tableView.tableHeaderView.frame),CGRectGetWidth(resourcePage.tableView.bounds)]);
            UIScrollView *filterScroll=[resourcePage valueForKey:@"kindScroll"];
            CGRect filtersInHeader=[filterScroll convertRect:filterScroll.bounds toView:resourcePage.tableView.tableHeaderView];
            check(CGRectGetMinY(filtersInHeader)>=0&&CGRectGetMaxY(filtersInHeader)<=CGRectGetHeight(resourcePage.tableView.tableHeaderView.frame)+1,[NSString stringWithFormat:@"resource category filters stay inside the measured header after return (filters=%@ header=%.1f)",NSStringFromCGRect(filtersInHeader),CGRectGetHeight(resourcePage.tableView.tableHeaderView.frame)]);
            BOOL filtersStable=filterInstances.count>=6&&filters.arrangedSubviews.count==filterInstances.count;
            for(NSUInteger index=0;filtersStable&&index<filterInstances.count;index++)filtersStable=filters.arrangedSubviews[index]==filterInstances[index];
            check(filtersStable,@"resource filter controls keep the same views across repeated refreshes");
            check(resourcePage.tableView.estimatedRowHeight==0&&resourcePage.tableView.estimatedSectionHeaderHeight==0,@"resource list measures variable-height rows and summary headers without estimates");
            CGRect headerFrame=resourcePage.tableView.tableHeaderView.frame;
            NSIndexPath *firstResource=[resourcePage.tableView numberOfRowsInSection:0]>0? [NSIndexPath indexPathForRow:0 inSection:0]:nil;
            CGRect firstRow=firstResource?[resourcePage.tableView rectForRowAtIndexPath:firstResource]:CGRectZero;
            check(!firstResource||CGRectGetMinY(firstRow)>=CGRectGetMaxY(headerFrame),@"resource rows begin after the measured top header without overlap");
            CGFloat largestRowGap=0;BOOL resourceRowsOrdered=YES;
            for(NSInteger row=1;row<[resourcePage.tableView numberOfRowsInSection:0];row++){
                CGRect previous=[resourcePage.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row-1 inSection:0]];
                CGRect current=[resourcePage.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
                CGFloat gap=CGRectGetMinY(current)-CGRectGetMaxY(previous);
                largestRowGap=MAX(largestRowGap,gap);
                if(gap < -0.5)resourceRowsOrdered=NO;
            }
            check(resourceRowsOrdered&&largestRowGap<20,@"resource rows stay ordered without large scroll-layout gaps");
            [resourcePage.tableView setContentOffset:CGPointZero animated:NO];
            [resourcePage.tableView layoutIfNeeded];
            capture(self.window,@"04b-resource-return");
            [root selectBottomTab:(id)tabs.arrangedSubviews[4]];
          },
          ^{
            capture(self.window, @"07-settings");
            SettingsViewController *settingsPage=(id)[root valueForKey:@"tabPage"];[settingsPage.view layoutIfNeeded];UITableView *settingsTable=[settingsPage valueForKey:@"table"];CGFloat expectedSettingsTop=settingsPage.view.safeAreaInsets.top;
            check(!nav.navigationBarHidden&&fabs(settingsTable.contentInset.top-expectedSettingsTop)<1.5&&fabs(settingsTable.contentOffset.y+expectedSettingsTop)<1.5,@"settings table content begins at its native navigation safe area without a reserved blank band");
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
            check([root.title isEqual:@"CCTV-1 综合"], @"expanded live player promotes the playing channel into the navigation title");UIView *livePlayerBox=[root valueForKey:@"playerBox"];UILabel *livePlayerTitle=[root valueForKey:@"titleLabel"];check(fabs(CGRectGetMinY(livePlayerBox.frame))<1&&CGRectGetHeight(livePlayerBox.frame)>root.view.safeAreaInsets.top&&fabs(CGRectGetMinY(livePlayerTitle.frame)-root.view.safeAreaInsets.top-8)<1.5,@"expanded live video reaches behind the status bar while its title stays in the safe area");
            NSArray *shown=[root valueForKey:@"shownChannels"];NSUInteger selectedIndex=NSNotFound;for(NSUInteger index=0;index<shown.count;index++)if([shown[index][@"id"] isEqual:@"cctv1"]){selectedIndex=index;break;}UICollectionView *grid=[root valueForKey:@"channelGrid"];NSIndexPath *selectedPath=selectedIndex==NSNotFound?nil:[NSIndexPath indexPathForItem:selectedIndex inSection:0];if(selectedPath){[grid scrollToItemAtIndexPath:selectedPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];[grid layoutIfNeeded];}selectedLiveCard=selectedPath?[grid cellForItemAtIndexPath:selectedPath]:nil;selectedLiveMark=(id)[selectedLiveCard.contentView viewWithTag:4107];check(selectedLiveCard&&[selectedLiveCard.accessibilityValue isEqual:@"正在播放"]&&selectedLiveMark&&!selectedLiveMark.hidden,[NSString stringWithFormat:@"selected channel remains marked in the compact grid while playing (index=%lu visible=%@)",(unsigned long)selectedIndex,selectedLiveMark&&!selectedLiveMark.hidden?@"yes":@"no"]);UITableView *selectionList=[root valueForKey:@"table"];UITableViewCell *selectedRow=selectedIndex==NSNotFound?nil:[root tableView:selectionList cellForRowAtIndexPath:[NSIndexPath indexPathForRow:selectedIndex inSection:0]];check([selectedRow.accessibilityValue isEqual:@"正在播放"]&&selectedRow.accessoryView&&selectedRow.accessoryType==UITableViewCellAccessoryNone,@"selected channel keeps a persistent playing checkmark in list-row mode");
            UIButton *liveMore=(id)[root valueForKey:@"catalogMoreButton"];
            NSArray *liveActionTitles=[liveMore.menu.children valueForKey:@"title"];
            BOOL hasCurrentFavoriteAction=[liveActionTitles containsObject:@"收藏当前频道"]||[liveActionTitles containsObject:@"取消收藏当前频道"];
            check(hasCurrentFavoriteAction&&[liveActionTitles containsObject:@"播放信息"]&&![(UIView *)[root valueForKey:@"catalogFloatingControls"] isHidden], @"expanded live player exposes favorite and playback info actions through the floating menu");
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
            UICollectionView *failedGrid=(id)[root valueForKey:@"channelGrid"];NSIndexPath *failedSelectionPath=[root indexPathForChannelID:@"cctv1"];if(failedGrid&&failedSelectionPath){[failedGrid scrollToItemAtIndexPath:failedSelectionPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];[failedGrid layoutIfNeeded];selectedLiveCard=[failedGrid cellForItemAtIndexPath:failedSelectionPath];selectedLiveMark=(id)[selectedLiveCard.contentView viewWithTag:4107];}
            check([selectedLiveCard.accessibilityValue isEqual:@"正在播放"]&&selectedLiveMark&&!selectedLiveMark.hidden,@"selected channel marker remains visible through a terminal playback failure and retry state");
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
            logoA=[UIImageView new];logoB=[UIImageView new];staleLogo=[UIImageView new];preservedLogo=[UIImageView new];oversizeLogo=[UIImageView new];
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
            UIImage *visibleLogo=logoA.image;NSString *slowLogoURL=[base stringByAppendingString:@"/slow-logo.png?refresh=1"];preservedLogo.image=visibleLogo;preservedLogo.accessibilityIdentifier=slowLogoURL;[HostImageLoader.shared loadURL:slowLogoURL intoImageView:preservedLogo];
            check(preservedLogo.image==visibleLogo,@"same-channel logo stays visible while an uncached refresh is pending");
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
            NSString *script=@"const fs=require('fs'),http=require('node:http');let server;module.exports={async init(){fs.writeFileSync('owned.txt','start');server=http.createServer((_req,res)=>res.end('node-http-ok'));await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});setInterval(()=>{},100)},home(){return {class:[{type_id:'movie',type_name:'Film'}]}},search(key){const address=server.address();return new Promise((resolve,reject)=>{const request=http.get({host:'127.0.0.1',port:address.port,path:'/'},response=>{let body='';response.setEncoding('utf8');response.on('data',part=>body+=part);response.on('end',()=>resolve({list:[{vod_id:key,vod_name:'Original Node JS'}],httpPort:address.port,httpStatus:response.statusCode,httpBody:body}))});request.on('error',reject)})},detail(ids){return {list:[{vod_id:ids[0]}]}},play(flag,id){return {parse:0,url:'https://fixture.test/'+id}},close(){return new Promise(resolve=>server.close(()=>{fs.appendFileSync('owned.txt','-closed');resolve()}))}}";
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
                NSString *pythonFolder=[[ServiceStore directory] stringByAppendingPathComponent:[@"hostcrypto-smoke-" stringByAppendingString:NSUUID.UUID.UUIDString]];
                [NSFileManager.defaultManager createDirectoryAtPath:pythonFolder withIntermediateDirectories:YES attributes:nil error:NULL];
                NSString *pythonPath=[pythonFolder stringByAppendingPathComponent:@"hostcrypto-smoke.py"];
                NSString *pythonResultPath=[pythonFolder stringByAppendingPathComponent:@"result.json"];
                NSString *pythonRuntimePath=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python/lib/python3.13"];
                BOOL pythonSmokeAvailable=[NSFileManager.defaultManager fileExistsAtPath:pythonRuntimePath];
                NSString *pythonScript=@"import builtins, http.server, json, os, sys, threading, time, hostcrypto\nkey=bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')\niv=bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff')\nplain=bytes(8*1024*1024)\nenc=hostcrypto.AES_CTR(key,iv); encrypted=enc.update(plain); enc.close()\nstart=time.perf_counter(); dec=hostcrypto.AES_CTR(key,iv); restored=dec.update(encrypted); dec.close(); elapsed=(time.perf_counter()-start)*1000\nclass Handler(http.server.BaseHTTPRequestHandler):\n def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'ok')\n def log_message(self,*args): pass\nserver=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)\ndef shutdown(): server.shutdown(); server.server_close(); worker.join(2)\nbuiltins._cctvhost_stop_service=shutdown\nworker=threading.Thread(target=server.serve_forever,daemon=True); worker.start(); server._host_serving.wait(10)\nwith open(sys.argv[1],'w') as result: json.dump({'backend':hostcrypto.backend,'available':hostcrypto.available,'bytes':len(restored),'roundTrip':restored==plain,'elapsedMs':elapsed,'port':server.server_port,'listening':server._host_serving.is_set()},result)\n";
                [pythonScript writeToFile:pythonPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                NSError *pythonStartError=nil;BOOL pythonStarted=pythonSmokeAvailable&&[PyHost startScriptAtPath:pythonPath identifier:@"hostcrypto-ios-smoke" port:0 dataDir:pythonFolder arguments:@[pythonResultPath] error:&pythonStartError];
                NSDate *pythonDeadline=[NSDate dateWithTimeIntervalSinceNow:50];NSDictionary *pythonCrypto=@{};
                while(pythonStarted&&[pythonDeadline timeIntervalSinceNow]>0){NSData *resultData=[NSData dataWithContentsOfFile:pythonResultPath];id result=resultData?[NSJSONSerialization JSONObjectWithData:resultData options:0 error:NULL]:nil;if([result isKindOfClass:NSDictionary.class]){pythonCrypto=result;break;}[NSThread sleepForTimeInterval:.05];}
                NSError *pythonStopError=nil;BOOL pythonStopped=pythonStarted&&[PyHost stopServiceIdentifier:@"hostcrypto-ios-smoke" error:&pythonStopError];
                NSDictionary *checks=@{@"start":start,@"confirmedNodeSessions":confirmedNodeSessions?:@[],@"search":search,@"stop":stop,@"saved":saved?:@"",@"catpaw":catpaw,@"providers":providers,@"catpawStop":catpawStop,@"pythonSmokeAvailable":@(pythonSmokeAvailable),@"pythonStarted":@(pythonStarted),@"pythonStartError":pythonStartError.localizedDescription?:@"",@"pythonCrypto":pythonCrypto,@"pythonStopped":@(pythonStopped),@"pythonStopError":pythonStopError.localizedDescription?:@""};
                [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];dispatch_async(dispatch_get_main_queue(),^{nodeChecks=checks;});
            }});
          }},
          @{@"until":^BOOL{return nodeChecks!=nil;},@"timeout":@70,@"run":^{
            check([nodeChecks[@"start"][@"ok"] boolValue],@"actual Node.js Mobile framework starts on iOS simulator");
            check([nodeChecks[@"start"][@"result"][@"version"] hasPrefix:@"18."],@"Node mobile version is measured from the embedded runtime");
            check([nodeChecks[@"search"][@"result"][@"list"][0][@"vod_id"] isEqual:@"opaque-node-id"],@"original CommonJS executes through native Node bridge");
            check([nodeChecks[@"search"][@"result"][@"httpPort"] integerValue]>0&&[nodeChecks[@"search"][@"result"][@"httpStatus"] integerValue]==200&&[nodeChecks[@"search"][@"result"][@"httpBody"] isEqual:@"node-http-ok"],@"actual Node.js Mobile node:http binds listen(0), returns the assigned loopback port and serves a request");
            check([nodeChecks[@"stop"][@"ok"] boolValue] && !NodePluginRuntime.shared.hasActivePlugin,@"Node plugin closes without destroying the reusable engine");
            check([nodeChecks[@"saved"] isEqual:@"start-closed"],@"plugin relative data path is isolated and close hook finishes");
            check([nodeChecks[@"catpaw"][@"ok"] boolValue],@"original 4 MB Catpaw bundle starts inside actual iOS Node Mobile framework");
            check([nodeChecks[@"providers"][@"result"] count]>50,@"original Catpaw configuration exposes its real film providers");
            check([nodeChecks[@"catpawStop"][@"ok"] boolValue],@"original Catpaw HTTP listener and handles stop on iOS");
            NSDictionary *pythonCrypto=nodeChecks[@"pythonCrypto"];
            if([nodeChecks[@"pythonSmokeAvailable"] boolValue]){
                check([nodeChecks[@"pythonStarted"] boolValue]&&[pythonCrypto[@"available"] boolValue]&&[pythonCrypto[@"backend"] isEqual:@"CommonCrypto"],@"embedded CPython imports the registered native hostcrypto module");
                check([pythonCrypto[@"bytes"] unsignedIntegerValue]==8*1024*1024&&[pythonCrypto[@"roundTrip"] boolValue]&&[pythonCrypto[@"elapsedMs"] doubleValue]<2000.0,[NSString stringWithFormat:@"embedded native AES-128-CTR transforms 8 MB in under 2 seconds (%.1f ms)",[pythonCrypto[@"elapsedMs"] doubleValue]]);
                check([pythonCrypto[@"port"] integerValue]>0&&[pythonCrypto[@"listening"] boolValue]&&[nodeChecks[@"pythonStopped"] boolValue],[NSString stringWithFormat:@"Python smoke listener uses port 0 and stops cleanly (stop=%@)",nodeChecks[@"pythonStopError"]?:@""]);
            }else check(![nodeChecks[@"pythonStarted"] boolValue],@"UI-only simulator target omits CPython; the embedded-Python AES probe is not run here");
            NSData *diagnostic=[NSJSONSerialization dataWithJSONObject:nodeChecks options:NSJSONWritingPrettyPrinted error:NULL];[diagnostic writeToFile:[outputDir stringByAppendingPathComponent:@"node-runtime.json"] atomically:YES];
            mediaPage=[MediaBrowserViewController new];
            NSInteger port=[NSProcessInfo.processInfo.arguments[([NSProcessInfo.processInfo.arguments indexOfObject:@"--smoke-port"]+1)] integerValue];
            mediaSourceID=[NSString stringWithFormat:@"media-ui-%@",NSUUID.UUID.UUIDString];
            mediaPage.sourcesProvider=^NSArray *{return @[@{@"id":mediaSourceID,@"name":@"本机影视测试",@"port":@(port),@"engine":@"node",@"url":[NSString stringWithFormat:@"http://127.0.0.1:%ld/media.js?token=visible",(long)port]}];};
            mediaPage.catalogsProvider=^NSArray *{return @[@{@"id":@"smoke-catalog",@"name":@"影视测试合集",@"sites":@[@{@"key":@"smoke-site",@"name":@"影视内部站点",@"apiKind":@"script",@"api":@"https://provider.test/index.js?token=kept",@"supported":@YES},@{@"key":@"smoke-unsupported",@"name":@"Android 专用站",@"supported":@NO,@"status":@"此脚本需要 Android/JAR 运行时；iOS 不支持"}],@"lives":@[@{@"name":@"直播内部列表",@"url":@"https://provider.test/live.m3u",@"supported":@YES}]}];};
            mediaPage.onImportCatalogSite=^(NSDictionary *site,NSString *identifier){catalogSiteSelectedFromMediaSelector=[identifier isEqual:@"smoke-catalog"]&&[site[@"key"] isEqual:@"smoke-site"];};
            mediaPage.onActivateService=^(NSDictionary *service,void (^done)(NSError *)){done(nil);};
            mediaPage.onPlay=^(NSDictionary *result,NSDictionary *context){mediaPlayback=[MediaPlaybackViewController new];mediaPlayback.result=result;mediaPlayback.context=context;[nav pushViewController:mediaPlayback animated:NO];};
            [nav pushViewController:mediaPage animated:NO];
          }},
          @{ @"until":^BOOL{return mediaPage!=nil&&[[mediaPage valueForKey:@"homeMode"] boolValue];},@"run":^{
            UIScrollView *home=[mediaPage valueForKey:@"homeScroll"];UIStackView *homeStack=[mediaPage valueForKey:@"homeStack"];UIButton *browseButton=[mediaPage valueForKey:@"homeModeButton"];UIButton *homeSearch=[mediaPage valueForKey:@"homeSearchButton"];UIButton *homeSource=[mediaPage valueForKey:@"sourceSelectButton"];UIButton *homeProvider=[mediaPage valueForKey:@"providerSelectButton"];
            UIStackView *homeSelectors=[mediaPage valueForKey:@"selectionRow"];
            UIView *statusCard=nil;for(UIView *view in homeStack.arrangedSubviews)if([view.accessibilityIdentifier isEqual:@"media-home-status-card"]){statusCard=view;break;}UIButton *start=[mediaPage valueForKey:@"homeStatusActionButton"];
            BOOL homeLoading=[[mediaPage valueForKey:@"homeStatusLoading"] boolValue];NSString *statusAction=start.currentTitle?:@"";BOOL statusActionReady=[@[@"启动并加载",@"重试启动",@"重试",@"打开影视库"] containsObject:statusAction];BOOL inlineStatusReady=homeLoading?start.hidden:statusActionReady;
            check(mediaPage.isHomeMode&&!home.hidden&&browseButton!=nil&&homeSearch!=nil,@"media tab presents a compact resource home with floating browse and search actions");check(homeStack.arrangedSubviews.count>0,@"media home renders configured modules");check(!homeSelectors.hidden&&homeSource!=nil&&!homeSource.hidden&&homeProvider!=nil&&!homeProvider.hidden,@"home keeps independent resource and site selectors side by side at the top");check([browseButton.accessibilityLabel isEqual:@"打开影视库"]&&[homeSearch.accessibilityLabel isEqual:@"全站搜索影视"]&&[homeSource.accessibilityLabel containsString:@"影视资源"]&&[homeProvider.accessibilityLabel containsString:@"内部站点"],@"home selectors expose resource-aggregate and internal-site actions");check(CGRectGetMinY(home.frame)<1.5&&CGRectGetMinY(homeStack.frame)>CGRectGetMaxY(homeSelectors.frame)&&[mediaPage valueForKey:@"homeTopImmersiveGradient"]!=nil,@"home content scrolls below the top resource and site selector row under a readable immersive status region");check(statusCard!=nil&&inlineStatusReady,[NSString stringWithFormat:@"home shows inline readiness or an actionable status (loading=%d, action=%@, card=%@)",homeLoading,statusAction,statusCard?@"visible":@"missing"]);
            [mediaPage addHomeCards:@[] emptyText:@"测试空列表" identifier:@"smoke-empty"];[mediaPage.view layoutIfNeeded];UIScrollView *emptyShelf=nil;for(UIView *candidate in homeStack.arrangedSubviews)if([candidate.accessibilityIdentifier isEqual:@"media-home-shelf-smoke-empty"]){emptyShelf=(UIScrollView *)candidate;break;}check(emptyShelf&&fabs(CGRectGetHeight(emptyShelf.frame)-88)<1.5,[NSString stringWithFormat:@"empty home shelves stay compact instead of reserving poster height (height=%.1f)",CGRectGetHeight(emptyShelf.frame)]);if(emptyShelf){[homeStack removeArrangedSubview:emptyShelf];[emptyShelf removeFromSuperview];}[mediaPage.view layoutIfNeeded];
            UIButton *homeMenu=[mediaPage valueForKey:@"homeMenuButton"];[mediaPage.view layoutIfNeeded];CGFloat expectedSelectorTop=mediaPage.view.safeAreaInsets.top+4;check(fabs(CGRectGetMinY(homeSelectors.frame)-expectedSelectorTop)<1.5&&fabs(CGRectGetMinX(homeSelectors.frame)-14)<1.5&&fabs(CGRectGetMaxX(homeSelectors.frame)-(CGRectGetWidth(mediaPage.view.bounds)-14))<1.5&&fabs(homeSelectors.spacing-10)<0.1,@"home source and site selectors sit 4 pt below the safe area with 14 pt side margins and 10 pt spacing");check([homeMenu.accessibilityLabel isEqual:@"更多影视操作"]&&homeMenu.menu.children.count==9&&homeMenu.currentImage!=nil,@"compact top toolbar keeps all nine original home actions and an accessible menu label");check(fabs(CGRectGetMinY(browseButton.frame)-CGRectGetMinY(homeMenu.frame))<1.5&&fabs(CGRectGetMinY(homeSearch.frame)-CGRectGetMinY(homeMenu.frame))<1.5&&CGRectGetMinY(home.frame)<1.5&&CGRectGetMinY(homeStack.frame)>CGRectGetMaxY(homeMenu.frame),@"library, search and menu controls share the top row above the discovery feed");CGFloat expectedHomeBottom=MAX(28,[[mediaPage valueForKey:@"bottomOverlayInset"] doubleValue]);check(home.contentInset.bottom>=expectedHomeBottom-0.5&&homeSearch.frame.size.height==32,@"discovery feed reserves its configured bottom inset and keeps compact toolbar buttons");check(homeSource.titleLabel.lineBreakMode==NSLineBreakByTruncatingTail&&[homeSource.accessibilityLabel containsString:@"本机影视测试"],@"long resource names truncate visually while the complete name remains accessible");capture(self.window,@"16-media-home");
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
            check(mediaPage.isHomeMode,@"home start action waits through health and capability readiness while retaining the home");
            [mediaPage.view layoutIfNeeded];
            UICollectionView *discovery=(UICollectionView *)SmokeViewWithAccessibilityIdentifier(mediaPage.view,@"media-home-discovery-grid");[discovery layoutIfNeeded];UICollectionViewFlowLayout *flow=(UICollectionViewFlowLayout *)discovery.collectionViewLayout;NSIndexPath *firstIndex=[NSIndexPath indexPathForItem:0 inSection:0];UICollectionViewLayoutAttributes *firstAttributes=[flow layoutAttributesForItemAtIndexPath:firstIndex];CGSize cardSize=firstAttributes.size;CGRect first=firstAttributes.frame;CGRect second=[flow layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]].frame;CGRect third=[flow layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:2 inSection:0]].frame;CGRect fourth=[flow layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:3 inSection:0]].frame;UIStackView *categoryButtons=[mediaPage valueForKey:@"categories"];UIButton *movieCategory=nil,*featuredCategory=nil;for(UIButton *button in categoryButtons.arrangedSubviews){if([button.accessibilityIdentifier isEqual:@"movies"])movieCategory=button;if([button.accessibilityIdentifier isEqual:@"__featured__"])featuredCategory=button;}
            check(discovery&&[discovery numberOfItemsInSection:0]==4&&cardSize.width>90&&fabs(CGRectGetMinY(first)-CGRectGetMinY(second))<1&&fabs(CGRectGetMinY(first)-CGRectGetMinY(third))<1&&CGRectGetMinY(fourth)>CGRectGetMaxY(first),[NSString stringWithFormat:@"home renders four real recommendations with three cards on the first row (grid=%@, size=%.1fx%.1f, rowY=%.1f/%.1f/%.1f/%.1f)",discovery?NSStringFromCGRect(discovery.frame):@"missing",cardSize.width,cardSize.height,CGRectGetMinY(first),CGRectGetMinY(second),CGRectGetMinY(third),CGRectGetMinY(fourth)]);
            check(movieCategory&&featuredCategory&&[movieCategory.currentTitle isEqual:@"电影"],@"home category pills mirror the source categories and offer a cached Featured view");UICollectionViewCell *firstCard=[discovery cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];UIImageView *poster=[firstCard valueForKey:@"posterView"];UILabel *cardTitle=[firstCard valueForKey:@"nameLabel"];BOOL hasPosterAction=NO;for(UIView *child in poster.subviews)if([child isKindOfClass:UIButton.class])hasPosterAction=YES;BOOL posterOpensDetail=(poster.accessibilityTraits&UIAccessibilityTraitButton)!=0&&[poster.accessibilityHint containsString:@"详情"];check(poster&&fabs(CGRectGetHeight(poster.frame)/CGRectGetWidth(poster.frame)-1.5)<0.02&&cardTitle.font.pointSize>=14&&!hasPosterAction&&posterOpensDetail,[NSString stringWithFormat:@"poster cards use 2:3 key art and readable titles without overlay actions; tapping the poster opens details (ratio=%.2f title=%.1f overlay=%@)",poster?CGRectGetHeight(poster.frame)/CGRectGetWidth(poster.frame):0,cardTitle.font.pointSize,hasPosterAction?@"yes":@"no"]);check([[firstCard valueForKey:@"posterLoaded"] boolValue],@"visible discovery cards start loading their poster on first display");capture(self.window,@"16-media-home-discovery-grid");
            [mediaPage openHomeConfiguration];

          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"timeout":@15,@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"home configuration");if(!sheet)return;UITableViewController *configuration=(id)sheet.topViewController;[configuration.tableView layoutIfNeeded];check([configuration.tableView numberOfSections]==3&&[configuration.tableView numberOfRowsInSection:1]==2,[NSString stringWithFormat:@"home configuration exposes 3-column and 4-column poster density choices (sections=%ld, choices=%ld)",(long)[configuration.tableView numberOfSections],(long)[configuration.tableView numberOfRowsInSection:1]]);NSIndexPath *threeIndex=[NSIndexPath indexPathForRow:0 inSection:1];UITableViewCell *threeCell=[configuration.tableView cellForRowAtIndexPath:threeIndex];check(threeCell.accessoryType==UITableViewCellAccessoryCheckmark&&[NSUserDefaults.standardUserDefaults integerForKey:@"cctv.mediaGridColumns.v1"]==3,@"3-column poster layout is the default and visibly selected");capture(self.window,@"16b-home-grid-columns");
            UICollectionView *discovery=(UICollectionView *)SmokeViewWithAccessibilityIdentifier(mediaPage.view,@"media-home-discovery-grid");NSIndexPath *firstIndex=[NSIndexPath indexPathForItem:0 inSection:0];[configuration.tableView.delegate tableView:configuration.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:1]];[discovery.collectionViewLayout invalidateLayout];[discovery layoutIfNeeded];CGSize fourColumnSize=[(id<UICollectionViewDelegateFlowLayout>)discovery.delegate collectionView:discovery layout:discovery.collectionViewLayout sizeForItemAtIndexPath:firstIndex];CGFloat expectedFourColumnWidth=floor((CGRectGetWidth(discovery.bounds)-30)/4.0);CGRect firstFourFrame=[discovery.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].frame;CGRect fourthFourFrame=[discovery.collectionViewLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:3 inSection:0]].frame;check([NSUserDefaults.standardUserDefaults integerForKey:@"cctv.mediaGridColumns.v1"]==4&&fabs(fourColumnSize.width-expectedFourColumnWidth)<1.0&&fabs(CGRectGetMinY(firstFourFrame)-CGRectGetMinY(fourthFourFrame))<1.0,[NSString stringWithFormat:@"choosing 4 columns persists and puts all four posters on the first row (actual=%.1f expected=%.1f y=%.1f/%.1f)",fourColumnSize.width,expectedFourColumnWidth,CGRectGetMinY(firstFourFrame),CGRectGetMinY(fourthFourFrame)]);
            [sheet dismissViewControllerAnimated:NO completion:^{UIStackView *categoryButtons=[mediaPage valueForKey:@"categories"];for(UIButton *button in categoryButtons.arrangedSubviews)if([button.accessibilityIdentifier isEqual:@"movies"]){[button sendActionsForControlEvents:UIControlEventTouchUpInside];break;}}];
          }},
          @{ @"until":^BOOL{return ![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"category"] isEqual:@"movies"]&&[[mediaPage valueForKey:@"items"] count]==1;},@"timeout":@30,@"run":^{UICollectionView *discovery=(id)[mediaPage valueForKey:@"homeGrid"];check([[mediaPage valueForKey:@"category"] isEqual:@"movies"]&&[discovery numberOfItemsInSection:0]==1,@"choosing a genre requests that category on demand and replaces the grid results");UIButton *featured=nil;for(UIButton *button in ((UIStackView *)[mediaPage valueForKey:@"categories"]).arrangedSubviews)if([button.accessibilityIdentifier isEqual:@"__featured__"])featured=button;[featured sendActionsForControlEvents:UIControlEventTouchUpInside];} },
          @{ @"until":^BOOL{return ![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"category"] length]==0&&[[mediaPage valueForKey:@"items"] count]==4;},@"timeout":@15,@"run":^{check([(UICollectionView *)[mediaPage valueForKey:@"homeGrid"] numberOfItemsInSection:0]==4,@"Featured returns immediately to cached home recommendations without another request");UIButton *browse=[mediaPage valueForKey:@"homeModeButton"];[browse sendActionsForControlEvents:UIControlEventTouchUpInside];} },
          @{ @"until":^BOOL{return [[mediaPage valueForKey:@"items"] count]>0&&!mediaPage.isHomeMode;},@"run":^{
            check([[mediaPage valueForKey:@"items"] count]==4,@"media library preserves the source's real home recommendations");
            UIStackView *selectionRow=[mediaPage valueForKey:@"selectionRow"];UIButton *sourceSelector=[mediaPage valueForKey:@"sourceSelectButton"];UIButton *providerSelector=[mediaPage valueForKey:@"providerSelectButton"];NSString *activeProviderID=[mediaPage valueForKey:@"provider"]?:@"";NSArray *loadedProviders=[mediaPage valueForKey:@"providers"]?:@[];NSString *activeProviderName=nil;for(NSDictionary *candidate in loadedProviders)if([candidate[@"id"] isEqual:activeProviderID]){activeProviderName=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:candidate[@"id"];break;}check(CGRectGetMinY(selectionRow.frame)>=mediaPage.view.safeAreaInsets.top,@"two-level resource selectors stay inside the media safe area");check([sourceSelector.currentTitle containsString:@"本机影视测试"]&&activeProviderName.length&&[providerSelector.currentTitle containsString:activeProviderName],[NSString stringWithFormat:@"top selectors show the active resource and its selected site (provider=%@, button=%@)",activeProviderName?:@"unresolved",providerSelector.currentTitle?:@""]);check(providerSelector.enabled,@"second-level selector becomes available after providers load");
            UIScrollView *categories=[mediaPage valueForKey:@"categoryScroll"];check([mediaPage.title isEqual:@"影视库"]&&!mediaPage.isHomeMode&&!selectionRow.hidden,@"opening a selected source from home enters the separate resource library");check(CGRectGetMinY(categories.frame)>CGRectGetMaxY(selectionRow.frame),@"film categories appear below the two-level resource selectors");UICollectionView *libraryGrid=[mediaPage valueForKey:@"grid"];CGSize libraryFixedColumnSize=[(id<UICollectionViewDelegateFlowLayout>)libraryGrid.delegate collectionView:libraryGrid layout:libraryGrid.collectionViewLayout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];CGFloat expectedLibraryFixedWidth=floor((CGRectGetWidth(libraryGrid.bounds)-28-20)/3.0);check([NSUserDefaults.standardUserDefaults integerForKey:@"cctv.mediaGridColumns.v1"]==4&&fabs(libraryFixedColumnSize.width-expectedLibraryFixedWidth)<1.0,[NSString stringWithFormat:@"home four-column setting leaves the library fixed at three columns (actual=%.1f expected=%.1f)",libraryFixedColumnSize.width,expectedLibraryFixedWidth]);UILabel *browseStatus=[mediaPage valueForKey:@"status"];UIButton *resourceAction=[mediaPage valueForKey:@"resourceButton"];UIActivityIndicatorView *browseSpinner=[mediaPage valueForKey:@"spinner"];[mediaPage showMessage:@"此影视资源未提供可切换的站点列表" loading:NO];check([[mediaPage valueForKey:@"items"] count]>0&&browseStatus.hidden&&resourceAction.hidden&&![browseSpinner isAnimating],@"provider messages stay out of the poster grid when content is already visible");[mediaPage showMessage:@"正在更新当前内容" loading:YES];check(browseStatus.hidden&&![browseSpinner isAnimating],@"background refreshes keep cached posters unobstructed and use inline readiness text");[mediaPage showMessage:@"" loading:NO];capture(self.window,@"16-media-library");[sourceSelector sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"resource selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];UITableViewCell *current=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            UIStackView *scopeStack=[picker valueForKey:@"scopeStack"];check(sheet.modalPresentationStyle==UIModalPresentationPageSheet,@"resource selection uses a native bottom sheet");check([picker.tableView numberOfRowsInSection:0]==2&&current.accessoryType==UITableViewCellAccessoryCheckmark,@"resource sheet shows the active resource and a saved collection");check(scopeStack.arrangedSubviews.count==3,@"resource sheet groups installed runtimes and on-demand collections");capture(self.window,@"16b-media-resource-sheet");
            NSIndexPath *catalogIndex=[NSIndexPath indexPathForRow:1 inSection:0];[picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:catalogIndex];
          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])==nil&&[[mediaPage valueForKey:@"selectedCatalogID"] isEqual:@"smoke-catalog"]&&[mediaPage valueForKey:@"source"]==nil&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==0;},@"run":^{
            UIButton *sourceSelector=[mediaPage valueForKey:@"sourceSelectButton"];UIButton *providerSelector=[mediaPage valueForKey:@"providerSelectButton"];
            check([sourceSelector.currentTitle containsString:@"影视测试合集"]&&[providerSelector.currentTitle containsString:@"选择站点"]&&nav.topViewController==mediaPage,@"selecting an aggregate keeps one parent resource selected in the media page");[providerSelector sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"provider selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];UIStackView *scopeStack=[picker valueForKey:@"scopeStack"];
            check([picker.title containsString:@"内部站点"],@"the second capsule opens the selected aggregate's internal source list");check([picker.tableView numberOfRowsInSection:0]==3&&scopeStack.arrangedSubviews.count==3,@"aggregate list includes supported and unavailable sites plus live playlist groups");UITableViewCell *site=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];UITableViewCell *unsupported=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];UITableViewCell *live=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];check([site.textLabel.text isEqual:@"影视内部站点"]&&[unsupported.textLabel.text isEqual:@"Android 专用站"]&&[live.textLabel.text isEqual:@"直播内部列表"],[NSString stringWithFormat:@"internal selector shows every individual entry (site=%@ unsupported=%@ live=%@)",site.textLabel.text?:@"",unsupported.textLabel.text?:@"",live.textLabel.text?:@""]);capture(self.window,@"16c-media-aggregate-sites");
            [picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
          }},
          @{ @"until":^BOOL{return catalogSiteSelectedFromMediaSelector&&SmokePresentedController(@[mediaPage,nav,root])==nil;},@"run":^{
            check(catalogSiteSelectedFromMediaSelector&&[mediaPage valueForKey:@"source"]==nil,@"choosing an internal script requests only that site without importing the whole aggregate");UIButton *sourceSelector=[mediaPage valueForKey:@"sourceSelectButton"];[sourceSelector sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])!=nil;},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"resource selector");if(!sheet)return;UITableViewController *picker=(id)sheet.topViewController;[picker.tableView layoutIfNeeded];NSIndexPath *standalone=nil;for(NSInteger row=0;row<[picker.tableView numberOfRowsInSection:0];row++){UITableViewCell *cell=[picker.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];if([cell.textLabel.text isEqual:@"本机影视测试"]){standalone=[NSIndexPath indexPathForRow:row inSection:0];break;}}
            check(standalone!=nil&&[picker.tableView numberOfRowsInSection:0]==2,@"switching away from an aggregate retains independently imported resources");if(standalone)[picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:standalone];
          }},
          @{ @"until":^BOOL{return [[mediaPage valueForKeyPath:@"source.id"] isEqual:mediaSourceID]&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==4;},@"run":^{
            check([[mediaPage valueForKeyPath:@"source.id"] isEqual:mediaSourceID]&&[[mediaPage valueForKey:@"items"] count]==4,@"switching back from the aggregate restores the selected resource's real media listing");[mediaPage openSourceConfiguration];
          }},
          @{@"until":^BOOL{UIViewController *presented=SmokePresentedController(@[mediaPage,nav,root]);if(![presented isKindOfClass:UINavigationController.class])return NO;UINavigationController *sheet=(UINavigationController *)presented;WKWebView *web=[sheet.topViewController isKindOfClass:MediaWebViewController.class]?[sheet.topViewController valueForKey:@"web"]:nil;return [sheet isKindOfClass:UINavigationController.class]&&[sheet.topViewController isKindOfClass:MediaWebViewController.class]&&[web.URL.path isEqual:@"/source-config"];},@"run":^{
            UINavigationController *sheet=SmokePresentedNavigation(@[mediaPage,nav,root],@"source configuration");if(!sheet)return;MediaWebViewController *page=(id)sheet.topViewController;WKWebView *web=[page valueForKey:@"web"];
            check([web.URL.path isEqual:@"/source-config"],[NSString stringWithFormat:@"source configuration opens the real local service page (url=%@)",web.URL.absoluteString?:@"nil"]);check(!web.configuration.websiteDataStore.persistent,@"source configuration uses an isolated ephemeral cookie store");check(sheet.modalInPresentation,@"configuration has an explicit close-and-refresh action");capture(self.window,@"16d-media-source-configuration");[page close];
          }},
          @{@"until":^BOOL{return SmokePresentedController(@[mediaPage,nav,root])==nil&&![[mediaPage valueForKey:@"loading"] boolValue]&&[[mediaPage valueForKey:@"items"] count]==4;},@"run":^{
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
            UIView *hero=[mediaDetail valueForKey:@"heroView"];CAGradientLayer *heroGradient=[mediaDetail valueForKey:@"heroGradient"];NSDictionary *detailSource=[mediaDetail valueForKey:@"source"]?:@{};NSString *parserCatalogID=[detailSource[@"catalogID"] isKindOfClass:NSString.class]?detailSource[@"catalogID"]:([detailSource[@"tvboxCatalogID"] isKindOfClass:NSString.class]?detailSource[@"tvboxCatalogID"]:@"");NSArray *scopedParsers=parserCatalogID.length?[TVBoxCatalogStore playbackParsersForCatalogID:parserCatalogID]:@[];BOOL parserRowHidden=[[mediaDetail valueForKey:@"parserRow"] isHidden];check([mediaDetail valueForKey:@"heroTitle"] && [mediaDetail valueForKey:@"playButton"] && [mediaDetail valueForKey:@"favoriteButton"] && [mediaDetail valueForKey:@"posterPlaceholder"]&&hero.bounds.size.height>hero.bounds.size.width&&heroGradient.colors.count==5,@"film detail keeps portrait poster, playback actions, and the five-stop immersive gradient");check(parserRowHidden,[NSString stringWithFormat:@"unscoped plugin hides parser controls (source=%@ catalog=%@ parsers=%lu hidden=%d)",detailSource[@"id"]?:@"",parserCatalogID,(unsigned long)scopedParsers.count,parserRowHidden]);capture(self.window,@"18-media-detail");
            UIButton *favorite=[mediaDetail valueForKey:@"favoriteButton"];[favorite sendActionsForControlEvents:UIControlEventTouchUpInside];check([favorite.accessibilityLabel isEqual:@"取消收藏影片"]&&[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] count]>0,@"film favorite is visibly updated and persisted");[favorite sendActionsForControlEvents:UIControlEventTouchUpInside];
            [(UIButton *)episodeButtons[0] sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{@"until":^BOOL{mediaPlayback=(id)[mediaDetail valueForKey:@"inlinePlaybackController"];AVPlayer *player=[mediaPlayback valueForKey:@"player"];return mediaPlayback&&player.currentItem.status==AVPlayerItemStatusReadyToPlay;},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];UIStackView *qualityButtons=[mediaPlayback valueForKey:@"qualityButtons"];NSArray *inlineEpisodeButtons=[mediaDetail valueForKey:@"episodeButtons"];NSUInteger expectedInlineRows=(inlineEpisodeButtons.count+3)/4;check(player.currentItem.status==AVPlayerItemStatusReadyToPlay,@"selected plugin episode reaches AVPlayer ready state embedded in film detail");check(nav.topViewController==mediaDetail,@"starting playback keeps the user on the same detail page");check([[mediaDetail valueForKey:@"heroView"] isHidden]&&((UIStackView *)[mediaDetail valueForKey:@"episodeGrid"]).arrangedSubviews.count==expectedInlineRows,@"inline video replaces the poster while detail episodes remain in the same scroll page");check([[mediaPlayback valueForKey:@"embeddedMode"] boolValue],@"the existing diagnostic player runs in inline mode");UILabel *playingEpisode=(id)[mediaPlayback valueForKey:@"episodeTitle"];check([playingEpisode.text containsString:@"正在播放"]&&[playingEpisode.text containsString:@"第一集"],@"inline player visibly identifies the episode currently playing");UIScrollView *detailScroll=[mediaDetail valueForKey:@"scrollView"];UIStackView *detailStack=[mediaDetail valueForKey:@"contentStack"];[mediaDetail.view layoutIfNeeded];[detailScroll layoutIfNeeded];CGFloat playerY=[mediaPlayback.view convertRect:mediaPlayback.view.bounds toView:detailStack].origin.y;UIEdgeInsets originalDetailInset=detailScroll.contentInset;detailScroll.contentInset=UIEdgeInsetsMake(originalDetailInset.top,originalDetailInset.left,originalDetailInset.bottom+MAX(0,playerY)+360,originalDetailInset.right);[detailScroll layoutIfNeeded];CGFloat pinTop=MAX(CGRectGetMinY([detailScroll convertRect:detailScroll.bounds toView:mediaDetail.view]),mediaDetail.view.safeAreaInsets.top);if(!nav.navigationBar.hidden)pinTop=MAX(pinTop,CGRectGetMaxY([nav.navigationBar convertRect:nav.navigationBar.bounds toView:mediaDetail.view]));detailScroll.contentOffset=CGPointMake(0,MAX(120,playerY+120));[detailScroll.delegate scrollViewDidScroll:detailScroll];CGRect pinnedPlayer=[mediaPlayback.view convertRect:mediaPlayback.view.bounds toView:mediaDetail.view];check(fabs(CGRectGetMinY(pinnedPlayer)-pinTop)<2,[NSString stringWithFormat:@"inline player floats below navigation while scrolling (y=%.1f expected=%.1f offset=%.1f)",CGRectGetMinY(pinnedPlayer),pinTop,detailScroll.contentOffset.y]);detailScroll.contentOffset=CGPointMake(0,detailScroll.contentOffset.y+90);[detailScroll.delegate scrollViewDidScroll:detailScroll];CGRect stillPinnedPlayer=[mediaPlayback.view convertRect:mediaPlayback.view.bounds toView:mediaDetail.view];check(fabs(CGRectGetMinY(stillPinnedPlayer)-pinTop)<2,@"inline player remains floating as the detail page continues scrolling");detailScroll.contentOffset=CGPointMake(0,MAX(0,detailScroll.contentOffset.y-50));[detailScroll.delegate scrollViewDidScroll:detailScroll];CGRect reverseScrollPlayer=[mediaPlayback.view convertRect:mediaPlayback.view.bounds toView:mediaDetail.view];check(fabs(CGRectGetMinY(reverseScrollPlayer)-pinTop)<2,@"inline player remains floating when scrolling back toward the top");detailScroll.contentInset=originalDetailInset;detailScroll.contentOffset=CGPointZero;[detailScroll.delegate scrollViewDidScroll:detailScroll];UIPanGestureRecognizer *playbackSwipe=[mediaPlayback valueForKey:@"playbackPanGesture"];check(playbackSwipe!=nil&&playbackSwipe.delegate==mediaPlayback,@"inline player installs guarded horizontal swipe seeking without replacing native controls");[mediaPlayback setValue:@(9.0/16.0) forKey:@"videoAspectRatio"];[mediaPlayback updatePlaybackLayoutForSize:mediaPlayback.view.bounds.size];[mediaPlayback.view layoutIfNeeded];NSLayoutConstraint *inlineTallViewport=[mediaPlayback valueForKey:@"embeddedTallVideoAspectConstraint"];check(inlineTallViewport.isActive,@"inline playback expands for portrait short-form video");[mediaPlayback setValue:@(16.0/9.0) forKey:@"videoAspectRatio"];[mediaPlayback updatePlaybackLayoutForSize:mediaPlayback.view.bounds.size];[mediaPlayback.view layoutIfNeeded];check(qualityButtons.arrangedSubviews.count==2,@"inline player exposes the source's actual alternate quality choices");capture(self.window,@"19-media-inline-playback");[(UIButton *)qualityButtons.arrangedSubviews[1] sendActionsForControlEvents:UIControlEventTouchUpInside];
          }},
          @{ @"timeout":@12,@"until":^BOOL{UILabel *status=[mediaPlayback valueForKey:@"status"];return [status.text containsString:@"视频首帧已就绪"];},@"run":^{
            UILabel *status=[mediaPlayback valueForKey:@"status"];AVPlayer *qualityPlayer=[mediaPlayback valueForKey:@"player"];AVURLAsset *qualityAsset=(AVURLAsset *)qualityPlayer.currentItem.asset;check([status.text containsString:@"视频首帧已就绪"],@"AVPlayerLayer displays a header-protected frame from the selected film resource");check([qualityAsset.URL.absoluteString containsString:@"quality=low"],@"choosing a quality option replaces the active AVPlayer item with that stream");UIButton *speedButton=[mediaPlayback valueForKey:@"playbackSpeedButton"];check([speedButton.accessibilityIdentifier isEqual:@"media-playback-speed"]&&speedButton.menu.children.count==7,@"player exposes seven accessible playback-speed choices alongside episode controls");[mediaPlayback setPlaybackRate:1.5];check([speedButton.currentTitle isEqual:@"1.5×"]&&fabs(qualityPlayer.defaultRate-1.5)<0.01&&fabs([NSUserDefaults.standardUserDefaults doubleForKey:@"cctv.mediaPlaybackRate"]-1.5)<0.01,@"quick speed control updates the player and persists the selected rate");[mediaPlayback setPlaybackRate:1.0];
            NSArray *playbackLines=[mediaPlayback valueForKey:@"lines"];check(playbackLines.count==2,[NSString stringWithFormat:@"playback retains both detail routes before opening selector (actual %lu)",(unsigned long)playbackLines.count]);
            [mediaPlayback openEpisodeSelection];UIViewController *selectorPage=nav.topViewController;check([selectorPage isKindOfClass:MediaEpisodeSelectionViewController.class],[NSString stringWithFormat:@"player opens shared episode selector (top page %@)",NSStringFromClass(selectorPage.class)]);
            if([selectorPage isKindOfClass:MediaEpisodeSelectionViewController.class]){mediaEpisodes=(id)selectorPage;[mediaEpisodes loadViewIfNeeded];check(mediaEpisodes.selectionUpdatesPlayer,@"episode selector keeps playback context");NSArray *selectorLines=[mediaEpisodes valueForKey:@"lines"];check(selectorLines.count==2,[NSString stringWithFormat:@"episode selector receives both playback routes (actual %lu)",(unsigned long)selectorLines.count]);UIStackView *routes=[mediaEpisodes valueForKey:@"routeButtons"];NSArray *episodeButtons=[mediaEpisodes valueForKey:@"episodeButtons"];UIButton *disclosure=[mediaEpisodes valueForKey:@"episodeDisclosureButton"];UIScrollView *episodeScroll=[mediaEpisodes valueForKey:@"scrollView"];check(routes.arrangedSubviews.count==2,@"playback episode picker renders both route chips");UIStackView *seasonButtons=[mediaEpisodes valueForKey:@"seasonButtons"];check(seasonButtons.arrangedSubviews.count==2,@"episode selector displays optional season chips when the source provides seasons");if(seasonButtons.arrangedSubviews.count>1){[(UIButton *)seasonButtons.arrangedSubviews[1] sendActionsForControlEvents:UIControlEventTouchUpInside];check([[mediaEpisodes valueForKey:@"selectedSeasonIndex"] integerValue]==1,[NSString stringWithFormat:@"season switching selects the requested season (index %@)",[mediaEpisodes valueForKey:@"selectedSeasonIndex"]]);seasonButtons=[mediaEpisodes valueForKey:@"seasonButtons"];if(seasonButtons.arrangedSubviews.count>0)[(UIButton *)seasonButtons.arrangedSubviews[0] sendActionsForControlEvents:UIControlEventTouchUpInside];}check(episodeButtons.count==3&&((UIStackView *)[mediaEpisodes valueForKey:@"episodeDetails"]).hidden,@"episode list starts collapsed to keep the detail page compact");check(disclosure!=nil&&[[(UIButton *)[mediaEpisodes valueForKey:@"continueButton"] currentTitle] containsString:@"继续播放"],@"episode picker keeps the selected episode in a sticky continue-play action");check(episodeScroll!=nil&&[mediaEpisodes.view viewWithTag:4101]!=nil&&[mediaEpisodes valueForKey:@"descriptionLabel"]!=nil,@"episode page includes poster artwork, synopsis and a scrollable detail layout");[disclosure sendActionsForControlEvents:UIControlEventTouchUpInside];episodeButtons=[mediaEpisodes valueForKey:@"episodeButtons"];check(episodeButtons.count==3&&!((UIStackView *)[mediaEpisodes valueForKey:@"episodeDetails"]).hidden,@"expanded episode picker renders the available three-item episode grid");capture(self.window,@"18-media-episodes");
              if(episodeButtons.count>1){UIButton *slowButton=episodeButtons[1];[slowButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaEpisodes.selectedEpisodeIndex==1,[NSString stringWithFormat:@"slow episode request updates selector immediately (selected %ld, tag %ld)",(long)mediaEpisodes.selectedEpisodeIndex,(long)slowButton.tag]);}else check(NO,@"player episode picker exposes a second episode");
              episodeButtons=[mediaEpisodes valueForKey:@"episodeButtons"];if(episodeButtons.count>2){UIButton *fastButton=episodeButtons[2];[fastButton sendActionsForControlEvents:UIControlEventTouchUpInside];check(mediaEpisodes.selectedEpisodeIndex==2,[NSString stringWithFormat:@"player episode selector stays responsive (selected %ld, tag %ld)",(long)mediaEpisodes.selectedEpisodeIndex,(long)fastButton.tag]);}else check(NO,@"player episode picker exposes a third episode");}
            stalePlaybackDeadline=[NSDate dateWithTimeIntervalSinceNow:4.0];
          }},
          @{ @"timeout":@12,@"until":^BOOL{AVPlayer *player=[mediaPlayback valueForKey:@"player"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;return player.currentItem.status==AVPlayerItemStatusReadyToPlay&&[asset.URL.absoluteString containsString:@"play=fast"]&&[stalePlaybackDeadline timeIntervalSinceNow]<=0;},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;check([asset.URL.absoluteString containsString:@"play=fast"],@"late slow parse cannot replace the latest selected episode");UILabel *playingEpisode=(id)[mediaPlayback valueForKey:@"episodeTitle"];check([playingEpisode.text containsString:@"正在播放"]&&[playingEpisode.text containsString:@"快速切换"],@"player episode label follows the latest selected episode after rapid switching");capture(self.window,@"20-media-fast-switch");UIStackView *routes=[mediaPlayback valueForKey:@"lineButtons"];if(routes.arrangedSubviews.count>1)[(UIButton *)routes.arrangedSubviews[1] sendActionsForControlEvents:UIControlEventTouchUpInside];else check(NO,@"film player offers the second source route for HLS compatibility check");
          }},
          @{ @"timeout":@16,@"until":^BOOL{AVPlayer *player=[mediaPlayback valueForKey:@"player"];UILabel *status=[mediaPlayback valueForKey:@"status"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;return player.currentItem.status==AVPlayerItemStatusReadyToPlay&&[asset.URL.pathExtension.lowercaseString isEqual:@"m3u8"]&&[status.text containsString:@"视频首帧已就绪"];},@"run":^{
            AVPlayer *player=[mediaPlayback valueForKey:@"player"];UILabel *status=[mediaPlayback valueForKey:@"status"];AVURLAsset *asset=(AVURLAsset *)player.currentItem.asset;NSDictionary *result=[mediaPlayback valueForKey:@"result"];check([result[@"parse"] boolValue]&&[result[@"format"] isEqual:@"hls"],@"legacy parse=1 HLS media result is routed to AVPlayer when the returned URL is a real HLS manifest");check([asset.URL.pathExtension.lowercaseString isEqual:@"m3u8"],@"plugin HLS route remains a native HLS asset");check([status.text containsString:@"视频首帧已就绪"],@"AVPlayer decodes and displays a real frame from the imported-source HLS fixture");capture(self.window,@"20b-media-hls-first-frame");[nav popToViewController:mediaPage animated:NO];
            MediaPlaybackViewController *viewportProbe=[MediaPlaybackViewController new];viewportProbe.context=@{@"source":@{@"id":@"viewport-fixture"},@"item":@{@"name":@"Viewport fixture"}};[nav pushViewController:viewportProbe animated:NO];[viewportProbe.view layoutIfNeeded];
            [viewportProbe setValue:@(9.0/16.0) forKey:@"videoAspectRatio"];[viewportProbe updatePlaybackLayoutForSize:viewportProbe.view.bounds.size];[viewportProbe.view layoutIfNeeded];UIView *probeVideo=[viewportProbe valueForKey:@"videoView"];NSLayoutConstraint *portraitViewport=[viewportProbe valueForKey:@"portraitTallViewportHeightConstraint"];NSLayoutConstraint *standardAspect=[viewportProbe valueForKey:@"videoAspectConstraint"];CGFloat expectedTallHeight=CGRectGetHeight(viewportProbe.view.bounds)*0.50;check(portraitViewport.isActive&&!standardAspect.isActive&&fabs(CGRectGetHeight(probeVideo.frame)-expectedTallHeight)<2,[NSString stringWithFormat:@"portrait media gets the configured half-height native-player viewport (actual=%.1f expected=%.1f)",CGRectGetHeight(probeVideo.frame),expectedTallHeight]);
            [viewportProbe setValue:@(16.0/9.0) forKey:@"videoAspectRatio"];[viewportProbe updatePlaybackLayoutForSize:viewportProbe.view.bounds.size];[viewportProbe.view layoutIfNeeded];check(standardAspect.isActive&&!portraitViewport.isActive&&fabs(CGRectGetHeight(probeVideo.frame)-CGRectGetWidth(probeVideo.frame)*0.5625)<2,@"landscape media restores the normal 16:9 player viewport");[nav popViewControllerAnimated:NO];
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
            UIStackView *collectionActions=(id)catalogPage.navigationItem.rightBarButtonItems.firstObject.customView;NSString *jsonAction=((UIView *)collectionActions.arrangedSubviews[1]).accessibilityLabel,*zipAction=((UIView *)collectionActions.arrangedSubviews[2]).accessibilityLabel;UIContextMenuConfiguration *singleResourceMenu=[catalogPage tableView:catalogPage.tableView contextMenuConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] point:CGPointZero];check([jsonAction isEqual:@"导出完整合集 JSON"]&&[zipAction isEqual:@"导出完整资源 ZIP（含 PY / JS）"]&&singleResourceMenu!=nil,@"resource collection offers complete JSON, full PY/JS ZIP and per-item export");
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
            [settingsTable layoutIfNeeded];check(fabs(CGRectGetMinY(settingsTable.frame))<1&&settingsTable.contentInset.top>=settings.view.safeAreaInsets.top-1&&fabs(settingsTable.contentOffset.y+settingsTable.contentInset.top)<1.5,@"settings content extends beneath the status region while its first section stays below the safe area");
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
