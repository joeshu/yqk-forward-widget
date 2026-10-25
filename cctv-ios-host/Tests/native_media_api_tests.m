#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "MediaAPIClient.h"
#import "RuntimeDiagnostics.h"

@implementation RuntimeDiagnostics
+ (instancetype)shared {static RuntimeDiagnostics *value;static dispatch_once_t once;dispatch_once(&once,^{value=[RuntimeDiagnostics new];});return value;}
- (BOOL)isEnabled {return NO;}
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields {}
@end

static void check(BOOL condition,NSString *message){if(!condition){NSLog(@"FAILED: %@",message);exit(1);}}
static id call(MediaAPIClient *client,NSString *operation,NSDictionary *arguments,NSError **error){
    __block BOOL done=NO;__block id result=nil;__block NSError *failure=nil;
    [client call:operation arguments:arguments completion:^(id value,NSError *requestError){result=value;failure=requestError;done=YES;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];while(!done&&[deadline timeIntervalSinceNow]>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    check(done,[NSString stringWithFormat:@"%@ callback completed",operation]);if(error)*error=failure;return result;
}
int main(int argc,const char **argv){@autoreleasepool{
    check(argc==2,@"server port supplied");NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%@/api.php?token=fixture&mode=tvbox",[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *source=@{@"id":@"tvbox-test",@"name":@"Fixture CMS",@"protocol":@"tvbox-api",@"tvboxType":@4,@"api":base,@"options":@"{\"region\":\"cn\"}",@"header":@{@"X-Fixture":@"header",@"Referer":@"https://source.example/",@"Host":@"invalid.example"}};
    MediaAPIClient *client=[[MediaAPIClient alloc] initWithTVBoxSource:source];NSError *error=nil;
    NSDictionary *home=call(client,@"home",@{},&error);check(!error&&[home[@"categories"] count]==1&&[home[@"items"][0][@"id"] isEqual:@"home-1"]&&[home[@"items"][0][@"poster"] isEqual:[NSString stringWithFormat:@"http://127.0.0.1:%@/poster.jpg",[NSString stringWithUTF8String:argv[1]]]]&&[home[@"filters"][@"movie"] count]==1,@"type 4 home normalizes categories, relative poster URLs, content, and filter choices");
    NSDictionary *category=call(client,@"category",@{@"categoryId":@"movie",@"page":@1,@"filters":@{@"area":@"cn",@"pg":@99}},&error);check(!error&&[category[@"hasMore"] boolValue],@"category pagination can derive page count from total/limit");
    NSDictionary *search=call(client,@"search",@{@"keyword":@"fixture",@"page":@2},&error);check(!error&&[search[@"page"] integerValue]==2&&[search[@"items"][0][@"name"] isEqual:@"Search fixture"],@"search result fields normalize");
    NSDictionary *detail=call(client,@"detail",@{@"id":@"film-1"},&error);check(!error&&[detail[@"lines"] count]==2&&[detail[@"lines"][0][@"episodes"][0][@"id"] isEqual:@"episode-1"],@"detail maps route flags and episodes");
    NSDictionary *play=call(client,@"play",@{@"id":@"episode-1",@"lineId":@"线路一"},&error);check(!error&&[play[@"url"] isEqual:@"https://cdn.example/low.m3u8"]&&[play[@"alternates"] count]==2, @"type 4 play response normalizes prefixed quality choices");check([play[@"headers"][@"Referer"] isEqual:@"https://source.example/"]&&[play[@"headers"][@"X-Playback"] isEqual:@"fixture"]&&[play[@"headers"][@"User-Agent"] isEqual:@"FixtureUA/1"],@"source and resolver playback headers are combined");
    NSDictionary *webPlay=call(client,@"play",@{@"id":@"web-episode",@"lineId":@"线路一"},&error);check(!error&&[webPlay[@"parse"] boolValue]&&[webPlay[@"jx"] boolValue]&&[webPlay[@"requiresWebPlayback"] boolValue],@"resolver flags survive normalization and request web playback handoff");
    NSError *apiError=nil;call(client,@"search",@{@"keyword":@"fail",@"page":@1},&apiError);check(apiError&&[apiError.localizedDescription containsString:@"fixture denied"],@"TVBox error message without content is reported as an API failure");
    NSDictionary *empty=call(client,@"search",@{@"keyword":@"empty",@"page":@1},&error);check(!error&&[empty[@"items"] count]==0,@"code 0 with a valid empty list is accepted");
    NSDictionary *type1=[@{@"id":@"tvbox-type1",@"protocol":@"tvbox-api",@"tvboxType":@1,@"api":base,@"playUrl":@"https://cdn.example/",@"header":@{@"Referer":@"https://type1.example/"}} copy];MediaAPIClient *direct=[[MediaAPIClient alloc] initWithTVBoxSource:type1];NSDictionary *directPlay=call(direct,@"play",@{@"id":@"episode.m3u8"},&error);check(!error&&[directPlay[@"url"] isEqual:@"https://cdn.example/episode.m3u8"]&&[directPlay[@"headers"][@"Referer"] isEqual:@"https://type1.example/"],@"type 1 direct playback applies source prefix and headers");
    NSLog(@"Native TVBox JSON API adapter tests passed");
}return 0;}
