#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const LocalMediaStoreDidChangeNotification;

/// Serializes local media copies and only publishes complete files.
@interface LocalMediaStore : NSObject
+ (instancetype)shared;
- (NSArray<NSURL *> *)filesSnapshot;
- (NSDictionary<NSString *, id> *)stateSnapshot;
- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *imported, NSArray<NSDictionary<NSString *, NSString *> *> *failures))completion;
- (void)stopAfterCurrentFile;
- (void)deleteFileAtURL:(NSURL *)url completion:(void (^)(BOOL removed, NSError * _Nullable error))completion;
/// 零拷贝外部文件挂载（Security-Scoped Bookmark），避免大体积 4K MKV 重复复制到沙盒。
- (void)mountExternalURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<NSURL *> *mounted, NSArray<NSDictionary<NSString *, NSString *> *> *failures))completion;
- (NSArray<NSURL *> *)mountedBookmarkURLsSnapshot;
@end

NS_ASSUME_NONNULL_END
