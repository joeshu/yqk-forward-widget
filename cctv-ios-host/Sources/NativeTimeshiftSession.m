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
    if(!isfinite(start)||!isfinite(end)||!isfinite(now)||start<=0||start>=now||end<0||(end!=0&&(end<=start||end>now)))return NO;
    SEL sel=@selector(seekToStartTime:endTime:completionHandler:);
    NSMethodSignature *signature=[(NSObject *)self.player methodSignatureForSelector:sel];
    if(!signature || signature.numberOfArguments!=5 || signature.methodReturnType[0]!='v' || [signature getArgumentTypeAtIndex:2][0]!='d' || [signature getArgumentTypeAtIndex:3][0]!='d' || strcmp([signature getArgumentTypeAtIndex:4],"@?")!=0)return NO;
    NSUInteger generation=++self.generation;__weak typeof(self) weakSelf=self;__block BOOL delivered=NO;
    @try {
        [self.player seekToStartTime:start endTime:end completionHandler:^(BOOL allowed){
            dispatch_async(dispatch_get_main_queue(),^{
                NativeTimeshiftSession *owner=weakSelf;
                if(!owner || generation!=owner.generation || delivered)return;
                delivered=YES;completion(allowed,nil);
            });
        }];
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
