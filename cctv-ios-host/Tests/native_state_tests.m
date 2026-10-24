#import "HostBackup.h"
#import "ServiceStore.h"
#import "HostLogBuffer.h"
#import <dispatch/dispatch.h>
#import <Foundation/Foundation.h>
static void check(BOOL ok, NSString *message) {
    if (!ok) {
        NSLog(@"FAILED: %@", message);
        exit(1);
    }
}
static NSData *encode(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}
int main(void) {
    @autoreleasepool {
        HostLogBuffer *logs=[[HostLogBuffer alloc] initWithMaximumCharacters:64];
        check([logs append:@"first"], @"first log schedules a notification");
        check(![logs append:@"second"], @"pending log delivery is coalesced");
        check([[logs drain] isEqual:@"firstsecond"], @"drain preserves unsaturated log order");
        check([logs append:[[@"😀" stringByPaddingToLength:100000 withString:@"😀" startingAtIndex:0] stringByAppendingString:@"x"]], @"new batch schedules again");
        NSString *tail=[logs drain];check(tail.length<=64 && [tail dataUsingEncoding:NSUTF8StringEncoding]!=nil,@"oversized unicode log is bounded without splitting surrogate pairs");
        __block NSUInteger notifications=0;
        dispatch_apply(2000,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t index){@autoreleasepool {
            if([logs append:[NSString stringWithFormat:@"线程 %zu 😀\\n",index]]){@synchronized(logs){notifications++;}}
        }});
        check(notifications==1 && logs.length<=64,@"concurrent log flood has one pending notification and bounded memory");
        tail=[logs drain];check([tail dataUsingEncoding:NSUTF8StringEncoding]!=nil,@"concurrent log tail remains valid UTF-8");
        [logs append:@"old"];[logs clear];check([[logs drain] isEqual:@""],@"clear drops pending output");
        check([logs append:@"new"],@"clear permits a fresh notification");
        NSDictionary *valid = @{
            @"format" : @"CCTVHost",
            @"version" : @1,
            @"subscriptions" : @[ @"https://example.com/live.m3u" ],
            @"favorites" : @[ @"cctv1" ],
            @"preferences" : @{@"autoLoadEPG" : @NO}
        };
        check([HostBackup validatedBackup:encode(valid) error:NULL] != nil, @"valid backup accepted");
        for (id data in @[
                 [NSData data], encode(@[]), encode(@{@"format" : @"CCTVHost"}),
                 [@"{bad json" dataUsingEncoding:NSUTF8StringEncoding]
             ])
            check([HostBackup validatedBackup:data error:NULL] == nil, @"malformed backup rejected");
        check([HostBackup validatedBackup:nil error:NULL] == nil, @"missing file rejected without exception");
        NSMutableDictionary *bad = [valid mutableCopy];
        bad[@"subscriptions"] = @[ @42 ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"non-string URL rejected");
        bad[@"subscriptions"] = @[ @"file:///etc/hosts" ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"local file URL rejected");
        bad[@"subscriptions"] = @[ @"https://" ];
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"hostless URL rejected");
        bad = [valid mutableCopy];
        bad[@"preferences"] = @{@"activePythonService" : @YES};
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"unrecognized preference rejected");
        bad[@"preferences"] = @{@"autoLoadEPG" : @"yes"};
        check(![HostBackup validatedBackup:encode(bad) error:NULL], @"wrong preference type rejected");
        [HostBackup restore:valid];
        check([[NSUserDefaults.standardUserDefaults arrayForKey:@"favorites"] isEqual:valid[@"favorites"]],
              @"favorites restored");
        check(![NSUserDefaults.standardUserDefaults boolForKey:@"autoLoadEPG"], @"false preference restored");
        check([HostBackup validatedBackup:encode([HostBackup snapshot]) error:NULL] != nil,
              @"export round-trip");
        NSString *sid = NSUUID.UUID.UUIDString;
        NSDictionary *service = @{@"id" : sid, @"name" : @"Test service", @"port" : @18768};
        [ServiceStore save:service];
        NSUInteger matches = 0;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:sid])
                matches++;
        check(matches == 1, @"service persisted once");
        [ServiceStore save:@{@"id" : sid, @"name" : @"Updated", @"port" : @18769}];
        matches = 0;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:sid]) {
                matches++;
                check([s[@"name"] isEqual:@"Updated"], @"service edit persisted");
            }
        check(matches == 1, @"edit replaces existing service");
        [ServiceStore remove:sid];
        for (NSDictionary *s in [ServiceStore services])
            check(![s[@"id"] isEqual:sid], @"service removed");
        NSString *portableID=NSUUID.UUID.UUIDString;
        NSString *portableBase=[[ServiceStore directory] stringByAppendingPathComponent:portableID];
        NSString *package=[portableBase stringByAppendingPathComponent:@"package/中文目录"];
        [NSFileManager.defaultManager createDirectoryAtPath:package withIntermediateDirectories:YES attributes:nil error:NULL];
        [@"class Spider: pass" writeToFile:[package stringByAppendingPathComponent:@"看剧 AI.py"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *legacy=@{@"id":portableID,@"name":@"看剧AI",@"port":@18781,@"engine":@"python",@"protocol":@"python-spider",@"packageRoot":[NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Services/%@/package/中文目录",portableID],@"archivePath":[NSString stringWithFormat:@"/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Services/%@/source.zip",portableID],@"manifest":@{@"runtime":@"python",@"moduleType":@"esm",@"entry":@"看剧 AI.py",@"options":@{@"fixture":@YES}}};
        NSMutableArray *seed=[[NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"] mutableCopy];if(!seed)seed=[NSMutableArray array];[seed addObject:legacy];[NSUserDefaults.standardUserDefaults setObject:seed forKey:@"pythonServices"];
        NSDictionary *portable=nil;for(NSDictionary *row in [ServiceStore services])if([row[@"id"] isEqual:portableID])portable=row;
        check([portable[@"packageRoot"] isEqual:package],@"sandbox UUID changes rebase only the same service's package");
        check([NSFileManager.defaultManager fileExistsAtPath:[ServiceStore codePath:legacy]],@"stale in-memory snapshots also resolve the Chinese entry filename");
        check([portable[@"packageRelativePath"] isEqual:@"package/中文目录"]&&[portable[@"archiveRelativePath"] isEqual:@"source.zip"],@"portable relative paths are persisted for future container moves");
        check([portable[@"manifest"][@"options"] isEqual:legacy[@"manifest"][@"options"]]&&[portable[@"manifest"][@"moduleType"] isEqual:@"script"],@"migration preserves options and corrects the Python display type");
        NSMutableDictionary *invalid=[legacy mutableCopy];invalid[@"packageRoot"]=@"/unrelated/package";invalid[@"packageRelativePath"]=@"../another-service/package";
        check([[ServiceStore resolvedService:invalid][@"packageRoot"] isEqual:@"/unrelated/package"],@"relative traversal is never rebased into another service");
        [ServiceStore remove:portableID];
        [ServiceStore remove:@"builtin-ysp"];
        BOOL builtin = NO;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:@"builtin-ysp"])
                builtin = YES;
        check(builtin, @"bundled service preserved");
        [ServiceStore remove:@"builtin-yangshipin-js"];
        NSDictionary *javascript=nil;
        for(NSDictionary *s in [ServiceStore services])if([s[@"id"] isEqual:@"builtin-yangshipin-js"])javascript=s;
        check(javascript && [javascript[@"engine"] isEqual:@"javascript"], @"JS service preserved with explicit engine");
        check([javascript[@"port"] integerValue]==18770, @"JS service has separate subscription port");
        NSString *jsData=[ServiceStore dataDirectoryForService:javascript error:NULL];
        check([jsData.lastPathComponent isEqual:@"builtin-yangshipin-js"], @"JS data does not share legacy YSP directory");
        NSString *migrationID = NSUUID.UUID.UUIDString;
        NSString *prior = [[ServiceStore directory] stringByAppendingPathComponent:@"builtin-ysp"];
        NSString *historical =
            [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                    .firstObject stringByAppendingPathComponent:@"ysp"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:prior withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:historical withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *existing = [migrationID stringByAppendingString:@"-existing"],
                 *missing = [migrationID stringByAppendingString:@"-missing"];
        [@"keep-old-identity" writeToFile:[historical stringByAppendingPathComponent:existing]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:NULL];
        [@"do-not-overwrite" writeToFile:[prior stringByAppendingPathComponent:existing]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:NULL];
        [@"recover-new-state" writeToFile:[prior stringByAppendingPathComponent:missing]
                               atomically:YES
                                 encoding:NSUTF8StringEncoding
                                    error:NULL];
        NSString *dataDir = [ServiceStore dataDirectoryForService:@{
            @"id" : @"builtin-ysp",
            @"builtin" : @YES
        }
                                                            error:NULL];
        check([dataDir isEqualToString:historical], @"built-in service returns to historical data directory");
        check([[NSString stringWithContentsOfFile:[dataDir stringByAppendingPathComponent:existing]
                                         encoding:NSUTF8StringEncoding
                                            error:NULL] isEqualToString:@"keep-old-identity"],
              @"migration never overwrites old device identity");
        check([[NSString stringWithContentsOfFile:[dataDir stringByAppendingPathComponent:missing]
                                         encoding:NSUTF8StringEncoding
                                            error:NULL] isEqualToString:@"recover-new-state"],
              @"missing state recovered from v0.16 directory");
        for (NSString *folder in @[ prior, historical ])
            for (NSString *name in @[ existing, missing ])
                [fm removeItemAtPath:[folder stringByAppendingPathComponent:name] error:NULL];
        NSLog(@"Native backup and service persistence checks passed");
    }
    return 0;
}
