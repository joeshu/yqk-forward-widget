#import <Foundation/Foundation.h>
@interface ServiceStore : NSObject
+ (NSArray<NSDictionary *> *)services;
+ (NSDictionary *)resolvedService:(NSDictionary *)service;
+ (NSString *)directory;
+ (NSString *)scriptPath:(NSDictionary *)service;
+ (NSString *)codePath:(NSDictionary *)service;
+ (BOOL)isMediaService:(NSDictionary *)service;
+ (void)save:(NSDictionary *)service;
+ (void)remove:(NSString *)identifier;
+ (NSString *)activeIdentifier;
+ (NSString *)dataDirectoryForService:(NSDictionary *)service error:(NSError **)error;
@end
