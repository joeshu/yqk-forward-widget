#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "MediaAPIClient.h"
#import "MediaPlaybackHeaders.h"
#import "RuntimeDiagnostics.h"
#import "TVBoxCatalogStore.h"

@implementation RuntimeDiagnostics
+ (instancetype)shared {static RuntimeDiagnostics *value;static dispatch_once_t once;dispatch_once(&once,^{value=[RuntimeDiagnostics new];});return value;}
- (BOOL)isEnabled {return NO;}
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields {}
@end

static void check(BOOL condition,NSString *message){if(!condition){NSLog(@"FAILED: %@",message);exit(1);}}
@interface MediaAPIClient (RequestIdentityProbe)
- (NSURLSession *)sessionForOperation:(NSString *)operation;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error;
@end
@interface MediaTaskIdentityFixture : NSObject
@property(nonatomic,readonly) NSUInteger taskIdentifier;
- (void)cancel;
@end
@implementation MediaTaskIdentityFixture
- (NSUInteger)taskIdentifier {return 7;}
- (void)cancel {}
@end
static void checkSessionTaskIsolation(void) {
    MediaAPIClient *client=[[MediaAPIClient alloc] initWithPort:1];
    NSURLSession *browse=[client valueForKey:@"session"],*play=[client sessionForOperation:@"play"];
    // Force a collision without assuming a Foundation task-counter starting
    // value or depending on the cancellation scheduling of real network tasks.
    NSURLSessionDataTask *old=(id)[MediaTaskIdentityFixture new],*current=(id)[MediaTaskIdentityFixture new];
    check(old!=current&&old.taskIdentifier==current.taskIdentifier,@"different API sessions can issue the same task identifier");
    id oldContext=[NSClassFromString(@"MediaAPIRequestContext") new],newContext=[NSClassFromString(@"MediaAPIRequestContext") new];
    [oldContext setValue:[NSMutableData data] forKey:@"data"];[newContext setValue:[NSMutableData data] forKey:@"data"];
    __block NSUInteger oldCalls=0,newCalls=0;
    [oldContext setValue:[^(NSData *data,NSURLResponse *response,NSError *error){oldCalls++;} copy] forKey:@"processor"];
    [newContext setValue:[^(NSData *data,NSURLResponse *response,NSError *error){check([data isEqual:[@"ready" dataUsingEncoding:NSUTF8StringEncoding]],@"play response bytes remain attached to the play task");newCalls++;} copy] forKey:@"processor"];
    NSMapTable *contexts=[client valueForKey:@"requestContexts"];
    [contexts setObject:oldContext forKey:old];[client setValue:old forKey:@"task"];[client cancel];
    [contexts setObject:newContext forKey:current];
    [client URLSession:browse task:old didCompleteWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
    check(oldCalls==0&&newCalls==0&&[contexts objectForKey:current]==newContext,@"late browse cancellation cannot consume the new play context");
    [client URLSession:play dataTask:current didReceiveData:[@"ready" dataUsingEncoding:NSUTF8StringEncoding]];
    [client URLSession:play task:current didCompleteWithError:nil];
    check(newCalls==1&&[contexts objectForKey:current]==nil,@"play completion is delivered once after a browse/play session switch");
    [browse invalidateAndCancel];[play invalidateAndCancel];
}
static id call(MediaAPIClient *client,NSString *operation,NSDictionary *arguments,NSError **error){
    __block BOOL done=NO;__block id result=nil;__block NSError *failure=nil;
    [client call:operation arguments:arguments completion:^(id value,NSError *requestError){result=value;failure=requestError;done=YES;}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];while(!done&&[deadline timeIntervalSinceNow]>0)[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    check(done,[NSString stringWithFormat:@"%@ callback completed",operation]);if(error)*error=failure;return result;
}
int main(int argc,const char **argv){@autoreleasepool{
    checkSessionTaskIsolation();
    check(argc==2,@"server port supplied");NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%@/api.php?token=fixture&mode=tvbox",[NSString stringWithUTF8String:argv[1]]];
    NSDictionary *dashDescriptor=@{@"url":@"https://cdn.example/manifest.mpd?token=fixture",@"format":@"application/dash+xml"};NSDictionary *extensionlessDash=@{@"url":@"https://cdn.example/manifest?id=fixture",@"format":@"application/dash+xml"};check(MediaPlaybackResultSupportsCicada(dashDescriptor)&&MediaPlaybackResultSupportsNativePlayback(dashDescriptor)&&!MediaPlaybackResultSupportsAVPlayer(dashDescriptor)&&MediaPlaybackResultSupportsCicada(extensionlessDash),@"MPEG-DASH manifests, including extensionless MIME-declared manifests, route to Cicada instead of AVPlayer");
    MediaAPIClient *timeoutClient=[[MediaAPIClient alloc] initWithPort:1];check(timeoutClient.playTimeoutMilliseconds==15000,@"play API timeout defaults to 15 seconds");timeoutClient.playTimeoutMilliseconds=20000;check(timeoutClient.playTimeoutMilliseconds==20000,@"play API accepts a configured timeout");timeoutClient.playTimeoutMilliseconds=500000;check(timeoutClient.playTimeoutMilliseconds==120000,@"play API timeout is capped at 120 seconds");timeoutClient.playTimeoutMilliseconds=10;check(timeoutClient.playTimeoutMilliseconds==1000,@"play API timeout has a safe 1 second lower bound");timeoutClient.playTimeoutMilliseconds=0;check(timeoutClient.playTimeoutMilliseconds==15000,@"invalid play timeout returns to the 15 second default");
    NSString *port=[NSString stringWithUTF8String:argv[1]];NSString *parserURL=[NSString stringWithFormat:@"http://127.0.0.1:%@/parse?url=",port];NSString *webParserURL=[NSString stringWithFormat:@"http://127.0.0.1:%@/webparse?url=",port];
    [TVBoxCatalogStore saveCatalog:@{@"id":@"parser-catalog",@"name":@"Fixture parsers",@"tvboxConfig":@{@"parses":@[@{@"name":@"JSON resolver",@"type":@1,@"url":parserURL,@"header":@{@"X-Parser":@"parser-fixture"}},@{@"name":@"Web resolver",@"type":@0,@"url":webParserURL}]}}];
    NSDictionary *source=@{@"id":@"tvbox-test",@"name":@"Fixture CMS",@"protocol":@"tvbox-api",@"tvboxType":@4,@"catalogID":@"parser-catalog",@"api":base,@"options":@"{\"region\":\"cn\"}",@"header":@{@"X-Fixture":@"header",@"Referer":@"https://source.example/",@"Authorization":@"Basic fixture",@"Cookie":@"session=fixture",@"X-API-Key":@"fixture-key",@"Host":@"invalid.example"}};
    MediaAPIClient *client=[[MediaAPIClient alloc] initWithTVBoxSource:source];NSError *error=nil;
    NSDictionary *home=call(client,@"home",@{},&error);check(!error&&[home[@"categories"] count]==1&&[home[@"items"][0][@"id"] isEqual:@"home-1"]&&[home[@"items"][0][@"poster"] isEqual:[NSString stringWithFormat:@"http://127.0.0.1:%@/poster.jpg",[NSString stringWithUTF8String:argv[1]]]]&&[home[@"filters"][@"movie"] count]==1,@"type 4 home normalizes categories, relative poster URLs, content, and filter choices");
    NSDictionary *category=call(client,@"category",@{@"categoryId":@"movie",@"page":@1,@"filters":@{@"area":@"cn",@"pg":@99}},&error);check(!error&&[category[@"hasMore"] boolValue],@"category pagination can derive page count from total/limit");
    NSDictionary *search=call(client,@"search",@{@"keyword":@"fixture",@"page":@2},&error);check(!error&&[search[@"page"] integerValue]==2&&[search[@"items"][0][@"name"] isEqual:@"Search fixture"],@"search result fields normalize");
    NSDictionary *redirected=call(client,@"search",@{@"keyword":@"redirect",@"page":@1},&error);check(!error&&[redirected[@"items"][0][@"id"] isEqual:@"redirected"],@"TVBox API follows a bounded cross-origin redirect");
    NSDictionary *detail=call(client,@"detail",@{@"id":@"film-1"},&error);check(!error&&[detail[@"lines"] count]==2&&[detail[@"lines"][0][@"episodes"][0][@"id"] isEqual:@"episode-1"],@"detail keeps opaque episode IDs unchanged");check([detail[@"lines"][0][@"episodes"][1][@"id"] isEqual:@"https://cdn.example/live.m3u8?token=abc%2Bdef&expires=123"],@"detail preserves signed episode URLs byte-for-byte");check([[detail[@"lines"][1][@"episodes"][0][@"id"] description] hasSuffix:@"/feature.m3u8"],@"detail resolves relative media URLs against the TVBox API origin");
    NSDictionary *play=call(client,@"play",@{@"id":@"episode-1",@"lineId":@"线路一"},&error);check(!error&&[play[@"url"] isEqual:@"https://cdn.example/low.m3u8"]&&[play[@"alternates"] count]==2, @"type 4 play response normalizes prefixed quality choices");check([play[@"headers"][@"Referer"] isEqual:@"https://source.example/"]&&[play[@"headers"][@"X-Playback"] isEqual:@"fixture"]&&[play[@"headers"][@"User-Agent"] isEqual:@"FixtureUA/1"],@"source and resolver playback headers are combined");
    NSDictionary *webPlay=call(client,@"play",@{@"id":@"web-episode",@"lineId":@"线路一",@"parserID":@"parser-catalog:0"},&error);check(!error&&[webPlay[@"nativePlayable"] boolValue]&&[webPlay[@"directMedia"] boolValue]&&[webPlay[@"url"] containsString:@"/stream.m3u8?token=fixture"]&&[webPlay[@"parserName"] isEqual:@"JSON resolver"]&&[webPlay[@"headers"][@"Referer"] isEqual:@"https://parser.example/"],@"selected type 1 parser turns a TVBox web page into an in-app native media result");
    NSDictionary *mpdResult=call(client,@"play",@{@"id":@"web-episode-mpd",@"lineId":@"线路一",@"parserID":@"parser-catalog:0"},&error);check(!error&&![mpdResult[@"requiresWebPlayback"] boolValue]&&[mpdResult[@"nativePlayable"] boolValue]&&[mpdResult[@"directMedia"] boolValue]&&[mpdResult[@"playbackEngine"] isEqual:@"cicada"]&&[mpdResult[@"url"] isEqual:@"https://cdn.example/manifest.mpd"]&&[mpdResult[@"format"] isEqual:@"mpd"],@"a DASH MPD parser result is recognized as Cicada-native media");
    NSDictionary *webFallback=call(client,@"play",@{@"id":@"web-episode",@"lineId":@"线路一",@"parserID":@"parser-catalog:1"},&error);NSURLComponents *webFallbackParts=[NSURLComponents componentsWithString:webFallback[@"url"]];NSString *webFallbackTarget=@"";for(NSURLQueryItem *queryItem in webFallbackParts.queryItems)if([queryItem.name isEqual:@"url"])webFallbackTarget=queryItem.value?:@"";check(!error&&[webFallback[@"requiresWebPlayback"] boolValue]&&[webFallbackParts.path isEqual:@"/webparse"]&&[webFallbackTarget isEqual:@"https://resolver.example/watch?id=fixture"],@"selected type 0 parser keeps the in-app web playback fallback");
    NSDictionary *officialWatch=call(client,@"play",@{@"id":@"official-watch-page",@"lineId":@"腾讯视频",@"parserID":@"parser-catalog:0"},&error);check(!error&&[officialWatch[@"url"] isEqual:@"https://v.qq.com/x/cover/fixture/episode.html"]&&[officialWatch[@"requiresWebPlayback"] boolValue]&&![officialWatch[@"parserName"] length],@"official Tencent watch pages skip third-party parsing and preserve authorized browser playback");
    NSDictionary *qualityPlay=call(client,@"play",@{@"id":@"quality-specific",@"lineId":@"线路一"},&error);check(!error&&[qualityPlay[@"alternates"] count]==2&&[qualityPlay[@"alternates"][0][@"headers"][@"X-Playback"] isEqual:@"shared"]&&[qualityPlay[@"alternates"][0][@"headers"][@"X-Quality"] isEqual:@"high"]&&[qualityPlay[@"alternates"][1][@"headers"][@"X-Quality"] isEqual:@"low"],@"per-quality request headers survive TVBox normalization");
    NSError *apiError=nil;call(client,@"search",@{@"keyword":@"fail",@"page":@1},&apiError);check(apiError&&[apiError.localizedDescription containsString:@"fixture denied"],@"TVBox error message without content is reported as an API failure");
    NSDictionary *empty=call(client,@"search",@{@"keyword":@"empty",@"page":@1},&error);check(!error&&[empty[@"items"] count]==0,@"code 0 with a valid empty list is accepted");
    NSDictionary *type1=[@{@"id":@"tvbox-type1",@"protocol":@"tvbox-api",@"tvboxType":@1,@"api":base,@"playUrl":@"https://cdn.example/",@"header":@{@"Referer":@"https://type1.example/"}} copy];MediaAPIClient *direct=[[MediaAPIClient alloc] initWithTVBoxSource:type1];NSDictionary *directPlay=call(direct,@"play",@{@"id":@"episode.m3u8"},&error);check(!error&&[directPlay[@"url"] isEqual:@"https://cdn.example/episode.m3u8"]&&[directPlay[@"headers"][@"Referer"] isEqual:@"https://type1.example/"],@"type 1 direct playback applies source prefix and headers");
    NSDictionary *doubanSource=@{@"id":@"douban-index:test:jueson",@"protocol":@"douban-index",@"tvboxType":@3,@"api":@"csp_DouDou"};MediaAPIClient *doubanClient=[[MediaAPIClient alloc] initWithTVBoxSource:doubanSource];NSDictionary *doubanCapabilities=call(doubanClient,@"capabilities",@{},&error);check(!error&&[doubanCapabilities[@"capabilities"] isEqual:@[@"home",@"category",@"search"]],@"DouDou JAR metadata class uses the native iOS index adapter without advertising playback");call(doubanClient,@"play",@{@"id":@"msearch:###Fixture###"},&error);check(error&&[error.localizedDescription containsString:@"跨来源搜索"],@"DouDou metadata items direct users to cross-source playback instead of pretending to contain a stream");
    NSString *signedURL=@"https://cdn.example/session/play?access_token=abc%2Bdef&expires=123";NSDictionary *macSource=@{@"id":@"mac-source",@"protocol":@"maccms-api",@"catalogID":@"mac-empty-catalog",@"api":base,@"header":@{@"Referer":@"https://source.example/"}};MediaAPIClient *macClient=[[MediaAPIClient alloc] initWithTVBoxSource:macSource];NSDictionary *signedPlay=call(macClient,@"play",@{@"id":signedURL},&error);check(!error&&[signedPlay[@"url"] isEqual:signedURL]&&[signedPlay[@"originalURL"] isEqual:signedURL]&&![signedPlay[@"requiresWebPlayback"] boolValue]&&![signedPlay[@"parse"] boolValue],@"MacCMS extensionless signed media URL stays intact and is tried by AVPlayer");NSDictionary *authKeyPlay=call(macClient,@"play",@{@"id":@"https://cdn.example/session/play?authKey=abc&sessionToken=xyz"},&error);check(!error&&![authKeyPlay[@"requiresWebPlayback"] boolValue]&&![authKeyPlay[@"parse"] boolValue],@"extensionless media with camel-case auth and session tokens uses native playback");NSDictionary *webPage=call(macClient,@"play",@{@"id":@"https://source.example/player.php?url=opaque"},&error);check(!error&&[webPage[@"requiresWebPlayback"] boolValue]&&[webPage[@"parse"] boolValue],[NSString stringWithFormat:@"MacCMS explicit parser pages still use web playback (error=%@ result=%@)",error.localizedDescription,webPage]);NSDictionary *unclassifiedPage=call(macClient,@"play",@{@"id":@"https://source.example/play?id=opaque"},&error);check(!error&&[unclassifiedPage[@"requiresWebPlayback"] boolValue],@"MacCMS extensionless parser URLs without signature hints keep the web handoff");
    NSDictionary *unscopedSource=@{@"id":@"unscoped-package",@"protocol":@"maccms-api",@"api":base,@"options":source[@"options"],@"header":source[@"header"]};MediaAPIClient *unscopedClient=[[MediaAPIClient alloc] initWithTVBoxSource:unscopedSource];NSDictionary *unscopedPage=call(unscopedClient,@"play",@{@"id":@"https://source.example/player.php?url=opaque",@"parserID":@"parser-catalog:0"},&error);check(!error&&[unscopedPage[@"requiresWebPlayback"] boolValue]&&![unscopedPage[@"parserName"] length],@"an unscoped media package cannot borrow parser endpoints from another TVBox collection");
    NSDictionary *threeQConfig=@{@"host":[NSString stringWithFormat:@"http://127.0.0.1:%@",port],@"finger":@"f",@"pkg":@"p",@"sk":@"s",@"ver":@"6"};
    NSString *threeQOptions=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:threeQConfig options:0 error:NULL] encoding:NSUTF8StringEncoding];
    MediaAPIClient *threeQ=[[MediaAPIClient alloc] initWithTVBoxSource:@{@"id":@"app3q-fixture",@"protocol":@"jar-bridge",@"tvboxType":@3,@"api":@"csp_App3Q",@"options":threeQOptions}];
    NSDictionary *threeQHome=call(threeQ,@"home",@{},&error);check(!error&&[threeQHome[@"categories"] count]==2&&[threeQHome[@"items"] count]==1,@"App3Q signed HTTP home uses categories/recommend schema");
    NSDictionary *threeQDetail=call(threeQ,@"detail",@{@"id":@"3q-1"},&error);check(!error&&[threeQDetail[@"lines"][0][@"episodes"][0][@"id"] isEqual:@"opaque-source-id"],@"App3Q detail keeps opaque IDs for its own decoder API");
    NSDictionary *threeQPlay=call(threeQ,@"play",@{@"id":@"opaque-source-id",@"lineId":@"native"},&error);check(!error&&[threeQPlay[@"url"] isEqual:@"https://cdn.example/app3q/episode.mp4"]&&[threeQPlay[@"directMedia"] boolValue]&&!threeQPlay[@"headers"][@"x-sign"],@"App3Q resolved media goes to native player without API signing headers");
    NSLog(@"Native TVBox JSON API adapter tests passed");
}return 0;}
