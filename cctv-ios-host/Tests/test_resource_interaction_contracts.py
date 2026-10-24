from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceInteractionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = (ROOT / 'Sources/ConfigCenterViewController.m').read_text()
        cls.root = (ROOT / 'Sources/RootViewController.m').read_text()
        cls.editor = (ROOT / 'Sources/ServiceEditorViewController.m').read_text()
        cls.detail = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        cls.playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        cls.resource_detail = (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text()

    def test_resource_filters_and_service_detail_use_distinct_controls(self):
        self.assertIn('@[@"全部",@"影视",@"直播",@"待处理"]', self.catalog)
        self.assertIn('onOpenResource', self.catalog)
        self.assertIn('onToggleProfile(p[@"source"], sender.on)', self.catalog)
        self.assertIn('onToggle=^', self.root)
        self.assertIn('isRunningServiceIdentifier', self.root)

    def test_live_resource_uses_declared_route_and_can_configure_missing_route(self):
        self.assertIn('item[@"playlistPath"]', self.root)
        self.assertIn('editor.service=item', self.root)
        self.assertIn('self.playlistPathField', self.editor)
        self.assertIn('playlistPath hasPrefix:@"/"', self.editor)
        self.assertIn('@"http://127.0.0.1:%@%@",item[@"port"],playlist', self.root)

    def test_episode_selection_carries_source_provider_line_and_episode_to_player(self):
        for key in ('@"source"', '@"provider"', '@"detail"', '@"lineIndex"', '@"episodeIndex"'):
            self.assertIn(key, self.detail)
        self.assertIn('MediaPlaybackViewController *player', self.root)
        self.assertIn('resolveAndPlay', self.playback)
        self.assertIn('self.playerController.player=self.player', self.playback)

    def test_local_interface_probe_is_bounded_and_does_not_follow_redirects(self):
        self.assertIn('completionHandler(nil)', self.resource_detail)
        self.assertIn('1024*1024', self.resource_detail)
        self.assertIn('timeoutIntervalForResource=7', self.resource_detail)
        self.assertIn('M3UParser parse:text baseURL:url', self.resource_detail)

    def test_starting_imported_service_does_not_implicitly_subscribe_its_playlist(self):
        start = self.root[self.root.index('NSString *playlistPath=[service[@"builtin"]'):
                                          self.root.index('for(NSString *source in self.subscriptionURLs.allObjects)',
                                                          self.root.index('NSString *playlistPath=[service[@"builtin"]'))]
        self.assertIn('if([service[@"builtin"] boolValue]', start)
        use = self.root[self.root.index('page.onUse=^'):
                        self.root.index('page.onLog=^', self.root.index('page.onUse=^'))]
        self.assertIn('[owner.subscriptionURLs addObject:url]', use)

    def test_duplicate_remote_import_is_explicit_and_does_not_replace_existing_data(self):
        importer = self.root[self.root.index('- (void)acceptImportedMedia:'):
                             self.root.index('- (void)documentPickerWasCancelled:')]
        self.assertIn('发现相同来源', importer)
        self.assertIn('保留为独立副本', importer)
        self.assertIn('打开已有资源', importer)
        self.assertIn('[ServiceStore remove:identifier]', importer)

    def test_imported_source_url_remains_visible_and_searchable(self):
        self.assertIn('@"title":@"资源来源"', self.resource_detail)
        self.assertIn('copySource', self.resource_detail)
        self.assertIn('p[@"url"]', self.catalog)

    def test_list_restore_stops_when_source_has_no_more_pages(self):
        self.assertIn('owner.pendingRestorePage>requestedPage && [result[@"hasMore"] boolValue] && incoming.count', self.detail)

    def test_player_reports_item_load_failure_and_does_not_claim_first_frame(self):
        self.assertIn('AVPlayerItemStatusFailed', self.playback)
        self.assertIn('首帧渲染状态未知', self.playback)


if __name__ == '__main__':
    unittest.main()
