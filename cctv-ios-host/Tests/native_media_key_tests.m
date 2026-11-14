#import <Foundation/Foundation.h>
#import "MediaKeyRequest.h"
static void check(BOOL value,NSString *message){if(!value){NSLog(@"FAILED %@",message);exit(1);}}
static void run(NSString *address,BOOL success,BOOL cancel) {
    __block NSUInteger calls=0;__block NSData *result;__block NSError *failure;
    MediaKeyRequest *request=[MediaKeyRequest new];
    [request loadURL:[NSURL URLWithString:address] headers:@{@"Authorization":@"private",@"X-API-Key":@"private",@"X-Auth":@"private",@"X-Session":@"private",@"Referer":@"https://origin.test/watch",@"Origin":@"https://origin.test"} completion:^(NSData *data,NSError *error){calls++;result=data;failure=error;}];
    if(cancel)[request cancel];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];while(!calls&&[deadline timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    check(calls==1,@"request completes once within its deadline");
    if(success)check(result.length==16&&!failure,@"valid key is delivered");else check(failure!=nil,@"invalid, oversized or canceled key returns an error");
}
int main(int argc,const char **argv){@autoreleasepool{
    NSString *base=[NSString stringWithUTF8String:argv[1]];
    run([base stringByAppendingString:@"/key"],YES,NO);
    run([base stringByAppendingString:@"/large"],NO,NO);
    run([base stringByAppendingString:@"/denied"],NO,NO);
    run([base stringByAppendingString:@"/redirect"],YES,NO);
    run([base stringByAppendingString:@"/key"],NO,YES);
    run([base stringByAppendingString:@"/same"],YES,NO);
    run([base stringByAppendingString:@"/loop"],NO,NO);
    run(@"file:///tmp/key",NO,NO);
    run(@"http://user:password@127.0.0.1/key",NO,NO);
    __block NSUInteger firstCalls=0,secondCalls=0;
    MediaKeyRequest *single=[MediaKeyRequest new];
    [single loadURL:[NSURL URLWithString:[base stringByAppendingString:@"/key"]] headers:@{} completion:^(NSData *data,NSError *error){firstCalls++;check(data.length==16&&!error,@"duplicate call preserves original request");}];
    [single loadURL:[NSURL URLWithString:base] headers:@{} completion:^(NSData *data,NSError *error){secondCalls++;check(!data&&error,@"duplicate call rejected");}];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];while(!firstCalls&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    check(firstCalls==1&&secondCalls==1,@"both invocations complete once");
    return 0;
}}
