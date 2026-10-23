#import <Foundation/Foundation.h>
@interface HostBackup : NSObject
+ (NSArray<NSString *> *)preferenceKeys;
+ (NSDictionary *)snapshot;
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error;
+ (void)restore:(NSDictionary *)backup;
@end
