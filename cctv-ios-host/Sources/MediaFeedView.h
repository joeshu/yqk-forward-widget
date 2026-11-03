#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One vertical media surface. Sections use kind=hero/posters/grid/status/skeleton,
/// an id, optional title/actionTitle/categoryID, and an array of original media items.
@interface MediaFeedView : UICollectionView
@property(nonatomic,copy,nullable) NSArray<NSDictionary *> *(^sectionsProvider)(void);
@property(nonatomic,copy,nullable) void (^onSelectItem)(NSDictionary *item, NSDictionary *section);
@property(nonatomic,copy,nullable) void (^onSelectSection)(NSDictionary *section);
@property(nonatomic,copy,nullable) void (^onScroll)(UIScrollView *scrollView);
@property(nonatomic,copy,nullable) void (^onNearEnd)(void);
@property(nonatomic,copy,nullable) void (^onVisibleCategories)(NSArray<NSString *> *categoryIDs);
@property(nonatomic,copy,readonly) NSArray<NSDictionary *> *sections;
@end

NS_ASSUME_NONNULL_END
