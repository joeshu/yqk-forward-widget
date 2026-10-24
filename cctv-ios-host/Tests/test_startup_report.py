import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("startup_report", Path(__file__).parents[1] / "Scripts/startup-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class StartupReport(unittest.TestCase):
    def test_item_readiness_and_cancelled_switches_are_not_first_frames(self):
        data = """CCTVHost 0.17.0 · SDK 3.23.28 · 当前原生模式：兼容复用
起播 CCTV-1 (cctv1) 线路=自动 · Python idle · variant no-python
原生起播 cctv1 · 兼容复用
首帧渲染 4.00s
起播 CCTV-2 (cctv2) 线路=自动 · Python idle · variant no-python
原生起播 cctv2 · 兼容复用
首帧渲染 6.00s
订阅就绪 0.01s
订阅播放器就绪，继续等待视频渲染
订阅视频首帧 3.00s
起播 CCTV-3 (cctv3) 线路=自动
"""
        groups = report.summarize(data)
        native = groups['0.17.0/no-python/CNPlayerSDK/reuse']
        self.assertEqual(native['samples'], 2)
        self.assertEqual(native['median_seconds'], 5)
        self.assertEqual(groups['0.17.0/no-python/AVPlayer']['median_seconds'], 3)
