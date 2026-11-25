#import "MediaBrowserQueryBuilder.h"

@implementation MediaBrowserQueryBuilder

+ (NSUInteger)choiceCountForScope:(NSString *)key choices:(NSArray<NSDictionary *> *)choices {
    NSUInteger count = 0;
    for (NSDictionary *choice in choices) {
        // 非字典条目（外部可设的公开 choices 属性可能含 NSNull/异类）直接跳过，
        // 与历史内联谓词行为一致：[choice[@"scope"] isEqual:key]。
        if (![choice isKindOfClass:NSDictionary.class]) continue;
        if ([choice[@"scope"] isEqual:key]) count++;
    }
    return count;
}

+ (NSArray<NSDictionary *> *)filteredChoices:(NSArray<NSDictionary *> *)choices
                                        query:(NSString *)query
                                        scope:(NSString *)scope {
    NSString *normalizedQuery = query ?: @"";
    NSString *activeScope = scope ?: @"*";
    BOOL scopeAll = [activeScope isEqual:@"*"];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray arrayWithCapacity:choices.count];
    for (NSDictionary *choice in choices) {
        if (![choice isKindOfClass:NSDictionary.class]) continue;
        NSString *choiceScope = [choice[@"scope"] isKindOfClass:NSString.class] ? choice[@"scope"] : @"";
        if (!scopeAll && ![choiceScope isEqual:activeScope]) continue;
        // 空 query 一律命中；否则在 name/subtitle/url 上做大小写/重音不敏感匹配。
        BOOL matches = ![normalizedQuery length];
        for (NSString *field in @[@"name", @"subtitle", @"url"]) {
            NSString *value = [choice[field] isKindOfClass:NSString.class] ? choice[field] : @"";
            if (normalizedQuery.length &&
                [value rangeOfString:normalizedQuery
                             options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
                matches = YES;
                break;
            }
        }
        if (matches) [results addObject:choice];
    }
    return results.copy;
}

+ (NSString *)emptyMessageForQuery:(NSString *)query {
    return query.length ? @"没有匹配的选项，请修改或清除搜索词"
                        : @"当前分组暂无选项，请切换到全部";
}

@end
