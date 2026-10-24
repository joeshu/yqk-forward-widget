#!/usr/bin/env python3
"""Prepare a diagnostic pre-EPG 0.2 controller, with explicit compatibility repairs.

Playback stays fresh CNPlayer -> playLIVE(channelID, delegate, Title) -> prepare.
No source list, EPG, Python, prewarm, or auto resume is added.
"""
from pathlib import Path
import subprocess

BASELINE = '2194ba4973ad3e1ed3ed1e9fc01b865f457809ad'


def transform(source):
    source = source.replace('#import "CNPlayerSDK.h"', '#import "CNPlayerSDK.h"\n#import <QuartzCore/QuartzCore.h>\n#import <objc/runtime.h>')
    pos = source.index('@end')
    source = source[:pos] + '@property(nonatomic,assign) NSTimeInterval referenceStartedAt;\n@property(nonatomic,assign) NSTimeInterval referenceVDNAt;\n' + source[pos:]
    source = source.replace('    self.title = @"CCTVHost";', '''    self.title = @"节目单前 · 0.2 流程";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"导出日志" style:UIBarButtonItemStylePlain target:self action:@selector(exportReferenceLog)];''')
    source = source.replace('    [self setupSDK];', '''    Protocol *p=NSProtocolFromString(@"CNPlayerCallbackProtocol");if(p)class_addProtocol(self.class,p);
    [self setupSDK];
    [self log:@"CCTVHost 0.2.1 · SDK pre-EPG reference · variant pre-epg"];''')
    # Historical code used an object in the BOOL argument register; use the fixed ABI.
    source = source.replace('((BOOL (*)(id, SEL, id *))objc_msgSend)(session, NSSelectorFromString(@"setActive:error:"), (id)kCFBooleanTrue, NULL);', '((BOOL (*)(id, SEL, BOOL, NSError **))objc_msgSend)(session, NSSelectorFromString(@"setActive:error:"), YES, NULL);')
    source = source.replace('    Class CNPlayerCls = NSClassFromString(@"CNPlayer");\n    [self log:@"—— 切换', '    self.referenceStartedAt=CACurrentMediaTime();self.referenceVDNAt=0;\n    Class CNPlayerCls = NSClassFromString(@"CNPlayer");\n    [self log:@"—— 切换')
    # Required by this exact SDK: without Title the old source can reject with 4012.
    source = source.replace('    NSDictionary *opts = @{};', '    NSDictionary *opts = @{@"CNPlayerConfigOptionKey_Title":name?:cid};')
    source = source.replace('    [self startWatchdog];\n    self.playPauseBtn.selected', '    [self log:@"prepareCall +%.3fs",CACurrentMediaTime()-self.referenceStartedAt];\n    [self startWatchdog];\n    self.playPauseBtn.selected')
    # Ignore callbacks from the released previous wrapper; retain fresh instances.
    for signature in ['- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {', '- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {', '- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {', '- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {', '- (void)player:(id)player playbackFailed:(NSError *)error {']:
        source = source.replace(signature, signature+'\n    if(player!=self.currentPlayer)return;')
    source = source.replace('    if (state == 3) { self.overlayTitle.text', '    if (state == 3) { self.referenceVDNAt=CACurrentMediaTime()-self.referenceStartedAt;[self log:@"VDN +%.3fs",self.referenceVDNAt];self.overlayTitle.text')
    source = source.replace('    if (event == 3) {', '    if (event == 3 && !self.firstRender) {')
    source = source.replace('[self log:@"首帧已渲染"];', '[self log:@"首帧渲染 %.3fs · vdn=%.3fs · channel=%@ · variant pre-epg",CACurrentMediaTime()-self.referenceStartedAt,self.referenceVDNAt,self.currentChannelID];')
    # Keep muted startup as in 0.2, make its button accurately report the state.
    source = source.replace('@try { [inst setValue:@(YES) forKey:@"muted"]; }', 'self.muteBtn.selected=YES;[self.muteBtn setTitle:@"开声音" forState:UIControlStateNormal];\n    @try { [inst setValue:@(YES) forKey:@"muted"]; }')
    pos = source.rfind('@end')
    source = source[:pos] + '''- (void)exportReferenceLog {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"cctvhost-pre-epg.log"];
    [self.logBuffer writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    v.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;[self presentViewController:v animated:YES completion:nil];
}
''' + source[pos:]
    assert 'get3D12HEPG' not in source and 'EPGViewController' not in source
    assert 'PyHost' not in source and 'reset' not in source
    assert 'CNPlayerConfigOptionKey_Title' in source
    return source


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    source = subprocess.check_output(['git', 'show', f'{BASELINE}:cctv-ios-host/Sources/RootViewController.m'], cwd=root, text=True)
    (root / 'Sources/RootViewController.m').write_text(transform(source))
    channels = subprocess.check_output(['git', 'show', f'{BASELINE}:cctv-ios-host/Resources/channels.json'], cwd=root)
    (root / 'Resources/channels.json').write_bytes(channels)
