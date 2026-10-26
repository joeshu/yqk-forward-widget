import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS = (ROOT / "Sources/RuntimeDiagnostics.m").read_text()
SETTINGS = (ROOT / "Sources/SettingsViewController.m").read_text()
HOST = (ROOT / "Sources/RootViewController.m").read_text()
MEDIA = (ROOT / "Sources/MediaAPIClient.m").read_text()
PLAYBACK = (ROOT / "Sources/MediaPlaybackViewController.m").read_text()
READINESS = (ROOT / "Sources/LocalServiceReadiness.m").read_text()
BROWSER = (ROOT / "Sources/MediaBrowserViewController.m").read_text()
PYHOST = (ROOT / "Sources/PyHost.m").read_text()
APP_DELEGATE = (ROOT / "Sources/AppDelegate.m").read_text()


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
        self.assertIn('#import "HostLogRedactor.h"', DIAGNOSTICS)

    def test_events_are_identifiable_and_joinable(self):
        self.assertIn('record[@"session_id"] = self.sessionID', DIAGNOSTICS)
        self.assertIn('record[@"event_id"] = NSUUID.UUID.UUIDString.lowercaseString', DIAGNOSTICS)
        self.assertIn('@"correlation_id"', HOST)
        self.assertIn('correlationID:self.diagnosticTraceID', BROWSER)
        self.assertIn('correlationID:self.diagnosticTraceID', PLAYBACK)

    def test_lifecycle_diagnostics_capture_unclean_exit_without_claiming_crash_cause(self):
        for event in (
            'previous_session_unclosed', 'app_started', 'app_will_resign_active',
            'entered_background', 'entered_foreground', 'app_became_active',
            'memory_warning_received', 'app_will_terminate',
        ):
            self.assertIn(f'@"{event}"', DIAGNOSTICS + APP_DELEGATE)
        self.assertIn('runtime-session.json', DIAGNOSTICS)
        self.assertIn('last_checkpoint_at', DIAGNOSTICS)
        self.assertIn('termination_reason', DIAGNOSTICS)
        self.assertIn('@"unknown"', DIAGNOSTICS)
        self.assertIn('session_marker_saved', DIAGNOSTICS)
        self.assertIn('beginAppSessionWithFields:', APP_DELEGATE)
        self.assertIn('applicationDidReceiveMemoryWarning:', APP_DELEGATE)

    def test_media_api_records_failure_stage_and_safe_playable_result_shape(self):
        for field in (
            'request_id', 'argument_count', 'failure_stage', 'http_status',
            'response_bytes', 'plugin_error_code', 'plugin_error_message',
            'result_has_media_url', 'result_parse_mode', 'result_alternate_count',
            'playback_host', 'playback_extension',
        ):
            self.assertIn(f'@"{field}"', MEDIA)
        for field in ('X-CCTVHost-Request-ID', 'X-CCTVHost-Correlation-ID',
                      'service_request_id', 'service_failure_stage'):
            self.assertIn(field, MEDIA)
        for stage in (
            'network_or_timeout', 'response_too_large', 'empty_response',
            'invalid_json', 'http_status', 'plugin_error', 'invalid_response_shape',
        ):
            self.assertIn(f'@"{stage}"', MEDIA)
        self.assertNotIn('startFields[@"arguments"]', MEDIA)
        self.assertNotIn('fields[@"url"]', MEDIA)

    def test_readiness_diagnostics_identify_probe_attempt_and_last_response(self):
        for field in (
            'probe_id', 'probe_attempts', 'last_http_status', 'last_response_bytes',
            'last_content_type', 'last_error_domain', 'last_error_code',
            'last_failure_kind', 'requires_health_json',
        ):
            self.assertIn(f'@"{field}"', READINESS)
        for failure in (
            'process_failed', 'probe_timeout', 'network_error', 'http_status',
            'invalid_health_response',
        ):
            self.assertIn(f'@"{failure}"', READINESS)

    def test_python_node_and_javascriptcore_sessions_emit_runtime_outcomes(self):
        for event in (
            'python_script_entry_started', 'python_runtime_failed',
            'python_runtime_background_work_active', 'python_runtime_stopped',
            'python_runtime_exited_unexpectedly', 'plugin_bridge_started',
            'plugin_bridge_succeeded', 'plugin_bridge_failed',
        ):
            self.assertIn(f'@"{event}"', PYHOST)
        self.assertIn('@"javascriptcore"', PYHOST)
        self.assertIn('@"node"', PYHOST)
        for field in ('service_id', 'operation', 'request_id', 'elapsed_ms', 'failure_stage'):
            self.assertIn(f'@"{field}"', PYHOST)

    def test_python_crash_breadcrumbs_are_durable_and_recovered_per_script(self):
        for token in (
            'recordEventSynchronously:', 'python-active-sessions',
            'python_runtime_breadcrumb', 'python_session_interrupted',
            'process_phys_footprint_bytes', 'script_name', 'last_runtime_stage',
            'PluginLogStore.shared appendLine:',
        ):
            self.assertIn(token, PYHOST)
        self.assertIn('recoverInterruptedPythonSessions', PYHOST)
        self.assertIn('[PyHost recoverInterruptedPythonSessions]', HOST)

    def test_unhandled_python_worker_failures_have_service_and_line_context(self):
        runtime = (ROOT / 'Scripts/host_service_runtime.py').read_text()
        for token in (
            'threading.excepthook = _thread_excepthook',
            '_cctvhost_python_exception', 'thread_name', 'source_file',
            'line_number', 'python_background_thread_exception',
        ):
            self.assertIn(token, runtime + PYHOST)

    def test_python_network_reads_are_bounded_and_explain_rejections(self):
        runtime = (ROOT / 'Scripts/host_service_runtime.py').read_text()
        for token in (
            '_max_http_response_bytes = 16 * 1024 * 1024',
            '_http_workers_per_service = 4',
            '_global_http_workers = threading.BoundedSemaphore(12)',
            '_global_response_reads = threading.BoundedSemaphore(8)',
            'http.client.HTTPResponse.read = _bounded_http_response_read',
            'owner.http_worker_slots',
            '_cctvhost_python_resource_limit', 'python_http_response_rejected',
            '_cctvhost_python_http_worker_rejected', 'python_http_worker_rejected',
        ):
            self.assertIn(token, runtime + PYHOST)

    def test_subscription_diagnostics_classify_parse_and_transport_failures(self):
        for event in (
            'subscription_refresh_started', 'subscription_refresh_failed',
            'subscription_refresh_succeeded', 'subscription_text_parse_started',
        ):
            self.assertIn(f'@"{event}"', HOST)
        for field in (
            'correlation_id', 'http_status', 'response_mime_type', 'received_bytes',
            'failure_stage', 'source_route_fingerprint', 'input_bytes',
        ):
            self.assertIn(f'@"{field}"', HOST)
        for stage in (
            'network_or_timeout', 'http_status', 'response_too_large',
            'empty_response', 'no_valid_channels', 'invalid_utf8', 'empty_input',
        ):
            self.assertIn(f'@"{stage}"', HOST)

    def test_runtime_events_cover_playback_services_subscriptions_and_media_api(self):
        for event in (
            'channel_selected', 'playback_first_frame', 'playback_failed',
            'service_start_accepted', 'service_start_failed', 'service_stopped',
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

    def test_nontransient_url_errors_skip_same_url_playback_retry(self):
        self.assertIn('CCTVRemotePlaybackErrorCanRetrySameURL(error)', HOST)
        for code in ('NSURLErrorBadURL', 'NSURLErrorFileDoesNotExist',
                     'NSURLErrorFileIsDirectory', 'NSURLErrorNoPermissionsToReadFile',
                     'NSURLErrorCannotDecodeContentData'):
            self.assertIn(code, HOST)
        self.assertIn('recovery_action', HOST)

    def test_media_diagnostics_do_not_include_request_arguments(self):
        diagnostic_call = MEDIA.split('[RuntimeDiagnostics.shared recordEvent:', 1)[1].split('];', 1)[0]
        self.assertNotIn('arguments', diagnostic_call)
        self.assertNotIn('HTTPBody', diagnostic_call)

    def test_playback_diagnostics_classify_signed_endpoint_without_logging_values(self):
        for field in ('playback_parameter_count', 'playback_parameter_names',
                      'playback_has_signed_parameter', 'network_error_status_code'):
            self.assertIn(f'@"{field}"', PLAYBACK)
        self.assertIn('NSURLQueryItem *item', PLAYBACK)
        self.assertIn('self.observedItem.errorLog.events.lastObject', PLAYBACK)
        self.assertNotIn('fields[@"source_url"]', PLAYBACK)


if __name__ == "__main__":
    unittest.main()
