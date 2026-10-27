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

NSDictionary<NSString *,id> *MediaPlaybackDiagnosticHeaderFields(NSDictionary *headers) {
    NSDictionary *safeHeaders = [headers isKindOfClass:NSDictionary.class] ? headers : @{};
    BOOL userAgent = NO, referer = NO, origin = NO, authMaterial = NO;
    NSUInteger count = 0;
    for (id rawName in safeHeaders) {
        if (![rawName isKindOfClass:NSString.class] || ![safeHeaders[rawName] isKindOfClass:NSString.class]) continue;
        count++;
        NSString *name = [rawName lowercaseString];
        if ([name isEqual:@"user-agent"]) userAgent = YES;
        else if ([name isEqual:@"referer"] || [name isEqual:@"referrer"]) referer = YES;
        else if ([name isEqual:@"origin"]) origin = YES;
        else if ([name isEqual:@"cookie"] || [name isEqual:@"authorization"]) authMaterial = YES;
    }
    return @{@"request_header_count":@(count), @"request_user_agent_present":@(userAgent), @"request_referrer_present":@(referer), @"request_origin_present":@(origin), @"request_auth_material_present":@(authMaterial)};
}

static NSString *MediaPlaybackString(id value) {
    return [value isKindOfClass:NSString.class] ? [(NSString *)value lowercaseString] : @"";
}

BOOL MediaPlaybackResultSupportsAVPlayer(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return NO;
    if([result[@"nativePlayable"] respondsToSelector:@selector(boolValue)]&&[result[@"nativePlayable"] boolValue])return YES;
    NSString *format=MediaPlaybackString(result[@"format"]?:result[@"mediaType"]?:result[@"playbackType"]);
    NSString *mime=MediaPlaybackString(result[@"contentType"]?:result[@"content_type"]?:result[@"mimeType"]?:result[@"mime"]);
    NSRange semicolon=[mime rangeOfString:@";"];if(semicolon.location!=NSNotFound)mime=[mime substringToIndex:semicolon.location];
    NSSet *formats=[NSSet setWithArray:@[@"hls",@"m3u8",@"m3u",@"mpegurl",@"application/vnd.apple.mpegurl",@"application/x-mpegurl",@"audio/mpegurl",@"mp4",@"m4v",@"mov",@"quicktime",@"mp3",@"m4a",@"aac",@"mpeg-ts",@"mpegts",@"ts"]];
    NSSet *mimes=[NSSet setWithArray:@[@"application/vnd.apple.mpegurl",@"application/x-mpegurl",@"audio/mpegurl",@"video/mp4",@"application/mp4",@"video/quicktime",@"audio/mp4",@"audio/mpeg",@"audio/aac",@"video/mp2t"]];
    if([formats containsObject:format]||[mimes containsObject:mime])return YES;
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:result[@"url"];
    NSURLComponents *components=[NSURLComponents componentsWithString:[raw isKindOfClass:NSString.class]?raw:@""];
    NSString *extension=components.path.pathExtension.lowercaseString?:@"";
    return [@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3",@"aac",@"ts"] containsObject:extension];
}

BOOL MediaPlaybackResultIsDirectMedia(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return NO;
    if([result[@"directMedia"] respondsToSelector:@selector(boolValue)]&&[result[@"directMedia"] boolValue])return YES;
    if(MediaPlaybackResultSupportsAVPlayer(result))return YES;
    NSString *format=MediaPlaybackString(result[@"format"]?:result[@"mediaType"]?:result[@"playbackType"]);
    NSString *mime=MediaPlaybackString(result[@"contentType"]?:result[@"content_type"]?:result[@"mimeType"]?:result[@"mime"]);
    if([mime hasPrefix:@"video/"]||[mime hasPrefix:@"audio/"])return YES;
    if([@[@"mpd",@"dash",@"flv",@"mkv",@"avi",@"webm",@"wmv",@"rmvb"] containsObject:format])return YES;
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:result[@"url"];
    NSURLComponents *components=[NSURLComponents componentsWithString:[raw isKindOfClass:NSString.class]?raw:@""];
    return [@[@"mpd",@"flv",@"mkv",@"avi",@"webm",@"wmv",@"rmvb"] containsObject:components.path.pathExtension.lowercaseString?:@""];
}
