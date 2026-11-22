#import <Foundation/Foundation.h>

// Preserve request headers for the same origin and standard HTTP-to-HTTPS
// upgrades. An unrelated destination only receives generic transport headers.
static inline NSDictionary<NSString *, NSString *> *HostRedirectHeaders(NSDictionary<NSString *, NSString *> *headers, NSURL *source, NSURL *destination) {
    NSString *sourceScheme=source.scheme.lowercaseString;
    NSString *destinationScheme=destination.scheme.lowercaseString;
    NSInteger sourcePort=source.port?source.port.integerValue:([sourceScheme isEqual:@"https"]?443:80);
    NSInteger destinationPort=destination.port?destination.port.integerValue:([destinationScheme isEqual:@"https"]?443:80);
    BOOL sameHost=source.host.length && [source.host.lowercaseString isEqual:destination.host.lowercaseString];
    BOOL sameOrigin=sameHost && (([sourceScheme isEqual:destinationScheme] && sourcePort==destinationPort) ||
                                ([sourceScheme isEqual:@"http"] && [destinationScheme isEqual:@"https"] && sourcePort==80 && destinationPort==443));
    if(sameOrigin)return headers.copy ?: @{};
    NSSet *allowed=[NSSet setWithArray:@[@"accept",@"accept-encoding",@"accept-language",@"cache-control",@"if-range",@"range",@"user-agent"]];
    NSMutableDictionary *filtered=[NSMutableDictionary dictionary];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        if([name isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] && [allowed containsObject:name.lowercaseString])filtered[name]=value;
    }];
    return filtered.copy;
}
