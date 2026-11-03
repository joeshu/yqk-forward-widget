// UI simulator target only. The production CicadaPlayer binary is a device
// framework and is intentionally not linked into the simulator smoke app.
// These no-op classes satisfy the host's Objective-C references; they do not
// model playback, decoding, DRM, or network behavior.
#import "CicadaSDK.h"

@implementation CicadaConfig
- (instancetype)init {
    self = [super init];
    if (self) _httpHeaders = [NSMutableArray array];
    return self;
}
@end

@interface CicadaUrlSource ()
@property (nonatomic, copy) NSString *smokeURL;
@end

@implementation CicadaUrlSource
- (instancetype)urlWithString:(NSString *)url {
    self = [super init];
    if (self) self.smokeURL = [url copy];
    return self;
}
@end

@implementation CicadaPlayer
- (void)setConfig:(CicadaConfig *)config {}
- (void)setUrlSource:(CicadaUrlSource *)source {}
- (void)prepare {}
- (void)start {}
- (void)pause {}
- (void)stop {}
- (void)destroy {}
- (void)seekToTime:(int64_t)time seekMode:(CicadaSeekMode)seekMode {}
@end

@implementation CicadaErrorModel
@end

@implementation CicadaPlayerView
@end
