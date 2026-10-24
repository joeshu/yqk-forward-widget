#import <UIKit/UIKit.h>
@class MediaAPIClient;
NS_ASSUME_NONNULL_BEGIN
@interface MediaEpisodeSelectionViewController : UITableViewController
@property(nonatomic,copy) NSDictionary *item;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,copy) NSString *provider;
@property(nonatomic,copy) NSDictionary *detail;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,copy) void (^onSelectEpisode)(NSDictionary *result,NSDictionary *context);
@property(nonatomic) NSInteger selectedLineIndex;
@property(nonatomic) NSInteger selectedEpisodeIndex;
@property(nonatomic) BOOL selectionUpdatesPlayer;
@end
NS_ASSUME_NONNULL_END
