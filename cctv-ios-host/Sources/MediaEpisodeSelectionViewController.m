#import "MediaEpisodeSelectionViewController.h"
#import "MediaAPIClient.h"
#import "HostTheme.h"
#import "MediaEpisodeLayout.h"
#import "RuntimeDiagnostics.h"

// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
static void MediaEpisodeApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

@interface MediaEpisodeSelectionViewController ()
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UIStackView *routeButtons;
@property(nonatomic,strong) UIStackView *episodeGrid;
@property(nonatomic,strong) NSMutableArray<UIButton *> *episodeButtons;
@property(nonatomic,strong) UILabel *pageLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIButton *previousButton;
@property(nonatomic,strong) UIButton *nextButton;
@property(nonatomic,strong) UIButton *reverseButton;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL episodeOrderReversed;
- (void)selectRoute:(UIButton *)sender;
- (void)selectEpisode:(UIButton *)sender;
@end

@implementation MediaEpisodeSelectionViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (NSArray *)episodesForLine:(NSInteger)index {
    NSArray *lines=self.lines;if(index<0||index>=lines.count)return @[];
    NSArray *episodes=[lines[index][@"episodes"] isKindOfClass:NSArray.class]?lines[index][@"episodes"]:@[];return episodes;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"选择线路和剧集";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.scrollEnabled=NO;
    self.selectedLineIndex=MAX(0,self.selectedLineIndex);self.selectedEpisodeIndex=MAX(0,self.selectedEpisodeIndex);self.episodeButtons=[NSMutableArray array];if(!self.correlationID.length)self.correlationID=NSUUID.UUID.UUIDString.lowercaseString;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,[self episodesForLine:self.selectedLineIndex].count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setTitle:@"‹" forState:UIControlStateNormal];back.titleLabel.font=[UIFont systemFontOfSize:32 weight:UIFontWeightMedium];back.titleLabel.adjustsFontForContentSizeCategory=NO;back.titleEdgeInsets=UIEdgeInsetsMake(-3,0,0,0);back.tintColor=HostAccent();HostStyleGlassCard(back,14);HostInstallPressFeedback(back);back.accessibilityLabel=@"返回";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
    self.navigationItem.prompt=self.lines.count?[NSString stringWithFormat:@"%@ · 选择要播放的分集",self.detail[@"name"]?:self.item[@"name"]?:@"影片"]:@"此影片没有可用分集";
    [self buildLayout];[self rebuildSelection];
}
- (void)dealloc {[self.client cancel];}
- (void)goBack {[self.navigationController popViewControllerAnimated:YES];}
- (UILabel *)heading:(NSString *)text {
    UILabel *label=[UILabel new];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];label.adjustsFontForContentSizeCategory=YES;label.textColor=HostText();label.text=text;return label;
}
- (void)buildLayout {
    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=14;self.contentStack.layoutMargins=UIEdgeInsetsMake(14,16,26,16);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[[self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],[self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],[self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],[self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]]];
    UILabel *name=[self heading:self.detail[@"name"]?:self.item[@"name"]?:@"影片"];name.numberOfLines=2;[self.contentStack addArrangedSubview:name];
    [self.contentStack addArrangedSubview:[self heading:@"播放线路"]];UIScrollView *lineScroll=[UIScrollView new];lineScroll.translatesAutoresizingMaskIntoConstraints=NO;lineScroll.showsHorizontalScrollIndicator=NO;[self.contentStack addArrangedSubview:lineScroll];
    self.routeButtons=[UIStackView new];self.routeButtons.translatesAutoresizingMaskIntoConstraints=NO;self.routeButtons.axis=UILayoutConstraintAxisHorizontal;self.routeButtons.spacing=8;[lineScroll addSubview:self.routeButtons];
    [NSLayoutConstraint activateConstraints:@[[lineScroll.heightAnchor constraintGreaterThanOrEqualToConstant:44],[self.routeButtons.leadingAnchor constraintEqualToAnchor:lineScroll.contentLayoutGuide.leadingAnchor],[self.routeButtons.trailingAnchor constraintEqualToAnchor:lineScroll.contentLayoutGuide.trailingAnchor],[self.routeButtons.topAnchor constraintEqualToAnchor:lineScroll.contentLayoutGuide.topAnchor],[self.routeButtons.bottomAnchor constraintEqualToAnchor:lineScroll.contentLayoutGuide.bottomAnchor],[self.routeButtons.heightAnchor constraintEqualToAnchor:lineScroll.frameLayoutGuide.heightAnchor]]];
    [self.contentStack addArrangedSubview:[self heading:@"选择分集"]];
    self.pageLabel=[UILabel new];self.pageLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.pageLabel.adjustsFontForContentSizeCategory=YES;self.pageLabel.textColor=HostSecondaryText();[self.contentStack addArrangedSubview:self.pageLabel];
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.spacing=8;self.reverseButton=[UIButton buttonWithType:UIButtonTypeSystem];self.previousButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.previousButton setTitle:@"上一组" forState:UIControlStateNormal];[self.nextButton setTitle:@"下一组" forState:UIControlStateNormal];HostStylePillButton(self.reverseButton,NO);HostStylePillButton(self.previousButton,NO);HostStylePillButton(self.nextButton,NO);MediaEpisodeApplyScaledPillFont(self.reverseButton);MediaEpisodeApplyScaledPillFont(self.previousButton);MediaEpisodeApplyScaledPillFont(self.nextButton);[self.reverseButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[self.previousButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[self.nextButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[self.reverseButton addTarget:self action:@selector(toggleEpisodeOrder) forControlEvents:UIControlEventTouchUpInside];[self.previousButton addTarget:self action:@selector(previousPage) forControlEvents:UIControlEventTouchUpInside];[self.nextButton addTarget:self action:@selector(nextPage) forControlEvents:UIControlEventTouchUpInside];[paging addArrangedSubview:self.reverseButton];[paging addArrangedSubview:self.previousButton];[paging addArrangedSubview:self.nextButton];[self.contentStack addArrangedSubview:paging];
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=8;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-episode-grid";[self.contentStack addArrangedSubview:self.episodeGrid];
    self.statusLabel=[UILabel new];self.statusLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.statusLabel.adjustsFontForContentSizeCategory=YES;self.statusLabel.textColor=HostSecondaryText();self.statusLabel.numberOfLines=0;[self.contentStack addArrangedSubview:self.statusLabel];
}
- (void)rebuildSelection {
    for(UIView *button in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:button];[button removeFromSuperview];}
    if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    for(NSUInteger index=0;index<self.lines.count;index++){
        NSDictionary *line=self.lines[index];NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-route-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];HostStylePillButton(button,index==self.selectedLineIndex);MediaEpisodeApplyScaledPillFont(button);[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];[self.routeButtons addArrangedSubview:button];
    }
    NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;NSUInteger pages=MAX(1,(episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup);self.page=MIN(self.page,(NSInteger)pages-1);NSUInteger start=(NSUInteger)self.page*CCTVEpisodesPerGroup,end=MIN(start+CCTVEpisodesPerGroup,episodes.count);
    NSUInteger firstSource=end>start?CCTVEpisodeSourceIndex(start,episodes.count,self.episodeOrderReversed):0,lastSource=end>start?CCTVEpisodeSourceIndex(end-1,episodes.count,self.episodeOrderReversed):0;
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 组 · 第 %lu–%lu 集 · %@",(long)self.page+1,(unsigned long)pages,(unsigned long)firstSource+1,(unsigned long)lastSource+1,self.episodeOrderReversed?@"倒序":@"正序"]:@"当前线路没有可选分集";
    if(!self.lines.count)self.statusLabel.text=@"此影片没有可用分集，请返回详情页重新加载或更换来源。";else if(!episodes.count)self.statusLabel.text=@"当前线路没有可选分集，请切换其他线路。";else self.statusLabel.text=@"";
    [self.reverseButton setTitle:self.episodeOrderReversed?@"正序":@"倒序" forState:UIControlStateNormal];self.reverseButton.accessibilityLabel=self.episodeOrderReversed?@"按正序排列分集，当前为倒序":@"按倒序排列分集，当前为正序";self.reverseButton.hidden=episodes.count<2;
    self.previousButton.hidden=pages<=1;self.nextButton.hidden=pages<=1;self.previousButton.enabled=self.page>0;self.nextButton.enabled=self.page+1<pages;
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];
    NSUInteger columns=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?3:4;
    for(NSUInteger rowIndex=0;rowIndex*columns<end-start;rowIndex++){
        UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=7;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<columns;col++){
            NSUInteger displayIndex=start+rowIndex*columns+col;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.layer.cornerRadius=14;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            if(displayIndex<end){NSUInteger index=CCTVEpisodeSourceIndex(displayIndex,episodes.count,self.episodeOrderReversed);NSDictionary *episode=episodes[index];[button setTitle:episode[@"name"]?:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1] forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-item-%lu",(unsigned long)index];button.accessibilityLabel=[NSString stringWithFormat:@"%@，第 %lu 集",episode[@"name"]?:@"分集",(unsigned long)index+1];HostStylePillButton(button,self.selectionUpdatesPlayer&&(NSInteger)index==self.selectedEpisodeIndex);button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];}else{button.hidden=YES;}
            [row addArrangedSubview:button];
        }
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
}
- (void)selectRoute:(UIButton *)sender {self.generation++;[self.client cancel];NSInteger line=MAX(0,sender.tag);if(self.lines.count)line=MIN(line,(NSInteger)self.lines.count-1);self.selectedLineIndex=line;self.selectedEpisodeIndex=0;self.page=0;self.statusLabel.text=@"";[self rebuildSelection];}
- (void)toggleEpisodeOrder {NSArray *episodes=[self episodesForLine:self.selectedLineIndex];self.episodeOrderReversed=!self.episodeOrderReversed;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,self.selectedEpisodeIndex),episodes.count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;[RuntimeDiagnostics.shared recordEvent:@"media_episode_order_changed" category:@"playback" fields:@{@"correlation_id":self.correlationID?:@"",@"line_index":@(self.selectedLineIndex),@"episode_count":@(episodes.count),@"selected_episode_index":@(self.selectedEpisodeIndex),@"reversed":@(self.episodeOrderReversed)}];[self rebuildSelection];}
- (void)previousPage {if(self.page>0){self.page--;[self rebuildSelection];}}
- (void)nextPage {NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.page+1<(NSInteger)((episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup)){self.page++;[self rebuildSelection];}}
- (void)selectEpisode:(UIButton *)sender {
    if(self.selectedLineIndex<0||self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(sender.tag<0||sender.tag>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[sender.tag];self.selectedEpisodeIndex=sender.tag;NSInteger capturedLineIndex=self.selectedLineIndex,capturedEpisodeIndex=sender.tag;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,episodes.count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;[self rebuildSelection];NSUInteger generation=++self.generation;self.statusLabel.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.correlationID?:@"", @"request_generation":@(generation), @"line_index":@(capturedLineIndex), @"episode_index":@(capturedEpisodeIndex)}];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.correlationID completion:^(id result,NSError *error){MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.statusLabel.text=@"";
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"", @"request_generation":@(generation), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.statusLabel.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"", @"request_generation":@(generation)}];NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"lineIndex":@(capturedLineIndex),@"episodeIndex":@(capturedEpisodeIndex),@"correlationID":owner.correlationID?:@""};
        if(owner.onSelectEpisode)owner.onSelectEpisode(result,context);if(owner.selectionUpdatesPlayer&&owner.navigationController.topViewController==owner)[owner.navigationController popViewControllerAnimated:YES];
    }];
}
@end
