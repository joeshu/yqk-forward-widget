#import <UIKit/UIKit.h>

@interface EPGViewController : UIViewController
- (instancetype)initWithChannel:(NSDictionary *)channel officialID:(NSString *)officialID;
- (instancetype)initWithChannelID:(NSString *)channelID name:(NSString *)name;
@end
