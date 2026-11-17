import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def read_source(name: str) -> str:
    if name == "RootViewController.m":
        return "\n".join(
            (
                p.read_text(encoding="utf-8").split("\n- (BOOL)sessionHasContent;", 1)[0]
                if p.name.endswith(".h")
                else p.read_text(encoding="utf-8")
            )
            for p in ([SOURCES / "RootViewController_Internal.h", *sorted(SOURCES.glob("RootViewController*.m"))])
        )
    return (SOURCES / name).read_text(encoding="utf-8")


class CatchupReplayEnhancementTests(unittest.TestCase):
    def test_catchup01_m3u_multi_protocol_placeholders_and_shift_attributes(self):
        """CATCHUP-01: M3UParser supports rich IPTV catchup templates, catchup-type/timeshift/tvg-rec attributes, and shift auto-templates."""
        m3u_m = read_source("M3UParser.m")
        for token in (
            '@"{utc}":startSec',
            '@"${utc}":startSec',
            '@"{start}":startSec',
            '@"${start}":startSec',
            '@"{timestamp}":startSec',
            '@"${timestamp}":startSec',
            '@"{utcend}":endSec',
            '@"${utcend}":endSec',
            '@"{end}":endSec',
            '@"${end}":endSec',
            '@"{duration}":durationSec',
            '@"${duration}":durationSec',
            '@"{lutc}":nowSec',
            '@"{now}":nowSec',
            '@"{offset}":offsetSec',
            '@"{YmdHMS}":compactStart',
            '@"{(b)yyyyMMddHHmmss}":compactStart',
            '@"${(b)yyyyMMddHHmmss}":compactStart',
            '@"{(e)yyyyMMddHHmmss}":compactEnd',
            '@"${(e)yyyyMMddHHmmss}":compactEnd',
            '@"{Yend}"',
            '@"{mend}"',
            '@"{dend}"',
        ):
            self.assertIn(token, m3u_m)
        self.assertIn('[self attribute:@"catchup-type" in:line]', m3u_m)
        self.assertIn('[self attribute:@"timeshift" in:line]', m3u_m)
        self.assertIn('[self attribute:@"tvg-rec" in:line]', m3u_m)
        self.assertIn('@"?utc={utc}&lutc={lutc}"', m3u_m)

    def test_catchup02_cross_route_and_native_fallback_resolution_with_unified_badges(self):
        """CATCHUP-02: Both CCTV page and Channels page resolve catchup across sibling routes / native stations and display clear badges."""
        catalog_m = read_source("RootViewController+Catalog.m")
        epg_m = read_source("RootViewController+EPG.m")
        self.assertIn("- (NSDictionary *)catchupChannelForChannel:(NSDictionary *)channel {", catalog_m)
        self.assertIn("- (NSDictionary *)nativeFallbackChannelForChannel:(NSDictionary *)channel {", catalog_m)
        self.assertIn('if ([self catchupChannelForChannel:channel] != nil) return YES;', catalog_m)
        self.assertIn('[tags addObject:@"时移回看"]', catalog_m)
        self.assertIn('%@ · %lu 线路 · 时移回看', catalog_m)
        self.assertIn("NSDictionary *catchupRow=[self catchupChannelForChannel:channel];", epg_m)
        self.assertIn("NSDictionary *nativeFallback=[self nativeFallbackChannelForChannel:channel];", epg_m)

    def test_catchup03_remote_catchup_session_tracking_and_one_tap_return_to_live(self):
        """CATCHUP-03: Active subscription catchup playback preserves live channel, keeps status overlay, and supports one-tap return to live."""
        internal_h = read_source("RootViewController_Internal.h")
        epg_m = read_source("RootViewController+EPG.m")
        playback_m = read_source("RootViewController+Playback.m")
        root_m = (SOURCES / "RootViewController.m").read_text(encoding="utf-8")
        self.assertIn("@property(nonatomic,assign) BOOL remoteCatchupActive;", internal_h)
        self.assertIn("@property(nonatomic,copy) NSString *activeCatchupProgramTitle;", internal_h)
        self.assertIn("@property(nonatomic,copy) NSDictionary *activeCatchupLiveChannel;", internal_h)
        self.assertIn("- (BOOL)startRemoteCatchupForChannel:(NSDictionary *)channel program:(NSDictionary *)program start:(NSTimeInterval)start end:(NSTimeInterval)end {", epg_m)
        self.assertIn("- (void)returnToLivePlayback {", playback_m)
        self.assertIn("- (BOOL)isCatchupOrTimeshiftActive {", playback_m)
        self.assertIn("if(self.remoteCatchupActive){self.titleLabel.text=[NSString stringWithFormat:@\"%@ · 回看\"", playback_m)
        self.assertIn("!owner.nativeTimeShiftActive&&!owner.remoteCatchupActive", root_m)

    def test_catchup04_unified_timeshift_and_catchup_quick_seek_controls(self):
        """CATCHUP-04: Player More menu, CCTV route sheet, and subscription tools expose unified timeshift/catchup quick seeks and return-to-live."""
        playback_m = read_source("RootViewController+Playback.m")
        catalog_m = read_source("RootViewController+Catalog.m")
        subs_m = read_source("RootViewController+Subscriptions.m")
        self.assertIn("- (void)seekCurrentChannelByOffsetMinutes:(double)minutes {", playback_m)
        self.assertIn("@[@1,@5,@15,@30,@60]", playback_m)
        self.assertIn("打开节目单选时段回看", playback_m)
        self.assertIn("BOOL canTimeshiftOrCatchup =", playback_m)
        self.assertIn("节目单与回看", catalog_m)
        self.assertIn("订阅频道 · 支持节目回看", subs_m)
        self.assertIn("时移 / 快速回退", subs_m)

    def test_catchup05_epg_live_program_restart_active_replay_badge_and_return_to_live(self):
        """CATCHUP-05: EPGViewController supports replaying the currently airing live program from the beginning and highlights active replay."""
        epg_h = read_source("EPGViewController.h")
        epg_m = read_source("EPGViewController.m")
        self.assertIn("@property(nonatomic,copy) void (^onReturnToLive)(void);", epg_h)
        self.assertIn("@property(nonatomic,assign) NSTimeInterval activeReplayStart;", epg_h)
        self.assertIn("@property(nonatomic,assign) NSInteger catchupDays;", epg_h)
        self.assertIn("点按从头回看", epg_m)
        self.assertIn("正在回看本节目", epg_m)
        self.assertIn('liveProgram[@"liveRestart"]=@YES;', epg_m)
        self.assertIn('identifier:@"epg.return.live"', epg_m)


if __name__ == "__main__":
    unittest.main()
