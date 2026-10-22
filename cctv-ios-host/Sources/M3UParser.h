#import <Foundation/Foundation.h>

@interface M3UChannel : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *group;
@property (nonatomic, copy, nullable) NSString *logo;
@end

@interface M3UParser : NSObject
/// 解析 m3u/m3u8 文本；相对地址按 baseURL 解析
+ (NSArray<M3UChannel *> *)parse:(NSString *)text baseURL:(nullable NSURL *)baseURL;
@end
