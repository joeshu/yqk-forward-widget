#import "ProfileStore.h"
@implementation ProfileStore
+ (BOOL)isHTTP:(id)source {
    if(![source isKindOfClass:NSString.class]||[source length]>8192)return NO;
    @try{NSURLComponents *c=[NSURLComponents componentsWithString:source];return c.URL&&c.host.length&&[@[@"http",@"https"] containsObject:c.scheme.lowercaseString];}@catch(NSException *e){return NO;}
}
+ (BOOL)isSource:(id)source {
    if([self isHTTP:source])return YES;
    return [source isKindOfClass:NSString.class]&&[source hasPrefix:@"local-playlist:"]&&[[NSUUID alloc] initWithUUIDString:[source substringFromIndex:15]]!=nil;
}
+ (NSDictionary *)metadata:(NSString *)source {return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"][source]?:@{};}
+ (void)update:(NSString *)source values:(NSDictionary *)values {
    if(![self isSource:source])return;
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];
    NSMutableDictionary *p=[[self metadata:source] mutableCopy];[p addEntriesFromDictionary:values];all[source]=p;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
}
+ (void)remove:(NSString *)source {
    NSMutableDictionary *all=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"profileMetadata"]?:@{} mutableCopy];[all removeObjectForKey:source];[NSUserDefaults.standardUserDefaults setObject:all forKey:@"profileMetadata"];
    for(NSString *key in @[@"profileOrder",@"disabledSubscriptions"]){NSMutableArray *a=[[NSUserDefaults.standardUserDefaults arrayForKey:key]?:@[] mutableCopy];[a removeObject:source];[NSUserDefaults.standardUserDefaults setObject:a forKey:key];}
}
+ (NSArray<NSString *> *)orderedSources:(NSArray<NSString *> *)sources {
    NSArray *order=[NSUserDefaults.standardUserDefaults arrayForKey:@"profileOrder"]?:@[];
    return [sources sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){NSUInteger x=[order indexOfObject:a],y=[order indexOfObject:b];if(x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;return [a compare:b];}];
}
+ (void)move:(NSString *)source offset:(NSInteger)offset sources:(NSArray<NSString *> *)sources {
    NSMutableArray *a=[[self orderedSources:sources] mutableCopy];NSUInteger i=[a indexOfObject:source];if(i==NSNotFound)return;NSInteger j=(NSInteger)i+offset;if(j<0||j>=a.count)return;[a exchangeObjectAtIndex:i withObjectAtIndex:j];[NSUserDefaults.standardUserDefaults setObject:a forKey:@"profileOrder"];
}
+ (NSString *)epgSourceForChannel:(NSDictionary *)channel {
    for(NSString *s in [self orderedSources:channel[@"subscriptionSources"]?:@[]]){NSDictionary *p=[self metadata:s];NSString *u=p[@"epgURL"];if(!u.length)u=p[@"detectedEPGURL"];if([self isHTTP:u])return u;}
    return nil;
}
+ (NSString *)epgIDForChannel:(NSDictionary *)channel {return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"][channel[@"id"]?:@""]?:channel[@"epgID"]?:channel[@"tvgName"]?:channel[@"name"]?:@"";}
@end
