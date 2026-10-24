#import "HLSRouteProbe.h"
@interface HLSRouteProbe () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,copy) void (^completion)(BOOL);
@property(nonatomic) NSUInteger depth;
@property(nonatomic) BOOL cancelled;
@end
@implementation HLSRouteProbe
- (void)startURL:(NSURL *)url completion:(void (^)(BOOL))completion {
    [self cancel];self.cancelled=NO;self.depth=0;self.completion=completion;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache=nil;config.HTTPCookieStorage=nil;config.timeoutIntervalForRequest=3;config.timeoutIntervalForResource=4;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:NSOperationQueue.mainQueue];
    [self fetch:url];
}
- (BOOL)validURL:(NSURL *)url {return url.host.length&&[@[@"http",@"https"] containsObject:url.scheme.lowercaseString]&&!url.user.length&&!url.password.length;}
- (void)fetch:(NSURL *)url {
    if(self.cancelled)return;
    if(![self validURL:url]){[self finish:NO];return;}
    self.body=[NSMutableData data];NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
    [request setValue:@"qqlive" forHTTPHeaderField:@"User-Agent"];[request setValue:@"https://live.cctv.cn/" forHTTPHeaderField:@"Referer"];
    self.task=[self.session dataTaskWithRequest:request];[self.task resume];
}
- (void)finish:(BOOL)plain {
    void(^done)(BOOL)=self.completion;self.completion=nil;[self.task cancel];self.task=nil;[self.session invalidateAndCancel];self.session=nil;
    if(!self.cancelled&&done)done(plain);
}
- (void)cancel {self.cancelled=YES;self.completion=nil;[self.task cancel];self.task=nil;[self.session invalidateAndCancel];self.session=nil;self.body=nil;}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    BOOL valid=task==self.task&&!self.cancelled&&[(NSHTTPURLResponse *)response statusCode]==200&&response.expectedContentLength<=256*1024;
    completionHandler(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid&&task==self.task)[self finish:NO];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(task!=self.task||self.cancelled)return;
    if(data.length>256*1024-self.body.length){[self finish:NO];return;}[self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(task==self.task&&[self validURL:request.URL]?request:nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(task!=self.task||self.cancelled)return;
    if(error){[self finish:NO];return;}
    NSString *text=[[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    if(![text hasPrefix:@"#EXTM3U"]){[self finish:NO];return;}
    NSString *child=nil;BOOL master=NO,media=NO;
    for(NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([line hasPrefix:@"#EXT-X-KEY:"]&&![line containsString:@"METHOD=NONE"]){[self finish:NO];return;}
        if([line hasPrefix:@"#EXT-X-SESSION-KEY:"]){[self finish:NO];return;}
        if([line hasPrefix:@"#EXT-X-STREAM-INF:"])master=YES;
        if([line hasPrefix:@"#EXTINF:"]||[line hasPrefix:@"#EXT-X-PART:"])media=YES;
        if(!child&&line.length&&![line hasPrefix:@"#"])child=line;
    }
    if(master){
        if(!child.length||self.depth++>=2){[self finish:NO];return;}
        NSURL *url=[NSURL URLWithString:child relativeToURL:task.response.URL].absoluteURL;[self fetch:url];return;
    }
    [self finish:media&&child.length>0];
}
@end
