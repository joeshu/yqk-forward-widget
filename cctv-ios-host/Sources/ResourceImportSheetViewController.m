#import "ResourceImportSheetViewController.h"

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
    self.backgroundColor=UIColor.whiteColor;
    self.contentView.backgroundColor=UIColor.whiteColor;
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
    _titleLabel.font=[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _titleLabel.textColor=[UIColor colorWithWhite:0.08 alpha:1];
    _titleLabel.translatesAutoresizingMaskIntoConstraints=NO;
    _detailLabel=[UILabel new];
    _detailLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _detailLabel.textColor=[UIColor colorWithWhite:0.48 alpha:1];
    _detailLabel.numberOfLines=2;
    _detailLabel.translatesAutoresizingMaskIntoConstraints=NO;
    UIStackView *labels=[[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel,_detailLabel]];
    labels.axis=UILayoutConstraintAxisVertical;
    labels.spacing=4;
    labels.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentView addSubview:labels];

    UIImageView *chevron=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor=[UIColor colorWithWhite:0.72 alpha:1];
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
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-18],
        [chevron.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12],
        [chevron.heightAnchor constraintEqualToConstant:18]
    ]];
    UIView *separator=[UIView new];
    separator.backgroundColor=[UIColor colorWithWhite:0.91 alpha:1];
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
    self.contentView.backgroundColor=highlighted?[UIColor colorWithWhite:0.94 alpha:1]:UIColor.whiteColor;
}
@end

@interface ResourceImportSheetViewController () <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UITableView *tableView;
@end

@implementation ResourceImportSheetViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleLight;
    self.view.backgroundColor=[UIColor colorWithRed:0.95 green:0.96 blue:0.93 alpha:1];

    UIView *header=[UIView new];
    header.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:header];
    UIView *grabber=[UIView new];
    grabber.backgroundColor=[UIColor colorWithWhite:0.80 alpha:1];
    grabber.layer.cornerRadius=3;
    grabber.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:grabber];
    UILabel *title=[UILabel new];
    title.text=@"添加资源";
    title.font=[UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor=[UIColor colorWithWhite:0.07 alpha:1];
    title.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:title];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor=[UIColor colorWithWhite:0.48 alpha:1];
    close.backgroundColor=[UIColor colorWithWhite:0.91 alpha:1];
    close.layer.cornerRadius=22;
    close.accessibilityLabel=@"关闭添加资源";
    [close addTarget:self action:@selector(closeSheet) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:close];

    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.backgroundColor=self.view.backgroundColor;
    self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource=self;
    self.tableView.delegate=self;
    self.tableView.rowHeight=98;
    self.tableView.sectionHeaderHeight=34;
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
        [header.heightAnchor constraintEqualToConstant:100],
        [grabber.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:58],
        [grabber.heightAnchor constraintEqualToConstant:6],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:24],
        [title.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?3:(section==1?3:1); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"在线导入",@"从本地导入",@"资源管理"][section];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UILabel *label=[UILabel new];
    label.text=[self tableView:tableView titleForHeaderInSection:section];
    label.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textColor=[UIColor colorWithWhite:0.43 alpha:1];
    label.frame=CGRectMake(28,0,tableView.bounds.size.width-56,34);
    return label;
}
- (NSArray<NSDictionary *> *)optionsForSection:(NSInteger)section {
    static NSArray *online,*local,*manage;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        UIColor *(^rgb)(CGFloat,CGFloat,CGFloat)=^UIColor *(CGFloat r,CGFloat g,CGFloat b){return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1];};
        online=@[
            @{ @"title":@"直播频道",@"detail":@"M3U / TXT 直播列表地址",@"icon":@"dot.radiowaves.left.and.right",@"color":rgb(246,151,0),@"option":@(ResourceImportOptionLiveURL)},
            @{ @"title":@"影视 / 插件资源链接",@"detail":@"脚本、ZIP、本机服务包或 .md5 校验地址",@"icon":@"link",@"color":rgb(35,132,238),@"option":@(ResourceImportOptionMediaURL)},
            @{ @"title":@"TVBox 配置",@"detail":@"导入 JSON 目录；支持站点脚本与直播列表",@"icon":@"square.stack.3d.up",@"color":rgb(103,83,222),@"option":@(ResourceImportOptionTVBox)}
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
