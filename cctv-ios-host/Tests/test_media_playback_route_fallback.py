from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources" / "MediaPlaybackViewController.m").read_text(encoding="utf-8")


def method_body(signature):
    start = SOURCE.rindex(signature)
    opening = SOURCE.index("{", start)
    depth = 0
    for index in range(opening, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class MediaPlaybackRouteFallbackTests(unittest.TestCase):
    def test_auto_fallback_is_bounded_and_tries_each_route_once(self):
        body = method_body("- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason")
        self.assertIn("CCTVAutomaticRouteFallbackLimit", SOURCE)
        self.assertIn("MIN(lineCount,CCTVAutomaticRouteFallbackLimit)", body)
        self.assertIn("containsIndex:candidateLine", body)
        self.assertIn("addIndex:candidateLine", body)
        self.assertIn('@"playback_auto_line_fallback"', body)

    def test_auto_alternate_quality_fallback_runs_before_line_switch(self):
        alt_body = method_body("- (BOOL)tryNextAlternateForAutomaticFallback:(NSString *)reason")
        self.assertIn("automaticFallbackTriedAlternateIndexes", alt_body)
        self.assertIn('@"playback_auto_alternate_fallback"', alt_body)
        line_body = method_body("- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason")
        self.assertIn("if([self tryNextAlternateForAutomaticFallback:reason])return YES;", line_body)
        resolve_body = method_body("- (void)resolveAndPlay")
        self.assertIn('tryNextLineForAutomaticFallback:@"episode_resolve_failed"', resolve_body)

    def test_fallback_preserves_the_same_episode_before_switching_routes(self):
        body = method_body("- (BOOL)tryNextLineForAutomaticFallback:(NSString *)reason")
        self.assertIn('currentEpisode[@"id"]', body)
        self.assertIn('currentEpisode[@"name"]', body)
        self.assertIn('isEqual:episodeID', body)
        self.assertIn("MediaPlaybackEpisodeNamesMatch(candidateName,episodeName)", body)
        self.assertIn('@"(?i)s\\\\d+\\\\s*e\\\\s*0*(\\\\d{1,4})"', SOURCE)
        self.assertIn('@"(?i)(?:episode|ep)\\\\s*0*(\\\\d{1,4})"', SOURCE)
        self.assertIn("if(candidateEpisode<0){", body)

    def test_missing_video_track_waits_briefly_then_tries_another_line(self):
        body = method_body("- (void)inspectVideoTracksForItem:(AVPlayerItem *)item generation:(NSUInteger)generation")
        self.assertIn("loadStatus==AVKeyValueStatusLoaded&&!hasVideo", body)
        self.assertIn("2*NSEC_PER_SEC", body)
        self.assertIn('tryNextLineForAutomaticFallback:@"no_video_track"', body)
        self.assertIn("item!=current.observedItem", body)
        self.assertIn("current.videoFrameReady", body)

    def test_item_errors_and_first_frame_timeouts_attempt_other_routes(self):
        failure = method_body("- (void)recordPlaybackFailureForItem:(AVPlayerItem *)item error:(NSError *)error stage:(NSString *)stage")
        self.assertIn("NSURLErrorNotConnectedToInternet", failure)
        self.assertIn("!offline&&[self tryNextLineForAutomaticFallback:kind]", failure)
        play_result = method_body("- (void)playResult:(NSDictionary *)result")
        self.assertIn('playback_video_frame_timeout', play_result)
        self.assertIn('tryNextLineForAutomaticFallback:@"first_frame_timeout"', play_result)

    def test_manual_line_episode_and_retry_choices_reset_auto_attempts(self):
        for anchor in (
            "[self resetAutomaticFallbackLines];self.pendingResolutionReason=@\"manual_retry\"",
            "[self resetAutomaticFallbackLines];",
        ):
            self.assertIn(anchor, SOURCE)
        self.assertIn("- (void)resetAutomaticFallbackLines", SOURCE)


if __name__ == "__main__":
    unittest.main()
