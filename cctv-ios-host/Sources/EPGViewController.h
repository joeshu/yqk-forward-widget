#import <UIKit/UIKit.h>

@interface EPGViewController : UIViewController
@property(nonatomic,copy) void (^onReplay)(NSDictionary *program);
@property(nonatomic,copy) BOOL (^canReplay)(NSDictionary *program);
- (instancetype)initWithChannel:(NSDictionary *)channel officialID:(NSString *)officialID;
- (instancetype)initWithChannelID:(NSString *)channelID name:(NSString *)name;
@end
