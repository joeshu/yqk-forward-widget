#import "JSPluginRuntime.h"
#import <Foundation/Foundation.h>
static NSInteger apiCalls=0;
static BOOL stall=NO;
static dispatch_semaphore_t stalled;
@interface FixtureProtocol : NSURLProtocol @end
@implementation FixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    if(stall){dispatch_semaphore_signal(stalled);return;}
    NSString *url=self.request.URL.absoluteString;NSString *body;
    if([url hasPrefix:@"https://bkliveinfo.ysp.cctv.cn/"]){apiCalls++;body=@"{\"iretcode\":0,\"playurl\":\"https://fixture.cctv.cn/index.m3u8\"}";}
    else if([url containsString:@"fixture.test"])body=@"<div class='list'><a href='/detail/1'>Native rule movie</a></div>";
    else body=@"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n#EXT-QQHLS-SEGMENT_RANGE:95-102\n#EXTINF:6,\n100.ts?token=one\n#EXTINF:6,\n101.ts?token=one\n#EXTINF:6,\n102.ts?token=one\n";
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/vnd.apple.mpegurl"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static void check(BOOL ok,NSString *message){if(!ok){NSLog(@"FAILED: %@",message);exit(1);}}
static NSDictionary *call(JSPluginRuntime *runtime,NSString *op,NSDictionary *payload){
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];NSString *json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);__block NSString *answer;__block NSError *error;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{answer=[runtime callOperation:op json:json timeout:10 error:&error];dispatch_semaphore_signal(sem);});
    check(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC))==0,@"bridge must not hang");check(answer!=nil,error.localizedDescription?:@"native bridge failed");
    return [NSJSONSerialization JSONObjectWithData:[answer dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
int main(int argc,const char **argv){@autoreleasepool {
    check(argc==3,@"compiled JS bundles supplied");
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.protocolClasses=@[FixtureProtocol.class];
    JSPluginRuntime *runtime=[[JSPluginRuntime alloc] initWithScriptURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] configuration:config];
    NSDictionary *start=call(runtime,@"start",@{@"session":@"A"});check([start[@"ok"] boolValue],@"real JavaScriptCore initializes original JS bundle");
    NSDictionary *catalog=call(runtime,@"catalog",@{@"session":@"A"});check([catalog[@"result"] count]==63,@"original channel catalog executed");
    NSDictionary *key=call(runtime,@"ckey",@{@"session":@"A",@"channelId":@"2024078201"});check([key[@"result"][@"cKey"] hasPrefix:@"--01"],@"original cKey uses native randomBytes/Buffer correctly");
    NSDictionary *manifest=call(runtime,@"resolve",@{@"session":@"A",@"ref":@"ysp-cctv1",@"userAgent":@"CCTVHost/1"});
    check([manifest[@"ok"] boolValue],@"async JS promise resolves through native HTTPS bridge");
    check([manifest[@"result"][@"manifestText"] containsString:@"https://fixture.cctv.cn/100.ts"],@"JS manifest rewriting preserved");check(apiCalls==1,@"one upstream ticket");
    NSDictionary *vip=call(runtime,@"resolve",@{@"session":@"A",@"ref":@"ysp-vip-cctvsjdl"});check(![vip[@"ok"] boolValue],@"no fake browser/VIP compatibility");
    stall=YES;stalled=dispatch_semaphore_create(0);dispatch_semaphore_t pending=dispatch_semaphore_create(0);
    __block NSString *cancelled;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{cancelled=[runtime callOperation:@"resolve" json:@"{\"session\":\"A\",\"ref\":\"ysp-cctv2\"}" timeout:10 error:NULL];dispatch_semaphore_signal(pending);});
    check(dispatch_semaphore_wait(stalled,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"network operation is pending");
    check([call(runtime,@"stop",@{@"session":@"A"})[@"ok"] boolValue],@"stop JS session");
    check(dispatch_semaphore_wait(pending,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"stop wakes pending Python bridge callers");
    check([cancelled containsString:@"false"],@"cancelled operation is reported as stopped");
    check(![call(runtime,@"catalog",@{@"session":@"A"})[@"ok"] boolValue],@"late calls cannot restart stopped JS context");
    stall=NO;check([call(runtime,@"start",@{@"session":@"B"})[@"ok"] boolValue],@"new JS session can start");
    call(runtime,@"stop",@{@"session":@"A"});check([call(runtime,@"catalog",@{@"session":@"B"})[@"result"] count]==63,@"old session cannot stop replacement");
    call(runtime,@"stop",@{@"session":@"B"});
    JSPluginRuntime *generic=[[JSPluginRuntime alloc] initWithScriptURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] configuration:config];
    NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *source=@"import {createHash} from 'crypto';export default {home(){return {class:[{type_id:'1',type_name:'Movies'}]}},search({keyword}){return {list:[{vod_id:createHash('md5').update(keyword).digest('hex'),vod_name:'Native ESM'}]}},play({id}){return {url:id}}}";
    [source writeToFile:[folder stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *genericStart=@{@"session":@"G",@"packageRoot":folder,@"entry":@"index.js",@"moduleType":@"esm",@"protocol":@"cctvhost.media/1"};
    NSDictionary *answer=call(generic,@"start",genericStart);check([answer[@"ok"] boolValue],[answer description]);
    answer=call(generic,@"search",@{@"session":@"G",@"keyword":@"hello"});
    check([answer[@"result"][@"list"][0][@"vod_id"] isEqual:@"5d41402abc4b2a76b9719d911017c592"],@"generic ESM compiler and crypto execute in actual JavaScriptCore");
    call(generic,@"stop",@{@"session":@"G"});
    source=@"var rule={title:'Native drpy',host:'https://fixture.test',url:'/list/fyclass/fypage',class_name:'Movies',class_url:'movies',一级:'.list&&a;a&&Text;;a&&Text;a&&href',二级:'js:VOD={vod_id:input,vod_name:\"Native rule movie\",vod_play_from:\"line\",vod_play_url:\"First$https://fixture.test/video.mp4\"}',lazy:'js:input={parse:0,url:input}'}";
    [source writeToFile:[folder stringByAppendingPathComponent:@"rule.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    answer=call(generic,@"start",@{@"session":@"D",@"packageRoot":folder,@"entry":@"rule.js",@"moduleType":@"script",@"protocol":@"drpy"});
    check([answer[@"ok"] boolValue],[answer description]);
    answer=call(generic,@"category",@{@"session":@"D",@"categoryId":@"movies",@"page":@1});
    id category=answer[@"result"];if([category isKindOfClass:NSString.class])category=[NSJSONSerialization JSONObjectWithData:[category dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    check([category[@"list"] count]>0,@"drpy synchronous req and HTML parser work in native JavaScriptCore");
    stall=YES;stalled=dispatch_semaphore_create(0);pending=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[generic callOperation:@"category" json:@"{\"session\":\"D\",\"categoryId\":\"movies\",\"page\":2}" timeout:10 error:NULL];dispatch_semaphore_signal(pending);});
    check(dispatch_semaphore_wait(stalled,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"drpy sync request pending");
    check([call(generic,@"stop",@{@"session":@"D"})[@"ok"] boolValue],@"stop interrupts drpy synchronous request");
    check(dispatch_semaphore_wait(pending,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"drpy caller wakes on stop");
    [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
    puts("PASS: real JavaScriptCore, original JS, native crypto/HTTPS/timers/promises, cancellation and session replacement");
}return 0;}
