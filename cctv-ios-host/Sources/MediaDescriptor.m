#import "MediaDescriptor.h"
#import "MediaPlaybackHeaders.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaCapabilityRegistry.h"
@implementation MediaDescriptor
- (instancetype)initWithResult:(NSDictionary *)result {
    if((self=[super init])){
        _result=[result isKindOfClass:NSDictionary.class]?[result copy]:@{};
        NSString *address=[_result[@"url"] isKindOfClass:NSString.class]?_result[@"url"]:@"";
        _url=[NSURL URLWithString:address];_transport=_url.scheme.lowercaseString?:@"";
        _headers=MediaPlaybackHeadersFromResult(_result);
        _container=[_result[@"probedContainer"] isKindOfClass:NSString.class]?[_result[@"probedContainer"] lowercaseString]:(_url.pathExtension.lowercaseString?:@"");
        _capabilityStatus=@"unknown";_capabilityReason=@"requires_device_playback_validation";
        if(MediaPlaybackResultRequiresWebViewOnly(_result)){_capabilityStatus=@"unsupported";_capabilityReason=@"unsupported_container";}
        else if([_result[@"videoCodec"] isKindOfClass:NSString.class]&&[MediaCapabilityUnsupportedVideoCodecs() containsObject:[_result[@"videoCodec"] lowercaseString]]){_capabilityStatus=@"unsupported";_capabilityReason=@"unsupported_video_codec";}
        else if(![MediaCapabilityNetworkTransports() containsObject:_transport]&&!_url.isFileURL){_capabilityStatus=@"unsupported";_capabilityReason=@"unsupported_transport";}
        else if(MediaPlaybackResultSupportsNativePlayback(_result)){_capabilityStatus=@"recognized";}
    }return self;
}
@end
