#import "LocalMediaViewController.h"
#import "MediaPlaybackViewController.h"
#import "HostTheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
static NSString *LocalMediaBoundedNamePart(NSString *value,NSUInteger maximumUTF8Bytes) {
    NSMutableString *result=[NSMutableString string];NSUInteger bytes=0;
    for(NSUInteger index=0;index<value.length;){NSRange range=[value rangeOfComposedCharacterSequenceAtIndex:index];NSString *part=[value substringWithRange:range];NSUInteger partBytes=[part lengthOfBytesUsingEncoding:NSUTF8StringEncoding];if(bytes+partBytes>maximumUTF8Bytes)break;[result appendString:part];bytes+=partBytes;index=NSMaxRange(range);}
    return result.copy;
}
@interface LocalMediaViewController () <UIDocumentPickerDelegate>
@property(nonatomic,copy) NSArray<NSURL *> *files;
@property(nonatomic) BOOL importing;
@end
@implementation LocalMediaViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSURL *)directory {
    NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory=[support URLByAppendingPathComponent:@"CCTVHost/LocalMedia" isDirectory:YES];[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];return directory;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"本地媒体";self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=64;self.tableView.backgroundColor=HostBackground();self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importMedia)];[self reloadFiles];
}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();[self.tableView reloadData];}
- (void)reloadFiles {
    self.files=[[NSFileManager.defaultManager contentsOfDirectoryAtURL:[self directory] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];}];[self.tableView reloadData];
    self.navigationItem.prompt=self.files.count?@"点击播放 · 左滑删除本机副本":@"添加视频或音频文件；导入会保存本机副本";
}
- (void)importMedia {if(self.importing)return;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie,UTTypeAudio,UTTypeAudiovisualContent] asCopy:NO];picker.delegate=self;picker.allowsMultipleSelection=YES;[self presentViewController:picker animated:YES completion:nil];}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if(self.importing)return;self.importing=YES;self.navigationItem.rightBarButtonItem.enabled=NO;self.navigationItem.prompt=@"正在保存本机副本…";NSURL *directory=[self directory];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSMutableArray *failures=[NSMutableArray array];
        for(NSURL *url in urls){BOOL scoped=[url startAccessingSecurityScopedResource];NSString *original=url.lastPathComponent?:@"media";NSString *stem=LocalMediaBoundedNamePart(original.stringByDeletingPathExtension,100);NSString *extension=LocalMediaBoundedNamePart(original.pathExtension,20);if(!stem.length)stem=@"media";NSString *name=[NSString stringWithFormat:@"%@-%@%@%@",NSUUID.UUID.UUIDString,stem,extension.length?@".":@"",extension];NSURL *target=[directory URLByAppendingPathComponent:name];NSError *error=nil;
            NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];__block BOOL copied=NO;
            [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *source){copied=[NSFileManager.defaultManager copyItemAtURL:source toURL:target error:nil];}];
            if(!copied){[NSFileManager.defaultManager removeItemAtURL:target error:nil];[failures addObject:url.lastPathComponent?:@"文件"];}
            if(scoped)[url stopAccessingSecurityScopedResource];
        }
        dispatch_async(dispatch_get_main_queue(),^{LocalMediaViewController *owner=weakSelf;if(!owner)return;owner.importing=NO;owner.navigationItem.rightBarButtonItem.enabled=YES;[owner reloadFiles];if(failures.count)owner.navigationItem.prompt=[NSString stringWithFormat:@"%lu 个文件未能保存，请检查空间或文件访问权限",(unsigned long)failures.count];});
    });
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.files.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"local"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"local"];
    NSString *name=self.files[path.row].lastPathComponent;cell.textLabel.text=name.length>37?[name substringFromIndex:37]:name;cell.textLabel.numberOfLines=0;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];NSURL *url=self.files[path.row];NSString *name=url.lastPathComponent.length>37?[url.lastPathComponent substringFromIndex:37]:url.lastPathComponent;
    MediaPlaybackViewController *page=[MediaPlaybackViewController new];page.title=name;page.context=@{@"localMedia":@YES,@"source":@{@"id":@"local-media",@"name":@"本地媒体"},@"item":@{@"name":name,@"id":url.absoluteString},@"detail":@{@"name":name,@"id":url.absoluteString}};page.result=@{@"url":url.absoluteString,@"directMedia":@YES};[self.navigationController pushViewController:page animated:YES];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {if(style==UITableViewCellEditingStyleDelete){[NSFileManager.defaultManager removeItemAtURL:self.files[path.row] error:nil];[self reloadFiles];}}
@end
