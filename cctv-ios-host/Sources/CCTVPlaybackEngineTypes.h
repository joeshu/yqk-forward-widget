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
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error;
- (void)cicadaAdapterDidComplete:(id)adapter;
- (void)cicadaAdapter:(id)adapter didUpdatePosition:(NSTimeInterval)position duration:(NSTimeInterval)duration;
- (void)cicadaAdapter:(id)adapter didUpdateLoading:(BOOL)loading progress:(float)progress;
- (void)cicadaAdapter:(id)adapter didUpdateDownloadSpeed:(double)bitsPerSecond;
- (void)cicadaAdapter:(id)adapter didUpdateVideoSize:(CGSize)size rotation:(NSInteger)rotation;
- (void)cicadaAdapterDidSeek:(id)adapter;
@end

NS_ASSUME_NONNULL_END
