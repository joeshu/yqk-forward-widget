#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 主题色板偏好：保存所选主题的标识；未设置或未知标识时回退到默认主题。
static NSString * const HostThemePaletteIdentifierPreferenceKey = @"cctv.themeIdentifier.v1";
static NSString * const HostThemePaletteDefaultIdentifier = @"midnight";

// 一套主题的完整色板。15 个颜色角色与 HostTheme.h 的 HostXxx() 辅助函数一一对应，
// 各页面只通过 HostXxx() 取色，因此换主题不需要逐个页面改色值。
@interface HostThemePalette : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly) NSString *tagline;
@property (nonatomic, assign, readonly) BOOL dark;
@property (nonatomic, strong, readonly) UIColor *background;
@property (nonatomic, strong, readonly) UIColor *card;
@property (nonatomic, strong, readonly) UIColor *raisedSurface;
@property (nonatomic, strong, readonly) UIColor *text;
@property (nonatomic, strong, readonly) UIColor *secondaryText;
@property (nonatomic, strong, readonly) UIColor *accent;
@property (nonatomic, strong, readonly) UIColor *onAccent;
@property (nonatomic, strong, readonly) UIColor *accentFill;
@property (nonatomic, strong, readonly) UIColor *mutedText;
@property (nonatomic, strong, readonly) UIColor *glassTint;
@property (nonatomic, strong, readonly) UIColor *border;
@property (nonatomic, strong, readonly) UIColor *separator;
@property (nonatomic, strong, readonly) UIColor *neutralSurface;
@property (nonatomic, strong, readonly) UIColor *selectedSurface;
@property (nonatomic, strong, readonly) UIColor *highlightedSurface;
@property (nonatomic, strong, readonly) UIColor *successSurface;

// 全部主题（顺序即设置页展示顺序）：4 套深色沉浸 + 2 套浅色。
+ (NSArray<HostThemePalette *> *)allThemes;
+ (nullable HostThemePalette *)paletteForIdentifier:(nullable NSString *)identifier;
+ (HostThemePalette *)defaultDarkPalette;
+ (HostThemePalette *)defaultLightPalette;
// 当前所选主题的标识；未设置时返回默认标识。
+ (NSString *)currentPaletteIdentifier;
+ (void)setCurrentPaletteIdentifier:(NSString *)identifier;
+ (HostThemePalette *)currentPalette;
// 给定深浅下实际生效的色板：所选主题与深浅一致时用它，否则用该深浅的默认色板。
// “跟随系统”模式下深浅由系统决定，色板同样按此规则选取。
+ (HostThemePalette *)effectivePaletteForDark:(BOOL)dark;
@end

NS_ASSUME_NONNULL_END
