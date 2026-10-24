#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const CCTVHostDiagnosticLogDidUpdateNotification;

@interface LogCenterViewController : UIViewController
@property(nonatomic,copy,nullable) NSString *scopeName;
@property(nonatomic,copy,nullable) NSString *(^logSnapshotProvider)(void);
@property(nonatomic,copy,nullable) dispatch_block_t onExportLog;
@property(nonatomic,copy,nullable) dispatch_block_t onClearLog;
@end

NS_ASSUME_NONNULL_END
