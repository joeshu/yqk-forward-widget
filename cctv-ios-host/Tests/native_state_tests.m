#import "HostBackup.h"
#import "ServiceStore.h"
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
        [ServiceStore remove:@"builtin-ysp"];
        BOOL builtin = NO;
        for (NSDictionary *s in [ServiceStore services])
            if ([s[@"id"] isEqual:@"builtin-ysp"])
                builtin = YES;
        check(builtin, @"bundled service preserved");
        NSLog(@"Native backup and service persistence checks passed");
    }
    return 0;
}
