#import "MediaNativePlaybackResolver.h"
#import "MediaPlaybackHeaders.h"
#import <TargetConditionals.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#include <stdint.h>
#include <string.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

static const NSUInteger MNRPageLimit=1024*1024, MNRBinaryLimit=64*1024;
static const NSTimeInterval MNRDeadline=15.0, MNRHTTPTimeout=4.0, MNRWebTimeout=8.0;
static __weak MediaNativePlaybackResolver *MNRWebOwner;

static NSString *MNRString(id value) {return [value isKindOfClass:NSString.class]?value:@"";}
static NSError *MNRError(NSString *code,NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostNativeResolver" code:1 userInfo:@{NSLocalizedDescriptionKey:message?:@"未取得可播放媒体",@"resolutionCode":code?:@"NO_MEDIA"}];
}
static BOOL MNRHTTP(NSURL *url) {
    return url.host.length&&[@[@"http",@"https"] containsObject:url.scheme.lowercaseString]&&!url.user.length&&!url.password.length&&url.absoluteString.length<=16384&&[url.absoluteString rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}
static BOOL MNRSameOrigin(NSURL *a,NSURL *b) {
    if(!a||!b)return NO;
    NSNumber *pa=a.port?:([a.scheme.lowercaseString isEqual:@"https"]?@443:@80),*pb=b.port?:([b.scheme.lowercaseString isEqual:@"https"]?@443:@80);
    return [a.scheme.lowercaseString isEqual:b.scheme.lowercaseString]&&[a.host.lowercaseString isEqual:b.host.lowercaseString]&&[pa isEqual:pb];
}
static BOOL MNRSensitive(NSString *key) {return [@[@"cookie",@"authorization",@"proxy-authorization",@"x-api-key",@"x-auth-token"] containsObject:key.lowercaseString];}
static BOOL MNRCookieMatches(NSHTTPCookie *cookie,NSURL *url) {
    NSString *domain=cookie.domain.lowercaseString?:@"",*host=url.host.lowercaseString?:@"";BOOL sub=[domain hasPrefix:@"."];
    if(sub)domain=[domain substringFromIndex:1];
    if(!domain.length||!([host isEqual:domain]||(sub&&[host hasSuffix:[@"." stringByAppendingString:domain]])))return NO;
    NSString *path=url.path.length?url.path:@"/",*cp=cookie.path.length?cookie.path:@"/";
    BOOL pathOK=[path isEqual:cp]||([path hasPrefix:cp]&&([cp hasSuffix:@"/"]||[path hasPrefix:[cp stringByAppendingString:@"/"]]));
    return pathOK&&(!cookie.secure||[url.scheme.lowercaseString isEqual:@"https"])&&(!cookie.expiresDate||cookie.expiresDate.timeIntervalSinceNow>0);
}
static NSString *MNRText(NSData *data) {
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text)text=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text?:@"";
}
// A media playlist often has no master-playlist CODECS/RESOLUTION metadata.
// Inspect its first MPEG-TS segment so ordinary video HLS is not rejected when
// AVFoundation cannot expose tracks from a short, local playlist probe.
// Returns 1 for video, 0 for a positively identified audio-only PMT, and -1
// when the segment format or PSI is not conclusive (for example fMP4/encrypted).
static NSInteger MNRTransportStreamVideoState(NSData *data) {
    const uint8_t *bytes=data.bytes;NSUInteger length=data.length;if(!bytes||length<188)return -1;
    NSUInteger start=NSNotFound;NSUInteger scan=MIN((NSUInteger)188,length-188);
    for(NSUInteger i=0;i<=scan;i++)if(bytes[i]==0x47&&(i+188>=length||bytes[i+188]==0x47)){start=i;break;}
    if(start==NSNotFound)return -1;
    NSInteger pmtPID=-1;BOOL foundPMT=NO,hasVideo=NO,hasUnknownStream=NO;
    for(NSUInteger offset=start;offset+188<=length;offset+=188){
        const uint8_t *packet=bytes+offset;if(packet[0]!=0x47)break;
        uint16_t pid=(uint16_t)(((packet[1]&0x1f)<<8)|packet[2]);
        if(pid!=0&&(pmtPID<0||pid!=(uint16_t)pmtPID))continue;
        uint8_t adaptation=(packet[3]>>4)&0x03;if(!(adaptation&0x01))continue;
        NSUInteger payload=4;if(adaptation&0x02){payload+=1+packet[payload];if(payload>=188)continue;}
        if(!(packet[1]&0x40)||payload>=188)continue;
        payload+=1+packet[payload];if(payload+3>188)continue;
        const uint8_t *section=packet+payload;NSUInteger sectionLength=((section[1]&0x0f)<<8)|section[2],total=3+sectionLength;
        if(total>188-payload||total<12)continue;
        if(pid==0&&section[0]==0x00){
            for(NSUInteger i=8;i+4<=total-4;i+=4){NSUInteger program=((NSUInteger)section[i]<<8)|section[i+1];if(program){pmtPID=(NSInteger)(((section[i+2]&0x1f)<<8)|section[i+3]);break;}}
            continue;
        }
        if(pmtPID<0||pid!=(uint16_t)pmtPID||section[0]!=0x02||total<16)continue;
        foundPMT=YES;NSUInteger infoLength=((NSUInteger)(section[10]&0x0f)<<8)|section[11];NSUInteger i=12+infoLength,end=total-4;
        while(i+5<=end){
            uint8_t type=section[i];NSUInteger descriptorLength=((NSUInteger)(section[i+3]&0x0f)<<8)|section[i+4];
            if([@[@(0x01),@(0x02),@(0x10),@(0x1b),@(0x24),@(0x42),@(0xd1),@(0xea)] containsObject:@(type)])hasVideo=YES;
            else if(![@[@(0x03),@(0x04),@(0x0f),@(0x11),@(0x81),@(0x87)] containsObject:@(type)])hasUnknownStream=YES;
            if(hasVideo)return 1;
            if(i+5+descriptorLength>end)break;i+=5+descriptorLength;
        }
    }
    return foundPMT&&!hasVideo&&!hasUnknownStream?0:-1;
}
static BOOL MNRLooksHTML(NSString *text,NSString *mime) {
    NSString *trim=[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [mime containsString:@"html"]||[trim hasPrefix:@"<!doctype html"]||[trim hasPrefix:@"<html"]||[trim hasPrefix:@"<head"];
}
static NSString *MNRResolvedString(NSString *raw,NSURL *base) {
    NSString *s=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    s=[[s stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    NSURL *url=[NSURL URLWithString:s relativeToURL:base].absoluteURL;
    return MNRHTTP(url)?url.absoluteString:@"";
}
static NSArray<NSString *> *MNRMatches(NSString *text,NSString *pattern,NSUInteger group) {
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:NULL];
    NSMutableArray *out=[NSMutableArray array];
    for(NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0,text.length)]){if(out.count>=8)break;if(m.numberOfRanges>group&&[m rangeAtIndex:group].location!=NSNotFound){NSString *s=[text substringWithRange:[m rangeAtIndex:group]];if(s.length)[out addObject:s];}}
    return out;
}

// The script only reports candidate metadata. Every reported URL is fetched and
// classified by native code before handoff. It does not read license payloads,
// cookies, request bodies, MediaSource buffers, or protected media bytes.
static NSString *MNRCaptureScript(void) {
    return @"(function(){if(window.__cctvNativeCapture)return;window.__cctvNativeCapture=1;const seen=new Map();let timer;const abs=(s)=>{try{let u=new URL(s,location.href);return /^https?:$/.test(u.protocol)?u.href:'';}catch(e){return '';}};const ad=(s)=>/(?:^|[\\/_?&.=-])(ads?|advert|preroll|tracking|trailer)(?:[\\/_?&.=-]|$)/i.test(s||'');const report=()=>{timer=0;let candidates=[...seen.values()].slice(0,8);try{webkit.messageHandlers.cctvNativeMedia.postMessage({token:window.__cctvNativeToken||'',frameURL:location.href,candidates});}catch(e){}};const add=(s,role)=>{let u=abs(s);if(!u||ad(u))return;let prior=seen.get(u);const rank={network:1,player:2,video:3};if(!prior||rank[role]>rank[prior.role])seen.set(u,{url:u,role,frameURL:location.href});if(!timer)timer=setTimeout(report,120);};const scan=()=>{try{for(const v of document.querySelectorAll('video')){let label=[v.id,v.className,v.getAttribute('data-role')].join(' ');if(/(?:^|[\\s_-])(ad|ads|advert|preview|trailer)(?:[\\s_-]|$)/i.test(label))continue;v.muted=true;let u=v.currentSrc||v.src;if(u)add(u,'video');for(const s of v.querySelectorAll('source'))add(s.src,'video');}for(const k of Object.keys(window)){if(!/^player_[a-z0-9_]+$/i.test(k)&&!['videoInfo','playInfo'].includes(k))continue;let p=window[k];if(!p||typeof p!=='object')continue;let u=p.url||p.playUrl;if(typeof u!=='string')continue;try{if(+p.encrypt===1)u=decodeURIComponent(u);else if(+p.encrypt===2||+p.encrypt===3)u=decodeURIComponent(atob(u));}catch(e){continue;}add(u,'player');}if(window.performance&&performance.getEntriesByType)for(const r of performance.getEntriesByType('resource'))if(/(?:\\.m3u8|\\.mpd|\\.mp4)(?:[?#]|$)/i.test(r.name))add(r.name,'network');}catch(e){}};const observeURL=(u)=>{u=typeof u==='string'?u:(u&&u.url)||'';if(/(?:\\.m3u8|\\.mpd|\\.mp4)(?:[?#]|$)/i.test(u))add(u,'network');};if(typeof window.fetch==='function'){const f=window.fetch;window.fetch=function(){observeURL(arguments[0]);return f.apply(this,arguments).then(r=>{observeURL(r.url);return r;});};}if(window.XMLHttpRequest){const o=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){observeURL(u);this.addEventListener('load',()=>observeURL(this.responseURL),{once:true});return o.apply(this,arguments);};}if(typeof MutationObserver==='function')new MutationObserver(scan).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['src']});document.addEventListener('loadedmetadata',scan,true);document.addEventListener('play',scan,true);document.addEventListener('DOMContentLoaded',scan);if(typeof PerformanceObserver==='function'){try{new PerformanceObserver(scan).observe({entryTypes:['resource']});}catch(e){}}scan();setTimeout(scan,500);setTimeout(scan,1500);})();";
}

@interface MNRHTTPContext : NSObject
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSHTTPURLResponse *response;
@property(nonatomic,strong) NSDictionary *node;
@property(nonatomic,strong) NSMutableDictionary *headers;
@property(nonatomic,strong) NSURL *scopeURL;
@property(nonatomic) NSUInteger limit,redirects;
@property(nonatomic) BOOL boundedComplete;
@property(nonatomic,strong) NSError *failure;
@end
@implementation MNRHTTPContext @end

@interface MNRMPDProbe : NSObject <NSXMLParserDelegate>
@property(nonatomic) BOOL root,video,segments,protectedContent;
@end
@implementation MNRMPDProbe
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    NSString *name=[[element componentsSeparatedByString:@":"] lastObject];
    if([name isEqual:@"MPD"])self.root=YES;
    if([name isEqual:@"ContentProtection"])self.protectedContent=YES;
    if([@[@"SegmentTemplate",@"SegmentList",@"SegmentBase",@"BaseURL"] containsObject:name])self.segments=YES;
    NSString *type=attributes[@"contentType"]?:@"",*mime=attributes[@"mimeType"]?:@"",*codecs=attributes[@"codecs"]?:@"";
    if([type isEqual:@"video"]||[mime hasPrefix:@"video/"]||[codecs hasPrefix:@"avc"]||[codecs hasPrefix:@"hvc"]||[codecs hasPrefix:@"hev"]||[codecs hasPrefix:@"av01"]||[codecs hasPrefix:@"vp09"])self.video=YES;
}
- (NSData *)parser:(NSXMLParser *)parser resolveExternalEntityName:(NSString *)name systemID:(NSString *)systemID {return nil;}
@end

@interface MediaNativePlaybackResolver () <NSURLSessionDataDelegate,WKNavigationDelegate,WKScriptMessageHandler>
@property(nonatomic,weak) UIView *hostView;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) MNRHTTPContext *http;
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) AVURLAsset *probeAsset;
@property(nonatomic,strong) NSDictionary *input,*identity,*entry;
@property(nonatomic,strong) NSArray<NSDictionary *> *entries;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *queue;
@property(nonatomic,strong) NSMutableSet<NSString *> *visited;
@property(nonatomic,strong) NSMutableArray<NSHTTPCookie *> *cookies;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *observed;
@property(nonatomic,strong) NSError *lastError;
@property(nonatomic,strong) NSDictionary *pendingWebNode;
@property(nonatomic,copy) void (^progressBlock)(NSDictionary *);
@property(nonatomic,copy) void (^completionBlock)(NSDictionary *,NSError *);
@property(nonatomic) NSUInteger generation,entryIndex,candidateCount;
@property(nonatomic) NSTimeInterval startedAt;
@property(nonatomic) BOOL webStarted,webReady,working;
@property(nonatomic,copy) NSString *webToken;
- (void)nextEntry;
- (void)pump;
- (void)startWebForNode:(NSDictionary *)node;
- (void)processData:(NSData *)data response:(NSHTTPURLResponse *)response node:(NSDictionary *)node;
- (void)finish:(NSDictionary *)media error:(NSError *)error;
@end

@implementation MediaNativePlaybackResolver
- (instancetype)initWithHostView:(UIView *)hostView {if((self=[super init]))_hostView=hostView;return self;}
- (void)resolveResult:(NSDictionary *)result identity:(NSDictionary *)identity progress:(void (^)(NSDictionary *))progress completion:(void (^)(NSDictionary *,NSError *))completion {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self resolveResult:result identity:identity progress:progress completion:completion];});return;}
    [self cancel];self.generation++;self.input=[result copy]?:@{};self.identity=[identity copy]?:@{};self.progressBlock=[progress copy];self.completionBlock=[completion copy];self.startedAt=NSDate.timeIntervalSinceReferenceDate;
    self.queue=[NSMutableArray array];self.visited=[NSMutableSet set];self.cookies=[NSMutableArray array];self.observed=[NSMutableDictionary dictionary];self.candidateCount=0;self.entryIndex=0;self.lastError=nil;
    NSMutableArray *entries=[NSMutableArray array];
    NSArray *declared=[result[@"resolutionCandidates"] isKindOfClass:NSArray.class]?result[@"resolutionCandidates"]:@[];
    for(id raw in declared){if(entries.count>=2)break;if(![raw isKindOfClass:NSDictionary.class])continue;NSURL *url=[NSURL URLWithString:MNRString(raw[@"url"])];if(MNRHTTP(url))[entries addObject:raw];}
    if(!entries.count){NSURL *url=[NSURL URLWithString:MNRString(result[@"url"])];if(MNRHTTP(url))[entries addObject:@{@"url":url.absoluteString,@"headers":MediaPlaybackHeadersFromResult(result),@"kind":@"source"}];}
    self.entries=entries.copy;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=MNRHTTPTimeout;config.timeoutIntervalForResource=MNRDeadline;config.HTTPShouldSetCookies=NO;config.HTTPCookieStorage=nil;config.URLCache=nil;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    NSUInteger generation=self.generation;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MNRDeadline*NSEC_PER_SEC)),dispatch_get_main_queue(),^{MediaNativePlaybackResolver *owner=weakSelf;if(owner&&owner.generation==generation&&owner.completionBlock)[owner finish:nil error:MNRError(@"TIMEOUT",@"原生媒体解析超时，可重试或更换当前合集解析器")];});
    [self nextEntry];
}
- (void)cancel {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self cancel];});return;}
    if(self.completionBlock)[self finish:nil error:MNRError(@"CANCELLED",@"本次解析已取消")];
    else [self teardown];
    self.generation++;
}
- (void)teardownWeb {
    if(self.web){[self.web evaluateJavaScript:@"try{document.querySelectorAll('video,audio').forEach(v=>{v.pause();v.removeAttribute('src');v.load();});}catch(e){}" completionHandler:nil];self.web.navigationDelegate=nil;[self.web.configuration.userContentController removeScriptMessageHandlerForName:@"cctvNativeMedia"];[self.web stopLoading];[self.web removeFromSuperview];self.web=nil;}
    if(MNRWebOwner==self)MNRWebOwner=nil;
    self.webToken=nil;self.webReady=NO;
}
- (void)teardown {
    [self.http.task cancel];self.http=nil;[self.probeAsset cancelLoading];self.probeAsset=nil;[self teardownWeb];[self.session invalidateAndCancel];self.session=nil;self.working=NO;
}
- (void)finish:(NSDictionary *)media error:(NSError *)error {
    void (^completion)(NSDictionary *,NSError *)=self.completionBlock;
    self.completionBlock=nil;self.progressBlock=nil;[self teardown];
    if(completion)completion(media,error);
}
- (void)progress:(NSString *)stage {
    if(!self.progressBlock)return;NSMutableDictionary *value=[@{@"stage":stage,@"parserIndex":@(self.entryIndex),@"candidateCount":@(self.candidateCount),@"elapsedMilliseconds":@((NSInteger)((NSDate.timeIntervalSinceReferenceDate-self.startedAt)*1000))} mutableCopy];
    for(NSString *key in @[@"parserID",@"parserName"])if(MNRString(self.entry[key]).length)value[key]=self.entry[key];self.progressBlock(value.copy);
}
- (void)nextEntry {
    [self.http.task cancel];self.http=nil;[self.probeAsset cancelLoading];self.probeAsset=nil;[self teardownWeb];self.working=NO;self.webStarted=NO;[self.queue removeAllObjects];[self.observed removeAllObjects];
    if(self.entryIndex>=self.entries.count){[self finish:nil error:self.lastError?:MNRError(@"NO_MEDIA",@"来源和所选解析器未返回有效的视频媒体")];return;}
    self.pendingWebNode=nil;self.entry=self.entries[self.entryIndex++];NSURL *url=[NSURL URLWithString:MNRString(self.entry[@"url"])];
    NSDictionary *headers=MediaPlaybackHeadersFromResult(self.entry);
    [self installHeaderCookies:headers forURL:url];
    [self.queue addObject:@{@"url":url.absoluteString,@"headers":headers,@"depth":@0,@"role":@"root",@"scopeURL":url.absoluteString}];[self progress:@"resolving"];[self pump];
}
- (void)failed:(NSError *)error {
    self.lastError=error;
    NSString *code=MNRString(error.userInfo[@"resolutionCode"]);
    if([@[@"DRM_UNSUPPORTED",@"AUTH_REQUIRED"] containsObject:code]){[self finish:nil error:error];return;}
    self.working=NO;[self pump];
}
- (void)installHeaderCookies:(NSDictionary *)headers forURL:(NSURL *)url {
    if(!url.host.length)return;
    for(NSString *key in headers)if([key.lowercaseString isEqual:@"cookie"]){for(NSString *part in [headers[key] componentsSeparatedByString:@";"]){NSRange equals=[part rangeOfString:@"="];if(equals.location==NSNotFound)continue;NSString *name=[[part substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*value=[part substringFromIndex:equals.location+1];if(!name.length)continue;NSHTTPCookie *cookie=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:name,NSHTTPCookieValue:value,NSHTTPCookieDomain:url.host,NSHTTPCookiePath:@"/"}];if(cookie)[self mergeCookie:cookie];}}
}
- (void)mergeCookie:(NSHTTPCookie *)cookie {
    NSIndexSet *old=[self.cookies indexesOfObjectsPassingTest:^BOOL(NSHTTPCookie *item,NSUInteger index,BOOL *stop){return [item.name isEqual:cookie.name]&&[item.domain isEqual:cookie.domain]&&[item.path isEqual:cookie.path];}];[self.cookies removeObjectsAtIndexes:old];[self.cookies addObject:cookie];
}
- (NSDictionary *)headers:(NSDictionary *)headers fromURL:(NSURL *)origin toURL:(NSURL *)url {
    NSMutableDictionary *clean=[NSMutableDictionary dictionary];
    for(NSString *key in headers){NSString *value=MNRString(headers[key]);if(!key.length||!value.length||[key rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)continue;
        if([@[@"host",@"connection",@"content-length",@"transfer-encoding",@"range"] containsObject:key.lowercaseString])continue;
        if(MNRSensitive(key)&&(!MNRSameOrigin(origin,url)||[key.lowercaseString isEqual:@"cookie"]))continue;clean[key]=value;
    }
    NSMutableArray *matching=[NSMutableArray array];for(NSHTTPCookie *cookie in self.cookies)if(MNRCookieMatches(cookie,url))[matching addObject:cookie];[clean addEntriesFromDictionary:[NSHTTPCookie requestHeaderFieldsWithCookies:matching]];
    if(![clean.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *key,NSDictionary *bindings){return [key.lowercaseString isEqual:@"user-agent"];}]].count)clean[@"User-Agent"]=@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Version/17.4 Mobile/15E148 Safari/604.1";
    return clean.copy;
}
- (BOOL)enqueueURL:(NSString *)raw base:(NSURL *)base headers:(NSDictionary *)headers depth:(NSUInteger)depth role:(NSString *)role {
    NSString *address=MNRResolvedString(raw,base);if(!address.length||depth>3||self.candidateCount>=8||[self.visited containsObject:address])return NO;
    for(NSDictionary *queued in self.queue)if([queued[@"url"] isEqual:address])return NO;
    NSMutableDictionary *h=[[self headers:headers fromURL:base toURL:[NSURL URLWithString:address]] mutableCopy];
    if(base.absoluteString.length)h[@"Referer"]=base.absoluteString;
    [self.queue addObject:@{@"url":address,@"headers":h.copy,@"scopeURL":address,@"depth":@(depth),@"role":role?:@"candidate"}];return YES;
}
- (void)pump {
    if(!self.completionBlock||self.working)return;
    while(self.queue.count){NSDictionary *node=self.queue.firstObject;[self.queue removeObjectAtIndex:0];NSString *address=node[@"url"];if([self.visited containsObject:address])continue;[self.visited addObject:address];self.candidateCount++;if(self.candidateCount>8)break;
        NSURL *url=[NSURL URLWithString:address];if(!MNRHTTP(url))continue;
        self.working=YES;MNRHTTPContext *context=[MNRHTTPContext new];context.node=node;context.data=[NSMutableData data];context.limit=MNRPageLimit;context.scopeURL=url;context.headers=[[self headers:node[@"headers"]?:@{} fromURL:url toURL:url] mutableCopy];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:MIN(MNRHTTPTimeout,MAX(0.1,MNRDeadline-(NSDate.timeIntervalSinceReferenceDate-self.startedAt)))];request.allHTTPHeaderFields=context.headers;
        context.task=[self.session dataTaskWithRequest:request];self.http=context;[self progress:@"validating"];[context.task resume];return;
    }
    if(self.web)return;
    if(self.pendingWebNode&&!self.webStarted){[self startWebForNode:self.pendingWebNode];return;}
    [self nextEntry];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    MNRHTTPContext *context=self.http;
    if(task!=context.task||![response isKindOfClass:NSHTTPURLResponse.class]||!self.completionBlock){completionHandler(NSURLSessionResponseCancel);return;}
    context.response=(NSHTTPURLResponse *)response;
    NSInteger status=context.response.statusCode;
    if(status<200||status>=300){context.failure=MNRError(status==401||status==403?@"AUTH_REQUIRED":@"RESOLVER_UNAVAILABLE",status==401||status==403?@"媒体或解析接口要求有效登录/授权":@"来源或解析接口返回了错误状态");completionHandler(NSURLSessionResponseCancel);return;}
    for(NSHTTPCookie *cookie in [NSHTTPCookie cookiesWithResponseHeaderFields:context.response.allHeaderFields forURL:response.URL])[self mergeCookie:cookie];
    NSString *mime=response.MIMEType.lowercaseString?:@"";
    context.limit=([mime hasPrefix:@"video/"]||[mime hasPrefix:@"audio/"]||[mime containsString:@"octet-stream"])?MNRBinaryLimit:MNRPageLimit;
    if([mime containsString:@"mpegurl"]||[mime containsString:@"dash+xml"])context.limit=MNRPageLimit;
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    MNRHTTPContext *context=self.http;if(task!=context.task||!self.completionBlock)return;
    if(!context.data.length&&data.length){NSString *prefix=MNRText([data subdataWithRange:NSMakeRange(0,MIN((NSUInteger)256,data.length))]);if([prefix containsString:@"#EXTM3U"]||[prefix containsString:@"<MPD"]||[prefix hasPrefix:@"<?xml"])context.limit=MNRPageLimit;}
    NSUInteger remain=context.limit>context.data.length?context.limit-context.data.length:0;
    if(remain)[context.data appendData:data.length>remain?[data subdataWithRange:NSMakeRange(0,remain)]:data];
    if(data.length>remain||context.data.length>=context.limit){
        if(context.limit==MNRBinaryLimit){context.boundedComplete=YES;}else context.failure=MNRError(@"NO_MEDIA",@"解析页面或媒体清单超过大小限制");
        [task cancel];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    MNRHTTPContext *context=self.http;if(task!=context.task||!MNRHTTP(request.URL)||++context.redirects>5){completionHandler(nil);return;}
    for(NSHTTPCookie *cookie in [NSHTTPCookie cookiesWithResponseHeaderFields:response.allHeaderFields forURL:response.URL])[self mergeCookie:cookie];
    NSMutableURLRequest *next=[request mutableCopy];NSDictionary *headers=[self headers:context.headers fromURL:context.scopeURL toURL:request.URL];next.allHTTPHeaderFields=headers;context.headers=[headers mutableCopy];context.scopeURL=request.URL;
    completionHandler(next);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    MNRHTTPContext *context=self.http;if(task!=context.task||!self.completionBlock)return;
    self.http=nil;self.working=NO;
    if(context.failure){[self failed:context.failure];return;}
    if(error&&!context.boundedComplete){[self failed:MNRError(error.code==NSURLErrorTimedOut?@"TIMEOUT":@"RESOLVER_UNAVAILABLE",@"媒体地址读取失败或超时")];return;}
    if(!context.response||!context.data.length){[self failed:MNRError(@"NO_MEDIA",@"来源未返回媒体数据")];return;}
    NSMutableDictionary *node=[context.node mutableCopy];node[@"headers"]=context.headers.copy;node[@"scopeURL"]=context.scopeURL.absoluteString?:node[@"url"];
    [self processData:context.data response:context.response node:node.copy];
}

- (void)acceptURL:(NSURL *)url format:(NSString *)format mime:(NSString *)mime headers:(NSDictionary *)headers evidence:(NSString *)evidence node:(NSDictionary *)node {
    if(!self.completionBlock)return;
    NSString *returnString=MNRString(node[@"validationReturnURL"]);NSURL *mediaURL=returnString.length?[NSURL URLWithString:returnString]:url;
    NSDictionary *returnHeaders=[node[@"validationReturnHeaders"] isKindOfClass:NSDictionary.class]?node[@"validationReturnHeaders"]:headers;
    NSMutableDictionary *result=[self.input mutableCopy]?:[NSMutableDictionary dictionary];
    BOOL unchanged=[MNRString(self.input[@"url"]) isEqual:mediaURL.absoluteString];
    result[@"url"]=mediaURL.absoluteString;
    if(!unchanged||!MNRString(result[@"originalURL"]).length)result[@"originalURL"]=mediaURL.absoluteString;
    NSString *page=MNRString(self.input[@"pageURL"]);if(!page.length)page=MNRString(self.entry[@"pageURL"]);
    if(!page.length&&!unchanged)page=MNRString(self.input[@"url"]);
    if(page.length)result[@"pageURL"]=page;
    for(NSString *key in @[@"resolutionCandidates",@"header",@"customHeaders",@"webPlayback",@"_nativeSniffed"])[result removeObjectForKey:key];
    if(!unchanged){
        // Source-page credentials and DRM hints must not survive a move to a
        // newly discovered media origin. Only URL-scoped headers are retained.
        [result removeObjectForKey:@"baseHeaders"];[result removeObjectForKey:@"ext"];[result removeObjectForKey:@"drmKey"];[result removeObjectForKey:@"licenseUrl"];
    }
    result[@"headers"]=[self headers:returnHeaders?:@{} fromURL:mediaURL toURL:mediaURL];
    result[@"format"]=format;result[@"contentType"]=mime;
    result[@"parse"]=@0;result[@"jx"]=@0;result[@"requiresWebPlayback"]=@NO;result[@"nativePlayable"]=@YES;result[@"directMedia"]=@YES;
    result[@"_nativeValidated"]=@YES;result[@"_nativeValidatedURL"]=mediaURL.absoluteString;result[@"resolutionIdentity"]=self.identity?:@{};
    result[@"playbackEngine"]=[@[@"dash",@"mpd",@"flv",@"mkv",@"webm"] containsObject:format]?@"cicada":@"avplayer";
    result[@"validationEvidence"]=@{@"kind":evidence?:@"video_track",@"host":mediaURL.host.lowercaseString?:@"",@"video":@YES};
    for(NSString *key in @[@"parserID",@"parserName"])if(MNRString(self.entry[key]).length)result[key]=self.entry[key];
    [self progress:@"resolved"];[self finish:result.copy error:nil];
}
- (void)probeVideoURL:(NSURL *)url format:(NSString *)format mime:(NSString *)mime headers:(NSDictionary *)headers node:(NSDictionary *)node {
    if(!self.completionBlock)return;
    self.working=YES;AVURLAsset *asset=[AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey":headers?:@{}}];self.probeAsset=asset;
    NSUInteger generation=self.generation;__weak typeof(self) weakSelf=self;
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{dispatch_async(dispatch_get_main_queue(),^{MediaNativePlaybackResolver *owner=weakSelf;if(!owner||owner.generation!=generation||owner.probeAsset!=asset||!owner.completionBlock)return;NSError *error=nil;BOOL hasVideo=[asset statusOfValueForKey:@"tracks" error:&error]==AVKeyValueStatusLoaded&&[asset tracksWithMediaType:AVMediaTypeVideo].count>0;owner.probeAsset=nil;owner.working=NO;[asset cancelLoading];if(hasVideo)[owner acceptURL:url format:format mime:mime headers:headers evidence:@"avasset_video_track" node:node];else [owner failed:MNRError(@"NO_MEDIA",@"候选媒体没有可确认的视频轨道")];});}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaNativePlaybackResolver *owner=weakSelf;if(!owner||owner.generation!=generation||owner.probeAsset!=asset||!owner.completionBlock)return;[asset cancelLoading];owner.probeAsset=nil;owner.working=NO;[owner failed:MNRError(@"NO_MEDIA",@"无法在限定时间内确认候选视频轨道")];});
}

- (void)processHLS:(NSString *)text url:(NSURL *)url headers:(NSDictionary *)headers node:(NSDictionary *)node {
    if([text containsString:@"KEYFORMAT=\"com.apple.streamingkeydelivery\""]||[text containsString:@"skd://"]||[text containsString:@"METHOD=SAMPLE-AES"]){[self failed:MNRError(@"DRM_UNSUPPORTED",@"此媒体需要当前构建尚未接入的授权许可证")];return;}
    NSArray *lines=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSString *variant=nil;BOOL videoDeclaration=NO,audioOnlyDeclaration=NO;NSString *previous=@"";
    for(NSString *line in lines){NSString *s=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([s hasPrefix:@"#EXT-X-STREAM-INF:"]){previous=s;continue;}
        if(previous.length&&s.length&&![s hasPrefix:@"#"]){
            NSString *upper=previous.uppercaseString;
            BOOL video=[upper containsString:@"RESOLUTION="]||[upper containsString:@"AVC"]||[upper containsString:@"HVC"]||[upper containsString:@"HEV"]||[upper containsString:@"AV01"]||[upper containsString:@"VP09"];
            if(video&&!variant.length){variant=MNRResolvedString(s,url);videoDeclaration=YES;}
            else if(!video&&[upper containsString:@"CODECS="]&&([upper containsString:@"MP4A"]||[upper containsString:@"AC-3"]||[upper containsString:@"EC-3"]))audioOnlyDeclaration=YES;
            else if(!variant.length)variant=MNRResolvedString(s,url);
            previous=@"";
        }
    }
    if(variant.length){
        if([node[@"depth"] unsignedIntegerValue]>=3){[self failed:MNRError(@"NO_MEDIA",@"媒体清单嵌套超过解析限制")];return;}
        BOOL queued=[self enqueueURL:variant base:url headers:headers depth:[node[@"depth"] unsignedIntegerValue]+1 role:@"hls_variant"];
        if(queued){NSMutableDictionary *child=[self.queue.lastObject mutableCopy];child[@"videoDeclared"]=@(videoDeclaration);child[@"validationReturnURL"]=node[@"validationReturnURL"]?:url.absoluteString;child[@"validationReturnHeaders"]=node[@"validationReturnHeaders"]?:headers;self.queue[self.queue.count-1]=child.copy;[self pump];return;}
        [self failed:MNRError(@"NO_MEDIA",@"媒体清单形成循环或没有可用分支")];return;
    }
    BOOL media=[text containsString:@"#EXTINF:"]||[text containsString:@"#EXT-X-PART:"];
    BOOL segments=NO;NSString *firstSegment=nil;for(NSString *line in lines){NSString *s=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(s.length&&![s hasPrefix:@"#"]){NSString *resolved=MNRResolvedString(s,url);if(resolved.length){segments=YES;if(!firstSegment)firstSegment=s;}}}
    if(audioOnlyDeclaration&&!videoDeclaration){[self failed:MNRError(@"NO_MEDIA",@"候选清单仅包含音频，不是视频正片")];return;}
    if(!media||!segments){[self failed:MNRError(@"NO_MEDIA",@"HLS 清单没有有效的媒体分片")];return;}
    if([node[@"videoDeclared"] boolValue]){[self acceptURL:url format:@"hls" mime:@"application/vnd.apple.mpegurl" headers:headers evidence:@"hls_video_variant" node:node];return;}
    NSUInteger depth=[node[@"depth"] unsignedIntegerValue];
    if(firstSegment.length&&depth<3&&[self enqueueURL:firstSegment base:url headers:headers depth:depth+1 role:@"hls_segment"]){
        NSMutableDictionary *segment=[self.queue.lastObject mutableCopy];segment[@"validationReturnURL"]=node[@"validationReturnURL"]?:url.absoluteString;segment[@"validationReturnHeaders"]=node[@"validationReturnHeaders"]?:headers;self.queue[self.queue.count-1]=segment.copy;[self pump];return;
    }
    [self probeVideoURL:url format:@"hls" mime:@"application/vnd.apple.mpegurl" headers:headers node:node];
}

- (NSArray<NSDictionary *> *)JSONCandidates:(id)value depth:(NSUInteger)depth {
    if(depth>4)return @[];
    if([value isKindOfClass:NSString.class]){NSString *s=MNRString(value);if(MNRHTTP([NSURL URLWithString:s]))return @[@{@"url":s}];return @[];}
    if([value isKindOfClass:NSArray.class]){NSMutableArray *out=[NSMutableArray array];for(id child in value){[out addObjectsFromArray:[self JSONCandidates:child depth:depth+1]];if(out.count>=8)break;}return out;}
    if(![value isKindOfClass:NSDictionary.class])return @[];
    NSDictionary *dictionary=value;
    for(NSString *key in @[@"url",@"playUrl",@"mediaUrl",@"src"]){NSString *address=MNRString(dictionary[key]);if(address.length){NSMutableDictionary *found=[dictionary mutableCopy];found[@"url"]=address;return @[found.copy];}}
    for(NSString *key in @[@"data",@"result",@"payload",@"playback",@"video"]){NSArray *found=[self JSONCandidates:dictionary[key] depth:depth+1];if(found.count)return found;}
    return @[];
}
- (void)processData:(NSData *)data response:(NSHTTPURLResponse *)response node:(NSDictionary *)node {
    NSURL *url=response.URL;NSString *mime=response.MIMEType.lowercaseString?:@"";NSDictionary *headers=[self headers:node[@"headers"]?:@{} fromURL:[NSURL URLWithString:MNRString(node[@"scopeURL"])] toURL:url];
    if([MNRString(node[@"role"]) isEqual:@"hls_segment"]){
        NSInteger videoState=MNRTransportStreamVideoState(data);NSURL *manifestURL=[NSURL URLWithString:MNRString(node[@"validationReturnURL"])];NSDictionary *manifestHeaders=[node[@"validationReturnHeaders"] isKindOfClass:NSDictionary.class]?node[@"validationReturnHeaders"]:headers;
        if(videoState>0){[self acceptURL:manifestURL format:@"hls" mime:@"application/vnd.apple.mpegurl" headers:manifestHeaders evidence:@"hls_transport_stream_video" node:node];return;}
        if(videoState==0){[self failed:MNRError(@"NO_MEDIA",@"HLS 分片确认只包含音频，没有视频轨道")];return;}
        if(manifestURL){[self probeVideoURL:manifestURL format:@"hls" mime:@"application/vnd.apple.mpegurl" headers:manifestHeaders node:node];return;}
        [self failed:MNRError(@"NO_MEDIA",@"HLS 分片无法确认并且缺少原始媒体清单")];return;
    }
    NSString *text=MNRText(data),*trim=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([trim hasPrefix:@"#EXTM3U"]){[self processHLS:trim url:url headers:headers node:node];return;}
    if([trim containsString:@"<MPD"]||[mime containsString:@"dash+xml"]){
        if([trim containsString:@"<!DOCTYPE"]||[trim containsString:@"<!ENTITY"]){[self failed:MNRError(@"NO_MEDIA",@"媒体清单包含不支持的外部实体")];return;}
        MNRMPDProbe *probe=[MNRMPDProbe new];NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];parser.shouldResolveExternalEntities=NO;parser.delegate=probe;BOOL valid=[parser parse];
        if(probe.protectedContent){[self failed:MNRError(@"DRM_UNSUPPORTED",@"DASH 媒体需要当前构建尚未接入的授权许可证")];return;}
        if(valid&&probe.root&&probe.video&&probe.segments){[self acceptURL:url format:@"dash" mime:@"application/dash+xml" headers:headers evidence:@"dash_video_representation" node:node];return;}
        [self failed:MNRError(@"NO_MEDIA",@"DASH 清单没有有效的视频轨道或分片描述")];return;
    }
    if(data.length>=12&&memcmp((const uint8_t *)data.bytes+4,"ftyp",4)==0){[self probeVideoURL:url format:@"mp4" mime:@"video/mp4" headers:headers node:node];return;}
    if(data.length>=9&&memcmp(data.bytes,"FLV",3)==0){const uint8_t *bytes=data.bytes;if(bytes[4]&1){[self acceptURL:url format:@"flv" mime:@"video/x-flv" headers:headers evidence:@"flv_video_flag" node:node];return;}[self failed:MNRError(@"NO_MEDIA",@"FLV 候选只包含音频")];return;}
    if([trim hasPrefix:@"{"]||[trim hasPrefix:@"["]||[mime containsString:@"json"]){
        id payload=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
        if([payload isKindOfClass:NSDictionary.class]){id code=payload[@"code"];NSString *codeString=[code respondsToSelector:@selector(description)]?[code description]:@"";if([@[@"401",@"403",@"AUTH_REQUIRED",@"LOGIN_REQUIRED"] containsObject:codeString]){[self failed:MNRError(@"AUTH_REQUIRED",@"解析接口要求有效登录或授权")];return;}}
        NSArray *candidates=[self JSONCandidates:payload depth:0];
        for(NSDictionary *candidate in candidates){NSString *address=MNRResolvedString(MNRString(candidate[@"url"]),url);if(!address.length)continue;NSMutableDictionary *h=[[self headers:headers fromURL:url toURL:[NSURL URLWithString:address]] mutableCopy];NSDictionary *explicit=MediaPlaybackHeadersFromResult(candidate);[self installHeaderCookies:explicit forURL:[NSURL URLWithString:address]];[h addEntriesFromDictionary:[self headers:explicit fromURL:[NSURL URLWithString:address] toURL:[NSURL URLWithString:address]]];[self enqueueURL:address base:url headers:h depth:[node[@"depth"] unsignedIntegerValue]+1 role:@"json"];}
        if(self.queue.count){[self pump];return;}[self failed:MNRError(@"NO_MEDIA",@"解析接口没有返回可验证的媒体地址")];return;
    }
    if(MNRHTTP([NSURL URLWithString:trim])&&trim.length<16384){if([self enqueueURL:trim base:url headers:headers depth:[node[@"depth"] unsignedIntegerValue]+1 role:@"text"]){[self pump];return;}}
    if(MNRLooksHTML(text,mime)){
        if([text containsString:@"江湖路远，后会无期"]){[self failed:MNRError(@"RESOLVER_UNAVAILABLE",@"当前解析服务已返回停用告别页")];return;}
        NSUInteger depth=[node[@"depth"] unsignedIntegerValue];
        if(depth>=3){[self failed:MNRError(@"NO_MEDIA",@"解析页面嵌套超过限制")];return;}
        NSMutableArray *videoURLs=[NSMutableArray array];
        for(NSString *tag in MNRMatches(text,@"(<video\\b[^>]*>|<source\\b[^>]*>)",1)){
            if([tag rangeOfString:@"(?:id|class|data-role)\\s*=\\s*['\"][^'\"]*(?:advert|preroll|trailer|preview)[^'\"]*['\"]" options:NSRegularExpressionSearch|NSCaseInsensitiveSearch].location!=NSNotFound)continue;
            [videoURLs addObjectsFromArray:MNRMatches(tag,@"\\bsrc\\s*=\\s*['\"]([^'\"]+)['\"]",1)];
        }
        NSMutableOrderedSet *unique=[NSMutableOrderedSet orderedSet];for(NSString *s in videoURLs){NSString *address=MNRResolvedString(s,url);if(address.length)[unique addObject:address];}
        if(unique.count>1){[self failed:MNRError(@"AMBIGUOUS_MEDIA",@"页面包含多个视频候选，无法确认当前分集主视频")];return;}
        for(NSString *address in unique)[self enqueueURL:address base:url headers:headers depth:depth+1 role:@"video"];
        if(!unique.count){
            for(NSString *json in MNRMatches(text,@"(?:player_[a-zA-Z0-9_]+|videoInfo|playInfo)\\s*=\\s*(\\{[^\\n;]+\\})",1)){
                NSDictionary *p=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];if(![p isKindOfClass:NSDictionary.class])continue;NSString *address=MNRString(p[@"url"]);if(!address.length)address=MNRString(p[@"playUrl"]);NSInteger encrypt=[p[@"encrypt"] integerValue];if(encrypt==1)address=address.stringByRemovingPercentEncoding?:address;else if(encrypt==2||encrypt==3){NSData *decoded=[[NSData alloc] initWithBase64EncodedString:address options:0];NSString *s=decoded?[[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding]:nil;if(s.length)address=s.stringByRemovingPercentEncoding?:s;}[self enqueueURL:address base:url headers:headers depth:depth+1 role:@"player"];
            }
        }
        NSMutableDictionary *pageNode=[node mutableCopy];pageNode[@"url"]=url.absoluteString;pageNode[@"headers"]=headers;self.pendingWebNode=pageNode.copy;
        BOOL dynamic=[text rangeOfString:@"<script" options:NSCaseInsensitiveSearch].location!=NSNotFound||[text rangeOfString:@"<iframe" options:NSCaseInsensitiveSearch].location!=NSNotFound||[text rangeOfString:@"<video" options:NSCaseInsensitiveSearch].location!=NSNotFound;
        if(!dynamic)self.pendingWebNode=nil;
        if(!self.queue.count&&!dynamic){[self failed:MNRError(@"NO_MEDIA",@"网页没有媒体地址或可执行的播放解析逻辑")];return;}
        [self pump];return;
    }
    // A MIME label alone does not prove that the body is a playable movie.
    // AVAsset is the bounded final probe for extensionless/other native formats.
    if([mime hasPrefix:@"video/"]&&!MNRLooksHTML(text,mime)&&![trim hasPrefix:@"{"]){[self probeVideoURL:url format:(url.pathExtension.lowercaseString.length?url.pathExtension.lowercaseString:@"mp4") mime:mime headers:headers node:node];return;}
    [self failed:MNRError(@"NO_MEDIA",@"候选响应不是可识别的视频清单或容器")];
}

- (void)startWebForNode:(NSDictionary *)node {
    if(!self.completionBlock||self.webStarted){[self nextEntry];return;}
    NSURL *url=[NSURL URLWithString:MNRString(node[@"url"])];
    if(!MNRHTTP(url)){[self failed:MNRError(@"NO_MEDIA",@"后台解析页面地址无效")];return;}
    MediaNativePlaybackResolver *previous=MNRWebOwner;
    if(previous&&previous!=self)[previous finish:nil error:MNRError(@"CANCELLED",@"后台解析已由新的播放请求替代")];
    MNRWebOwner=self;self.webStarted=YES;self.webToken=NSUUID.UUID.UUIDString;
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
#if TARGET_OS_IPHONE
    config.allowsInlineMediaPlayback=YES;
#endif
    WKUserContentController *content=[WKUserContentController new];
    NSData *tokenData=[NSJSONSerialization dataWithJSONObject:@[self.webToken] options:0 error:NULL];NSString *tokenArray=[[NSString alloc] initWithData:tokenData encoding:NSUTF8StringEncoding];
    NSString *source=[NSString stringWithFormat:@"window.__cctvNativeToken=(%@)[0];%@",tokenArray,MNRCaptureScript()];
    [content addUserScript:[[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    [content addScriptMessageHandler:self name:@"cctvNativeMedia"];config.userContentController=content;
    WKWebView *web=[[WKWebView alloc] initWithFrame:CGRectMake(-400,0,320,180) configuration:config];self.web=web;web.navigationDelegate=self;
#if TARGET_OS_IPHONE
    web.userInteractionEnabled=NO;web.accessibilityElementsHidden=YES;
    // Keep the document attached while scripts execute, outside the visible
    // native player. No browser controller or webpage is presented.
    if(self.hostView)[self.hostView addSubview:web];
#endif
    NSDictionary *headers=[self headers:node[@"headers"]?:@{} fromURL:url toURL:url];
    for(NSString *key in headers)if([key.lowercaseString isEqual:@"user-agent"])web.customUserAgent=headers[key];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:MIN(MNRWebTimeout,MAX(0.1,MNRDeadline-(NSDate.timeIntervalSinceReferenceDate-self.startedAt)))];request.allHTTPHeaderFields=headers;
    NSUInteger generation=self.generation;__weak typeof(self) weakSelf=self;__block BOOL loaded=NO;
    void (^load)(void)=^{MediaNativePlaybackResolver *owner=weakSelf;if(!owner||owner.generation!=generation||owner.web!=web||!owner.completionBlock||loaded)return;loaded=YES;[owner progress:@"background_page"];[web loadRequest:request];};
    dispatch_group_t cookies=dispatch_group_create();for(NSHTTPCookie *cookie in self.cookies){if(!MNRCookieMatches(cookie,url))continue;dispatch_group_enter(cookies);[config.websiteDataStore.httpCookieStore setCookie:cookie completionHandler:^{dispatch_group_leave(cookies);}];}
    dispatch_group_notify(cookies,dispatch_get_main_queue(),load);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,800*NSEC_PER_MSEC),dispatch_get_main_queue(),load);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MNRWebTimeout*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        MediaNativePlaybackResolver *owner=weakSelf;if(!owner||owner.generation!=generation||owner.web!=web||!owner.completionBlock)return;
        BOOL ambiguous=owner.observed.count>1;[owner teardownWeb];owner.lastError=MNRError(ambiguous?@"AMBIGUOUS_MEDIA":@"NO_MEDIA",ambiguous?@"后台页面包含多个无法确认身份的媒体候选":@"后台页面未提供可交给原生播放器的视频媒体");
        [owner pump];
    });
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if(webView!=self.web||!self.completionBlock)return;self.webReady=YES;
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self webView:webView didFailNavigation:navigation withError:error];}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if(webView!=self.web||!self.completionBlock||error.code==NSURLErrorCancelled)return;
    [self teardownWeb];[self failed:MNRError(@"RESOLVER_UNAVAILABLE",@"后台播放解析页面无法加载")];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSString *scheme=action.request.URL.scheme.lowercaseString?:@"";BOOL allowed=MNRHTTP(action.request.URL)||[scheme isEqual:@"about"];
    decisionHandler(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
    if(allowed&&!action.targetFrame)[webView loadRequest:action.request];
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if(!self.completionBlock||message.webView!=self.web||![message.name isEqual:@"cctvNativeMedia"]||![message.body isKindOfClass:NSDictionary.class])return;
    NSDictionary *payload=message.body;
    if(![MNRString(payload[@"token"]) isEqual:self.webToken])return;
    NSURL *frameURL=[NSURL URLWithString:MNRString(payload[@"frameURL"])];NSString *originHost=message.frameInfo.securityOrigin.host.lowercaseString?:@"",*originProtocol=message.frameInfo.securityOrigin.protocol.lowercaseString?:@"";
    if(!MNRHTTP(frameURL)||![originHost isEqual:frameURL.host.lowercaseString]||![originProtocol isEqual:frameURL.scheme.lowercaseString])return;
    if([payload[@"protectedContent"] boolValue]){[self finish:nil error:MNRError(@"DRM_UNSUPPORTED",@"后台页面要求受保护媒体的授权许可证")];return;}
    NSArray *candidates=[payload[@"candidates"] isKindOfClass:NSArray.class]?payload[@"candidates"]:@[];
    NSUInteger count=0;for(id raw in candidates){if(++count>8)break;if(![raw isKindOfClass:NSDictionary.class])continue;NSString *address=MNRString(raw[@"url"]),*role=MNRString(raw[@"role"]);if(![@[@"video",@"player",@"network"] containsObject:role]||!MNRHTTP([NSURL URLWithString:address]))continue;
        NSDictionary *prior=self.observed[address];NSDictionary *rank=@{@"video":@3,@"player":@2,@"network":@1};
        if(!prior||[rank[role] integerValue]>[rank[prior[@"role"]] integerValue])self.observed[address]=@{@"url":address,@"role":role,@"frameURL":frameURL.absoluteString};
    }
    if(self.observed.count>8){[self finish:nil error:MNRError(@"AMBIGUOUS_MEDIA",@"后台页面媒体候选过多，无法确认分集主视频")];return;}
    NSUInteger generation=self.generation;WKWebView *web=self.web;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        MediaNativePlaybackResolver *owner=weakSelf;if(!owner||owner.generation!=generation||owner.web!=web||!owner.completionBlock)return;
        NSDictionary *rank=@{@"video":@3,@"player":@2,@"network":@1};NSInteger highest=0;NSMutableArray *best=[NSMutableArray array];
        for(NSDictionary *candidate in owner.observed.allValues){NSInteger r=[rank[candidate[@"role"]] integerValue];if(r>highest){highest=r;[best removeAllObjects];}if(r==highest)[best addObject:candidate];}
        if(best.count!=1)return;
        NSDictionary *candidate=best.firstObject;NSString *address=candidate[@"url"];
        if([owner.visited containsObject:address])return;
        [web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies){dispatch_async(dispatch_get_main_queue(),^{
            MediaNativePlaybackResolver *current=weakSelf;if(!current||current.generation!=generation||current.web!=web||!current.completionBlock)return;
            for(NSHTTPCookie *cookie in cookies)[current mergeCookie:cookie];
            NSURL *base=[NSURL URLWithString:candidate[@"frameURL"]];NSDictionary *pageHeaders=[current.pendingWebNode[@"headers"] isKindOfClass:NSDictionary.class]?current.pendingWebNode[@"headers"]:@{};
            [current enqueueURL:address base:base headers:pageHeaders depth:[current.pendingWebNode[@"depth"] unsignedIntegerValue]+1 role:candidate[@"role"]];[current pump];
        });}];
    });
}
- (void)dealloc {[self.http.task cancel];[self.probeAsset cancelLoading];[self.session invalidateAndCancel];}
@end
