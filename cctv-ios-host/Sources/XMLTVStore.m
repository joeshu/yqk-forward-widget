#import "XMLTVStore.h"
#import "ProfileStore.h"
#import <zlib.h>
#import <CommonCrypto/CommonDigest.h>
@interface XMLTVReader : NSObject <NSXMLParserDelegate>
@property(nonatomic,strong) NSMutableDictionary *channels;
@property(nonatomic,strong) NSMutableDictionary *aliases;
@property(nonatomic,strong) NSMutableDictionary *programme;
@property(nonatomic,strong) NSMutableString *text;
@property(nonatomic,copy) NSString *channel;
@property(nonatomic,copy) NSString *element;
@property(nonatomic,strong) NSDateFormatter *formatter;
@property(nonatomic,assign) NSUInteger count;
@end
@implementation XMLTVReader
- (instancetype)init {if(self=[super init]){_channels=[NSMutableDictionary dictionary];_aliases=[NSMutableDictionary dictionary];_formatter=[NSDateFormatter new];_formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];_formatter.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];_formatter.dateFormat=@"yyyyMMddHHmmss Z";}return self;}
- (NSTimeInterval)timestamp:(NSString *)s {if(!s.length)return 0;NSString *value=s;if(s.length==14)value=[s stringByAppendingString:@" +0000"];return [[self.formatter dateFromString:value] timeIntervalSince1970];}
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)n qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    self.element=e;self.text=[NSMutableString string];
    if([e isEqual:@"channel"])self.channel=a[@"id"];
    if([e isEqual:@"programme"]){self.programme=[@{@"channel":a[@"channel"]?:@"",@"start":@([self timestamp:a[@"start"]]),@"end":@([self timestamp:a[@"stop"]])} mutableCopy];if(++self.count>250000)[p abortParsing];}
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {if(self.text.length+s.length>65536){[p abortParsing];return;}[self.text appendString:s];}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)n qualifiedName:(NSString *)q {
    NSString *text=[self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([e isEqual:@"display-name"]&&self.channel.length&&text.length)self.aliases[text.lowercaseString]=self.channel;
    if([e isEqual:@"channel"])self.channel=nil;
    if([e isEqual:@"title"]&&self.programme&&![self.programme[@"title"] length])self.programme[@"title"]=text;
    if([e isEqual:@"programme"]){NSString *cid=self.programme[@"channel"];if(cid.length&&[self.programme[@"title"] length]&&[self.programme[@"start"] doubleValue]>0&&[self.programme[@"end"] doubleValue]>[self.programme[@"start"] doubleValue]){NSMutableArray *rows=self.channels[cid];if(!rows){rows=[NSMutableArray array];self.channels[cid]=rows;}[rows addObject:@{@"start":self.programme[@"start"],@"end":self.programme[@"end"],@"title":self.programme[@"title"]}];}self.programme=nil;}
    self.text=[NSMutableString string];
}
@end
@interface XMLTVStore ()
@property(nonatomic,strong) NSMutableDictionary *cache;
@property(nonatomic,strong) NSMutableDictionary *tasks;
@property(nonatomic,strong) NSMutableDictionary *callbacks;
@property(nonatomic,assign) BOOL paused;
@property(nonatomic,assign) NSUInteger generation;
@property(nonatomic,strong) dispatch_queue_t diskQueue;
@end
@implementation XMLTVStore
+ (instancetype)shared {static XMLTVStore *s;static dispatch_once_t once;dispatch_once(&once,^{s=[self new];s.cache=[NSMutableDictionary dictionary];s.tasks=[NSMutableDictionary dictionary];s.callbacks=[NSMutableDictionary dictionary];s.diskQueue=dispatch_queue_create("com.cctvhost.xmltv",DISPATCH_QUEUE_SERIAL);});return s;}
+ (NSDictionary *)parseData:(NSData *)input error:(NSError **)error {
    NSData *data=input;const unsigned char *b=data.bytes;
    if(data.length>64*1024*1024)goto invalid;
    if(data.length>2&&b[0]==0x1f&&b[1]==0x8b){z_stream stream={0};if(inflateInit2(&stream,15+32)!=Z_OK)goto invalid;stream.next_in=(Bytef *)data.bytes;stream.avail_in=(uInt)data.length;NSMutableData *out=[NSMutableData data];int rc;unsigned char buffer[32768];do{stream.next_out=buffer;stream.avail_out=sizeof(buffer);rc=inflate(&stream,Z_NO_FLUSH);[out appendBytes:buffer length:sizeof(buffer)-stream.avail_out];if(out.length>64*1024*1024){rc=Z_MEM_ERROR;break;}}while(rc==Z_OK);inflateEnd(&stream);if(rc!=Z_STREAM_END)goto invalid;data=out;}
    {XMLTVReader *reader=[XMLTVReader new];NSXMLParser *p=[[NSXMLParser alloc] initWithData:data];p.shouldResolveExternalEntities=NO;p.delegate=reader;
        if(![p parse]||!reader.channels.count)goto invalid;
        NSMutableDictionary *result=[NSMutableDictionary dictionary];for(NSString *cid in reader.channels){NSArray *rows=[reader.channels[cid] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"start"] compare:b[@"start"]];}];result[cid.lowercaseString]=rows;}
        for(NSString *alias in reader.aliases)if(!result[alias])result[alias]=result[[reader.aliases[alias] lowercaseString]];
        return result;}
invalid:
    if(error)*error=[NSError errorWithDomain:@"XMLTV" code:1 userInfo:@{NSLocalizedDescriptionKey:@"XMLTV 数据无效、过大或没有有效节目，请检查来源。"}];return nil;
}
- (NSString *)pathForSource:(NSString *)s {NSString *dir=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"XMLTV"];[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding];unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,hash);NSMutableString *key=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[key appendFormat:@"%02x",hash[i]];return [dir stringByAppendingPathComponent:[key stringByAppendingString:@".plist"]];}
- (NSArray *)cachedRowsForSource:(NSString *)source channel:(NSString *)identifier {return self.cache[source][@"rows"][identifier.lowercaseString]?:@[];}
- (void)setPaused:(BOOL)paused {
    _paused=paused;if(!paused)return;self.generation++;
    for(NSURLSessionDataTask *task in self.tasks.allValues)[task cancel];[self.tasks removeAllObjects];
    NSDictionary *pending=[self.callbacks copy];[self.callbacks removeAllObjects];for(NSArray *blocks in pending.allValues)for(void (^block)(NSDictionary *,NSError *) in blocks)block(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
}
- (void)loadSource:(NSString *)source channel:(NSString *)identifier force:(BOOL)force completion:(void (^)(NSArray<NSDictionary *> *,NSError *))completion {
    if(![ProfileStore isHTTP:source]){completion(@[],[NSError errorWithDomain:@"XMLTV" code:2 userInfo:@{NSLocalizedDescriptionKey:@"请先配置有效的 XMLTV 地址。"}]);return;}
    if(self.paused){NSArray *rows=[self cachedRowsForSource:source channel:identifier];completion(rows,rows.count?nil:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);return;}
    void (^finish)(NSDictionary *,NSError *)=^(NSDictionary *cache,NSError *error){completion(cache[@"rows"][identifier.lowercaseString]?:@[],error);};
    if(self.callbacks[source]){[self.callbacks[source] addObject:[finish copy]];return;}
    self.callbacks[source]=[NSMutableArray arrayWithObject:[finish copy]];NSUInteger generation=self.generation;NSString *path=[self pathForSource:source];NSDictionary *memory=self.cache[source];
    dispatch_async(self.diskQueue,^{NSDictionary *cached=memory?:[NSDictionary dictionaryWithContentsOfFile:path];dispatch_async(dispatch_get_main_queue(),^{
        if(generation!=self.generation)return;
        if(cached)self.cache[source]=cached;
        NSTimeInterval age=NSDate.date.timeIntervalSince1970-[cached[@"ts"] doubleValue];
        if(!force&&cached&&age>=0&&age<6*3600){[self complete:source cache:cached error:nil];return;}
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:source]];request.timeoutInterval=20;
        NSURLSessionDataTask *task=[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
            dispatch_async(self.diskQueue,^{NSError *parseError=error;NSDictionary *rows=nil;
                NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
                if(!error&&status>=200&&status<300)rows=[XMLTVStore parseData:data error:&parseError];
                else if(!parseError)parseError=[NSError errorWithDomain:@"XMLTV" code:status userInfo:@{NSLocalizedDescriptionKey:@"节目单下载失败，保留上次缓存。"}];
                NSDictionary *entry=rows?@{@"rows":rows,@"ts":@(NSDate.date.timeIntervalSince1970)}:cached;
                dispatch_async(dispatch_get_main_queue(),^{if(generation!=self.generation)return;if(entry)self.cache[source]=entry;[self complete:source cache:entry error:parseError];if(rows)dispatch_async(self.diskQueue,^{[entry writeToFile:path atomically:YES];});});
            });
        }];self.tasks[source]=task;[task resume];
    });});
}
- (void)complete:(NSString *)source cache:(NSDictionary *)cache error:(NSError *)error {NSArray *blocks=[self.callbacks[source] copy];[self.callbacks removeObjectForKey:source];[self.tasks removeObjectForKey:source];for(void (^block)(NSDictionary *,NSError *) in blocks)block(cache,error);}
- (void)clear {[self setPaused:YES];[self.cache removeAllObjects];NSString *dir=[[self pathForSource:@"clear"] stringByDeletingLastPathComponent];dispatch_async(self.diskQueue,^{[NSFileManager.defaultManager removeItemAtPath:dir error:NULL];});[self setPaused:NO];}
@end
