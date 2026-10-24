#import "MediaPlaybackHeaders.h"

static BOOL MediaPlaybackHeaderNameIsAllowed(NSString *name) {
    if(!name.length||name.length>128)return NO;
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"] invertedSet];
    if([name rangeOfCharacterFromSet:invalid].location!=NSNotFound)return NO;
    return ![@[@"host",@"content-length",@"connection",@"transfer-encoding",@"keep-alive",@"upgrade"] containsObject:name.lowercaseString];
}

static void MediaPlaybackInsertHeader(NSMutableDictionary<NSString *,NSString *> *headers, NSString *name, NSString *value) {
    NSString *key=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *text=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(headers.count>=64||!MediaPlaybackHeaderNameIsAllowed(key)||text.length>8192||[text rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound)return;
    headers[key]=text;
}

static void MediaPlaybackAddHeaderValue(NSMutableDictionary<NSString *,NSString *> *headers, id value) {
    if([value isKindOfClass:NSDictionary.class]){
        NSDictionary *dictionary=value;
        for(id rawName in dictionary){if(![rawName isKindOfClass:NSString.class])continue;id rawValue=dictionary[rawName];if([rawValue isKindOfClass:NSString.class])MediaPlaybackInsertHeader(headers,rawName,rawValue);if(headers.count>=64)break;}
        return;
    }
    if(![value isKindOfClass:NSString.class]||[value length]>65536)return;
    for(NSString *part in [(NSString *)value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n#"]]){
        NSRange separator=[part rangeOfString:@"$"];NSUInteger offset=separator.location;
        if(separator.location==NSNotFound){separator=[part rangeOfString:@":"];offset=separator.location;}
        if(separator.location==NSNotFound||offset==0)continue;
        MediaPlaybackInsertHeader(headers,[part substringToIndex:offset],[part substringFromIndex:offset+1]);
    }
}

NSDictionary<NSString *,NSString *> *MediaPlaybackHeadersFromResult(NSDictionary *result) {
    NSMutableDictionary<NSString *,NSString *> *headers=[NSMutableDictionary dictionary];
    MediaPlaybackAddHeaderValue(headers,result[@"headers"]);
    MediaPlaybackAddHeaderValue(headers,result[@"header"]);
    return headers.copy;
}
