#import <Foundation/Foundation.h>

// A thread-safe bounded tail, shared by UI and diagnostic producers/consumers.
@interface HostLogBuffer : NSObject
- (instancetype)initWithMaximumCharacters:(NSUInteger)maximum;
- (BOOL)append:(NSString *)text; // YES only when a new consumer notification is needed.
- (NSString *)drain;
- (void)clear;
@property(nonatomic, readonly) NSUInteger length;
@end
