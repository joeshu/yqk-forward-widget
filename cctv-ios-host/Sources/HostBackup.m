#import "HostBackup.h"
@implementation HostBackup
+ (NSArray<NSString *> *)preferenceKeys {
    return @[
        @"resumeLastChannel", @"rememberLastChannel", @"autoLoadEPG", @"allowBackgroundAudio", @"autoPiP",
        @"channelGridMode", @"nativeChannelsEnabled"
    ];
}
+ (NSDictionary *)snapshot {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    for (NSString *k in [self preferenceKeys])
        if ([d objectForKey:k])
            p[k] = @([d boolForKey:k]);
    return @{
        @"format" : @"CCTVHost",
        @"version" : @1,
        @"subscriptions" : [d arrayForKey:@"subscriptions"] ?: @[],
        @"favorites" : [d arrayForKey:@"favorites"] ?: @[],
        @"preferences" : p
    };
}
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error {
    id json = data.length > 0 && data.length <= 1024 * 1024
                  ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]
                  : nil;
    BOOL valid = [json isKindOfClass:NSDictionary.class];
    NSDictionary *j = valid ? json : @{};
    valid = valid && [j[@"format"] isEqual:@"CCTVHost"] && [j[@"version"] isEqual:@1] &&
            [j[@"subscriptions"] isKindOfClass:NSArray.class] &&
            [j[@"favorites"] isKindOfClass:NSArray.class] &&
            [j[@"preferences"] isKindOfClass:NSDictionary.class];
    if (valid) {
        NSArray *urls = j[@"subscriptions"], *favorites = j[@"favorites"];
        valid = urls.count <= 500 && favorites.count <= 10000;
        for (id value in [urls arrayByAddingObjectsFromArray:favorites])
            if (![value isKindOfClass:NSString.class] || [value length] > 8192)
                valid = NO;
        if (valid)
            for (NSString *u in urls) {
                NSURLComponents *c = [NSURLComponents componentsWithString:u];
                if (!c.URL || !c.host.length ||
                    ![@[ @"https", @"http" ] containsObject:c.scheme.lowercaseString])
                    valid = NO;
            }
        for (NSString *key in j[@"preferences"])
            if (![[self preferenceKeys] containsObject:key] ||
                ![j[@"preferences"][key] isKindOfClass:NSNumber.class])
                valid = NO;
    }
    if (!valid) {
        if (error)
            *error = [NSError
                errorWithDomain:@"CCTVHostBackup"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"文件不是有效的 CCTVHost 配置备份，或数据超过限制。"
                       }];
        return nil;
    }
    return j;
}
+ (void)restore:(NSDictionary *)backup {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setObject:backup[@"subscriptions"] forKey:@"subscriptions"];
    [d setObject:backup[@"favorites"] forKey:@"favorites"];
    [d removeObjectForKey:@"disabledSubscriptions"];
    for (NSString *k in [self preferenceKeys]) {
        [d removeObjectForKey:k];
        if (backup[@"preferences"][k])
            [d setObject:backup[@"preferences"][k] forKey:k];
    }
}
@end
