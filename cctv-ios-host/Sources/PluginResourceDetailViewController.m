#import "PluginResourceDetailViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "PyHost.h"
#import "ServiceStore.h"
#import "ProfileStore.h"
#import "M3UParser.h"
#import "RuntimeDiagnostics.h"

@interface PluginResourceDetailViewController () <UITableViewDataSource,UITableViewDelegate,NSURLSessionDataDelegate,NSURLSessionTaskDelegate>
@property(nonatomic,strong) UILabel *notice;
@property(nonatomic) BOOL operationPending;
@property(nonatomic,copy) NSString *probeStatus;
@property(nonatomic,strong) NSURLSession *probeSession;
@property(nonatomic,strong) NSURLSessionDataTask *probeTask;
@property(nonatomic,strong) NSMutableData *probeData;
@property(nonatomic,copy) NSArray<NSString *> *playlistCandidates;
@property(nonatomic,copy) NSString *resolvedPlaylistPath;
@property(nonatomic) NSUInteger probeGeneration;
@property(nonatomic) NSInteger probeStatusCode;
@property(nonatomic,strong) NSURL *probeResponseURL;
@property(nonatomic) NSInteger probeChannelCount;
@property(nonatomic) BOOL probingPlaylist;
@property(nonatomic) BOOL probePlaylistChecked;
@property(nonatomic,copy) NSArray<NSString *> *probePaths;
@property(nonatomic) NSUInteger probePathIndex;
@property(nonatomic) NSInteger probeLastHTTPStatus;
@property(nonatomic,copy) NSString *probeLastFailure;
- (NSString *)baseURL;
- (void)showNotice:(NSString *)message;
- (void)showError:(NSString *)message;
- (void)probeNextPlaylistPath;
@end

@implementation PluginResourceDetailViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (BOOL)mediaCapable {return [ServiceStore isVODMediaService:self.service];}
- (NSArray<NSString *> *)serviceCapabilities {id caps=self.service[@"capabilities"];if(![caps isKindOfClass:NSArray.class]){NSDictionary *manifest=[self.service[@"manifest"] isKindOfClass:NSDictionary.class]?self.service[@"manifest"]:@{};caps=manifest[@"capabilities"];}return [caps isKindOfClass:NSArray.class]?caps:@[];}
- (BOOL)liveCapable {return [ServiceStore subscriptionURLForService:self.service].length>0||[[self serviceCapabilities] containsObject:@"live"];}
- (void)refreshPlaylistPathState {self.resolvedPlaylistPath=[ServiceStore playlistPathForService:self.service];self.playlistCandidates=[ServiceStore playlistPathCandidatesForService:self.service];}
- (BOOL)running {return [PyHost isRunningServiceIdentifier:self.service[@"id"]];}
- (NSString *)baseURL {NSInteger port=[self.service[@"port"] integerValue];return [NSString stringWithFormat:@"http://127.0.0.1:%ld",(long)port];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.service[@"name"]?:@"资源详情";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=58;
    self.notice=[UILabel new];self.notice.textColor=UIColor.secondaryLabelColor;self.notice.numberOfLines=0;self.notice.textAlignment=NSTextAlignmentCenter;self.tableView.backgroundView=self.notice;
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"square.and.pencil",@"title":@"编辑配置",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onEdit)w.onEdit(w.service);}]}])];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];for(NSDictionary *latest in [ServiceStore services])if([latest[@"id"] isEqual:self.service[@"id"]]){self.service=latest;break;}self.title=self.service[@"name"];[self refreshPlaylistPathState];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged) name:PyHostRuntimeStateDidChangeNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(metadataDidChange) name:ProfileStoreMetadataDidChangeNotification object:nil];[self.tableView reloadData];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];[NSNotificationCenter.defaultCenter removeObserver:self name:ProfileStoreMetadataDidChangeNotification object:nil];self.probeGeneration++;self.probingPlaylist=NO;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];self.probeSession=nil;}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.probeTask cancel];[self.probeSession invalidateAndCancel];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {completionHandler(nil);}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {BOOL valid=task==self.probeTask&&[response isKindOfClass:NSHTTPURLResponse.class]&&response.expectedContentLength<=1024*1024;self.probeStatusCode=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;self.probeResponseURL=response.URL;completion(valid?NSURLSessionResponseAllow:NSURLSessionResponseCancel);}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {if(task!=self.probeTask)return;if(self.probeData.length+data.length>1024*1024){[task cancel];return;}[self.probeData appendData:data];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(task!=self.probeTask)return;
    NSUInteger generation=self.probeGeneration;
    NSData *data=[self.probeData copy];
    NSInteger status=self.probeStatusCode;
    NSURL *url=self.probeResponseURL;
    NSUInteger pathIndex=self.probePathIndex;
    NSString *attemptedPath=pathIndex<self.probePaths.count?self.probePaths[pathIndex]:@"";
    dispatch_async(dispatch_get_main_queue(),^{
        if(generation!=self.probeGeneration)return;
        self.probeTask=nil;
        if(error){self.probeLastFailure=error.code==NSURLErrorCancelled?@"响应超过 1 MiB 或请求已取消":(error.localizedDescription?:@"连接失败");self.probeLastHTTPStatus=0;}
        else{
            self.probeLastHTTPStatus=status;
            if(status>=200&&status<300){
                NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSArray *channels=text?[M3UParser parse:text baseURL:url]:@[];
                BOOL playlistFormat=[text containsString:@"#EXTM3U"]||[text containsString:@"#EXTINF"]||channels.count>0;
                if(playlistFormat&&channels.count>0){
                    self.probePlaylistChecked=YES;self.probeChannelCount=(NSInteger)channels.count;self.probingPlaylist=NO;
                    NSMutableDictionary *updated=[self.service mutableCopy];updated[@"playlistPath"]=attemptedPath;
                    if(![updated[@"playlistPathSource"] isEqual:@"manual"])updated[@"playlistPathSource"]=@"detected";
                    [ServiceStore save:updated];self.service=updated;[self refreshPlaylistPathState];
                    NSString *subscriptionURL=[ServiceStore subscriptionURLForService:self.service];
                    self.probeStatus=[NSString stringWithFormat:subscriptionURL.length&&self.onPlaylistDiscovered?@"已识别 %@ · %lu 个频道 · 已加入资源列表":@"已识别 %@ · %lu 个频道 · 请检查订阅地址",attemptedPath,(unsigned long)channels.count];
                    [RuntimeDiagnostics.shared recordEvent:@"service_playlist_endpoint_discovered" category:@"service" fields:@{@"service_id":self.service[@"id"]?:@"",@"engine":self.service[@"engine"]?:@"unknown",@"protocol":self.service[@"protocol"]?:@"unknown",@"candidate_index":@(pathIndex),@"candidate_count":@(self.probePaths.count),@"channel_count":@(channels.count),@"path_length":@(attemptedPath.length)}];
                    [self.probeSession finishTasksAndInvalidate];self.probeSession=nil;
                    if(subscriptionURL.length&&self.onPlaylistDiscovered)self.onPlaylistDiscovered(self.service,subscriptionURL,channels.count);
                    [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];
                    return;
                }
                self.probeLastFailure=playlistFormat?@"列表有效但没有频道":@"响应不是 M3U 频道列表";
            }else self.probeLastFailure=[NSString stringWithFormat:@"HTTP %ld",(long)status];
        }
        if(pathIndex+1<self.probePaths.count){self.probePathIndex=pathIndex+1;[self probeNextPlaylistPath];return;}
        self.probingPlaylist=NO;self.probePlaylistChecked=NO;
        self.probeStatus=[NSString stringWithFormat:@"未发现有效节目单 · 已检查 %lu 个本机地址 · %@ · 可编辑填写路径",(unsigned long)self.probePaths.count,self.probeLastFailure.length?self.probeLastFailure:@"无有效响应"];
        [RuntimeDiagnostics.shared recordEvent:@"service_playlist_endpoint_not_found" category:@"service" fields:@{@"service_id":self.service[@"id"]?:@"",@"engine":self.service[@"engine"]?:@"unknown",@"protocol":self.service[@"protocol"]?:@"unknown",@"candidate_count":@(self.probePaths.count),@"last_http_status":@(self.probeLastHTTPStatus)}];
        [self.probeSession finishTasksAndInvalidate];self.probeSession=nil;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];
    });
}
- (void)stateChanged {[self.tableView reloadData];}
- (void)metadataDidChange {if(self.isViewLoaded&&self.view.window)[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 4;}
- (NSArray *)resourceRows {
    NSArray *caps=[self serviceCapabilities];
    NSMutableArray *rows=[NSMutableArray arrayWithArray:@[@{@"title":@"运行能力",@"value":[NSString stringWithFormat:@"%@ · %@",self.service[@"engine"]?:@"未知引擎",self.service[@"protocol"]?:@"未知协议"]},@{@"title":@"能力探测",@"value":caps.count?[caps componentsJoinedByString:@"、"]:@"启动后验证实际能力"}]];
    NSString *version=[self.service[@"manifest"][@"pluginVersion"] isKindOfClass:NSString.class]?self.service[@"manifest"][@"pluginVersion"]:@"";if(version.length)[rows addObject:@{@"title":@"资源版本",@"value":version}];
    NSString *entry=[self.service[@"manifest"][@"entry"] isKindOfClass:NSString.class]?self.service[@"manifest"][@"entry"]:@"";if(entry.length)[rows addObject:@{@"title":@"入口文件",@"value":entry}];
    if(self.mediaCapable)[rows addObject:@{@"title":@"打开影视",@"value":@"资源 → 站点 → 详情选集 → 播放"}];
    if(self.liveCapable)[rows addObject:@{@"title":@"打开直播频道",@"value":@"读取下方显示的本机订阅地址后进入频道页"}];
    if([self.service[@"protocol"] isEqual:@"catpaw-http"]){[rows addObject:@{@"title":@"源配置与账号",@"value":@"管理此源的站点、网盘与登录信息",@"action":@"configuration"}];
        NSDictionary *states=@{@"verified":@"已下载并通过 MD5 校验",@"downloaded_without_checksum":@"已下载 · 来源未提供配置校验",@"missing_using_defaults":@"未提供配套配置 · 启动时使用脚本默认值"};
        [rows addObject:@{@"title":@"配套配置",@"value":states[self.service[@"configurationState"]?:@""]?:([self.service[@"manifest"][@"configEntry"] length]?@"包内配置":@"未知 · 可检查更新补齐")}];}
    NSArray *verifiedLocalChecksums=[self.service[@"manifest"][@"verifiedLocalChecksums"] isKindOfClass:NSArray.class]?self.service[@"manifest"][@"verifiedLocalChecksums"]:@[];
    if([self.service[@"url"] length]){NSString *checksum=[self.service[@"downloadChecksum"] isKindOfClass:NSString.class]?self.service[@"downloadChecksum"]:@"";NSString *status=checksum.length?[NSString stringWithFormat:@"下载 MD5 已通过 · %@（完整性校验，不是数字签名）",checksum]:@"未提供文件校验";if(verifiedLocalChecksums.count)status=[status stringByAppendingFormat:@"；ZIP 内 %@ 已校验",[verifiedLocalChecksums componentsJoinedByString:@"、"]];[rows addObject:@{@"title":@"文件校验",@"value":status}];[rows addObject:@{@"title":@"资源来源",@"value":self.service[@"url"],@"action":@"copySource"}];}
    else if(verifiedLocalChecksums.count)[rows addObject:@{@"title":@"文件校验",@"value":[NSString stringWithFormat:@"ZIP 内 MD5 已通过：%@",[verifiedLocalChecksums componentsJoinedByString:@"、"]]}];
    return rows;
}
- (NSArray *)managementRows {
    if([self.service[@"builtin"] boolValue])return @[];
    NSMutableArray *rows=[NSMutableArray arrayWithObject:@{@"title":@"查看此资源日志",@"value":@"独立日志 · 查看与导出",@"action":@"log"}];
    if([self.service[@"url"] length])[rows addObject:@{@"title":@"检查资源更新",@"value":@"校验新版 · 保留服务 ID、账号和配置",@"action":@"update"}];
    if([self.service[@"previousImport"] isKindOfClass:NSDictionary.class])[rows addObject:@{@"title":@"切回上一版代码",@"value":@"保留账号数据与当前端口",@"action":@"rollback"}];
    [rows addObject:@{@"title":@"移除资源",@"value":@"移除本机代码及配置",@"action":@"remove"}];return rows;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {if(section==0)return self.resourceRows.count;if(section==1)return 4;if(section==2)return 7;return self.managementRows.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"资源能力",@"运行状态",@"本机接口",@"管理与诊断"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"点击“使用”后才会按需启动服务。运行中、接口健康、列表可读和视频解码是不同状态。";if(section==1)return [self.service[@"manifest"][@"compatibilityNote"] isKindOfClass:NSString.class]?self.service[@"manifest"][@"compatibilityNote"]:@"服务可独立启停；停止失败时请查看此资源的日志。";return nil;}
- (NSDictionary *)rowAt:(NSIndexPath *)ip {
    if(ip.section==0)return self.resourceRows[ip.row];
    NSString *port=[NSString stringWithFormat:@"%@",self.service[@"port"]?:@"未知"];
    if(ip.section==1){NSArray *rows=@[@{@"title":@"服务进程",@"value":self.operationPending?@"正在启停…":(self.running?@"运行中 · 视频解码状态未知":@"已停止")},@{@"title":self.running?@"停止服务":@"启动服务",@"value":self.running?@"仅停止此服务":@"按需启动此服务",@"action":@"toggle"},@{@"title":@"检测资源接口",@"value":self.probeStatus?:@"点击检测声明的本机接口",@"action":@"probe"},@{@"title":@"运行状态说明",@"value":self.service[@"status"]?:@"暂无状态信息"}];return rows[ip.row];}
    if(ip.section==2){NSString *resolvedPath=self.resolvedPlaylistPath;NSString *pendingPath=self.playlistCandidates.firstObject;NSString *playlist=resolvedPath?: (pendingPath.length?[NSString stringWithFormat:@"待验证 · %@",pendingPath]:@"未发现 · 点击上方检测资源接口");NSInteger servicePort=[self.service[@"port"] integerValue];NSString *resolvedURL=[ServiceStore subscriptionURLForService:self.service];NSString *subscription=resolvedURL?: (pendingPath.length&&servicePort>0?[NSString stringWithFormat:@"待验证 · http://127.0.0.1:%ld%@",(long)servicePort,pendingPath]:@"未识别 · 点击上方检测后加入资源列表");NSString *epg=[ServiceStore epgURLForService:self.service]?:@"尚未从订阅清单中识别";NSDictionary *metadata=resolvedURL.length?[ProfileStore metadata:resolvedURL]:@{};NSArray *cached=[metadata[@"cachedChannels"] isKindOfClass:NSArray.class]?metadata[@"cachedChannels"]:@[];NSString *count=cached.count?[NSString stringWithFormat:@"%lu 个缓存频道",(unsigned long)cached.count]:(self.probePlaylistChecked?[NSString stringWithFormat:@"%ld 个 · 最近一次接口检测",(long)self.probeChannelCount]:@"未知 · 尚未读取有效清单");NSString *status=[metadata[@"status"] isKindOfClass:NSString.class]?metadata[@"status"]:(resolvedURL.length?(self.running?@"服务运行中 · 等待读取":@"服务已停止"): @"未配置已验证的播放列表");NSTimeInterval updated=[metadata[@"updatedAt"] doubleValue];NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"yyyy-MM-dd HH:mm";NSString *last=updated>0?[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]:@"尚无成功记录";NSArray *rows=@[@{@"title":@"复制本机服务地址",@"value":[NSString stringWithFormat:@"http://127.0.0.1:%@",port],@"action":@"copy"},@{@"title":@"服务订阅地址",@"value":subscription},@{@"title":@"节目单地址",@"value":epg},@{@"title":@"播放列表路径",@"value":playlist},@{@"title":@"频道数量",@"value":count},@{@"title":@"订阅清单状态",@"value":status},@{@"title":@"最近成功刷新",@"value":last}];NSMutableDictionary *row=[rows[ip.row] mutableCopy];BOOL subscriptionURL=[subscription hasPrefix:@"http://"]||[subscription hasPrefix:@"https://"];BOOL epgURL=[epg hasPrefix:@"http://"]||[epg hasPrefix:@"https://"];if((ip.row==1&&subscriptionURL)||(ip.row==2&&epgURL))row[@"action"]=@"copy";return row;}
    return self.managementRows[ip.row];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {NSDictionary *row=[self rowAt:ip];BOOL sourceURL=[row[@"action"] isEqual:@"copySource"],copyURL=[row[@"action"] isEqual:@"copy"];BOOL address=sourceURL||copyURL;NSString *reuse=address?@"service.resource.address":@"service.resource.value";UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:address?UITableViewCellStyleSubtitle:UITableViewCellStyleValue1 reuseIdentifier:reuse];cell.backgroundColor=HostCard();cell.textLabel.text=row[@"title"];cell.textLabel.textColor=HostText();cell.textLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.text=row[@"value"];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textAlignment=address?NSTextAlignmentLeft:NSTextAlignmentNatural;cell.accessoryType=row[@"action"]?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=row[@"action"]?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;return cell;}
- (void)probeInterface {
    if(self.probingPlaylist)return;
    if(!self.running){self.probeStatus=@"服务未运行 · 启动后可检测节目单地址";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];return;}
    NSArray<NSString *> *paths=self.playlistCandidates?:@[];
    if(!paths.count){self.probeStatus=@"此资源未提供本机播放列表接口";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];return;}
    self.probeGeneration++;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];
    self.probePaths=paths;self.probePathIndex=0;self.probeLastHTTPStatus=0;self.probeLastFailure=@"";self.probeData=[NSMutableData data];self.probeChannelCount=0;self.probePlaylistChecked=NO;self.probingPlaylist=YES;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=1.5;config.timeoutIntervalForResource=2;config.HTTPMaximumConnectionsPerHost=2;config.URLCache=nil;config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;self.probeSession=[NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.probeStatus=[NSString stringWithFormat:@"正在检测 %lu 个本机节目单地址…",(unsigned long)paths.count];[self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];[self probeNextPlaylistPath];
}
- (void)probeNextPlaylistPath {
    if(!self.probingPlaylist||self.probePathIndex>=self.probePaths.count)return;
    NSString *path=self.probePaths[self.probePathIndex];NSInteger port=[self.service[@"port"] integerValue];
    NSString *trimmed=[path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(port<1||port>65535||![trimmed isEqualToString:path]||![path hasPrefix:@"/"]||[path hasPrefix:@"//"]||[path containsString:@".."]||[path containsString:@"?"]||[path containsString:@"#"]||[path containsString:@"\\"]||[path containsString:@":"]||[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){
        self.probeLastFailure=@"候选路径无效";self.probePathIndex++;[self probeNextPlaylistPath];return;
    }
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"%@%@",self.baseURL,path]];
    if(!url||![url.host isEqual:@"127.0.0.1"]){self.probeLastFailure=@"本机接口地址无效";self.probePathIndex++;[self probeNextPlaylistPath];return;}
    self.probeData=[NSMutableData data];self.probeStatusCode=0;self.probeResponseURL=nil;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=@"GET";request.timeoutInterval=1.5;[request setValue:@"application/vnd.apple.mpegurl, application/x-mpegURL, text/plain" forHTTPHeaderField:@"Accept"];
    self.probeTask=[self.probeSession dataTaskWithRequest:request];[self.probeTask resume];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {[tableView deselectRowAtIndexPath:ip animated:YES];NSDictionary *row=[self rowAt:ip];NSString *action=row[@"action"];if(ip.section==0 && [row[@"title"] isEqual:@"打开影视"]){if(self.onUse)self.onUse(self.service,@"vod");return;}if(ip.section==0 && [row[@"title"] isEqual:@"打开直播频道"]){if(self.onUse)self.onUse(self.service,@"live");return;}if([action isEqual:@"configuration"]){if(self.onUse)self.onUse(self.service,@"configuration");return;}if([action isEqual:@"update"]){if(self.onUpdate)self.onUpdate(self.service);return;}if([action isEqual:@"rollback"]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"切回上一版代码？" message:@"会先停止此服务，再切换到保留的上一版代码。账号、日志和当前端口会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"切换" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onRollback)self.onRollback(self.service);}]];[self presentViewController:alert animated:YES completion:nil];return;}if([action isEqual:@"toggle"]){if(self.operationPending)return;if(!self.onToggle){[self showError:@"服务控制暂不可用"];return;}self.operationPending=YES;[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];__weak typeof(self) weakSelf=self;self.onToggle(self.service,!self.running,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{PluginResourceDetailViewController *owner=weakSelf;if(!owner)return;owner.operationPending=NO;if(error)[owner showError:error.localizedDescription?:@"服务操作失败，请查看此资源日志"];[owner.tableView reloadData];});});return;}if([action isEqual:@"probe"]){[self probeInterface];return;}if([action isEqual:@"copy"]||[action isEqual:@"copySource"]){UIPasteboard.generalPasteboard.string=row[@"value"];NSString *message=[action isEqual:@"copySource"]?@"资源来源地址已复制（包含原查询参数）":([row[@"title"] isEqual:@"节目单地址"]?@"节目单地址已复制":([row[@"title"] isEqual:@"服务订阅地址"]?@"服务订阅地址已复制":@"本机服务地址已复制"));[self showNotice:message];return;}if([action isEqual:@"log"]){if(self.onLog)self.onLog(self.service);return;}if([action isEqual:@"remove"]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除此资源？" message:@"会移除本机服务代码及配置。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){if(self.onRemove)self.onRemove(self.service);}]];[self presentViewController:alert animated:YES completion:nil];}}
- (void)showNotice:(NSString *)message {if(!message.length)return;self.navigationItem.prompt=message;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if([self.navigationItem.prompt isEqual:message])self.navigationItem.prompt=nil;});}
- (void)showError:(NSString *)message {if(!message.length)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"服务操作失败" message:message preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onLog)self.onLog(self.service);}]];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
@end
