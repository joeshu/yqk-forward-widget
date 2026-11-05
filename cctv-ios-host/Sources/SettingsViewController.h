#import <UIKit/UIKit.h>
@interface SettingsViewController : UIViewController
@property(nonatomic,copy) void (^onPreferenceChanged)(NSString *key, BOOL value);
@property(nonatomic,copy) void (^onIntegerPreferenceChanged)(NSString *key, NSInteger value);
@property(nonatomic,copy) void (^onOpenTab)(NSInteger tab);
@property(nonatomic,copy) dispatch_block_t onOpenServices;
@property(nonatomic,copy) dispatch_block_t onClearEPG;
@property(nonatomic,copy) dispatch_block_t onClearWatchHistory;
@property(nonatomic,copy) dispatch_block_t onClearFavorites;
@property(nonatomic,copy) dispatch_block_t onOpenLog;
@property(nonatomic,copy) dispatch_block_t onExportData;
@property(nonatomic,copy) dispatch_block_t onImportData;
@property(nonatomic,copy) dispatch_block_t onOpenDiagnostics;
@end
