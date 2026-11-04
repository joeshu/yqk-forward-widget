#import "ResourceImportWorkflowViewController.h"
#import "HostTheme.h"
#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import "TVBoxCatalogStore.h"
#import "ServiceStore.h"
#import "M3UParser.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation;
@end
@implementation ResourceImportWorkflowViewController
- (instancetype)init {if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){self.candidates=[NSMutableArray array];self.stage=@"粘贴地址，或选择本地文件";}return self;}
- (NSString *)taskSummary {return self.stage?:@"添加资源";}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.title=@"添加资源";self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"收起" style:UIBarButtonItemStylePlain target:self action:@selector(minimize)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(saveSelected)];
    self.address=[UITextView new];self.address.delegate=self;self.address.backgroundColor=HostRaisedSurface();self.address.textColor=HostText();self.address.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.address.autocapitalizationType=UITextAutocapitalizationTypeNone;self.address.autocorrectionType=UITextAutocorrectionTypeNo;self.address.smartQuotesType=UITextSmartQuotesTypeNo;self.address.smartDashesType=UITextSmartDashesTypeNo;self.address.smartInsertDeleteType=UITextSmartInsertDeleteTypeNo;self.address.keyboardType=UIKeyboardTypeURL;self.address.layer.cornerRadius=14;self.address.accessibilityLabel=@"资源链接";self.address.accessibilityIdentifier=@"resource-import-url";
    self.runtime=[[UISegmentedControl alloc] initWithItems:@[@"自动识别",@"Python",@"Node.js"]];self.runtime.selectedSegmentIndex=0;
    self.duplicatePolicy=[[UISegmentedControl alloc] initWithItems:@[@"更新已有",@"保存副本"]];self.duplicatePolicy.selectedSegmentIndex=0;
    [self updateView];
}
- (void)dealloc {[self.fetcher cancel];[self.downloader cancel];for(NSDictionary *row in self.candidates)if(row[@"service"]&&![row[@"saved"] boolValue])[ServiceStore remove:row[@"service"][@"id"]];}
- (void)updateView {
    self.navigationItem.rightBarButtonItem.enabled=!self.busy&&!self.finished&&[self.candidates filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [row[@"selected"] boolValue]&&!row[@"error"]&&![row[@"saved"] boolValue];}]].count>0;
    self.address.editable=!self.busy&&!self.candidates.count;self.runtime.enabled=!self.busy&&!self.candidates.count;self.duplicatePolicy.enabled=!self.busy;[self.tableView reloadData];if(self.onStateChanged)self.onStateChanged();
}
- (void)minimize {[self.view endEditing:YES];[self.navigationController dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?5:(section==1?1+self.candidates.count:2);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"选择导入方式",self.stage?:@"识别预览",@"任务操作"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return @"支持 TVBox JSON、直播列表、PY / JS 和 ZIP。运行环境默认自动识别；识别与保存阶段不启动脚本。";
    if(section==1)return @"合集仅保存一份索引，内部站点按需加载。勾选要保存的项目；更新保留原资源身份，运行中的资源须先停止后更新。";
    return @"收起后任务仍可从资源页“添加”返回。应用进入后台后受系统调度限制，回到前台可继续查看结果。";
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {return indexPath.section==0&&indexPath.row==0?116:UITableViewAutomaticDimension;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    UIView *control=nil;
    if(ip.section==0){if(ip.row==0){control=self.address;cell.selectionStyle=UITableViewCellSelectionStyleNone;}else if(ip.row==1){control=self.runtime;cell.selectionStyle=UITableViewCellSelectionStyleNone;}else{cell.textLabel.text=@[@"识别链接",@"选择文件（多选）",@"选择文件夹"][ip.row-2];cell.textLabel.textColor=HostAccent();}}
    else if(ip.section==1){if(ip.row==0){control=self.duplicatePolicy;cell.selectionStyle=UITableViewCellSelectionStyleNone;}else{NSDictionary *row=self.candidates[ip.row-1];cell.textLabel.text=row[@"name"]?:@"资源";cell.detailTextLabel.text=row[@"saved"]?@"已保存":(row[@"saveError"]?:row[@"error"]?:row[@"summary"]);cell.accessoryType=[row[@"selected"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;cell.tintColor=HostAccent();}}
    else {cell.textLabel.text=ip.row==0?(self.busy?@"取消当前任务":@"开始新的导入"):@"高级导入方式";cell.textLabel.textColor=HostAccent();}
    if(control){[cell.contentView addSubview:control];control.translatesAutoresizingMaskIntoConstraints=NO;[NSLayoutConstraint activateConstraints:@[[control.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],[control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],[control.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],[control.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12]]];}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(ip.section==2&&ip.row==0){if(self.busy)[self cancelWork];else[self reset];return;}if(self.busy)return;
    if(ip.section==0){if(ip.row==2)[self recognizeURL];else if(ip.row==3||ip.row==4)[self pickFiles:ip.row==4];}
    else if(ip.section==1&&ip.row>0){NSMutableDictionary *row=self.candidates[ip.row-1];if(!row[@"error"]&&![row[@"saved"] boolValue]){row[@"selected"]=@(![row[@"selected"] boolValue]);self.finished=NO;}[self updateView];}
    else if(ip.section==2&&ip.row==1&&self.onAdvanced){[self.navigationController dismissViewControllerAnimated:YES completion:self.onAdvanced];}
}
- (void)reset {
    self.generation++;[self.fetcher cancel];[self.downloader cancel];for(NSDictionary *row in self.candidates)if(row[@"service"]&&![row[@"saved"] boolValue])[ServiceStore remove:row[@"service"][@"id"]];[self.candidates removeAllObjects];self.finished=NO;self.stage=@"粘贴地址，或选择本地文件";[self updateView];
}
- (void)cancelWork {self.generation++;[self.fetcher cancel];[self.downloader cancel];self.busy=NO;self.stage=@"任务已取消 · 已保存项目保留，可重试未保存项";[self updateView];}
- (NSString *)runtimeHint {return self.runtime.selectedSegmentIndex==1?@"python":(self.runtime.selectedSegmentIndex==2?@"node":nil);}
- (void)showFailure:(NSString *)message {self.busy=NO;self.stage=message?:@"识别失败，请重试";[self updateView];}
- (NSMutableDictionary *)candidateForData:(NSData *)data file:(NSURL *)file origin:(NSString *)origin companions:(NSDictionary *)companions hint:(NSString *)hint {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *fingerprint=[NSMutableString string];for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[fingerprint appendFormat:@"%02x",digest[i]];
    NSError *error=nil;NSMutableDictionary *catalog=[[TVBoxCatalogStore parseData:data sourceURL:origin error:&error] mutableCopy];if(catalog)catalog[@"importFingerprint"]=fingerprint;
    if(catalog){NSArray *sites=catalog[@"sites"]?:@[];NSUInteger recognized=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])recognized++;return [@{@"kind":@"catalog",@"catalog":catalog,@"name":catalog[@"name"]?:file.lastPathComponent?:@"资源合集",@"summary":[NSString stringWithFormat:@"合集 · %lu 个站点 · %lu 个已识别 · %lu 个直播列表",(unsigned long)sites.count,(unsigned long)recognized,(unsigned long)[catalog[@"lives"] count]],@"selected":@YES} mutableCopy];}
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];NSArray *channels=text.length?[M3UParser parse:text baseURL:origin.length?[NSURL URLWithString:origin]:nil]:nil;
    if(channels.count)return [@{@"kind":@"playlist",@"text":text,@"origin":origin?:@"",@"name":file.lastPathComponent?:@"直播订阅",@"summary":[NSString stringWithFormat:@"直播列表 · %lu 个频道",(unsigned long)channels.count],@"selected":@YES} mutableCopy];
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];if(origin.length&&[json isKindOfClass:NSDictionary.class]&&[json[@"list"] isKindOfClass:NSArray.class]){NSDictionary *api=[TVBoxCatalogStore catalogWithMacCMSAPIURL:origin name:nil error:&error];if(api)return [@{@"kind":@"catalog",@"catalog":api,@"name":api[@"name"]?:@"影视接口",@"summary":@"MacCMS 影视接口 · 按需连接",@"selected":@YES} mutableCopy];}
    NSDictionary *service=[MediaPackageImporter importFile:file companionFiles:companions runtimeHint:hint error:&error];
    if(service){NSMutableDictionary *imported=[service mutableCopy];if(origin.length)imported[@"url"]=origin;imported[@"importFingerprint"]=fingerprint;return [@{@"kind":@"service",@"service":imported,@"name":service[@"name"]?:file.lastPathComponent,@"summary":[NSString stringWithFormat:@"脚本资源 · %@ · %@",service[@"engine"]?:@"自动识别",service[@"protocol"]?:@"启动后验证能力"],@"selected":@YES} mutableCopy];}
    return [@{@"name":file.lastPathComponent?:@"资源",@"error":error.localizedDescription?:@"不支持或无法识别此文件",@"selected":@NO} mutableCopy];
}
- (void)recognizeURL {
    if(self.candidates.count){[self showFailure:@"请先保存当前预览，或开始新的导入"];return;}
    NSString *raw=[self.address.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSURL *url=[NSURL URLWithString:raw];
    if(!url.host.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||[raw rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound){[self showFailure:@"请输入一个完整的 HTTP / HTTPS 链接"];return;}
    if([raw rangeOfString:@"\\.jsonhttps?://" options:NSRegularExpressionSearch].location!=NSNotFound){[self showFailure:@"可能粘贴了多个链接，请每次识别一个完整地址"];return;}
    [self.view endEditing:YES];self.busy=YES;self.stage=@"正在下载与识别…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    if([@[@"py",@"js",@"zip",@"md5"] containsObject:url.pathExtension.lowercaseString]){
        self.downloader=[MediaPackageDownloader new];self.downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;owner.stage=expected>0?[NSString stringWithFormat:@"%@ · %.1f / %.1f MiB",stage,received/1048576.0,expected/1048576.0]:[NSString stringWithFormat:@"%@ · %.1f MiB",stage,received/1048576.0];if(owner.onStateChanged)owner.onStateChanged();[owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];};
        [self.downloader importURL:url headers:nil runtimeHint:hint completion:^(NSDictionary *service,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){if(service)[ServiceStore remove:service[@"id"]];return;}if(!service){[owner showFailure:error.localizedDescription];return;}[owner.candidates addObject:[@{@"kind":@"service",@"service":service,@"name":service[@"name"]?:@"脚本资源",@"summary":[NSString stringWithFormat:@"已识别 · %@ · %@",service[@"engine"]?:@"",service[@"protocol"]?:@""],@"selected":@YES} mutableCopy]];owner.busy=NO;owner.stage=@"识别完成 · 尚未保存";[owner updateView];}];return;
    }
    self.fetcher=[ResourceImportFetcher new];self.fetcher.completion=^(NSData *data,NSURLResponse *response,NSError *error){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;if(error){[owner showFailure:error.localizedDescription];return;}
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];NSString *ext=([text containsString:@"class Spider"]||[text containsString:@"def init("])?@"py":@"js";NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"resource-%@.%@",NSUUID.UUID.UUIDString,ext]];[data writeToFile:path atomically:YES];NSMutableDictionary *row=[owner candidateForData:data file:[NSURL fileURLWithPath:path] origin:raw companions:@{} hint:hint];[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{if(owner.generation!=generation){if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}[owner.candidates addObject:row];owner.busy=NO;owner.stage=@"识别完成 · 请选择要保存的资源";[owner updateView];});
        });
    };[self.fetcher load:url];
}
- (void)pickFiles:(BOOL)folder {
    if(self.candidates.count){[self showFailure:@"请先保存当前预览，或开始新的导入"];return;}self.pickingFolder=folder;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder?UTTypeFolder:UTTypeData] asCopy:!folder];picker.allowsMultipleSelection=!folder;picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(!urls.count)return;BOOL folder=self.pickingFolder;self.busy=YES;self.stage=@"正在检查本地文件…";NSUInteger generation=++self.generation;NSString *hint=[self runtimeHint];[self updateView];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        NSURL *root=folder?urls.firstObject:nil;BOOL scoped=[root startAccessingSecurityScopedResource];NSMutableArray *files=[NSMutableArray array];BOOL truncated=NO;
        if(folder){NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url,NSError *error){return NO;}];for(NSURL *url in enumerator){NSNumber *regular=nil,*link=nil;[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];if(link.boolValue){[enumerator skipDescendants];continue;}if(!regular.boolValue)continue;if(![@[@"json",@"js",@"py",@"zip",@"txt",@"m3u",@"m3u8",@"php"] containsObject:url.pathExtension.lowercaseString])continue;if(files.count==128){truncated=YES;break;}[files addObject:url];}}
        else {truncated=urls.count>128;[files addObjectsFromArray:[urls subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)128,urls.count))]];}
        NSMutableArray *rows=[NSMutableArray array];NSUInteger total=0;
        for(NSURL *file in files){ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation)break;BOOL childScope=[file startAccessingSecurityScopedResource];NSNumber *size=nil;[file getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];NSData *data=nil;if(size.unsignedLongLongValue<=32*1024*1024&&total+size.unsignedLongLongValue<=64*1024*1024)data=[NSData dataWithContentsOfURL:file];if(data)total+=data.length;
            NSMutableDictionary *companions=[NSMutableDictionary dictionary];if([@[@"js",@"mjs",@"cjs"] containsObject:file.pathExtension.lowercaseString]&&![file.lastPathComponent isEqual:@"index.config.js"]){for(NSURL *other in files)if([other.lastPathComponent isEqual:@"index.config.js"]&&[other.URLByDeletingLastPathComponent isEqual:file.URLByDeletingLastPathComponent]){BOOL access=[other startAccessingSecurityScopedResource];NSNumber *bytes=nil;[other getResourceValue:&bytes forKey:NSURLFileSizeKey error:NULL];if(bytes.unsignedLongLongValue<=65536){NSData *configuration=[NSData dataWithContentsOfURL:other];if(configuration)companions[@"index.config.js"]=configuration;}if(access)[other stopAccessingSecurityScopedResource];break;}}
            NSMutableDictionary *row=data?[owner candidateForData:data file:file origin:nil companions:companions hint:hint]:[@{@"name":file.lastPathComponent,@"error":@"无法读取或超过本次导入大小上限",@"selected":@NO} mutableCopy];[rows addObject:row];if(childScope)[file stopAccessingSecurityScopedResource];
        }
        if(scoped)[root stopAccessingSecurityScopedResource];dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner||owner.generation!=generation){for(NSDictionary *row in rows)if(row[@"service"])[ServiceStore remove:row[@"service"][@"id"]];return;}[owner.candidates addObjectsFromArray:rows];owner.busy=NO;owner.stage=truncated?@"已检查前 128 个文件 · 部分文件未处理":(rows.count?@"本地文件识别完成 · 尚未保存":@"未发现支持的资源文件");[owner updateView];});
    }});
}
- (void)saveSelected {if(self.busy||!self.onSaveCandidate)return;self.busy=YES;self.stage=@"正在保存资源…";NSUInteger generation=++self.generation;[self updateView];[self saveNext:0 generation:generation];}
- (void)saveNext:(NSUInteger)index generation:(NSUInteger)generation {
    if(self.generation!=generation)return;
    if(index>=self.candidates.count){self.busy=NO;NSUInteger saved=0,failed=0,pending=0;for(NSDictionary *row in self.candidates){if([row[@"saved"] boolValue])saved++;else if(row[@"error"]||row[@"saveError"])failed++;else if([row[@"selected"] boolValue])pending++;}self.finished=failed==0&&pending==0;self.stage=[NSString stringWithFormat:@"已保存 %lu 项 · 失败 / 不支持 %lu 项",(unsigned long)saved,(unsigned long)failed];[self updateView];return;}
    NSMutableDictionary *row=self.candidates[index];if(![row[@"selected"] boolValue]||row[@"error"]||[row[@"saved"] boolValue]){[self saveNext:index+1 generation:generation];return;}
    __weak typeof(self) weakSelf=self;self.onSaveCandidate(row,self.duplicatePolicy.selectedSegmentIndex==0,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ResourceImportWorkflowViewController *owner=weakSelf;if(!owner)return;if(error)row[@"saveError"]=error.localizedDescription?:@"保存失败";else{row[@"saved"]=@YES;[row removeObjectForKey:@"saveError"];}[owner updateView];[owner saveNext:index+1 generation:generation];});});
}
@end
