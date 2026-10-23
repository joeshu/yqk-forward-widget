#import <Foundation/Foundation.h>

// Holds at most one SDK-owned metadata preparation; never starts video playback.
@interface NativeChannelPreloader : NSObject
@property(nonatomic,copy) void (^onLog)(NSString *message);
- (instancetype)initWithFactory:(id (^)(void))factory clock:(NSTimeInterval (^)(void))clock;
- (void)prepareChannel:(NSString *)channel title:(NSString *)title;
- (id)takeChannel:(NSString *)channel;
- (void)cancel;
@end
