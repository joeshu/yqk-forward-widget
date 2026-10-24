#!/usr/bin/env python3
"""Build-only preparation of the pre-Python 0.9 controller plus timing/export probes.

Changes the ephemeral CI checkout, never used for the full or no-python build.
Playback ordering, options, framework versions and EPG behavior are left as in 0.9.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = subprocess.check_output([
    'git', 'show', '2966473:cctv-ios-host/Sources/RootViewController.m'
], cwd=root, text=True)
source = source.replace('#import "RootViewController.h"', '#import "RootViewController.h"\n#import <QuartzCore/QuartzCore.h>')
source = source.replace('[self log:@"SDK 启动版本 %@", ver]', '[self log:@"CCTVHost 0.9.0 · SDK %@ · baseline09", ver]')
pos = source.index('@end')
source = source[:pos] + '@property(nonatomic,assign) NSTimeInterval baselineStartedAt;\n' + source[pos:]
source = source.replace('    self.firstRender = NO;', '    self.firstRender = NO;self.baselineStartedAt=CACurrentMediaTime();')
source = source.replace('[self log:@"首帧渲染"];', '[self log:@"首帧渲染 %.2fs",CACurrentMediaTime()-self.baselineStartedAt];')
source = source.replace('    [super viewDidLoad];', '''    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"导出对照日志" style:UIBarButtonItemStylePlain target:self action:@selector(exportBaselineLog)];''')
pos = source.rfind('@end')
source = source[:pos] + '''- (void)exportBaselineLog {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"cctvhost-baseline09.log"];
    [self.logBuffer writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    v.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    [self presentViewController:v animated:YES completion:nil];
}
''' + source[pos:]
(root / 'Sources/RootViewController.m').write_text(source)
