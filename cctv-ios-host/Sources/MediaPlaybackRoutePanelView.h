#import <UIKit/UIKit.h>

#import "HostTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// 线路面板纯呈现视图（b-route-episode-panel 阶段拆分）。
///
/// 背景：`MediaPlaybackViewController` 此前在 `buildLines` 内手搓横向滚动
/// `UIScrollView` + `UIStackView` 容器、五条内部约束与每条线路按钮的样式 /
/// accessibilityIdentifier / accessibilityLabel / accessibilityHint /
/// accessibilityTraits，呈现逻辑与控制器状态、路由回退、播放器状态机混在
/// 同一 2900 行实现里。本类把「线路面板的纯呈现职责」抽离为独立 UIView：
///
///   1. 自持 `lineScroll`（横向滚动容器）与 `lineButtons`（按钮栈）及其内部
///      Auto Layout 约束，控制器只负责把本视图钉到 `controlPanel` 并给定 44pt
///      高度——不再在控制器里手写内部约束。
///   2. `rebuildWithLines:selectedIndex:target:action:` 逐字迁移原 `buildLines`
///      的按钮构造：标题（线路名或缺省「线路 N」）、13pt Medium 字体、
///      `HostStylePillButton` 选中态、`MediaPlaybackApplyScaledPillFont` 动态
///      字体缩放、`button.tag=idx`、`accessibilityIdentifier=
///      "media-playback-line-%lu"`、`accessibilityLabel`、`accessibilityHint`、
///      `accessibilityTraits`（含 `UIAccessibilityTraitSelected`），并把点按
///      事件以 target/action 转发给控制器——不持有任何路由 / 会话 / 播放器
///      状态，_SELECTED 线路、线路列表均由调用方以值传入。
///
/// 设计约束（与既有契约一致）：
///   - 不依赖 `MediaPlaybackDecodeRouter` / `HostPlaybackSession` / 播放器状态机；
///   - accessibilityIdentifier / accessibilityLabel / accessibilityHint /
///     accessibilityTraits 与原 `buildLines` 逐字一致，UI Smoke 与
///     `test_p3_accessibility_contracts` / `test_ui_round2_playback_search`
///     断言的字符串契约在新位置继续成立；
///   - `lineButtons` / `lineScroll` 以 readonly 暴露，供控制器的 KVC
///     （UISmoke `valueForKey:@"lineButtons"`）与既有别名兼容。
@interface MediaPlaybackRoutePanelView : UIView

/// 横向滚动容器。控制器外部约束不再直接引用；保留 readonly 供兼容访问。
@property(nonatomic,strong,readonly) UIScrollView *lineScroll;
/// 线路按钮栈。UISmoke 经 KVC `valueForKey:@"lineButtons"` 取该栈触发
/// `selectLine:`，故仍按原约定暴露。
@property(nonatomic,strong,readonly) UIStackView *lineButtons;

/// 依据线路列表重建按钮。逐字迁移自 `MediaPlaybackViewController.buildLines`，
/// 仅把 `self.lines`/`self.lineIndex`/`self`/`@selector(selectLine:)` 改为
/// 由参数传入，行为等价。
///
/// @param lines        线路字典数组（每项可含 `name`）。
/// @param selectedIndex 当前选中线路下标，用于选中态样式与 a11y trait。
/// @param target       按钮点按 target（控制器自身）。
/// @param action       按钮点按 action（`selectLine:`）。
- (void)rebuildWithLines:(NSArray *)lines
            selectedIndex:(NSInteger)selectedIndex
                   target:(id)target
                   action:(SEL)action;

@end

NS_ASSUME_NONNULL_END
