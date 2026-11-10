#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "MediaJARRuntime.h"
void RunCicadaAdapterProbe(void (^completion)(BOOL,NSString *));
@interface JARSmokeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) MediaJARRequest *request;
@property(nonatomic,strong) AVPlayer *player;
@property(nonatomic,strong) AVPlayerLayer *layer;
@property(nonatomic,strong) NSMutableArray *results;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic) NSInteger step;
@property(nonatomic,copy) NSString *origin;
@end
@implementation JARSmokeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[UIViewController new];self.window.rootViewController.view.backgroundColor=UIColor.blackColor;[self.window makeKeyAndVisible];self.results=[NSMutableArray array];
    NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger index=[args indexOfObject:@"--port"];
    NSString *port=index!=NSNotFound&&index+1<args.count?args[index+1]:@"0";self.origin=[@"http://127.0.0.1:" stringByAppendingString:port];
    NSString *ext=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"mediaURL":[self.origin stringByAppendingString:@"/video.mp4"]} options:0 error:NULL] encoding:NSUTF8StringEncoding];
    self.source=@{@"id":@"fixture",@"protocol":@"jar-bridge",@"api":@"csp_CCTVFixture",@"tvboxSiteKey":@"fixture",@"subscriptionURL":[self.origin stringByAppendingString:@"/config.json"],@"jar":@{@"url":[self.origin stringByAppendingString:@"/fixture.jar"]},@"header":@{@"X-Jar-Fixture":@"jar-only"},@"options":ext};
    dispatch_async(dispatch_get_main_queue(),^{[self next];});return YES;
}
- (void)save:(BOOL)passed message:(NSString *)message {
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"message":message?:@"",@"steps":self.results} options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToFile:[documents stringByAppendingPathComponent:@"jar-results.json"] atomically:YES];
}
- (void)next {
    NSArray *ops=@[@"home",@"category",@"search",@"detail",@"play"];
    NSArray *args=@[@{},@{@"categoryId":@"movie",@"page":@2,@"filters":@{@"area":@"测试地区"}},@{@"keyword":@"中文😀+&",@"page":@2},@{@"id":@"fixture"},@{@"id":@"opaque+id%26signed",@"lineId":@"fixture",@"detailId":@"fixture"}];
    NSInteger step=self.step;CFTimeInterval start=CACurrentMediaTime();
    self.request=[MediaJARRuntime requestSource:self.source operation:ops[(NSUInteger)step] arguments:args[(NSUInteger)step] completion:^(id raw,NSError *error){
        if(error){[self save:NO message:[NSString stringWithFormat:@"%@ (%ld)",error.domain,(long)error.code]];return;}
        BOOL valid=[raw isKindOfClass:NSDictionary.class];
        if(step==0)valid=valid&&[raw[@"class"] count]==1&&[raw[@"list"] count]==1;
        if(step==1)valid=valid&&[raw[@"list"][0][@"vod_name"] isEqual:@"测试地区"];
        if(step==2)valid=valid&&[raw[@"list"][0][@"vod_name"] isEqual:@"中文😀+&"];
        if(step==3)valid=valid&&[raw[@"list"][0][@"vod_play_url"] hasSuffix:@"opaque+id%26signed"];
        if(step==4)valid=valid&&[raw[@"url"] isEqual:[self.origin stringByAppendingString:@"/video.mp4"]];
        [self.results addObject:@{@"operation":ops[(NSUInteger)step],@"passed":@(valid),@"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-start)*1000))}];
        if(!valid){[self save:NO message:@"Unexpected DEX fixture response"];return;}
        self.step++;
        if(self.step<5)[self next];else[self render:raw];
    }];
}
- (void)render:(NSDictionary *)result {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL URLWithString:result[@"url"]] options:@{@"AVURLAssetHTTPHeaderFieldsKey":result[@"header"]?:@{}}];
    self.player=[AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];self.layer=[AVPlayerLayer playerLayerWithPlayer:self.player];self.layer.frame=self.window.rootViewController.view.bounds;[self.window.rootViewController.view.layer addSublayer:self.layer];[self.player play];
    [self checkFrame:0];
}
- (void)checkFrame:(NSUInteger)count {
    if(self.layer.readyForDisplay&&CMTimeGetSeconds(self.player.currentTime)>0.1){
        [self.results addObject:@{@"operation":@"AVPlayer video frame after JAR resolution",@"passed":@YES}];
        RunCicadaAdapterProbe(^(BOOL passed,NSString *message){[self.results addObject:@{@"operation":@"Cicada adapter state/first-frame/buffer/seek",@"passed":@(passed)}];[self save:passed message:message];});return;
    }
    if(count>=150||self.player.currentItem.status==AVPlayerItemStatusFailed){[self save:NO message:@"AVPlayer fixture frame did not render"];return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{[self checkFrame:count+1];});
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(JARSmokeApp.class));}}
