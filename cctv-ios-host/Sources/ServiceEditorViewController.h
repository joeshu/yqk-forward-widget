#import <UIKit/UIKit.h>
@interface ServiceEditorViewController : UITableViewController
@property(nonatomic, copy) NSDictionary *service;
@property(nonatomic, copy) dispatch_block_t onSave;
@property(nonatomic, copy) void (^onApplyService)(NSDictionary *previousService,
                                                  NSDictionary *updatedService,
                                                  void (^completion)(NSError * _Nullable error));
@end
@interface ServiceCodeViewController : UIViewController
@property(nonatomic, copy) NSString *path;
@property(nonatomic, assign) BOOL readOnly;
@end
