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
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    UIColor *sheetSurface=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:0.055 green:0.059 blue:0.075 alpha:1]:[UIColor colorWithRed:0.94 green:0.949 blue:0.969 alpha:1];}];
    self.view.backgroundColor=sheetSurface;

    UIView *header=[UIView new];
    header.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:header];
    UILabel *title=[UILabel new];
    title.text=@"按类型选择导入方式";
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
    close.accessibilityIdentifier=@"resource-import.close";
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
    self.tableView.sectionFooterHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedSectionFooterHeight=34;
    self.tableView.contentInset=UIEdgeInsetsMake(0,0,20,0);
    self.tableView.translatesAutoresizingMaskIntoConstraints=NO;
    [self.tableView registerClass:ResourceImportSheetCell.class forCellReuseIdentifier:@"resource-option"];
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintGreaterThanOrEqualToConstant:76],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:14],
        [title.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-12],
        [close.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-22],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor constant:-1],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],
        [self.tableView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];

}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self optionsForSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"已导入服务",@"在线资源",@"从本地导入"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return @"管理已导入的本机影视与直播服务。";
    if(section==1)return @"支持导入 TVBox 配置、影视接口、脚本资源和 M3U / TXT 直播订阅。";
    return @"ZIP 会校验入口、相对路径、大小和声明后再保存；导入阶段不会执行插件代码。";
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
    static NSArray *servers,*video,*local;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        UIColor *(^rgb)(CGFloat,CGFloat,CGFloat)=^UIColor *(CGFloat r,CGFloat g,CGFloat b){return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];};
        servers=@[
            @{ @"id":@"services",@"title":@"脚本与服务",@"detail":@"查看、启动和管理本机影视 / 直播服务",@"icon":@"slider.horizontal.3",@"color":rgb(229,43,105),@"option":@(ResourceImportOptionServices)}
        ];
        video=@[
            @{ @"id":@"tvbox-url",@"title":@"TVBox 影视源",@"detail":@"粘贴配置地址，解析 JSON 后逐站点识别",@"icon":@"square.stack.3d.up",@"color":rgb(229,43,105),@"option":@(ResourceImportOptionTVBox)},
            @{ @"id":@"live-url",@"title":@"直播频道",@"detail":@"M3U / TXT 直播订阅地址",@"icon":@"dot.radiowaves.left.and.right",@"color":rgb(246,151,0),@"option":@(ResourceImportOptionLiveURL)},
            @{ @"id":@"script-auto-url",@"title":@"影视 / 合集链接 · 自动识别",@"detail":@"TVBox JSON 与 iOS 合集地址，也支持 JS、Python、ZIP、.md5",@"icon":@"sparkles",@"color":rgb(35,132,238),@"option":@(ResourceImportOptionMediaURL)},
            @{ @"id":@"python-url",@"title":@"Python Spider 链接",@"detail":@"TVBox .py Spider；由内置 CPython 启动",@"icon":@"chevron.left.forwardslash.chevron.right",@"color":rgb(54,137,91),@"option":@(ResourceImportOptionPythonURL)},
            @{ @"id":@"catvod-url",@"title":@"CatVod / TVBox JS 链接",@"detail":@"CatVod、DRPY 与 .js.md5；检查协议和入口",@"icon":@"film.stack",@"color":rgb(103,83,222),@"option":@(ResourceImportOptionCatVodURL)},
            @{ @"id":@"node-url",@"title":@"Node.js Mobile 链接",@"detail":@"Node 18.20.4；支持动态 require 与内置模块",@"icon":@"shippingbox",@"color":rgb(75,102,186),@"option":@(ResourceImportOptionNodeURL)},
            @{ @"id":@"maccms-url",@"title":@"MacCMS 影视接口",@"detail":@"JSON / XML 采集 API，不依赖脚本运行时",@"icon":@"film",@"color":rgb(197,67,147),@"option":@(ResourceImportOptionMacCMS)}
        ];
        local=@[
            @{ @"id":@"live-file",@"title":@"导入直播列表文件",@"detail":@"本地 M3U / M3U8 / TXT 频道列表",@"icon":@"dot.radiowaves.left.and.right",@"color":rgb(246,151,0),@"option":@(ResourceImportOptionLiveFile)},
            @{ @"id":@"folder-import",@"title":@"导入文件夹里的源",@"detail":@"扫描并批量识别 JS / Python / ZIP、TVBox JSON 与直播列表",@"icon":@"folder.badge.plus",@"color":rgb(45,127,164),@"option":@(ResourceImportOptionFolder)},
            @{ @"id":@"script-auto-file",@"title":@"导入脚本 / ZIP · 自动识别",@"detail":@"检查入口、运行环境、协议和校验文件",@"icon":@"doc.zipper",@"color":rgb(92,83,218),@"option":@(ResourceImportOptionMediaFile)},
            @{ @"id":@"python-file",@"title":@"导入 Python Spider 文件",@"detail":@"选择 .py；按 Spider 接口识别影视能力",@"icon":@"chevron.left.forwardslash.chevron.right",@"color":rgb(54,137,91),@"option":@(ResourceImportOptionPythonFile)},
            @{ @"id":@"node-file",@"title":@"导入 Node.js Mobile 脚本 / ZIP",@"detail":@"显式选 Node 运行时，支持动态 Node 模块引用",@"icon":@"shippingbox",@"color":rgb(75,102,186),@"option":@(ResourceImportOptionNodeFile)},
            @{ @"id":@"tvbox-file",@"title":@"导入 TVBox JSON",@"detail":@"本地导入配置目录，不覆盖现有目录",@"icon":@"doc.text",@"color":rgb(103,83,222),@"option":@(ResourceImportOptionTVBoxFile)},
            @{ @"id":@"host-capabilities",@"title":@"宿主运行能力与调用示例",@"detail":@"Python AES-CTR、Node HTTP、播放超时与识别规则",@"icon":@"wrench.and.screwdriver",@"color":rgb(45,127,164),@"option":@(ResourceImportOptionHostCapabilities)}
        ];
    });
    if(section<0||section>=3)return @[];
    return @[servers,video,local][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ResourceImportSheetCell *cell=[tableView dequeueReusableCellWithIdentifier:@"resource-option" forIndexPath:indexPath];
    NSArray *options=[self optionsForSection:indexPath.section];if(indexPath.row<0||indexPath.row>=options.count)return cell;
    NSDictionary *item=options[indexPath.row];
    [cell configureWithTitle:item[@"title"] detail:item[@"detail"] icon:item[@"icon"] color:item[@"color"]];
    cell.accessibilityIdentifier=[@"resource-import.option." stringByAppendingString:item[@"id"]?:@"unknown"];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *options=[self optionsForSection:indexPath.section];if(indexPath.row<0||indexPath.row>=options.count)return;
    NSNumber *storedOption=options[indexPath.row][@"option"];
    ResourceImportOption option=(ResourceImportOption)storedOption.integerValue;
    void (^selection)(ResourceImportOption)=self.onSelect;
    [self dismissViewControllerAnimated:YES completion:^{if(selection)selection(option);}];
}
- (void)closeSheet { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
