#import "MediaSourceHealthStore.h"
#import <float.h>
#import <math.h>

static NSString * const MediaSourceHealthDefaultsKey = @"cctv.mediaSourceHealth.v1";
static NSUInteger const MediaSourceHealthLimit = 128;
static NSTimeInterval const MediaSourceHealthExpiry = 7 * 24 * 60 * 60;

@implementation MediaSourceHealthStore
+ (instancetype)shared { static MediaSourceHealthStore *store; static dispatch_once_t once; dispatch_once(&once, ^{ store=[MediaSourceHealthStore new]; }); return store; }
- (NSMutableDictionary *)records { id value=[NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSourceHealthDefaultsKey];return [value isKindOfClass:NSDictionary.class]?[value mutableCopy]:[NSMutableDictionary dictionary]; }
- (BOOL)isDeprioritizedSourceID:(NSString *)sourceID {
    if(!sourceID.length)return NO;@synchronized(self){NSDictionary *record=[self records][sourceID];if(![record isKindOfClass:NSDictionary.class])return NO;NSTimeInterval now=NSDate.date.timeIntervalSince1970,updated=[record[@"updated"] doubleValue];if(now-updated>MediaSourceHealthExpiry)return NO;return [record[@"cooldownUntil"] doubleValue]>now;}
}
- (void)recordSourceID:(NSString *)sourceID success:(BOOL)success elapsed:(NSTimeInterval)elapsed {
    if(!sourceID.length)return;@synchronized(self){NSMutableDictionary *records=[self records];NSTimeInterval now=NSDate.date.timeIntervalSince1970;for(NSString *key in records.allKeys.copy)if(now-[records[key][@"updated"] doubleValue]>MediaSourceHealthExpiry)[records removeObjectForKey:key];NSMutableDictionary *record=[records[sourceID] isKindOfClass:NSDictionary.class]?[records[sourceID] mutableCopy]:[NSMutableDictionary dictionary];
        if(success){double old=[record[@"latency"] doubleValue],sample=MAX(0,MIN(600,elapsed));record[@"failures"]=@0;record[@"cooldownUntil"]=@0;record[@"latency"]=old>0?@(old*0.7+sample*0.3):@(sample);record[@"lastSuccess"]=@(now);}
        else{NSUInteger failures=MIN(10,[record[@"failures"] unsignedIntegerValue]+1);NSTimeInterval delay=MIN(600,30*pow(2,MIN(5,failures-1)));record[@"failures"]=@(failures);record[@"cooldownUntil"]=@(now+delay);record[@"lastFailure"]=@(now);}
        record[@"updated"]=@(now);records[sourceID]=record;while(records.count>MediaSourceHealthLimit){NSString *oldest=nil;double oldestTime=DBL_MAX;for(NSString *key in records){NSDictionary *candidate=records[key];double updated=[candidate[@"updated"] doubleValue];if(updated<oldestTime){oldestTime=updated;oldest=key;}}if(!oldest)break;[records removeObjectForKey:oldest];}[NSUserDefaults.standardUserDefaults setObject:records forKey:MediaSourceHealthDefaultsKey];
    }
}
@end
