#import "MediaPlaybackRoutePanelView.h"

// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
// 与 MediaPlaybackViewController.m 内的同名 file-scope static 等价（内部 linkage，
// 互不冲突）；保持本视图自持、不反向依赖控制器。
static void MediaPlaybackApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

@interface MediaPlaybackRoutePanelView ()
@property(nonatomic,strong) UIScrollView *lineScroll;
@property(nonatomic,strong) UIStackView *lineButtons;
@end

@implementation MediaPlaybackRoutePanelView

- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.translatesAutoresizingMaskIntoConstraints=NO;
        _lineScroll=[UIScrollView new];_lineScroll.translatesAutoresizingMaskIntoConstraints=NO;_lineScroll.showsHorizontalScrollIndicator=NO;[self addSubview:_lineScroll];
        _lineButtons=[UIStackView new];_lineButtons.axis=UILayoutConstraintAxisHorizontal;_lineButtons.spacing=8;_lineButtons.translatesAutoresizingMaskIntoConstraints=NO;[_lineScroll addSubview:_lineButtons];
        // 原 buildLines 调用点把以下五条内部约束写在控制器的 portrait/embedded
        // 约束块里；此处收敛到面板自身，控制器只钉本视图的外部几何。
        [NSLayoutConstraint activateConstraints:@[
            [_lineScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_lineScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_lineScroll.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_lineScroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_lineButtons.leadingAnchor constraintEqualToAnchor:_lineScroll.contentLayoutGuide.leadingAnchor],
            [_lineButtons.trailingAnchor constraintEqualToAnchor:_lineScroll.contentLayoutGuide.trailingAnchor],
            [_lineButtons.topAnchor constraintEqualToAnchor:_lineScroll.contentLayoutGuide.topAnchor],
            [_lineButtons.bottomAnchor constraintEqualToAnchor:_lineScroll.contentLayoutGuide.bottomAnchor],
            [_lineButtons.heightAnchor constraintEqualToAnchor:_lineScroll.frameLayoutGuide.heightAnchor],
        ]];
    }
    return self;
}

- (void)rebuildWithLines:(NSArray *)lines
            selectedIndex:(NSInteger)selectedIndex
                   target:(id)target
                   action:(SEL)action {
    for(UIView *view in self.lineButtons.arrangedSubviews.copy){[self.lineButtons removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSUInteger idx=0;idx<lines.count;idx++){NSDictionary *line=lines[idx];NSString *lineName=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:nil;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:lineName.length?lineName:[NSString stringWithFormat:@"线路 %lu",(unsigned long)idx+1] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];HostStylePillButton(button,idx==selectedIndex);MediaPlaybackApplyScaledPillFont(button);button.tag=idx;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-playback-line-%lu",(unsigned long)idx];button.accessibilityLabel=[NSString stringWithFormat:@"线路 %@",lineName.length?lineName:[NSString stringWithFormat:@"%lu",(unsigned long)idx+1]];button.accessibilityHint=@"切换到此播放线路并重新加载分集";button.accessibilityTraits=UIAccessibilityTraitButton|(idx==selectedIndex?UIAccessibilityTraitSelected:0);[button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];[self.lineButtons addArrangedSubview:button];}
}

@end
