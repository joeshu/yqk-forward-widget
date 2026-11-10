#import <Foundation/Foundation.h>
#import "MediaJARSource.h"
#import "TVBoxCatalogStore.h"
#define Check(value) do { if(!(value)){NSLog(@"failed: %s",#value);return 1;} } while(0)
int main(void){@autoreleasepool {
    Check([MediaJARClass(@"csp_Test") isEqual:@"csp_Test"]);
    Check(!MediaJARClass(@"csp_").length&&!MediaJARClass(@"csp_Test/evil").length);
    Check([MediaJARClass(@"com.github.catvod.spider.Test") length]>0);
    Check(!MediaJARClass(@"https://example.test/csp_Test").length);
    NSDictionary *jar=MediaJARReference(@"./spider.jar;md5;0123456789ABCDEF0123456789ABCDEF",@"https://source.test/sub/config.json?token=private");
    Check([jar[@"url"] isEqual:@"https://source.test/sub/spider.jar"]);
    Check([jar[@"md5"] isEqual:@"0123456789abcdef0123456789abcdef"]);
    Check(!MediaJARReference(@"file:///tmp/spider.jar",@"https://source.test/config"));
    Check(!MediaJARReference(@"https://u:p@source.test/a.jar",nil));
    Check(!MediaJARReference(@"https://source.test/a.jar;md5;invalid",nil));
    NSDictionary *config=@{@"spider":@"./global.jar",@"sites":@[@{@"key":@"global",@"type":@3,@"api":@"csp_Test",@"ext":@{@"hello":@"中文😀"}},@{@"key":@"own",@"type":@3,@"api":@"com.github.catvod.spider.Own",@"jar":@"../own.jar",@"ext":@"./ext.json"}]};
    NSError *error=nil;NSDictionary *catalog=[TVBoxCatalogStore parseData:[NSJSONSerialization dataWithJSONObject:config options:0 error:NULL] sourceURL:@"https://source.test/sub/config.json" error:&error];
    Check(catalog&&!error);
    NSDictionary *first=catalog[@"sites"][0],*second=catalog[@"sites"][1];
    Check([first[@"api"] isEqual:@"csp_Test"]&&[first[@"apiKind"] isEqual:@"jar-bridge"]);
    NSMutableDictionary *source=[@{@"protocol":@"jar-bridge",@"api":first[@"api"],@"options":first[@"ext"]} mutableCopy];MediaJARAttachSource(source,first,catalog);
    Check([source[@"jar"][@"url"] isEqual:@"https://source.test/sub/global.jar"]&&MediaJARUsesRuntime(source));
    MediaJARAttachSource(source,second,catalog);source[@"options"]=second[@"ext"];
    Check([source[@"jar"][@"url"] isEqual:@"https://source.test/own.jar"]);
    Check([MediaJARExtension(source) isEqual:@"https://source.test/sub/ext.json"]);
    Check([MediaJARParameters(@"search",@{@"keyword":@"中文😀+&",@"page":@2})[@"wd"] isEqual:@"中文😀+&"]);
    Check([MediaJARParameters(@"play",@{@"id":@"opaque+id%26signed",@"lineId":@"line"})[@"play"] isEqual:@"opaque+id%26signed"]);
    Check(!MediaJARParameters(@"unsupported",@{}));
    NSLog(@"JAR source and parameter tests passed");return 0;
}}
