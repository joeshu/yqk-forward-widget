#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MediaPlaybackCicadaAdapterState) {
    MediaPlaybackCicadaAdapterStateIdle = 0,
    MediaPlaybackCicadaAdapterStatePreparing,
    MediaPlaybackCicadaAdapterStatePlaying,
    MediaPlaybackCicadaAdapterStatePaused,
    MediaPlaybackCicadaAdapterStateCompleted,
    MediaPlaybackCicadaAdapterStateFailed,
};

@protocol MediaPlaybackCicadaAdapterDelegate <NSObject>
@optional
- (void)cicadaAdapterDidPrepare:(id)adapter;
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter;
/// 纯音频开始（S2）：时间在前进、没有视频轨道/视频画面时报告；与
/// 首帧不同——调用方不得把音频开始当作视频首帧（videoFrameReady 保持
/// NO）。视频画面随后出现时仍可再报 cicadaAdapterDidShowFirstFrame:。
- (void)cicadaAdapterDidStartAudioOnly:(id)adapter;
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error;
- (void)cicadaAdapterDidComplete:(id)adapter;
- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration;
- (void)cicadaAdapter:(id)adapter didUpdateLoading:(BOOL)loading progress:(float)progress;
- (void)cicadaAdapter:(id)adapter didUpdateDownloadSpeed:(double)bitsPerSecond;
- (void)cicadaAdapter:(id)adapter didUpdateVideoSize:(CGSize)size rotation:(NSInteger)rotation;
- (void)cicadaAdapterDidSeek:(id)adapter;
@end

NS_ASSUME_NONNULL_END
