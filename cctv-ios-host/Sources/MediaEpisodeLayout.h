#import <Foundation/Foundation.h>

static const NSUInteger CCTVEpisodesPerGroup = 30;

typedef NS_ENUM(NSInteger, CCTVEpisodeLayoutStyle) {
    CCTVEpisodeLayoutStyleGrid4 = 0, // 四列网格（默认紧凑）
    CCTVEpisodeLayoutStyleList = 1,  // 单列列表（完整分集名与状态）
    CCTVEpisodeLayoutStyleCard2 = 2, // 双列卡片（双行宽幅）
    CCTVEpisodeLayoutStyleGrid3 = 3, // 三列网格（均衡大字）
};

static NSString * const CCTVEpisodeLayoutStyleDefaultsKey = @"cctv.mediaEpisodeLayoutStyle.v1";
static NSString * const CCTVEpisodeShowRemarksBadgeDefaultsKey = @"cctv.mediaEpisodeShowBadge.v1";
static NSString * const CCTVEpisodeAutoExpandListDefaultsKey = @"cctv.mediaEpisodeAutoExpand.v1";
static NSString * const CCTVMediaEpisodeLayoutStyleDidChangeNotification = @"CCTVMediaEpisodeLayoutStyleDidChangeNotification";

static inline CCTVEpisodeLayoutStyle CCTVEpisodeCurrentLayoutStyle(void) {
    NSInteger raw = [[NSUserDefaults standardUserDefaults] integerForKey:CCTVEpisodeLayoutStyleDefaultsKey];
    if (raw < 0 || raw > 3) return CCTVEpisodeLayoutStyleGrid4;
    return (CCTVEpisodeLayoutStyle)raw;
}

static inline void CCTVEpisodeSetLayoutStyle(CCTVEpisodeLayoutStyle style) {
    NSInteger clamped = (style < 0 || style > 3) ? 0 : (NSInteger)style;
    [[NSUserDefaults standardUserDefaults] setInteger:clamped forKey:CCTVEpisodeLayoutStyleDefaultsKey];
    if (NSThread.isMainThread) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:@(clamped)];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:@(clamped)];
        });
    }
}

static inline BOOL CCTVEpisodeShowRemarksBadgeEnabled(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:CCTVEpisodeShowRemarksBadgeDefaultsKey];
    return obj ? [obj boolValue] : YES;
}

static inline void CCTVEpisodeSetShowRemarksBadgeEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:CCTVEpisodeShowRemarksBadgeDefaultsKey];
    if (NSThread.isMainThread) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];
        });
    }
}

static inline BOOL CCTVEpisodeAutoExpandEnabled(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:CCTVEpisodeAutoExpandListDefaultsKey];
    return obj ? [obj boolValue] : NO;
}

static inline void CCTVEpisodeSetAutoExpandEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:CCTVEpisodeAutoExpandListDefaultsKey];
}

static inline NSUInteger CCTVEpisodeColumnsForStyle(CCTVEpisodeLayoutStyle style, BOOL isAccessibilityCategory) {
    switch (style) {
        case CCTVEpisodeLayoutStyleList:
            return 1;
        case CCTVEpisodeLayoutStyleCard2:
            return isAccessibilityCategory ? 1 : 2;
        case CCTVEpisodeLayoutStyleGrid3:
            return isAccessibilityCategory ? 2 : 3;
        case CCTVEpisodeLayoutStyleGrid4:
        default:
            return isAccessibilityCategory ? 3 : 4;
    }
}

static inline NSString *CCTVEpisodeLayoutStyleName(CCTVEpisodeLayoutStyle style) {
    switch (style) {
        case CCTVEpisodeLayoutStyleList: return @"单列列表";
        case CCTVEpisodeLayoutStyleCard2: return @"双列卡片";
        case CCTVEpisodeLayoutStyleGrid3: return @"三列网格";
        case CCTVEpisodeLayoutStyleGrid4: default: return @"四列网格";
    }
}

static inline NSString *CCTVEpisodeLayoutStyleShortName(CCTVEpisodeLayoutStyle style) {
    switch (style) {
        case CCTVEpisodeLayoutStyleList: return @"列表";
        case CCTVEpisodeLayoutStyleCard2: return @"双列";
        case CCTVEpisodeLayoutStyleGrid3: return @"三列";
        case CCTVEpisodeLayoutStyleGrid4: default: return @"网格";
    }
}

static inline NSString *CCTVEpisodeLayoutStyleIconName(CCTVEpisodeLayoutStyle style) {
    switch (style) {
        case CCTVEpisodeLayoutStyleList: return @"list.bullet";
        case CCTVEpisodeLayoutStyleCard2: return @"rectangle.grid.2x2";
        case CCTVEpisodeLayoutStyleGrid3: return @"square.grid.3x2";
        case CCTVEpisodeLayoutStyleGrid4: default: return @"square.grid.2x2";
    }
}

static inline NSString *CCTVEpisodeFormattedDisplayTitle(NSDictionary *episode, NSUInteger sourceIndex, CCTVEpisodeLayoutStyle style, BOOL selected, BOOL resumeMatch, BOOL showBadge) {
    NSString *name = [episode[@"name"] isKindOfClass:NSString.class] && [episode[@"name"] length]
        ? episode[@"name"]
        : [NSString stringWithFormat:@"第 %lu 集", (unsigned long)sourceIndex + 1];
    if (style == CCTVEpisodeLayoutStyleGrid4 || style == CCTVEpisodeLayoutStyleGrid3) {
        return name;
    }
    NSString *numPrefix = [NSString stringWithFormat:@"%02lu · ", (unsigned long)sourceIndex + 1];
    NSString *base = [name hasPrefix:@"第"] ? [numPrefix stringByAppendingString:name] : [NSString stringWithFormat:@"%@%@", numPrefix, name];
    if (!showBadge) return base;
    NSString *remark = [episode[@"remark"] isKindOfClass:NSString.class] ? episode[@"remark"] : ([episode[@"remarks"] isKindOfClass:NSString.class] ? episode[@"remarks"] : @"");
    NSMutableString *full = [base mutableCopy];
    if (remark.length && ![full containsString:remark]) {
        [full appendFormat:@" · %@", remark];
    }
    if (style == CCTVEpisodeLayoutStyleList) {
        if (selected) [full appendString:@"   ● 当前选集"];
        else if (resumeMatch) [full appendString:@"   ↺ 上次观看"];
    } else if (style == CCTVEpisodeLayoutStyleCard2) {
        if (selected) [full appendString:@" · ●"];
        else if (resumeMatch) [full appendString:@" · ↺"];
    }
    return full.copy;
}

static inline NSUInteger CCTVEpisodeDisplayIndex(NSUInteger sourceIndex, NSUInteger count, BOOL reversed) {
    if (count == 0 || sourceIndex >= count) return NSNotFound;
    return reversed ? count - sourceIndex - 1 : sourceIndex;
}

static inline NSUInteger CCTVEpisodeSourceIndex(NSUInteger displayIndex, NSUInteger count, BOOL reversed) {
    if (count == 0 || displayIndex >= count) return NSNotFound;
    return reversed ? count - displayIndex - 1 : displayIndex;
}

static inline NSInteger CCTVEpisodeGroupForSourceIndex(NSUInteger sourceIndex, NSUInteger count, BOOL reversed) {
    NSUInteger displayIndex = CCTVEpisodeDisplayIndex(sourceIndex, count, reversed);
    // 非法下标返回 NSNotFound 而不是静默映射为第 0 组，由调用点显式决定回退。
    return displayIndex == NSNotFound ? NSNotFound : (NSInteger)(displayIndex / CCTVEpisodesPerGroup);
}
