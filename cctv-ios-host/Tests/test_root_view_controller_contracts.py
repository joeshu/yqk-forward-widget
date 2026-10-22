import pathlib
import re
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "RootViewController.m"
TEXT = SOURCE.read_text(encoding="utf-8")


def method_body(signature):
    start = TEXT.index(signature)
    opening = TEXT.index("{", start)
    depth = 0
    for index in range(opening, len(TEXT)):
        if TEXT[index] == "{":
            depth += 1
        elif TEXT[index] == "}":
            depth -= 1
            if depth == 0:
                return TEXT[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class RootViewControllerSourceContracts(unittest.TestCase):
    def test_subscription_refresh_is_source_owned_and_replaces_stale_entries(self):
        body = method_body("- (void)fetchSubscription:")
        self.assertIn("stableURLKey:", body)
        self.assertIn('existing[@"subscriptionSources"]', body)
        self.assertIn("[owners removeObject:sourceKey]", body)
        self.assertIn("subscriptionSources", body)
        self.assertIn('urlIndexes[stable]', body)

    def test_delete_removes_only_source_owned_channels_and_invalidates_fetch(self):
        body = method_body("- (void)removeSubscriptionSource:")
        self.assertIn("[sources removeObject:sourceKey]", body)
        self.assertIn("if (!sources.count) continue", body)
        self.assertIn("self.allChannels = kept", body)
        delete_block = TEXT[TEXT.index('actionWithTitle:@"删除"'):TEXT.index('actionWithTitle:@"取消"', TEXT.index('actionWithTitle:@"删除"'))]
        self.assertIn("subscriptionRequestVersions", delete_block)
        self.assertIn("removeSubscriptionSource:", delete_block)

    def test_subscription_response_is_version_guarded(self):
        body = method_body("- (void)fetchSubscription:")
        self.assertIn("requestVersion", body)
        self.assertIn("!= requestVersion", body)

    def test_logo_completion_checks_reused_image_view_binding(self):
        body = method_body("- (void)loadLogo:")
        self.assertIn("iv.accessibilityIdentifier = url", body)
        self.assertIn("weakIV.accessibilityIdentifier isEqualToString:url", body)

    def test_epg_cache_rejects_future_timestamps(self):
        body = method_body("- (void)loadEPGCache")
        self.assertRegex(body, r"ts\s*<=\s*now")
        self.assertRegex(body, r"now\s*-\s*ts\s*<\s*6\s*\*\s*3600")

    def test_now_next_uses_cache_and_rejects_stale_playback_callback(self):
        body = method_body("- (void)refreshNowNext")
        self.assertIn("NSDictionary *cached = self.epgCache[cid]", body)
        self.assertIn("epgGeneration != weakSelf.playbackGeneration", body)
        self.assertIn("![weakSelf.channelID isEqualToString:cid]", body)

    def test_panda_official_feed_is_grouped_but_not_claimed_verified(self):
        import json
        channels = json.loads((SOURCE.parents[1] / "Resources" / "channels.json").read_text(encoding="utf-8"))
        matches = [c for c in channels if c["id"] == "ipanda-live"]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["group"], "熊猫")
        self.assertFalse(matches[0]["verified"])
        self.assertIn("not a specific camera", matches[0]["validationStatus"])
        self.assertIn("@\"熊猫\"", TEXT)

    def test_epg_cache_path_uses_valid_objc_message_expression(self):
        body = method_body("- (NSString *)epgCachePath")
        self.assertIn("NSSearchPathForDirectoriesInDomains(NSCachesDirectory", body)
        self.assertNotIn(".firstObject];", body)

    def test_retry_is_bound_to_current_generation_and_playback_type(self):
        body = method_body("- (void)player:(id)player playbackFailed:")
        self.assertIn("generation != self.playbackGeneration", body)
        self.assertIn("BOOL remotePlayback = self.avPlayer != nil", body)
        self.assertIn("if (remotePlayback)", body)
        self.assertIn("playViaSDK:cid title:name", body)
        self.assertIn("self.playbackGeneration += 1", method_body("- (void)playRemote:"))


if __name__ == "__main__":
    unittest.main()
