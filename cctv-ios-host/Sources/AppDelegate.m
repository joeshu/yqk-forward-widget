#import "AppDelegate.h"
#import "RootViewController.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"

@interface HostNavigationController : UINavigationController
@end

@implementation HostNavigationController
- (BOOL)shouldAutorotate { return self.topViewController.shouldAutorotate; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.topViewController.supportedInterfaceOrientations; }
@end

@implementation AppDelegate

- (NSDictionary *)diagnosticLifecycleFields {
    UIApplicationState state = UIApplication.sharedApplication.applicationState;
    NSString *stateName = state == UIApplicationStateActive ? @"active" : (state == UIApplicationStateBackground ? @"background" : @"inactive");
    return @{
        @"application_state":stateName,
        @"process_uptime_seconds":@(ProcessInfo.processInfo.systemUptime),
        @"app_version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"app_build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"ios_version":UIDevice.currentDevice.systemVersion ?: @"unknown"
    };
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [RuntimeDiagnostics.shared beginAppSessionWithFields:[self diagnosticLifecycleFields]];
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

- (void)applicationWillResignActive:(UIApplication *)application {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"app_will_resign_active" fields:[self diagnosticLifecycleFields]];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"entered_background" fields:[self diagnosticLifecycleFields]];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"entered_foreground" fields:[self diagnosticLifecycleFields]];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"app_became_active" fields:[self diagnosticLifecycleFields]];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"memory_warning_received" fields:[self diagnosticLifecycleFields]];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [RuntimeDiagnostics.shared endAppSession];
}

@end
