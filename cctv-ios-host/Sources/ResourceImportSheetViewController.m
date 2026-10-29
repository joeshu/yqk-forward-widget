#import "ResourceImportSheetViewController.h"
#import "HostTheme.h"

@interface ResourceImportSheetCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon color:(UIColor *)color;
@end

@implementation ResourceImportSheetCell {
    UIView *_iconBackground;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self=[super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if(!self)return nil;
    self.backgroundColor=HostCard();
    self.contentView.backgroundColor=HostCard();
    self.selectionStyle=UITableViewCellSelectionStyleDefault;

    _iconBackground=[UIView new];
    _iconBackground.layer.cornerRadius=26;
    _iconBackground.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentView addSubview:_iconBackground];
    _iconView=[UIImageView new];
    _iconView.contentMode=UIViewContentModeScaleAspectFit;
    _iconView.tintColor=UIColor.whiteColor;
    _iconView.translatesAutoresizingMaskIntoConstraints=NO;
    [_iconBackground addSubview:_iconView];

    _titleLabel=[UILabel new];
    _titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold]];
    _titleLabel.adjustsFontForContentSizeCategory=YES;
    _titleLabel.textColor=HostText();
    _titleLabel.numberOfLines=0;
    _titleLabel.translatesAutoresizingMaskIntoConstraints=NO;
    _detailLabel=[UILabel new];
    _detailLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]];
    _detailLabel.adjustsFontForContentSizeCategory=YES;
    _detailLabel.textColor=HostSecondaryText();
    _detailLabel.numberOfLines=0;
    _detailLabel.translatesAutoresizingMaskIntoConstraints=NO;
    UIStackView *labels=[[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel,_detailLabel]];
    labels.axis=UILayoutConstraintAxisVertical;
    labels.spacing=4;
    labels.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentView addSubview:labels];

    UIImageView *chevron=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor=HostSecondaryText();
    chevron.contentMode=UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentView addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [_iconBackground.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:18],
        [_iconBackground.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconBackground.widthAnchor constraintEqualToConstant:52],
        [_iconBackground.heightAnchor constraintEqualToConstant:52],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconBackground.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconBackground.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24],
        [_iconView.heightAnchor constraintEqualToConstant:24],
        [labels.leadingAnchor constraintEqualToAnchor:_iconBackground.trailingAnchor constant:16],
        [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [labels.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [labels.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
        [chevron.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12],
        [chevron.heightAnchor constraintEqualToConstant:18]
    ]];
    UIView *separator=[UIView new];
    separator.backgroundColor=HostSeparator();
    separator.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentView addSubview:separator];
    [NSLayoutConstraint activateConstraints:@[
        [separator.leadingAnchor constraintEqualToAnchor:labels.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    self.accessoryView=nil;
    return self;
}
- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail icon:(NSString *)icon color:(UIColor *)color {
    _titleLabel.text=title;
    _detailLabel.text=detail;
    _iconView.image=[UIImage systemImageNamed:icon];
    _iconBackground.backgroundColor=color;
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.contentView.backgroundColor=highlighted?HostHighlightedSurface():HostCard();
}
@end

@interface ResourceImportSheetViewController () <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UITableView *tableView;
@end

@implementation ResourceImportSheetViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    UIColor *sheetSurface=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:0.055 green:0.059 blue:0.075 alpha:1]:[UIColor colorWithRed:0.94 green:0.949 blue:0.969 alpha:1];}];
    self.view.backgroundColor=sheetSurface;

    UIView *header=[UIView new];
    header.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:header];
    UIView *grabber=[UIView new];
    grabber.backgroundColor=HostBorder();
    grabber.layer.cornerRadius=3;
    grabber.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:grabber];
    UILabel *title=[UILabel new];
    title.text=@"添加资源";
    title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:[UIFont systemFontOfSize:28 weight:UIFontWeightBold]];
    title.adjustsFontForContentSizeCategory=YES;
    title.textColor=HostText();
    title.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:title];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor=HostSecondaryText();
    close.backgroundColor=HostRaisedSurface();
    close.layer.cornerRadius=22;
    close.accessibilityLabel=@"关闭添加资源";
    [close addTarget:self action:@selector(closeSheet) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:close];

    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.backgroundColor=sheetSurface;
    self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource=self;
    self.tableView.delegate=self;
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=98;
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight=34;
    self.tableView.sectionFooterHeight=14;
    self.tableView.contentInset=UIEdgeInsetsMake(0,0,20,0);
    self.tableView.translatesAutoresizingMaskIntoConstraints=NO;
    [self.tableView registerClass:ResourceImportSheetCell.class forCellReuseIdentifier:@"resource-option"];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintGreaterThanOrEqualToConstant:100],
        [grabber.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:58],
        [grabber.heightAnchor constraintEqualToConstant:6],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [title.topAnchor constraintEqualToAnchor:grabber.bottomAnchor constant:18],
        [title.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-12],
        [close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-22],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor constant:-1],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
        [self.tableView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UISheetPresentationController *sheet=self.sheetPresentationController;
    if(sheet){
        sheet.detents=@[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible=NO;
        sheet.preferredCornerRadius=30;
        sheet.largestUndimmedDetentIdentifier=nil;
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?4:(section==1?3:1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"在线导入",@"从本地导入",@"资源管理"][section];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UILabel *label=[UILabel new];
    label.text=[self tableView:tableView titleForHeaderInSection:section];
    label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    label.adjustsFontForContentSizeCategory=YES;
    label.textColor=HostSecondaryText();
    label.numberOfLines=0;label.translatesAutoresizingMaskIntoConstraints=NO;
    UIView *container=[UIView new];[container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:28],[label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24],[label.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],[label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4]]];
    return container;
}
- (NSArray<NSDictionary *> *)optionsForSection:(NSInteger)section {
    static NSArray *online,*local,*manage;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        UIColor *(^rgb)(CGFloat,CGFloat,CGFloat)=^UIColor *(CGFloat r,CGFloat g,CGFloat b){return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];};
        online=@[
            @{ @"title":@"直播频道",@"detail":@"M3U / TXT 直播列表地址",@"icon":@"dot.radiowaves.left.and.right",@"color":rgb(246,151,0),@"option":@(ResourceImportOptionLiveURL)},
            @{ @"title":@"影视 / 猫源 / 插件链接",@"detail":@"JS、.js.md5 猫源、Python 或 ZIP 资源包",@"icon":@"link",@"color":rgb(35,132,238),@"option":@(ResourceImportOptionMediaURL)},
            @{ @"title":@"TVBox 配置",@"detail":@"导入 JSON 目录；支持站点脚本与直播列表",@"icon":@"square.stack.3d.up",@"color":rgb(103,83,222),@"option":@(ResourceImportOptionTVBox)},
            @{ @"title":@"MacCMS 影视接口",@"detail":@"直接添加 JSON / XML 采集接口，不需要脚本运行时",@"icon":@"film",@"color":rgb(197,67,147),@"option":@(ResourceImportOptionMacCMS)}
        ];
        local=@[
            @{ @"title":@"导入直播列表文件",@"detail":@"本地 M3U / M3U8 / TXT 频道列表",@"icon":@"dot.radiowaves.left.and.right",@"color":rgb(246,151,0),@"option":@(ResourceImportOptionLiveFile)},
            @{ @"title":@"导入脚本或 ZIP 包",@"detail":@"导入后检查入口、运行环境和影视 / 直播能力",@"icon":@"doc.zipper",@"color":rgb(92,83,218),@"option":@(ResourceImportOptionMediaFile)},
            @{ @"title":@"导入 TVBox JSON",@"detail":@"从本地导入配置文件，不会覆盖现有目录",@"icon":@"doc.text",@"color":rgb(103,83,222),@"option":@(ResourceImportOptionTVBox)}
        ];
        manage=@[
            @{ @"title":@"脚本与服务",@"detail":@"查看、启用和管理已导入的影视插件",@"icon":@"slider.horizontal.3",@"color":rgb(229,43,105),@"option":@(ResourceImportOptionServices)}
        ];
    });
    return @[online,local,manage][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ResourceImportSheetCell *cell=[tableView dequeueReusableCellWithIdentifier:@"resource-option" forIndexPath:indexPath];
    NSDictionary *item=[self optionsForSection:indexPath.section][indexPath.row];
    [cell configureWithTitle:item[@"title"] detail:item[@"detail"] icon:item[@"icon"] color:item[@"color"]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSNumber *storedOption=[self optionsForSection:indexPath.section][indexPath.row][@"option"];
    ResourceImportOption option=(ResourceImportOption)storedOption.integerValue;
    void (^selection)(ResourceImportOption)=self.onSelect;
    [self dismissViewControllerAnimated:YES completion:^{if(selection)selection(option);}];
}
- (void)closeSheet { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
