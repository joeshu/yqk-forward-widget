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
    else if([url containsString:@"/qjs"])body=@"{\"ok\":true}";
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
static id field(id value,NSString *key){return [value isKindOfClass:NSDictionary.class]?value[key]:nil;}
static id at(id value,NSUInteger index){return [value isKindOfClass:NSArray.class]&&[value count]>index?value[index]:nil;}
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
    JSPluginRuntime *router=[JSPluginRuntime routerWithScriptURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] configuration:config];
    NSString *parallelA=[folder stringByAppendingPathComponent:@"parallel-a"],*parallelB=[folder stringByAppendingPathComponent:@"parallel-b"];
    [NSFileManager.defaultManager createDirectoryAtPath:parallelA withIntermediateDirectories:YES attributes:nil error:NULL];[NSFileManager.defaultManager createDirectoryAtPath:parallelB withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *parallelSource=@"let count=0;export default {search(){count++;return {list:[{vod_id:String(count),vod_name:'isolated'}]}}}";
    [parallelSource writeToFile:[parallelA stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];[parallelSource writeToFile:[parallelB stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *parallelPayloadA=@{@"session":@"js-a",@"serviceID":@"service-a",@"packageRoot":parallelA,@"entry":@"index.js",@"moduleType":@"esm",@"protocol":@"cctvhost.media/1"};
    NSDictionary *parallelPayloadB=@{@"session":@"js-b",@"serviceID":@"service-b",@"packageRoot":parallelB,@"entry":@"index.js",@"moduleType":@"esm",@"protocol":@"cctvhost.media/1"};
    check([call(router,@"start",parallelPayloadA)[@"ok"] boolValue]&&[call(router,@"start",parallelPayloadB)[@"ok"] boolValue],@"JavaScriptCore router starts two independent contexts");
    check([call(router,@"search",@{@"session":@"js-a"})[@"result"][@"list"][0][@"vod_id"] isEqual:@"1"]&&[call(router,@"search",@{@"session":@"js-b"})[@"result"][@"list"][0][@"vod_id"] isEqual:@"1"],@"parallel JavaScriptCore contexts keep independent module state");
    check([call(router,@"stop",@{@"session":@"js-a"})[@"ok"] boolValue]&&[call(router,@"search",@{@"session":@"js-b"})[@"result"][@"list"][0][@"vod_id"] isEqual:@"2"],@"stopping one JavaScriptCore context leaves the other usable");
    __block BOOL stoppedByServiceID=NO;dispatch_semaphore_t stopByServiceIDDone=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{stoppedByServiceID=[router stopSessionsForServiceIdentifier:@"service-b" error:NULL];dispatch_semaphore_signal(stopByServiceIDDone);});
    BOOL stopByServiceIDReturned=dispatch_semaphore_wait(stopByServiceIDDone,dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC))==0;
    check(stopByServiceIDReturned&&stoppedByServiceID&&![[router managedServiceIdentifiers] containsObject:@"service-b"],@"service-ID shutdown stops and removes the matching JavaScriptCore context off the main thread");
    NSString *slowRoot=[folder stringByAppendingPathComponent:@"slow-start"];
    [NSFileManager.defaultManager createDirectoryAtPath:slowRoot withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *slowSource=@"export default {async init(){await new Promise(()=>{})},search(){return {list:[]}}}";
    [slowSource writeToFile:[slowRoot stringByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *slowPayload=@{@"session":@"js-slow",@"serviceID":@"service-slow",@"packageRoot":slowRoot,@"entry":@"index.js",@"moduleType":@"esm",@"protocol":@"cctvhost.media/1"};
    NSData *slowData=[NSJSONSerialization dataWithJSONObject:slowPayload options:0 error:NULL];NSString *slowJSON=[[NSString alloc] initWithData:slowData encoding:NSUTF8StringEncoding];
    dispatch_semaphore_t slowDone=dispatch_semaphore_create(0);__block NSString *slowAnswer=nil;__block NSError *slowError=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{slowAnswer=[router callOperation:@"start" json:slowJSON timeout:.1 error:&slowError];dispatch_semaphore_signal(slowDone);});
    check(dispatch_semaphore_wait(slowDone,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0&&slowAnswer==nil,@"a hung asynchronous JS start returns a bounded timeout");
    // A timeout can beat the JSC queue before activeSession is assigned. The router must
    // retain the managed owner during that window, then release it only after ordered stop.
    check([[router managedServiceIdentifiers] containsObject:@"service-slow"],@"timed-out JSC startup keeps its managed owner reachable until cleanup");
    NSDate *cleanupDeadline=[NSDate dateWithTimeIntervalSinceNow:3];while([[router managedServiceIdentifiers] containsObject:@"service-slow"]&&cleanupDeadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.02];
    check(![[router managedServiceIdentifiers] containsObject:@"service-slow"],@"ordered cleanup releases the timed-out JSC session owner");
    source=@"import jpeg from 'jpeg-js';import {Readable} from 'node:stream';export default function createSpider(){return {meta:{key:'native_spider',name:'Native Spider',type:3},api:async fastify=>{fastify.post('/init',async()=>({}));fastify.post('/home',async()=>{const width=jpeg.decode(jpeg.encode({data:new Uint8Array([255,0,0,255]),width:1,height:1}).data).width,streamText=await new Promise(resolve=>{const chunks=[];Readable.from(['JSC','-stream']).on('data',chunk=>chunks.push(chunk)).on('end',()=>resolve(chunks.join('')))});return {class:[{type_id:'movie',type_name:'电影'}],list:[{vod_id:'one',vod_name:width===1&&streamText==='JSC-stream'?'Native CatPaw':'runtime mismatch'}]}});fastify.post('/category',async request=>({list:[{vod_id:request.body.id,vod_name:'分类'}]}));fastify.post('/detail',async request=>({list:[{vod_id:request.body.id[0],vod_name:'详情',vod_play_from:'线路A$$$线路B',vod_play_url:'第一集$one$$$正片$two'}]}));fastify.post('/play',async request=>({parse:1,url:'https://fixture.test/'+request.body.id,header:{Referer:request.server.prefix}}));fastify.post('/search',async request=>({list:[{vod_id:request.body.wd,vod_name:request.body.wd}]}));fastify.get('/proxy/:file',async(request,reply)=>reply.type('application/vnd.apple.mpegurl').send('proxy:'+request.params.file))}}}";
    [source writeToFile:[folder stringByAppendingPathComponent:@"cat.js"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    answer=call(generic,@"start",@{@"session":@"S",@"packageRoot":folder,@"entry":@"cat.js",@"moduleType":@"esm",@"protocol":@"catvod-spider"});check([answer[@"ok"] boolValue],[answer description]);
    answer=call(generic,@"home",@{@"session":@"S"});id homeName=field(at(field(field(answer,@"result"),@"list"),0),@"vod_name");check([homeName isEqual:@"Native CatPaw"],[NSString stringWithFormat:@"CatPaw Fastify ESM Spider runs in JavaScriptCore: %@",answer]);
    answer=call(generic,@"detail",@{@"session":@"S",@"id":@"movie/one"});id playList=field(at(field(field(answer,@"result"),@"list"),0),@"vod_play_url");check([playList isEqual:@"第一集$one$$$正片$two"],[NSString stringWithFormat:@"CatVod multiline episodes are preserved: %@",answer]);
    answer=call(generic,@"play",@{@"session":@"S",@"lineId":@"线路A",@"id":@"opaque"});id playHeaders=field(answer[@"result"],@"header");check([field(answer[@"result"],@"parse") integerValue]==1&&[[field(playHeaders,@"Referer") description] containsString:@"native_spider"],[NSString stringWithFormat:@"parse=1 and CatVod header are preserved for playback: %@",answer]);
    answer=call(generic,@"route",@{@"session":@"S",@"method":@"GET",@"path":@"/spider/native_spider/3/proxy/index.m3u8",@"host":@"127.0.0.1:18780"});check([field(answer[@"result"],@"body") isEqual:@"proxy:index.m3u8"],[NSString stringWithFormat:@"Fastify proxy route is callable: %@",answer]);call(generic,@"stop",@{@"session":@"S"});
    source=@"export default function createSpider(site){return {async init(ext){local.set('native-ext',ext)},async home(filter){const response=await net.json('https://fixture.test/qjs');return {class:[{type_id:'movie',type_name:'电影'}],list:[{vod_id:site.key,vod_name:site.name+':'+local.get('native-ext')+':'+response.ok+':'+filter}] }},async homeVod(){return {list:[]}},async category(tid,pg,filter,extend){return {page:Number(pg),list:[{vod_id:tid,vod_name:JSON.stringify(extend)}]}},async search(key,quick,pg){return {page:Number(pg),list:[{vod_id:key,vod_name:key}]}},async detail(id){return {list:[{vod_id:id,vod_name:id,vod_play_from:'线路',vod_play_url:'第一集$'+id}]}},async play(flag,id,vipFlags){return {parse:0,url:'https://fixture.test/'+id,header:{Referer:'https://fixture.test/'+flag}}}}}";
    [source writeToFile:[folder stringByAppendingPathComponent:@"quickjs.mjs"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    answer=call(generic,@"start",@{@"session":@"Q",@"packageRoot":folder,@"entry":@"quickjs.mjs",@"moduleType":@"esm",@"protocol":@"catvod-js",@"name":@"原生 QuickJS",@"options":@{@"site":@{@"key":@"quickjs_native",@"name":@"CatVod 原生"},@"ext":@"extension-value"}});check([answer[@"ok"] boolValue],[NSString stringWithFormat:@"CatVod method-style factory initializes in JavaScriptCore: %@",answer]);
    answer=call(generic,@"home",@{@"session":@"Q"});id qjsHome=field(field(answer,@"result"),@"list");id qjsName=field(at(qjsHome,0),@"vod_name");check([qjsName isEqual:@"CatVod 原生:extension-value:true:true"],[NSString stringWithFormat:@"CatVod site, ext, net.json and home filter are adapted: %@",answer]);
    answer=call(generic,@"detail",@{@"session":@"Q",@"id":@"opaque/id"});check([field(at(field(field(answer,@"result"),@"list"),0),@"vod_id") isEqual:@"opaque/id"],[NSString stringWithFormat:@"Modern CatVod detail receives scalar ID: %@",answer]);
    answer=call(generic,@"play",@{@"session":@"Q",@"lineId":@"线路",@"id":@"opaque/id"});check([field(field(answer,@"result"),@"url") isEqual:@"https://fixture.test/opaque/id"]&&[field(field(field(answer,@"result"),@"header"),@"Referer") isEqual:@"https://fixture.test/线路"],[NSString stringWithFormat:@"CatVod play receives flag, ID and headers: %@",answer]);call(generic,@"stop",@{@"session":@"Q"});
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
