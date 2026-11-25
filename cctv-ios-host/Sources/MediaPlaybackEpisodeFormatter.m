#import "MediaPlaybackEpisodeFormatter.h"

NSString *MediaPlaybackEpisodeNumber(NSString *value) {
    if(!value.length)return @"";
    NSArray<NSString *> *patterns=@[@"(?i)s\\d+\\s*e\\s*0*(\\d{1,4})",
                                    @"(?i)(?:第\\s*)?0*(\\d{1,4})\\s*(?:集|话|期)",
                                    @"(?i)(?:episode|ep)\\s*0*(\\d{1,4})",
                                    @"^\\s*0*(\\d{1,4})\\s*$"];
    for(NSString *pattern in patterns){
        NSRegularExpression *expression=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
        NSTextCheckingResult *match=[expression firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];
        if(match.numberOfRanges>1){NSString *digits=[value substringWithRange:[match rangeAtIndex:1]];return [NSString stringWithFormat:@"%ld",(long)digits.integerValue];}
    }
    return @"";
}

BOOL MediaPlaybackEpisodeNamesMatch(NSString *left,NSString *right) {
    if(!left.length||!right.length)return NO;
    if([left localizedCaseInsensitiveCompare:right]==NSOrderedSame)return YES;
    NSString *leftNumber=MediaPlaybackEpisodeNumber(left),*rightNumber=MediaPlaybackEpisodeNumber(right);
    return leftNumber.length&&[leftNumber isEqualToString:rightNumber];
}
