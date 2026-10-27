#import <Foundation/Foundation.h>
#import "MediaSearchResults.h"
#import "MediaRelayDiagnostics.h"
#define CHECK(condition) do { if(!(condition)){NSLog(@"Failed line %d",__LINE__);return 1;} } while(0)
int main(void){@autoreleasepool{
    NSDictionary *event=@{@"event":@"media_relay_failed",@"request_id":@"trace-fixture",@"upstream_status":@403,@"upstream_host":@"fixture.test",@"url":@"private",@"Cookie":@"credential",@"service_id":@"forged"};
    NSString *line=[@"[CCTVHostMediaRelay] " stringByAppendingString:[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:event options:0 error:NULL] encoding:NSUTF8StringEncoding]];
    NSDictionary *parsed=MediaRelayDiagnosticRecord(line);
    CHECK([parsed[@"upstream_status"] integerValue]==403);
    CHECK(parsed[@"url"]==nil&&parsed[@"Cookie"]==nil&&parsed[@"service_id"]==nil);
    CHECK(MediaRelayDiagnosticRecord(@"[CCTVHostMediaRelay] not JSON")==nil);
    CHECK(MediaRelayDiagnosticRecord(@"[CCTVHostMediaRelay] {\"event\":\"app_started\"}")==nil);
    NSMutableArray *stored=[NSMutableArray array];
    NSArray *items=@[@{@"id":@"same",@"name":@"Film"},@{@"id":@"same",@"name":@"Duplicate"},NSNull.null,@{@"name":@""}];
    CHECK(MediaSearchAppend(stored,items,@"a",@"Station A",100)==1);
    CHECK(MediaSearchAppend(stored,items,@"b",@"Station B",100)==1);
    CHECK(stored.count==2);
    CHECK(MediaSearchAppend(stored,items,@"a",@"Station A",100)==0);
    CHECK(MediaSearchEntries(stored,@"a").count==1);
    CHECK(MediaSearchEntries(stored,@"b").count==1);
    CHECK(MediaSearchEntries(stored,@"missing").count==0);
    CHECK(MediaSearchEntries(stored,nil).count==2);
    CHECK(MediaSearchAppend(stored,@[@{@"id":@1,@"name":@"One"},@{@"id":@2,@"name":@"Two"}],@"a",@"A",1)==1);
    CHECK(MediaSearchAppend(stored,items,@"c",@"C",0)==0);
    CHECK(![MediaSearchIdentity(@"a|b",@"c") isEqual:MediaSearchIdentity(@"a",@"b|c")]);
    CHECK(MediaSearchText(@2026).length==4);
    CHECK(MediaSearchText(NSNull.null).length==0);
    CHECK(MediaSearchText(@[]).length==0);
    CHECK(MediaSearchEntries(stored,@"a").count==2);
}return 0;}
