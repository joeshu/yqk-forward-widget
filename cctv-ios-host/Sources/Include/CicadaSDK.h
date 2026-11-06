// Minimal public CicadaPlayer declarations used by the VOD playback adapter.
// The bundled framework is the Alibaba CicadaPlayer SDK already linked by the app.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CicadaPlayer;
@class CicadaErrorModel;

typedef NS_ENUM(NSUInteger, CicadaStatus) {
    CicadaStatusIdle = 0,
    CicadaStatusInitialized,
    CicadaStatusPrepared,
    CicadaStatusStarted,
    CicadaStatusPaused,
    CicadaStatusStopped,
    CicadaStatusCompletion,
    CicadaStatusError,
    CicadaStatusMax,
};

typedef NS_ENUM(NSUInteger, CicadaSeekMode) {
    CICADA_SEEKMODE_ACCURATE = 0x01,
    CICADA_SEEKMODE_INACCURATE = 0x10,
};

typedef NS_ENUM(NSUInteger, CicadaScalingMode) {
    CICADA_SCALINGMODE_SCALETOFILL = 0,
    CICADA_SCALINGMODE_SCALEASPECTFIT,
    CICADA_SCALINGMODE_SCALEASPECTFILL,
};

typedef NS_ENUM(NSUInteger, CicadaEventType) {
    CicadaEventPrepareDone = 0,
    CicadaEventAutoPlayStart,
    CicadaEventFirstRenderedStart,
    CicadaEventCompletion,
    CicadaEventLoadingStart,
    CicadaEventLoadingEnd,
    CicadaEventSeekEnd,
    CicadaEventLoopingStart,
};

@protocol CicadaDelegate <NSObject>
@optional
- (void)onPlayerEvent:(CicadaPlayer *)player eventType:(CicadaEventType)eventType;
- (void)onError:(CicadaPlayer *)player errorModel:(CicadaErrorModel *)errorModel;
- (void)onPlayerStatusChanged:(CicadaPlayer *)player oldStatus:(CicadaStatus)oldStatus newStatus:(CicadaStatus)newStatus;
- (void)onCurrentPositionUpdate:(CicadaPlayer *)player position:(int64_t)position;
- (void)onBufferedPositionUpdate:(CicadaPlayer *)player position:(int64_t)position;
- (void)onLoadingProgress:(CicadaPlayer *)player progress:(float)progress;
- (void)onCurrentDownLoadSpeed:(CicadaPlayer *)player progress:(float)speed;
- (void)onVideoSizeChanged:(CicadaPlayer *)player width:(int)width height:(int)height rotation:(int)rotation;
- (void)onVideoRendered:(CicadaPlayer *)player timeMs:(int64_t)timeMs pts:(int64_t)pts;
@end

@interface CicadaConfig : NSObject
@property (nonatomic) BOOL isNeedUDRMDecrypt_pvt;
@property (nonatomic, copy, nullable) NSString *udrmLicenseUrl;
@property (nonatomic, copy, nullable) NSString *macAddress;
@property (nonatomic) int networkTimeout;
@property (nonatomic) int networkRetryCount;
@property (nonatomic, copy, nullable) NSString *userAgent;
@property (nonatomic, copy, nullable) NSString *referer;
@property (nonatomic, copy) NSMutableArray<NSString *> *httpHeaders;
@end

@interface CicadaUrlSource : NSObject
- (instancetype)urlWithString:(NSString *)url;
@end

@interface CicadaPlayer : NSObject
- (void)setConfig:(CicadaConfig *)config;
- (void)setUrlSource:(CicadaUrlSource *)source;
- (void)setPlayerView:(UIView *)view;
- (void)setDelegate:(nullable id<CicadaDelegate>)delegate;
- (void)prepare;
- (void)start;
- (void)pause;
- (void)stop;
- (void)destroy;
- (void)seekToTime:(int64_t)time seekMode:(CicadaSeekMode)seekMode;
@property (nonatomic, weak, nullable) id<CicadaDelegate> delegate;
@property (nonatomic, strong, nullable) UIView *playerView;
@property (nonatomic) BOOL enableHardwareDecoder;
@property (nonatomic) BOOL autoPlay;
@property (nonatomic) float rate;
@property (nonatomic) CicadaScalingMode scalingMode;
@property (nonatomic) int64_t currentPosition;
@property (nonatomic) int64_t bufferedPosition;
@property (nonatomic) int64_t duration;
@end

@interface CicadaErrorModel : NSObject
@property (nonatomic) NSInteger code;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, copy, nullable) NSString *requestId;
@end

@interface CicadaPlayerView : UIView
@end

NS_ASSUME_NONNULL_END
