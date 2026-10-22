// CicadaSDK.h —— 仅声明宿主实际调用的接口（官方 framework 未附带头文件）
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CicadaConfig : NSObject
@property (nonatomic) BOOL isNeedUDRMDecrypt_pvt;
@property (nonatomic, copy, nullable) NSString *udrmLicenseUrl;
@property (nonatomic, copy, nullable) NSString *macAddress;
@property (nonatomic) int networkTimeout;
@property (nonatomic, copy, nullable) NSString *userAgent;
@property (nonatomic, copy, nullable) NSString *referer;
@end

@interface CicadaUrlSource : NSObject
+ (instancetype)urlWithString:(NSString *)url;
@end

@interface CicadaPlayer : NSObject
- (void)setConfig:(CicadaConfig *)config;
- (void)setUrlSource:(CicadaUrlSource *)source;
- (void)setPlayerView:(UIView *)view;
- (void)setDelegate:(nullable id)delegate;
- (void)setEnableHardwareDecoder:(BOOL)on;
- (void)prepare;
- (void)start;
- (void)pause;
- (void)stop;
- (void)destroy;
@end

NS_ASSUME_NONNULL_END
