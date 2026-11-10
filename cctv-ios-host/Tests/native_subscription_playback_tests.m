#import <Foundation/Foundation.h>
#import "MediaSP360Adapter.h"
#import "MediaApp3QAdapter.h"
#import "MediaSubscriptionToken.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaPlaybackHeaders.h"
static void check(BOOL ok, NSString *message){if(!ok){NSLog(@"FAILED: %@",message);exit(1);}}
int main(void){@autoreleasepool{
    NSDictionary *headers=MediaPlaybackHeadersFromResult(@{@"ext":@{@"header":@{@"Referer":@"https://old.example/",@"Cookie":@"old=1"}},@"headers":@{@"referer":@"https://new.example/"},@"header":@"Referer:https://cdn.example/?token=$signed\nCookie$new=1",@"customHeaders":@{@"HOST":@"blocked.example",@"X-Bad":@"a\001b",@"X-OK":@"ok"}});
    check(headers.count==3&&[headers[@"Referer"] isEqual:@"https://cdn.example/?token=$signed"]&&[headers[@"Cookie"] isEqual:@"new=1"]&&[headers[@"X-OK"] isEqual:@"ok"],@"headers override case-insensitively, retain dollar in values, and reject controls/hop headers");
    check(MediaPlaybackHeadersFromResult((id)NSNull.null).count==0,@"malformed result does not crash header extraction");
    for(NSString *ext in @[@"avi",@"wmv",@"rmvb",@"mpg",@"mpeg"]){
        check(!MediaPlaybackResultSupportsCicada(@{@"url":[@"https://cdn.example/video." stringByAppendingString:ext]}),@"unsupported bundled demuxers are not advertised");
    }
    check(MediaPlaybackResultSupportsAVPlayer(@{@"url":@"https://cdn.example/live",@"contentType":@" Video/MP4 ; charset=binary"}),@"MIME whitespace and casing do not block AVPlayer");
    check([MediaLytvsSubscriptionToken(@"abcdef12") isEqual:@"tk_abcdef12"],@"legacy subscription token regains its required prefix");
    check([MediaLytvsSubscriptionToken(@" tk_abcdef12 ") isEqual:@"tk_abcdef12"],@"full subscription token is preserved without doubling prefix");
    check(!MediaLytvsSubscriptionToken(@"")&&!MediaLytvsSubscriptionToken(@"tk_fixture\r\nunsafe"),@"empty and malformed credentials are rejected");
    NSDictionary *appConfig=@{@"host":@"https://app.example",@"finger":@"f",@"pkg":@"p",@"sk":@"s",@"ver":@"6"};
    NSDictionary *appHeaders=MediaApp3QHeaders(appConfig,@"1700000000",@"123");
    check([appHeaders[@"x-sign"] isEqual:@"6E2317F31FCEF18A3BECC578C58A5A12E84083A8E19725FA035E69D68FA6FBFE"],@"App3Q request matches independent SHA256 wire-format vector");
    NSURLRequest *appHome=MediaApp3QRequest(appConfig,@"home",@{},NULL);
    check([appHome.URL.path isEqual:@"/api.php/app/index/home"]&&[appHome valueForHTTPHeaderField:@"x-sign"].length==64,@"App3Q uses signed dedicated endpoint");
    check(!MediaApp3QRequest(@{@"host":@"https://app.example"},@"home",@{},NULL),@"missing signing configuration does not fall back to an unrelated service");
    NSMutableDictionary *badHeaders=[appConfig mutableCopy];badHeaders[@"pkg"]=@"p\r\nx-test: unsafe";
    check(!MediaApp3QRequest(badHeaders,@"home",@{},NULL),@"reject header control characters before constructing request");
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
