#import <Foundation/Foundation.h>
@interface XMLTVStore : NSObject
+ (instancetype)shared;
+ (NSDictionary<NSString *,NSArray<NSDictionary *> *> *)parseData:(NSData *)data error:(NSError **)error;
- (void)setPaused:(BOOL)paused;
- (NSArray<NSDictionary *> *)cachedRowsForSource:(NSString *)source channel:(NSString *)identifier;
- (void)loadSource:(NSString *)source channel:(NSString *)identifier force:(BOOL)force completion:(void (^)(NSArray<NSDictionary *> *,NSError *))completion;
- (void)clear;
@end
