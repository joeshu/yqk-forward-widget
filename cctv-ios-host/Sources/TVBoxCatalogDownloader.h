#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogDownloader : NSObject
- (void)loadURL:(NSURL *)url completion:(void (^)(NSDictionary * _Nullable catalog,NSError * _Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
