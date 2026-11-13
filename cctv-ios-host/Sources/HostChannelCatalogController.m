#import "HostChannelCatalogController.h"
#import "HostTheme.h"
@interface HostCatalogSurface : UIView
@end
@implementation HostCatalogSurface
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {UIView *hit=[super hitTest:point withEvent:event];return hit==self?nil:hit;}
@end
@interface HostChannelCatalogController ()
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UICollectionView *grid;
@end
@implementation HostChannelCatalogController
- (instancetype)initWithTable:(UITableView *)table grid:(UICollectionView *)grid {if((self=[super initWithNibName:nil bundle:nil])){_table=table;_grid=grid;}return self;}
- (void)loadView {self.view=[HostCatalogSurface new];self.view.backgroundColor=UIColor.clearColor;[self.view addSubview:self.table];[self.view addSubview:self.grid];}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.table.backgroundColor=HostBackground();self.table.separatorColor=HostSeparator();self.grid.backgroundColor=HostBackground();}
@end
