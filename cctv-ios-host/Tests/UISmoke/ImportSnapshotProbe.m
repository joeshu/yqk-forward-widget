#import <UIKit/UIKit.h>
#import "ResourceImportWorkflowViewController.h"

@interface ResourceImportWorkflowViewController (SnapshotProbe)
- (void)writeCurrentSnapshot;
@end

typedef void (^ImportSnapshotProbeCompletion)(BOOL passed);

static void waitForRestore(ResourceImportWorkflowViewController *controller, NSDate *deadline, ImportSnapshotProbeCompletion completion) {
    if(![[controller valueForKey:@"restoringSnapshot"] boolValue]){completion(YES);return;}
    if([deadline timeIntervalSinceNow]<=0){completion(NO);return;}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        waitForRestore(controller,deadline,completion);
    });
}

void ImportSnapshotRunSmokeChecksAsync(ImportSnapshotProbeCompletion completion) {
    ResourceImportWorkflowViewController *first=[ResourceImportWorkflowViewController new];
    waitForRestore(first,[NSDate dateWithTimeIntervalSinceNow:30],^(BOOL firstRestored){
        if(!firstRestored){NSLog(@"IMPORT_SNAPSHOT_PROBE initial restore timed out");completion(NO);return;}
        NSMutableData *payload=[NSMutableData dataWithLength:2*1024*1024];memset(payload.mutableBytes,0x5A,payload.length);
        [first setValue:[NSMutableArray arrayWithObject:[@{@"name":@"snapshot fixture",@"retryData":payload,@"selected":@NO} mutableCopy]] forKey:@"candidates"];
        [first setValue:@"snapshot fixture" forKey:@"stage"];[first writeCurrentSnapshot];

        ResourceImportWorkflowViewController *restored=[ResourceImportWorkflowViewController new];
        waitForRestore(restored,[NSDate dateWithTimeIntervalSinceNow:30],^(BOOL didRestoreBlob){
            NSArray *rows=[restored valueForKey:@"candidates"];
            BOOL blobRestored=didRestoreBlob&&rows.count==1&&[rows[0][@"retryData"] isEqual:payload];
            if(!blobRestored)NSLog(@"IMPORT_SNAPSHOT_PROBE blob restore mismatch restored=%d rows=%lu dataClass=%@ dataLength=%lu expectedLength=%lu stage=%@",didRestoreBlob,(unsigned long)rows.count,rows.count?NSStringFromClass([rows[0][@"retryData"] class]):@"none",(unsigned long)[rows.firstObject[@"retryData"] length],(unsigned long)payload.length,[restored valueForKey:@"stage"]);

            // Rapid updates must leave the final snapshot, not an earlier queued write.
            for(NSUInteger i=0;i<8;i++){[restored setValue:[NSString stringWithFormat:@"revision %lu",(unsigned long)i] forKey:@"stage"];[restored writeCurrentSnapshot];}
            ResourceImportWorkflowViewController *latest=[ResourceImportWorkflowViewController new];
            waitForRestore(latest,[NSDate dateWithTimeIntervalSinceNow:30],^(BOOL latestRestored){
                BOOL finalRevision=latestRestored&&[[latest valueForKey:@"stage"] isEqual:@"revision 7"];
                if(!latestRestored||!finalRevision)NSLog(@"IMPORT_SNAPSHOT_PROBE final revision mismatch restored=%d stage=%@",latestRestored,[latest valueForKey:@"stage"]);
                [latest setValue:[NSMutableArray array] forKey:@"candidates"];[latest setValue:@"" forKey:@"restoredAddress"];[latest setValue:@"粘贴地址，或选择本地文件" forKey:@"stage"];[latest writeCurrentSnapshot];

                ResourceImportWorkflowViewController *cleared=[ResourceImportWorkflowViewController new];
                waitForRestore(cleared,[NSDate dateWithTimeIntervalSinceNow:30],^(BOOL clearedRestored){
                    BOOL clearedSnapshot=clearedRestored&&[[cleared valueForKey:@"candidates"] count]==0;
                    if(!clearedRestored||!clearedSnapshot)NSLog(@"IMPORT_SNAPSHOT_PROBE clear mismatch restored=%d rows=%lu",clearedRestored,(unsigned long)[[cleared valueForKey:@"candidates"] count]);
                    completion(blobRestored&&finalRevision&&clearedSnapshot);
                });
            });
        });
    });
}
