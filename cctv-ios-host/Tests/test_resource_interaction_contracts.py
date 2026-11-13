from pathlib import Path
import hashlib
import json
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceInteractionContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog = (ROOT / 'Sources/ConfigCenterViewController.m').read_text()
        cls.root = (ROOT / 'Sources/RootViewController.m').read_text()
        cls.editor = (ROOT / 'Sources/ServiceEditorViewController.m').read_text()
        cls.detail = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        cls.feed = (ROOT / 'Sources/MediaFeedView.m').read_text()
        cls.browser = cls.detail.split('@implementation MediaBrowserViewController', 1)[1]
        cls.playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        cls.episodes = (ROOT / 'Sources/MediaEpisodeSelectionViewController.m').read_text()
        cls.resource_detail = (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text()
        cls.service_store = (ROOT / 'Sources/ServiceStore.m').read_text()
        cls.import_workflow = (ROOT / 'Sources/ResourceImportWorkflowViewController.m').read_text()
        cls.services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        cls.package_downloader = (ROOT / 'Sources/MediaPackageDownloader.m').read_text()
        cls.js_runtime = (ROOT / 'Sources/JSPluginRuntime.m').read_text()
        cls.importer = (ROOT / 'Sources/MediaPackageImporter.m').read_text()
        cls.tvbox = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        cls.services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        cls.plugin_page = (ROOT / 'Sources/PluginViewController.m').read_text()
        cls.profile_store = (ROOT / 'Sources/ProfileStore.m').read_text()

    def test_player_exit_cancels_work_after_confirmed_transition(self):
        will = self.playback.split('- (void)viewWillDisappear:', 1)[1].split('- (void)viewDidDisappear:', 1)[0]
        did = self.playback.split('- (void)viewDidDisappear:', 1)[1].split('- (void)viewWillAppear:', 1)[0]
        self.assertIn('self.navigationController.isBeingDismissed', will)
        self.assertNotIn('[self.client cancel]', will)
        self.assertIn('if(!self.pendingScreenExit)return;', did)
        self.assertLess(did.index('self.generation++'), did.index('[self.client cancel]'))
        self.assertIn('[self clearCurrentPlayerItem]', did)
        clear = self.playback.split('- (void)clearCurrentPlayerItem {', 1)[1].split('- (void)updateEpisodeTitle', 1)[0]
        self.assertIn('replaceCurrentItemWithPlayerItem:nil', clear)
        appeared = self.playback.split('- (void)viewDidAppear:', 1)[1].split('- (void)viewWillDisappear:', 1)[0]
        self.assertIn('self.pendingScreenExit=NO', appeared)

    def test_resource_filters_and_service_detail_use_distinct_controls(self):
        for kind in ('all', 'vod', 'live', 'catalog', 'script', 'attention'):
            self.assertIn(f'@"id":@"{kind}"', self.catalog)
        self.assertIn('resource-filter-', self.catalog)
        self.assertIn('chevron.up', self.catalog)
        self.assertIn('importTaskExpanded?76:44', self.catalog)
        self.assertIn('profile:profile matchesKind:identifier', self.catalog)
        self.assertIn('initWithFrame:CGRectMake(0,0,104,44)', self.catalog)
        # 资源列表开关恢复标准尺寸，不再缩放到 0.88（低于标准触控目标）。
        # 第二轮 UI：更多按钮 36→44pt 达最小触摸目标，容器 96→104 宽与之匹配。
        self.assertNotIn('CGAffineTransformMakeScale(.88,.88)', self.catalog)
        self.assertIn('more.frame=CGRectMake(58,0,44,44)', self.catalog)
        self.assertIn('onOpenResource', self.catalog)
        self.assertIn('onToggleProfile(p[@"source"], sender.on)', self.catalog)
        self.assertIn('onToggle=^', self.root)
        self.assertIn('isRunningServiceIdentifier', self.root)
        self.assertIn('打开资源详情与配置', self.services)
        # 移植合并：5f2eac6 给第 3 节加了“重启服务”行，现为 5 行。
        self.assertIn('查看 / 导出代码', self.services)
        self.assertIn(': section == 3 ? 5', self.services)

    def test_floating_resource_add_opens_the_unified_import_workflow(self):
        action = self.root.split('UIAction *import=', 1)[1].split(';', 1)[0]
        self.assertIn('actionWithTitle:@"添加资源"', action)
        self.assertIn('[weakSelf addSubscription]', action)
        self.assertNotIn('[weakSelf importMediaPackage]', action)
        self.assertIn('导入资源 · URL / 文件 / 文件夹', self.services)
        self.assertIn('self.onImportResource();', self.services)

    def test_live_only_service_without_capabilities_is_not_both(self):
        # 无能力元数据且有直播证据的服务不再被默认成 vod，避免纯直播被标为 both。
        self.assertIn('resourceKindForService:service subscriptionURL:subscriptionURL', self.root)
        self.assertIn('+ (NSString *)resourceKindForService:', self.service_store)
        self.assertIn('if(!capabilities.count && live)vod=NO;', self.service_store)

    def test_default_media_protocol_requires_a_media_api_method(self):
        # 默认兜底 cctvhost.media/1 须入口实现至少一个媒体方法，否则拒绝导入。
        self.assertIn('MediaAPIMethodDeclaredInSource', self.importer)
        self.assertIn('protocolDefaulted', self.importer)
        self.assertIn('未实现 cctvhost.media/1 接口', self.importer)

    def test_tvbox_type_zero_spider_gets_its_own_unsupported_reason(self):
        self.assertIn('TVBox type 0 为 JS 爬虫', self.tvbox)

    def test_resource_return_layout_reuses_filters_and_measures_variable_rows(self):
        self.assertIn('@interface CCTVResourceProfileCell : UITableViewCell', self.catalog)
        self.assertIn('profileDetailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14', self.catalog)
        self.assertIn('self.tableView.estimatedRowHeight = 0', self.catalog)
        self.assertIn('self.tableView.estimatedSectionHeaderHeight = 0', self.catalog)
        self.assertIn('self.tableView.estimatedSectionFooterHeight = 0', self.catalog)
        filters = self.catalog.split('- (void)updateKindFilters {', 1)[1].split('- (void)traitCollectionDidChange:', 1)[0]
        self.assertIn('if(self.kindFilterButtons.count!=definitions.count)', filters)
        self.assertIn('UIButton *button=self.kindFilterButtons[index]', filters)
        self.assertIn('viewForHeaderInSection', self.catalog)
        # 资源分组头按实际文本测高（最小 34pt），大字体/窄屏下不再截断。
        self.assertIn('heightForHeaderInSection:(NSInteger)section {', self.catalog)
        self.assertIn('return MAX(34,ceil(bounds.size.height)+8);', self.catalog)
        self.assertIn('c.textLabel.numberOfLines=2', self.catalog)
        self.assertIn('c.detailTextLabel.numberOfLines = 0', self.catalog)
        self.assertIn('c.detailTextLabel.lineBreakMode=NSLineBreakByCharWrapping', self.catalog)
        self.assertIn('UIFontTextStyleFootnote', self.catalog)
        self.assertIn('[NSURL URLWithString:source].host', self.catalog)
        self.assertIn('if(name.length)return name;', self.catalog)
        self.assertIn('c.accessibilityValue=c.detailTextLabel.text', self.catalog)

    def test_resource_rows_measure_and_keep_all_summary_fields_visible(self):
        self.assertIn('- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:', self.catalog)
        self.assertIn('return MAX(112,ceil(14+titleHeight+6+detailHeight+14+14));', self.catalog)
        self.assertIn('- (NSString *)resourceTitleForProfile:(NSDictionary *)profile', self.catalog)
        self.assertIn('- (NSString *)resourceDetailForProfile:(NSDictionary *)profile', self.catalog)
        self.assertIn('个缓存频道', self.catalog)
        self.assertIn('最近保存', self.catalog)
        self.assertIn('最近更新', self.catalog)
        self.assertIn('检测中…', self.catalog)
        self.assertIn('profile[@"count"]?:@0,profile[@"epgStatus"]?:@"自动匹配"', self.catalog)
        self.assertIn('summary=[summary stringByAppendingFormat:@"\\n%@",profile[@"status"]]', self.catalog)
        self.assertIn('c.detailTextLabel.text=[self resourceDetailForProfile:p]', self.catalog)

    def test_five_tab_navigation_is_clear_and_pages_scroll_under_it(self):
        self.assertIn('self.bottomBarBackdrop.backgroundColor=UIColor.clearColor', self.root)
        self.assertIn('self.bottomBar.backgroundColor=UIColor.clearColor', self.root)
        self.assertIn('CGFloat contentY=y+6+segmentHeight+4;CGFloat contentBottom=height', self.root)
        self.assertIn('tabContentInset=MAX(8,height-tabY+8)', self.root)
        self.assertIn('setBottomOverlayInset:tabContentInset', self.root)
        self.assertIn('five-tab navigation stays fully transparent over content that extends behind it',
                      (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text())

    def test_top_edge_is_immersive_while_controls_respect_safe_areas(self):
        navigation = (ROOT / 'Sources/HostTheme.h').read_text()
        settings = (ROOT / 'Sources/SettingsViewController.m').read_text()
        self.assertIn('[edge configureWithTransparentBackground]', navigation)
        self.assertIn('nav.navigationBar.scrollEdgeAppearance = edge', navigation)
        self.assertIn('compactScrollEdgeAppearance = edge', navigation)
        self.assertIn('CGFloat pageTop=0', self.root)
        self.assertIn('CGRect frame=CGRectMake(0,0,w,MAX(0,contentBottom))', self.root)
        self.assertIn('CCTVApplyImmersiveScrollGeometry(self.channelGrid,frame,catalogInsets)', self.root)
        self.assertIn('self.playerBox.frame=CGRectMake(0,playerTop,w,ph)', self.root)
        # Step 3：overlayTop 改由统一 helper 计算，取值与旧三元一致
        # （expanded 0 / fullscreen safe.top / 其余 0），底边亦然。
        self.assertIn('- (CGFloat)playerOverlayTopInset', self.root)
        self.assertIn('- (UIEdgeInsets)playerOverlayInsets', self.root)
        self.assertIn('UIEdgeInsets overlayInsets=[self playerOverlayInsets]', self.root)
        self.assertIn('CGFloat overlayTop=overlayInsets.top', self.root)
        self.assertIn('CGFloat bottom = overlayInsets.bottom', self.root)
        self.assertNotIn('expandedLive?0:(self.fullscreen?safe.top:0)', self.root)
        self.assertIn('self.liveResourceCapsule.frame=CGRectMake(safe.left+14,top+4,capsuleWidth,36)', self.root)
        self.assertIn('@"immersiveTopVersion":@1', self.root)
        self.assertIn('if(oldTopGeometry){gridY-=topInset;listY-=self.table.contentInset.top;}', self.root)
        self.assertIn('[feed.topAnchor constraintEqualToAnchor:self.view.topAnchor]', self.detail)
        self.assertIn('self.homeMode&&hero?0:overlay', self.detail)
        self.assertIn('homeTopImmersiveGradient.colors', self.detail)
        self.assertIn('[self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor]', settings)
        self.assertIn('UIEdgeInsetsMake(top,0,bottom,0)', settings)
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('expanded CCTV video has a distinct resource capsule row above the player', smoke)
        self.assertIn('under a readable immersive status region', smoke)

    def test_resource_header_is_remeasured_after_navigation_return_and_preserves_scroll_position(self):
        self.assertIn('- (void)refreshHeaderAfterNavigationTransition', self.catalog)
        self.assertIn('- (void)prepareForNavigationTransition', self.catalog)
        self.assertIn('updateResourceHeaderLayoutReattaching:(BOOL)reattach', self.catalog)
        self.assertIn('BOOL needsAttach=reattach||oldHeader!=header', self.catalog)
        self.assertIn('table.tableHeaderView=header', self.catalog)
        self.assertIn('oldOffset.y+(newHeight-oldHeight)', self.catalog)
        self.assertIn('[resourcePage refreshHeaderAfterNavigationTransition]', self.root)
        self.assertIn('[resourcePage prepareForNavigationTransition]', self.root)
        self.assertIn('if(viewController==self&&self.activeTab==3)', self.root)
        appearance = self.catalog.split('- (void)viewWillAppear:(BOOL)animated {', 1)[1].split('- (void)viewDidDisappear:', 1)[0]
        self.assertIn('[self updateResourceHeaderLayoutReattaching:YES]', appearance)
        self.assertNotIn('[self refreshHeaderAfterNavigationTransition]', appearance)

    def test_service_directory_omits_empty_runtime_groups(self):
        services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        self.assertIn('if(running.count){[visibleSections addObject:running]', services)
        self.assertIn('if(pending.count){[visibleSections addObject:pending]', services)
        self.assertIn('if(stopped.count){[visibleSections addObject:stopped]', services)
        self.assertIn('return self.sections.count;', services)
        self.assertIn('return section<self.sectionTitles.count?self.sectionTitles[section]:nil;', services)

    def test_import_sheet_uses_an_opaque_theme_surface(self):
        sheet = (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text()
        self.assertIn('alpha:1]:[UIColor colorWithRed:0.94 green:0.949 blue:0.969 alpha:1]', sheet)
        self.assertIn('self.view.backgroundColor=sheetSurface', sheet)
        self.assertIn('self.tableView.backgroundColor=sheetSurface', sheet)

    def test_resource_single_taps_show_details_or_choices_instead_of_implicitly_switching_pages(self):
        selection = self.catalog[self.catalog.index('- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:'):]
        self.assertIn('self.onOpenResource(source)', selection)
        self.assertNotIn('self.onUseResource(source', selection)
        self.assertIn('打开频道', selection)
        self.assertIn('编辑订阅与节目单', selection)
        self.assertIn('添加直播频道', self.catalog)
        self.assertIn('进入影视', self.catalog)

    def test_python_http_playlist_addresses_are_displayed_and_auto_subscribed_on_start(self):
        start = self.root[self.root.index('- (BOOL)startService:'):
                          self.root.index('- (void)toggleService:', self.root.index('- (BOOL)startService:'))]
        self.assertIn('[ServiceStore subscriptionURLForService:service]', start)
        self.assertIn('服务订阅地址：%@', start)
        self.assertIn('节目单地址：', start)
        self.assertIn('[self.subscriptionURLs addObject:playlistURL]', start)
        self.assertIn('@"managedServiceID":serviceID', start)
        self.assertIn('if(health)c.path=@"/health"', self.root)
        self.assertIn('playlistPathForService:service', self.root)
        self.assertIn('节目单地址', (ROOT / 'Sources/ServicesViewController.m').read_text())
        self.assertIn('服务订阅地址', self.resource_detail)
        self.assertIn('节目单地址', self.resource_detail)
        self.assertIn('节目单地址：%@', self.root)

    def test_playing_a_stopped_managed_channel_starts_its_own_service_then_checks_readiness(self):
        start = self.root[self.root.index('- (void)startRemoteChannel:'):
                          self.root.index('- (void)failRemoteReadiness:', self.root.index('- (void)startRemoteChannel:'))]
        self.assertIn('[self changeService:service enabled:YES completion:', start)
        self.assertIn('continueRemotePlaybackForURL:u service:service generation:generation', start)
        self.assertIn('generation!=owner.playbackGeneration', start)
        self.assertIn('local_service_start_for_playback_requested', start)
        self.assertIn('正在启动本机服务', start)
        self.assertNotIn('请先在服务页启动此自定义 Python 服务', start)

    def test_local_channel_service_resolution_uses_subscription_owner_and_rejects_ambiguous_ports(self):
        lookup_start = self.root.index('- (NSDictionary *)localServiceForURL:')
        lookup_end = self.root.index('- (NSArray<NSString *> *)managedSubscriptionSourcesForService:', lookup_start)
        lookup = self.root[lookup_start:lookup_end]
        self.assertIn('managedServiceID', lookup)
        self.assertIn('matches.count==1', lookup)
        self.assertIn('if(running)return nil', lookup)
        self.assertIn('localServiceForChannel:ch URL:', self.root)
        self.assertIn('channel[@"subscriptionSources"]', lookup)

    def test_service_status_and_successful_port_migration_reach_all_resource_views(self):
        install = self.root[self.root.index('- (void)installPlaylist:'):
                            self.root.index('- (void)applyPlaylistText:', self.root.index('- (void)installPlaylist:'))]
        self.assertIn('managedSubscriptionSourcesForService', install)
        self.assertIn('retiredSourceSet', install)
        self.assertLess(install.index('snapshot.length>4*1024*1024'), install.index('[ProfileStore remove:retiredSource]'))
        self.assertIn('migratedDisabled', install)
        self.assertIn('replacementOrderIndex', install)
        self.assertLess(install.index('snapshot.length>4*1024*1024'), install.index('replacementOrderIndex'))
        self.assertIn('ProfileStoreMetadataDidChangeNotification', install)
        services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        self.assertIn('订阅清单状态', services)
        self.assertIn('最近成功刷新', services)
        # 服务信息区：直播类服务 13 行（含 main 新增第 13 行“本次启动时间”），非直播类服务只列前 7 行（Codex 的条件行数保留）。
        self.assertIn('section == 2 ? ([ServiceStore isLiveMediaService:self.service]?13:7)', services)
        self.assertIn('本次启动时间', services)
        self.assertIn('probePlaylistChecked', services)
        self.assertIn('probeChannelCount=channels.count', services)
        self.assertIn('probeChannelCount', services)
        self.assertIn('channelCount', self.root)
        self.assertIn('subscriptionStatus', self.catalog)
        self.assertIn('openServiceEditorForService', self.root)
        self.assertIn('editor.onApplyService=', self.root)

    def test_playlist_errors_are_searchable_and_visible_in_attention_filter(self):
        self.assertIn('profile[@"subscriptionStatus"]', self.catalog)
        self.assertIn('[playlistStatus containsString:@"失败"]', self.catalog)
        self.assertIn('subscriptionStatus', self.catalog)
        self.assertIn('刷新中…', self.root)
        self.assertIn('ProfileStoreMetadataDidChangeNotification object:sourceKey', self.root)

    def test_resource_ui_keeps_full_source_query_while_logs_redact_query_values(self):
        address = self.root[self.root.index('static NSString *CCTVServiceLogAddress'):
                            self.root.index('static NSString *CCTVRouteGroupKey')]
        self.assertIn('value:item.value.length?@"[已脱敏]":item.value', address)
        self.assertIn('CCTVServiceLogAddress(sourceKey)', self.root)
        self.assertIn('CCTVServiceLogAddress(u)', self.root)
        self.assertIn('"value":subscription', self.resource_detail)
        self.assertIn('profile[@"subscriptionURL"]', self.catalog)

    def test_unified_media_separates_resource_site_and_scopes_cached_recommendations(self):
        self.assertIn('MediaHomeModulesSchemaKey', self.detail)
        self.assertIn('media-source-selector', self.detail)
        self.assertIn('media-provider-selector', self.detail)
        self.assertIn('cachedHomeResultForSelectedProvider:', self.browser)
        self.assertIn('maximumAge:DBL_MAX', self.browser)
        self.assertIn('self.homeScroll=feed', self.browser)
        self.assertIn('owner.generation!=generation', self.browser)
        self.assertIn('owner.source', self.browser)
        self.assertIn('pendingProviderPickerAfterLoad', self.browser)
        self.assertIn('站点列表已就绪，请选择影视站点', self.browser)

    def test_unified_media_top_controls_keep_one_search_and_safe_touch_targets(self):
        self.assertIn('selectionRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4', self.browser)
        self.assertIn('selectionRow.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14', self.browser)
        self.assertIn('self.selectionRow.spacing=8', self.browser)
        self.assertIn('button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail', self.browser)
        self.assertIn('label:@"我的收藏与观看历史"', self.browser)
        self.assertIn('homeMenuButton.widthAnchor constraintEqualToConstant:44', self.browser)
        self.assertIn('self.floatingSearchBottomConstraint.constant=-(MAX(self.bottomOverlayInset,self.view.safeAreaInsets.bottom)+12)', self.browser)
    def test_bottom_overlay_setters_do_not_reenter_themselves(self):
        sources = {
            "media": self.detail,
            "resources": (ROOT / "Sources/ConfigCenterViewController.m").read_text(),
            "settings": (ROOT / "Sources/SettingsViewController.m").read_text(),
        }
        for name, source in sources.items():
            with self.subTest(page=name):
                setter = source.split('- (void)setBottomOverlayInset:', 1)[1].split('\n}', 1)[0]
                self.assertIn('_bottomOverlayInset=', setter)
                self.assertNotIn('self.bottomOverlayInset=', setter)
        self.assertIn('navigationController.topViewController!=viewController', self.root)

    def test_unified_media_uses_one_reusable_feed_and_visible_category_loading(self):
        view_load = self.browser.split('- (void)viewDidLoad {', 1)[1].split('- (void)setBottomOverlayInset:', 1)[0]
        self.assertIn('MediaFeedView *feed=', view_load)
        self.assertIn('self.grid=feed;self.homeScroll=feed', view_load)
        self.assertNotIn('self.homeModeButton=', view_load)
        self.assertNotIn('self.homeSearchButton=', view_load)
        self.assertIn('MediaContentModeFeatured', self.detail)
        self.assertIn('MediaContentModeCategory', self.detail)
        self.assertIn('feed.onVisibleCategories=', view_load)
        self.assertIn('loadHomeShelves:self.homeCategories', self.browser)
        self.assertIn('UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous', self.feed)
        self.assertIn('onNearEnd', self.feed)
        self.assertIn('movingDown', self.feed)

    def test_media_display_settings_preserve_grid_density_and_live_under_settings(self):
        configuration = self.detail.split('@implementation MediaHomeConfigurationViewController', 1)[1].split('\n@end', 1)[0]
        self.assertIn('section==1?2:self.sources.count', configuration)
        self.assertIn('indexPath.row==0?3:4 forKey:MediaBrowserGridColumnsDefaultsKey', configuration)
        self.assertIn('cctv.mediaGridColumns.v1', self.feed)
        self.assertIn('large?2:', self.feed)
        self.assertIn('- (UIViewController *)mediaDisplaySettingsViewController', self.browser)
        self.assertIn('onMediaDisplaySettings', self.root)
        self.assertIn('mediaDisplaySettingsViewController', self.root)
        self.assertIn('onMediaDisplaySettings', (ROOT / 'Sources/SettingsViewController.h').read_text())

    def test_horizontal_shelves_and_category_grids_use_distinct_responsive_layouts(self):
        self.assertIn('floor((width-28)/2.5)', self.feed)
        self.assertIn('floor((width-28-(columns-1)*10)/columns)', self.feed)
        self.assertIn('UIContentSizeCategoryIsAccessibilityCategory', self.feed)
        self.assertIn('cctv.mediaGridColumns.v1', self.feed)
        self.assertIn('NSCollectionLayoutGroup horizontalGroupWithLayoutSize:', self.feed)

    def test_movie_detail_is_compact_has_poster_fallback_and_removes_cast_strip(self):
        detail = self.detail[self.detail.index('@interface MediaDetailViewController'):
                             self.detail.index('@interface MediaFavoritesViewController')]
        self.assertIn('media-detail-backdrop', detail)
        self.assertIn('systemImageNamed:@"film"', detail)
        self.assertIn('media-detail-share', detail)
        self.assertIn('media-detail-copy-title', detail)
        self.assertIn('media-detail-jump-episodes', detail)
        self.assertNotIn('演职阵容', detail)
        self.assertNotIn('person.crop.circle.fill', detail)
        self.assertIn('multiplier:0.36', detail)
        self.assertIn('@"vod_pic_slide"', detail)
        self.assertIn('@"coverUrl"', detail)
        self.assertIn('暂无海报，显示影片占位图', detail)
        self.assertIn('posterURL.length>0', detail)
        self.assertIn('cover_url', detail)
        self.assertIn('posterUrl', detail)
        self.assertIn('HostStyleGlassCard(infoCard,17)', detail)
        self.assertIn('HostStyleGlassCard(sourceCard,17)', detail)
        self.assertIn('self.contentStack.spacing=9', detail)
        self.assertIn('configureWithTransparentBackground', detail)
        self.assertIn('contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever', detail)
        self.assertIn('scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor', detail)
        self.assertIn('heroSpacer.heightAnchor constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.36', detail)
        self.assertIn('NSUInteger rowCount=(visibleCount+columnCount-1)/columnCount', detail)
        self.assertIn('UIView *spacer=[UIView new]', detail)
        self.assertIn('media-detail-page-status', detail)

    def test_media_browser_cancels_parent_requests_and_resumes_after_child_navigation(self):
        self.assertIn('media_request_cancelled_on_page_exit', self.browser)
        self.assertIn('self.generation++;self.homeShelfGeneration=0', self.browser)
        self.assertIn('[self.client cancel]', self.browser)
        self.assertIn('resumeCancelledMediaRequestOnAppear', self.browser)
        appearance = self.browser.split('- (void)viewWillAppear:', 1)[1].split('- (void)traitCollectionDidChange:', 1)[0]
        self.assertIn('media_request_resumed_after_page_return', appearance)
        self.assertIn('if([operation isEqualToString:@"home"])', appearance)
        self.assertIn('[self loadListing:NO]', appearance)
        self.assertNotIn('home_content_requires_explicit_resource_refresh', appearance)

    def test_selected_site_restores_cache_before_loading_and_empty_catalog_waits_for_selection(self):
        load_sources = self.browser.split('- (void)loadSources {', 1)[1].split('- (void)loadHomeOnDemand', 1)[0]
        self.assertLess(load_sources.index('[self applyHomeResult:cached]'), load_sources.index('[self activate:selected keepingHome:YES]'))
        self.assertIn('!selected&&!catalog', load_sources)
        self.assertIn('请选择合集中的一个站点', load_sources)
        # playMediaResult: 已随合并从 Root 删掉，openMediaTab 后紧跟 playerViewController:。
        media_tab = self.root.split('- (void)openMediaTab {', 1)[1].split('- (void)playerViewController:', 1)[0]
        self.assertNotIn('page.deferAutomaticLoading=YES', media_tab)
        self.assertNotIn('returnToHomeFromNavigation', media_tab)

    def test_selected_site_cache_restores_the_correct_provider_label(self):
        load_sources = self.browser.split('- (void)loadSources {', 1)[1].split('- (void)loadHomeOnDemand', 1)[0]
        self.assertIn('self.provider=provider;[self applyHomeResult:cached]', load_sources)
        selector = self.browser.split('- (void)updateSelectionControls {', 1)[1].split('- (BOOL)isHomeMode', 1)[0]
        self.assertIn('mediaProviderName.%@', selector)
        self.assertIn('if(!providerID.length)providerID=savedProviderID', selector)
        self.assertIn('if(self.deferAutomaticLoading)', load_sources)
        self.assertIn('self.homeLoadDeferred=NO', load_sources)

    def test_media_reappearance_keeps_finished_content_and_only_resumes_cancelled_queries(self):
        appeared = self.browser.split('- (void)viewWillAppear:', 1)[1].split('- (void)traitCollectionDidChange:', 1)[0]
        self.assertIn('resumeCancelledMediaRequestOnAppear', appeared)
        home_appearance = appeared[appeared.index('if(self.homeMode)[self refreshHomeModules]'):]
        self.assertNotIn('[self loadHome]', home_appearance)
        self.assertIn('self.pendingRestoreOffset', self.browser)
        self.assertIn('saveCategorySession', self.browser)

    def test_media_refresh_is_local_and_tab_switch_preserves_content_state(self):
        browser_header = (ROOT / 'Sources/MediaBrowserViewController.h').read_text()
        self.assertIn('refreshHomeContentFromResourcePage', browser_header)
        refresh = self.browser.split('- (BOOL)refreshHomeContentFromResourcePage {', 1)[1].split('- (void)openSourceIdentifier:', 1)[0]
        self.assertIn('[self refreshMediaContent]', refresh)
        self.assertNotIn('[self showHome:', refresh)
        # playMediaResult: 已随合并从 Root 删掉，openMediaTab 后紧跟 playerViewController:。
        media_tab = self.root.split('- (void)openMediaTab {', 1)[1].split('- (void)playerViewController:', 1)[0]
        self.assertNotIn('returnToHomeFromNavigation', media_tab)
        self.assertIn('UIRefreshControl *refresh=', self.browser)
        self.assertIn('action:@selector(refreshMediaContent)', self.browser)
        # main 侧可兼容的部分（合并后源码仍成立）：切 tab 不按需加载首页；
        # 回首页调用仍在 Root 里，只是接收方随 mediaPageCreatingIfNeeded 改为 browser。
        self.assertNotIn('[page loadHomeOnDemand]', media_tab)
        self.assertIn('[browser returnToHomeFromNavigation]', self.root)

    def test_media_detail_returns_to_the_same_media_context(self):
        detail = self.detail[self.detail.index('@interface MediaDetailViewController'):self.detail.index('@interface MediaFavoritesViewController')]
        route = self.browser.split('- (void)pushMediaDetail:', 1)[1].split('- (void)openHomeRecommendation:', 1)[0]
        self.assertIn('onReturnHome', detail)
        self.assertIn('popToViewController:owner animated:YES', route)
        self.assertNotIn('returnToHomeFromNavigation', route)
        self.assertIn('[self pushMediaPage:detail]', route)
        helper = self.browser.split('- (void)pushMediaPage:', 1)[1].split('- (void)updateSelectionControls', 1)[0]
        self.assertIn('setNavigationBarHidden:NO', helper)
        self.assertIn('pushViewController:page animated:YES', helper)

    def test_media_status_is_an_inline_section_and_updates_are_coalesced(self):
        show_message = self.browser.split('- (void)showMessage:', 1)[1].split('- (void)chooseResource', 1)[0]
        self.assertIn('[self.grid.refreshControl endRefreshing]', show_message)
        self.assertIn('[self refreshHomeModules]', show_message)
        refresh = self.browser.split('- (void)refreshHomeModules {', 1)[1].split('- (NSArray *)homeCategoryModuleSignature', 1)[0]
        self.assertIn('self.homeRebuildScheduled', refresh)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', refresh)
        self.assertIn('@"kind":@"status"', self.browser)
        self.assertIn('@"action":@"retry"', self.browser)

    def test_browse_status_and_loading_feedback_never_cover_existing_posters(self):
        sections = self.browser.split('- (NSArray<NSDictionary *> *)mediaFeedSections {', 1)[1].split('- (void)updateMediaFeedInsets', 1)[0]
        self.assertIn('@"kind":@"grid"', sections)
        self.assertIn('if(self.loading&&!self.items.count)', sections)
        self.assertIn('@"id":@"query-status",@"kind":@"status"', sections)
        show = self.browser.split('- (void)showMessage:', 1)[1].split('- (void)chooseResource', 1)[0]
        self.assertNotIn('[self.view addSubview:', show)
        self.assertNotIn('startAnimating', show)

    def test_empty_home_shelves_are_compact_and_scroll_positions_are_source_scoped(self):
        self.assertIn('@"kind":kind', self.browser)
        self.assertIn('attempted?@"status":@"skeleton"', self.browser)
        self.assertIn('cctv.mediaHome.scrollOffset.v3.', self.browser)
        self.assertIn('cctv.mediaHome.scrollOffset.v2.', self.browser)
        self.assertIn('categorySessionKey', self.browser)
        self.assertIn('self.provider', self.browser.split('- (NSString *)categorySessionKey', 1)[1].split('\n}', 1)[0])

    def test_reused_media_feed_cells_clear_poster_identity_and_load_visible_artwork(self):
        self.assertIn('HostImageLoader.shared loadPosterURL:', self.feed)
        self.assertIn('- (void)prepareForReuse', self.feed)
        self.assertIn('self.poster.accessibilityIdentifier=nil', self.feed)
        self.assertIn('self.poster.image=nil', self.feed)
        self.assertIn('willDisplayCell:', self.feed)

    def test_history_and_recommendation_detail_readiness_preserve_the_media_context(self):
        readiness = self.browser.split('- (void)prepareDetailSource:', 1)[1].split('- (void)openHomeRecommendation:', 1)[0]
        recommendation = self.browser.split('- (void)openHomeRecommendation:', 1)[1].split('- (void)browsePinnedSource:', 1)[0]
        history = self.browser.split('- (void)openHistoryEntry:', 1)[1].split('- (void)openHistoryDetail:', 1)[0]
        self.assertIn('self.onActivateService(source,', readiness)
        self.assertIn('detachedGeneration!=request', readiness)
        self.assertIn('LocalServiceReadiness alloc', readiness)
        self.assertIn('if(!failure)completion()', readiness)
        self.assertNotIn('self.source=source', readiness)
        self.assertIn('[self prepareDetailSource:source completion:', recommendation)
        self.assertIn('[self prepareDetailSource:source completion:', history)
        self.assertIn('[owner pushMediaDetail:detail]', recommendation)

    def test_resource_collection_script_and_native_sources_open_the_film_library(self):
        collection = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        collection_store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        browser_header = (ROOT / 'Sources/MediaBrowserViewController.h').read_text()
        browser = self.detail
        self.assertIn('searchBar.placeholder=@"搜索合集中的站点、协议或 URL"', collection)
        self.assertIn('filteredRowsForSection:', collection)
        self.assertIn('serviceForSite(row)', collection)
        self.assertIn('启动并打开资源', collection)
        self.assertIn('导入并打开资源', collection)
        self.assertIn('仅导入到资源页', collection)
        self.assertIn('onImportSite(row,YES)', collection)
        self.assertIn('onImportSite(row,NO)', collection)
        self.assertIn('资源合集', collection_store)
        self.assertIn('- (void)openSourceIdentifier:(NSString *)identifier', browser_header)
        open_source = browser[browser.index('- (void)openSourceIdentifier:'):
                              browser.index('- (void)showMessage:', browser.index('- (void)openSourceIdentifier:'))]
        self.assertIn('self.sourcesProvider?self.sourcesProvider():@[]', open_source)
        self.assertIn('[self activate:target]', open_source)
        self.assertNotIn('[self refreshSources]', open_source)
        self.assertIn('[browser openSourceIdentifier:item[@"id"]', self.root)
        self.assertIn('[browser openSourceIdentifier:sourceID]', self.root)
        self.assertIn('[service[@"url"] isEqual:api]', self.root)
        self.assertIn('siteCount', self.root)
        self.assertIn('个站点 · %lu 个已识别', self.catalog)

    def test_live_resource_uses_declared_route_and_can_configure_missing_route(self):
        self.assertIn('[ServiceStore subscriptionURLForService:item]', self.root)
        self.assertIn('[self openServiceEditorForService:item]', self.root)
        self.assertIn('editor.onApplyService=', self.root)
        self.assertIn('self.playlistPathField', self.editor)
        self.assertIn('[ServiceStore playlistPathForService:self.service]', self.editor)
        self.assertIn('playlistPath hasPrefix:@"/"', self.editor)
        self.assertIn('未配置直播列表', self.root + (ROOT / 'Sources/ServicesViewController.m').read_text())

    def test_playlist_route_inference_requires_route_evidence(self):
        self.assertIn('Only infer a URL when it appears in an actual route declaration', self.service_store)
        self.assertIn('legacyPythonHTTP', self.service_store)
        self.assertIn('if(!mediaHost&&!pythonHTTP&&![service[@"protocol"] isEqual:@"nanotv-service-v2"])return @[]', self.service_store)
        self.assertIn('add_url_rule|add_get|add_route', self.service_store)
        self.assertIn('route|playlist(?:_path)?|m3u_path', self.service_store)
        self.assertIn('inferredPlaylistPathInCode:entryText', (ROOT / 'Sources/MediaPackageImporter.m').read_text())
        self.assertIn('get|post|put|addroute|add_route|addget|add_get', self.service_store)
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('@"resolvedPlaylistPath":[ServiceStore playlistPathForService:service]',native)
        self.assertIn('--playlist-check',native)
        fixture=(ROOT / 'Tests/test_native_package.py').read_text()
        self.assertIn('test_python_spider_routes_are_not_misidentified_as_local_live_subscriptions',fixture)
        self.assertIn('test_only_live_service_protocols_expose_declared_playlist_paths',fixture)

    def test_playlist_discovery_requires_a_readable_nonempty_m3u_then_subscribes_it(self):
        self.assertIn('playlistPathCandidatesForService:self.service', self.resource_detail)
        self.assertIn('playlistFormat&&channels.count>0', self.resource_detail)
        self.assertIn('playlistPathSource"]=@"detected"', self.resource_detail)
        self.assertIn('onPlaylistDiscovered', self.resource_detail)
        self.assertIn('待验证 · http://127.0.0.1:', self.resource_detail)
        start=self.root.index('page.onPlaylistDiscovered=')
        callback=self.root[start:self.root.index('page.onUse=^',start)]
        self.assertIn('[owner.subscriptionURLs addObject:url]', callback)
        self.assertIn('[owner fetchSubscription:url silent:YES]', callback)
        self.assertIn('managedServiceID', callback)
        self.assertIn('parts.query.length', callback)

    def test_resource_updates_refresh_detected_runtime_defaults_but_preserve_manual_overrides(self):
        importer=(ROOT / 'Sources/MediaPackageImporter.m').read_text()
        editor=(ROOT / 'Sources/ServiceEditorViewController.m').read_text()
        self.assertIn('@"argumentsSource":@"inferred"', importer)
        self.assertIn('importedService[@"playlistPathSource"]=@"inferred"', importer)
        self.assertIn('runtimeChanged||inferredArguments', self.service_store)
        self.assertIn('hasManualPlaylist', self.service_store)
        self.assertIn('argumentsSource"] isEqual:@"inferred"', self.service_store)
        self.assertIn('playlistPathSource"] isEqual:@"inferred"', self.service_store)
        self.assertIn('service[@"argumentsSource"]=@"manual"', editor)
        self.assertIn('service[@"playlistPathSource"]=@"manual"', editor)
        self.assertIn('留空自动识别，或填 /all.m3u', editor)
        self.assertIn('else if(![service[@"playlistPathSource"] isEqual:@"detected"])', editor)
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('--update-manual', native)
        self.assertIn('rollbackRestoredPlaylist', native)

    def test_resource_detail_exposes_import_metadata_and_explains_md5_boundary(self):
        importer=(ROOT / 'Sources/MediaPackageImporter.m').read_text()
        self.assertIn('clean[@"pluginVersion"]=pluginVersion', importer)
        self.assertIn('package[@"version"]', importer)
        self.assertIn('@"title":@"资源版本"', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())
        self.assertIn('@"title":@"入口文件"', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())
        self.assertIn('完整性校验，不是数字签名', (ROOT / 'Sources/PluginResourceDetailViewController.m').read_text())

    def test_import_progress_distinguishes_checksum_runtime_inspection_and_persistence(self):
        downloader=(ROOT / 'Sources/MediaPackageDownloader.m').read_text()
        for stage in ('MD5 校验值已读取','MD5 校验通过','未验证来源完整性',
                      '检查资源入口、运行时与协议','识别完成 · 保存到本机资源库'):
            self.assertIn(stage,downloader)
        progress=downloader[downloader.index('- (void)progress:'):downloader.index('- (void)importURL:')]
        self.assertIn('lastProgressStage',progress)
        self.assertIn('stageChanged',progress)
        native=(ROOT / 'Tests/native_package_tests.m').read_text()
        self.assertIn('@"progressStages":progressStages',native)
        remote=(ROOT / 'Tests/test_native_package.py').read_text()
        self.assertIn("stages=result['progressStages']",remote)

    def test_import_preview_and_single_file_retries_survive_process_recreation(self):
        self.assertIn('ApplicationSupportDirectory', self.import_workflow)
        self.assertIn('workflow-v1.plist', self.import_workflow)
        self.assertIn('NSPropertyListBinaryFormat_v1_0', self.import_workflow)
        self.assertIn('ResourceImportReadSnapshot()', self.import_workflow)
        self.assertIn('if([snapshot[@"busy"] boolValue])', self.import_workflow)
        self.assertIn('retryData', self.import_workflow)
        self.assertIn('retryBookmark', self.import_workflow)
        self.assertIn('retryCandidateAtIndex:', self.import_workflow)
        self.assertIn('retrySaveCandidateAtIndex:', self.import_workflow)
        self.assertIn('refreshExistingResourceMatches', self.import_workflow)
        self.assertIn('existingImportTargetsProvider', self.root)
        self.assertIn('importFingerprint', self.import_workflow)
        self.assertIn('filename.lastPathComponent', self.import_workflow)

    def test_categorized_import_remains_inside_advanced_options_and_reuses_preview(self):
        self.assertIn('advancedOptionsExpanded?7:5', self.import_workflow)
        self.assertIn('按类型选择导入方式', self.import_workflow)
        self.assertIn('showCategorizedImportOptions', self.import_workflow)
        self.assertIn('applyImportCategory:', self.import_workflow)
        self.assertIn('snapshot[@"importCategory"]', self.import_workflow)
        self.assertIn('ResourceImportOptionTVBoxFile', self.import_workflow)
        self.assertIn('catalogWithMacCMSAPIURL:raw name:nil', self.import_workflow)
        self.assertIn('workflow.onOpenServices=^{[weakSelf openServicesPage];}', self.root)

    def test_service_health_snapshot_is_persistent_and_channel_counts_are_scoped(self):
        self.assertIn('healthSnapshotForServiceIdentifier:', self.service_store)
        self.assertIn('recordHealthSnapshot:', self.service_store)
        self.assertIn('updated[@"healthSnapshot"]=clean', self.service_store)
        self.assertIn('healthResult', self.root)
        self.assertIn('healthCheckedAt', self.root)
        self.assertIn('healthSnapshotForServiceIdentifier:', self.services)
        self.assertIn('self.probePlaylistChecked=NO;self.probeChannelCount=0', self.services)
        self.assertIn('removeObjectForKey:@"healthSnapshot"', self.service_store)

    def test_service_editor_uses_dynamic_type_and_vertical_input_rows(self):
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('self.tableView.rowHeight = UITableViewAutomaticDimension', self.editor)
        self.assertIn('adjustsFontForContentSizeCategory=YES', self.editor)
        self.assertIn('stack.axis=UILayoutConstraintAxisVertical', self.editor)
        self.assertIn('stack.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor', self.editor)
        self.assertIn('UIContentSizeCategoryAccessibilityExtraExtraExtraLarge', smoke)
        self.assertIn('label does not overlap its input at large text size', smoke)
        self.assertIn('stays inside its large-type editor row', smoke)

    def test_running_http_service_port_edit_stops_saves_and_restarts(self):
        services = (ROOT / 'Sources/ServicesViewController.m').read_text()
        self.assertIn('v.onApplyService = self.onApplyService', services)
        self.assertIn('停止并重启', self.editor)
        self.assertIn('CCTVHostServiceConfigurationSaved', self.editor)
        implementation = self.root.index('@implementation RootViewController')
        apply_start = self.root.index('- (void)applyServiceConfigurationFrom:', implementation)
        apply_handler = self.root[apply_start:self.root.index('- (void)usePluginService:', apply_start)]
        self.assertLess(apply_handler.index('enabled:NO'), apply_handler.index('[ServiceStore save:updated]'))
        self.assertLess(apply_handler.index('[ServiceStore save:updated]'), apply_handler.index('enabled:YES'))
        self.assertIn('associateLegacyLoopbackSubscriptionsForService:previous', apply_handler)
        self.assertIn('def test_configured_service_port_overrides_hardcoded_primary_http_port',
                      (ROOT / 'Tests/test_service_runtime.py').read_text())

    def test_episode_selection_carries_source_provider_line_and_episode_to_player(self):
        for key in ('@"source"', '@"provider"', '@"detail"', '@"lineIndex"', '@"episodeIndex"'):
            self.assertIn(key, self.episodes)
        self.assertIn('MediaPlaybackViewController *player', self.root)
        self.assertIn('resolveAndPlay', self.playback)
        self.assertIn('self.playerController.player=self.player', self.playback)
        self.assertIn('selectionUpdatesPlayer=YES', self.playback)
        self.assertIn('MediaEpisodeSelectionViewController', self.playback)

    def test_episode_switch_remains_available_during_resolution_and_discards_stale_results(self):
        selector_start = self.episodes.index('- (void)selectEpisode:(UIButton *)sender {')
        selector = self.episodes[selector_start:self.episodes.index('\n@end', selector_start)]
        resolver = self.playback[self.playback.index('- (void)resolveAndPlay'):]
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('NSUInteger generation=++self.generation', selector)
        self.assertIn('owner.generation!=generation', selector)
        self.assertIn('NSUInteger generation=++self.generation', resolver)
        self.assertIn('generation!=owner.generation', resolver)
        self.assertIn('[self cancelWithReason:@"superseded_by_new_request"]', api_client)
        self.assertIn('- (void)cancel { [self cancelWithReason:@"caller_cancelled"]; }', api_client)
        self.assertIn('self.generation++;', api_client)

    def test_detail_embeds_route_and_paged_episode_grid_and_resolves_playback(self):
        detail = self.detail[self.detail.index('@interface MediaDetailViewController'):
                             self.detail.index('@interface MediaBrowserViewController')]
        self.assertIn('media-detail-episode-grid', detail)
        self.assertIn('media-detail-route-', detail)
        self.assertIn('media-detail-parser-selector', detail)
        self.assertIn('self.parserRow.hidden=parsers.count==0', detail)
        self.assertIn('if(!catalogID.length)return @[];', detail)
        self.assertIn('NSString *parserID=[self selectedPlaybackParserID]', detail)
        self.assertIn('constraintGreaterThanOrEqualToConstant:44', detail)
        self.assertIn('call:@"play"', detail)
        self.assertIn('toggleFavorite', detail)
        self.assertIn('cctv.mediaFavorites.v1', detail)
        self.assertIn('MediaFavoritesViewController', self.detail)
        self.assertIn('openFavorites', self.detail)
        self.assertIn('@"lineIndex"', self.episodes)
        self.assertIn('@"episodeIndex"', self.episodes)
        self.assertIn('viewWillTransitionToSize', self.playback)
        self.assertIn('landscapeConstraints', self.playback)
        self.assertIn('viewDidAppear:(BOOL)animated', self.playback)

    def test_detail_resume_survives_regenerated_route_and_episode_ids(self):
        restore = self.detail.split('- (void)restoreResumeEntrySelection {', 1)[1].split(
            '\n- (void)restoreSelectionFromDetail:', 1)[0]
        route_view = self.detail.split('- (void)updateRouteAndEpisodeViews {', 1)[1].split(
            '\n- (void)selectRoute:', 1)[0]
        name_matcher = self.detail.split('static BOOL MediaBrowserIdentityNameMatches', 1)[1].split(
            '\n}', 1)[0]
        playback_state = (ROOT / 'Sources/MediaPlaybackStateStore.m').read_text()

        self.assertLess(restore.index('lineID.length'), restore.index('lineName.length'))
        self.assertLess(restore.index('lineName.length'), restore.index('lineIndex<0||lineIndex>=self.lines.count'))
        self.assertLess(restore.index('episodeID.length'), restore.index('episodeName.length'))
        self.assertLess(restore.index('episodeName.length'), restore.index('episodeIndex<0||episodeIndex>=episodes.count'))
        self.assertIn('resumeLineName', route_view)
        self.assertIn('resumeEpisodeName', route_view)
        self.assertIn('value isKindOfClass:NSString.class', name_matcher)
        self.assertIn('saved.length', name_matcher)
        self.assertIn('@"lineName"', playback_state)
        self.assertIn('@"episodeName"', playback_state)

    def test_tvbox_parser_selection_drives_native_resolution_and_web_fallback(self):
        catalog = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('playbackParsersForCatalogID:', catalog)
        self.assertIn('if(!catalogID.length)return @[];', catalog)
        self.assertIn('parserCatalogID', api_client)
        self.assertIn('MediaParserRequestURL', api_client)
        self.assertIn('parserDirectURL', api_client)
        self.assertIn('MediaParserResponseIsDirectMedia', api_client)
        self.assertIn('MediaParserCandidateSupportsNativePlayer(address,found)', api_client)
        self.assertIn('application/dash+xml', api_client)
        self.assertIn('MediaParserKind(parser)', api_client)
        self.assertIn('self.parserWebFallbackResult?:self.parserFallbackResult', api_client)
        self.assertIn('if(!catalogID.length){if(completion)completion(result,nil);return;}', api_client)
        self.assertIn('playbackParsersForCatalogID:catalogID])if([parser[@"id"] isEqual:selected])return selected', self.playback)
        self.assertIn('playbackParsersForCatalogID:catalogID])if([parser[@"id"] isEqual:selected])return selected', self.episodes)
        self.assertIn('parserID', self.detail)
        self.assertIn('parserID', self.playback)
        self.assertIn('parserID', self.episodes)
        self.assertIn('selected type 1 parser turns a TVBox web page',
                      (ROOT / 'Tests/native_media_api_tests.m').read_text())
        self.assertIn('selected type 0 parser keeps the in-app web playback fallback',
                      (ROOT / 'Tests/native_media_api_tests.m').read_text())

    def test_fullscreen_player_shows_observed_rate_and_available_audio_tracks(self):
        self.assertIn('media-playback-throughput', self.playback)
        self.assertIn('AVPlayerItemAccessLogEvent *event=self.player.currentItem.accessLog.events.lastObject', self.playback)
        self.assertIn('AVMediaCharacteristicLegible title:@"字幕"', self.playback)
        self.assertIn('AVMediaCharacteristicAudible title:@"音轨"', self.playback)
        self.assertIn('弹幕 · 当前视频未提供弹幕轨道', self.playback)

    def test_detail_and_portrait_player_extend_under_top_chrome_without_hiding_controls(self):
        detail_page = self.detail[self.detail.index('@implementation MediaDetailViewController'):
                                  self.detail.index('@interface MediaFavoritesViewController')]
        self.assertIn('bar.standardAppearance=scrolled;bar.scrollEdgeAppearance=edge', detail_page)
        self.assertIn('compactScrollEdgeAppearance=edge', detail_page)
        self.assertIn('colorWithWhite:0 alpha:0.78', detail_page)
        self.assertIn('scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor', detail_page)

        player = self.playback[self.playback.index('@implementation MediaPlaybackViewController'):]
        self.assertIn('videoView.topAnchor constraintEqualToAnchor:self.view.topAnchor', player)
        self.assertIn('videoView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor', player)
        self.assertIn('videoView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor', player)
        self.assertIn('self.videoTopScrim', player)
        self.assertIn('throughputPortraitTopConstraint.active=!landscape', player)
        self.assertIn('throughputLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor', player)
        self.assertIn('gestureFeedbackPortraitTopConstraint.active=!landscape', player)
        self.assertIn('controlPanel.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor', player)
        self.assertIn('videoView.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor', player)
        self.assertIn('if(viewController==self)HostStyleNavigation(navigationController)', self.root)

    def test_embedded_player_overlays_stay_inside_the_video_view_hierarchy(self):
        player = self.playback[self.playback.index('@implementation MediaPlaybackViewController'):]
        self.assertIn('UIView *gestureSurface=self.videoView;', player)
        self.assertIn('gestureFeedbackLabel.topAnchor constraintEqualToAnchor:self.videoView.safeAreaLayoutGuide.topAnchor', player)
        # 直连 Cicada 引擎已删除（setGestureSurfaceForCicada 随之删除）：
        # 手势面改锚 viewDidLoad 的初始化行，仍断言反馈标签挂在 videoView
        # 派生的手势面上、而非 AVPlayerViewController 的 contentOverlayView。
        switch_surface = player[player.index('UIView *gestureSurface=self.videoView;'):]
        self.assertIn('[gestureSurface addSubview:self.gestureFeedbackLabel]', switch_surface)
        self.assertNotIn('self.playerController.contentOverlayView?:self.videoView', switch_surface)

    def test_detail_starts_player_inline_without_push_and_preserves_player_diagnostics(self):
        detail = self.detail[self.detail.index('@implementation MediaDetailViewController'):
                             self.detail.index('@interface MediaFavoritesViewController')]
        push = self.detail[self.detail.index('- (void)pushMediaDetail:', self.detail.index('@implementation MediaBrowserViewController')):
                           self.detail.index('- (void)openHomeRecommendation:', self.detail.index('- (void)pushMediaDetail:', self.detail.index('@implementation MediaBrowserViewController')))]
        self.assertIn('showInlinePlaybackResult:result context:context', push)
        self.assertIn('installFloatingInlineSurfaceInHost:dock controlsStack:self.contentStack', detail)
        self.assertIn('[player loadViewIfNeeded]', detail)
        self.assertIn('playInlineResult:result context:context', detail)
        self.assertIn('embeddedMode=YES', detail)
        self.assertIn('inline_playback_attached', detail)
        self.assertIn('@property(nonatomic) BOOL embeddedMode', (ROOT / 'Sources/MediaPlaybackViewController.h').read_text())
        self.assertIn('episode_resolve_succeeded', detail)
        self.assertIn('previousEpisodeID', detail)
        self.assertIn('if(self.inlinePlaybackController&&episodes.count)[self resolveAndPlaySelectedEpisode]', detail)
        self.assertIn('pendingEpisodeResult', self.playback)

    def test_inline_player_floats_above_scrolling_detail_controls(self):
        detail = self.detail[self.detail.index('@implementation MediaDetailViewController'):
                             self.detail.index('@interface MediaFavoritesViewController')]
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('media-detail-floating-player', detail)
        self.assertIn('installFloatingInlineSurfaceInHost:dock controlsStack:self.contentStack', detail)
        self.assertIn('inlinePlaybackScrollTopConstraint.active=YES', detail)
        self.assertIn('media-inline-now-playing', self.playback)
        self.assertIn('inlineNowPlayingPill.hidden=!self.floatingInlineSurfaceInstalled', self.playback)
        self.assertNotIn('stickyPlayBar', detail)
        self.assertIn('[self.contentStack addArrangedSubview:self.playButton]', detail)
        self.assertIn('inline player surface stays pinned while detail content scrolls', smoke)
        self.assertIn('inline playback controls flow with detail content below the floating video', smoke)

    def test_live_player_resource_capsule_selects_resource_page_live_sources(self):
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('live.resource.capsule', self.root)
        self.assertIn('showsMenuAsPrimaryAction=self.activeTab==1', self.root)
        self.assertIn('subscriptionOwner:owner matchesLiveResourceSource:self.activeSource', self.root)
        self.assertIn('UI Smoke Live Resource · 1', smoke)
        self.assertIn('selecting a resource capsule filters the channel page to that resource', smoke)

    def test_player_exposes_quality_choices_and_keeps_parse_and_resolution_states_clear(self):
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('self.result[@"alternates"]', self.playback)
        self.assertIn('playback_quality_selected', self.playback)
        self.assertIn('awaitingWebPlaybackReturn', self.playback)
        self.assertIn('if(self.resolving)return', self.playback)
        self.assertIn('MediaPlaybackResultSupportsAVPlayer(result)', self.playback)
        self.assertIn('url.user.length||url.password.length', self.playback)
        self.assertIn('[self setRetryAvailable:NO]', self.playback)
        self.assertIn('inline player exposes the source\'s actual alternate quality choices', smoke)
        self.assertIn('quality=low', smoke)

    def test_quality_specific_headers_survive_source_normalization_relay_and_selection(self):
        runtime = (ROOT / 'Plugins/host_media_runtime.py').read_text()
        service = (ROOT / 'Plugins/media-service.py').read_text()
        api = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn("choice_headers = merge_media_headers(item.get('headers', {}), item.get('header', {}),", runtime)
        self.assertIn("'baseHeaders': media_headers(base_headers)", runtime)
        self.assertIn("alternate_headers.update(alternate.get('headers') or {})", service)
        self.assertIn('alternate_headers or is_declared_hls(alternate_media, address)', service)
        self.assertIn('def is_extensionless_url(url):', service)
        self.assertIn('or is_extensionless_url(result.get(\'url\'))', service)
        self.assertIn('MediaTVBoxPlaybackHeaders(source,root)', api)
        self.assertIn('MediaTVBoxPlaybackHeaders(@{},choice)', api)
        self.assertIn('choiceHeaders=[headers mutableCopy]', api)
        self.assertIn('MediaPlaybackHeadersFromResult(alternate)', self.playback)
        self.assertIn('basePlaybackHeaders', self.playback)
        self.assertIn('test_quality_specific_headers_reach_hls_alternate',
                      (ROOT / 'Tests/test_media_runtime.py').read_text())
        self.assertIn('per-quality request headers survive TVBox normalization',
                      (ROOT / 'Tests/native_media_api_tests.m').read_text())
        fixture = (ROOT / 'Tests/UISmoke/fixture_server.py').read_text()
        self.assertIn("if \"?\" in self.path and (self.headers.get(\"Referer\")", fixture)

    def test_media_resource_and_site_pickers_are_separate(self):
        self.assertIn('选择影视资源', self.detail)
        self.assertIn('内部站点：%@，点按切换', self.detail)
        self.assertIn('media-source-selector', self.detail)
        self.assertIn('media-provider-selector', self.detail)
        self.assertIn('selectionRow.bottomAnchor', self.detail)
        self.assertIn('[self updateSelectionControls]', self.detail)
        self.assertIn('- (void)chooseResource', self.detail)
        self.assertIn('- (void)chooseProvider', self.detail)
        self.assertIn('UIModalPresentationPageSheet', self.detail)
        self.assertIn('mediumDetent', self.detail)
        self.assertIn('UITableViewCellAccessoryCheckmark', self.detail)
        self.assertIn('scopeStack', self.detail)
        self.assertIn('NSString *url=[source[@"url"] isKindOfClass:NSString.class]', self.detail)
        self.assertIn('@"url":url', self.detail)

    def test_home_exposes_separate_top_resource_and_site_pickers_and_prepares_sites_on_demand(self):
        self.assertIn('action:@selector(chooseResource)', self.browser)
        self.assertIn('action:@selector(chooseProvider)', self.browser)
        self.assertIn('self.pendingProviderPickerAfterLoad=YES', self.browser)
        self.assertIn('[self activate:self.source keepingHome:self.homeMode]', self.browser)
        self.assertIn('[page chooseProvider]', self.browser)
        self.assertIn('此资源使用单站点接口', self.browser)
        self.assertIn('self.providerSelectButton.hidden=NO', self.browser)
        self.assertIn('selectionRow.bottomAnchor', self.browser)

    def test_home_request_diagnostics_record_the_action_trigger_and_deferred_state(self):
        request = self.detail[self.detail.index('- (void)loadHome {'):
                              self.detail.index('- (void)applyHomeResult:', self.detail.index('- (void)loadHome {'))]
        self.assertIn('self.nextHomeLoadTrigger', request)
        self.assertIn('@"trigger":trigger', request)
        self.assertIn('@"automatic_load_deferred":@(self.deferAutomaticLoading||self.homeLoadDeferred)', request)
        self.assertIn('media_pull_refresh', self.detail)
        self.assertIn('site_selector_prepare', self.detail)

    def test_home_duplicate_requests_are_suppressed_and_stale_responses_cannot_replace_new_operations(self):
        request = self.detail[self.detail.index('- (void)loadHome {'):
                              self.detail.index('- (void)applyHomeResult:', self.detail.index('- (void)loadHome {'))]
        self.assertIn('activeHomeRequestSourceID', request)
        self.assertIn('activeHomeRequestProviderID', request)
        self.assertIn('sameRequestInFlight', request)
        self.assertIn('media_home_duplicate_request_suppressed', request)
        self.assertIn('same_resource_site_request_in_flight', request)
        self.assertIn('stillCurrentOperation', request)
        self.assertIn('superseded_operation', request)

    def test_unified_search_defaults_to_current_site_and_expansion_is_explicit(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        header = (ROOT / 'Sources/MediaGlobalSearchViewController.h').read_text()
        for field in ('currentSourceID', 'currentProviderID', 'currentCatalogID'):
            self.assertIn(field, header)
            self.assertIn('page.' + field + '=', self.browser)
        self.assertIn('self.searchSources=self.currentSiteScope?@[self.currentSiteSource]:self.availableSources', search)
        change = search.split('- (void)changeSearchScope:', 2)[2].split('- (', 1)[0]
        self.assertIn('[self cancelJobsAndAdvanceGeneration]', change)
        self.assertIn('[self.rows removeAllObjects]', change)
        self.assertIn('self.searching=NO', change)
        self.assertNotIn('[self submitSearch]', change)
        self.assertIn('selectedProviderID=page.currentProviderID', search)
        self.assertIn('当前站点已不可用', search)

    def test_featured_deduplicates_banner_items_and_never_mixes_category_grid(self):
        featured = self.browser.split('NSSet *enabled=MediaHomeEnabledModules()', 1)[1].split('- (void)updateMediaFeedInsets', 1)[0]
        self.assertIn('MediaBrowserItemIdentity(item)', featured)
        self.assertIn('[seen containsObject:key]', featured)
        self.assertIn('NSMakeRange(bannerCount,count)', featured)
        self.assertNotIn('@"kind":@"grid"', featured)
        self.assertNotIn('更多精选', self.browser)
        self.assertIn('UIAccessibilityIsReduceMotionEnabled()', self.feed)
        self.assertIn('UIAccessibilityIsVoiceOverRunning()', self.feed)
        self.assertIn('self.feedVisible', self.feed)

    def test_category_switch_cancels_background_work_and_restores_context_scoped_session(self):
        select = self.browser.split('- (void)selectMediaCategory:', 1)[1].split('- (void)viewWillTransitionToSize:', 1)[0]
        self.assertIn('[self saveCategorySession]', select)
        self.assertIn('self.generation++', select)
        self.assertIn('[self.client cancel]', select)
        self.assertIn('self.categorySessions[[self categorySessionKey]]', select)
        self.assertIn('self.items=saved[@"items"]', select)
        self.assertIn('self.hasMore=[saved[@"hasMore"] boolValue]', select)
        self.assertIn('self.grid setContentOffset:', select)
        self.assertIn('stateKeyForSource:self.source provider:self.provider', self.browser)

    def test_local_interface_probe_is_bounded_and_does_not_follow_redirects(self):
        self.assertIn('completionHandler(nil)', self.resource_detail)
        self.assertIn('1024*1024', self.resource_detail)
        self.assertIn('timeoutIntervalForRequest=1.5', self.resource_detail)
        self.assertIn('timeoutIntervalForResource=2', self.resource_detail)
        self.assertIn('M3UParser parse:text baseURL:url', self.resource_detail)

    def test_starting_python_http_adds_the_configured_subscription_without_inventing_missing_routes(self):
        start = self.root[self.root.index('- (BOOL)startService:'):
                          self.root.index('- (void)toggleService:', self.root.index('- (BOOL)startService:'))]
        self.assertIn('NSString *playlistURL=[ServiceStore subscriptionURLForService:service]', start)
        self.assertIn('if(playlistURL.length)', start)
        self.assertIn('else if([service[@"protocol"] isEqual:@"python-http"])', start)
        self.assertIn('不会添加猜测地址', start)
        use = self.root[self.root.index('page.onUse=^'):
                        self.root.index('page.onLog=^', self.root.index('page.onUse=^'))]
        service_start = self.root.index('- (void)usePluginService:', self.root.index('@implementation RootViewController'))
        service_use = self.root[service_start:
                                self.root.index('- (void)openTVBoxCatalog:', service_start)]
        self.assertIn('[self.subscriptionURLs addObject:url]', service_use)
        self.assertIn('[weakSelf usePluginService:item kind:kind]', use)

    def test_duplicate_remote_import_is_explicit_and_does_not_replace_existing_data(self):
        importer = self.root[self.root.index('- (void)acceptImportedMedia:'):
                             self.root.index('- (void)documentPickerWasCancelled:')]
        self.assertIn('发现相同来源', importer)
        self.assertIn('保留为独立副本', importer)
        self.assertIn('打开已有资源', importer)
        self.assertIn('[ServiceStore remove:identifier]', importer)

    def test_import_shortcuts_share_runtime_detection_and_report_recognized_type(self):
        sheet = (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text()
        importer = (ROOT / 'Sources/MediaPackageImporter.m').read_text()
        downloader = (ROOT / 'Sources/MediaPackageDownloader.m').read_text()
        workflow = self.import_workflow
        self.assertIn('ResourceImportOptionPythonURL', sheet)
        self.assertIn('ResourceImportOptionCatVodURL', sheet)
        self.assertIn('ResourceImportOptionNodeURL', sheet)
        self.assertIn('ResourceImportOptionHostCapabilities', sheet)
        self.assertIn('ResourceImportOptionFolder', sheet)
        self.assertIn('showCategorizedImportOptions', workflow)
        self.assertIn('applyImportCategory:', workflow)
        self.assertIn('UTTypeFolder', workflow)
        self.assertIn('picker.allowsMultipleSelection=!folder', workflow)
        self.assertNotIn('importMediaPackage', self.root)
        self.assertNotIn('importMultipleMediaFiles', self.root)
        self.assertNotIn('importTVBoxCatalog', self.root)
        self.assertIn('runtimeHint:self.runtimeHint', downloader)
        self.assertIn('inspectDirectory:package runtimeHint:runtimeHint', importer)
        self.assertIn('Node.js 快捷导入只适用于 JavaScript 入口', importer)
        self.assertIn('识别类型：%@ · %@', self.root)
        self.assertIn('能力待测：启动后查询插件的 capabilities()', self.root)

    def test_resource_import_sheet_hides_types_without_backend_support(self):
        sheet = (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text()
        for unsupported in ('Emby 服务器', '飞牛影视 / Jellyfin', 'Kazumi 规则仓库',
                            'network-mount', 'WebDAV / SFTP / FTP'):
            self.assertNotIn(unsupported, sheet)
        self.assertNotIn('@"unsupported"', sheet)
        self.assertNotIn('当前版本暂不支持', sheet)
        self.assertIn('@"id":@"services"', sheet)
        self.assertIn('@"id":@"tvbox-url"', sheet)
        self.assertIn('@"id":@"script-auto-url"', sheet)
        self.assertIn('@"id":@"live-file"', sheet)
        smoke = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('numberOfRowsInSection:0]==5', smoke)
        workflow = (ROOT / 'Sources/ResourceImportWorkflowViewController.m').read_text()
        self.assertIn('选择文件（多选）', workflow)
        self.assertIn('选择文件夹', workflow)
        self.assertIn('高级选项', workflow)
        self.assertIn('runtimeSelection', workflow)
        self.assertIn('仅重试失败项', workflow)
        self.assertNotIn('高级导入方式', workflow)

    def test_native_crypto_does_not_use_private_cpython_bytes_resize(self):
        host = (ROOT / 'Sources/PyHost.m').read_text()
        self.assertIn('CCCryptorUpdate(self->cryptor', host)
        self.assertIn('moved != inputLength', host)
        self.assertNotIn('PyBytes_Resize', host)
        self.assertNotIn('_PyBytes_Resize', host)

    def test_imported_source_url_remains_visible_with_inline_resource_search(self):
        self.assertIn('@"title":@"资源来源"', self.resource_detail)
        self.assertIn('copySource', self.resource_detail)
        self.assertNotIn('UISearchController', self.catalog)
        self.assertIn('self.resourceSearchField.placeholder=@"搜索资源"', self.catalog)
        self.assertIn('NSString *query=self.searchQuery?:@""', self.catalog)

    def test_list_restore_stops_when_source_has_no_more_pages(self):
        self.assertIn('owner.pendingRestorePage>requestedPage && MediaBrowserBoolean(normalized[@"hasMore"]) && incoming.count', self.detail)

    def test_tvbox_catalog_import_is_additive_and_adapter_bounded(self):
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        catalog_view = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('ResourceImportOptionTVBox', (ROOT / 'Sources/ResourceImportSheetViewController.m').read_text())
        self.assertIn('TVBoxCatalogStore parseData:data sourceURL:origin', self.import_workflow)
        self.assertIn('@[@"更新已有",@"保存副本"]', self.import_workflow)
        self.assertIn('全量导入（较慢）', catalog_view)
        self.assertIn('推荐按需加载', catalog_view)
        self.assertIn('type 1/4 JSON API', catalog_view)
        self.assertIn('tvboxConfig', store)
        self.assertIn('apiKindTVBox', store)
        self.assertIn('TVBox API 请求地址无效或过长', api_client)
        self.assertIn('vod_play_from', api_client)
        self.assertIn('values[@"wd"]', api_client)
        self.assertIn('values[@"ac"]=@"detail"', api_client)
        self.assertIn('values[@"filter"]=@"true"', api_client)
        self.assertIn('values[@"quick"]=@"false"', api_client)
        self.assertIn('MediaTVBoxReservedFilterKeys()', api_client)
        self.assertIn('values[@"play"]', api_client)
        self.assertIn('MediaTVBoxPlaybackHeaders', api_client)
        self.assertIn('result[@"alternates"]=alternates', api_client)
        self.assertIn('apiCode==0', api_client)
        self.assertIn('hasUsablePayload', api_client)
        self.assertIn('initWithTVBoxSource', self.detail)
        self.assertIn('onUseNativeSite', self.root)
        self.assertIn('removeCatalog:', self.root)
        self.assertIn('@"tvboxCatalogs"', store)

    def test_catvod_doudou_metadata_spider_uses_native_index_and_cross_source_playback(self):
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        global_search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        root = (ROOT / 'Sources/RootViewController.m').read_text()
        self.assertIn('apiKindDouban=[siteType isEqual:@"3"]&&[api.lowercaseString isEqual:@"csp_doudou"]', store)
        self.assertIn('@"douban-index"', store)
        self.assertIn('MediaDoubanRequest(operation,arguments?:@{},error)', api_client)
        self.assertIn('/api/v2/search/subjects', api_client)
        self.assertIn('msearch:###%@###%@', api_client)
        self.assertIn('openMetadataSearchForItem', browser)
        self.assertIn('excludingIndexSources:YES', browser)
        self.assertIn('page.initialKeyword=keyword', browser)
        self.assertIn('self.initialKeyword.length', global_search)
        self.assertIn('douban-index', root)
        catalog_test = (ROOT / 'Tests/native_profile_tests.m').read_text()
        self.assertIn('type 3 JAR stays unsupported', catalog_test)
        self.assertIn('type 1 direct playback', (ROOT / 'Tests/native_media_api_tests.m').read_text())

    def test_smart_resource_import_recognizes_tvbox_json_and_ios_bundle_urls(self):
        workflow = self.import_workflow
        self.assertIn('TVBoxCatalogStore parseData:data sourceURL:origin', workflow)
        self.assertIn('candidateForData:data file:', workflow)
        self.assertIn('catalogWithMacCMSAPIURL:origin', workflow)
        self.assertIn('row[@"kind"] isEqual:@"catalog"', workflow)
        self.assertIn('ResourceImportFetcher', workflow)
        self.assertIn('isEqual:@"url"', workflow)
        self.assertIn('recognizeURL', workflow)
        self.assertIn('response.URL.absoluteString?:raw', workflow)
        self.assertNotIn('shouldImportTVBoxCatalogFromURL', self.root)

    def test_builtin_maccms_catalogs_cover_ystj_sources(self):
        # 内置 4 个 MacCMS 影视源（与 For-ADM 蜘蛛 ystj.py 同款），读取目录时幂等补入。
        store = self.tvbox
        self.assertIn('ensureBuiltInMacCMSCatalogs', store)
        self.assertIn('[self ensureBuiltInMacCMSCatalogs]', store)
        for api in ('https://cj.lziapi.com/api.php/provide/vod/',
                    'https://caiji.dyttzyapi.com/api.php/provide/vod/',
                    'https://api.wujinapi.me/api.php/provide/vod/',
                    'https://api.ffzyapi.com/api.php/provide/vod/'):
            self.assertIn(api, store)
        for cid in ('builtin-maccms-lziapi', 'builtin-maccms-dytt',
                    'builtin-maccms-wujin', 'builtin-maccms-ffzy'):
            self.assertIn(cid, store)
        self.assertIn('@"maccms-api"', store)
        self.assertIn('@"builtin":@YES', store)
        # 幂等：已存在同 id 时跳过（不重复插入）。
        ensure = store.split('+ (void)ensureBuiltInMacCMSCatalogs', 1)[1].split('+ (NSArray<NSDictionary *> *)catalogs', 1)[0]
        self.assertIn('if([ids containsObject:spec[@"id"]]) continue;', ensure)
        # 直读 NSUserDefaults，不经 +catalogs，避免递归。
        self.assertIn('[NSUserDefaults.standardUserDefaults arrayForKey:@"tvboxCatalogs"]', ensure)
        self.assertNotIn('[self catalogs]', ensure)

    def test_media_home_reuses_existing_history_favorites_and_services(self):
        self.assertIn('MediaPlaybackStateStore.watchHistory', self.detail)
        self.assertIn('trailingSwipeActionsConfigurationForRowAtIndexPath', self.detail)
        self.assertIn('removeHistoryEntryWithKey', self.detail)
        self.assertIn('performsFirstActionWithFullSwipe=NO', self.detail)
        self.assertIn('cctv.mediaFavorites.v1', self.detail)
        self.assertIn('MediaHomePinnedSourcesDefaultsKey', self.detail)
        self.assertIn('sourcesProvider', self.detail)
        self.assertIn('onActivateService', self.detail)
        # 413 首页用悬浮搜索按钮（MediaFeedView 架构），不用 main 旧首页
        # 的 browse/search 按钮与 homeSearchButton 显隐切换。
        self.assertIn('media-home-floating-search', self.detail)
        self.assertIn('floatingHomeSearchButton', self.detail)
        self.assertIn('openGlobalSearch', self.detail)
        self.assertIn('onDisplayModeChanged', self.root)
        self.assertIn('[owner activate:source keepingHome:YES]', self.detail)
        self.assertIn('openHomeConfiguration', self.detail)
        self.assertIn('@"影视库"', self.root)
        self.assertIn('CCTV",@"频道",@"影视库",@"资源",@"设置', self.root)
        self.assertIn('@"频道"', self.root)

    def test_tvbox_collection_can_be_added_as_a_bounded_batch_with_live_user_agents(self):
        bulk = (ROOT / 'Sources/TVBoxCatalogBulkImporter.m').read_text()
        root = self.root
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        catalog_view = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        self.assertIn('onImportCompatibleContents', catalog_view)
        self.assertIn('全量导入（较慢）', catalog_view)
        self.assertIn('catalogsProvider', (ROOT / 'Sources/MediaBrowserViewController.h').read_text())
        self.assertIn('onOpenTVBoxCatalog', self.detail)
        source_selector = self.detail[self.detail.index('- (void)chooseResource'):self.detail.index('- (void)refreshCurrentSource')]
        self.assertIn('catalogsProvider', source_selector)
        self.assertIn('按需选择', source_selector)
        self.assertIn('bulkImportTVBoxCatalog:identifier page:weakPage', root)
        self.assertIn('_maximumConcurrentDownloads=3', bulk)
        self.assertIn('512*1024*1024', bulk)
        self.assertIn('downloadLimitReached', root)
        self.assertIn('headers:site[@"header"]', bulk)
        self.assertIn('manifest[@"options"]=ext', bulk)
        self.assertIn('tvboxSiteKeys', bulk)
        self.assertIn('[downloader cancel]', bulk)
        self.assertIn('live[@"ua"]', store)
        self.assertIn('for(NSDictionary *live in lives)', root)
        self.assertIn('forHTTPHeaderField:@"User-Agent"', root)
        self.assertIn('推荐按需加载', catalog_view)

    def test_tvbox_aggregators_accept_redirects_maccms_basic_auth_and_larger_catalogs(self):
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        downloader = (ROOT / 'Sources/TVBoxCatalogDownloader.m').read_text()
        package_downloader = (ROOT / 'Sources/MediaPackageDownloader.m').read_text()
        root = self.root
        self.assertIn('apiKindMacCMS', store)
        self.assertIn('TVBoxBasicAuthorization', store)
        self.assertIn('sites.count>2000 || lives.count>500', store)
        self.assertIn('data.length > 8*1024*1024', store)
        self.assertIn('++self.redirectCount<=5', downloader)
        self.assertIn('https"]&&[to.scheme.lowercaseString isEqual:@"http', downloader)
        self.assertIn('PackageSafeHeaders', package_downloader)
        self.assertIn('PackageSameCredentialScope', package_downloader)
        self.assertIn('saved[@"importHeaders"]', package_downloader)
        self.assertIn('importHeaders",@"downloadChecksum', (ROOT / 'Sources/ServiceStore.m').read_text())
        self.assertIn('headers:item[@"importHeaders"]', root)
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('return self.tvboxSource?8*1024*1024:2*1024*1024', api_client)
        self.assertIn('redirectCount<=5', api_client)
        self.assertIn('setValue:nil forHTTPHeaderField:name', api_client)
        self.assertIn('_capture_plugin_loopback_servers()', (ROOT / 'Plugins/host_media_runtime.py').read_text())

    def test_resource_exports_keep_complete_catalog_data_and_bundle_internal_scripts(self):
        store = (ROOT / 'Sources/TVBoxCatalogStore.m').read_text()
        exporter = (ROOT / 'Sources/TVBoxCatalogPackageExporter.m').read_text()
        catalog_view = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        resource_view = (ROOT / 'Sources/ConfigCenterViewController.m').read_text()
        root = self.root
        self.assertIn('_sourceConfigData', store)
        self.assertIn('exportDataForCatalogID:', store)
        self.assertIn('exportSingleResourceForCatalogID:', store)
        self.assertIn('TVBoxZIPData', store)
        self.assertIn('导出完整合集 JSON', catalog_view)
        self.assertIn('导出资源 ZIP（含可获取的 PY / JS）', catalog_view)
        self.assertNotIn('导出完整资源 ZIP（含 PY / JS）', catalog_view)
        self.assertIn('contextMenuConfigurationForRowAtIndexPath', catalog_view)
        self.assertIn('导出单项资源文件', resource_view)
        self.assertIn('catalog-json', resource_view)
        self.assertIn('catalog-zip', resource_view)
        self.assertIn('TVBoxCatalogPackageExporter', root)
        self.assertIn('CCTVTVBoxStoredSubscriptionToken()', root)
        self.assertIn('scripts/%03lu-', exporter)
        self.assertIn('source-manifest.json', exporter)
        self.assertIn('部分导出 · 内部脚本未收齐', exporter)
        self.assertIn('已收集 %lu / %lu', exporter)
        self.assertIn('128*1024*1024', exporter)
        native = (ROOT / 'Tests/native_profile_tests.m').read_text()
        self.assertIn('complete collection JSON and single-site JSON preserve original provider fields', native)

    def test_unified_media_reuses_history_and_moves_management_to_dedicated_entries(self):
        self.assertIn('MediaPlaybackStateStore.watchHistory', self.browser)
        self.assertIn('@"__historyEntry"', self.browser)
        self.assertIn('[owner openHistoryEntry:history]', self.browser)
        self.assertIn('- (void)openFavorites', self.browser)
        self.assertIn('MediaHomePinnedSources', self.detail)
        self.assertIn('onResources', self.browser)
        self.assertIn('onMediaDisplaySettings', self.root)
    def test_global_search_filters_restore_state_and_cancel_changed_queries(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        self.assertIn('media-search-station-filters', search)
        self.assertIn('[self.renderedFilterKey isEqual:self.filterPositionKey]', search)
        self.assertIn('MediaSearchEntries(entries,provider).count', search)
        self.assertIn('MediaSearchAppend(stored,items,providerID,providerName,remaining)', search)
        self.assertIn('HostImageLoader.shared loadPosterURL:url intoImageView:view completion:', search)
        self.assertIn('暂无影片信息', search)
        self.assertIn('@"无结果"', search)
        self.assertIn('@"来源失败"', search)
        changed = search.split('textDidChange:(NSString *)searchText', 1)[1].split('- (BOOL)sourceAvailableForSearch:', 1)[0]
        self.assertIn('[self cancelSearch]', changed)
        self.assertIn('[self cancelJobsAndAdvanceGeneration]', changed)
        self.assertIn('self.keyword=@""', changed)
        self.assertIn('self.savedSearchOffset=self.tableView.contentOffset', search)
        self.assertIn('[self restoreReadingPosition:self.savedReadingPosition]', search)
        self.assertIn('if(!self.resultsVisible){return;}', search)
        self.assertIn('hasSubmittedSearchInput', search)
        self.assertIn('self.selectedProvider&&!sourceFailed', search)
        self.assertIn('job.generation == self.generation', search)
        self.assertIn('self.jobs[@(job.section)] == job', search)

    def test_global_search_reports_each_source_and_retries_failures(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        self.assertIn('已完成 %lu / %lu 个资源', search)
        self.assertIn('重试失败', search)
        self.assertIn('retryFailedSources', search)
        self.assertIn('部分完成', search)
        self.assertIn('failedProviders', search)
        self.assertIn('retryProviders', search)
        self.assertIn('sourceAvailableForSearch', search)
        self.assertIn('不会自动启动其他插件', search)
        self.assertIn('MediaGlobalSearchMaximumConcurrentSources = 3', search)
        self.assertIn('MediaGlobalSearchJob', search)
        self.assertIn('searchNextProviderForJob', search)
        self.assertIn('cancelJobsAndAdvanceGeneration', search)
        self.assertIn('enqueueStartedSection', search)
        self.assertIn('initWithTVBoxSource:source', search)

    def test_signed_media_urls_keep_parameters_and_relay_failures_are_stage_specific(self):
        relay = (ROOT / 'Plugins/host_media_relay.py').read_text()
        service = (ROOT / 'Plugins/media-service.py').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        native_tests = (ROOT / 'Tests/native_media_api_tests.m').read_text()
        for stage in ('upstream_http_error', 'upstream_timeout', 'upstream_network_error',
                      'upstream_dns_error', 'upstream_tls_error', 'upstream_connect_error',
                      'manifest_invalid', 'manifest_encoding_invalid', 'manifest_too_large'):
            self.assertIn(stage, relay)
        self.assertIn('parent.query', relay)
        self.assertIn('fallback_url', relay)
        self.assertIn('X-CCTVHost-Relay-Stage', relay)
        self.assertIn('diagnostic_id=correlation_id or request_id', service)
        self.assertIn('alternate[\'originalURL\'] = address', service)
        self.assertIn('alternate[@"originalURL"]', self.playback)
        self.assertIn('X-CCTVHost-Correlation-ID', api_client)
        self.assertIn('extensionless signed media URL stays intact', native_tests)
        self.assertIn('detail preserves signed episode URLs byte-for-byte', native_tests)

    def test_player_distinguishes_item_ready_from_first_frame_ready(self):
        self.assertIn('AVPlayerItemStatusFailed', self.playback)
        self.assertIn('AVPlayerLayer', self.playback)
        self.assertIn('readyForDisplay', self.playback)
        self.assertIn('playback_first_frame_ready', self.playback)
        headers = (ROOT / 'Sources/MediaPlaybackHeaders.m').read_text()
        self.assertIn('MediaPlaybackHeadersFromResult(result)', self.playback)
        self.assertIn('AVURLAssetHTTPHeaderFieldsKey', self.playback)
        self.assertIn('result[@"headers"]', headers)
        self.assertIn('result[@"header"]', headers)
        self.assertIn('@"host"', headers)
        fixture = (ROOT / 'Tests/UISmoke/fixture_server.py').read_text()
        self.assertIn('X-Fixture-Playback', fixture)
        self.assertIn('self.headers.get("Referer")', fixture)
        self.assertIn('播放器尚未显示画面', self.playback)
        self.assertNotIn('首帧渲染状态未知', self.playback)

    def test_web_playback_close_keeps_native_fallback_action_available(self):
        appeared = self.playback[self.playback.index('- (void)viewDidAppear:'):
                                 self.playback.index('- (void)viewWillDisappear:')]
        fallback = self.playback[self.playback.index('- (void)tryNativePlayback {'):
                                 self.playback.index('- (void)selectLine:')]
        webview = (ROOT / 'Sources/MediaWebViewController.m').read_text()
        self.assertIn('网页播放已关闭 · 可尝试原生播放', appeared)
        self.assertIn('[self setRetryAvailable:YES]', appeared)
        self.assertNotIn('self.awaitingWebPlaybackReturn=NO', appeared)
        # playbackMethodOverride 是死数据（全仓库无读取处），tryNativePlayback
        # 已删掉它，路由改按格式决定，不再把 FLV 推回注定失败的 AVPlayer。
        self.assertNotIn('playbackMethodOverride', fallback)
        self.assertIn('web.onTryNativePlayback=^{[weakSelf tryNativePlayback];}', self.playback)
        self.assertIn('@"原生播放"', webview)
        self.assertIn('loadInitialPageAtURL:configurationURL cookie:cookie', webview)
        self.assertIn('httpCookieStore setCookie:item', webview)
        self.assertIn('WKWebsiteDataStore.nonPersistentDataStore', webview)

    def test_webview_cookie_store_cannot_block_initial_page_load(self):
        webview = (ROOT / 'Sources/MediaWebViewController.m').read_text()
        self.assertEqual(webview.count('loadInitialPageAtURL:configurationURL cookie:cookie'), 2)
        initial_load = webview[webview.index('- (void)loadInitialPageAtURL:'):
                               webview.index('- (void)installCookieHeader:', webview.index('- (void)loadInitialPageAtURL:'))]
        self.assertIn('installCookieHeader:cookie forURL:url completion:startLoading', initial_load)
        self.assertIn('dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1200*NSEC_PER_MSEC)', initial_load)
        self.assertIn('if(!owner||owner.didClose||started)return', initial_load)
        self.assertIn('allHTTPHeaderFields=MediaPlaybackHeadersFromResult(self.result)', webview)

    def test_parser_marked_source_plays_inside_the_app_without_external_handoff(self):
        route = self.playback[self.playback.index('BOOL directMedia='):
                              self.playback.index('self.hasDiagnosticTimeControlStatus=NO;', self.playback.index('BOOL directMedia='))]
        self.assertIn('result[@"parse"]', route)
        self.assertIn('result[@"jx"]', route)
        self.assertIn('MediaWebViewController *web=[[MediaWebViewController alloc] initWithResult:result', route)
        self.assertIn('[[UINavigationController alloc] initWithRootViewController:web]', route)
        self.assertIn('[self presentViewController:nav animated:YES completion:nil]', route)
        self.assertNotIn('openURL:', route)

    def test_no_media_error_offers_the_original_episode_page_without_exposing_its_url(self):
        self.assertIn('MediaPlaybackEpisodePageFallbackURL', self.playback)
        self.assertIn('pluginCode isEqualToString:@"NO_MEDIA"', self.playback)
        self.assertIn('owner.episodeWebFallbackAvailable=pageURL!=nil', self.playback)
        self.assertIn('@selector(openEpisodePageWebFallback)', self.playback)
        self.assertIn('episode_web_fallback_available', self.playback)
        self.assertIn('打开分集网页尝试播放', self.playback)
        self.assertNotIn('fields[@"episode_url"]', self.playback)

    def test_extensionless_signed_media_endpoints_use_native_playback_classification(self):
        client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        native_tests = (ROOT / 'Tests/native_media_api_tests.m').read_text()
        self.assertIn('MediaTVBoxQueryNameLooksSigned', client)
        self.assertIn('@"token",@"sign",@"auth"', client)
        self.assertIn('[compact hasSuffix:@"key"]', client)
        self.assertIn('camel-case auth and session tokens uses native playback', native_tests)
        self.assertIn('playback_has_signed_parameter', playback)

    def test_tvbox_playback_keeps_native_api_client_across_episode_switches_and_auto_next(self):
        self.assertIn('MediaPlaybackClientForSource', self.playback)
        self.assertIn('MediaSourceUsesNativeCatalogAPI(source)', self.playback)
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('[protocol isEqual:@"tvbox-api"]', api_client)
        self.assertIn('[protocol isEqual:@"maccms-api"]', api_client)
        self.assertIn('self.client=MediaPlaybackClientForSource(source)', self.playback)
        self.assertIn('page.client=MediaPlaybackClientForSource(page.source)', self.playback)
        self.assertIn('cctv.mediaAutoPlayNext', self.playback)
        self.assertIn('playback_auto_advance', self.playback)
        self.assertIn('self.episodeIndex+1<self.episodes.count', self.playback)
        self.assertIn('关闭自动连播下一集', self.playback)
        self.assertIn('开启自动连播下一集', self.playback)

    def test_configurable_play_timeout_uses_manifest_options_and_preserves_other_timeouts(self):
        client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        playback_client = self.playback[self.playback.index('static MediaAPIClient *MediaPlaybackClientForSource'):
                                        self.playback.index('static NSDictionary *MediaPlaybackDiagnosticSourceFields')]
        self.assertIn('manifest[@"options"]', playback_client)
        self.assertIn('source[@"options"]', playback_client)
        self.assertIn('rawTimeout=options[@"playTimeoutMs"]', playback_client)
        self.assertIn('timeout=MIN(120000,MAX(1000,timeout))', playback_client)
        self.assertIn('_playTimeoutMilliseconds=15000', client)
        self.assertIn('timeoutIntervalForResource=125', client)
        self.assertIn('request.timeoutInterval=[operation isEqual:@"play"]?self.playTimeoutMilliseconds/1000.0:self.requestTimeout', client)
        self.assertIn('sessionForOperation:operation', client)
        # 移植合并：cdeeaff 把网络超时改为可配置（cctv.networkTimeout.v1，
        # 默认 20s，上限 40s），不再硬编码 requestTimeout:40。
        self.assertIn('initWithPort:port requestTimeout:savedTimeout', client)
        self.assertIn('doubleForKey:@"cctv.networkTimeout.v1"]:20', client)

    def test_tvbox_filters_and_playback_flags_survive_native_adaptation(self):
        client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('MediaTVBoxFilters(root)', client)
        self.assertIn('arguments[@"filters"]', client)
        self.assertIn('clearFilters', self.detail)
        self.assertIn('result[@"jx"]', self.playback)
        self.assertIn('result[@"requiresWebPlayback"]', self.playback)
        self.assertNotIn('@"filters":@{}', client)
        self.assertIn('MediaTVBoxResolvedPoster', client)
        self.assertIn('TVBoxWebURL(resolved.absoluteString)', (ROOT / 'Sources/TVBoxCatalogStore.m').read_text())

    def test_global_search_uses_bounded_source_health_cooldowns(self):
        search = (ROOT / 'Sources/MediaGlobalSearchViewController.m').read_text()
        health = (ROOT / 'Sources/MediaSourceHealthStore.m').read_text()
        self.assertIn('sortPendingSectionsByHealth', search)
        self.assertIn('recordSourceID:job.source', search)
        self.assertIn('MediaSourceHealthLimit = 128', health)
        self.assertIn('MediaSourceHealthExpiry = 7 * 24 * 60 * 60', health)
        self.assertIn('MIN(600,30*pow', health)

    def test_media_http_health_precedes_slow_spider_init_and_capabilities_retry_busy(self):
        service = (ROOT / 'Plugins/media-service.py').read_text()
        runtime = (ROOT / 'Plugins/host_media_runtime.py').read_text()
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        load_capabilities = self.detail[self.detail.index('- (void)loadCapabilities {'):
                                        self.detail.index('- (void)loadHome {', self.detail.index('- (void)loadCapabilities {'))]
        self.assertLess(service.index('server = Server((args.bind, args.port), runtime)'),
                        service.index('runtime.start_initialization(create_engine, initialization_failed)'))
        self.assertIn("'runtime_state': self._state", runtime)
        self.assertIn("MediaError('BUSY', '影视资源脚本正在准备", runtime)
        self.assertIn('@"plugin_retryable":@(pluginRetryable)', api_client)
        self.assertIn('error.userInfo[@"plugin_retryable"]', load_capabilities)
        self.assertIn('capabilityReadinessRetryCount<45', load_capabilities)
        self.assertIn('资源脚本正在准备', load_capabilities)

    def test_media_health_waits_for_spider_ready_without_repeating_busy_api_calls(self):
        readiness = (ROOT / 'Sources/LocalServiceReadiness.m').read_text()
        browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text()
        self.assertIn('healthJSON[@"runtime_ready"]', readiness)
        self.assertIn('@"runtime_preparing"', readiness)
        self.assertIn('@"runtime_failed"', readiness)
        self.assertIn('NSTimeInterval pollInterval = 0.4', readiness)
        self.assertIn('MIN(2.0,pollInterval*1.6)', readiness)
        self.assertIn('MAX(0.75,pollInterval)', readiness)
        self.assertIn('initWithURL:health timeout:45 requiresHealthJSON:YES', browser)

    def test_playback_recovery_is_generation_scoped_and_quality_restores_pause_state(self):
        self.assertIn('owner.stallRecoveryAttempts>=1', self.playback)
        self.assertIn('playback_stall_recovery_started', self.playback)
        self.assertIn('generation!=owner.playerGeneration', self.playback)
        self.assertIn('pendingQualityWasPlaying', self.playback)
        self.assertIn('self.player.timeControlStatus!=AVPlayerTimeControlStatusPaused', self.playback)
        self.assertIn('UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground||self.pictureInPictureActive', self.playback)
        self.assertIn('CCTVPlayerControllerReadyContext', self.playback)
        self.assertIn('[self.playerController addObserver:self forKeyPath:@"readyForDisplay"', self.playback)
        self.assertIn('[self.playerController removeObserver:self forKeyPath:@"readyForDisplay"', self.playback)
        self.assertIn('item==self.player.currentItem&&controller==self.playerController&&controller.readyForDisplay', self.playback)
        self.assertIn('未能按名称确认分集', self.playback)

    def test_settings_expose_bounded_movie_metadata_cache_cleanup(self):
        settings = (ROOT / 'Sources/SettingsViewController.m').read_text()
        cache = (ROOT / 'Sources/MediaMetadataCache.m').read_text()
        self.assertIn('clearMediaMetadata', settings)
        self.assertIn('收藏、观看历史、订阅和插件数据会保留', settings)
        self.assertIn('MediaMetadataCacheEntryLimit = 64', cache)
        self.assertIn('MediaMetadataCacheByteLimit = 8 * 1024 * 1024', cache)
        self.assertIn('MediaMetadataPersistentEntryLimit = 32', cache)
        self.assertIn('MediaMetadataPersistentByteLimit = 4 * 1024 * 1024', cache)
        self.assertIn('MediaMetadataPersistentSafeValue', cache)
        self.assertIn('MediaDetailContainsTransientAddress', cache)
        self.assertIn('BOOL persist=[@[@"home",@"category"] containsObject:operation]', cache)
        self.assertIn('影片详情仅短时缓存在内存中，播放地址不持久化', settings)

    def test_rotation_is_limited_to_the_player_and_supported_by_the_app(self):
        with (ROOT / 'Resources/Info.plist').open('rb') as f:
            plist = plistlib.load(f)
        self.assertIn('UIInterfaceOrientationLandscapeLeft', plist['UISupportedInterfaceOrientations'])
        self.assertIn('UIInterfaceOrientationLandscapeRight', plist['UISupportedInterfaceOrientations'])
        app_delegate = (ROOT / 'Sources/AppDelegate.m').read_text()
        self.assertIn('self.topViewController.supportedInterfaceOrientations', app_delegate)
        self.assertIn('supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait;', self.root)
        self.assertIn('supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}', self.detail)
        self.assertIn('UIInterfaceOrientationMaskAllButUpsideDown', self.playback)

    def test_imported_playlist_snapshots_are_property_list_safe(self):
        self.assertIn("CCTVPlaylistSnapshotRows", self.root)
        self.assertNotIn('@"cachedChannels":parsed', self.root)
        smoke = (ROOT / "Tests/UISmoke/SmokeDriver.m").read_text()
        self.assertIn("valid for persistent preference storage", smoke)
        self.assertIn("serializable channel snapshots", smoke)

    def test_bundled_aggregators_stay_grouped_and_load_members_on_demand(self):
        media = self.detail
        resources = ROOT / 'Resources/BuiltinMedia'
        lytvs = json.loads((resources / 'lytvs-ios.json').read_text())
        for_adm = json.loads((resources / 'for-adm.json').read_text())
        for retired in ('haoliang-live.json', 'haoliang-py.json', 'haoliang-tvbox.json',
                        'hongguo-1.0.4.py', 'hongguo-1.0.4.js'):
            self.assertFalse((resources / retired).exists())
        self.assertEqual({p.name for p in resources.glob('hongguo-*')},
                         {'hongguo-python.py', 'hongguo-node.js'})
        self.assertIn("VERSION = '1.0.5-cctvhost-r6'", (resources / 'hongguo-python.py').read_text())
        self.assertIn("const VERSION = '1.0.5-cctvhost-r6';", (resources / 'hongguo-node.js').read_text())
        self.assertEqual(len(lytvs['sites']), 324)
        self.assertEqual(len(lytvs['lives']), 40)
        self.assertEqual(for_adm['name'], 'For-ADM CCTVHost 影视资源合集')
        self.assertEqual(len(for_adm['sites']), 8)
        self.assertEqual(len(for_adm['lives']), 0)
        self.assertTrue(all(site.get('type') == 'script' and site.get('api', '').lower().split('?', 1)[0].endswith('.js') for site in for_adm['sites']))
        self.assertTrue(all(site['api'].endswith('?v=3') for site in for_adm['sites']))
        self.assertEqual(len({site['key'] for site in for_adm['sites']}), 8)
        for builtin, example in (
            (resources / 'hongguo-python.py', ROOT / 'Examples/hgtv-python/hgtv_public_1_0_5.py'),
            (resources / 'hongguo-node.js', ROOT / 'Examples/hgtv-node/hgtv.js'),
        ):
            self.assertEqual(hashlib.sha256(builtin.read_bytes()).digest(), hashlib.sha256(example.read_bytes()).digest())
        lytvs_python = [site for site in lytvs['sites'] if site['api'].split('?', 1)[0].lower().endswith('.py')]
        self.assertEqual(len(lytvs_python), 223)
        self.assertEqual(sum(site['api'].count('__LYTVS_SUBSCRIPTION_TOKEN__') for site in lytvs['sites']), 218)
        self.assertFalse((resources / 'zen-keke-stream.js').exists())
        self.assertIn('installBundledMediaResourcesIfNeeded', self.root)
        self.assertIn('builtin-lytvs-ios', self.root)
        self.assertIn('builtin-for-adm', self.root)
        self.assertIn('cctv.bundledMediaResources.v5', self.root)
        self.assertIn('builtin-hongguo-python', self.root)
        self.assertIn('builtin-hongguo-node', self.root)
        self.assertIn('runtimeHint:spec[@"runtime"]', self.root)
        self.assertIn('playTimeoutMs', self.root)
        self.assertIn('builtin-haoliang-live', self.root)  # one-time migration removes prior installs
        self.assertIn('builtin-haoliang-py', self.root)
        self.assertIn('builtin-haoliang-tvbox', self.root)
        self.assertIn('CCTVTVBoxStoredSubscriptionToken', self.root)
        self.assertIn('CCTVTVBoxSaveSubscriptionToken', self.root)
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly', self.root)
        self.assertIn('CCTVTVBoxURLByResolvingToken', self.root)
        self.assertIn('runtimeHint:runtimeHint completion:', self.root)
        self.assertIn('MediaPackageImporter importFile:', self.root)
        self.assertIn('cp -R Resources/BuiltinMedia "$APP/BuiltinMedia"', (ROOT / 'Scripts/ci-build.sh').read_text())

        selector = media[media.index('- (void)chooseResource'):media.index('- (void)refreshCurrentSource')]
        self.assertIn('if(memberID.length)continue', selector)
        self.assertIn('一个资源站 · 按需选择 %lu 个内部站点/直播列表', selector)
        self.assertIn('chooseCatalogProvider', selector)
        self.assertIn('onImportCatalogSite', selector)
        self.assertIn('onSubscribeCatalogLive', selector)
        self.assertIn('selectedMediaCatalogID', media)

        profiles_start = self.root.index('- (NSArray *)configurationProfiles')
        profiles = self.root[profiles_start:self.root.index('- (void)openPluginResource:', profiles_start)]
        self.assertIn('tvboxCatalogID', profiles)
        self.assertIn('[catalogIDs containsObject:catalogID]', profiles)
        live_loader_start = self.root.index('- (void)subscribeLiveFromCatalog:')
        live_loader = self.root[live_loader_start:self.root.index('- (void)openTVBoxCatalog:', live_loader_start)]
        self.assertIn('[self deleteSubscription:existingURL]', live_loader)
        self.assertIn('tvboxLiveSelection.%@', live_loader)
        self.assertIn('tvboxCatalogID', live_loader)

    def test_for_adm_signed_sources_follow_the_working_native_client_contract(self):
        downloader = self.package_downloader
        self.assertIn('PackageAdaptForADMSignedSource', downloader)
        self.assertIn('raw.githubusercontent.com', downloader)
        for source in ('kkapp', 'ncat', 'happ'):
            self.assertIn(f'/joeshu/for-adm/master/cctvhost/{source}.js', downloader)
        self.assertIn('/joeshu/for-adm/master/cctvhost/yqk.js', downloader)
        self.assertIn('sitePrepareImageDomains(value)', downloader)
        self.assertIn("siteHeaderValue(headers,'encrypted')!=='1'", downloader)
        self.assertIn("contentType.indexOf('image/')===0", downloader)
        self.assertIn('await sitePrepareImageDomains(data)', downloader)
        self.assertIn('encrypted_image_requires_decryption_or_clear_mirror', (ROOT / 'Sources/HostImageLoader.m').read_text())
        self.assertIn('timeout=MAX(timeout,60000)', self.playback)
        self.assertIn('rawTimeout=opts[@"timeout"]', self.js_runtime)
        self.assertIn('timeoutInterval:timeout', self.js_runtime)
        self.assertIn('timeoutIntervalForResource=self.genericMode?120:15', self.js_runtime)
        self.assertIn('/joeshu/for-adm/master/cctvhost/dyls.js', downloader)
        self.assertIn("if(String(ep.parseUrl||'').trim())return false", downloader)
        self.assertIn("function dylProbeHls(url,headers)", downloader)
        self.assertIn("await dylProbeHls(safe,headers)", downloader)
        self.assertIn("m3u8|mp4", downloader)
        self.assertIn("method.toLowerCase()", downloader)
        self.assertIn("path==='/config/prod/appInit.html'?method:method.toLowerCase()", downloader)
        self.assertIn("join('&')", downloader)
        self.assertIn("headers['Content-Type']='application/json'", downloader)
        self.assertIn("this.api(path,params,'logic','GET')", downloader)
        self.assertIn('rows=Array.isArray(result)?result:', downloader)
        self.assertIn("headers.Referer=Source.origin+'/'", downloader)
        self.assertIn('For-ADM 三源脚本协议已变化，未导入不兼容版本。', downloader)
        self.assertIn('adapterOccurrences==1&&![text containsString:@"async function sitePrepareImageDomains(value)"]', downloader)
        self.assertIn('probe=siteImageDomains[String(row.imageGroup||\'\')]', downloader)
        self.assertIn('resolverOccurrences==1&&![text containsString:@"async function dylProbeHls(url,headers)"]', downloader)
        self.assertIn('function yqkRequestTimeout(budget,fallback)', downloader)

    def test_explicit_maccms_web_pages_keep_the_web_playback_handoff(self):
        api = (ROOT / 'Sources/MediaAPIClient.m').read_text()
        self.assertIn('BOOL native=!webPage&&(MediaPlaybackResultSupportsNativePlayback(result)||MediaTVBoxURLHasSignedQuery(url))', api)
        self.assertIn('static BOOL MediaTVBoxURLHasSignedQuery(NSString *value)', api)
        self.assertIn('result[@"requiresWebPlayback"]=@(webPage||!native)', api)
    def test_resource_page_has_per_item_refresh_actions(self):
        # 资源页每种主要条目都有独立刷新入口：插件行（清单/健康/EPG/重启）、
        # 订阅行（健康/EPG）、合集行（重新下载），不再只有整页刷新。
        for action in ('onRecheckProfile', 'onRematchEPGProfile', 'onRestartProfile', 'onRefreshCatalogProfile'):
            self.assertIn(action, self.catalog)
            self.assertIn(action, self.root)
        for title in ('刷新订阅清单', '重新检测健康', '重新匹配节目单（EPG）', '重启服务', '刷新合集'):
            self.assertIn(title, self.catalog)
        # 插件行的刷新回调收到的仍是行 source（plugin:<id>），由 Root 解析
        # 到它自己的订阅清单地址；直接传 plugin: 源给 fetchSubscription 是空操作。
        self.assertIn('refreshSubscriptionForProfile:', self.root)
        self.assertIn('resourceServiceForSource:source', self.root)
        self.assertIn('subscriptionURLForService:service', self.root)

    def test_resource_page_catalog_refresh_preserves_existing_id(self):
        # 合集刷新用新解析结果覆盖旧行：先把解析出的新 id 换回原合集 id，
        # saveCatalog 按 id 合并才不会把同一合集存成两行。
        body = self.root.split('- (void)refreshTVBoxCatalogProfile:(NSString *)source {', 1)[1].split('- (void)installPlaylist:', 1)[0]
        self.assertIn('catalogForID:identifier', body)
        self.assertIn('loadURL:url completion:', body)
        self.assertIn('updated[@"id"]=identifier', body)
        self.assertIn('saveCatalog:updated', body)
        self.assertIn('refreshConfigurationPage', body)
        # MacCMS 行的 url 是接口地址而非 JSON 配置，不走下载刷新；空合集不覆盖。
        self.assertIn('isEqual:@"maccms"', body)
        self.assertIn('重新下载的合集为空，已保留原合集', body)

    def test_resource_page_health_recheck_forces_a_fresh_readiness_probe(self):
        # 有清单的条目重查健康时先丢弃 2 秒内的就绪缓存，强制重新探测；
        # 无清单的插件直接对服务做一次就绪探测，失败有明确提示。
        body = self.root.split('- (void)recheckProfileHealth:(NSString *)source {', 1)[1].split('- (void)rematchEPGForProfile:(NSString *)source {', 1)[0]
        self.assertIn('readyLocalOrigins removeObjectForKey', body)
        self.assertIn('readinessForURL:base service:service', body)
        self.assertIn('服务未运行，无法检测健康状态', body)
        self.assertIn('showServiceError:error.localizedDescription', body)

    def test_successful_subscription_refresh_clears_stale_detected_epg(self):
        # 新清单不再提供节目单地址时，成功刷新要清掉过期推导值，否则行上
        # 永远显示“已配置”；失败路径不碰它，旧地址留待下次成功刷新再推导。
        self.assertIn('removeValueForKey:@"detectedEPGURL"', self.root)
        self.assertIn('+ (void)removeValueForKey:', self.profile_store)
        fetch = self.root.split('- (void)fetchSubscription:', 1)[1].split('- (void)installPlaylist:', 1)[0]
        self.assertIn('removeValueForKey:@"detectedEPGURL"', fetch)
        self.assertIn('新订阅清单未提供节目单', fetch)

    def test_service_detail_offers_restart_with_progress_and_failure_feedback(self):
        # 服务详情页此前只有启停开关与接口检测，没有重启入口；重启与
        # 影视库页复用同一 restartMediaService，失败弹明确原因。
        self.assertIn('onRestartService', self.services)
        self.assertIn('onRestart', self.services)
        self.assertIn('重启服务', self.services)
        self.assertIn('正在重启服务…', self.services)
        self.assertIn('重启失败', self.services)
        self.assertIn('restartMediaService:service completion:completion', self.root)

    def test_plugin_service_page_probes_http_and_refreshes_subscription_count(self):
        # YSP Live 服务页此前只写“HTTP 未检测”，订阅数只在建页时传入一次：
        # 现每次出现时现取订阅数，并对 /health 做一次带代次守卫的探测。
        self.assertIn('subscriptionCountProvider', self.plugin_page)
        self.assertIn('subscriptionCountProvider=^', self.root)
        self.assertIn('/health', self.plugin_page)
        self.assertIn('HTTP 可达', self.plugin_page)
        self.assertIn('HTTP 未响应', self.plugin_page)
        self.assertNotIn('HTTP 未检测', self.plugin_page)
        self.assertIn('httpProbeGeneration!=generation', self.plugin_page)


    def test_service_detail_delete_blocked_while_running_explains_stop_first(self):
        # 运行中的服务点“删除”此前静默无反应：现在明确提示先停止再删。
        delete = self.services.split('ip.section == 4', 1)[1][:1200]
        self.assertIn('isManagedServiceIdentifier', delete)
        self.assertIn('请先停止服务', delete)
        self.assertIn('停止后才能删除', delete)

    def test_service_detail_auto_probes_health_on_appear_when_running(self):
        # 打开服务详情即自动检测一次接口健康，不再等用户手动点按；
        # 60 秒内已有成功响应时不再重复探测。
        appear = self.services.split('- (void)viewWillAppear:(BOOL)animated {', 1)[1].split('- (void)viewDidDisappear:', 1)[0]
        self.assertIn('probeIfStale', appear)
        stale = self.services.split('- (void)probeIfStale {', 1)[1].split('- (void)verifyPortReleasedAfterStop', 1)[0]
        self.assertIn('lastProbeResponseAt', stale)
        self.assertIn('[self probe]', stale)

    def test_service_stop_is_verified_against_the_local_port(self):
        # 停止只代表会话结束，不代表监听端口已释放：运行→已停止时
        # 后台确认一次端口状态，文案写清已释放/仍可访问/未知。
        self.assertIn('HostLocalPortState', self.services)
        self.assertIn('verifyPortReleasedAfterStop', self.services)
        self.assertIn('端口已释放', self.services)
        self.assertIn('端口仍可访问', self.services)
        self.assertIn('stopPortState', self.services)
        self.assertIn('HostLocalPortState', self.plugin_page)
        self.assertIn('verifyPortReleasedAfterStop', self.plugin_page)
        self.assertIn('stopPortState', self.plugin_page)

    def test_plugin_service_page_offers_restart(self):
        # YSP Live 服务页此前只有启动/停止，没有重启入口；现与服务详情
        # 复用同一 restartMediaService，失败弹框给明确原因并可看日志。
        self.assertIn('重启服务', self.plugin_page)
        self.assertIn('onRestart', self.plugin_page)
        self.assertIn('restarting', self.plugin_page)
        self.assertIn('showRestartError', self.plugin_page)
        self.assertIn('page.onRestart', self.root)
        self.assertIn('restartMediaService:current completion:completion', self.root)

    def test_service_search_matches_engine_protocol_and_port(self):
        # 排查端口冲突时常按端口或协议找服务：搜索只按名称搜不到。
        refresh = self.services.split('- (void)refresh {', 1)[1].split('- (void)updateSearchResultsForSearchController', 1)[0]
        self.assertIn('s[@"engine"]', refresh)
        self.assertIn('s[@"protocol"]', refresh)
        self.assertIn('s[@"port"]', refresh)
        self.assertIn('s[@"id"]', refresh)
        self.assertIn('搜索名称、端口或协议', self.services)

    def test_resource_header_counts_running_services(self):
        # 资源页头部此前只统计“已启用”，已启用 ≠ 运行中：现单独计运行中。
        header = self.catalog.split('titleForHeaderInSection', 1)[1].split('- (UITableViewCell *)tableView:', 1)[0]
        self.assertIn('运行中', header)
        self.assertIn('isRunningServiceIdentifier', header)
        self.assertIn('runningServices', header)

    def test_service_editor_warns_on_port_collision_before_saving(self):
        # 端口冲突此前只在启动时才报错：保存时先提示，点“仍要保存”才继续。
        self.assertIn('端口已被占用', self.editor)
        self.assertIn('仍要保存', self.editor)
        self.assertIn('applySaveForService', self.editor)
        self.assertIn('conflictingService', self.editor)

    def test_service_editor_allows_name_only_save_while_running(self):
        # 运行中的服务此前任何保存都被拒：只改名称且代码无未保存修改时
        # 直接保存名称，不用先停服务。
        save = self.editor.split('- (void)applySaveForService:', 1)[1].split('- (void)applyPortChange:', 1)[0]
        self.assertIn('只改了名称', save)
        self.assertIn('customCodeMatchesSavedVersion', save)
        self.assertIn('persistService', save)

    def test_service_detail_shows_current_run_start_time(self):
        # 服务详情此前没有本次启动时间：现从运行日志的最新记录取 startedAt。
        self.assertIn('本次启动时间', self.services)
        self.assertIn('runsForIdentifier', self.services)
        self.assertIn('currentRunStartedAt', self.services)
        self.assertIn('PluginLogStore', self.services)



    def test_resource_center_unicode_search_single_probe_and_diagnostic_summary(self):
        self.assertIn('- (BOOL)profile:(NSDictionary *)profile matchesSearchQuery:(NSString *)query', self.catalog)
        self.assertIn('[self resourceTitleForProfile:profile]', self.catalog)
        self.assertIn('[self resourceDetailForProfile:profile]', self.catalog)
        self.assertIn('- (void)probeSingleProfile:(NSString *)source', self.catalog)
        self.assertIn('- (void)copyResourceDiagnosticSummary', self.catalog)
        self.assertIn('@"单条测速连接"', self.catalog)
        self.assertIn('@"复制资源概览摘要"', self.catalog)
        self.assertIn('@"仅已启用资源"', self.catalog)

    def test_subscription_subpage_stack_form_paste_helpers_and_complete_management(self):
        sub_h = (ROOT / 'Sources/SubscriptionResourceViewController.h').read_text()
        sub_m = (ROOT / 'Sources/SubscriptionResourceViewController.m').read_text()
        for prop in ('onRecheckHealth', 'onRematchEPG', 'onDelete', 'reloadThemeAppearance'):
            self.assertIn(prop, sub_h)
            self.assertIn(prop, sub_m)
        self.assertIn('UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,field]]', sub_m)
        self.assertIn('- (void)pasteIntoField:(UIButton *)sender', sub_m)
        self.assertIn('- (void)confirmDeleteSubscription', sub_m)
        self.assertIn('@"复制订阅地址"', sub_m)
        self.assertIn('@"移除此订阅"', sub_m)
        self.assertIn('page.onRecheckHealth=', self.root)
        self.assertIn('page.onRematchEPG=', self.root)
        self.assertIn('page.onDelete=', self.root)

    def test_tvbox_catalog_subpage_filter_updates_empty_state_and_summary_header(self):
        tvbox_m = (ROOT / 'Sources/TVBoxCatalogViewController.m').read_text()
        self.assertIn('- (void)filterChanged {[self.tableView reloadData];[self updateEmptyState];}', tvbox_m)
        self.assertIn('- (void)updateCatalogSummary', tvbox_m)
        self.assertIn('tvbox.catalog.summary', tvbox_m)
        self.assertIn('@"打开或导入此站点"', tvbox_m)
        self.assertIn('@"复制合集源地址"', tvbox_m)

    def test_resource_subpages_support_live_theme_reload_and_practical_tools(self):
        for filename in (
            'ConfigCenterViewController.m',
            'SubscriptionResourceViewController.m',
            'TVBoxCatalogViewController.m',
            'PluginResourceDetailViewController.m',
            'ServicesViewController.m',
            'ServiceEditorViewController.m',
            'PluginViewController.m',
            'PluginRunHistoryViewController.m',
            'ResourceImportSheetViewController.m',
            'ResourceImportWorkflowViewController.m',
        ):
            src = (ROOT / 'Sources' / filename).read_text()
            self.assertIn('- (void)reloadThemeAppearance', src, f"{filename} missing reloadThemeAppearance")
        self.assertIn('- (void)assignAvailablePort', self.editor)
        self.assertIn('- (void)pasteURLIntoField', self.editor)
        self.assertIn('- (void)copyAllCode', self.editor)
        self.assertIn('- (void)pasteReplaceCode', self.editor)
        self.assertIn('- (void)pasteClipboardAddress', self.import_workflow)
        self.assertIn('- (void)clearAddressText', self.import_workflow)
        self.assertIn('- (void)toggleSelectAllCandidates', self.import_workflow)
        self.assertIn('page.onRestart=', self.root)



    def test_live_service_port_and_epg_port_recognition_across_resource_pages(self):
        m3u_parser = (ROOT / 'Sources/M3UParser.m').read_text()
        importer = (ROOT / 'Sources/MediaPackageImporter.m').read_text()
        self.assertIn('M3UNormalizedLoopbackURL', m3u_parser)
        self.assertIn('@"x-tvg-url",@"url-tvg",@"tvg-url",@"epg-url",@"tvg-epg"', m3u_parser)
        self.assertIn('+ (NSInteger)inferredPortInCode:(NSString *)source', self.service_store)
        self.assertIn('+ (NSString *)portRecognitionSummaryForService:(NSDictionary *)service', self.service_store)
        self.assertIn('+ (NSString *)inferredEPGPathInCode:(NSString *)source', self.service_store)
        self.assertIn('+ (NSString *)epgPathForService:(NSDictionary *)service', self.service_store)
        self.assertIn('+ (NSArray<NSString *> *)epgPathCandidatesForService:(NSDictionary *)service', self.service_store)
        self.assertIn('+ (NSString *)rewrittenLoopbackURL:(NSString *)urlString forService:(NSDictionary *)service', self.service_store)
        self.assertIn('inferredEPGPathInCode:entryText', importer)
        self.assertIn('inferredPortInCode:entryText', importer)
        self.assertIn('probeLocalEPGCandidatesForSubscription:', self.resource_detail)
        self.assertIn('[M3UParser epgURL:text baseURL:url]', self.resource_detail)
        self.assertIn('[M3UParser epgURL:text baseURL:probeURL]', self.services)
        self.assertIn('[ServiceStore portRecognitionSummaryForService:self.service]', self.services)
        self.assertIn('[ServiceStore rewrittenLoopbackURL:configured forService:service]', self.root)


    def test_maccms_collection_sites_chunked_response_category_merge_and_m3u8_priority(self):
        api_client = (ROOT / 'Sources/MediaAPIClient.m').read_text(encoding='utf-8')
        browser = (ROOT / 'Sources/MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('response.expectedContentLength>0&&response.expectedContentLength>(long long)limit', api_client)
        self.assertIn('MediaSanitizedJSONObjectWithData', api_client)
        self.assertIn('forHTTPHeaderField:@"User-Agent"', api_client)
        self.assertIn('listArgs[@"_maccms_ac"]=@"list"', api_client)
        self.assertIn('@[@"type_pid",@"pid",@"parent_id"]', api_client)
        self.assertIn('[flagName containsString:@"m3u8"]', api_client)
        self.assertIn('if(nativeLines.count&&webLines.count){[nativeLines addObjectsFromArray:webLines];lines=nativeLines;}', api_client)
        self.assertIn('@"catalog_single_site_auto"', browser)
        self.assertIn('@"切换采集站"', browser)



    def test_detail_reload_bypasses_cache_and_integrates_adaptation_monitor(self):
        browser_src = (ROOT / 'Sources/MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('@"media-detail-reload"', browser_src)
        self.assertIn('if(forceRefresh)args[@"refresh"]=@YES;', browser_src)
        self.assertIn('openAdaptationMonitor', browser_src)
        self.assertIn('MediaAdaptationMonitor.shared', browser_src)
        monitor_h = (ROOT / 'Sources/MediaAdaptationMonitor.h').read_text(encoding='utf-8')
        monitor_m = (ROOT / 'Sources/MediaAdaptationMonitor.m').read_text(encoding='utf-8')
        self.assertIn('MediaAdaptationMonitorViewController', monitor_h)
        self.assertIn('probeURLString:', monitor_m)
        self.assertIn('diagnosisAndRecommendationForRecord:', monitor_m)


if __name__ == '__main__':
    unittest.main()
