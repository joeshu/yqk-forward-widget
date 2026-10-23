import unittest
from pathlib import Path
S=Path(__file__).resolve().parents[1].joinpath('Sources/RootViewController.m').read_text()
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
  self.assertIn('@selector(exportDiagnosticLog)',S)
  self.assertIn('UIActivityViewController',S)
 def test_clear_removes_buffer_and_persistent_log(self):
  body=S.split('- (void)clearDiagnosticLog {',1)[1].split('\n}',1)[0]
  self.assertIn('[self.pendingLogWrites clear]',body)
  self.assertIn('self.diagnosticLogPath atomically:YES',body)
if __name__=='__main__':unittest.main()
