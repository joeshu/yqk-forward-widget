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
    if(!MediaPlaybackHeaderNameIsAllowed(key)||text.length>8192)return;
    // Header fields are case-insensitive. Later sources override earlier ones,
    // including at the field-count limit; never send two Referer/Cookie values.
    for(NSUInteger i=0;i<text.length;i++){
        unichar c=[text characterAtIndex:i];
        if((c<0x20&&c!='\t')||c==0x7f||[NSCharacterSet.newlineCharacterSet characterIsMember:c])return;
    }
    NSString *oldKey=nil;
    for(NSString *existing in headers){if([existing caseInsensitiveCompare:key]==NSOrderedSame){oldKey=existing;break;}}
    if(!oldKey&&headers.count>=64)return;
    if(oldKey)[headers removeObjectForKey:oldKey];
    headers[key]=text;
}

static void MediaPlaybackAddHeaderValue(NSMutableDictionary<NSString *,NSString *> *headers, id value) {
    if([value isKindOfClass:NSDictionary.class]){
        NSDictionary *dictionary=value;
        NSUInteger inspected=0;
        for(id rawName in dictionary){if(inspected++>=256)break;if(![rawName isKindOfClass:NSString.class])continue;id rawValue=dictionary[rawName];if([rawValue isKindOfClass:NSString.class])MediaPlaybackInsertHeader(headers,rawName,rawValue);}
        return;
    }
    if(![value isKindOfClass:NSString.class]||[value length]>65536)return;
    for(NSString *part in [(NSString *)value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n#"]]){
        NSRange separator=[part rangeOfString:@"$"];
        NSRange colon=[part rangeOfString:@":"];
        if(colon.location<separator.location)separator=colon;
        NSUInteger offset=separator.location;
        if(separator.location==NSNotFound||offset==0)continue;
        MediaPlaybackInsertHeader(headers,[part substringToIndex:offset],[part substringFromIndex:offset+1]);
    }
}

NSDictionary<NSString *,NSString *> *MediaPlaybackHeadersFromResult(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return @{};
    NSMutableDictionary<NSString *,NSString *> *headers=[NSMutableDictionary dictionary];
    if([result[@"ext"] isKindOfClass:NSDictionary.class]){
        MediaPlaybackAddHeaderValue(headers,result[@"ext"][@"headers"]);
        MediaPlaybackAddHeaderValue(headers,result[@"ext"][@"header"]);
    }
    MediaPlaybackAddHeaderValue(headers,result[@"headers"]);
    MediaPlaybackAddHeaderValue(headers,result[@"header"]);
    MediaPlaybackAddHeaderValue(headers,result[@"customHeaders"]);
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
    return [value isKindOfClass:NSString.class] ? [[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString] : @"";
}

BOOL MediaPlaybackResultSupportsAVPlayer(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return NO;
    if([result[@"dashRemuxed"] boolValue])return YES;
    NSString *format=MediaPlaybackString(result[@"format"]?:result[@"mediaType"]?:result[@"playbackType"]);
    NSString *mime=MediaPlaybackString(result[@"contentType"]?:result[@"content_type"]?:result[@"mimeType"]?:result[@"mime"]);
    NSRange semicolon=[mime rangeOfString:@";"];if(semicolon.location!=NSNotFound)mime=[[mime substringToIndex:semicolon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *engine=MediaPlaybackString(result[@"playbackEngine"]);
    if([engine isEqual:@"cicada"]||MediaPlaybackResultSupportsCicada(result))return NO;
    if([result[@"nativePlayable"] respondsToSelector:@selector(boolValue)]&&[result[@"nativePlayable"] boolValue])return YES;
    if([result[@"drmKey"] isKindOfClass:NSString.class]&&[(NSString *)result[@"drmKey"] length])return YES;
    NSSet *formats=[NSSet setWithArray:@[@"hls",@"m3u8",@"m3u",@"mpegurl",@"application/vnd.apple.mpegurl",@"application/x-mpegurl",@"audio/mpegurl",@"mp4",@"m4v",@"mov",@"quicktime",@"mp3",@"m4a",@"aac",@"mpeg-ts",@"mpegts",@"ts",@"fmp4",@"cmaf",@"m4s",@"f4v",@"wav",@"flac",@"alac",@"ac3",@"eac3"]];
    NSSet *mimes=[NSSet setWithArray:@[@"application/vnd.apple.mpegurl",@"application/x-mpegurl",@"audio/mpegurl",@"video/mp4",@"application/mp4",@"video/quicktime",@"audio/mp4",@"audio/x-m4a",@"audio/mpeg",@"audio/aac",@"audio/wav",@"audio/flac",@"video/x-m4v",@"video/mp2t"]];
    if([formats containsObject:format]||[mimes containsObject:mime])return YES;
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:result[@"url"];
    NSURLComponents *components=[NSURLComponents componentsWithString:[raw isKindOfClass:NSString.class]?raw:@""];
    NSString *extension=components.path.pathExtension.lowercaseString?:@"";
    if([@[@"m3u8",@"m3u",@"mp4",@"m4v",@"mov",@"m4a",@"mp3",@"aac",@"ts",@"m4s",@"f4v",@"wav",@"flac",@"ac3",@"eac3"] containsObject:extension])return YES;
    if(!extension.length&&[raw isKindOfClass:NSString.class]&&raw.length){
        NSString *lowerRaw=[raw lowercaseString];
        if([lowerRaw containsString:@".m3u8"]||[lowerRaw containsString:@".mp4"]||[lowerRaw containsString:@"/m3u8/"]||[lowerRaw containsString:@"/hls/"]||[lowerRaw containsString:@"/cenc/"]||[lowerRaw containsString:@"format=m3u8"]||[lowerRaw containsString:@"type=m3u8"]||[lowerRaw containsString:@"ctype=m3u8"]||[lowerRaw containsString:@"playtype=m3u8"]||[lowerRaw containsString:@"ext=m3u8"]||[lowerRaw containsString:@"ext=mp4"]||[lowerRaw containsString:@"type=mp4"]||[lowerRaw containsString:@"mime=video"])return YES;
    }
    return NO;
}

BOOL MediaPlaybackResultSupportsCicada(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return NO;
    if([result[@"dashRemuxed"] boolValue])return NO;
    NSString *engine=MediaPlaybackString(result[@"playbackEngine"]);
    if([engine isEqual:@"cicada"])return YES;
    NSString *format=MediaPlaybackString(result[@"format"]?:result[@"mediaType"]?:result[@"playbackType"]);
    NSString *mime=MediaPlaybackString(result[@"contentType"]?:result[@"content_type"]?:result[@"mimeType"]?:result[@"mime"]);
    NSRange semicolon=[mime rangeOfString:@";"];if(semicolon.location!=NSNotFound)mime=[[mime substringToIndex:semicolon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:result[@"url"];
    NSURLComponents *components=[NSURLComponents componentsWithString:[raw isKindOfClass:NSString.class]?raw:@""];
    NSString *extension=components.path.pathExtension.lowercaseString?:@"";
    // Match the bundled demuxers documented in MediaPlaybackDecodeRouter.m.
    // A container hint does not establish codec support (notably WebM).
    NSSet *formats=[NSSet setWithArray:@[@"mpd",@"dash",@"mpeg-dash",@"flv",@"live_flv",@"mkv",@"matroska",@"webm",@"3gp",@"3gpp",@"rtmp"]];
    NSSet *extensions=[NSSet setWithArray:@[@"mpd",@"flv",@"mkv",@"webm",@"3gp",@"3gpp"]];
    NSSet *mimes=[NSSet setWithArray:@[@"application/dash+xml",@"video/x-flv",@"video/x-matroska",@"video/webm",@"video/3gpp",@"video/3gpp2",@"application/x-rtmp"]];
    NSString *scheme=components.scheme.lowercaseString;
    return [formats containsObject:format]||[extensions containsObject:extension]||[mimes containsObject:mime]||[mimes containsObject:format]||[scheme isEqual:@"rtmp"]||[scheme isEqual:@"rtmps"];
}

BOOL MediaPlaybackResultSupportsNativePlayback(NSDictionary *result) {
    return MediaPlaybackResultSupportsAVPlayer(result)||MediaPlaybackResultSupportsCicada(result);
}

BOOL MediaPlaybackResultIsDirectMedia(NSDictionary *result) {
    if(![result isKindOfClass:NSDictionary.class])return NO;
    if([result[@"directMedia"] respondsToSelector:@selector(boolValue)]&&[result[@"directMedia"] boolValue])return YES;
    if(MediaPlaybackResultSupportsNativePlayback(result))return YES;
    NSString *format=MediaPlaybackString(result[@"format"]?:result[@"mediaType"]?:result[@"playbackType"]);
    NSString *mime=MediaPlaybackString(result[@"contentType"]?:result[@"content_type"]?:result[@"mimeType"]?:result[@"mime"]);
    if([mime hasPrefix:@"video/"]||[mime hasPrefix:@"audio/"])return YES;
    if([@[@"mpd",@"dash",@"flv",@"mkv",@"avi",@"webm",@"wmv",@"rmvb"] containsObject:format])return YES;
    NSString *raw=[result[@"originalURL"] isKindOfClass:NSString.class]?result[@"originalURL"]:result[@"url"];
    NSURLComponents *components=[NSURLComponents componentsWithString:[raw isKindOfClass:NSString.class]?raw:@""];
    NSString *ext=components.path.pathExtension.lowercaseString?:@"";
    if([@[@"mpd",@"flv",@"mkv",@"avi",@"webm",@"wmv",@"rmvb",@"m3u8",@"mp4"] containsObject:ext])return YES;
    if(!ext.length&&[raw isKindOfClass:NSString.class]&&raw.length){
        NSString *lowerRaw=[raw lowercaseString];
        if([lowerRaw containsString:@".m3u8"]||[lowerRaw containsString:@".mp4"]||[lowerRaw containsString:@".flv"]||[lowerRaw containsString:@".mpd"])return YES;
    }
    return NO;
}
