// CNPlayerSDK.h —— 仅声明宿主实际调用的接口（官方 framework 未附带头文件）
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CNPlayer : NSObject
// 启动
+ (void)startPlayerSDK_Options:(id)options;
+ (void)startPlayerSDK_AppKey:(NSString *)appKey appSecret:(NSString *)appSecret;
+ (id)defaultOptions;
+ (void)logEnabled:(BOOL)enabled;
// 端点注入（不调用则使用 SDK 默认值）
+ (void)configSDK_LiveVDNUrl_V2th:(NSString *)url;
+ (void)configSDK_CICADA_UDRMUrl:(NSString *)url;
+ (void)configSDK_HTTP_Origin:(NSString *)origin;
+ (void)configSDK_HTTP_Refer:(NSString *)refer;
// 播放
+ (id)playLIVEWithChannelID:(NSString *)channelID
                   delegate:(nullable id)delegate
              configOptions:(nullable NSDictionary *)options;
@property (nonatomic, readonly, nullable) UIView *view;
- (void)prepareToPlay;
- (void)play;
- (void)pause;
- (void)stop;
- (void)switchToRateNumber:(int)number completionBlock:(nullable void (^)(NSError *_Nullable))block;
@end

NS_ASSUME_NONNULL_END
