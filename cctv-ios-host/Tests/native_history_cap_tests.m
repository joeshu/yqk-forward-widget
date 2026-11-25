#import "HostBackup.h"
#import "HostLibraryStore.h"
#import "ProfileStore.h"
#import "ServiceStore.h"
#import <Foundation/Foundation.h>

// 定向测试：备份恢复路径对 recents / watchHistory 的数量上限与 Store cap 一致性。
// 验证点：
//   1. validatedBackup 不对 recents/watchHistory 数量做硬拒绝（与 catalogs/epgReminders 的
//      reject 式上限不同，用户历史数据按 Store 上限在恢复时裁剪）。
//   2. restore 后 Store 实际持有条数被裁剪到 HostLibraryRecentsLimit / HostMediaWatchHistoryLimit。
//   3. 再次 snapshot 不会导出超限条目（自愈）。

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
        NSDictionary *base = @{
            @"format" : @"CCTVHost",
            @"version" : @1,
            @"subscriptions" : @[ @"https://example.com/live.m3u" ],
            @"favorites" : @[ @"cctv1" ],
            @"preferences" : @{}
        };

        // 30 条互异 id 的 recents，超过 24 条上限。
        NSMutableArray *oversizedRecents = [NSMutableArray array];
        for (NSUInteger i = 0; i < 30; i++) {
            [oversizedRecents addObject:@{ @"id" : [NSString stringWithFormat:@"recent-%lu", (unsigned long)i],
                                           @"title" : [NSString stringWithFormat:@"频道 %lu", (unsigned long)i],
                                           @"watchedAt" : @(1000.0 + (double)i) }];
        }
        // 150 条互异 key 的 watchHistory，超过 100 条上限。
        NSMutableArray *oversizedHistory = [NSMutableArray array];
        for (NSUInteger i = 0; i < 150; i++) {
            [oversizedHistory addObject:@{ @"key" : [NSString stringWithFormat:@"watch-%lu", (unsigned long)i],
                                           @"updatedAt" : @(2000.0 + (double)i),
                                           @"position" : @(double)i }];
        }

        NSMutableDictionary *oversized = [base mutableCopy];
        oversized[@"recents"] = oversizedRecents;
        oversized[@"watchHistory"] = oversizedHistory;

        // validatedBackup 应接受（不因数量超限而整包拒绝）。
        NSDictionary *validated = [HostBackup validatedBackup:encode(oversized) error:NULL];
        check(validated != nil, @"oversized recents/watchHistory backup is accepted (truncation, not rejection)");
        check([validated[@"recents"] count] == 30, @"validation preserves original oversized recents count");

        [HostBackup restore:validated];
        [HostLibraryStore.shared flush];

        check([HostLibraryStore.shared recents].count == HostLibraryRecentsLimit,
              @"restore trims recents to HostLibraryRecentsLimit (24)");
        check([HostLibraryStore.shared mediaWatchHistory].count == HostMediaWatchHistoryLimit,
              @"restore trims watchHistory to HostMediaWatchHistoryLimit (100)");

        // 再次快照不应导出超限条目，确认上限在恢复后自愈且可往返。
        NSDictionary *snap = [HostBackup snapshot];
        check([snap[@"recents"] count] <= HostLibraryRecentsLimit, @"re-exported recents respect Store cap");
        check([snap[@"watchHistory"] count] <= HostMediaWatchHistoryLimit, @"re-exported watchHistory respect Store cap");

        NSLog(@"History cap consistency checks passed");
    }
    return 0;
}
