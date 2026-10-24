#import <Foundation/Foundation.h>
@interface ProfileStore : NSObject
+ (BOOL)isSource:(id)source;
+ (BOOL)isHTTP:(id)source;
+ (NSDictionary *)metadata:(NSString *)source;
+ (void)update:(NSString *)source values:(NSDictionary *)values;
+ (void)remove:(NSString *)source;
+ (NSArray<NSString *> *)orderedSources:(NSArray<NSString *> *)sources;
+ (void)move:(NSString *)source offset:(NSInteger)offset sources:(NSArray<NSString *> *)sources;
+ (NSString *)epgSourceForChannel:(NSDictionary *)channel;
+ (NSString *)epgIDForChannel:(NSDictionary *)channel;
@end
