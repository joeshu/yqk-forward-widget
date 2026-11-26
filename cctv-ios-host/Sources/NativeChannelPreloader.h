#import <Foundation/Foundation.h>

// Holds at most one SDK-owned metadata preparation; never starts video playback.
@interface NativeChannelPreloader : NSObject
@property(nonatomic,copy) void (^onLog)(NSString *message);
// 预热记账（T22/S6，只读快照，供诊断与测试读取，不参与准入门禁）：
// prepared=成功发起的 SDK 元数据准备次数；hit=交割成功次数；
// waste=已发起准备被丢弃且未交割的次数（取消/过期/失败/被取代）。
@property(nonatomic,readonly) NSUInteger preparedCount;
@property(nonatomic,readonly) NSUInteger hitCount;
@property(nonatomic,readonly) NSUInteger wasteCount;
- (instancetype)initWithFactory:(id (^)(void))factory clock:(NSTimeInterval (^)(void))clock;
- (void)prepareChannel:(NSString *)channel title:(NSString *)title;
- (id)takeChannel:(NSString *)channel;
- (void)cancel;
@end
