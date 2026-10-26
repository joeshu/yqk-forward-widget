#import "AppDelegate.h"
#import "RootViewController.h"
#import "HostTheme.h"

@interface HostNavigationController : UINavigationController
@end

@implementation HostNavigationController
- (BOOL)shouldAutorotate { return self.topViewController.shouldAutorotate; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.topViewController.supportedInterfaceOrientations; }
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.window.backgroundColor=UIColor.clearColor;
    HostInstallGlassBackdrop(self.window);
    RootViewController *vc = [RootViewController new];
    UINavigationController *nav = [[HostNavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
