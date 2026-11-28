#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import "MediaPlaybackMPVAdapter.h"
#import "MediaPlaybackFullscreenHost.h"
#import "RuntimeDiagnostics.h"

// The adapter and fullscreen view are production code. Diagnostics are stubbed
// because this minimal app has no persistent CCTVHost services.
@implementation RuntimeDiagnostics
+ (instancetype)shared { static RuntimeDiagnostics *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance=[self new]; }); return instance; }
- (BOOL)isEnabled { return NO; }
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary *)fields { NSLog(@"diagnostic %@ %@ %@",category,event,fields); }
@end

@interface MPVSmokeApp : UIResponder <UIApplicationDelegate, MediaPlaybackCicadaAdapterDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIViewController *root;
@property(nonatomic,strong) MediaPlaybackMPVAdapter *adapter;
@property(nonatomic,strong) MediaPlaybackFullscreenHost *host;
@property(nonatomic) NSInteger round;
@property(nonatomic) BOOL finished;
@property(nonatomic,copy) NSString *documents;
- (void)enterFullscreen;
- (void)exitFullscreen;
- (void)waitForProgressAfter:(NSTimeInterval)before deadline:(NSDate *)deadline;
- (void)waitForScreenshotUntil:(NSDate *)deadline;
@end

@implementation MPVSmokeApp
- (void)finish:(NSString *)error {
    if(self.finished)return;
    self.finished=YES;
    [self.adapter destroy];
    [self.adapter destroy];
    NSDictionary *result=@{@"passed":@(!error),@"error":error?:@"",@"rounds":@(self.round),@"position":@(self.adapter.currentPosition)};
    NSString *path=[self.documents stringByAppendingPathComponent:@"mpv-results.json"];
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:path atomically:YES];
    NSLog(@"MPV_SMOKE_RESULT %@",result);
}
- (void)mount:(UIView *)view in:(UIView *)container {
    [container insertSubview:view atIndex:0];
    view.frame=container.bounds;
    view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [container layoutIfNeeded];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.root=[UIViewController new];
    self.root.view.backgroundColor=UIColor.blackColor;
    self.window.rootViewController=self.root;
    [self.window makeKeyAndVisible];
    self.documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    if(![MediaPlaybackMPVAdapter isAvailable]){[self finish:@"CCTVMPVCore unavailable"];return YES;}
    NSURL *url=[NSBundle.mainBundle URLForResource:@"fixture" withExtension:@"mp4"];
    self.adapter=[[MediaPlaybackMPVAdapter alloc] initWithURL:url headers:@{} networkTimeout:10];
    self.adapter.delegate=self;
    [self mount:self.adapter.playerView in:self.root.view];
    [self.adapter prepareWithHardwareDecoder:NO];
    [self.adapter start];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,180*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self finish:@"timed out waiting for MPV playback or fullscreen transitions"];});
    return YES;
}
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter {
    if(adapter!=self.adapter||self.finished)return;
    [self enterFullscreen];
}
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error {
    if(adapter==self.adapter)[self finish:error.localizedDescription?:@"MPV failed"];
}
- (void)cicadaAdapterDidComplete:(id)adapter {
    if(adapter!=self.adapter||self.finished)return;
    [self finish:@"fixture ended before fullscreen smoke completed"];
}
- (void)enterFullscreen {
    if(self.finished)return;
    self.host=[MediaPlaybackFullscreenHost new];
    self.host.modalPresentationStyle=UIModalPresentationOverFullScreen;
    [self.root presentViewController:self.host animated:NO completion:^{
        if(self.finished)return;
        if(self.host.view.window!=self.window||self.adapter.playerView.window!=self.window){[self finish:@"fullscreen hosts are not in the same window"];return;}
        [self mount:self.adapter.playerView in:self.host.view];
        CAMetalLayer *layer=(CAMetalLayer *)self.adapter.playerView.layer;
        if(![layer isKindOfClass:CAMetalLayer.class]||layer.drawableSize.width<=1||layer.drawableSize.height<=1){[self finish:@"invalid Metal drawable after fullscreen entry"];return;}
        NSTimeInterval before=self.adapter.currentPosition;
        [self waitForProgressAfter:before deadline:[NSDate dateWithTimeIntervalSinceNow:8]];
    }];
}
- (void)waitForProgressAfter:(NSTimeInterval)before deadline:(NSDate *)deadline {
    if(self.finished)return;
    if(self.adapter.currentPosition>before+0.15){
        if(self.round==0){
            [@"ready" writeToFile:[self.documents stringByAppendingPathComponent:@"mpv-frame-ready"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            [self waitForScreenshotUntil:[NSDate dateWithTimeIntervalSinceNow:90]];
            return;
        }
        [self exitFullscreen];
        return;
    }
    if(deadline.timeIntervalSinceNow<=0){[self finish:@"MPV position did not advance in fullscreen"];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self waitForProgressAfter:before deadline:deadline];});
}
- (void)waitForScreenshotUntil:(NSDate *)deadline {
    if(self.finished)return;
    if([NSFileManager.defaultManager fileExistsAtPath:[self.documents stringByAppendingPathComponent:@"mpv-frame-captured"]]){[self exitFullscreen];return;}
    if(deadline.timeIntervalSinceNow<=0){[self finish:@"fullscreen screenshot was not captured"];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self waitForScreenshotUntil:deadline];});
}
- (void)exitFullscreen {
    if(self.finished)return;
        [self mount:self.adapter.playerView in:self.root.view];
        [self.host dismissViewControllerAnimated:NO completion:^{
            self.host=nil;
            self.round++;
            if(self.round>=3){[self finish:nil];return;}
            [self.adapter seekToTime:0 completion:^(BOOL ok){
                if(!ok){[self finish:@"seek failed between fullscreen cycles"];return;}
                [self enterFullscreen];
            }];
        }];
}
@end

int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(MPVSmokeApp.class)); }
}
