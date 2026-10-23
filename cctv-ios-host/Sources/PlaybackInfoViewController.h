#import <UIKit/UIKit.h>
@interface PlaybackInfoViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> * (^rowsProvider)(void);
@end
