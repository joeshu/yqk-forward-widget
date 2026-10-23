#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AppDelegate.h"
#import "RootViewController.h"
#import "ServicesViewController.h"
#import "ServiceEditorViewController.h"
#import "ServiceStore.h"
#import "EPGViewController.h"

@interface RootViewController (Smoke)
- (void)selectBottomTab:(UIButton *)button;
- (void)openServicesPage;
- (void)toggleLog;
- (void)applyFilter;
@end
@interface EPGViewController (Smoke)
- (void)rebuildDates;
@end
static NSMutableArray *failures;
static NSString *outputDir;
static void check(BOOL value,NSString *message){if(!value)[failures addObject:message];}
static void capture(UIWindow *window,NSString *name){[window layoutIfNeeded];UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];UIImage *image=[r imageWithActions:^(UIGraphicsImageRendererContext *context){[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];}];[UIImagePNGRepresentation(image) writeToFile:[outputDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]] atomically:YES];}
static void next(NSArray *steps,NSUInteger index){if(index>=steps.count){NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"failures":failures,@"passed":@(failures.count==0)} options:NSJSONWritingPrettyPrinted error:NULL];[data writeToFile:[outputDir stringByAppendingPathComponent:@"results.json"] atomically:YES];return;}dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{@try{((dispatch_block_t)steps[index])();}@catch(NSException *e){[failures addObject:e.reason?:e.name];}next(steps,index+1);});}
@interface AppDelegate (SmokeDriver)
@end
@implementation AppDelegate (SmokeDriver)
+ (void)load {method_exchangeImplementations(class_getInstanceMethod(self,@selector(application:didFinishLaunchingWithOptions:)),class_getInstanceMethod(self,@selector(smokeApplication:didFinishLaunchingWithOptions:)));}
- (BOOL)smokeApplication:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL ok=[self smokeApplication:app didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        failures=[NSMutableArray array];outputDir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ui-smoke"];[NSFileManager.defaultManager createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:NULL];
        UINavigationController *nav=(id)self.window.rootViewController;RootViewController *root=(id)nav.viewControllers.firstObject;UIStackView *tabs=[root valueForKey:@"bottomBar"];
        NSArray *steps=@[
            ^{UICollectionView *grid=[root valueForKey:@"channelGrid"];check([grid numberOfItemsInSection:0]>20,@"home catalog populated");check(!grid.hidden,@"grid visible by default");capture(self.window,@"01-live-grid");},
            ^{[root setValue:[NSMutableArray arrayWithObject:@"cctv1"] forKey:@"favorites"];[root selectBottomTab:(id)tabs.arrangedSubviews[1]];},
            ^{NSArray *shown=[root valueForKey:@"shownChannels"];check(shown.count==1,@"favorite filter returns only saved channel");capture(self.window,@"02-favorites");[root selectBottomTab:(id)tabs.arrangedSubviews[2]];},
            ^{check([[root valueForKey:@"tabPage"] isKindOfClass:NSClassFromString(@"ConfigCenterViewController")],@"configuration tab embedded");capture(self.window,@"03-configuration");[root openServicesPage];},
            ^{check([nav.topViewController isKindOfClass:ServicesViewController.class],@"service directory opened");capture(self.window,@"04-services");ServicesViewController *v=(id)nav.topViewController;UITableView *table=[v valueForKey:@"table"];[table.delegate tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];},
            ^{check([NSStringFromClass(nav.topViewController.class) isEqualToString:@"ServiceDetailViewController"],@"service detail opened");capture(self.window,@"05-service-detail");ServiceEditorViewController *edit=[ServiceEditorViewController new];[nav pushViewController:edit animated:NO];},
            ^{capture(self.window,@"06-service-editor");ServiceEditorViewController *edit=(id)nav.topViewController;[(UITextField *)[edit valueForKey:@"nameField"] setText:@"UI Smoke Service"];[edit setValue:@"print('service smoke test')\n" forKey:@"code"];[edit performSelector:NSSelectorFromString(@"save")];},
            ^{BOOL saved=NO;for(NSDictionary *s in [ServiceStore services])if([s[@"name"] isEqualToString:@"UI Smoke Service"])saved=YES;check(saved,@"custom service editor saves code and metadata");[nav popToRootViewControllerAnimated:NO];[root selectBottomTab:(id)tabs.arrangedSubviews[3]];},
            ^{capture(self.window,@"07-settings");[root selectBottomTab:(id)tabs.arrangedSubviews[0]];[root setValue:@NO forKey:@"gridMode"];[root.view setNeedsLayout];},
            ^{UITableView *table=[root valueForKey:@"table"];check(!table.hidden,@"list mode visible");capture(self.window,@"08-live-list");EPGViewController *epg=[[EPGViewController alloc] initWithChannelID:@"cctv1" name:@"CCTV-1 综合"];[nav pushViewController:epg animated:NO];},
            ^{EPGViewController *epg=(id)nav.topViewController;[[epg valueForKey:@"task"] cancel];NSTimeInterval t=NSDate.date.timeIntervalSince1970;[epg setValue:@[@{@"start":@(t-900),@"end":@(t+900),@"title":@"当前节目 · UI 测试数据"},@{@"start":@(t+900),@"end":@(t+2700),@"title":@"接下来 · UI 测试数据"}] forKey:@"allRows"];[epg rebuildDates];},
            ^{capture(self.window,@"09-epg-fixture");[nav popToRootViewControllerAnimated:NO];[root toggleLog];},
            ^{capture(self.window,@"10-diagnostic-log");}
        ];next(steps,0);
    });return ok;
}
@end
