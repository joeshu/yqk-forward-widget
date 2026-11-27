#import <UIKit/UIKit.h>
@interface ServiceEditorViewController : UITableViewController
@property(nonatomic, copy) NSDictionary *service;
@property(nonatomic, copy) dispatch_block_t onSave;
@property(nonatomic, copy) void (^onApplyService)(NSDictionary *previousService,
                                                  NSDictionary *updatedService,
                                                  void (^completion)(NSError * _Nullable error));
- (void)reloadThemeAppearance;
@end
@interface ServiceCodeViewController : UIViewController
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy, nullable) NSString *bundledResourcePath;
@property(nonatomic, assign) BOOL readOnly;
@property(nonatomic, copy, nullable) BOOL (^onWillSaveCode)(NSString *code, NSError * _Nullable * _Nullable error);
@property(nonatomic, copy, nullable) dispatch_block_t onSaveCode;
@property(nonatomic, copy, nullable) dispatch_block_t onCloseCode;
- (void)reloadThemeAppearance;
@end
