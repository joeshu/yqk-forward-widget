#import "NativeTimeshiftSession.h"
#import <math.h>
#import <string.h>
@protocol CCTVNativeTimeshift <NSObject>
- (void)seekToStartTime:(NSTimeInterval)start endTime:(NSTimeInterval)end completionHandler:(void (^)(BOOL))completion;
- (void)backToLive;
@end
@interface NativeTimeshiftSession ()
@property(nonatomic,weak) id<CCTVNativeTimeshift> player;
@property(nonatomic) NSUInteger generation;
@end
@implementation NativeTimeshiftSession
- (instancetype)initWithPlayer:(id)player {if(self=[super init])_player=player;return self;}
- (BOOL)seekStart:(NSTimeInterval)start end:(NSTimeInterval)end now:(NSTimeInterval)now completion:(void (^)(BOOL,NSError *))completion {
    return [self seekStart:start end:end now:now error:NULL completion:completion];
}
- (BOOL)seekStart:(NSTimeInterval)start end:(NSTimeInterval)end now:(NSTimeInterval)now error:(NSError **)error completion:(void (^)(BOOL,NSError *))completion {
    if(!isfinite(start)||!isfinite(end)||!isfinite(now)||start<=0||start>=now||end<0||(end!=0&&(end<=start||end>now))){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostTimeshift" code:CCTVHostTimeshiftErrorInvalidRange userInfo:@{NSLocalizedDescriptionKey:@"回看时间范围无效：开始时间须大于 0 且早于当前时间，结束时间须晚于开始时间且不晚于当前时间"}];
        return NO;
    }
    SEL sel=@selector(seekToStartTime:endTime:completionHandler:);
    NSMethodSignature *signature=[(NSObject *)self.player methodSignatureForSelector:sel];
    if(!signature || signature.numberOfArguments!=5 || signature.methodReturnType[0]!='v' || [signature getArgumentTypeAtIndex:2][0]!='d' || [signature getArgumentTypeAtIndex:3][0]!='d' || strcmp([signature getArgumentTypeAtIndex:4],"@?")!=0){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostTimeshift" code:CCTVHostTimeshiftErrorUnsupportedPlayer userInfo:@{NSLocalizedDescriptionKey:@"当前播放器不支持时移定位接口"}];
        return NO;
    }
    NSUInteger generation=++self.generation;__weak typeof(self) weakSelf=self;__block BOOL delivered=NO;
    @try {
        [self.player seekToStartTime:start endTime:end completionHandler:^(BOOL allowed){
            dispatch_async(dispatch_get_main_queue(),^{
                NativeTimeshiftSession *owner=weakSelf;
                if(!owner || generation!=owner.generation || delivered)return;
                delivered=YES;completion(allowed,nil);
            });
        }];
        // SDK 回调可能永不触发：10 秒后以超时失败交付，避免调用方永久挂起。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(10*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            NativeTimeshiftSession *owner=weakSelf;
            if(!owner || generation!=owner.generation || delivered)return;
            delivered=YES;completion(NO,[NSError errorWithDomain:@"CCTVHostTimeshift" code:CCTVHostTimeshiftErrorTimeout userInfo:@{NSLocalizedDescriptionKey:@"回看定位超时，未收到播放器回调"}]);
        });
        return YES;
    } @catch(NSException *exception){return NO;}
}
- (BOOL)backToLive {
    [self cancel];
    NSMethodSignature *signature=[(NSObject *)self.player methodSignatureForSelector:@selector(backToLive)];
    if(!signature || signature.numberOfArguments!=2 || signature.methodReturnType[0]!='v')return NO;
    @try{[self.player backToLive];return YES;}@catch(NSException *exception){return NO;}
}
- (void)cancel {self.generation++;}
@end
