#import <Foundation/Foundation.h>

// Shared by the search UI and Foundation regression tests. IDs are scoped to
// providers; delimiters inside an ID must not create an identity collision.
static inline NSString *MediaSearchText(id value) {
    return [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSNumber.class] ? [value stringValue] : @"");
}
static inline NSString *MediaSearchIdentity(NSString *provider, id identifier) {
    // provider 非字符串时 dataWithJSONObject 会失败返回 nil，进而退化为 @""，
    // 使不同影片的 identity 坍缩、去重误删；先用 MediaSearchText 归一。
    NSData *data=[NSJSONSerialization dataWithJSONObject:@[MediaSearchText(provider),MediaSearchText(identifier)] options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]?:@"";
}
static inline NSArray *MediaSearchEntries(NSArray *entries, NSString *provider) {
    if(!provider)return entries?:@[];
    return [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id rawEntry,NSDictionary *bindings){if(![rawEntry isKindOfClass:NSDictionary.class])return NO;NSDictionary *entry=rawEntry;return [MediaSearchText(entry[@"provider"]) isEqual:provider];}]];
}
static inline NSUInteger MediaSearchAppend(NSMutableArray *stored, NSArray *items, NSString *provider, NSString *name, NSUInteger remaining) {
    NSMutableSet *identities=[NSMutableSet set];
    for(id rawEntry in stored){if(![rawEntry isKindOfClass:NSDictionary.class])continue;NSDictionary *entry=rawEntry;NSDictionary *item=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};[identities addObject:MediaSearchIdentity(MediaSearchText(entry[@"provider"]),item[@"id"]?:item[@"name"])];}
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

// T05/M05：搜索/列表结果统一契约。Valid = 字典且 items 为数组（可能为空 =
// 真正零条）；Malformed = 非字典，或 items 缺失/非数组（不得计为成功、不得
// 记健康成功、不得展示为"无结果"）；Failed = NSError 非空。取消由调用方的
// 代际/任务校验处理，不属于结果分类。
typedef NS_ENUM(NSInteger, MediaSearchResultKind) {
    MediaSearchResultKindValid = 0,
    MediaSearchResultKindMalformed,
    MediaSearchResultKindFailed
};
static inline MediaSearchResultKind MediaSearchClassifyResult(id result, NSError *error) {
    if(error)return MediaSearchResultKindFailed;
    if(![result isKindOfClass:NSDictionary.class])return MediaSearchResultKindMalformed;
    if(![result[@"items"] isKindOfClass:NSArray.class])return MediaSearchResultKindMalformed;
    return MediaSearchResultKindValid;
}
static inline NSString *MediaSearchMalformedMessage(id result) {
    if([result isKindOfClass:NSDictionary.class]){
        for(NSString *key in @[@"error",@"errMsg",@"message",@"msg"]){
            NSString *text=MediaSearchText(result[key]);
            if(text.length)return text;
        }
    }
    return @"来源返回的数据格式不完整";
}
