#import <Foundation/Foundation.h>
#import "NativeChannelPreloader.h"
static void check(BOOL ok,NSString *why){if(!ok){NSLog(@"FAILED: %@",why);exit(1);}}
static void drain(void){[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];}
@interface MetadataPlayer : NSObject
@property(nonatomic) BOOL autoPlay;
@property(nonatomic,weak) id delegate;
@property(nonatomic) NSUInteger configured,resets;
@property(nonatomic,copy) void (^completion)(BOOL,NSError *);
- (BOOL)playLIVEWithChannelID:(NSString *)channel delegate:(id)delegate configOptions:(NSDictionary *)options;
- (void)prepareRateItemToPlay_completionBlock:(void (^)(BOOL,NSError *))completion;
- (void)reset;
@end
@implementation MetadataPlayer
- (BOOL)playLIVEWithChannelID:(NSString *)channel delegate:(id)delegate configOptions:(NSDictionary *)options {self.configured++;self.delegate=delegate;check([options[@"CNPlayerConfigOptionKey_Title"] length]>0,@"title supplied");return YES;}
- (void)prepareRateItemToPlay_completionBlock:(void (^)(BOOL,NSError *))completion{self.completion=completion;check(!self.autoPlay,@"metadata preparation cannot auto play");}
- (void)reset{self.resets++;self.delegate=nil;}
@end
int main(void){@autoreleasepool{
    __block NSTimeInterval now=100;__block MetadataPlayer *latest;
    NativeChannelPreloader *p=[[NativeChannelPreloader alloc] initWithFactory:^id{latest=[MetadataPlayer new];return latest;} clock:^NSTimeInterval{return now;}];
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];
    MetadataPlayer *first=latest;
    check(!first.autoPlay && first.configured==1,@"metadata configured once without autoplay");
    check([p takeChannel:@"cctv2"]==nil && first.resets==1,@"incomplete metadata never transferred");
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];first=latest;first.completion(YES,nil);drain();
    id taken=[p takeChannel:@"cctv2"];
    check(taken==first && first.resets==0 && first.delegate==nil,@"handoff keeps prepared item and detaches temporary delegate");
    check([p takeChannel:@"cctv2"]==nil,@"handoff can occur only once");
    [p prepareChannel:@"cctv3" title:@"CCTV-3"];first=latest;first.completion(YES,nil);drain();now+=16;
    check([p takeChannel:@"cctv3"]==nil && first.resets==1,@"expired metadata reset instead of played");
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];first=latest;void (^stale)(BOOL,NSError *)=first.completion;
    [p prepareChannel:@"cctv3" title:@"CCTV-3"];MetadataPlayer *second=latest;stale(YES,nil);drain();
    check([p takeChannel:@"cctv3"]==nil && second.resets==1,@"stale completion cannot make replacement ready");
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];first=latest;first.completion(YES,nil);drain();
    check([p takeChannel:@"cctv3"]==nil && first.resets==1,@"different channel never consumes cached metadata");
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];first=latest;first.completion(NO,[NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);drain();
    check([p takeChannel:@"cctv2"]==nil && first.resets==1,@"failed metadata discarded");
    [p prepareChannel:@"cctv2" title:@"CCTV-2"];first=latest;[p cancel];first.completion(YES,nil);drain();
    check([p takeChannel:@"cctv2"]==nil,@"cancelled work cannot be revived");
    NativeChannelPreloader *unsupported=[[NativeChannelPreloader alloc] initWithFactory:^id{return [NSObject new];} clock:^NSTimeInterval{return now;}];
    [unsupported prepareChannel:@"cctv2" title:@"CCTV-2"];check([unsupported takeChannel:@"cctv2"]==nil,@"unknown SDK safely ignored");
    puts("metadata preloader lifecycle checks passed");
}return 0;}
