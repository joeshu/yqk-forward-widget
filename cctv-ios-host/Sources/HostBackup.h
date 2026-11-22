#import <Foundation/Foundation.h>
@interface HostBackup : NSObject
+ (NSArray<NSString *> *)preferenceKeys;
+ (NSArray<NSString *> *)numberPreferenceKeys;
+ (NSArray<NSString *> *)stringPreferenceKeys;
+ (NSDictionary *)snapshot;
+ (NSDictionary *)validatedBackup:(NSData *)data error:(NSError **)error;
+ (void)restore:(NSDictionary *)backup;
+ (BOOL)restore:(NSDictionary *)backup error:(NSError **)error;
@end
