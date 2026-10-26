import unittest
from pathlib import Path
S=Path(__file__).resolve().parents[1].joinpath('Sources/RootViewController.m').read_text()
L=Path(__file__).resolve().parents[1].joinpath('Sources/LogCenterViewController.m').read_text()
class PersistentLogTests(unittest.TestCase):
 def test_log_persistence_is_event_driven_and_batches_writes(self):
  persist=S.split('- (void)persistDiagnosticLine:',1)[1].split('\n}',1)[0]
  flush=S.split('- (void)flushDiagnosticLog {',1)[1].split('\n}',1)[0]
  self.assertIn('[self scheduleDiagnosticLogFlush]',persist)
  self.assertIn('350*NSEC_PER_MSEC',S)
  self.assertNotIn('scheduledTimerWithTimeInterval:1 target:self selector:@selector(flushDiagnosticLog)',S)
  self.assertIn('hasPending=self.pendingLogWrites.length>0',flush)
  self.assertIn('@synchronized (self.pendingLogWrites)',S)
 def test_background_flushes_pending_diagnostics(self):
  body=S.split('- (void)onBackground {',1)[1].split('\n}',1)[0]
  self.assertIn('[self flushDiagnosticLog]',body)
 def test_log_is_restored_on_relaunch(self):
  self.assertIn('[self restoreDiagnosticLog];',S)
  self.assertIn('上次运行日志（崩溃/强制退出前）',S)
 def test_disk_log_is_bounded(self):
  self.assertIn('512*1024',S); self.assertIn('256*1024',S)
 def test_export_action_is_available(self):
  self.assertIn('onExportLog=^',S)
  self.assertIn('UIActivityViewController',S)
 def test_clear_removes_buffer_and_persistent_log(self):
  body=S.split('- (void)clearDiagnosticLog {',1)[1].split('\n}',1)[0]
  self.assertIn('[self.pendingLogWrites clear]',body)
  self.assertIn('self.diagnosticLogPath atomically:YES',body)
 def test_log_center_is_a_separate_searchable_page(self):
  self.assertIn('LogCenterViewController *page',S)
  self.assertIn('diagnostic.logs.search',L)
  self.assertIn('@"全部",@"播放",@"插件",@"错误"',L)
  self.assertIn('CCTVHostDiagnosticLogDidUpdateNotification',L)
  self.assertNotIn('self.logView',S)
  self.assertNotIn('owner.infoLabel.text=summary',S)
 def test_log_center_pauses_when_hidden_and_preserves_reader_position(self):
  self.assertIn('self.pageVisible=YES',L)
  self.assertIn('self.pageVisible=NO',L)
  self.assertIn('if(!self.pageVisible||self.refreshScheduled)return',L)
  self.assertIn('if(!NSThread.isMainThread)',L)
  self.assertIn('dispatch_get_main_queue(),^{[weakSelf scheduleRefresh];}',L)
  self.assertIn('if(owner.pageVisible)[owner refreshLog]',L)
  self.assertIn('removeObserver:self name:CCTVHostDiagnosticLogDidUpdateNotification',L)
  self.assertIn('if(self.hasLoadedSnapshot&&[self.allLines isEqualToArray:lines])return',L)
  self.assertIn('BOOL followsTail=!self.hasLoadedSnapshot||',L)
  self.assertIn('applyFilterFollowingTail:followsTail',L)
  self.assertIn('if(followsTail&&filtered.count',L)
  self.assertIn('scaledFontForFont:',L)
  self.assertIn('adjustsFontForContentSizeCategory=YES',L)
  self.assertIn('日志内容已复制',L)
  self.assertIn('当前筛选的日志已复制',L)
 def test_each_plugin_has_its_own_persistent_exportable_log(self):
  P=Path(__file__).resolve().parents[1].joinpath('Sources/PluginLogStore.m').read_text()
  self.assertIn('appendLine:line forIdentifier:identifier',S)
  self.assertIn('logPluginLine:line identifier:serviceID name:serviceName',S)
  self.assertIn('plugin-logs',P)
  self.assertIn('prepareExportForIdentifier:',P)
  self.assertIn('runsForIdentifier:scope',S)
  self.assertIn('logForIdentifier:scope runID:selectedRun',S)
 def test_each_service_start_has_an_independent_bounded_run_record(self):
  P=Path(__file__).resolve().parents[1].joinpath('Sources/PluginLogStore.m').read_text()
  H=Path(__file__).resolve().parents[1].joinpath('Sources/PluginRunHistoryViewController.m').read_text()
  self.assertIn('beginRunForIdentifier:serviceID',S)
  self.assertIn('finishRunForIdentifier:serviceID status:@"已停止"',S)
  self.assertIn('finishRunForIdentifier:serviceID status:@"启动失败"',S)
  self.assertIn('PluginRunMaximumBytes = 256 * 1024',P)
  self.assertIn('PluginRunMaximumCount = 20',P)
  self.assertIn('metadataPathForIdentifier:',P)
  self.assertIn('plugin.run-history.list',H)
  self.assertIn('onSelectRun',S)
 def test_pre_upgrade_service_logs_remain_available_as_a_separate_record(self):
  P=Path(__file__).resolve().parents[1].joinpath('Sources/PluginLogStore.m').read_text()
  self.assertIn('@"legacy"',P)
  self.assertIn('@"更新前历史日志"',P)
  self.assertIn('markUnmanagedRunsInterruptedForIdentifier:',S)
if __name__=='__main__':unittest.main()
