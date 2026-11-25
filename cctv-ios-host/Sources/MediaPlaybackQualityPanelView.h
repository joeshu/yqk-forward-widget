#import <UIKit/UIKit.h>

#import "HostTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// 画质面板纯呈现视图（b-quality-panel 阶段拆分）。
///
/// 背景：`MediaPlaybackViewController` 此前在控件装配块里手搓
/// `qualityGroup`（纵向 UIStackView）+ `qualityLabel`（「清晰度」标题）+
/// `qualityScroll`（横向滚动容器）+ `qualityButtons`（按钮栈）四件套，连同
/// `qualityScroll` 的 44pt 高度约束与五条内部锚约束一并写在控制器里；又把
/// `buildQualityButtons` 的「按 alternates 计数折叠显示标题/滚动条」与
/// 「逐档按钮的样式 / accessibilityIdentifier / accessibilityLabel /
/// accessibilityHint / 选中态 / 按压反馈 / 动态字体缩放」构造逻辑混在同一
/// 2900 行实现里。本类把「画质面板的纯呈现职责」抽离为独立 UIView：
///
///   1. 自持 `qualityGroup`（纵向栈：标题 + 滚动条）及其内部 Auto Layout
///      约束（`qualityGroup` 钉到本视图四边，`qualityScroll` 44pt 高，
///      `qualityButtons` 锚到 `qualityScroll` 内容区），控制器只负责把本
///      视图钉到 `controlPanel` 并通过 `qualityGroup` 别名参与外部几何——
///      不再在控制器里手写内部约束。
///   2. `rebuildWithAlternates:selectedIndex:target:action:` 逐字迁移原
///      `buildQualityButtons` 的面板折叠（`qualityGroup.spacing` /
///      `qualityLabel.hidden` / `qualityScroll.hidden` / 标题文案随档数
///      切换）与每档按钮构造：标题（`alternate[@"name"]` 或缺省「清晰度 N」）、
///      13pt Medium 字体、`HostStylePillButton` 选中态、
///      `MediaPlaybackApplyScaledPillFont` 动态字体缩放、`button.tag=index`、
///      `accessibilityIdentifier="media-quality-%lu"`、`accessibilityLabel`、
///      `accessibilityHint`（单档/多档分支）、`HostInstallPressFeedback`，
///      把点按事件以 target/action 转发给控制器——不持有任何 alternates
///      模型、selectedAlternateIndex 状态、路由 / 会话 / 播放器状态；alternates
///      列表与选中下标均由调用方以值传入。
///
/// 设计约束（与既有契约一致）：
///   - 不依赖 `MediaPlaybackDecodeRouter` / `HostPlaybackSession` / 播放器状态机，
///     不调用 `resolveAndPlay` / `playResult:` / `selectAlternate:`；
///   - accessibilityIdentifier / accessibilityLabel / accessibilityHint 与原
///     `buildQualityButtons` 逐字一致，UISmoke 与
///     `test_ui_round2_playback_search` / `test_ui_2026_deep_refinements`
///     断言的字符串契约在新位置继续成立；
///   - `qualityGroup` / `qualityLabel` / `qualityScroll` / `qualityButtons`
///     以 readonly 暴露，供控制器的 KVC（UISmoke
///     `valueForKey:@"qualityButtons"` 触发 `selectAlternate:`）与既有外部
///     约束别名兼容。
@interface MediaPlaybackQualityPanelView : UIView

/// 纵向容器栈（标题 + 横向滚动条）。控制器外部约束仍引用 `qualityGroup`
/// （top/leading/trailing），故按原约定暴露；本视图内部将其钉到自身四边。
@property(nonatomic,strong,readonly) UIStackView *qualityGroup;
/// 「清晰度」标题。控制器经别名引用，保留 readonly 供兼容访问。
@property(nonatomic,strong,readonly) UILabel *qualityLabel;
/// 横向滚动容器。控制器外部约束 / 高度契约经别名引用，保留 readonly。
@property(nonatomic,strong,readonly) UIScrollView *qualityScroll;
/// 画质按钮栈。UISmoke 经 KVC `valueForKey:@"qualityButtons"` 取该栈触发
/// `selectAlternate:`，故仍按原约定暴露。
@property(nonatomic,strong,readonly) UIStackView *qualityButtons;

/// 依据 alternates 列表重建画质按钮。逐字迁移自
/// `MediaPlaybackViewController.buildQualityButtons` 的折叠与按钮构造段，
/// 仅把 `self.result[@"alternates"]` / `self.selectedAlternateIndex` /
/// `self` / `@selector(selectAlternate:)` 改为由参数传入，行为等价。
/// 选中下标解析（按 originalURL 匹配、单档缺省）继续留在控制器，本方法
/// 只负责按给定下标渲染选中态。
///
/// @param alternates  alternates 字典数组（每项可含 `name`/`url`/`originalURL`）。
/// @param selectedIndex 当前选中画质下标（-1 表示无选中），用于选中态样式。
/// @param target      按钮点按 target（控制器自身）。
/// @param action      按钮点按 action（`selectAlternate:`）。
- (void)rebuildWithAlternates:(NSArray *)alternates
                 selectedIndex:(NSInteger)selectedIndex
                        target:(id)target
                        action:(SEL)action;

@end

NS_ASSUME_NONNULL_END
