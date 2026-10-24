#import "MediaEpisodeSelectionViewController.h"
#import "MediaAPIClient.h"
#import "HostTheme.h"

@interface MediaEpisodeSelectionViewController ()
@property(nonatomic) NSUInteger generation;
@end
@implementation MediaEpisodeSelectionViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewDidLoad {[super viewDidLoad];self.title=@"选择线路和剧集";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=58;self.tableView.estimatedRowHeight=58;self.selectedLineIndex=MAX(0,self.selectedLineIndex);self.navigationItem.prompt=self.lines.count?[NSString stringWithFormat:@"%@ · 选择要播放的分集",self.detail[@"name"]?:self.item[@"name"]?:@"影片"]:@"此影片没有可用分集";}
- (void)dealloc {[self.client cancel];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return self.lines.count;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {NSArray *episodes=[self.lines[section][@"episodes"] isKindOfClass:NSArray.class]?self.lines[section][@"episodes"]:@[];return episodes.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {NSDictionary *line=self.lines[section];NSArray *episodes=[line[@"episodes"] isKindOfClass:NSArray.class]?line[@"episodes"]:@[];return [NSString stringWithFormat:@"%@ · %lu 集",line[@"name"]?:[NSString stringWithFormat:@"线路 %ld",(long)section+1],(unsigned long)episodes.count];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return section==0?@"选择具体分集后会先解析，再进入播放器；切换分集时只采用最后一次选择。":nil;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media.episode"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media.episode"];NSDictionary *line=self.lines[ip.section],*episode=line[@"episodes"][ip.row];BOOL selected=self.selectionUpdatesPlayer&&ip.section==self.selectedLineIndex&&ip.row==self.selectedEpisodeIndex;cell.backgroundColor=HostCard();cell.textLabel.text=episode[@"name"]?:[NSString stringWithFormat:@"第 %ld 集",(long)ip.row+1];cell.textLabel.textColor=selected?HostAccent():UIColor.labelColor;cell.detailTextLabel.text=selected?@"当前播放位置 · 点击切换":@"点击解析并播放";cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(ip.section>=self.lines.count)return;
    NSDictionary *line=self.lines[ip.section],*episode=line[@"episodes"][ip.row];self.selectedLineIndex=ip.section;self.selectedEpisodeIndex=ip.row;[self.tableView reloadData];
    NSUInteger generation=++self.generation;self.navigationItem.prompt=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;
    __weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args completion:^(id result,NSError *error){
        MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;
        owner.navigationItem.prompt=[NSString stringWithFormat:@"%@ · 选择要播放的分集",owner.detail[@"name"]?:owner.item[@"name"]?:@"影片"];
        if(error||![result isKindOfClass:NSDictionary.class]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"无法播放此分集" message:error.localizedDescription?:@"来源没有返回可播放结果，请选择其他线路或分集。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[owner presentViewController:alert animated:YES completion:nil];return;}
        NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"lineIndex":@(ip.section),@"episodeIndex":@(ip.row)};
        if(owner.onSelectEpisode)owner.onSelectEpisode(result,context);
        if(owner.selectionUpdatesPlayer&&owner.navigationController.topViewController==owner)[owner.navigationController popViewControllerAnimated:YES];
    }];
}
@end
