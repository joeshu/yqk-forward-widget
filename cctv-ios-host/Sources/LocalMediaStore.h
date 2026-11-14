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
@end

NS_ASSUME_NONNULL_END
