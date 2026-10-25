#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface M3UChannel : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy, nullable) NSString *logo;
@property (nonatomic, copy, nullable) NSString *epgID;
@property (nonatomic, copy, nullable) NSString *tvgName;
@end

@interface M3UParser : NSObject
/// 解析 m3u/m3u8 文本；相对地址按 baseURL 解析
+ (nullable NSString *)epgURL:(NSString *)text baseURL:(nullable NSURL *)baseURL;
+ (nullable NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(nullable NSURL *)baseURL;
+ (nullable NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(nullable NSURL *)baseURL error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
