// MediaProtocolCapabilities.h
//
// 协议能力表（P2）：按协议/封装标注宿主播放链路的支持成熟度。
//
//   verified          设备上已验证可播：HLS、MP4
//   engine_dependent  取决于所选内核（Cicada/MPV 等）及构建能力：FLV、DASH、RTMP
//   experimental      实验性，未做设备验证，不保证可播：RTSP、SRT、SMB、UDP
//
// 数据源与 Plugins/media-capabilities.json 的 "protocolCapabilities" 保持一致，
// 由 Tests/test_protocol_capabilities.py 做源码契约校验。纯 Foundation，不引用播放器 SDK。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MediaProtocolCapabilityStatus) {
    MediaProtocolCapabilityStatusUnknown = 0,
    MediaProtocolCapabilityStatusVerified,
    MediaProtocolCapabilityStatusEngineDependent,
    MediaProtocolCapabilityStatusExperimental,
};

/// 协议标识（小写）→ 状态字符串（@"verified" / @"engine_dependent" / @"experimental"）。
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *MediaProtocolCapabilityTable(void);

/// 按协议标识查询（大小写不敏感，接受 @"m3u8"→hls、@"mpd"→dash 等别名）；未登记返回 Unknown。
FOUNDATION_EXPORT MediaProtocolCapabilityStatus MediaProtocolCapabilityStatusForProtocol(NSString * _Nullable protocolName);

/// 从 URL 推断协议标识：先看 scheme（rtmp/rtmps/rtsp/rtsps/srt/smb/udp/rtp），
/// 再看扩展名（m3u8/m3u→hls、mp4/m4v→mp4、flv→flv、mpd→dash）；推断不出返回 nil。
FOUNDATION_EXPORT NSString * _Nullable MediaProtocolIdentifierForURL(NSURL * _Nullable url);

/// 便捷：MediaProtocolCapabilityStatusForProtocol(MediaProtocolIdentifierForURL(url))。
FOUNDATION_EXPORT MediaProtocolCapabilityStatus MediaProtocolCapabilityStatusForURL(NSURL * _Nullable url);

/// 状态 → 字符串（@"verified" / @"engine_dependent" / @"experimental" / @"unknown"）。
FOUNDATION_EXPORT NSString *MediaProtocolCapabilityStatusName(MediaProtocolCapabilityStatus status);

/// 是否已验证（仅 verified 为 YES）。
FOUNDATION_EXPORT BOOL MediaProtocolCapabilityIsVerified(NSString * _Nullable protocolName);

NS_ASSUME_NONNULL_END
