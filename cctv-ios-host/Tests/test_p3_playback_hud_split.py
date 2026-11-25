"""Source contracts for the extracted Cicada playback HUD builder."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
VC = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
BUILDER = (SOURCES / "MediaPlaybackCicadaControls.m").read_text(encoding="utf-8")
HEADER = (SOURCES / "MediaPlaybackCicadaControls.h").read_text(encoding="utf-8")


class PlaybackHUDSplitContracts(unittest.TestCase):
    def test_controller_delegates_layout_creation_to_builder(self):
        self.assertIn('#import "MediaPlaybackCicadaControls.h"', VC)
        self.assertIn("@property(nonatomic,strong) MediaPlaybackCicadaControls *cicadaControlsBuilder;", VC)
        self.assertIn("initWithVideoView:self.videoView target:self", VC)
        self.assertNotIn("- (UIButton *)cicadaControlButton:", VC)

    def test_builder_exposes_readonly_controls_without_controller_state(self):
        for name in ("view", "playPauseButton", "rewindButton", "forwardButton", "rateButton", "optionsButton", "fullscreenButton", "seekSlider", "elapsedLabel", "durationLabel"):
            self.assertIn(f"{name};", HEADER)
        self.assertNotIn("cicadaAdapter", BUILDER)
        self.assertNotIn("PlaybackSession", BUILDER)

    def test_existing_accessibility_identifiers_are_owned_by_builder(self):
        for identifier in ("media-cicada-controls", "media-cicada-play-pause", "media-cicada-fullscreen", "media-cicada-progress"):
            self.assertIn(f'@"{identifier}"', BUILDER)
        self.assertIn("accessibilityValue=[NSString stringWithFormat:@\"%.2g×\",self.cicadaAdapter.rate]", VC)

    def test_builder_connects_same_controller_actions_and_scrub_events(self):
        for selector in ("toggleCicadaPlayback", "cicadaRewind", "cicadaForward", "toggleCicadaFullscreen", "beginCicadaScrubbing", "changeCicadaScrubbing", "endCicadaScrubbing", "cancelCicadaScrubbing"):
            self.assertIn(f"@selector({selector})", VC)
        for event in ("UIControlEventTouchDown", "UIControlEventValueChanged", "UIControlEventTouchUpInside|UIControlEventTouchUpOutside", "UIControlEventTouchCancel"):
            self.assertIn(event, BUILDER)


if __name__ == "__main__":
    unittest.main()
