#import <UIKit/UIKit.h>
#import "ResourceImportWorkflowViewController.h"
@interface ResourceImportWorkflowViewController (SnapshotProbe)
- (void)writeCurrentSnapshot;
@end
static BOOL waitForRestore(ResourceImportWorkflowViewController *controller) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
    while([[controller valueForKey:@"restoringSnapshot"] boolValue]&&[deadline timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ![[controller valueForKey:@"restoringSnapshot"] boolValue];
}
BOOL ImportSnapshotRunSmokeChecks(void) {
    ResourceImportWorkflowViewController *first=[ResourceImportWorkflowViewController new];if(!waitForRestore(first)){NSLog(@"IMPORT_SNAPSHOT_PROBE initial restore timed out");return NO;}
    NSMutableData *payload=[NSMutableData dataWithLength:2*1024*1024];memset(payload.mutableBytes,0x5A,payload.length);
    [first setValue:[NSMutableArray arrayWithObject:[@{@"name":@"snapshot fixture",@"retryData":payload,@"selected":@NO} mutableCopy]] forKey:@"candidates"];
    [first setValue:@"snapshot fixture" forKey:@"stage"];[first writeCurrentSnapshot];
    ResourceImportWorkflowViewController *restored=[ResourceImportWorkflowViewController new];if(!waitForRestore(restored)){NSLog(@"IMPORT_SNAPSHOT_PROBE blob restore timed out");return NO;}
    NSArray *rows=[restored valueForKey:@"candidates"];BOOL blobRestored=rows.count==1&&[rows[0][@"retryData"] isEqual:payload];
    if(!blobRestored)NSLog(@"IMPORT_SNAPSHOT_PROBE blob restore mismatch rows=%lu dataClass=%@ dataLength=%lu expectedLength=%lu stage=%@",(unsigned long)rows.count,rows.count?NSStringFromClass([rows[0][@"retryData"] class]):@"none",(unsigned long)[rows.firstObject[@"retryData"] length],(unsigned long)payload.length,[restored valueForKey:@"stage"]);
    // Rapid updates must leave the final snapshot, not an earlier queued write.
    for(NSUInteger i=0;i<8;i++){[restored setValue:[NSString stringWithFormat:@"revision %lu",(unsigned long)i] forKey:@"stage"];[restored writeCurrentSnapshot];}
    ResourceImportWorkflowViewController *latest=[ResourceImportWorkflowViewController new];BOOL latestRestored=waitForRestore(latest);BOOL finalRevision=latestRestored&&[[latest valueForKey:@"stage"] isEqual:@"revision 7"];
    if(!latestRestored||!finalRevision)NSLog(@"IMPORT_SNAPSHOT_PROBE final revision mismatch restored=%d stage=%@",latestRestored,[latest valueForKey:@"stage"]);
    [latest setValue:[NSMutableArray array] forKey:@"candidates"];[latest setValue:@"" forKey:@"restoredAddress"];[latest setValue:@"粘贴地址，或选择本地文件" forKey:@"stage"];[latest writeCurrentSnapshot];
    ResourceImportWorkflowViewController *cleared=[ResourceImportWorkflowViewController new];BOOL clearedRestored=waitForRestore(cleared);BOOL clearedSnapshot=clearedRestored&&[[cleared valueForKey:@"candidates"] count]==0;
    if(!clearedRestored||!clearedSnapshot)NSLog(@"IMPORT_SNAPSHOT_PROBE clear mismatch restored=%d rows=%lu",clearedRestored,(unsigned long)[[cleared valueForKey:@"candidates"] count]);
    return blobRestored&&finalRevision&&clearedSnapshot;
}
