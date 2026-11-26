import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
DRIVER = (ROOT / "Tests/UISmoke/SmokeDriver.m").read_text(encoding="utf-8")


class PluginRunHistorySmokeWaitTests(unittest.TestCase):
    def block(self):
        start = DRIVER.index("plugin store persisted two independent runs")
        end = DRIVER.index("selecting a run opens its own searchable log page", start)
        return DRIVER[start:end]

    def test_wait_uses_generous_timeout(self):
        m = re.search(r"dateWithTimeIntervalSinceNow:(\d+)\];NSDate \*nextRefresh", self.block())
        self.assertIsNotNone(m)
        self.assertGreaterEqual(int(m.group(1)), 30)

    def test_wait_requires_table_rows_and_retriggers_refresh(self):
        body = self.block()
        loop = body[body.index("while(deadline.timeIntervalSinceNow>0)"):body.index("check(historyRows==2")]
        self.assertIn("[history.tableView numberOfRowsInSection:0]==2", loop)
        self.assertIn("numberOfRowsInSection:0];", loop)
        self.assertIn("@selector(refreshRuns)", loop, "refreshRuns coalesces in-flight calls; loop must re-request so the latest state is fetched")
        self.assertNotIn("count]<2&&deadline", body)

    def test_selection_happens_only_after_row_check(self):
        body = self.block()
        check_at = body.index("check(historyRows==2")
        select_at = body.index("didSelectRowAtIndexPath:")
        self.assertLess(check_at, select_at)
        self.assertIn("if(historyRows>0)[history tableView:history.tableView didSelectRowAtIndexPath:", body)


if __name__ == "__main__":
    unittest.main()
