#import <Foundation/Foundation.h>
#import "ProfileStore.h"
#import "ServiceStore.h"
#import "TVBoxCatalogStore.h"
#import "MediaPlaybackStateStore.h"
#define Check(v) do{if(!(v)){NSLog(@"failed: %s",#v);return 1;}}while(0)
int main(void){@autoreleasepool {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    for(NSString *key in @[@"profileMetadata",@"pythonServices",@"tvboxCatalogs",@"cctv.mediaWatchHistory.v1",@"cctv.mediaSkipPoints.v1"])[defaults removeObjectForKey:key];
    NSString *source=@"https://fixture.test/list.m3u";
    [defaults setObject:@{source:@"corrupt record"} forKey:@"profileMetadata"];Check([ProfileStore metadata:source].count==0);
    [ProfileStore update:source values:@{@"recovered":@YES}];Check([[ProfileStore metadata:source][@"recovered"] boolValue]);
    [defaults setObject:@[@"invalid",@{@"id":@42}] forKey:@"pythonServices"];Check([ServiceStore services].count==2);
    [defaults setObject:@[@"invalid",@{@"id":@42}] forKey:@"tvboxCatalogs"];Check([TVBoxCatalogStore catalogs].count==4);
    [ServiceStore save:(id)@"invalid"];[TVBoxCatalogStore saveCatalog:(id)@"invalid"];
    dispatch_apply(40,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){@autoreleasepool{
        NSString *identifier=[NSString stringWithFormat:@"concurrent-%lu",(unsigned long)i];
        [ProfileStore update:source values:@{identifier:@(i)}];
        [ServiceStore save:@{@"id":identifier,@"name":identifier,@"port":@18780,@"engine":@"python",@"protocol":@"cctvhost.media/1",@"manifest":@{@"entry":@"main.py",@"runtime":@"python",@"protocol":@"cctvhost.media/1"}}];
        [TVBoxCatalogStore saveCatalog:@{@"id":identifier,@"name":identifier,@"sites":@[],@"lives":@[],@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
        NSDictionary *context=@{@"source":@{@"id":identifier},@"item":@{@"id":@"title",@"name":@"Test"}};
        [MediaPlaybackStateStore recordContext:context lineIndex:0 episodeIndex:0 position:10 duration:60 completed:NO];
        [MediaPlaybackStateStore setIntroEnd:5 forContext:context];
    }});
    NSMutableSet *ids=[NSMutableSet set],*ports=[NSMutableSet set];
    for(NSDictionary *service in [ServiceStore services])if([service[@"id"] hasPrefix:@"concurrent-"]){[ids addObject:service[@"id"]];[ports addObject:service[@"port"]];}
    Check(ids.count==40&&ports.count==40);
    Check([ProfileStore metadata:source].count==41);Check([MediaPlaybackStateStore watchHistory].count==40);
    for(NSUInteger i=0;i<40;i++){NSString *identifier=[NSString stringWithFormat:@"concurrent-%lu",(unsigned long)i];Check([TVBoxCatalogStore catalogForID:identifier]!=nil);NSDictionary *context=@{@"source":@{@"id":identifier},@"item":@{@"id":@"title"}};Check([MediaPlaybackStateStore introEndForContext:context]==5);}
    NSLog(@"Concurrent stores preserved all resources, ports, metadata and history");return 0;
}}
