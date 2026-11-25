// MediaPlaybackSettingsCoordinator.h
//
// 播放设置/菜单协调器（阶段 B-P1）：从 MediaPlaybackViewController（约 3070 行）抽出
// 播放设置菜单的构建职责——倍速、画面比例、音轨、字幕、外挂字幕、睡眠定时、解码模式、
// 观看偏好（自动连播/常亮/片头片尾跳过）、诊断与监测、分集快捷导航——以及睡眠定时状态。
//
// 设计：
//   协调器只负责「菜单构建」与「睡眠定时生命周期」。引擎作用类操作（setPlaybackRate /
//   setVideoGravity / setKeepScreenAwake / rememberIntroEnd / rememberOutroSkip / playResult:
//   / 诊断拷贝 / 监测页 / 解码模式切换 / 上下集切换）仍由宿主 VC 实现，协调器经 owner 回调。
//   这样巨型 VC 的菜单层被独立成单一职责协调器，引擎/状态机/路由层不被触碰
//   （MPV 路由属 a-playback-route 分支；状态机属 a-playback-session 分支）。
//
//   accessibilityIdentifier（如 media-playback-speed）与菜单标识符
//   （media.playback.menu.av / .controls / .prefs / .diag / .skip / .episodes / .extsub）
//   保持不变；按钮样式与触发行为（showsMenuAsPrimaryAction 等）由宿主 VC 维持。
//
// 不直接持有 UI 控件所有权：按钮由宿主 VC 在布局阶段创建并经协议暴露给协调器，
// 协调器仅读写其 .menu / .hidden / 标题等可变属性。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "HostSubtitleOverlayView.h"

NS_ASSUME_NONNULL_BEGIN

@class MediaPlaybackCicadaAdapter;
@class AVPlayer;

/// 宿主向协调器提供的状态与回调契约。宿主（MediaPlaybackViewController）在类扩展中声明遵循。
@protocol MediaPlaybackSettingsCoordinatorOwner <NSObject>
// ---- 只读播放器/控件状态 ----
@property (nonatomic, readonly, nullable) AVPlayer *player;
@property (nonatomic, readonly, nullable) MediaPlaybackCicadaAdapter *cicadaAdapter;
@property (nonatomic, readonly, nullable) UIButton *playbackSpeedButton;
@property (nonatomic, readonly, nullable) UIBarButtonItem *playbackOptionsItem;
@property (nonatomic, readonly, nullable) UIButton *inlineOptionsButton;
@property (nonatomic, readonly, nullable) HostSubtitleOverlayView *subtitleOverlay;
@property (nonatomic, readonly, nullable) UILabel *status;
@property (nonatomic, copy, readonly, nullable) NSDictionary *context;
@property (nonatomic, readonly) NSInteger lineIndex;
@property (nonatomic, readonly) NSInteger episodeIndex;
@property (nonatomic, readonly) NSArray *episodes;
@property (nonatomic, copy, readonly, nullable) NSString *diagnosticTraceID;
// ---- 引擎能力与位置查询 ----
- (BOOL)activeEngineSupportsRateWriting;
- (NSTimeInterval)activeEngineCurrentPosition;
- (BOOL)isCicadaEngineActive;
// ---- 引擎作用类回调（宿主实现） ----
- (void)setPlaybackRate:(double)rate;
- (void)setVideoGravity:(NSString *)gravity;
- (void)setKeepScreenAwake:(BOOL)enabled;
- (void)rememberIntroEnd;
- (void)rememberOutroSkip;
- (void)copyCurrentStreamDiagnostics;
- (void)openAdaptationMonitor;
- (void)playResult:(NSDictionary *)result;
- (void)playNextEpisodeManually;
- (void)playPreviousEpisodeManually;
- (void)showGestureFeedback:(NSString *)text;
- (void)pauseActiveEngine;
- (void)ensureSubtitleOverlayInstalled;
- (void)updateSkipButtonForCurrentPosition;
/// 解码模式切换：保存偏好并以新解码重载当前播放（续播进度恢复由宿主负责）。
- (void)applyDecodeModeChange:(NSString *)mode;
@end

@interface MediaPlaybackSettingsCoordinator : NSObject
/// 弱引用宿主 VC，避免循环。
@property (nonatomic, weak, nullable) id<MediaPlaybackSettingsCoordinatorOwner> owner;
/// 当前睡眠定时分钟数；0 表示未开启。
@property (nonatomic) NSInteger mediaSleepMinutes;
/// 睡眠定时器实例。
@property (nonatomic, strong, nullable) NSTimer *mediaSleepTimer;

- (instancetype)initWithOwner:(id<MediaPlaybackSettingsCoordinatorOwner>)owner NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 重建顶层菜单并回写 playbackOptionsItem / inlineOptionsButton / playbackSpeedButton。
/// 宿主在任意设置变更后调用以刷新菜单与按钮可用态。
- (void)refreshMenus;
/// 顶层播放设置菜单（音画与解码 / 播放控制 / 观看偏好 / 诊断与监测 / 分集快捷导航）。
- (UIMenu *)playbackOptionsMenu;
/// 倍速子菜单；引擎不支持写倍速时隐藏 playbackSpeedButton 并返回 nil。
- (nullable UIMenu *)playbackRateMenu;
/// 睡眠定时子菜单。
- (UIMenu *)playbackSleepTimerMenu;
/// 轨道选择子菜单（音轨/字幕）；引擎不支持轨道选择或当前无轨道时返回 nil（隐藏该子菜单）。
- (nullable UIMenu *)mediaSelectionMenuForCharacteristic:(AVMediaCharacteristic)characteristic title:(NSString *)title;
/// 外挂字幕调节子菜单（显示/隐藏、字号、时间轴偏移）。
- (UIMenu *)externalSubtitleMenu;
/// 设置睡眠定时（分钟）；<=0 关闭并清除。到点自动暂停播放并提示。
- (void)configureMediaSleepTimerMinutes:(NSInteger)minutes;
/// 立即停止睡眠定时（不触发到点暂停）；宿主退出/dealloc 时调用。
- (void)invalidateSleepTimer;
@end

NS_ASSUME_NONNULL_END
