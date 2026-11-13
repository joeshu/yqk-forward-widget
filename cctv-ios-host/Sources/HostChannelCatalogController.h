#import <UIKit/UIKit.h>
@interface HostChannelCatalogController : UIViewController
- (instancetype)initWithTable:(UITableView *)table grid:(UICollectionView *)grid;
- (void)reloadThemeAppearance;
@end
