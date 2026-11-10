#import <Foundation/Foundation.h>

// LYTVS publishes tk_<id> in both subscription names and API query values.
// Older clients saved only <id> from .hawk paths, producing a different account.
static NSString *MediaLytvsSubscriptionToken(NSString *raw) {
    if(![raw isKindOfClass:NSString.class])return nil;
    NSString *value=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!value.length||value.length>512||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return nil;
    if([value.lowercaseString hasPrefix:@"tk_"])return value.length>3?[@"tk_" stringByAppendingString:[value substringFromIndex:3]]:nil;
    if([value rangeOfString:@"^[A-Za-z0-9]{6,64}$" options:NSRegularExpressionSearch].location!=NSNotFound)return [@"tk_" stringByAppendingString:value];
    return value;
}
