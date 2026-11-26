#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const LocalMediaStoreDidChangeNotification;

/// Serializes local media copies and only publishes complete files.
@interface LocalMediaStore : NSObject
+ (instancetype)shared;
/// 展示名：去掉导入时加的 UUID- 前缀（与 LocalMediaViewController 同款规则）。
+ (NSString *)displayNameForFileURL:(NSURL *)url;
- (NSArray<NSURL *> *)filesSnapshot;
- (NSDictionary<NSString *, id> *)stateSnapshot;
- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *imported, NSArray<NSDictionary<NSString *, NSString *> *> *failures))completion;
- (void)stopAfterCurrentFile;
- (void)deleteFileAtURL:(NSURL *)url completion:(void (^)(BOOL removed, NSError * _Nullable error))completion;
/// 零拷贝外部文件挂载（Security-Scoped Bookmark），避免大体积 4K MKV 重复复制到沙盒。
- (void)mountExternalURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *mounted, NSArray<NSDictionary<NSString *, NSString *> *> *failures))completion;
- (NSArray<NSURL *> *)mountedBookmarkURLsSnapshot;
/// 移除一条外部挂载（只删书签，原文件不受影响）；不在书签里返回 NO。
- (void)removeBookmarkForURL:(NSURL *)url completion:(void (^)(BOOL removed))completion;
/// 是否本机沙盒内的副本（挂载的外部文件返回 NO）。
- (BOOL)isCopiedFileURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END
