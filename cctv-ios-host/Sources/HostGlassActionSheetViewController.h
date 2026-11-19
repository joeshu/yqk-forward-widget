#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface HostGlassSheetAction : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *subtitle;
@property(nonatomic, copy, nullable) NSString *value;
@property(nonatomic, copy, nullable) NSString *iconName;
@property(nonatomic, strong, nullable) UIColor *tintColor;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL selected;
@property(nonatomic, copy, nullable) dispatch_block_t handler;
+ (instancetype)actionWithTitle:(NSString *)title
                       subtitle:(nullable NSString *)subtitle
                          value:(nullable NSString *)value
                           icon:(nullable NSString *)iconName
                           tint:(nullable UIColor *)tintColor
                    destructive:(BOOL)destructive
                       selected:(BOOL)selected
                        handler:(nullable dispatch_block_t)handler;
@end

@interface HostGlassSheetSection : NSObject
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, copy) NSArray<HostGlassSheetAction *> *actions;
@property(nonatomic, assign) BOOL horizontalChips;
+ (instancetype)sectionWithTitle:(nullable NSString *)title actions:(NSArray<HostGlassSheetAction *> *)actions;
+ (instancetype)chipSectionWithTitle:(nullable NSString *)title actions:(NSArray<HostGlassSheetAction *> *)actions;
@end

@interface HostGlassActionSheetViewController : UIViewController
@property(nonatomic, copy) NSString *sheetTitle;
@property(nonatomic, copy, nullable) NSString *sheetSubtitle;
@property(nonatomic, copy, nullable) NSString *badgeText;
@property(nonatomic, strong, nullable) UIColor *badgeColor;
@property(nonatomic, copy) NSArray<HostGlassSheetSection *> *sections;
- (void)reloadThemeAppearance;
+ (void)presentOn:(UIViewController *)presenter
            title:(NSString *)title
         subtitle:(nullable NSString *)subtitle
        badgeText:(nullable NSString *)badgeText
       badgeColor:(nullable UIColor *)badgeColor
         sections:(NSArray<HostGlassSheetSection *> *)sections
       sourceView:(nullable UIView *)sourceView;
@end

NS_ASSUME_NONNULL_END
