#import "ResourceImportWorkflowViewController.h"
#import "HostTheme.h"
#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import "ResourceImportSheetViewController.h"
#import "TVBoxCatalogStore.h"
#import "ServiceStore.h"
#import "M3UParser.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSData *ResourceImportReadBounded(NSURL *url,NSUInteger limit) {
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:NULL];NSData *data=nil;
    @try{data=[file readDataUpToLength:limit+1 error:NULL];if(data.length>limit)data=nil;}@catch(NSException *exception){data=nil;}@finally{[file closeAndReturnError:NULL];}return data;
}

static NSURL *ResourceImportSnapshotURL(void) {
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory=[support stringByAppendingPathComponent:@"CCTVHost/ImportTasks"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"workflow-v1.plist"]];
}
static dispatch_queue_t ResourceImportSnapshotQueue(void) {
    static dispatch_queue_t queue;static dispatch_once_t once;dispatch_once(&once,^{queue=dispatch_queue_create("com.cctvhost.resource-import-snapshot",DISPATCH_QUEUE_SERIAL);});return queue;
}
static id ResourceImportFrozenPropertyList(id value) {
    if(!value||value==NSNull.null)return nil;
    if([value isKindOfClass:NSString.class]||[value isKindOfClass:NSNumber.class]||[value isKindOfClass:NSData.class]||[value isKindOfClass:NSDate.class])return [value copy];
    if([value isKindOfClass:NSURL.class])return [value absoluteString];
    if([value isKindOfClass:NSArray.class]){NSMutableArray *rows=[NSMutableArray array];for(id item in value){id frozen=ResourceImportFrozenPropertyList(item);if(frozen)[rows addObject:frozen];}return rows.copy;}
    if([value isKindOfClass:NSDictionary.class]){NSMutableDictionary *rows=[NSMutableDictionary dictionary];for(id key in value){if(![key isKindOfClass:NSString.class])continue;id frozen=ResourceImportFrozenPropertyList(value[key]);if(frozen)rows[key]=frozen;}return rows.copy;}
    return nil;
}
static NSDictionary *ResourceImportReadSnapshot(void) {
    NSData *data=[NSData dataWithContentsOfURL:ResourceImportSnapshotURL() options:NSDataReadingMappedIfSafe error:NULL];if(!data.length||data.length>80*1024*1024)return nil;
    id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    return [value isKindOfClass:NSDictionary.class]&&[value[@"version"] integerValue]==1?value:nil;
}
static void ResourceImportWriteSnapshot(NSDictionary *snapshot) {
    NSURL *url=ResourceImportSnapshotURL();
    if(!snapshot.count){[NSFileManager.defaultManager removeItemAtURL:url error:NULL];return;}
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:snapshot format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];if(data.length&&data.length<=80*1024*1024)[data writeToURL:url options:NSDataWritingAtomic error:NULL];
}

static NSDictionary *ResourceCatalogDiff(NSArray *oldRows,NSArray *newRows,NSArray<NSString *> *identityFields,NSArray<NSString *> *compareFields) {
    NSMutableDictionary *oldByID=[NSMutableDictionary dictionary],*newByID=[NSMutableDictionary dictionary];NSMutableDictionary *oldCounts=[NSMutableDictionary dictionary],*newCounts=[NSMutableDictionary dictionary];
    for(NSDictionary *row in oldRows){NSString *base=nil;for(NSString *field in identityFields)if([row[field] isKindOfClass:NSString.class]&&[row[field] length]){base=[NSString stringWithFormat:@"%@:%@",field,row[field]];break;}if(!base)base=[NSString stringWithFormat:@"row:%@",row[@"sourceIndex"]?:@(oldByID.count)];NSUInteger n=[oldCounts[base] unsignedIntegerValue];oldCounts[base]=@(n+1);oldByID[[NSString stringWithFormat:@"%@#%lu",base,(unsigned long)n]]=row;}
    for(NSDictionary *row in newRows){NSString *base=nil;for(NSString *field in identityFields)if([row[field] isKindOfClass:NSString.class]&&[row[field] length]){base=[NSString stringWithFormat:@"%@:%@",field,row[field]];break;}if(!base)base=[NSString stringWithFormat:@"row:%@",row[@"sourceIndex"]?:@(newByID.count)];NSUInteger n=[newCounts[base] unsignedIntegerValue];newCounts[base]=@(n+1);newByID[[NSString stringWithFormat:@"%@#%lu",base,(unsigned long)n]]=row;}
    NSUInteger added=0,removed=0,changed=0;for(NSString *key in newByID){NSDictionary *old=oldByID[key],*new=newByID[key];if(!old){added++;continue;}for(NSString *field in compareFields){id a=old[field]?:NSNull.null,b=new[field]?:NSNull.null;if(![a isEqual:b]){changed++;break;}}}for(NSString *key in oldByID)if(!newByID[key])removed++;
    return @{@"added":@(added),@"changed":@(changed),@"removed":@(removed)};
}

// Metadata probing is bounded independently of package downloads.
@interface ResourceImportFetcher : NSObject <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,copy) void (^completion)(NSData *,NSURLResponse *,NSError *);
@property(nonatomic,strong) NSError *failure;
- (void)load:(NSURL *)url;
- (void)cancel;
@end
@implementation ResourceImportFetcher
- (void)load:(NSURL *)url {
    self.body=[NSMutableData data];NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=30;
    self.session=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];[[self.session dataTaskWithURL:url] resume];
}
- (void)cancel {self.completion=nil;[self.session invalidateAndCancel];self.session=nil;}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.response=response;NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
    if(status<200||status>=300||response.expectedContentLength>8*1024*1024){self.failure=[NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:response.expectedContentLength>8*1024*1024?@"索引超过 8 MiB 上限": [NSString stringWithFormat:@"资源返回 HTTP %ld",(long)status]}];completionHandler(NSURLSessionResponseCancel);return;}
    completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.body.length+data.length>8*1024*1024){self.failure=[NSError errorWithDomain:@"ResourceImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"索引超过 8 MiB 上限"}];[task cancel];return;}[self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^completion)(NSData *,NSURLResponse *,NSError *)=self.completion;self.completion=nil;NSData *data=[self.body copy];self.body=nil;NSURLResponse *response=self.response;NSError *failure=self.failure?:error;[session finishTasksAndInvalidate];self.session=nil;
    dispatch_async(dispatch_get_main_queue(),^{if(completion)completion(data,response,failure);});
}
@end

@interface ResourceImportWorkflowViewController () <UIDocumentPickerDelegate,UITextViewDelegate>
@property(nonatomic,strong) UITextView *address;
@property(nonatomic,strong) UILabel *addressPlaceholder;
@property(nonatomic,strong) UIButton *pasteAddressButton;
@property(nonatomic,strong) UIButton *clearAddressButton;
@property(nonatomic,strong) UISegmentedControl *runtime;
@property(nonatomic,strong) UISegmentedControl *duplicatePolicy;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *candidates;
@property(nonatomic,strong) ResourceImportFetcher *fetcher;
@property(nonatomic,strong) MediaPackageDownloader *downloader;
@property(nonatomic,readwrite) BOOL busy;
@property(nonatomic,copy) NSString *stage;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL pickingFolder;
@property(nonatomic) BOOL finished;
@property(nonatomic,copy) NSString *taskKind;
@property(nonatomic,copy) NSString *restoredAddress;
@property(nonatomic) NSInteger restoredDuplicatePolicy;
@property(nonatomic) NSInteger restoredRuntimeSelection;
@property(nonatomic) NSInteger selectedImportCategory;
@property(nonatomic) BOOL advancedOptionsExpanded;
@property(nonatomic) NSInteger retryCandidateIndex;
@property(nonatomic) NSTimeInterval lastSnapshotPersistAt;
@property(nonatomic) BOOL persistentSnapshotAvailable;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *batchRetryIndices;
@property(nonatomic) BOOL batchRetrying;
- (void)persistSnapshot;
- (void)decorateCandidate:(NSMutableDictionary *)row file:(NSURL *)file origin:(NSString *)origin;
- (void)retryCandidateAtIndex:(NSUInteger)index;
- (void)retrySaveCandidateAtIndex:(NSUInteger)index;
- (NSUInteger)failedCandidateCount;
- (void)retryFailedCandidates;
- (void)advanceBatchRetry;
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation;
- (void)showCategorizedImportOptions;
- (void)applyImportCategory:(ResourceImportOption)option;
@end
@implementation ResourceImportWorkflowViewController
- (instancetype)init {if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){self.candidates=[NSMutableArray array];self.batchRetryIndices=[NSMutableArray array];self.stage=@"粘贴地址，或选择本地文件";self.retryCandidateIndex=NSNotFound;self.selectedImportCategory=-1;NSDictionary *snapshot=ResourceImportReadSnapshot();if(snapshot){NSArray *rows=[snapshot[@"candidates"] isKindOfClass:NSArray.class]?snapshot[@"candidates"]:@[];for(NSDictionary *row in rows)if([row isKindOfClass:NSDictionary.class])[self.candidates addObject:[row mutableCopy]];self.restoredAddress=[snapshot[@"address"] isKindOfClass:NSString.class]?snapshot[@"address"]:@"";self.taskKind=[snapshot[@"taskKind"] isKindOfClass:NSString.class]?snapshot[@"taskKind"]:@"";self.finished=[snapshot[@"finished"] boolValue];self.persistentSnapshotAvailable=YES;self.restoredDuplicatePolicy=[snapshot[@"duplicatePolicy"] respondsToSelector:@selector(integerValue)]?[snapshot[@"duplicatePolicy"] integerValue]:0;self.restoredRuntimeSelection=[snapshot[@"runtimeSelection"] respondsToSelector:@selector(integerValue)]?[snapshot[@"runtimeSelection"] integerValue]:0;self.selectedImportCategory=[snapshot[@"importCategory"] respondsToSelector:@selector(integerValue)]?[snapshot[@"importCategory"] integerValue]:-1;if([snapshot[@"busy"] boolValue])self.stage=[self.taskKind isEqual:@"save"]?@"上次保存中断 · 可重试未保存项目":([self.taskKind isEqual:@"url"]?@"上次链接识别中断 · 点按识别链接重试":@"上次本地识别中断 · 重新选择文件，或重试单项");else self.stage=[snapshot[@"stage"] isKindOfClass:NSString.class]?snapshot[@"stage"]:@"已恢复上次导入任务";}}return self;}
- (NSString *)taskSummary {if(!self.candidates.count&&!self.restoredAddress.length&&([self.stage isEqual:@"粘贴地址，或选择本地文件"]||!self.stage.length))return nil;return self.stage?:@"添加资源";}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=@"添加资源";UISheetPresentationController *sheet=self.navigationController.sheetPresentationController?:self.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=26;}self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"收起" style:UIBarButtonItemStylePlain target:self action:@selector(minimize)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(saveSelected)];
    self.address=[UITextView new];self.address.delegate=self;self.address.text=self.restoredAddress?:@"";self.address.backgroundColor=HostRaisedSurface();self.address.textColor=HostText();self.address.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.address.autocapitalizationType=UITextAutocapitalizationTypeNone;self.address.autocorrectionType=UITextAutocorrectionTypeNo;self.address.smartQuotesType=UITextSmartQuotesTypeNo;self.address.smartDashesType=UITextSmartDashesTypeNo;self.address.smartInsertDeleteType=UITextSmartInsertDeleteTypeNo;self.address.keyboardType=UIKeyboardTypeURL;self.address.layer.cornerRadius=14;self.address.textContainerInset=UIEdgeInsetsMake(10,6,34,6);self.address.accessibilityLabel=@"资源链接";self.address.accessibilityHint=@"影视、直播或资源合集链接";self.address.accessibilityIdentifier=@"resource-import-url";
    self.addressPlaceholder=[UILabel new];self.addressPlaceholder.text=@"粘贴影视、直播或资源合集链接";self.addressPlaceholder.font=self.address.font;self.addressPlaceholder.textColor=HostSecondaryText();self.addressPlaceholder.userInteractionEnabled=NO;self.addressPlaceholder.translatesAutoresizingMaskIntoConstraints=NO;[self.address addSubview:self.addressPlaceholder];[NSLayoutConstraint activateConstraints:@[[self.addressPlaceholder.leadingAnchor constraintEqualToAnchor:self.address.leadingAnchor constant:10],[self.addressPlaceholder.topAnchor constraintEqualToAnchor:self.address.topAnchor constant:10]]];self.addressPlaceholder.hidden=self.address.text.length>0;
    self.pasteAddressButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.pasteAddressButton setTitle:@"粘贴剪贴板" forState:UIControlStateNormal];self.pasteAddressButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.pasteAddressButton.tintColor=HostAccent();self.pasteAddressButton.accessibilityIdentifier=@"resource-import-paste";[self.pasteAddressButton addTarget:self action:@selector(pasteClipboardAddress) forControlEvents:UIControlEventTouchUpInside];
    self.clearAddressButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.clearAddressButton setTitle:@"清空" forState:UIControlStateNormal];self.clearAddressButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.clearAddressButton.tintColor=HostSecondaryText();self.clearAddressButton.accessibilityIdentifier=@"resource-import-clear";[self.clearAddressButton addTarget:self action:@selector(clearAddressText) forControlEvents:UIControlEventTouchUpInside];
    self.runtime=[[UISegmentedControl alloc] initWithItems:@[@"自动识别",@"Python",@"Node.js"]];self.runtime.selectedSegmentIndex=MIN(2,MAX(0,self.restoredRuntimeSelection));self.runtime.selectedSegmentTintColor=HostAccent();[self.runtime addTarget:self action:@selector(runtimeChanged:) forControlEvents:UIControlEventValueChanged];
    self.duplicatePolicy=[[UISegmentedControl alloc] initWithItems:@[@"更新已有",@"保存副本"]];self.duplicatePolicy.selectedSegmentIndex=MIN(1,MAX(0,self.restoredDuplicatePolicy));self.duplicatePolicy.selectedSegmentTintColor=HostAccent();
    [self.duplicatePolicy addTarget:self action:@selector(duplicatePolicyChanged:) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];[self updateView];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.address.backgroundColor=HostRaisedSurface();
    self.address.textColor=HostText();
    self.addressPlaceholder.textColor=HostSecondaryText();
    self.pasteAddressButton.tintColor=HostAccent();
    self.clearAddressButton.tintColor=HostSecondaryText();
    self.runtime.selectedSegmentTintColor=HostAccent();
    self.duplicatePolicy.selectedSegmentTintColor=HostAccent();
    [self.tableView reloadData];
}
- (void)pasteClipboardAddress {
    if(self.busy||self.candidates.count)return;
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clip.length)return;
    self.address.text=clip;
    [self textViewDidChange:self.address];
}
- (void)clearAddressText {
    if(self.busy||self.candidates.count)return;
    self.address.text=@"";
    [self textViewDidChange:self.address];
}
- (void)toggleSelectAllCandidates {
    if(self.busy||!self.candidates.count)return;
    BOOL anyUnselected=NO;
    for(NSDictionary *row in self.candidates){
        if(!row[@"error"]&&![row[@"saved"] boolValue]&&![row[@"selected"] boolValue]){anyUnselected=YES;break;}
    }
    for(NSMutableDictionary *row in self.candidates){
        if(!row[@"error"]&&![row[@"saved"] boolValue])row[@"selected"]=@(anyUnselected);
    }
    self.finished=NO;
    [self updateView];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.fetcher cancel];[self.downloader cancel];}
- (void)updateView {
    self.navigationItem.rightBarButtonItem.enabled=!self.busy&&!self.finished&&[self.candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [row[@"selected"] boolValue]&&!row[@"error"]&&![row[@"saved"] boolValue];}]].count>0;
    self.address.editable=!self.busy&&!self.candidates.count;self.pasteAddressButton.enabled=self.address.editable;self.clearAddressButton.enabled=self.address.editable;self.clearAddressButton.hidden=self.address.text.length==0;self.runtime.enabled=!self.busy&&!self.candidates.count;self.duplicatePolicy.enabled=!self.busy;[self.tableView reloadData];[self persistSnapshot];if(self.onStateChanged)self.onStateChanged();
}
- (void)persistSnapshot {
    NSString *address=self.address.text?:self.restoredAddress?:@"";BOOL blank=!self.busy&&!self.candidates.count&&!address.length&&[self.stage isEqual:@"粘贴地址，或选择本地文件"];
    NSMutableDictionary *snapshot=[NSMutableDictionary dictionary];if(!blank){snapshot[@"version"]=@1;snapshot[@"candidates"]=ResourceImportFrozenPropertyList(self.candidates)?:@[];snapshot[@"address"]=address;snapshot[@"taskKind"]=self.taskKind?:@"";snapshot[@"stage"]=self.stage?:@"添加资源";snapshot[@"busy"]=@(self.busy);snapshot[@"finished"]=@(self.finished);snapshot[@"duplicatePolicy"]=@(self.duplicatePolicy?self.duplicatePolicy.selectedSegmentIndex:self.restoredDuplicatePolicy);snapshot[@"runtimeSelection"]=@(self.runtime?self.runtime.selectedSegmentIndex:self.restoredRuntimeSelection);snapshot[@"importCategory"]=@(self.selectedImportCategory);}
    self.persistentSnapshotAvailable=!blank;NSDictionary *immutable=snapshot.copy;UIBackgroundTaskIdentifier task=UIApplication.sharedApplication.applicationState==UIApplicationStateBackground?[UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:nil]:UIBackgroundTaskInvalid;dispatch_async(ResourceImportSnapshotQueue(),^{ResourceImportWriteSnapshot(immutable);if(task!=UIBackgroundTaskInvalid)dispatch_async(dispatch_get_main_queue(),^{[UIApplication.sharedApplication endBackgroundTask:task];});});
}
- (void)applicationDidEnterBackground:(NSNotification *)notification {[self persistSnapshot];}
- (void)textViewDidChange:(UITextView *)textView {self.restoredAddress=textView.text?:@"";self.addressPlaceholder.hidden=textView.text.length>0;self.clearAddressButton.hidden=textView.text.length==0;[self persistSnapshot];}
- (void)runtimeChanged:(UISegmentedControl *)sender {self.restoredRuntimeSelection=sender.selectedSegmentIndex;[self persistSnapshot];}
- (void)duplicatePolicyChanged:(UISegmentedControl *)sender {self.finished=NO;[self updateView];}
- (void)minimize {[self.view endEditing:YES];[self.navigationController dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?(self.advancedOptionsExpanded?7:5):(section==1?1+self.candidates.count:(1+([self failedCandidateCount]>0?1:0)));}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"选择导入方式",self.stage?:@"识别预览",@"任务操作"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return @"支持 TVBox JSON、直播列表、PY / JS 和 ZIP。默认自动识别；高级选项可指定运行环境，或按原分类入口选择导入方式。识别阶段不会执行脚本。";
    if(section==1)return @"合集仅保存一份索引，内部站点按需加载。勾选要保存的项目；更新保留原资源身份，运行中的资源须先停止后更新。";
    return @"失败项可逐条重试，或只重试失败项；收起后资源页会保留任务卡。应用进入后台后受系统调度限制，回到前台可继续查看结果。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {return indexPath.section==0&&indexPath.row==0?124:UITableViewAutomaticDimension;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    UIView *control=nil;
    if(ip.section==0){
        if(ip.row==0){
            UIView *box=[UIView new];
            [box addSubview:self.address];
            [box addSubview:self.pasteAddressButton];
            [box addSubview:self.clearAddressButton];
            self.address.translatesAutoresizingMaskIntoConstraints=NO;
            self.pasteAddressButton.translatesAutoresizingMaskIntoConstraints=NO;
            self.clearAddressButton.translatesAutoresizingMaskIntoConstraints=NO;
            [NSLayoutConstraint activateConstraints:@[
                [self.address.topAnchor constraintEqualToAnchor:box.topAnchor],
                [self.address.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
                [self.address.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
                [self.address.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
                [self.pasteAddressButton.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10],
                [self.pasteAddressButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-4],
                [self.clearAddressButton.trailingAnchor constraintEqualToAnchor:self.pasteAddressButton.leadingAnchor constant:-12],
                [self.clearAddressButton.centerYAnchor constraintEqualToAnchor:self.pasteAddressButton.centerYAnchor]
            ]];
            control=box;cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }
        else if(ip.row==1){cell.textLabel.text=[self.taskKind isEqual:@"url"]&&self.restoredAddress.length?@"识别链接 · 可重试上次地址":@"识别链接";cell.textLabel.textColor=HostAccent();}
        else if(ip.row==2){cell.textLabel.text=@"选择文件（多选）";cell.textLabel.textColor=HostAccent();}
        else if(ip.row==3){cell.textLabel.text=@"选择文件夹";cell.textLabel.textColor=HostAccent();}
        else if(ip.row==4){cell.textLabel.text=self.advancedOptionsExpanded?@"收起高级选项":@"高级选项";cell.detailTextLabel.text=@"指定运行环境 · 分类导入入口";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.textLabel.textColor=HostAccent();}
        else if(ip.row==5){UILabel *label=[UILabel new];label.text=@"运行环境";label.textColor=HostText();label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,self.runtime]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;control=stack;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
        else {cell.textLabel.text=@"按类型选择导入方式";cell.detailTextLabel.text=@"TVBox、直播、Python、JS、ZIP 与文件夹";cell.textLabel.textColor=HostAccent();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    }
    else if(ip.section==1){if(ip.row==0){
        if(self.candidates.count>1){
            UIButton *toggleAll=[UIButton buttonWithType:UIButtonTypeSystem];
            [toggleAll setTitle:@"全选 / 反选" forState:UIControlStateNormal];
            toggleAll.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            toggleAll.tintColor=HostAccent();
            [toggleAll addTarget:self action:@selector(toggleSelectAllCandidates) forControlEvents:UIControlEventTouchUpInside];
            UIStackView *policyRow=[[UIStackView alloc] initWithArrangedSubviews:@[self.duplicatePolicy,toggleAll]];
            policyRow.axis=UILayoutConstraintAxisHorizontal;
            policyRow.spacing=10;
            control=policyRow;
        }else{
            control=self.duplicatePolicy;
        }
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }else{NSDictionary *row=self.candidates[ip.row-1];cell.textLabel.text=row[@"name"]?:@"资源";NSString *detail=row[@"saved"]?@"已保存":(row[@"saveError"]?:row[@"error"]?:row[@"summary"]);if(!row[@"saved"]&&row[@"updatePreview"]){NSString *preview=self.duplicatePolicy.selectedSegmentIndex==0?row[@"updatePreview"]:@"将另存为独立副本 · 原资源保持不变";detail=[NSString stringWithFormat:@"%@\n%@",detail,preview];}cell.detailTextLabel.text=detail;cell.accessoryType=[row[@"selected"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;cell.tintColor=HostAccent();if(row[@"error"]||row[@"saveError"]){UIButton *retry=[UIButton buttonWithType:UIButtonTypeSystem];retry.tag=ip.row-1;[retry setTitle:@"重试" forState:UIControlStateNormal];retry.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];retry.tintColor=HostAccent();[retry sizeToFit];retry.frame=CGRectMake(0,0,52,44);[retry addTarget:self action:@selector(retryButtonTapped:) forControlEvents:UIControlEventTouchUpInside];cell.accessoryView=retry;}}}
    else {NSUInteger failed=[self failedCandidateCount];if(ip.row==0){cell.textLabel.text=self.busy?@"取消当前任务":@"开始新的导入";cell.textLabel.textColor=HostAccent();}else{cell.textLabel.text=[NSString stringWithFormat:@"仅重试失败项（%lu）",(unsigned long)failed];cell.textLabel.textColor=HostAccent();}}
    if(control){[cell.contentView addSubview:control];control.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[control.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],[control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],[control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],[control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12]]];}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(ip.section==2&&ip.row==0){if(self.busy)[self cancelWork];else[self reset];return;}if(self.busy)return;
    if(ip.section==0){if(ip.row==1)[self recognizeURL];else if(ip.row==2||ip.row==3)[self pickFiles:ip.row==3];else if(ip.row==4){self.advancedOptionsExpanded=!self.advancedOptionsExpanded;[tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];}else if(ip.row==6)[self showCategorizedImportOptions];}
    else if(ip.section==1&&ip.row>0){NSMutableDictionary *row=self.candidates[ip.row-1];if(row[@"error"])[self retryCandidateAtIndex:(NSUInteger)(ip.row-1)];else if([row[@"matchTargets"] count]>1&&![row[@"saved"] boolValue])[self chooseExistingResourceForCandidate:row];else if(!row[@"saved"]){row[@"selected"]=@(![row[@"selected"] boolValue]);self.finished=NO;}[self updateView];}
    else if(ip.section==2&&[self failedCandidateCount]>0&&ip.row==1)[self retryFailedCandidates];
}
- (void)showCategorizedImportOptions {
    if(self.candidates.count){[self showFailure:@"请先保存当前预览，或开始新的导入"];return;}
    ResourceImportSheetViewController *chooser=[ResourceImportSheetViewController new];chooser.modalPresentationStyle=UIModalPresentationFullScreen;__weak typeof(self) weakSelf=self;
    chooser.onSelect=^(ResourceImportOption option){ResourceImportWorkflowViewController *owner=weakSelf;if(owner)[owner applyImportCategory:option];};
    [self presentViewController:chooser animated:YES completion:nil];
}
- (void)applyImportCategory:(ResourceImportOption)option {
    if(option==ResourceImportOptionServices){dispatch_block_t open=self.onOpenServices;[self.navigationController dismissViewControllerAnimated:YES completion:^{if(open)open();}];return;}
    if(option==ResourceImportOptionHostCapabilities){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"宿主运行能力" message:@"资源导入阶段只做静态识别，不会执行脚本。Python 资源使用内置 CPython；JavaScript 资源可自动识别，必要时在高级选项指定 Node.js。启动后的实际能力与健康状态可在服务页查看。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];return;}
    self.selectedImportCategory=option;NSInteger runtimeIndex=0;BOOL chooseFile=NO,chooseFolder=NO;NSString *category=nil;
    switch(option){
        case ResourceImportOptionLiveURL:category=@"直播列表链接 · M3U / TXT";break;
        case ResourceImportOptionMediaURL:category=@"影视、合集或脚本链接";break;
        case ResourceImportOptionTVBox:category=@"TVBox 配置链接 · JSON";break;
        case ResourceImportOptionMacCMS:category=@"MacCMS 影视接口 · JSON / XML";break;
        case ResourceImportOptionPythonURL:category=@"Python Spider 链接";runtimeIndex=1;break;
        case ResourceImportOptionCatVodURL:category=@"CatVod / TVBox JavaScript 链接";break;
        case ResourceImportOptionNodeURL:category=@"Node.js Mobile 链接";runtimeIndex=2;break;
        case ResourceImportOptionLiveFile:category=@"直播列表文件 · M3U / M3U8 / TXT";chooseFile=YES;break;
        case ResourceImportOptionMediaFile:category=@"影视脚本或 ZIP 文件";chooseFile=YES;break;
        case ResourceImportOptionPythonFile:category=@"Python Spider 文件";runtimeIndex=1;chooseFile=YES;break;
        case ResourceImportOptionNodeFile:category=@"Node.js Mobile 脚本 / ZIP";runtimeIndex=2;chooseFile=YES;break;
        case ResourceImportOptionTVBoxFile:category=@"TVBox 配置文件 · JSON";chooseFile=YES;break;
        case ResourceImportOptionFolder:category=@"资源文件夹";chooseFolder=YES;break;
        default:category=@"资源链接";break;
    }
    [self.runtime setSelectedSegmentIndex:runtimeIndex];[self runtimeChanged:self.runtime];
    self.addressPlaceholder.text=[category stringByAppendingString:chooseFolder?@"":(chooseFile?@" · 选择文件后自动识别":@" · 粘贴链接后点识别")];self.addressPlaceholder.hidden=self.address.text.length>0;self.address.accessibilityHint=category;
    if(chooseFile||chooseFolder){[self pickFiles:chooseFolder];return;}
    self.navigationItem.prompt=category;[self.address becomeFirstResponder];
}
- (void)reset {
    self.generation++;[self.fetcher cancel];[self.downloader cancel];self.batchRetrying=NO;[self.batchRetryIndices removeAllObjects];for(NSDictionary *row in self.candidates)if(row[@"service"]&&![row[@"saved"] boolValue])[ServiceStore remove:row[@"service"][@"id"]];[self.candidates removeAllObjects];self.finished=NO;self.taskKind=@"";self.selectedImportCategory=-1;self.restoredAddress=@"";self.address.text=@"";self.addressPlaceholder.hidden=NO;self.addressPlaceholder.text=@"粘贴影视、直播或资源合集链接";self.stage=@"粘贴地址，或选择本地文件";[self updateView];
}
- (void)cancelWork {self.generation++;[self.fetcher cancel];[self.downloader cancel];self.batchRetrying=NO;[self.batchRetryIndices removeAllObjects];self.retryCandidateIndex=NSNotFound;self.busy=NO;self.stage=@"任务已取消 · 已保存项目保留，可重试未保存项";[self updateView];}
- (NSString *)runtimeHint {return self.runtime.selectedSegmentIndex==1?@"python":(self.runtime.selectedSegmentIndex==2?@"node":nil);}
- (void)showFailure:(NSString *)message {self.busy=NO;self.stage=message?:@"识别失败，请重试";[self updateView];}
- (void)retryButtonTapped:(UIButton *)sender {if(sender.tag>=0&&(NSUInteger)sender.tag<self.candidates.count)[self retryCandidateAtIndex:(NSUInteger)sender.tag];}
- (NSUInteger)failedCandidateCount {NSUInteger count=0;for(NSDictionary *row in self.candidates)if((row[@"error"]||row[@"saveError"])&&![row[@"saved"] boolValue])count++;return count;}
- (void)retryFailedCandidates {
    if(self.busy||self.batchRetrying)return;[self.batchRetryIndices removeAllObjects];for(NSUInteger index=0;index<self.candidates.count;index++){NSDictionary *row=self.candidates[index];if((row[@"error"]||row[@"saveError"])&&![row[@"saved"] boolValue])[self.batchRetryIndices addObject:@(index)];}
    if(!self.batchRetryIndices.count)return;self.batchRetrying=YES;self.stage=[NSString stringWithFormat:@"正在重试 %lu 个失败项目…",(unsigned long)self.batchRetryIndices.count];[self advanceBatchRetry];
}
- (void)advanceBatchRetry {
    if(!self.batchRetrying||self.busy)return;
    if(self.batchRetryIndices.count){NSUInteger index=self.batchRetryIndices.firstObject.unsignedIntegerValue;[self.batchRetryIndices removeObjectAtIndex:0];[self retryCandidateAtIndex:index];return;}
    self.batchRetrying=NO;self.stage=@"失败项目重试完成 · 可查看仍失败的项目";[self updateView];
}
- (void)retryCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count)return;NSMutableDictionary *row=self.candidates[index];
    if(row[@"saveError"]){[self retrySaveCandidateAtIndex:index];return;}
    NSData *data=[row[@"retryData"] isKindOfClass:NSData.class]?row[@"retryData"]:nil;NSString *filename=row[@"retryFileName"]?:row[@"localFileName"]?:row[@"name"]?:@"resource.json";NSURL *sourceURL=nil;
    if(!data&&[row[@"retryBookmark"] isKindOfClass:NSData.class])sourceURL=[NSURL URLByResolvingBookmarkData:row[@"retryBookmark"] options:0 relativeToURL:nil bookmarkDataIsStale:nil error:NULL];
    if(!data&&sourceURL){BOOL scope=[sourceURL startAccessingSecurityScopedResource];data=ResourceImportReadBounded(sourceURL,32*1024*1024);if(scope)[sourceURL stopAccessingSecurityScopedResource];}
    if(!data){self.retryCandidateIndex=(NSInteger)index;if(self.batchRetrying){self.busy=YES;self.stage=[NSString stringWithFormat:@"请重新选择 %@",filename];[self updateView];}UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];picker.allowsMultipleSelection=NO;picker.delegate=self;self.pickingFolder=NO;[self presentViewController:picker animated:YES completion:nil];return;}
    self.busy=YES;self.taskKind=@"file-retry";self.stage=[NSString stringWithFormat:@"正在重试 %@…",filename];NSUInteger generation=++self.generation;[self updateView];NSDictionary *companions=[row[@"retryCompanions"] isKindOfClass:NSDictionary.class]?row[@"retryCompanions"]:@{};NSString *origin=row[@"retryOrigin"]?:@"",*hint=row[@"retryHint"]?:@"";__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"retry-%@",NSUUID.UUID.UUIDString]];[NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];NSString *path=[directory stringByAppendingPathComponent:filename.lastPathComponent.length?filename.lastPathComponent:@"resource.json"];[data writeToFile:path atomically:YES];NSMutableDictionary *candidate=[weakSelf candidateForData:data file:[NSURL fileURLWithPath:path] origin:origin companions:companions hint:hint];[NSFileManager.defaultManager removeItemAtPath:directory error:NULL];dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){if(candidate[@"service"])[ServiceStore remove:candidate[@"service"][@"id"]];return;}if(!candidate[@"error"]){candidate[@"selected"]=@YES;[owner.candidates replaceObjectAtIndex:index withObject:candidate];}else{row[@"error"]=candidate[@"error"];row[@"retryData"]=data;if(candidate[@"localFileName"])row[@"localFileName"]=candidate[@"localFileName"];}owner.busy=NO;owner.stage=candidate[@"error"]?@"单项重试失败 · 可再次重试或重新选择文件":@"单项识别成功 · 已更新预览";[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];});});
}
- (void)retrySaveCandidateAtIndex:(NSUInteger)index {
    if(self.busy||index>=self.candidates.count||!self.onSaveCandidate)return;NSMutableDictionary *row=self.candidates[index];self.busy=YES;self.taskKind=@"save";self.stage=[NSString stringWithFormat:@"正在重试保存 %@…",row[@"name"]?:@"资源"];NSUInteger generation=++self.generation;[self updateView];__weak typeof(self) weakSelf=self;
    self.onSaveCandidate(row,self.duplicatePolicy.selectedSegmentIndex==0,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.busy=NO;if(error){row[@"saveError"]=error.localizedDescription?:@"保存失败";owner.stage=@"单项保存失败 · 可再次重试";}else{row[@"saved"]=@YES;[row removeObjectForKey:@"saveError"];[row removeObjectForKey:@"retryData"];owner.stage=@"单项资源已保存";}[owner updateView];if(owner.batchRetrying)[owner advanceBatchRetry];});});
}
- (void)attachUpdatePreviewToCandidate:(NSMutableDictionary *)row {
    if(![row[@"kind"] isEqual:@"catalog"])return;NSDictionary *incoming=row[@"catalog"]?:@{};NSDictionary *existing=nil;
    for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:catalog[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:catalog[@"importFingerprint"]])){existing=catalog;break;}
    if(!existing)return;
    NSDictionary *sites=ResourceCatalogDiff([existing[@"sites"] isKindOfClass:NSArray.class]?existing[@"sites"]:@[],[incoming[@"sites"] isKindOfClass:NSArray.class]?incoming[@"sites"]:@[],@[@"key",@"api"],@[@"name",@"api",@"type",@"ext",@"header",@"playUrl"]);
    NSDictionary *lives=ResourceCatalogDiff([existing[@"lives"] isKindOfClass:NSArray.class]?existing[@"lives"]:@[],[incoming[@"lives"] isKindOfClass:NSArray.class]?incoming[@"lives"]:@[],@[@"url",@"name"],@[@"name",@"url",@"type",@"ua"]);
    NSUInteger added=[sites[@"added"] unsignedIntegerValue]+[lives[@"added"] unsignedIntegerValue],changed=[sites[@"changed"] unsignedIntegerValue]+[lives[@"changed"] unsignedIntegerValue],removed=[sites[@"removed"] unsignedIntegerValue]+[lives[@"removed"] unsignedIntegerValue];if(![(existing[@"tvboxConfig"]?:@{}) isEqual:(incoming[@"tvboxConfig"]?:@{})])changed++;
    row[@"existingCatalogID"]=existing[@"id"]?:@"";row[@"updatePreview"]=[NSString stringWithFormat:@"更新「%@」：新增 %lu · 变更 %lu · 移除 %lu",existing[@"name"]?:@"资源合集",(unsigned long)added,(unsigned long)changed,(unsigned long)removed];
}
- (void)decorateCandidate:(NSMutableDictionary *)row file:(NSURL *)file origin:(NSString *)origin {
    if(!origin.length&&file.isFileURL){NSString *filename=file.lastPathComponent?:@"";if(filename.length)row[@"localFileName"]=filename;}
    [self attachUpdatePreviewToCandidate:row];
    if(!self.existingImportTargetsProvider)return;
    NSString *kind=row[@"kind"]?:@"",*filename=row[@"localFileName"]?:@"";NSDictionary *catalog=row[@"catalog"]?:@{},*service=row[@"service"]?:@{};
    NSString *url=catalog[@"url"]?:service[@"url"]?:row[@"origin"]?:@"",*fingerprint=catalog[@"importFingerprint"]?:service[@"importFingerprint"]?:row[@"importFingerprint"]?:@"";
    NSMutableArray *matches=[NSMutableArray array];
    for(NSDictionary *target in self.existingImportTargetsProvider()?:@[]){if(![target[@"kind"] isEqual:kind])continue;BOOL sameURL=url.length&&[url isEqual:target[@"url"]];BOOL sameFingerprint=fingerprint.length&&[fingerprint isEqual:target[@"fingerprint"]];BOOL sameFile=filename.length&&[filename caseInsensitiveCompare:target[@"sourceFilename"]?:@""]==NSOrderedSame;if(sameURL||sameFingerprint||sameFile)[matches addObject:target];}
    if(!matches.count){[row removeObjectForKey:@"existingResourceID"];[row removeObjectForKey:@"existingResourceKind"];[row removeObjectForKey:@"existingCatalogID"];return;}row[@"matchTargets"]=matches.copy;
    if(matches.count>1){NSString *selectedID=row[@"existingResourceID"];for(NSDictionary *candidate in matches)if(selectedID.length&&[candidate[@"id"] isEqual:selectedID]){row[@"updatePreview"]=[NSString stringWithFormat:@"已选择更新「%@」并保留资源身份",candidate[@"name"]?:@"资源"];return;}[row removeObjectForKey:@"existingResourceID"];[row removeObjectForKey:@"existingResourceKind"];row[@"updatePreview"]=[NSString stringWithFormat:@"有 %lu 个同名旧资源 · 点按选择要更新的资源",(unsigned long)matches.count];return;}
    NSDictionary *target=matches.firstObject;row[@"existingResourceID"]=target[@"id"]?:@"";row[@"existingResourceKind"]=kind;
    if([kind isEqual:@"catalog"]){row[@"existingCatalogID"]=target[@"id"]?:@"";if(!row[@"updatePreview"])row[@"updatePreview"]=[NSString stringWithFormat:@"本地文件名匹配旧合集「%@」 · 更新将保留资源身份",target[@"name"]?:@"资源合集"];}
    else row[@"updatePreview"]=[NSString stringWithFormat:@"%@匹配旧资源「%@」 · 更新将保留资源身份",filename.length?@"本地文件名":@"内容或地址",target[@"name"]?:@"资源"];
}
- (void)refreshExistingResourceMatches {
    for(NSMutableDictionary *row in self.candidates){NSString *filename=row[@"localFileName"];if(!filename.length)continue;[row removeObjectForKey:@"matchTargets"];[self decorateCandidate:row file:[NSURL fileURLWithPath:filename] origin:nil];}
    [self updateView];
}
- (void)chooseExistingResourceForCandidate:(NSMutableDictionary *)row {
    NSArray *targets=[row[@"matchTargets"] isKindOfClass:NSArray.class]?row[@"matchTargets"]:@[];if(targets.count<2)return;
    UIAlertController *choices=[UIAlertController alertControllerWithTitle:@"选择要更新的旧资源" message:@"确认后会保留所选资源的 ID 和个人设置。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *target in targets){NSString *title=[NSString stringWithFormat:@"%@ · %@",target[@"name"]?:@"未命名资源",target[@"kindLabel"]?:@"资源"];[choices addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){row[@"existingResourceID"]=target[@"id"]?:@"";row[@"existingResourceKind"]=target[@"kind"]?:@"";row[@"updatePreview"]=[NSString stringWithFormat:@"将更新「%@」并保留资源身份",target[@"name"]?:@"资源"];[self updateView];}]];}
    [choices addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];choices.popoverPresentationController.sourceView=self.view;choices.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);[self presentViewController:choices animated:YES completion:nil];
}
- (NSMutableDictionary *)candidateForData:(NSData *)data file:(NSURL *)file origin:(NSString *)origin companions:(NSDictionary *)companions hint:(NSString *)hint {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *fingerprint=[NSMutableString string];for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[fingerprint appendFormat:@"%02x",digest[i]];
    NSError *error=nil;NSMutableDictionary *catalog=[[TVBoxCatalogStore parseData:data sourceURL:origin error:&error] mutableCopy];if(catalog)catalog[@"importFingerprint"]=fingerprint;
    if(catalog){NSArray *sites=catalog[@"sites"]?:@[];NSUInteger recognized=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])recognized++;NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":catalog,@"name":catalog[@"name"]?:file.lastPathComponent?:@"资源合集",@"summary":[NSString stringWithFormat:@"合集 · %lu 个站点 · %lu 个已识别 · %lu 个直播列表",(unsigned long)sites.count,(unsigned long)recognized,(unsigned long)[catalog[@"lives"] count]],@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return row;}
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];NSArray *channels=text.length?[M3UParser parse:text baseURL:origin.length?[NSURL URLWithString:origin]:nil]:nil;
    if(channels.count){NSMutableDictionary *row=[@{@"kind":@"playlist",@"text":text,@"origin":origin?:@"",@"importFingerprint":fingerprint,@"name":file.lastPathComponent?:@"直播订阅",@"summary":[NSString stringWithFormat:@"直播列表 · %lu 个频道",(unsigned long)channels.count],@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return row;}
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if(origin.length&&[json isKindOfClass:NSDictionary.class]&&[json[@"list"] isKindOfClass:NSArray.class]){NSDictionary *api=[TVBoxCatalogStore catalogWithMacCMSAPIURL:origin name:nil error:&error];if(api){NSMutableDictionary *catalog=[api mutableCopy];catalog[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":catalog,@"name":catalog[@"name"]?:@"影视接口",@"summary":@"MacCMS 影视接口 · 按需连接",@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return row;}}
    NSDictionary *service=[MediaPackageImporter importFile:file companionFiles:companions runtimeHint:hint error:&error];
    if(service){NSMutableDictionary *imported=[service mutableCopy];if(origin.length)imported[@"url"]=origin;imported[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"service",@"service":imported,@"name":service[@"name"]?:file.lastPathComponent,@"summary":[NSString stringWithFormat:@"脚本资源 · %@ · %@",service[@"engine"]?:@"自动识别",service[@"protocol"]?:@"启动后验证能力"],@"selected":@YES} mutableCopy];[self decorateCandidate:row file:file origin:origin];return row;}
    NSMutableDictionary *failed=[@{@"name":file.lastPathComponent?:@"资源",@"error":error.localizedDescription?:@"不支持或无法识别此文件",@"selected":@NO} mutableCopy];if(data.length<=32*1024*1024)failed[@"retryData"]=data;if(file.isFileURL)failed[@"retryFileName"]=file.lastPathComponent?:@"";failed[@"retryOrigin"]=origin?:@"";failed[@"retryCompanions"]=companions?:@{};failed[@"retryHint"]=hint?:@"";[self decorateCandidate:failed file:file origin:origin];return failed;
}
- (void)recognizeURL {
    if(self.candidates.count){[self showFailure:@"请先保存当前预览，或开始新的导入"];return;}
    NSString *raw=[self.address.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSURL *url=[NSURL URLWithString:raw];
    if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||[raw rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound){[self showFailure:@"请输入一个完整的 HTTP / HTTPS 链接"];return;}
    if([raw rangeOfString:@"\\.jsonhttps?://" options:NSRegularExpressionSearch].location!=NSNotFound){[self showFailure:@"可能粘贴了多个链接，请每次识别一个完整地址"];return;}
    [self.view endEditing:YES];self.restoredAddress=raw;self.taskKind=@"url";self.busy=YES;self.stage=@"正在下载与识别…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    if(self.selectedImportCategory==ResourceImportOptionMacCMS){NSError *error=nil;NSDictionary *catalog=[TVBoxCatalogStore catalogWithMacCMSAPIURL:raw name:nil error:&error];if(!catalog){[self showFailure:error.localizedDescription?:@"MacCMS 接口地址无效"];return;}unsigned char digest[CC_SHA256_DIGEST_LENGTH];NSData *sourceData=[raw dataUsingEncoding:NSUTF8StringEncoding];CC_SHA256(sourceData.bytes,(CC_LONG)sourceData.length,digest);NSMutableString *fingerprint=[NSMutableString string];for(NSUInteger index=0;index<CC_SHA256_DIGEST_LENGTH;index++)[fingerprint appendFormat:@"%02x",digest[index]];NSMutableDictionary *prepared=[catalog mutableCopy];prepared[@"importFingerprint"]=fingerprint;NSMutableDictionary *row=[@{@"kind":@"catalog",@"catalog":prepared,@"name":prepared[@"name"]?:@"MacCMS 影视接口",@"summary":@"MacCMS API · 保存接口索引，选中后请求 JSON / XML",@"selected":@YES} mutableCopy];[self decorateCandidate:row file:nil origin:raw];[self.candidates addObject:row];self.busy=NO;self.stage=@"MacCMS 接口已识别 · 尚未验证网络";[self updateView];return;}
    if([@[@"py",@"js",@"zip",@"md5"] containsObject:url.pathExtension.lowercaseString]){
        self.downloader=[MediaPackageDownloader new];self.downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.stage=expected>0?[NSString stringWithFormat:@"%@ · %.1f / %.1f MiB",stage,received/1048576.0,expected/1048576.0]:[NSString stringWithFormat:@"%@ · %.1f MiB",stage,received/1048576.0];if(owner.onStateChanged)owner.onStateChanged();[owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];};
        [self.downloader importURL:url headers:nil runtimeHint:hint completion:^(NSDictionary *service,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){if(service)[ServiceStore remove:service[@"id"]];return;}if(!service){[owner showFailure:error.localizedDescription];return;}NSMutableDictionary *row=[@{@"kind":@"service",@"service":service,@"name":service[@"name"]?:@"脚本资源",@"summary":[NSString stringWithFormat:@"已识别 · %@ · %@",service[@"engine"]?:@"",service[@"protocol"]?:@""],@"selected":@YES} mutableCopy];[owner decorateCandidate:row file:nil origin:url.absoluteString];[owner.candidates addObject:row];owner.busy=NO;owner.stage=@"识别完成 · 尚未保存";[owner updateView];}];return;
    }
    self.fetcher=[ResourceImportFetcher new];self.fetcher.completion=^(NSData *data,NSURLResponse *response,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;if(error){[owner showFailure:error.localizedDescription];return;}
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];NSString *ext=([text containsString:@"class Spider"]||[text containsString:@"def init("])?@"py":@"js";NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"resource-%@.%@",NSUUID.UUID.UUIDString,ext]];[data writeToFile:path atomically:YES];NSMutableDictionary *row=[owner candidateForData:data file:[NSURL fileURLWithPath:path] origin:response.URL.absoluteString?:raw companions:@{} hint:hint];if([row[@"kind"] isEqual:@"catalog"]){NSMutableDictionary *catalog=[row[@"catalog"] mutableCopy];catalog[@"url"]=raw;row[@"catalog"]=catalog;}else if([row[@"kind"] isEqual:@"playlist"]){row[@"origin"]=raw;row[@"resolvedURL"]=response.URL.absoluteString?:raw;}else if(row[@"service"]){NSMutableDictionary *service=[row[@"service"] mutableCopy];service[@"url"]=raw;row[@"service"]=service;}[owner decorateCandidate:row file:nil origin:raw];[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{if(owner.generation!=generation){if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}[owner.candidates addObject:row];owner.busy=NO;owner.stage=@"识别完成 · 请选择要保存的资源";[owner updateView];});
        });
    };[self.fetcher load:url];
}
- (void)pickFiles:(BOOL)folder {
    if(self.candidates.count){[self showFailure:@"请先保存当前预览，或开始新的导入"];return;}self.pickingFolder=folder;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder?UTTypeFolder:UTTypeData] asCopy:!folder];picker.allowsMultipleSelection=!folder;picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {self.retryCandidateIndex=NSNotFound;if(self.batchRetrying){self.busy=NO;self.stage=@"已跳过需要重新选择的失败文件";[self updateView];[self advanceBatchRetry];}}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count){self.retryCandidateIndex=NSNotFound;return;}BOOL folder=self.pickingFolder;NSInteger retryIndex=self.retryCandidateIndex;self.retryCandidateIndex=NSNotFound;self.busy=YES;self.taskKind=retryIndex!=NSNotFound?@"file-retry":@"file";self.stage=retryIndex!=NSNotFound?@"正在重新识别此文件…":@"正在检查本地文件…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSURL *root=folder?urls.firstObject:nil;BOOL scoped=[root startAccessingSecurityScopedResource];NSMutableArray *files=[NSMutableArray array];BOOL truncated=NO;
        if(folder){NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url,NSError *error){return NO;}];NSUInteger scanned=0;for(NSURL *url in enumerator){if(++scanned>4096||weakSelf.generation!=generation){truncated=YES;break;}NSNumber *regular=nil,*link=nil;[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];if(link.boolValue){[enumerator skipDescendants];continue;}if(!regular.boolValue)continue;if(![@[@"json",@"js",@"mjs",@"cjs",@"py",@"zip",@"txt",@"m3u",@"m3u8",@"php"] containsObject:url.pathExtension.lowercaseString])continue;if(files.count==128){truncated=YES;break;}[files addObject:url];}}
        else {truncated=urls.count>128;[files addObjectsFromArray:[urls subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)128,urls.count))]];}
        NSMutableArray *rows=[NSMutableArray array];NSUInteger total=0;
        for(NSURL *file in files){if([file.lastPathComponent isEqual:@"index.config.js"]){BOOL companion=NO;for(NSURL *main in files)if(![main isEqual:file]&&[@[@"js",@"mjs",@"cjs"] containsObject:main.pathExtension.lowercaseString]&&[main.URLByDeletingLastPathComponent isEqual:file.URLByDeletingLastPathComponent]){companion=YES;break;}if(companion)continue;}ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)break;BOOL childScope=[file startAccessingSecurityScopedResource];NSNumber *size=nil;[file getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];NSData *data=nil;if(size.unsignedLongLongValue<=32*1024*1024&&total+size.unsignedLongLongValue<=64*1024*1024)data=ResourceImportReadBounded(file,MIN((NSUInteger)32*1024*1024,(NSUInteger)64*1024*1024-total));if(data)total+=data.length;
            NSMutableDictionary *companions=[NSMutableDictionary dictionary];if([@[@"js",@"mjs",@"cjs"] containsObject:file.pathExtension.lowercaseString]&&![file.lastPathComponent isEqual:@"index.config.js"]){for(NSURL *other in files)if([other.lastPathComponent isEqual:@"index.config.js"]&&[other.URLByDeletingLastPathComponent isEqual:file.URLByDeletingLastPathComponent]){BOOL access=[other startAccessingSecurityScopedResource];NSNumber *bytes=nil;[other getResourceValue:&bytes forKey:NSURLFileSizeKey error:NULL];if(bytes.unsignedLongLongValue<=65536){NSData *configuration=ResourceImportReadBounded(other,65536);if(configuration)companions[@"index.config.js"]=configuration;}if(access)[other stopAccessingSecurityScopedResource];break;}}
            NSMutableDictionary *row=data?[owner candidateForData:data file:file origin:nil companions:companions hint:hint]:[@{@"name":file.lastPathComponent,@"error":@"无法读取或超过本次导入大小上限",@"selected":@NO,@"localFileName":file.lastPathComponent?:@""} mutableCopy];if(!data){NSData *bookmark=[file bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(bookmark)row[@"retryBookmark"]=bookmark;row[@"retryFileName"]=file.lastPathComponent?:@"";row[@"retryHint"]=hint?:@"";}[rows addObject:row];if(childScope)[file stopAccessingSecurityScopedResource];
        }
        if(scoped)[root stopAccessingSecurityScopedResource];dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){for(NSDictionary *row in rows)if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}if(retryIndex!=NSNotFound&&retryIndex>=0&&(NSUInteger)retryIndex<owner.candidates.count){NSMutableDictionary *prior=owner.candidates[(NSUInteger)retryIndex];NSMutableDictionary *replacement=rows.firstObject;if(replacement&&!replacement[@"error"]){replacement[@"selected"]=@YES;[owner.candidates replaceObjectAtIndex:(NSUInteger)retryIndex withObject:replacement];owner.stage=@"单项识别成功 · 已更新预览";}else{if(replacement)prior[@"error"]=replacement[@"error"]?:@"重新识别失败";prior[@"retryFileName"]=urls.firstObject.lastPathComponent?:prior[@"retryFileName"]?:@"";NSData *bookmark=[urls.firstObject bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];if(bookmark)prior[@"retryBookmark"]=bookmark;owner.stage=@"单项重试失败 · 可再次重试";}}else{[owner.candidates addObjectsFromArray:rows];owner.stage=truncated?@"扫描达到数量上限 · 部分文件未处理":(rows.count?@"本地文件识别完成 · 尚未保存":@"未发现支持的资源文件");}owner.busy=NO;[owner updateView];if(owner.batchRetrying&&retryIndex!=NSNotFound)[owner advanceBatchRetry];});
    }});
}
- (void)saveSelected {if(self.busy||!self.onSaveCandidate)return;self.taskKind=@"save";self.busy=YES;self.stage=@"正在保存资源…";NSUInteger generation=++self.generation;[self updateView];[self saveNext:0 generation:generation];}
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation {
    if(self.generation!=generation)return;
    if(index>=self.candidates.count){self.busy=NO;NSUInteger saved=0,failed=0,pending=0;for(NSMutableDictionary *row in self.candidates){if([row[@"saved"] boolValue]){saved++;[row removeObjectForKey:@"retryData"];}else if(row[@"error"]||row[@"saveError"])failed++;else if([row[@"selected"] boolValue])pending++;}self.finished=failed==0&&pending==0;self.stage=[NSString stringWithFormat:@"已保存 %lu 项 · 失败 / 不支持 %lu 项",(unsigned long)saved,(unsigned long)failed];[self updateView];return;}
    NSMutableDictionary *row=self.candidates[index];if(![row[@"selected"] boolValue]||row[@"error"]||[row[@"saved"] boolValue]){[self saveNext:index+1 generation:generation];return;}
    __weak typeof(self) weakSelf=self;self.onSaveCandidate(row,self.duplicatePolicy.selectedSegmentIndex==0,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;if(error)row[@"saveError"]=error.localizedDescription?:@"保存失败";else{row[@"saved"]=@YES;[row removeObjectForKey:@"saveError"];[row removeObjectForKey:@"retryData"];}[owner updateView];[owner saveNext:index+1 generation:generation];});});
}
@end
