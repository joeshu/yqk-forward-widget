#import "PluginLogStore.h"
#import "HostLogBuffer.h"
#import "HostLogRedactor.h"
#import <CommonCrypto/CommonDigest.h>

@interface PluginLogStore ()
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) NSMutableDictionary<NSString *,HostLogBuffer *> *pending;
@property(nonatomic,strong) NSMutableSet<NSString *> *scheduled;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *generations;
@property(nonatomic,strong) NSLock *lock;
- (void)flushIdentifier:(NSString *)identifier generation:(NSUInteger)generation;
@end

@implementation PluginLogStore
+ (instancetype)shared {static PluginLogStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[PluginLogStore new];});return store;}
- (instancetype)init {
    if((self=[super init])){
        NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
        self.directory=[[support stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"plugin-logs"];
        self.queue=dispatch_queue_create("com.cctvhost.plugin-logs",DISPATCH_QUEUE_SERIAL);
        self.pending=[NSMutableDictionary dictionary];self.scheduled=[NSMutableSet set];self.generations=[NSMutableDictionary dictionary];self.lock=[NSLock new];
    }
    return self;
}
- (NSString *)pathForIdentifier:(NSString *)identifier {
    NSData *data=[(identifier.length?identifier:@"unknown") dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *name=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[name appendFormat:@"%02x",digest[i]];return [self.directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"log"]];
}
- (void)appendLine:(NSString *)line forIdentifier:(NSString *)identifier {
    if(!line.length||!identifier.length)return;
    NSString *safeLine=[HostLogRedactor redactText:line];if(safeLine.length>4096){NSUInteger end=4096;unichar last=[safeLine characterAtIndex:end-1];if(last>=0xd800&&last<=0xdbff)end--;safeLine=[[safeLine substringToIndex:end] stringByAppendingString:@"… [日志已截断]"];}
    NSString *entry=[NSString stringWithFormat:@"[%@] %@\n",NSDate.date.description,safeLine];NSUInteger generation=0;BOOL schedule=NO;
    [self.lock lock];HostLogBuffer *buffer=self.pending[identifier];if(!buffer){buffer=[[HostLogBuffer alloc] initWithMaximumCharacters:65536];self.pending[identifier]=buffer;}[buffer append:entry];generation=[self.generations[identifier] unsignedIntegerValue];if(![self.scheduled containsObject:identifier]){[self.scheduled addObject:identifier];schedule=YES;}[self.lock unlock];
    if(schedule)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),self.queue,^{[self flushIdentifier:identifier generation:generation];});
}
- (void)flushIdentifier:(NSString *)identifier generation:(NSUInteger)generation {
    [self.lock lock];if([self.generations[identifier] unsignedIntegerValue]!=generation){[self.lock unlock];return;}[self.scheduled removeObject:identifier];NSString *batch=[self.pending[identifier] drain];[self.lock unlock];if(!batch.length)return;
    NSString *path=[self pathForIdentifier:identifier];NSFileManager *fm=NSFileManager.defaultManager;[fm createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];if(![fm fileExistsAtPath:path])[fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:path];@try{[file seekToEndOfFile];[file writeData:[batch dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];file=nil;}@catch(NSException *exception){@try{[file closeFile];}@catch(NSException *ignored){};return;}
    unsigned long long size=[[fm attributesOfItemAtPath:path error:NULL] fileSize];if(size>512*1024){NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:path];[reader seekToFileOffset:size-256*1024];NSData *tail=[reader readDataOfLength:256*1024];[reader closeFile];NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];NSRange boundary=[tail rangeOfData:newline options:0 range:NSMakeRange(0,tail.length)];if(boundary.location!=NSNotFound)[[tail subdataWithRange:NSMakeRange(NSMaxRange(boundary),tail.length-NSMaxRange(boundary))] writeToFile:path atomically:YES];}
}
- (NSString *)logForIdentifier:(NSString *)identifier {
    if(!identifier.length)return @"";__block NSString *text=@"";NSString *path=[self pathForIdentifier:identifier];
    dispatch_sync(self.queue,^{[self.lock lock];NSUInteger generation=[self.generations[identifier] unsignedIntegerValue];[self.lock unlock];[self flushIdentifier:identifier generation:generation];text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL]?:@"";text=[HostLogRedactor redactText:text];});return text;
}
- (void)clearLogForIdentifier:(NSString *)identifier completion:(dispatch_block_t)completion {
    if(!identifier.length){if(completion)completion();return;}NSString *path=[self pathForIdentifier:identifier];dispatch_async(self.queue,^{[self.lock lock];self.generations[identifier]=@([self.generations[identifier] unsignedIntegerValue]+1);[self.pending[identifier] clear];[self.scheduled removeObject:identifier];[self.lock unlock];[@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];if(completion)dispatch_async(dispatch_get_main_queue(),completion);});
}
- (void)prepareExportForIdentifier:(NSString *)identifier displayName:(NSString *)displayName completion:(void (^)(NSURL *,NSError *))completion {
    NSString *source=identifier.length?[self pathForIdentifier:identifier]:nil;NSString *safe=[displayName stringByReplacingOccurrencesOfString:@"/" withString:@"-"]?:@"插件";NSString *digest=source.lastPathComponent.stringByDeletingPathExtension;NSString *suffix=digest.length>=8?[digest substringToIndex:8]:@"plugin";NSString *destination=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CCTVHost-%@-%@-日志.txt",safe,suffix]];
    dispatch_async(self.queue,^{if(identifier.length){[self.lock lock];NSUInteger generation=[self.generations[identifier] unsignedIntegerValue];[self.lock unlock];[self flushIdentifier:identifier generation:generation];}NSError *error=nil;NSString *content=source?[NSString stringWithContentsOfFile:source encoding:NSUTF8StringEncoding error:&error]:nil;if(!content&&!error)error=[NSError errorWithDomain:@"PluginLogStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"该脚本还没有日志记录。"}];NSData *data=content?[[HostLogRedactor redactText:content] dataUsingEncoding:NSUTF8StringEncoding]:nil;if(data&&![data writeToFile:destination options:NSDataWritingAtomic error:&error])data=nil;dispatch_async(dispatch_get_main_queue(),^{completion(data?[NSURL fileURLWithPath:destination]:nil,error);});});
}
@end
