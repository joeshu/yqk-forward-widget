#import <UIKit/UIKit.h>

#import "HostTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// A reusable, self-centering empty-状态视图。
///
/// 背景：阶段 C UI 审计发现 EPG、本地媒体、日志中心、全局搜索、影视收藏/历史、
/// 资源合集详情等十余处 二级页面 各自 hand-rolled `UILabel` 作为
/// `tableView.backgroundView` 来表达“暂无内容”：字号、颜色、动态字体开关
/// (dynamic type)、`accessibilityLabel`/`accessibilityHint` 与 VoiceOver 容器
/// 行为并不一致——部分站点缺 `adjustsFontForContentSizeCategory`，大字号下文字
/// 不缩放且容易截断；部分 “空” 标签未 设置 `accessibilityLabel`，VoiceOver 读出
/// 无意义占位。本 helper 收敛这些约定，使后续各页统一采用，降低 iPad/大字号与
/// 无障碍回归风险。
///
/// 设计目标（与既有 `HostGlassActionSheetViewController` 的 host 风格一致）：
///   1. 文字统一走 `preferredFontForTextStyle:` + `adjustsFontForContentSizeCategory`,
///      颜色走 `HostSecondaryText()`/`HostText()`；主题切换与 prefersLargeText
///      通过 `traitCollectionDidChange` 自动重刷。
///   2. 提供 SF Symbol 图标与可选 副标题、可选动作按钮，覆盖审计中常见的
///      “空态 + 单一动作入口”（如“返回导入”“重试”）形态。
///   3. 整体作为单个 VoiceOver 元素：`isAccessibilityElement=YES`，`accessibilityLabel`
///      由 title+subtitle 组合，`accessibilityTraits` 为静态文本；有动作按钮时改为
///      `UIAccessibilityTraitButton` 并附带 `accessibilityHint`，避免逐子元素朗读
///      造成冗余。
///   4. 提供工厂 `+placeholderLabelWithText:color:` 用于 直接替换既有
///      `UILabel` 背景 模式（保持最小迁移面）。
///
/// 用法：
///   @code
///   HostEmptyStateView *v = [HostEmptyStateView emptyStateViewWithTitle:@"还没有收藏影视"
///                                                                subtitle:@"在影片详情页点按「收藏」即可保存"
///                                                                  symbol:@"heart"
///                                                                actionTitle:@"去发现影视"];
///   v.onAction = ^{ [self openDiscover]; };
///   self.tableView.backgroundView = v;
///   @endcode
@interface HostEmptyStateView : UIView

/// 空态 主标题（如“还没有收藏影视”）。可空；为空时不显示标题行。
@property (nonatomic, copy, nullable) NSString *title;
/// 空态 副标题/提示（如“在影片详情页点按「收藏」即可保存”）。可空。
@property (nonatomic, copy, nullable) NSString *subtitle;
/// SF Symbol 名称（如 `heart`/`tray`）。可空；为空时不显示图标。
@property (nonatomic, copy, nullable) NSString *symbolName;
/// 可选动作按钮标题（如“重试”/“去导入”）。为空时不显示按钮。
@property (nonatomic, copy, nullable) NSString *actionTitle;
/// 动作按钮点击回调。仅在 `actionTitle` 非空且按钮被点按时触发。
@property (nonatomic, copy, nullable) void (^onAction)(void);
/// 空态视图无障碍标识，便于 UI 测试定位（如 `media-favorites-empty`）。
@property (nonatomic, copy, nullable) NSString *accessibilityIdentifier;

/// 便捷工厂：构造一个带 title/subtitle/symbol 的空态视图，不含动作按钮。
+ (instancetype)emptyStateViewWithTitle:(nullable NSString *)title
                                 subtitle:(nullable NSString *)subtitle
                                   symbol:(nullable NSString *)symbol;

/// 便捷工厂：构造一个带 title/subtitle/symbol 与动作按钮的空态视图。
+ (instancetype)emptyStateViewWithTitle:(nullable NSString *)title
                                 subtitle:(nullable NSString *)subtitle
                                   symbol:(nullable NSString *)symbol
                               actionTitle:(nullable NSString *)actionTitle;

/// 工厂：返回一个按本项目空态约定配置的占位 `UILabel`，可直接赋给
/// `tableView.backgroundView`。文字多行、居中、动态字体、`HostSecondaryText`
/// 颜色，并带 `accessibilityLabel`/`accessibilityTraits`。`NSString` 文案中
/// 的 `\n` 会被保留为换行（与现有 各页 的 `numberOfLines=0` 行为一致）。
+ (UILabel *)placeholderLabelWithText:(NSString *)text;

/// 主题/动态字体刷新。页面层面的 `reloadThemeAppearance` 可调用本方法以保持
/// 颜色一致。对占位标签工厂产出的 label 无需调用（标签使用动态颜色提供者）。
- (void)reloadThemeAppearance;

@end

NS_ASSUME_NONNULL_END
