#import "MediaEpisodeSelectionViewController.h"
#import "MediaAPIClient.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"

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
@property(nonatomic) NSInteger page;
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
    self.selectedLineIndex=MAX(0,self.selectedLineIndex);self.selectedEpisodeIndex=MAX(0,self.selectedEpisodeIndex);self.episodeButtons=[NSMutableArray array];if(!self.correlationID.length)self.correlationID=NSUUID.UUID.UUIDString.lowercaseString;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];back.tintColor=HostText();HostStyleGlassCard(back,14);HostInstallPressFeedback(back);back.accessibilityLabel=@"返回";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
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
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.spacing=10;self.previousButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.previousButton setTitle:@"上一页" forState:UIControlStateNormal];[self.nextButton setTitle:@"下一页" forState:UIControlStateNormal];HostStylePillButton(self.previousButton,NO);HostStylePillButton(self.nextButton,NO);[self.previousButton addTarget:self action:@selector(previousPage) forControlEvents:UIControlEventTouchUpInside];[self.nextButton addTarget:self action:@selector(nextPage) forControlEvents:UIControlEventTouchUpInside];[paging addArrangedSubview:self.previousButton];[paging addArrangedSubview:self.nextButton];[self.contentStack addArrangedSubview:paging];
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=8;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-episode-grid";[self.contentStack addArrangedSubview:self.episodeGrid];
    self.statusLabel=[UILabel new];self.statusLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.statusLabel.adjustsFontForContentSizeCategory=YES;self.statusLabel.textColor=HostSecondaryText();self.statusLabel.numberOfLines=0;[self.contentStack addArrangedSubview:self.statusLabel];
}
- (void)rebuildSelection {
    for(UIView *button in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:button];[button removeFromSuperview];}
    if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    for(NSUInteger index=0;index<self.lines.count;index++){
        NSDictionary *line=self.lines[index];NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-route-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];HostStylePillButton(button,index==self.selectedLineIndex);[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];[self.routeButtons addArrangedSubview:button];
    }
    NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;NSUInteger pages=MAX(1,(episodes.count+11)/12);self.page=MIN(self.page,(NSInteger)pages-1);NSUInteger start=(NSUInteger)self.page*12,end=MIN(start+12,episodes.count);
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 页  ·  第 %lu–%lu 集",(long)self.page+1,(unsigned long)pages,(unsigned long)start+1,(unsigned long)end]:@"当前线路没有可选分集";
    self.previousButton.hidden=pages<=1;self.nextButton.hidden=pages<=1;self.previousButton.enabled=self.page>0;self.nextButton.enabled=self.page+1<pages;
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];
    for(NSUInteger rowIndex=0;rowIndex<4&&start+rowIndex*3<end;rowIndex++){
        UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=8;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<3;col++){
            NSUInteger index=start+rowIndex*3+col;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            if(index<end){NSDictionary *episode=episodes[index];[button setTitle:episode[@"name"]?:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1] forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-item-%lu",(unsigned long)index];HostStylePillButton(button,self.selectionUpdatesPlayer&&(NSInteger)index==self.selectedEpisodeIndex);[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];}else{button.hidden=YES;}
            [row addArrangedSubview:button];
        }
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
}
- (void)selectRoute:(UIButton *)sender {self.generation++;[self.client cancel];self.selectedLineIndex=sender.tag;self.selectedEpisodeIndex=0;self.page=0;self.statusLabel.text=@"";[self rebuildSelection];}
- (void)previousPage {if(self.page>0){self.page--;[self rebuildSelection];}}
- (void)nextPage {NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.page+1<(NSInteger)(episodes.count+11)/12){self.page++;[self rebuildSelection];}}
- (void)selectEpisode:(UIButton *)sender {
    if(self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(sender.tag>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[sender.tag];self.selectedEpisodeIndex=sender.tag;[self rebuildSelection];NSUInteger generation=++self.generation;self.statusLabel.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.correlationID?:@"", @"request_generation":@(generation), @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex)}];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.correlationID completion:^(id result,NSError *error){MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.statusLabel.text=@"";
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"", @"request_generation":@(generation), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.statusLabel.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"", @"request_generation":@(generation)}];NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"lineIndex":@(owner.selectedLineIndex),@"episodeIndex":@(owner.selectedEpisodeIndex),@"correlationID":owner.correlationID?:@""};
        if(owner.onSelectEpisode)owner.onSelectEpisode(result,context);if(owner.selectionUpdatesPlayer&&owner.navigationController.topViewController==owner)[owner.navigationController popViewControllerAnimated:YES];
    }];
}
@end
