#import <Foundation/Foundation.h>
@interface ServiceStore : NSObject
+ (NSArray<NSDictionary *> *)services;
+ (NSDictionary *)resolvedService:(NSDictionary *)service;
+ (NSString *)directory;
+ (NSString *)scriptPath:(NSDictionary *)service;
+ (NSString *)codePath:(NSDictionary *)service;
+ (BOOL)isMediaService:(NSDictionary *)service;
+ (void)save:(NSDictionary *)service;
/// Caller must first confirm that this service is stopped. Retains code for rollback and all user data.
+ (NSDictionary *)replaceImportedService:(NSDictionary *)existing withService:(NSDictionary *)incoming error:(NSError **)error;
+ (NSDictionary *)rollbackImportedService:(NSDictionary *)service error:(NSError **)error;
+ (void)remove:(NSString *)identifier;
+ (NSString *)activeIdentifier;
+ (NSString *)dataDirectoryForService:(NSDictionary *)service error:(NSError **)error;
@end
