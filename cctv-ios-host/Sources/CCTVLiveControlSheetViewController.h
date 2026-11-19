#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CCTVLiveControlSheetViewController : UIViewController
@property(nonatomic, copy) NSString *channelTitle;
@property(nonatomic, copy) NSString *routeLabel;
@property(nonatomic, copy) NSString *modeLabel;
@property(nonatomic, assign) BOOL catchupActive;
@property(nonatomic, assign) BOOL playbackFailed;
@property(nonatomic, assign) BOOL canTimeshiftOrCatchup;
@property(nonatomic, assign) BOOL fullscreenActive;
@property(nonatomic, assign) BOOL pipSupported;
@property(nonatomic, assign) NSInteger sleepMinutes;
@property(nonatomic, copy, nullable) dispatch_block_t onRoutes;
@property(nonatomic, copy, nullable) dispatch_block_t onEPG;
@property(nonatomic, copy, nullable) dispatch_block_t onCast;
@property(nonatomic, copy, nullable) dispatch_block_t onToggleFullscreen;
@property(nonatomic, copy, nullable) dispatch_block_t onPrevChannel;
@property(nonatomic, copy, nullable) dispatch_block_t onNextChannel;
@property(nonatomic, copy, nullable) dispatch_block_t onRetryAlternate;
@property(nonatomic, copy, nullable) dispatch_block_t onTimeshift;
@property(nonatomic, copy, nullable) dispatch_block_t onReturnLive;
@property(nonatomic, copy, nullable) dispatch_block_t onPlaybackInfo;
@property(nonatomic, copy, nullable) dispatch_block_t onPiP;
@property(nonatomic, copy, nullable) void (^onSelectSleepMinutes)(NSInteger minutes);
@property(nonatomic, copy, nullable) dispatch_block_t onDiagnosticLog;
- (void)reloadThemeAppearance;
@end

NS_ASSUME_NONNULL_END
