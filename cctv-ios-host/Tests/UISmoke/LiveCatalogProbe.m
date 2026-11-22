#import <UIKit/UIKit.h>
#import "RootViewController.h"

@interface RootViewController (LiveCatalogSmoke)
- (NSDictionary *)anyCatchupChannelForStation:(NSDictionary *)channel;
- (NSDictionary *)catchupChannelForChannel:(NSDictionary *)channel;
- (NSUInteger)sourceCountForChannel:(NSDictionary *)channel;
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path;
@end

static NSUInteger failures;
static void verify(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"LIVE CATALOG FAILED: %@", message); failures++; }
}

BOOL LiveCatalogRunSmokeChecks(void) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    id previousDisabled=[defaults objectForKey:@"disabledSubscriptions"];
    failures=0;
    @try {
        RootViewController *root=[RootViewController new];
        [root setValue:[NSMutableArray array] forKey:@"favorites"];
        [root setValue:[NSMutableDictionary dictionary] forKey:@"epgCache"];
        [root setValue:@3 forKey:@"gridColumns"];
        NSDictionary *current=@{@"id":@"current", @"name":@"CCTV-1 综合", @"epgID":@"station-a", @"remoteURL":@"https://live.example/a", @"subscriptionSources":@[@"enabled"]};
        NSDictionary *conflict=@{@"id":@"conflict", @"name":@"CCTV-1 综合", @"epgID":@"station-b", @"remoteURL":@"https://live.example/b", @"catchupSource":@"https://live.example/b/{start}", @"subscriptionSources":@[@"enabled"]};
        NSDictionary *disabled=@{@"id":@"disabled", @"name":@"CCTV-1 综合", @"epgID":@"station-a", @"remoteURL":@"https://live.example/c", @"catchupSource":@"https://live.example/c/{start}", @"subscriptionSources":@[@"disabled"]};
        NSDictionary *enabled=@{@"id":@"enabled", @"name":@"CCTV-1 综合", @"epgID":@"station-a", @"remoteURL":@"https://live.example/d", @"catchupSource":@"https://live.example/d/{start}", @"subscriptionSources":@[@"enabled"]};
        [defaults setObject:@[@"disabled"] forKey:@"disabledSubscriptions"];
        [root setValue:@[current,conflict,disabled,enabled] forKey:@"allChannels"];
        verify([[root anyCatchupChannelForStation:current][@"id"] isEqual:@"enabled"], @"skips a disabled first candidate and finds an enabled same-ID source");
        verify([[root catchupChannelForChannel:disabled][@"id"] isEqual:@"enabled"], @"a disabled direct catchup source is never selected");
        [defaults setObject:@[@"disabled",@"enabled"] forKey:@"disabledSubscriptions"];
        verify([root anyCatchupChannelForStation:current]==nil, @"subscription disable takes effect without rebuilding the index");
        [defaults setObject:@[@"disabled"] forKey:@"disabledSubscriptions"];
        [root setValue:@[current,conflict] forKey:@"allChannels"];
        verify([root anyCatchupChannelForStation:current]==nil, @"canonical-name fallback rejects conflicting explicit EPG identities");
        NSDictionary *nameOnly=@{@"id":@"legacy", @"name":@"CCTV-1 综合", @"remoteURL":@"https://live.example/e", @"catchupSource":@"https://live.example/e/{start}", @"subscriptionSources":@[@"enabled"]};
        [root setValue:@[current,nameOnly] forKey:@"allChannels"];
        verify([[root anyCatchupChannelForStation:current][@"id"] isEqual:@"legacy"], @"legacy no-ID sources retain canonical station matching");
        NSDictionary *sameURL=@{@"id":@"copy", @"name":@"CCTV-1 综合", @"epgID":@"station-a", @"remoteURL":@"https://live.example/a", @"subscriptionSources":@[@"other"]};
        [root setValue:@[current,sameURL,disabled,enabled] forKey:@"allChannels"];
        verify([root sourceCountForChannel:current]==2, @"source count counts distinct enabled URLs instead of subscriptions");

        UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
        UICollectionView *grid=[[UICollectionView alloc] initWithFrame:CGRectMake(0,0,330,600) collectionViewLayout:layout];
        [root setValue:@[current] forKey:@"shownChannels"];
        CGSize shortSize=[root collectionView:grid layout:layout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        NSMutableDictionary *renamed=[current mutableCopy];
        renamed[@"name"]=@"这是一个会在频道卡片中换行显示的很长的频道名称";
        renamed[@"group"]=@"这是一个很长的分组名称用于验证字幕高度";
        [root setValue:@[renamed] forKey:@"shownChannels"];
        CGSize longSize=[root collectionView:grid layout:layout sizeForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        verify(longSize.height>shortSize.height, @"same-ID title and subtitle changes invalidate cached card height");
    } @finally {
        if(previousDisabled)[defaults setObject:previousDisabled forKey:@"disabledSubscriptions"];
        else [defaults removeObjectForKey:@"disabledSubscriptions"];
    }
    return failures==0;
}
