"""Second-round UI/layout/interaction + stability contracts for the playback
and search pages (MediaPlayback / MediaWebView / MediaGlobalSearch /
MediaEpisodeSelection / PlaybackInfo).

Source-pattern contracts in the same style as the other contract suites:
each test pins a small, reviewable guard that was added in this round.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
PLAYBACK_SOURCE = (SOURCES / "MediaPlaybackViewController.m").read_text(encoding="utf-8")
WEBVIEW_SOURCE = (SOURCES / "MediaWebViewController.m").read_text(encoding="utf-8")
SEARCH_SOURCE = (SOURCES / "MediaGlobalSearchViewController.m").read_text(encoding="utf-8")
EPISODE_SOURCE = (SOURCES / "MediaEpisodeSelectionViewController.m").read_text(encoding="utf-8")
INFO_SOURCE = (SOURCES / "PlaybackInfoViewController.m").read_text(encoding="utf-8")


def method_body(source, signature):
    start = source.rindex(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"unterminated Objective-C method: {signature}")


class PlaybackSearchRound2Contracts(unittest.TestCase):
    def test_quality_buttons_meet_44pt_touch_target(self):
        self.assertIn(
            "[self.qualityScroll.heightAnchor constraintEqualToConstant:44]",
            PLAYBACK_SOURCE,
        )
        self.assertNotIn(
            "[self.qualityScroll.heightAnchor constraintEqualToConstant:36]",
            PLAYBACK_SOURCE,
        )

    def test_embedded_playback_buttons_meet_44pt_touch_target(self):
        for fragment in (
            "[self.playbackActionRow.heightAnchor constraintGreaterThanOrEqualToConstant:44]",
            "[self.inlineOptionsButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]",
            "[self.inlineRetryButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]",
            "[self.inlineWebButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]",
        ):
            self.assertIn(fragment, PLAYBACK_SOURCE)

    def test_gesture_feedback_label_scales_with_dynamic_type(self):
        self.assertIn(
            "gestureFeedbackLabel.font=[[UIFontMetrics metricsForTextStyle:"
            "UIFontTextStyleSubheadline]",
            PLAYBACK_SOURCE,
        )
        self.assertIn(
            "gestureFeedbackLabel.adjustsFontForContentSizeCategory=YES",
            PLAYBACK_SOURCE,
        )

    def test_landscape_playback_clamps_title_and_status_lines(self):
        body = method_body(
            PLAYBACK_SOURCE, "- (void)updatePlaybackLayoutForSize:(CGSize)size {"
        )
        self.assertIn("self.episodeTitle.numberOfLines=landscape?1:2", body)
        self.assertIn("self.status.numberOfLines=landscape?2:3", body)

    def test_line_and_episode_lookups_sanitize_untrusted_entries(self):
        self.assertIn(
            "for(id line in raw)[clean addObject:[line isKindOfClass:"
            "NSDictionary.class]?line:@{}]",
            PLAYBACK_SOURCE,
        )
        self.assertIn(
            "for(id episode in raw)[clean addObject:[episode isKindOfClass:"
            "NSDictionary.class]?episode:@{}]",
            PLAYBACK_SOURCE,
        )

    def test_line_buttons_require_string_names(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildLines {")
        self.assertIn('isKindOfClass:NSString.class]?line[@"name"]', body)

    def test_episode_title_line_name_requires_string(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)updateEpisodeTitle {")
        self.assertIn(
            'isKindOfClass:NSString.class]?self.lines[self.lineIndex][@"name"]',
            body,
        )

    def test_quality_switch_rejects_negative_tag_and_non_dictionary(self):
        body = method_body(
            PLAYBACK_SOURCE, "- (void)selectAlternate:(UIButton *)sender {"
        )
        self.assertIn("sender.tag<0||sender.tag>=(NSInteger)alternates.count", body)
        self.assertIn(
            "isKindOfClass:NSDictionary.class]?alternates[sender.tag]:nil", body
        )
        self.assertIn("if(!alternate)return;", body)

    def test_quality_buttons_skip_non_dictionary_alternates(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)buildQualityButtons {")
        self.assertIn(
            "isKindOfClass:NSDictionary.class]?alternates[index]:nil", body
        )
        self.assertIn("if(!alternate)continue;", body)

    def test_line_selection_rejects_negative_tag(self):
        body = method_body(
            PLAYBACK_SOURCE, "- (void)selectLine:(UIButton *)sender {"
        )
        self.assertIn("sender.tag<0||sender.tag>=self.lines.count", body)

    def test_resolve_reports_out_of_range_instead_of_silently_returning(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)resolveAndPlay {")
        self.assertIn("self.lineIndex<0||self.lineIndex>=lines.count", body)
        self.assertIn("self.episodeIndex<0||self.episodeIndex>=episodes.count", body)
        self.assertIn("没有可选分集", body)

    def test_resolve_cancels_stale_play_call_before_reissuing(self):
        body = method_body(PLAYBACK_SOURCE, "- (void)resolveAndPlay {")
        self.assertLess(
            body.index("[self.client cancel]"),
            body.index('[self.client call:@"play"'),
        )

    def test_player_item_notifications_hop_to_main_thread(self):
        for signature in (
            "- (void)playerItemStalled:(NSNotification *)notification {",
            "- (void)playerItemEnded:(NSNotification *)notification {",
            "- (void)playerItemFailed:(NSNotification *)notification {",
        ):
            body = method_body(PLAYBACK_SOURCE, signature)
            self.assertIn("if(!NSThread.isMainThread)", body)
            self.assertIn("dispatch_get_main_queue()", body)

    def test_resume_prompt_falls_back_when_it_cannot_present(self):
        item_body = method_body(
            PLAYBACK_SOURCE, "- (void)offerResumeForItem:(AVPlayerItem *)item {"
        )
        self.assertIn("self.presentedViewController||!self.view.window", item_body)
        self.assertIn("[self applyPendingPlaybackSeekForItem:item]", item_body)
        cicada_body = method_body(
            PLAYBACK_SOURCE, "- (void)offerResumeForCicada {"
        )
        self.assertIn(
            "self.presentedViewController||!self.view.window", cicada_body
        )
        self.assertIn("[self applyPendingPlaybackSeekForCicada]", cicada_body)

    def test_web_fallback_does_not_present_over_an_existing_modal(self):
        for signature in (
            "- (void)openWebPlaybackFallback {",
            "- (void)openEpisodePageWebFallback {",
        ):
            body = method_body(PLAYBACK_SOURCE, signature)
            self.assertIn("if(self.presentedViewController)return;", body)
        play_body = method_body(PLAYBACK_SOURCE, "- (void)playResult:(NSDictionary *)result {")
        self.assertIn("已有页面正在显示", play_body)

    def test_web_navigation_policy_handles_missing_url_scheme(self):
        body = method_body(
            WEBVIEW_SOURCE,
            "- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:",
        )
        self.assertIn('url.scheme.lowercaseString?:@""', body)
        self.assertNotIn(
            'containsObject:url.scheme.lowercaseString]', body
        )

    def test_search_history_button_meets_44pt_touch_target(self):
        self.assertIn(
            "[self.historyButton.heightAnchor "
            "constraintGreaterThanOrEqualToConstant:44]",
            SEARCH_SOURCE,
        )

    def test_search_reuse_guard_clears_stale_result_cell(self):
        body = method_body(
            SEARCH_SOURCE,
            "- (UITableViewCell *)tableView:(UITableView *)tableView "
            "cellForRowAtIndexPath:(NSIndexPath *)indexPath {",
        )
        self.assertIn('stale.nameLabel.text=@""', body)
        self.assertIn("stale.poster.image=nil", body)
        self.assertIn("stale.searchEntry=nil", body)

    def test_episode_page_scroll_view_respects_safe_area_bottom(self):
        # 413 选集页 scrollView 底接 playBar，playBar 底锚 safeArea：
        # 内容同样不会落入 Home Indicator 区，只是经 playBar 间接锚定。
        self.assertIn(
            "[self.scrollView.bottomAnchor constraintEqualToAnchor:playBar.topAnchor]",
            EPISODE_SOURCE,
        )
        self.assertIn(
            "[playBar.bottomAnchor constraintEqualToAnchor:"
            "self.view.safeAreaLayoutGuide.bottomAnchor]",
            EPISODE_SOURCE,
        )

    def test_episode_selection_sanitizes_lines_and_episodes(self):
        episodes_body = method_body(
            EPISODE_SOURCE, "- (NSArray *)episodesForLine:(NSInteger)index {"
        )
        self.assertIn(
            "isKindOfClass:NSDictionary.class]?lines[(NSUInteger)index]:@{}", episodes_body
        )
        rebuild_body = method_body(EPISODE_SOURCE, "- (void)rebuildSelection {")
        self.assertIn(
            "isKindOfClass:NSDictionary.class]?self.lines[index]:@{}",
            rebuild_body,
        )
        self.assertIn(
            'isKindOfClass:NSString.class]?episode[@"name"]', rebuild_body
        )

    def test_episode_selection_cancels_stale_resolve_and_handles_missing_client(self):
        body = method_body(
            EPISODE_SOURCE, "- (void)selectEpisode:(UIButton *)sender {"
        )
        self.assertIn(
            "isKindOfClass:NSDictionary.class]?self.lines[self.selectedLineIndex]:@{}",
            body,
        )
        self.assertIn("无法解析 · 播放服务不可用", body)
        self.assertLess(
            body.index("[self.client cancel]"),
            body.index('[self.client call:@"play"'),
        )

    def test_playback_info_uses_theme_secondary_text(self):
        self.assertIn(
            "c.detailTextLabel.textColor = HostSecondaryText();", INFO_SOURCE
        )
        self.assertNotIn("UIColor.secondaryLabelColor", INFO_SOURCE)


if __name__ == "__main__":
    unittest.main()
