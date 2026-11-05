#import <Foundation/Foundation.h>
// 时移失败错误码：1 超时未收到 SDK 回调；2 时间范围无效；3 播放器不支持时移接口。
typedef NS_ENUM(NSInteger, CCTVHostTimeshiftError) {
    CCTVHostTimeshiftErrorTimeout = 1,
    CCTVHostTimeshiftErrorInvalidRange = 2,
    CCTVHostTimeshiftErrorUnsupportedPlayer = 3,
};
@interface NativeTimeshiftSession : NSObject
- (instancetype)initWithPlayer:(id)player;
- (BOOL)seekStart:(NSTimeInterval)start end:(NSTimeInterval)end now:(NSTimeInterval)now completion:(void (^)(BOOL allowed,NSError *error))completion;
- (BOOL)seekStart:(NSTimeInterval)start end:(NSTimeInterval)end now:(NSTimeInterval)now error:(NSError **)error completion:(void (^)(BOOL allowed,NSError *error))completion;
- (BOOL)backToLive;
- (void)cancel;
@end
