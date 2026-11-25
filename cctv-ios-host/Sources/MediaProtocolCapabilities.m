// MediaProtocolCapabilities.m
#import "MediaProtocolCapabilities.h"

static NSString * const MediaProtocolCapabilityVerifiedName = @"verified";
static NSString * const MediaProtocolCapabilityEngineDependentName = @"engine_dependent";
static NSString * const MediaProtocolCapabilityExperimentalName = @"experimental";
static NSString * const MediaProtocolCapabilityUnknownName = @"unknown";

NSDictionary<NSString *, NSString *> *MediaProtocolCapabilityTable(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"hls": @"verified",
            @"mp4": @"verified",
            @"flv": @"engine_dependent",
            @"dash": @"engine_dependent",
            @"rtmp": @"engine_dependent",
            @"rtsp": @"experimental",
            @"srt": @"experimental",
            @"smb": @"experimental",
            @"udp": @"experimental",
        };
    });
    return table;
}

static NSString *MediaProtocolCanonicalName(NSString *protocolName) {
    if (![protocolName isKindOfClass:NSString.class]) return nil;
    NSString *name = [[protocolName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!name.length) return nil;
    static NSDictionary<NSString *, NSString *> *aliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @{
            @"m3u8": @"hls", @"m3u": @"hls",
            @"application/vnd.apple.mpegurl": @"hls", @"application/x-mpegurl": @"hls",
            @"m4v": @"mp4", @"video/mp4": @"mp4",
            @"live_flv": @"flv", @"video/x-flv": @"flv",
            @"mpd": @"dash", @"mpeg-dash": @"dash", @"application/dash+xml": @"dash",
            @"rtmps": @"rtmp",
            @"rtsps": @"rtsp",
            @"rtp": @"udp",
        };
    });
    return aliases[name] ?: name;
}

NSString *MediaProtocolCapabilityStatusName(MediaProtocolCapabilityStatus status) {
    switch (status) {
        case MediaProtocolCapabilityStatusVerified: return MediaProtocolCapabilityVerifiedName;
        case MediaProtocolCapabilityStatusEngineDependent: return MediaProtocolCapabilityEngineDependentName;
        case MediaProtocolCapabilityStatusExperimental: return MediaProtocolCapabilityExperimentalName;
        case MediaProtocolCapabilityStatusUnknown: return MediaProtocolCapabilityUnknownName;
    }
    return MediaProtocolCapabilityUnknownName;
}

MediaProtocolCapabilityStatus MediaProtocolCapabilityStatusForProtocol(NSString *protocolName) {
    NSString *name = MediaProtocolCanonicalName(protocolName);
    if (!name) return MediaProtocolCapabilityStatusUnknown;
    NSString *value = MediaProtocolCapabilityTable()[name];
    if ([value isEqualToString:MediaProtocolCapabilityVerifiedName]) return MediaProtocolCapabilityStatusVerified;
    if ([value isEqualToString:MediaProtocolCapabilityEngineDependentName]) return MediaProtocolCapabilityStatusEngineDependent;
    if ([value isEqualToString:MediaProtocolCapabilityExperimentalName]) return MediaProtocolCapabilityStatusExperimental;
    return MediaProtocolCapabilityStatusUnknown;
}

NSString *MediaProtocolIdentifierForURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return nil;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([@[@"rtmp", @"rtmps", @"rtsp", @"rtsps", @"srt", @"smb", @"udp", @"rtp"] containsObject:scheme]) {
        return MediaProtocolCanonicalName(scheme);
    }
    NSString *ext = url.pathExtension.lowercaseString ?: @"";
    if ([@[@"m3u8", @"m3u"] containsObject:ext]) return @"hls";
    if ([@[@"mp4", @"m4v"] containsObject:ext]) return @"mp4";
    if ([ext isEqualToString:@"flv"]) return @"flv";
    if ([ext isEqualToString:@"mpd"]) return @"dash";
    return nil;
}

MediaProtocolCapabilityStatus MediaProtocolCapabilityStatusForURL(NSURL *url) {
    return MediaProtocolCapabilityStatusForProtocol(MediaProtocolIdentifierForURL(url));
}

BOOL MediaProtocolCapabilityIsVerified(NSString *protocolName) {
    return MediaProtocolCapabilityStatusForProtocol(protocolName) == MediaProtocolCapabilityStatusVerified;
}
