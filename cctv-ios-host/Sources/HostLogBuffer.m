#import "HostLogBuffer.h"

@implementation HostLogBuffer {
    NSMutableString *_text;
    NSUInteger _maximum;
    BOOL _notified;
}
- (instancetype)initWithMaximumCharacters:(NSUInteger)maximum {
    if((self=[super init])){_maximum=MAX((NSUInteger)2,maximum);_text=[NSMutableString string];}
    return self;
}
- (BOOL)append:(NSString *)text {
    if(!text.length)return NO;
    @synchronized(self) {
        // Trim the incoming value before appending, so a single oversized log
        // cannot transiently expand the buffer without bound.
        NSUInteger start=text.length>_maximum?text.length-_maximum:0;
        if(start && [text characterAtIndex:start]>=0xdc00 && [text characterAtIndex:start]<=0xdfff)start++;
        [_text appendString:start?[text substringFromIndex:start]:text];
        if(_text.length>_maximum){NSUInteger remove=_text.length-_maximum;unichar next=[_text characterAtIndex:remove];if(next>=0xdc00 && next<=0xdfff)remove++;[_text deleteCharactersInRange:NSMakeRange(0,remove)];}
        BOOL notify=!_notified;_notified=YES;return notify;
    }
}
- (NSString *)drain {@synchronized(self){NSString *result=_text.copy;[_text setString:@""];_notified=NO;return result;}}
- (void)clear {@synchronized(self){[_text setString:@""];_notified=NO;}}
- (NSUInteger)length {@synchronized(self){return _text.length;}}
@end
