#import <Foundation/Foundation.h>

// Shared by the search UI and Foundation regression tests. IDs are scoped to
// providers; delimiters inside an ID must not create an identity collision.
static inline NSString *MediaSearchText(id value) {
    return [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSNumber.class] ? [value stringValue] : @"");
}
static inline NSString *MediaSearchIdentity(NSString *provider, id identifier) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:@[provider?:@"",MediaSearchText(identifier)] options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:@"";
}
static inline NSArray *MediaSearchEntries(NSArray *entries, NSString *provider) {
    if(!provider)return entries?:@[];
    return [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry,NSDictionary *bindings){return [MediaSearchText(entry[@"provider"]) isEqual:provider];}]];
}
static inline NSUInteger MediaSearchAppend(NSMutableArray *stored, NSArray *items, NSString *provider, NSString *name, NSUInteger remaining) {
    NSMutableSet *identities=[NSMutableSet set];
    for(NSDictionary *entry in stored)[identities addObject:MediaSearchIdentity(MediaSearchText(entry[@"provider"]),entry[@"item"][@"id"]?:entry[@"item"][@"name"])];
    NSUInteger added=0;
    for(id candidate in items){
        if(added>=remaining)break;
        if(![candidate isKindOfClass:NSDictionary.class]||!MediaSearchText(candidate[@"name"]).length)continue;
        NSString *identity=MediaSearchIdentity(provider,candidate[@"id"]?:candidate[@"name"]);
        if([identities containsObject:identity])continue;
        [identities addObject:identity];[stored addObject:@{@"item":candidate,@"provider":provider?:@"",@"providerName":name?:@""}];added++;
    }
    return added;
}
