import unittest
from pathlib import Path
S=Path(__file__).resolve().parents[1].joinpath('Sources/RootViewController.m').read_text()
L=Path(__file__).resolve().parents[1].joinpath('Sources/LogCenterViewController.m').read_text()
class PersistentLogTests(unittest.TestCase):
 def test_log_is_buffered_and_flushed_once_per_second(self):
  self.assertIn('scheduledTimerWithTimeInterval:1 target:self selector:@selector(flushDiagnosticLog)',S)
  self.assertIn('@synchronized (self.pendingLogWrites)',S)
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
 def test_each_plugin_has_its_own_persistent_exportable_log(self):
  P=Path(__file__).resolve().parents[1].joinpath('Sources/PluginLogStore.m').read_text()
  self.assertIn('appendLine:line forIdentifier:identifier',S)
  self.assertIn('logPluginLine:line identifier:serviceID name:serviceName',S)
  self.assertIn('plugin-logs',P)
  self.assertIn('prepareExportForIdentifier:',P)
  self.assertIn('logForIdentifier:scope',S)
if __name__=='__main__':unittest.main()
