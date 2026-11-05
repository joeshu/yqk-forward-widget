from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SettingsContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = (ROOT / 'Sources/SettingsViewController.m').read_text()
        cls.settings_h = (ROOT / 'Sources/SettingsViewController.h').read_text()
        cls.root = (ROOT / 'Sources/RootViewController.m').read_text()
        cls.playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        cls.backup = (ROOT / 'Sources/HostBackup.m').read_text()
        cls.media_api = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        cls.browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        cls.search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()

    def test_settings_expose_hidden_playback_preferences(self):
        # 只在播放器菜单里有的偏好，设置页也要有入口：自动连播、屏幕常亮、
        # 默认速度、默认画面比例；播放器启动时现读这些键，下次播放生效。
        for key in ['cctv.mediaAutoPlayNext', 'cctv.mediaKeepScreenAwake']:
            self.assertIn('@\"key\":@\"' + key + '\"', self.settings)
            self.assertIn('@\"' + key + '\"', self.playback)
        self.assertIn('@\"action\":@\"defaultPlaybackRate\"', self.settings)
        self.assertIn('@\"action\":@\"defaultVideoGravity\"', self.settings)
        self.assertIn('cctv.mediaPlaybackRate', self.playback)
        self.assertIn('cctv.mediaVideoGravity', self.playback)
        self.assertIn('setDouble:rate forKey:@"cctv.mediaPlaybackRate"', self.settings)
        self.assertIn('setObject:value forKey:@"cctv.mediaVideoGravity"', self.settings)

    def test_settings_expose_channel_grid_preferences(self):
        # 频道网格/列表与列数只在频道页菜单里有入口，设置页补上；切换要
        # 即时同步到 RootViewController 的内存状态，否则切回频道页仍是旧模式。
        self.assertIn('@\"key\":@\"channelGridMode\"', self.settings)
        self.assertIn('@\"key\":@\"cctv.channelGridColumns.v1\"', self.settings)
        self.assertIn('@\"segmented\":@YES', self.settings)
        self.assertIn('onIntegerPreferenceChanged', self.settings_h)
        self.assertIn('channelGridMode', self.root)
        self.assertIn('if ([key isEqualToString:@"channelGridMode"]) { weakSelf.gridMode=value; [weakSelf configureCatalogNavigation]; }', self.root)
        self.assertIn('onIntegerPreferenceChanged=^(NSString *key, NSInteger value)', self.root)
        self.assertIn('cctv.channelGridColumns.v1', self.root)

    def test_settings_offer_search_history_toggle_and_clear(self):
        # 搜索历史开关只在搜索页里，设置页补开关与清除入口；清除直接删键，
        # 搜索页每次现读，无内存副本过期问题。
        self.assertIn('@\"key\":@\"media.globalSearchHistoryEnabled.v1\"', self.settings)
        self.assertIn('@\"action\":@\"clearSearchHistory\"', self.settings)
        self.assertIn('removeObjectForKey:@"media.globalSearchHistory.v1"', self.settings)

    def test_settings_offer_watch_history_and_favorites_cleanup(self):
        # 观看历史与收藏只能在频道页菜单里清，设置页集中管理；RootViewController
        # 持有内存副本，必须经回调清内存 + 写 defaults + 刷新列表，不能只清 defaults。
        self.assertIn('@\"action\":@\"clearWatchHistory\"', self.settings)
        self.assertIn('@\"action\":@\"clearFavorites\"', self.settings)
        self.assertIn('onClearWatchHistory', self.settings_h)
        self.assertIn('onClearFavorites', self.settings_h)
        self.assertIn('page.onClearWatchHistory=', self.root)
        self.assertIn('[weakSelf.recents removeAllObjects]', self.root)
        self.assertIn('setObject:@[] forKey:@"recents"', self.root)
        self.assertIn('page.onClearFavorites=', self.root)
        self.assertIn('[weakSelf.favorites removeAllObjects]', self.root)
        self.assertIn('setObject:@[] forKey:@"favorites"', self.root)

    def test_settings_offer_clear_all_caches(self):
        # 原先三种缓存只能逐项清理；一键清理要同时清节目单文件、台标内存
        # 缓存与影视元数据缓存，且保留收藏、历史、订阅与插件数据。
        self.assertIn('@\"action\":@\"clearAllCaches\"', self.settings)
        self.assertIn('SettingsRemoveEPGCacheFile()', self.settings)
        self.assertIn('[HostImageLoader.shared clearCache]', self.settings)
        self.assertIn('[MediaMetadataCache.shared clear]', self.settings)
        self.assertIn('收藏、观看历史、订阅和插件数据会保留', self.settings)

    def test_settings_show_epg_cache_size_privacy_and_build_number(self):
        # 节目单缓存不显示占用；无隐私说明入口；版本行只有短版本号，没有 build 号。
        self.assertIn('SettingsEPGCacheSizeText()', self.settings)
        self.assertIn('@\"action\":@\"privacy\"', self.settings)
        self.assertIn('只保存在本机，不会上传到任何服务器', self.settings)
        self.assertIn('CFBundleVersion', self.settings)

    def test_settings_restore_last_tab_is_opt_out(self):
        # 启动恢复上次 Tab 没有开关；关闭后应从央视直播开始，且默认保持恢复。
        self.assertIn('@\"key\":@\"cctv.restoreLastTab.v1\"', self.settings)
        self.assertIn('CCTVBoolPreference(@"cctv.restoreLastTab.v1",YES)', self.root)

    def test_service_rows_in_settings_open_pages(self):
        # 服务分组三行原来点按无反应；现在分别跳到央视直播、频道页与服务页。
        self.assertIn('@\"action\":@\"openTabLive\"', self.settings)
        self.assertIn('@\"action\":@\"openTabChannels\"', self.settings)
        self.assertIn('@\"action\":@\"openServices\"', self.settings)
        self.assertIn('page.onOpenTab=', self.root)
        self.assertIn('page.onOpenServices=', self.root)
        self.assertIn('[weakSelf openServicesPage]', self.root)

    def test_backup_covers_media_playback_preferences(self):
        # 备份只含布尔偏好：播放速度、画面比例、自动连播、常亮、搜索历史
        # 开关与网格列数都不进备份；数值与字符串偏好要按原类型保存与校验。
        self.assertIn('cctv.mediaAutoPlayNext', self.backup)
        self.assertIn('cctv.mediaKeepScreenAwake', self.backup)
        self.assertIn('media.globalSearchHistoryEnabled.v1', self.backup)
        self.assertIn('numberPreferenceKeys', self.backup)
        self.assertIn('@\"cctv.mediaPlaybackRate\"', self.backup)
        self.assertIn('@\"cctv.channelGridColumns.v1\"', self.backup)
        self.assertIn('stringPreferenceKeys', self.backup)
        self.assertIn('@\"cctv.mediaVideoGravity\"', self.backup)
        self.assertIn('[value doubleValue]<0.5||[value doubleValue]>2.0', self.backup)
        self.assertIn('[value integerValue]!=3&&[value integerValue]!=4', self.backup)
        self.assertIn('AVLayerVideoGravityResizeAspectFill', self.backup)
    def test_settings_offer_auto_skip_intro_outro(self):
        # 自动跳过片头片尾：开关在设置页；播放器每秒检查跳过点，开启后按
        # 记住的位置自动跳过，每集只自动跳一次，换片后标记重置。
        self.assertIn('@\"key\":@\"cctv.mediaAutoSkipIntroOutro\"', self.settings)
        self.assertIn('cctv.mediaAutoSkipIntroOutro', self.playback)
        self.assertIn('autoSkippedIntroEpisodeIndex', self.playback)
        self.assertIn('autoSkippedOutroEpisodeIndex', self.playback)
        self.assertIn('autoSkipContext', self.playback)
        self.assertIn('[self performSkipAction];return;', self.playback)

    def test_settings_offer_default_quality(self):
        # 默认清晰度：设置页有选择入口；播放器建 AVPlayerItem 时按选择
        # 约束 HLS 自适应码率；央视直播走 SDK 的 VDN 自动选线，无可调接口。
        self.assertIn('@\"action\":@\"defaultQuality\"', self.settings)
        self.assertIn('cctv.mediaPreferredQuality.v1', self.settings)
        self.assertIn('presentPreferredQualityPicker', self.settings)
        self.assertIn('preferredPeakBitRate', self.playback)
        self.assertIn('cctv.mediaPreferredQuality.v1', self.playback)

    def test_settings_offer_network_timeout(self):
        # 网络请求超时：设置页有 10/20/40 秒三档；影视数据请求默认走
        # 设置值（默认 20 秒），不再写死 40 秒。
        self.assertIn('@\"key\":@\"cctv.networkTimeout.v1\"', self.settings)
        self.assertIn('@\"values\":@[@10,@20,@40]', self.settings)
        self.assertIn('cctv.networkTimeout.v1', self.media_api)
        self.assertIn('requestTimeout:savedTimeout', self.media_api)

    def test_settings_offer_font_size(self):
        # 应用内字号：设置页有标准/大/特大三档；以系统字号为基准上调，
        # 覆盖写在 RootViewController 上，Tab 子页面继承，push 的页面
        # 由导航代理逐个覆盖；系统字号变化时重新计算。
        self.assertIn('@\"key\":@\"cctv.appFontSize.v1\"', self.settings)
        self.assertIn('@\"values\":@[@0,@1,@2]', self.settings)
        self.assertIn('fontSizeOverrideTraitCollection', self.root)
        self.assertIn('applyFontSizeOverride', self.root)
        self.assertIn('traitCollectionWithPreferredContentSizeCategory', self.root)
        self.assertIn('setOverrideTraitCollection:', self.root)
        self.assertIn('cctv.appFontSize.v1', self.root)

    def test_settings_offer_update_check(self):
        # 检查更新：设置页有入口；拉取 GitHub 最新发布并用数字比较版本
        # 号，高于当前版本才提示去下载；失败给明确提示。
        self.assertIn('@\"action\":@\"checkUpdate\"', self.settings)
        self.assertIn('checkForUpdateFromIndexPath', self.settings)
        self.assertIn('releases/latest', self.settings)
        self.assertIn('NSNumericSearch', self.settings)
        self.assertIn('lastUpdateCheckText', self.settings)

    def test_settings_clear_search_history_clears_browse_keywords(self):
        # 设置页清除搜索历史：只删历史键不够，浏览状态里存的关键词也
        # 要清掉并通知影视页与搜索页，否则回到来源还会恢复旧关键词。
        self.assertIn('media.browseStates.v1', self.settings)
        self.assertIn('@\"cleared\":@YES', self.settings)
        self.assertIn('MediaGlobalSearchHistoryDidChange', self.settings)
        self.assertIn('@\"cleared\"', self.browser)
        self.assertIn('searchHistoryCleared:', self.search)
        self.assertIn('MediaGlobalSearchHistoryDidChange', self.search)

    def test_backup_covers_all_settings_preferences(self):
        # 备份要覆盖设置页的全部偏好，不只是上一轮的 6 项：补上预解析、
        # 快速起播、SDK 日志、诊断开关、恢复上次 Tab、自动跳过、主题
        # 模式与深色标记，以及新加的超时、字号、清晰度偏好；数值与
        # 字符串偏好按类型与范围校验。
        for key in ['preloadNativeChannel', 'fastNativeStartup',
                    'nativeSDKVerboseLogs', 'runtimeDiagnosticsEnabled',
                    'cctv.restoreLastTab.v1', 'cctv.mediaAutoSkipIntroOutro',
                    'hostDarkTheme']:
            self.assertIn('@\"' + key + '\"', self.backup)
        for key in ['cctv.networkTimeout.v1', 'cctv.appFontSize.v1']:
            self.assertIn('@\"' + key + '\"', self.backup)
        for key in ['cctv.mediaPreferredQuality.v1', 'hostThemeMode']:
            self.assertIn('@\"' + key + '\"', self.backup)
        self.assertIn('[value doubleValue]<5||[value doubleValue]>40', self.backup)
        self.assertIn('[value integerValue]<0||[value integerValue]>2', self.backup)
        self.assertIn('@\"auto\",@\"smooth\",@\"hd\",@\"uhd\"', self.backup)
        self.assertIn('@\"system\",@\"light\",@\"dark\"', self.backup)


if __name__ == '__main__':
    unittest.main()
