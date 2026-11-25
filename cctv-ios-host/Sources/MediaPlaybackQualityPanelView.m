#import "MediaPlaybackQualityPanelView.h"

// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
// 与 MediaPlaybackViewController.m / MediaPlaybackRoutePanelView.m 内的同名
// file-scope static 等价（内部 linkage，互不冲突）；保持本视图自持、不反向
// 依赖控制器。
static void MediaPlaybackApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

@interface MediaPlaybackQualityPanelView ()
@property(nonatomic,strong) UIStackView *qualityGroup;
@property(nonatomic,strong) UILabel *qualityLabel;
@property(nonatomic,strong) UIScrollView *qualityScroll;
@property(nonatomic,strong) UIStackView *qualityButtons;
@end

@implementation MediaPlaybackQualityPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.translatesAutoresizingMaskIntoConstraints=NO;
        _qualityGroup=[UIStackView new];_qualityGroup.translatesAutoresizingMaskIntoConstraints=NO;_qualityGroup.axis=UILayoutConstraintAxisVertical;_qualityGroup.spacing=3;[self addSubview:_qualityGroup];
        _qualityLabel=[UILabel new];_qualityLabel.text=@"清晰度";_qualityLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];_qualityLabel.adjustsFontForContentSizeCategory=YES;_qualityLabel.textColor=HostSecondaryText();[_qualityGroup addArrangedSubview:_qualityLabel];
        _qualityScroll=[UIScrollView new];_qualityScroll.translatesAutoresizingMaskIntoConstraints=NO;_qualityScroll.showsHorizontalScrollIndicator=NO;[_qualityGroup addArrangedSubview:_qualityScroll];
        _qualityButtons=[UIStackView new];_qualityButtons.translatesAutoresizingMaskIntoConstraints=NO;_qualityButtons.axis=UILayoutConstraintAxisHorizontal;_qualityButtons.spacing=8;[_qualityScroll addSubview:_qualityButtons];
        // 原 buildQualityButtons 调用点把 qualityGroup 四边钉到自身、qualityScroll
        // 44pt 高与 qualityButtons 五条内部约束写在控制器的 portrait/embedded
        // 约束块里；此处收敛到面板自身，控制器只经 qualityGroup 别名参与外部几何。
        NSLayoutConstraint *qualityScrollHeight=[self.qualityScroll.heightAnchor constraintEqualToConstant:44];qualityScrollHeight.priority=UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [self.qualityGroup.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.qualityGroup.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.qualityGroup.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.qualityGroup.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            qualityScrollHeight,
            [self.qualityButtons.leadingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.leadingAnchor],
            [self.qualityButtons.trailingAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.trailingAnchor],
            [self.qualityButtons.topAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.topAnchor],
            [self.qualityButtons.bottomAnchor constraintEqualToAnchor:self.qualityScroll.contentLayoutGuide.bottomAnchor],
            [self.qualityButtons.heightAnchor constraintEqualToAnchor:self.qualityScroll.frameLayoutGuide.heightAnchor],
        ]];
    }
    return self;
}

- (void)rebuildWithAlternates:(NSArray *)alternates
                 selectedIndex:(NSInteger)selectedIndex
                        target:(id)target
                        action:(SEL)action {
    for(UIView *view in self.qualityButtons.arrangedSubviews.copy){[self.qualityButtons removeArrangedSubview:view];[view removeFromSuperview];}
    BOOL available=alternates.count>0;self.qualityGroup.spacing=available?3:0;self.qualityLabel.hidden=!available;self.qualityScroll.hidden=!available;self.qualityLabel.text=alternates.count==1?@"清晰度（仅此档可用）":@"清晰度";
    if(!available)return;
    for(NSUInteger index=0;index<alternates.count;index++){
        NSDictionary *alternate=[alternates[index] isKindOfClass:NSDictionary.class]?alternates[index]:nil;if(!alternate)continue;NSString *name=[alternate[@"name"] isKindOfClass:NSString.class]?alternate[@"name"]:[NSString stringWithFormat:@"清晰度 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-quality-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.enabled=alternates.count>1;if(!button.enabled)[button setTitleColor:HostText() forState:UIControlStateDisabled];button.accessibilityLabel=name;button.accessibilityHint=alternates.count==1?@"当前资源仅提供这一档可播放清晰度":@"切换到此视频清晰度";HostStylePillButton(button,(NSInteger)index==selectedIndex);HostInstallPressFeedback(button);MediaPlaybackApplyScaledPillFont(button);[button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];[self.qualityButtons addArrangedSubview:button];
    }
}

@end
