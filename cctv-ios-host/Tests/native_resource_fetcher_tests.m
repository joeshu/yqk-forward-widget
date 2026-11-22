#import <Foundation/Foundation.h>
#import "ResourceImportFetcher.h"
#import "HostSyncRequest.h"
#import <string.h>
#define Check(v) do{if(!(v)){NSLog(@"failed: %s",#v);return 1;}}while(0)
static void waitFor(BOOL (^finished)(void),NSTimeInterval seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];while(!finished()&&end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];}
int main(int argc,char **argv){@autoreleasepool {
    Check(argc==2);NSString *base=[NSString stringWithFormat:@"http://127.0.0.1:%s",argv[1]];
    HostSyncRequest *sync=[[HostSyncRequest alloc] initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    Check([sync performRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/ok"]]]][@"error"]!=nil);
    for(NSString *path in @[@"/ok",@"/redirect",@"/loop",@"/too-large",@"/stream-large",@"/zip-large",@"/zip-stream",@"/fake.zip",@"/zip-over-limit"]){
        __block BOOL done=NO;__block NSError *failure=nil;__block NSData *body=nil;__block NSUInteger calls=0;
        ResourceImportFetcher *fetch=[ResourceImportFetcher new];fetch.completion=^(NSData *data,NSURLResponse *response,NSError *error){if(!NSThread.isMainThread)abort();body=data;failure=error;calls++;done=YES;};
        [fetch load:[NSURL URLWithString:[base stringByAppendingString:path]]];NSURL *temporaryURL=[fetch valueForKey:@"bodyURL"];waitFor(^BOOL{return done;},10);
        Check(done&&calls==1);
        Check(temporaryURL && ![NSFileManager.defaultManager fileExistsAtPath:temporaryURL.path]);
        if([@[@"/ok",@"/redirect"] containsObject:path])Check(!failure&&[[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] isEqual:@"resource"]);
        else if([@[@"/zip-large",@"/zip-stream"] containsObject:path])Check(!failure&&body.length>8*1024*1024&&body.length<24*1024*1024&&memcmp(body.bytes,"PK\003\004",4)==0);
        else Check(failure!=nil);
    }
    __block BOOL delivered=NO;ResourceImportFetcher *cancel=[ResourceImportFetcher new];cancel.completion=^(NSData *data,NSURLResponse *response,NSError *error){delivered=YES;};
    [cancel load:[NSURL URLWithString:[base stringByAppendingString:@"/slow"]]];NSURL *cancelURL=[cancel valueForKey:@"bodyURL"];[cancel cancel];waitFor(^BOOL{return delivered;},.5);Check(!delivered);Check(cancelURL && ![NSFileManager.defaultManager fileExistsAtPath:cancelURL.path]);
    NSLog(@"Resource fetch limits, redirect bounds, main-thread guard and cancellation passed");return 0;
}}
