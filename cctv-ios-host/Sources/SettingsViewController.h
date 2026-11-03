#import <UIKit/UIKit.h>
@interface SettingsViewController : UIViewController
- (void)setBottomOverlayInset:(CGFloat)inset;
@property(nonatomic,copy) void (^onPreferenceChanged)(NSString *key, BOOL value);
@property(nonatomic,copy) dispatch_block_t onClearEPG;
@property(nonatomic,copy) dispatch_block_t onOpenLog;
@property(nonatomic,copy) dispatch_block_t onExportData;
@property(nonatomic,copy) dispatch_block_t onImportData;
@property(nonatomic,copy) dispatch_block_t onOpenDiagnostics;
@property(nonatomic,copy) dispatch_block_t onMediaDisplaySettings;
@end
