from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CCTVHostQualityFollowupContracts(unittest.TestCase):
    def test_channel_badges_only_report_bounded_measured_samples(self):
        root = (ROOT / 'Sources/RootViewController.m').read_text()
        probe = (ROOT / 'Sources/MediaChannelProbe.m').read_text()
        self.assertNotIn('860.0', root)
        self.assertNotIn('FNV', root)
        self.assertIn('MediaChannelProbeByteLimit = 4096', probe)
        self.assertIn('configuration.timeoutIntervalForResource=3.5', probe)
        self.assertIn('configuration.HTTPCookieStorage=nil', probe)
        self.assertIn('sampleBytes', root)
        self.assertIn('首帧 %.1f 秒', root)

    def test_page_sniffer_bounds_body_time_redirects_and_header_scope(self):
        fetch = (ROOT / 'Sources/MediaPlaybackSniffFetch.m').read_text()
        playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        self.assertIn('MediaPlaybackSniffMaximumBytes=2*1024*1024', fetch)
        self.assertIn('configuration.timeoutIntervalForResource=8.0', fetch)
        self.assertIn('self.redirectCount>5', fetch)
        self.assertIn('MediaPlaybackHeadersScopedToURL', fetch)
        self.assertIn('startWithRequest:req completion:', playback)

    def test_webdav_xml_parser_rejects_doctypes_at_every_encoding(self):
        source = (ROOT / 'Plugins/host_media_servers.py').read_text()
        requirements = (ROOT / 'Scripts/media-python-requirements.txt').read_text()
        validator = (ROOT / 'Scripts/validate_ipa.py').read_text()
        tests = (ROOT / 'Tests/test_media_servers.py').read_text()
        self.assertIn('from defusedxml import ElementTree as ET', source)
        self.assertIn('forbid_dtd=True, forbid_entities=True, forbid_external=True', source)
        self.assertIn('defusedxml==0.7.1', requirements)
        self.assertIn("'defusedxml'", validator)
        self.assertIn('utf16le', tests)
        self.assertIn('utf16be', tests)

    def test_user_stop_finishes_current_copy_then_stops_queue(self):
        store = (ROOT / 'Sources/LocalMediaStore.m').read_text()
        controller = (ROOT / 'Sources/LocalMediaViewController.m').read_text()
        stop = store.split('- (void)stopAfterCurrentFile', 1)[1].split('\n- (void)', 1)[0]
        self.assertIn('@synchronized(self)', stop)
        self.assertNotIn('dispatch_async(self.queue', stop)
        self.assertIn('if([self stopWasRequested])break;', store)
        self.assertIn('moveItemAtURL:staging toURL:target', store)
        self.assertIn('已停止后续导入', controller)

    def test_hls_refresh_and_cicada_resume_keep_user_intent(self):
        relay = (ROOT / 'Plugins/host_media_relay.py').read_text()
        transport_test = (ROOT / 'Tests/test_relay_transport_regressions.py').read_text()
        playback = (ROOT / 'Sources/MediaPlaybackViewController.m').read_text()
        self.assertIn("url = ll_hls_upstream_url(url, getattr(handler, 'path', ''))", relay)
        self.assertIn("url=ll_hls_upstream_url(url,getattr(handler,'path',''))", relay)
        self.assertIn('test_ll_hls_delivery_directives_survive_forced_manifest_refresh', transport_test)
        self.assertIn('resumeActiveEngineIfWantedForGeneration', playback)
        self.assertIn('currentSession!=(id<PlaybackSession>)self', playback)

    def test_rejected_m3u_rows_clear_catchup_and_monitor_records_are_scrubbed(self):
        parser = (ROOT / 'Sources/M3UParser.m').read_text()
        monitor = (ROOT / 'Sources/MediaAdaptationMonitor.m').read_text()
        self.assertIn('if (!url) { pendingName = nil;', parser)
        self.assertIn('catchupMode=nil;catchupSource=nil;catchupDays=0;tvgShift=0;', parser)
        self.assertIn('CCTVMonitorSanitizedRecord(item)', monitor)
        self.assertIn('CCTVMonitorSanitizedRecord(enriched)', monitor)
        self.assertIn('else if([key isEqual:@"provider"]&&parts.host.length)safe[key]=parts.host.lowercaseString', monitor)

    def test_remote_toggle_and_large_type_tab_labels_stay_accessible(self):
        coordinator = (ROOT / 'Sources/PlaybackCoordinator.m').read_text()
        root = (ROOT / 'Sources/RootViewController.m').read_text()
        self.assertIn('togglePlayPauseCommand addTarget:self', coordinator)
        self.assertIn('MPRemoteCommandHandlerStatus)togglePlayPause', coordinator)
        self.assertIn('configuration.title=accessibilitySize?@"":titles[button.tag]', root)
        self.assertIn('b.accessibilityLabel=titles[i]', root)

    def test_ui_matrix_and_release_freshness_are_configured(self):
        workflow = (ROOT.parent / '.github/workflows/cctv-ios-host.yml').read_text()
        smoke = (ROOT / 'Scripts/ui-smoke.sh').read_text()
        driver = (ROOT / 'Tests/UISmoke/SmokeDriver.m').read_text()
        self.assertIn('iPhone SE (3rd generation)', workflow)
        self.assertIn('accessibility-xxxl', workflow)
        self.assertIn('Check that this build is still the latest main commit', workflow)
        self.assertIn('cancel-in-progress: true', workflow)
        self.assertIn('CCTV_UI_DEVICE_NAME', smoke)
        self.assertIn('--ui-content-size', driver)
        self.assertIn('media home screenshot uses the real root tab', driver)


if __name__ == '__main__':
    unittest.main()
