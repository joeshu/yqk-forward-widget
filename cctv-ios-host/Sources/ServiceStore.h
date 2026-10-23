#import <Foundation/Foundation.h>
@interface ServiceStore : NSObject
+ (NSArray<NSDictionary *> *)services;
+ (NSString *)directory;
+ (NSString *)scriptPath:(NSDictionary *)service;
+ (void)save:(NSDictionary *)service;
+ (void)remove:(NSString *)identifier;
+ (NSString *)activeIdentifier;
@end
