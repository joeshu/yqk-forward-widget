#import "AppDelegate.h"
#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import <objc/runtime.h>
@interface RootViewController (ReferenceSmoke)
- (void)playChannel:(NSString *)cid name:(NSString *)name;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
@end
@interface AppDelegate (ReferenceSmoke)
@end
static NSMutableArray *failures;
static NSString *outputDir;
static void check(BOOL ok,NSString *message){if(!ok)[failures addObject:message];}
@implementation AppDelegate (ReferenceSmoke)
+ (void)load {method_exchangeImplementations(class_getInstanceMethod(self,@selector(application:didFinishLaunchingWithOptions:)),class_getInstanceMethod(self,@selector(referenceApplication:didFinishLaunchingWithOptions:)));}
- (BOOL)referenceApplication:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL ok=[self referenceApplication:app didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        failures=[NSMutableArray array];outputDir=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/pre-epg-smoke"];
        [NSFileManager.defaultManager createDirectoryAtPath:outputDir withIntermediateDirectories:YES attributes:nil error:NULL];
        RootViewController *root=(id)((UINavigationController *)self.window.rootViewController).topViewController;
        check(NSClassFromString(@"EPGViewController")==Nil,@"EPG class excluded from reference executable");
        check(NSClassFromString(@"PyHost")==Nil,@"Python host excluded from reference executable");
        [root playChannel:@"cctv1" name:@"CCTV-1 综合"];
        id previous=[root valueForKey:@"currentPlayer"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            check([[root valueForKey:@"firstRender"] boolValue],@"first channel renders through SDK callback");
            [root playChannel:@"cctv2" name:@"CCTV-2 财经"];
            check([root valueForKey:@"currentPlayer"]!=previous,@"pre-EPG switching creates fresh SDK wrapper");
            [root player:previous statEvent:3 value:nil];
            check(![[root valueForKey:@"firstRender"] boolValue],@"late old callback rejected");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                check([[root valueForKey:@"firstRender"] boolValue],@"second channel renders");
                check([[root valueForKey:@"currentChannelID"] isEqual:@"cctv2"],@"selected channel retained");
                check([[root valueForKey:@"logBuffer"] containsString:@"首帧渲染"],@"measured first frame logged");
                UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];UIImage *image=[r imageWithActions:^(UIGraphicsImageRendererContext *c){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];[UIImagePNGRepresentation(image) writeToFile:[outputDir stringByAppendingPathComponent:@"pre-epg.png"] atomically:YES];
                [[root valueForKey:@"logBuffer"] writeToFile:[outputDir stringByAppendingPathComponent:@"reference.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(failures.count==0),@"failures":failures} options:NSJSONWritingPrettyPrinted error:NULL];[json writeToFile:[outputDir stringByAppendingPathComponent:@"results.json"] atomically:YES];
            });
        });
    });return ok;
}
@end
