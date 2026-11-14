#import "LocalMediaViewController.h"
#import "LocalMediaStore.h"
#import "MediaPlaybackViewController.h"
#import "HostTheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LocalMediaViewController () <UIDocumentPickerDelegate>
@property(nonatomic,strong) LocalMediaStore *store;
@property(nonatomic,copy) NSArray<NSURL *> *files;
@property(nonatomic,strong) UIView *progressHeader;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) UIButton *stopButton;
@end

@implementation LocalMediaViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.store=LocalMediaStore.shared;self.title=@"本地媒体";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=72;self.tableView.backgroundColor=HostBackground();
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importMedia)];
    self.progressHeader=[UIView new];self.progressHeader.backgroundColor=HostCard();self.progressHeader.layer.cornerRadius=14;self.progressLabel=[UILabel new];self.progressLabel.translatesAutoresizingMaskIntoConstraints=NO;self.progressLabel.numberOfLines=0;self.progressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.progressLabel.adjustsFontForContentSizeCategory=YES;self.progressLabel.textColor=HostText();
    self.stopButton=[UIButton buttonWithType:UIButtonTypeSystem];self.stopButton.translatesAutoresizingMaskIntoConstraints=NO;[self.stopButton setTitle:@"停止" forState:UIControlStateNormal];self.stopButton.accessibilityLabel=@"停止后续导入";self.stopButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.stopButton.titleLabel.adjustsFontForContentSizeCategory=YES;[self.stopButton addTarget:self action:@selector(stopImport) forControlEvents:UIControlEventTouchUpInside];[self.progressHeader addSubview:self.progressLabel];[self.progressHeader addSubview:self.stopButton];[NSLayoutConstraint activateConstraints:@[[self.progressLabel.leadingAnchor constraintEqualToAnchor:self.progressHeader.leadingAnchor constant:14],[self.progressLabel.topAnchor constraintEqualToAnchor:self.progressHeader.topAnchor constant:10],[self.progressLabel.bottomAnchor constraintEqualToAnchor:self.progressHeader.bottomAnchor constant:-10],[self.progressLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.stopButton.leadingAnchor constant:-8],[self.stopButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],[self.stopButton.trailingAnchor constraintEqualToAnchor:self.progressHeader.trailingAnchor constant:-10],[self.stopButton.centerYAnchor constraintEqualToAnchor:self.progressHeader.centerYAnchor],[self.stopButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeDidChange:) name:LocalMediaStoreDidChangeNotification object:self.store];[self updateFromStore];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];[self updateFromStore];}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];if(self.tableView.tableHeaderView==self.progressHeader)[self updateProgressHeaderSize];}
- (void)updateProgressHeaderSize {CGFloat width=self.tableView.bounds.size.width;if(width<=0)return;CGRect frame=self.progressHeader.frame;frame.size.width=width;self.progressHeader.frame=frame;[self.progressHeader setNeedsLayout];[self.progressHeader layoutIfNeeded];CGSize fitting=[self.progressHeader systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];CGFloat height=MAX(62,fitting.height);if(fabs(self.progressHeader.frame.size.height-height)>0.5){frame.size.height=height;self.progressHeader.frame=frame;self.tableView.tableHeaderView=self.progressHeader;}}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.progressHeader.backgroundColor=HostCard();self.progressLabel.textColor=HostText();[self.tableView reloadData];}
- (NSString *)displayNameForURL:(NSURL *)url {NSString *name=url.lastPathComponent?:@"媒体文件";if(name.length>37&&[name characterAtIndex:36]=='-')return [name substringFromIndex:37];return name;}
- (void)updateFromStore {
    self.files=[self.store filesSnapshot];NSDictionary *state=[self.store stateSnapshot];BOOL importing=[state[@"importing"] boolValue],stopping=[state[@"stopRequested"] boolValue];self.navigationItem.rightBarButtonItem.enabled=!importing;
    if(importing){NSString *name=[state[@"currentFileName"] isKindOfClass:NSString.class]?state[@"currentFileName"]:@"";NSString *line=[NSString stringWithFormat:@"正在保存：%@\n已完成 %lu/%lu 个文件",name,(unsigned long)[state[@"completed"] unsignedIntegerValue],(unsigned long)[state[@"total"] unsignedIntegerValue]];self.progressLabel.text=line;self.stopButton.hidden=stopping;self.stopButton.enabled=!stopping;self.tableView.tableHeaderView=self.progressHeader;[self updateProgressHeaderSize];self.navigationItem.prompt=stopping?@"停止请求已收到 · 当前文件完成后结束":@"导入过程中仍可播放已完成文件";
    }else{self.tableView.tableHeaderView=nil;NSUInteger failed=[state[@"failureCount"] unsignedIntegerValue];if(failed)self.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件未能保存；请重新选择",(unsigned long)failed];else if(stopping)self.navigationItem.prompt=[NSString stringWithFormat:@"已停止后续导入 · 已完成 %lu/%lu 个文件",(unsigned long)[state[@"completed"] unsignedIntegerValue],(unsigned long)[state[@"total"] unsignedIntegerValue]];else self.navigationItem.prompt=self.files.count?@"点击播放 · 左滑删除本机副本":@"添加视频或音频；文件会复制到本机";}
    [self.tableView reloadData];
}
- (void)storeDidChange:(NSNotification *)notification {[self updateFromStore];}
- (void)importMedia {
    if([[self.store stateSnapshot][@"importing"] boolValue]){self.navigationItem.prompt=@"已有导入任务进行中";return;}
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie,UTTypeAudio,UTTypeAudiovisualContent] asCopy:NO];picker.delegate=self;picker.allowsMultipleSelection=YES;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count)return;[self.store importURLs:urls completion:^(NSArray<NSURL *> *imported,NSArray<NSDictionary<NSString *,NSString *> *> *failures){[self updateFromStore];if(failures.count)self.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件未能保存，请检查访问权限或可用空间",(unsigned long)failures.count];else if(imported.count)self.navigationItem.prompt=[NSString stringWithFormat:@"已保存 %lu 个本机副本",(unsigned long)imported.count];}];[self updateFromStore];
}
- (void)stopImport {[self.store stopAfterCurrentFile];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.files.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"local"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"local"];NSURL *url=self.files[path.row];NSString *name=[self displayNameForURL:url];NSNumber *size=nil;[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];NSString *kind=[url.pathExtension.lowercaseString isEqualToString:@"mp3"]||[url.pathExtension.lowercaseString isEqualToString:@"m4a"]?@"音频文件":@"视频文件";cell.textLabel.text=name;cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",kind,[NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];cell.textLabel.numberOfLines=2;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.accessibilityIdentifier=[@"local-media:" stringByAppendingString:url.lastPathComponent];return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];NSURL *url=self.files[path.row];NSString *name=[self displayNameForURL:url];MediaPlaybackViewController *page=[MediaPlaybackViewController new];page.title=name;page.context=@{@"localMedia":@YES,@"source":@{@"id":@"local-media",@"name":@"本地媒体"},@"item":@{@"name":name,@"id":url.absoluteString},@"detail":@{@"name":name,@"id":url.absoluteString}};page.result=@{@"url":url.absoluteString,@"directMedia":@YES};[self.navigationController pushViewController:page animated:YES];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {if(style!=UITableViewCellEditingStyleDelete||path.row>=self.files.count)return;NSURL *url=self.files[path.row];[self.store deleteFileAtURL:url completion:^(BOOL removed,NSError *error){[self updateFromStore];if(!removed)self.navigationItem.prompt=error.localizedDescription?:@"无法删除本机副本";}];}
@end
