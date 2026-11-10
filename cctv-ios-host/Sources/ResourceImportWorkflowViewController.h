#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface ResourceImportWorkflowViewController : UITableViewController
@property(nonatomic,copy) void (^onSaveCandidate)(NSDictionary *candidate,BOOL updateExisting,void (^completion)(NSError * _Nullable error));
@property(nonatomic,copy) dispatch_block_t onStateChanged;
@property(nonatomic,copy,nullable) dispatch_block_t onOpenServices;
@property(nonatomic,copy) NSArray<NSDictionary *> *(^existingImportTargetsProvider)(void);
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,readonly,copy,nullable) NSString *taskSummary;
- (void)refreshExistingResourceMatches;
- (void)reloadThemeAppearance;
- (void)saveAndActivateSelected;
- (void)promptRenameCandidateAtIndex:(NSUInteger)index;
- (void)expandSubScriptsForCandidateAtIndex:(NSUInteger)index;
@end
NS_ASSUME_NONNULL_END
