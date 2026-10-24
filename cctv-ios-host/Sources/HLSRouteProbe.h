#import <Foundation/Foundation.h>
// Classification only; a readable manifest does not prove video decoding.
@interface HLSRouteProbe : NSObject
- (void)startURL:(NSURL *)url completion:(void (^)(BOOL plainMediaPlaylist))completion;
- (void)cancel;
@end
