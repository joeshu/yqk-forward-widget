#import <UIKit/UIKit.h>
#import "ResourceImportWorkflowViewController.h"
@interface ResourceImportWorkflowViewController (SnapshotProbe)
- (void)writeCurrentSnapshot;
@end
static BOOL waitForRestore(ResourceImportWorkflowViewController *controller) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while([[controller valueForKey:@"restoringSnapshot"] boolValue]&&[deadline timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ![[controller valueForKey:@"restoringSnapshot"] boolValue];
}
BOOL ImportSnapshotRunSmokeChecks(void) {
    ResourceImportWorkflowViewController *first=[ResourceImportWorkflowViewController new];if(!waitForRestore(first))return NO;
    NSMutableData *payload=[NSMutableData dataWithLength:2*1024*1024];memset(payload.mutableBytes,0x5A,payload.length);
    [first setValue:[NSMutableArray arrayWithObject:[@{@"name":@"snapshot fixture",@"retryData":payload,@"selected":@NO} mutableCopy]] forKey:@"candidates"];
    [first setValue:@"snapshot fixture" forKey:@"stage"];[first writeCurrentSnapshot];
    ResourceImportWorkflowViewController *restored=[ResourceImportWorkflowViewController new];if(!waitForRestore(restored))return NO;
    NSArray *rows=[restored valueForKey:@"candidates"];BOOL valid=rows.count==1&&[rows[0][@"retryData"] isEqual:payload];
    // Rapid updates must leave the final snapshot, not an earlier queued write.
    for(NSUInteger i=0;i<8;i++){[restored setValue:[NSString stringWithFormat:@"revision %lu",(unsigned long)i] forKey:@"stage"];[restored writeCurrentSnapshot];}
    ResourceImportWorkflowViewController *latest=[ResourceImportWorkflowViewController new];valid=waitForRestore(latest)&&[[latest valueForKey:@"stage"] isEqual:@"revision 7"]&&valid;
    [latest setValue:[NSMutableArray array] forKey:@"candidates"];[latest setValue:@"" forKey:@"restoredAddress"];[latest setValue:@"粘贴地址，或选择本地文件" forKey:@"stage"];[latest writeCurrentSnapshot];
    ResourceImportWorkflowViewController *cleared=[ResourceImportWorkflowViewController new];valid=waitForRestore(cleared)&&[[cleared valueForKey:@"candidates"] count]==0&&valid;
    return valid;
}
