#import <UIKit/UIKit.h>

@interface EPGViewController : UIViewController
@property(nonatomic,copy) void (^onReplay)(NSDictionary *program);
@property(nonatomic,copy) BOOL (^canReplay)(NSDictionary *program);
@property(nonatomic,copy) void (^onReturnToLive)(void);
@property(nonatomic,assign) NSTimeInterval activeReplayStart;
@property(nonatomic,assign) NSInteger catchupDays;
- (instancetype)initWithChannel:(NSDictionary *)channel officialID:(NSString *)officialID;
- (instancetype)initWithChannelID:(NSString *)channelID name:(NSString *)name;
@end
