#import <Foundation/Foundation.h>
#import "NativeCDNPreference.h"

static NSDictionary *stored;
static NSUInteger writes;
static NSString *rejectedHost,*ignoredHost;
static void check(BOOL ok,NSString *message){if(!ok){NSLog(@"FAILED: %@",message);exit(1);}}
@interface CDNConfigFixture : NSObject
+ (NSDictionary *)getVDNConfig_CDNLive_DefaultCDNInfo;
@end
@implementation CDNConfigFixture
+ (NSDictionary *)getVDNConfig_CDNLive_DefaultCDNInfo {return stored;}
@end
@interface CDNPlayerFixture : NSObject
+ (id)configSDK_CDN_LIVEDefaultCDNInfo:(NSDictionary *)value;
@end
@implementation CDNPlayerFixture
+ (id)configSDK_CDN_LIVEDefaultCDNInfo:(NSDictionary *)value {
    writes++;check([value isKindOfClass:NSDictionary.class],@"SDK receives dictionary, never an array/model");
    check([value[@"cdn_vip"] isKindOfClass:NSString.class],@"cdn_vip is a domain string");
    if([value[@"cdn_vip"] isEqual:rejectedHost])return [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    if(![value[@"cdn_vip"] isEqual:ignoredHost])stored=value.copy;
    return nil;
}
@end
@interface CDNObservedFixture : NSObject
@property(nonatomic,strong) id p_cdn;
@end
@implementation CDNObservedFixture @end
int main(void){@autoreleasepool {
    NSDictionary *baseline=@{@"cdn_code":@"default",@"cdn_name":@"Default",@"cdn_vip":@"default.test",@"extraSDKField":@"preserved"};stored=baseline;
    NativeCDNPreference *preference=[[NativeCDNPreference alloc] initWithPlayerClass:CDNPlayerFixture.class configurationClass:CDNConfigFixture.class];
    NSDictionary *ws=@{@"provider":@"WS",@"url":@"https://ws.test/channel/index.m3u8?signature=do-not-store"};NSError *error=nil;
    check([preference applyRoute:ws error:&error],@"real class split for setter/getter accepts route");
    check([stored[@"cdn_vip"] isEqual:@"ws.test"]&&[stored[@"cdn_code"] isEqual:@"ws"],@"host, not full signed URL or numeric flag, reaches SDK");
    check([stored[@"extraSDKField"] isEqual:@"preserved"],@"unrelated SDK fields survive preference changes");
    check(preference.overrideMayBeActive&&![stored.description containsString:@"do-not-store"],@"tracks configured preference without copying signatures");
    rejectedHost=@"bd.test";
    check(![preference applyRoute:@{@"provider":@"bd",@"url":@"https://bd.test/live"} error:&error],@"SDK error is not reported as successful node selection");
    check([stored[@"cdn_vip"] isEqual:@"ws.test"]&&preference.overrideMayBeActive,@"failed switch restores the previous preference");
    rejectedHost=nil;ignoredHost=@"ks.test";
    check(![preference applyRoute:@{@"provider":@"ks",@"url":@"https://ks.test/live"} error:&error],@"ignored writes fail the readback check");
    check([stored[@"cdn_vip"] isEqual:@"ws.test"],@"readback mismatch does not overwrite previous selection");
    ignoredHost=nil;rejectedHost=@"default.test";
    check(![preference restoreDefault:&error]&&preference.overrideMayBeActive,@"failed automatic restore keeps the override tracked");
    rejectedHost=nil;check([preference restoreDefault:&error]&&[stored isEqual:baseline]&&!preference.overrideMayBeActive,@"automatic route restores the captured SDK dictionary");
    NSUInteger before=writes;
    for(NSString *url in @[@"file:///etc/test",@"https://user:pass@ws.test/live",@"https://ws.test:444/live",@"invalid"])
        check(![preference applyRoute:@{@"provider":@"ws",@"url":url} error:&error],@"unsupported or credential-bearing source rejected before mutation");
    check(writes==before,@"invalid routes never mutate global SDK state");
    NativeCDNPreference *missing=[[NativeCDNPreference alloc] initWithPlayerClass:CDNPlayerFixture.class configurationClass:NSObject.class];
    check(![missing applyRoute:ws error:&error]&&writes==before,@"missing manager getter cannot be mistaken for successful configuration");
    NativeCDNPreference *noSetter=[[NativeCDNPreference alloc] initWithPlayerClass:NSObject.class configurationClass:CDNConfigFixture.class];
    check(![noSetter applyRoute:ws error:&error]&&writes==before&&!noSetter.overrideMayBeActive,@"unsupported setter fails before reserving an override");
    CDNObservedFixture *observed=[CDNObservedFixture new];observed.p_cdn=@{@"cdn_vip":@"https://user:pass@actual.test/live?token=secret"};
    check([[NativeCDNPreference observedCDNDescriptionForPlayer:observed] isEqual:@"actual.test"],@"observed node comes from SDK model and shows only host");
    check([[NativeCDNPreference observedCDNDescriptionForPlayer:NSObject.new] hasPrefix:@"未知"],@"unsupported SDK diagnostics stay unknown");
    puts("CDN configuration, rollback and observation checks passed");
}return 0;}
