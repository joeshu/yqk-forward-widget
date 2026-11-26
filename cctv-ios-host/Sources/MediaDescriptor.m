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
        // 门禁与可播判定统一到 MediaPlaybackDecodeRouter（单一决策点）：
        // 拒绝原因非空 → unsupported + 该原因；有候选 → recognized。
        NSString *rejection=MediaPlaybackDecodeRouteRejectionReasonForResult(_result);
        if(rejection){_capabilityStatus=@"unsupported";_capabilityReason=rejection;}
        else if(MediaPlaybackDecodeRouteCandidatesForResult(_result,0,NO).count){_capabilityStatus=@"recognized";}
    }return self;
}
@end
