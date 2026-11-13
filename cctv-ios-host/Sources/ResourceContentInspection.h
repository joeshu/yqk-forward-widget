#import <Foundation/Foundation.h>

/// Static inspection only. Neither scripts nor HTML are executed.
FOUNDATION_EXPORT NSString *ResourceContentText(NSData *data);
FOUNDATION_EXPORT BOOL ResourceContentIsHTML(NSData *data);
FOUNDATION_EXPORT NSString *ResourceContentExtension(NSData *data, NSString *suggestedFilename);
FOUNDATION_EXPORT NSArray<NSDictionary *> *ResourceContentPageLinks(NSData *data, NSURL *origin);

/// Static classification evidence only; never implies connectivity or decoding.
@interface ResourceDetectionResult : NSObject
@property(nonatomic,copy,readonly) NSString *kind;
@property(nonatomic,copy,readonly) NSArray<NSString *> *evidence;
+ (instancetype)inspectData:(NSData *)data filename:(NSString *)filename;
@end
