#import <UIKit/UIKit.h>

@interface PlaybackInfoViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> * (^rowsProvider)(void);
@property(nonatomic, copy) NSArray<NSDictionary *> * (^sectionsProvider)(void);
@property(nonatomic, copy) NSDictionary * (^summaryProvider)(void);
@property(nonatomic, copy) NSArray<NSDictionary *> *snapshotRows;
@property(nonatomic, assign) NSTimeInterval autoRefreshInterval;
@end
