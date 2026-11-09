#import <Foundation/Foundation.h>

@interface MediaPackageImporter : NSObject
// Performs bounded ZIP extraction and static metadata inspection. Never runs code.
// Call off the main thread; the returned service is persisted by the caller.
+ (nullable NSDictionary *)importFile:(NSURL *)file error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)importFile:(NSURL *)file companionFiles:(NSDictionary<NSString *, NSData *> *)files error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)importFile:(NSURL *)file companionFiles:(NSDictionary<NSString *, NSData *> *)files runtimeHint:(nullable NSString *)runtimeHint error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)inspectDirectory:(NSString *)directory error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)inspectDirectory:(NSString *)directory runtimeHint:(nullable NSString *)runtimeHint error:(NSError * _Nullable * _Nullable)error;
/// Re-detects Node packages imported by versions that defaulted every JS ZIP to JavaScriptCore.
+ (void)migrateLegacyRuntimeMetadata;
@end
