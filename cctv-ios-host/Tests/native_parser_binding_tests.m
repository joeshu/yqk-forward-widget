#import <Foundation/Foundation.h>
#import "ServiceStore.h"

static void check(BOOL ok, NSString *message) {
    if(!ok){NSLog(@"FAILED: %@",message);exit(1);}
}
static NSDictionary *savedSource(NSString *identifier) {
    for(NSDictionary *source in [ServiceStore services])if([source[@"id"] isEqual:identifier])return source;
    return @{};
}
int main(void){@autoreleasepool {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"pythonServices"];
    [defaults setObject:@"unrelated-latest-catalog" forKey:@"selectedMediaCatalogID"];
    check(![ServiceStore playbackParserCatalogIDForSource:@{@"id":@"standalone"}].length,@"standalone sources do not borrow the latest collection");
    NSDictionary *source=@{@"id":@"parser-binding-fixture",@"name":@"Fixture",@"port":@19842,@"catalogID":@"content-owner",@"tvboxCatalogID":@"legacy-owner",@"parserCatalogID":@"resolver-owner",@"protocol":@"python-spider",@"capabilities":@[@"home",@"detail",@"play"]};
    check([[ServiceStore playbackParserCatalogIDForSource:source] isEqual:@"resolver-owner"],@"explicit parser binding takes precedence");
    check([source[@"catalogID"] isEqual:@"content-owner"],@"parser selection preserves content collection identity");
    [ServiceStore save:source];
    NSDictionary *saved=savedSource(source[@"id"]);
    check([saved[@"parserCatalogID"] isEqual:@"resolver-owner"]&&[saved[@"catalogID"] isEqual:@"content-owner"],@"binding survives service save and reload independently of content ownership");
    NSMutableDictionary *inherited=[saved mutableCopy];[inherited removeObjectForKey:@"parserCatalogID"];
    [ServiceStore save:inherited];
    check([[ServiceStore playbackParserCatalogIDForSource:savedSource(source[@"id"])] isEqual:@"content-owner"],@"removing override restores source inheritance");
    check([[ServiceStore playbackParserCatalogIDForSource:@{@"tvboxCatalogID":@"legacy-owner"}] isEqual:@"legacy-owner"],@"legacy imported scripts inherit their own collection");
    NSMutableDictionary *invalid=[saved mutableCopy];invalid[@"parserCatalogID"]=@[@"not-an-id"];
    [ServiceStore save:invalid];
    check(!savedSource(source[@"id"])[@"parserCatalogID"],@"malformed binding is not persisted");
    check([ServiceStore isSupportedPlaybackParser:@{@"type":@0,@"url":@"https://parser.test/?url={url}"}],@"type 0 can run in the background resolver");
    check([ServiceStore isSupportedPlaybackParser:@{@"type":@"json",@"url":@"https://parser.test/api?url=%s"}],@"declared JSON parser is supported");
    check(![ServiceStore isSupportedPlaybackParser:@{@"type":@3,@"url":@"https://parser.test/aggregate"}],@"unsupported aggregate types cannot be selected");
    check(![ServiceStore isSupportedPlaybackParser:@{@"type":@0,@"url":@"javascript:run()"}],@"non-HTTP parser endpoints cannot be selected");
    check(![ServiceStore isSupportedPlaybackParser:@{@"type":@1,@"url":@"https://user:secret@parser.test/"}],@"inline credentials do not become parser choices");
    puts("PASS: per-source parser binding, persistence, inheritance and supported parser types");
}}
