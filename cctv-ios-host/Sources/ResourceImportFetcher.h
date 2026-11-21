#import <Foundation/Foundation.h>

static inline NSString *ResourceImportUserAgent(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 CCTVHost/1.0";
}

@interface ResourceImportFetcher : NSObject
@property(nonatomic,copy) void (^completion)(NSData *,NSURLResponse *,NSError *);
@property(nonatomic,copy) NSData *(^fallbackDataProvider)(NSURL *);
/// One fetch per instance. Completion is on main; cancellation suppresses delivery.
- (void)load:(NSURL *)url;
- (void)cancel;
@end
