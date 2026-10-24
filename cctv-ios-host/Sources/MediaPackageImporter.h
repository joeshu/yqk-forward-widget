#import <Foundation/Foundation.h>

@interface MediaPackageImporter : NSObject
// Performs bounded ZIP extraction and static metadata inspection. Never runs code.
// Call off the main thread; the returned service is persisted by the caller.
+ (NSDictionary *)importFile:(NSURL *)file error:(NSError **)error;
+ (NSDictionary *)inspectDirectory:(NSString *)directory error:(NSError **)error;
/// Re-detects Node packages imported by versions that defaulted every JS ZIP to JavaScriptCore.
+ (void)migrateLegacyRuntimeMetadata;
@end
