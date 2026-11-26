#import "HostPlaybackAndResourceCoordinators.h"
#import "MediaPlaybackMPVAdapter.h"
#import "MediaPlaybackCicadaAdapter.h"
#import "ChannelSQLiteIndex.h"

@implementation HostLivePlayerCoordinator

+ (instancetype)shared {
    static HostLivePlayerCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

+ (nullable id<CCTVPlaybackEngine>)engineForRoute:(MediaPlaybackDecodeRoute)route
                                               url:(NSURL *)url
                                           headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                    networkTimeout:(NSTimeInterval)timeout
                                    liveStreamHint:(BOOL)isLive {
    id<CCTVPlaybackEngine> engine = nil;
    if (route == MediaPlaybackDecodeRouteMPV) {
        // MPV 被禁用时 fail-closed：绝不实例化，调用方走统一终态。
        if (!MediaPlaybackMPVRouteEnabled()) return nil;
        engine = [[MediaPlaybackMPVAdapter alloc] initWithURL:url headers:headers networkTimeout:timeout];
    } else if (route == MediaPlaybackDecodeRouteCicadaPlayer) {
        if (![MediaPlaybackCicadaAdapter isAvailable]) return nil;
        engine = [[MediaPlaybackCicadaAdapter alloc] initWithURL:url headers:headers networkTimeout:timeout];
    } else {
        return nil;
    }
    engine.liveStreamHint = isLive;
    return engine;
}

- (NSTimeInterval)remainingSleepSeconds {
    if (!self.sleepTimerFireDate) return 0;
    return MAX(0, [self.sleepTimerFireDate timeIntervalSinceNow]);
}

@end

@implementation HostSubscriptionSyncCoordinator

+ (instancetype)shared {
    static HostSubscriptionSyncCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (NSString *)udpxyOverrideForSubscriptionURL:(NSString *)sourceURL {
    if (!sourceURL.length) return nil;
    NSDictionary *map = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.subscription.udpxy.v1"];
    if (![map isKindOfClass:NSDictionary.class]) return nil;
    NSString *val = map[sourceURL];
    return [val isKindOfClass:NSString.class] && val.length ? val : nil;
}

- (NSArray<M3UChannel *> *)parsePlaylistText:(NSString *)text
                                     baseURL:(NSURL *)baseURL
                                   sourceKey:(NSString *)sourceKey
                                       error:(NSError **)error {
    NSString *udpxy = [self udpxyOverrideForSubscriptionURL:sourceKey];
    return [M3UParser parse:text baseURL:baseURL udpxyOverride:udpxy error:error];
}

- (void)indexChannelsAsync:(NSArray<NSDictionary *> *)channels forSourceID:(NSString *)sourceID {
    NSArray<NSDictionary *> *snapshot = [channels copy] ?: @[];
    NSString *src = sourceID.length ? [sourceID copy] : @"catalog";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [ChannelSQLiteIndex.shared replaceChannels:snapshot forSourceID:src];
    });
}

@end

@implementation HostResourceBackupCoordinator

+ (NSData *)serializedBackupDataFromPayload:(NSDictionary *)payload error:(NSError **)error {
    if (![payload isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"CCTVHost.Backup" code:1 userInfo:@{NSLocalizedDescriptionKey: @"无效的配置数据"}];
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
}

+ (NSDictionary *)validatedBackupPayloadFromData:(NSData *)data error:(NSError **)error {
    if (!data.length || data.length > 10 * 1024 * 1024) {
        if (error) *error = [NSError errorWithDomain:@"CCTVHost.Backup" code:2 userInfo:@{NSLocalizedDescriptionKey: @"配置文件为空或超出 10 MiB 上限"}];
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![obj isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"CCTVHost.Backup" code:3 userInfo:@{NSLocalizedDescriptionKey: @"配置文件格式不是有效的 JSON 对象"}];
        return nil;
    }
    return (NSDictionary *)obj;
}

@end
