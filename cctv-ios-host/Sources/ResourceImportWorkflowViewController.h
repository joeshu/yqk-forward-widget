#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface ResourceImportWorkflowViewController : UITableViewController
@property(nonatomic,copy) void (^onSaveCandidate)(NSDictionary *candidate,BOOL updateExisting,void (^completion)(NSError * _Nullable error));
@property(nonatomic,copy) dispatch_block_t onAdvanced;
@property(nonatomic,copy) dispatch_block_t onStateChanged;
@property(nonatomic,copy) NSArray<NSDictionary *> *(^existingImportTargetsProvider)(void);
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,readonly,copy) NSString *taskSummary;
- (void)refreshExistingResourceMatches;
@end
NS_ASSUME_NONNULL_END
