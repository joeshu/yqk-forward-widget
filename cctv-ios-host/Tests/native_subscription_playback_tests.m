#import <Foundation/Foundation.h>
#import "MediaSP360Adapter.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackHeaders.h"
static void check(BOOL ok, NSString *message){if(!ok){NSLog(@"FAILED: %@",message);exit(1);}}
int main(void){@autoreleasepool{
    NSURLRequest *home=MediaSP360Request(@"home",@{},NULL);
    check([home.URL.host isEqual:@"api.web.360kan.com"]&&[home.URL.path isEqual:@"/v1/rank"],@"360 uses its own protocol with no ext URL");
    NSURLRequest *search=MediaSP360Request(@"search",@{@"keyword":@"中文 & 测试",@"page":@2},NULL);
    NSURLComponents *parts=[NSURLComponents componentsWithURL:search.URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary *query=[NSMutableDictionary dictionary];for(NSURLQueryItem *item in parts.queryItems)query[item.name]=item.value;
    check([query[@"kw"] isEqual:@"中文 & 测试"]&&[query[@"pageno"] isEqual:@"2"],@"search query encoding");
    NSDictionary *homeResult=MediaSP360Normalize(@"home",@{},@{@"data":@[@{@"ent_id":@"film",@"cat":@2,@"title":@"电影",@"cover":@"//cdn.example/p.jpg"}]} );
    check([homeResult[@"categories"] count]==4&&[homeResult[@"items"][0][@"id"] isEqual:@"film+2"],@"home is actual 360 data");
    NSDictionary *detail=MediaSP360Normalize(@"detail",@{@"id":@"film+2"},@{@"data":@{@"title":@"电影",@"playlink_sites":@[@"qq",@"youku"],@"allepidetail":@{@"qq":@[@{@"url":@"https://v.qq.com/1.html",@"playlink_num":@1}]},@"playlinksdetail":@{@"youku":@{@"default_url":@"https://v.youku.com/1.html",@"quality":@"高清"}}}});
    check([detail[@"lines"] count]==2&&[detail[@"lines"][0][@"episodes"][0][@"id"] isEqual:@"https://v.qq.com/1.html"],@"detail preserves the correct provider episode URLs");
    NSDictionary *play=MediaSP360Normalize(@"play",@{@"id":@"https://v.qq.com/1.html"},@{});
    check([play[@"parse"] boolValue]&&[play[@"requiresWebPlayback"] boolValue],@"official page needs parser; never label it a decoded stream");
    for(NSNumber *code in @[@0x20030003,@0x20050006,@(-1001)])check(!MediaPlaybackCicadaErrorAllowsSoftwareRetry([NSError errorWithDomain:@"test" code:code.integerValue userInfo:@{NSLocalizedDescriptionKey:@"Invalid data found when processing input"}]),@"network/demux/timeout do not reset decoders");
    check(MediaPlaybackCicadaErrorAllowsSoftwareRetry([NSError errorWithDomain:@"test" code:0x20040001 userInfo:nil]),@"video decoder failure can retry software");
    NSDictionary *dash=@{@"url":@"http://127.0.0.1:19000/media/session",@"originalURL":@"https://cdn.example/a.mpd",@"dashRemuxed":@YES,@"format":@"hls",@"playbackEngine":@"avplayer"};
    check(MediaPlaybackResultSupportsAVPlayer(dash)&&!MediaPlaybackResultSupportsCicadaPlayer(dash),@"converted HLS uses its effective format");
    check(MediaPlaybackDecodeRouteNextForResult(dash,0)==MediaPlaybackDecodeRouteAVPlayer,@"converted DASH starts with AVPlayer");
    check(MediaPlaybackDecodeRouteNextForResult(dash,MediaPlaybackDecodeRouteAttemptedAVPlayer)==MediaPlaybackDecodeRouteCicadaPlayer,@"original DASH fallback stays available");
    puts("PASS: source-specific 360 normalization, URL encoding, decoder retry and DASH route behavior");
}}
