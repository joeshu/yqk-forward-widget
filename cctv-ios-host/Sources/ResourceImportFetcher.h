#import <Foundation/Foundation.h>
@interface ResourceImportFetcher : NSObject
@property(nonatomic,copy) void (^completion)(NSData *,NSURLResponse *,NSError *);
@property(nonatomic,copy) NSData *(^fallbackDataProvider)(NSURL *);
/// One fetch per instance. Completion is on main; cancellation suppresses delivery.
- (void)load:(NSURL *)url;
- (void)cancel;
@end
