#import "AppDelegate.h"
#import "RootViewController.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import <mach/mach.h>

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
    task_vm_info_data_t memoryInfo = {0};
    mach_msg_type_number_t memoryInfoCount = TASK_VM_INFO_COUNT;
    NSMutableDictionary *fields = [@{
        @"application_state":stateName,
        @"process_uptime_seconds":@(NSProcessInfo.processInfo.systemUptime),
        @"app_version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"app_build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"ios_version":UIDevice.currentDevice.systemVersion ?: @"unknown"
    } mutableCopy];
    if (RuntimeDiagnostics.shared.enabled && task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memoryInfo, &memoryInfoCount) == KERN_SUCCESS)
        fields[@"process_phys_footprint_bytes"] = @(memoryInfo.phys_footprint);
    return fields;
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
