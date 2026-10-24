import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS = (ROOT / "Sources/RuntimeDiagnostics.m").read_text()
SETTINGS = (ROOT / "Sources/SettingsViewController.m").read_text()
HOST = (ROOT / "Sources/RootViewController.m").read_text()
MEDIA = (ROOT / "Sources/MediaAPIClient.m").read_text()
PLAYBACK = (ROOT / "Sources/MediaPlaybackViewController.m").read_text()


class RuntimeDiagnosticsContractTests(unittest.TestCase):
    def test_mode_is_opt_in_and_persisted(self):
        self.assertIn('RuntimeDiagnosticsPreferenceKey = @"runtimeDiagnosticsEnabled"', DIAGNOSTICS)
        self.assertIn('_diagnosticModeEnabled = [NSUserDefaults.standardUserDefaults boolForKey:RuntimeDiagnosticsPreferenceKey]', DIAGNOSTICS)
        self.assertIn('@"default":@NO', SETTINGS)
        self.assertIn('[RuntimeDiagnostics.shared setEnabled:value]', HOST)

    def test_export_is_explicit_and_reports_empty_log(self):
        self.assertIn('@"exportRuntimeDiagnostics"', SETTINGS)
        self.assertIn('prepareExportWithCompletion:', DIAGNOSTICS)
        self.assertIn('暂无调试记录', DIAGNOSTICS)
        self.assertIn('page.onExportDebugLog=', HOST)

    def test_diagnostic_file_has_a_hard_size_limit(self):
        self.assertIn('RuntimeDiagnosticsMaximumBytes = 1024 * 1024', DIAGNOSTICS)
        self.assertIn('RuntimeDiagnosticsRetainedBytes = 768 * 1024', DIAGNOSTICS)
        self.assertIn('[self trimLogToTail]', DIAGNOSTICS)

    def test_sensitive_fields_and_urls_are_redacted(self):
        for sensitive in ('url', 'token', 'cookie', 'auth', 'password', 'signature', 'credential', 'query', 'body'):
            self.assertIn(f'@"{sensitive}"', DIAGNOSTICS)
        self.assertIn('URL redacted', DIAGNOSTICS)
        self.assertIn('path redacted', DIAGNOSTICS)

    def test_runtime_events_cover_playback_services_subscriptions_and_media_api(self):
        for event in (
            'channel_selected', 'playback_first_frame', 'playback_failed',
            'service_process_started', 'service_start_failed', 'service_stopped',
            'local_service_health_ready', 'local_service_health_failed',
            'subscription_refresh_succeeded', 'subscription_refresh_failed',
        ):
            self.assertIn(f'@"{event}"', HOST)
        self.assertIn('media_api_succeeded', MEDIA)
        self.assertIn('media_api_failed', MEDIA)
        self.assertIn('episode_resolve_failed', PLAYBACK)
        self.assertIn('player_waiting_to_play', PLAYBACK)
        self.assertIn('playback_first_frame_ready', PLAYBACK)
        self.assertIn('playback_video_frame_timeout', PLAYBACK)
        self.assertIn('playback_first_frame_ready', PLAYBACK)
        self.assertIn('elapsed_ms', MEDIA)

    def test_media_diagnostics_do_not_include_request_arguments(self):
        diagnostic_call = MEDIA.split('[RuntimeDiagnostics.shared recordEvent:', 1)[1].split('];', 1)[0]
        self.assertNotIn('arguments', diagnostic_call)
        self.assertNotIn('HTTPBody', diagnostic_call)


if __name__ == "__main__":
    unittest.main()
