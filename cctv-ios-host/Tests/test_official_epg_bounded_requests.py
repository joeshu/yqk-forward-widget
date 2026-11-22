import unittest
from pathlib import Path

SOURCES = Path(__file__).resolve().parents[1] / "Sources"
ROOT = (SOURCES / "RootViewController+EPG.m").read_text(encoding="utf-8")
PAGE = (SOURCES / "EPGViewController.m").read_text(encoding="utf-8")


def method(source, signature, next_signature):
    return source.split(signature, 1)[1].split(next_signature, 1)[0]


class OfficialEPGRequestRegression(unittest.TestCase):
    def test_list_and_playing_channel_bound_and_validate_http_before_parsing(self):
        listing = method(ROOT, "- (void)loadEPGForChannel:", "#pragma mark - 节目单")
        now = method(ROOT, "- (void)refreshOfficialNowNext", "- (BOOL)startRemoteCatchupForChannel:")
        self.assertIn("2 * 1024 * 1024", ROOT)
        for body in (listing, now):
            self.assertIn("HostBoundedDataTask(req, CCTVOfficialEPGMaximumBytes", body)
            self.assertIn("status < 200 || status >= 300", body)
            self.assertLess(body.index("status < 200"), body.index("JSONObjectWithData"))
            self.assertIn("respondsToSelector:@selector(doubleValue)", body)

    def test_old_list_completion_cannot_clear_replacement_request(self):
        listing = method(ROOT, "- (void)loadEPGForChannel:", "#pragma mark - 节目单")
        identity = listing.index("weakSelf.epgListTasks[cid] != weakTask")
        self.assertLess(identity, listing.index("removeObjectForKey:cid"))
        self.assertIn("weakTask = task;", listing)
        self.assertIn("self.epgListTasks[cid] = task;", listing)

    def test_detail_and_lookback_requests_are_bounded_and_cancelled(self):
        detail = method(PAGE, "- (void)fetchOfficial {", "- (void)viewDidLayoutSubviews")
        lookback = method(PAGE, "- (void)fetchOfficialSevenDayLookback {", "- (void)clearChannelReminders")
        cancel = method(PAGE, "- (void)cancelLookbackTasks {", "- (void)cancelPageRequest")
        for body in (detail, lookback):
            self.assertIn("HostBoundedDataTask(req, 2", body)
            self.assertIn("status >= 200 && status < 300", body)
        self.assertIn("[task cancel]", cancel)
        self.assertIn("[self.lookbackTasks addObject:task]", lookback)
        self.assertIn("generation != owner.requestGeneration", lookback)
        self.assertNotIn("dataTaskWithRequest:req completionHandler:", lookback)


if __name__ == "__main__":
    unittest.main()
