#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HostSubtitleCue : NSObject
@property (nonatomic, assign) NSTimeInterval startTime;
@property (nonatomic, assign) NSTimeInterval endTime;
@property (nonatomic, copy) NSString *text;
@end

/// 轻量原生外挂字幕渲染层（支持 SRT / WebVTT / ASS-SSA，兼容 AVPlayer 与 Cicada/MPV）。
@interface HostSubtitleOverlayView : UIView

/// 字号缩放倍率（0.8 ~ 1.6，默认 1.0）。
@property (nonatomic, assign) CGFloat fontScale;
/// 字幕时间轴偏移（秒，支持 ±0.5s 微调，正值延后，负值提前）。
@property (nonatomic, assign) NSTimeInterval timeOffset;
/// 是否启用显示（默认 YES）。
@property (nonatomic, assign) BOOL subtitlesEnabled;
/// 已解析的字幕条目数。
@property (nonatomic, readonly) NSUInteger cueCount;

/// 同步解析 SRT / WebVTT / ASS 文本并按时间排序。
+ (NSArray<HostSubtitleCue *> *)parseSubtitleText:(NSString *)rawText;

/// 异步拉取远端或本地字幕文件并解析挂载。
- (void)loadSubtitleURL:(NSURL *)url
                headers:(nullable NSDictionary<NSString *, NSString *> *)headers
             completion:(nullable void (^)(BOOL loaded, NSUInteger cueCount))completion;

/// 直接加载字幕文本。
- (void)loadSubtitleText:(NSString *)rawText;

/// 清空当前字幕。
- (void)clearSubtitles;

/// 按当前播放进度（秒）O(log N) 刷新字幕文本。
- (void)updateForPlaybackTime:(NSTimeInterval)playbackTime;

@end

NS_ASSUME_NONNULL_END
