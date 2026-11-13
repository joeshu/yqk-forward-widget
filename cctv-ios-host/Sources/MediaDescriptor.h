#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Normalized immutable input to playback routing. Unknown fields remain unknown.
@interface MediaDescriptor : NSObject
@property(nonatomic,copy,readonly) NSDictionary *result;
@property(nonatomic,strong,readonly,nullable) NSURL *url;
@property(nonatomic,copy,readonly) NSString *transport;
@property(nonatomic,copy,readonly) NSString *container;
@property(nonatomic,copy,readonly) NSDictionary *headers;
@property(nonatomic,copy,readonly) NSString *capabilityStatus;
@property(nonatomic,copy,readonly) NSString *capabilityReason;
- (instancetype)initWithResult:(NSDictionary *)result;
@end
NS_ASSUME_NONNULL_END
