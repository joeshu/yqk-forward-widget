// UI test target only: models the legacy wrapper lifecycle and callback ordering.
#import "CNPlayerSDK.h"
#import <UIKit/UIKit.h>
@protocol CNPlayerCallbackProtocol <NSObject>
@end
@interface NSObject (SmokeCallbacks)
- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state;
- (void)player:(id)player loadStateDidChanged:(NSUInteger)state;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
@end
@interface CNPlayer ()
@property(nonatomic, strong) UIView *view;
@property(nonatomic, weak) id delegate;
@property(nonatomic, assign) BOOL autoPlay;
@property(nonatomic, assign) BOOL isPlaying;
@property(nonatomic, assign) NSUInteger preparation;
@end
static NSInteger resets, plays, configures;
static id cdnPreference;
@interface IJKFFMoviePlayerController : NSObject
- (UIImage *)thumbnailImageAtCurrentTime;
@end
@implementation IJKFFMoviePlayerController
- (UIImage *)thumbnailImageAtCurrentTime {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"UIGraphicsBeginImageContext failed for zero-sized frame"
                                 userInfo:nil];
}
@end
@implementation CNPlayer
- (instancetype)init {
    if (self = [super init])
        _view = [UIView new];
    return self;
}
+ (void)startPlayerSDK_Options:(id)options {
}
+ (void)startPlayerSDK_AppKey:(NSString *)key appSecret:(NSString *)secret {
}
+ (id)defaultOptions {
    return @{};
}
+ (void)logEnabled:(BOOL)enabled {
}
+ (void)configSDK_LiveVDNUrl_V2th:(NSString *)url {
}
+ (void)configSDK_CICADA_UDRMUrl:(NSString *)url {
}
+ (void)configSDK_HTTP_Origin:(NSString *)origin {
}
+ (void)configSDK_HTTP_Refer:(NSString *)refer {
}
+ (void)configSDK_CDN_LIVEDefaultCDNInfo:(id)value {
    cdnPreference = value;
}
+ (id)getVDNConfig_CDNLive_DefaultCDNInfo {
    return cdnPreference;
}
+ (BOOL)authed {
    return YES;
}
+ (NSString *)SDKVersion {
    return @"UI-test-stub";
}
+ (NSInteger)smokeResetCount {
    return resets;
}
+ (NSInteger)smokeConfigureCount { return configures; }
+ (NSInteger)smokePlayCount {
    return plays;
}
+ (id)playLIVEWithChannelID:(NSString *)cid delegate:(id)delegate configOptions:(NSDictionary *)options {
    return nil;
}
- (BOOL)playLIVEWithChannelID:(NSString *)cid delegate:(id)delegate configOptions:(NSDictionary *)options {
    configures++;self.delegate = delegate;
    return YES;
}
- (void)prepareRateItemToPlay_completionBlock:(void (^)(BOOL,NSError *))completion {
    NSUInteger token=++self.preparation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{if(token==self.preparation)completion(YES,nil);});
}
- (void)prepareToPlay {
    NSUInteger token = ++self.preparation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      if (token != self.preparation)
          return;
      if (self.autoPlay)
          [self play];
      [self.delegate player:self vdnRequestStateDidChanged:3];
      [self.delegate player:self statEvent:2 value:nil];
      [self.delegate player:self statEvent:3 value:nil];
      [self.delegate player:self loadStateDidChanged:4];
    });
}
- (void)seekToStartTime:(double)start endTime:(double)end completionHandler:(void (^)(BOOL))completion {
    completion(YES);[self prepareToPlay];
}
- (void)backToLive {[self prepareToPlay];}
- (void)reset {
    resets++;
    self.preparation++;
    self.isPlaying = NO;
}
- (void)play {
    plays++;
    self.isPlaying = YES;
}
- (void)pause {
    self.isPlaying = NO;
}
- (void)stop {
    self.preparation++;
    self.isPlaying = NO;
}
- (void)switchToRateNumber:(int)number completionBlock:(void (^)(NSError *))block {
    if (block)
        block(nil);
}
@end
