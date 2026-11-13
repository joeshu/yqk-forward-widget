#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface M3UChannel : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy, nullable) NSString *catchupMode;
@property (nonatomic, copy, nullable) NSString *catchupSource;
@property (nonatomic) double catchupDays;
@property (nonatomic) double tvgShift;
- (nullable NSURL *)catchupURLForStart:(NSDate *)start end:(NSDate *)end;
@property (nonatomic, copy, nullable) NSString *logo;
@property (nonatomic, copy, nullable) NSString *epgID;
@property (nonatomic, copy, nullable) NSString *tvgName;
/// HTTP request headers declared for this playlist entry (never written to diagnostics).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@end

@interface M3UParser : NSObject
+ (BOOL)isHLSManifest:(NSString *)text;
+ (NSDictionary *)reportForText:(NSString *)text baseURL:(nullable NSURL *)baseURL;
/// Parses IPTV M3U, IPTV TXT and strict URL lists; HLS stays a single resource.
+ (nullable NSString *)epgURL:(NSString *)text baseURL:(nullable NSURL *)baseURL;
+ (nullable NSArray<M3UChannel *> *)parse:(nullable NSString *)text baseURL:(nullable NSURL *)baseURL;
+ (nullable NSArray<M3UChannel *> *)parse:(nullable NSString *)text baseURL:(nullable NSURL *)baseURL error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
