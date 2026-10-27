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
IMAGE_LOADER = (ROOT / "Sources/HostImageLoader.m").read_text()
M3U = (ROOT / "Sources/M3UParser.m").read_text()
PLAYBACK_HEADERS = (ROOT / "Sources/MediaPlaybackHeaders.m").read_text()


class RuntimeDiagnosticsContractTests(unittest.TestCase):
    def test_mode_is_opt_in_and_persisted(self):
        self.assertIn('RuntimeDiagnosticsPreferenceKey = @"runtimeDiagnosticsEnabled"', DIAGNOSTICS)
        self.assertIn('_diagnosticModeEnabled = [NSUserDefaults.standardUserDefaults boolForKey:RuntimeDiagnosticsPreferenceKey]', DIAGNOSTICS)
        self.assertIn('@"default":@NO', SETTINGS)
        self.assertIn('[RuntimeDiagnostics.shared setEnabled:value]', HOST)

    def test_diagnostics_are_browsed_and_exported_per_app_session(self):
        self.assertIn('@"runtimeDiagnostics"', SETTINGS)
        self.assertIn('loadSessionsWithCompletion:', DIAGNOSTICS)
        self.assertIn('loadEventsForSessionID:', DIAGNOSTICS)
        self.assertIn('prepareExportForSessionID:', DIAGNOSTICS)
        self.assertIn('initWithSessionID:nil', HOST)
        self.assertIn('暂无运行记录', (ROOT / "Sources/RuntimeDiagnosticsViewController.m").read_text())

    def test_diagnostic_records_can_be_deleted_individually_or_cleared(self):
        self.assertIn('deleteSessionID:', DIAGNOSTICS)
        self.assertIn('clearAllSessionsWithCompletion:', DIAGNOSTICS)
        page = (ROOT / "Sources/RuntimeDiagnosticsViewController.m").read_text()
        self.assertIn('confirmClearAll', page)
        self.assertIn('confirmDeleteCurrentSession', page)

    def test_current_run_has_its_own_file_and_legacy_log_is_split_by_session(self):
        self.assertIn('self.logPath = [self pathForSessionID:self.sessionID]', DIAGNOSTICS)
        self.assertIn('sessionsDirectoryPath', DIAGNOSTICS)
        self.assertIn('migrateLegacyLogIfNeeded', DIAGNOSTICS)
        self.assertIn('object[@"session_id"]', DIAGNOSTICS)
        self.assertIn('Remove the old aggregate only after all per-session files were written', DIAGNOSTICS)
        self.assertIn('RuntimeDiagnosticsMaximumSessions = 24', DIAGNOSTICS)
        self.assertIn('RuntimeDiagnosticsMaximumTotalBytes = 32 * 1024 * 1024', DIAGNOSTICS)

    def test_diagnostic_file_has_a_hard_size_limit(self):
        self.assertIn('RuntimeDiagnosticsMaximumBytes = 4 * 1024 * 1024', DIAGNOSTICS)
        self.assertIn('RuntimeDiagnosticsRetainedBytes = 3 * 1024 * 1024', DIAGNOSTICS)
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
            'memory_warning_received', 'app_will_terminate', 'app_session_closed',
        ):
            self.assertIn(f'@"{event}"', DIAGNOSTICS + APP_DELEGATE)
        self.assertIn('runtime-session.json', DIAGNOSTICS)
        self.assertIn('last_checkpoint_at', DIAGNOSTICS)
        self.assertIn('termination_reason', DIAGNOSTICS)
        self.assertIn('process_phys_footprint_bytes', DIAGNOSTICS)
        self.assertIn('process_phys_footprint_sample_checkpoint', DIAGNOSTICS)
        self.assertIn('process_phys_footprint_bytes', APP_DELEGATE)
        self.assertIn('@"unknown"', DIAGNOSTICS)
        self.assertIn('session_marker_saved', DIAGNOSTICS)
        self.assertIn('session_marker_closed', DIAGNOSTICS)
        self.assertIn('beginAppSessionWithFields:', APP_DELEGATE)
        self.assertIn('applicationDidReceiveMemoryWarning:', APP_DELEGATE)

    def test_no_ips_fallback_captures_objc_exceptions_metrickit_and_media_render_stages(self):
        for marker in (
            'NSSetUncaughtExceptionHandler', 'uncaught_objc_exception',
            'MXMetricManager', 'didReceiveDiagnosticPayloads:',
            'metrickit_crash_diagnostic_received', 'related_session_id',
            'JSONRepresentation', 'call_stack_frame_summaries',
            'offsetIntoBinaryTextSegment',
        ):
            self.assertIn(marker, DIAGNOSTICS)
        self.assertIn('last_checkpoint_context', DIAGNOSTICS)
        for marker in (
            'media_home_data_apply_started', 'media_home_data_apply_completed',
            'media_home_modules_rebuild_started', 'media_home_modules_rebuild_completed',
            'media_grid_cell_configuration_started', 'media_grid_cell_configuration_completed',
            'media_grid_first_cell_will_display',
        ):
            self.assertIn(marker, BROWSER)
        self.assertIn('MetricKit.framework', (ROOT / 'project.yml').read_text())

    def test_unclosed_session_preserves_only_the_active_playback_breadcrumb(self):
        for field in (
            'active_playback_attempt_id', 'active_playback_service_id',
            'active_playback_source_host', 'active_playback_outcome',
            'last_playback_attempt_id', 'last_playback_outcome',
            'last_playback_failure_kind', 'last_playback_http_status',
        ):
            self.assertIn(f'@"{field}"', DIAGNOSTICS)
        self.assertIn('@"active_playback_outcome":@"in_progress"', PLAYBACK)
        self.assertIn('terminal?@"":self.playbackAttemptID', PLAYBACK)
        self.assertIn('terminal?@"":outcome', PLAYBACK)
        self.assertIn('terminal?@"playback_attempt_finished":@"playback_attempt_progressed"', PLAYBACK)
        self.assertIn('@"playback_screen_closed"', PLAYBACK)
        self.assertIn('@"completed" failureKind:nil httpStatus:0 terminal:YES', PLAYBACK)
        self.assertIn('@"first_frame_ready" failureKind:nil httpStatus:0 terminal:NO', PLAYBACK)
        self.assertIn('@"webview_handoff" failureKind:nil httpStatus:0 terminal:NO', PLAYBACK)
        self.assertIn('@"webview_returned" failureKind:nil httpStatus:0 terminal:YES', PLAYBACK)
        self.assertIn('@"first_frame_timeout" failureKind:@"first_frame_timeout" httpStatus:0 terminal:NO', PLAYBACK)

    def test_process_footprint_is_omitted_when_diagnostics_or_task_info_is_unavailable(self):
        self.assertIn('fields[@"process_phys_footprint_bytes"] = @(memoryInfo.phys_footprint)', APP_DELEGATE)
        self.assertNotIn('@"process_phys_footprint_bytes":physicalFootprint', APP_DELEGATE)
        self.assertIn('checkpointFields[@"process_phys_footprint_bytes"] = @(memoryInfo.phys_footprint)', DIAGNOSTICS)
        self.assertIn('[marker removeObjectForKey:@"process_phys_footprint_bytes"]', DIAGNOSTICS)

    def test_lifecycle_labels_system_uptime_accurately_and_migrates_legacy_field(self):
        self.assertIn('@"system_uptime_seconds":@(NSProcessInfo.processInfo.systemUptime)', APP_DELEGATE)
        self.assertNotIn('@"process_uptime_seconds":@(NSProcessInfo.processInfo.systemUptime)', APP_DELEGATE)
        self.assertIn('Older builds mislabeled NSProcessInfo.systemUptime', DIAGNOSTICS)

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
            'PluginLogStore.shared appendLine:', '_cctvhost_python_stage',
            'python_runner_entered', 'python_plugin_script_loading',
            'media_service_listener_bound', 'media_engine_prepare_started',
            'media_server_loop_started', 'spider_module_import_started',
            'spider_init_started', 'spider_ready',
        ):
            self.assertIn(token, PYHOST)
        runtime = (ROOT / 'Scripts/host_service_runtime.py').read_text()
        media_service = (ROOT / 'Plugins/media-service.py').read_text()
        media_runtime = (ROOT / 'Plugins/host_media_runtime.py').read_text()
        self.assertIn('report_runtime_stage(\'python_runner_entered\')', runtime)
        self.assertIn('report_runtime_stage(\'python_plugin_script_loading\')', runtime)
        for phase in ('media_service_listener_bound', 'media_engine_prepare_started',
                      'media_server_loop_started'):
            self.assertIn(phase, media_service)
        for phase in ('spider_module_import_started', 'spider_module_loaded',
                      'spider_constructor_started', 'spider_init_started', 'spider_ready'):
            self.assertIn(phase, media_runtime)
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
        self.assertIn('item.errorLog.events.lastObject', PLAYBACK)
        self.assertIn('recordPlaybackFailureForItem:', PLAYBACK)
        self.assertIn('playback_attempt_id', PLAYBACK)
        self.assertIn('playback_attempt_started', DIAGNOSTICS + PLAYBACK)
        self.assertNotIn('fields[@"source_url"]', PLAYBACK)

    def test_media_address_presence_boolean_survives_secret_redaction(self):
        self.assertIn('lower isEqualToString:@"result_has_media_url"', DIAGNOSTICS)

    def test_remote_playback_preserves_playlist_headers_and_logs_only_safe_metadata(self):
        for token in ('#EXTVLCOPT:', '#EXTHTTP:', 'http-user-agent', 'http-referrer', 'http-cookie'):
            self.assertIn(token, M3U)
        self.assertIn('entry[@"headers"] = c.headers', HOST)
        self.assertIn('self.currentRemoteHeaders', HOST)
        self.assertIn('@"AVURLAssetHTTPHeaderFieldsKey":headers', HOST)
        for field in ('request_header_count', 'request_user_agent_present',
                      'request_referrer_present', 'request_origin_present',
                      'request_auth_material_present'):
            self.assertIn(f'@"{field}"', PLAYBACK_HEADERS)
            self.assertIn(f'@"{field}"', DIAGNOSTICS)
        self.assertIn('network_error_status_code', HOST)
        self.assertIn('network.errorStatusCode)', HOST)
        self.assertNotIn('MAX(0, network.errorStatusCode)', HOST)
        self.assertIn('underlying_error_chain', HOST)
        self.assertIn('numberOfBytesTransferred', HOST)
        self.assertIn('[value isKindOfClass:NSNumber.class]) return value;', DIAGNOSTICS)
        self.assertIn('[pendingHeaders removeAllObjects];', M3U)

    def test_media_browser_diagnostics_cover_detail_route_episode_cache_and_stale_responses(self):
        for event in (
            'media_detail_request_started', 'media_detail_readable', 'media_detail_failed',
            'media_detail_response_discarded', 'media_detail_no_episodes',
            'media_route_selected', 'media_episode_selected', 'episode_resolve_requested',
            'episode_resolve_succeeded', 'episode_resolve_failed',
            'episode_resolve_response_discarded', 'media_listing_request_started',
            'media_listing_result_applied', 'media_listing_failed',
            'media_listing_response_discarded', 'media_home_shelf_cache_decision',
            'media_home_shelf_response_discarded',
        ):
            self.assertIn(f'@"{event}"', BROWSER)
        for field in ('line_count', 'episode_count', 'result_has_media_url',
                      'result_parse_mode', 'result_alternate_count', 'cache_hit',
                      'cache_stale', 'cached_item_count', 'search_term_length',
                      'request_generation', 'elapsed_ms'):
            self.assertIn(f'@"{field}"', BROWSER)
        self.assertIn('@"search_term_length":@(requestedKeyword.length)', BROWSER)
        self.assertNotIn('@"keyword":requestedKeyword', BROWSER)

    def test_player_diagnostics_capture_transport_and_recovery_without_media_urls(self):
        for field in (
            'media_requests', 'media_bytes_transferred', 'media_stall_count',
            'media_dropped_video_frames', 'media_transfer_duration_seconds',
            'media_observed_bitrate_bps', 'media_indicated_bitrate_bps',
            'media_reported_startup_seconds', 'video_presentation_width',
            'video_presentation_height',
        ):
            self.assertIn(f'@"{field}"', PLAYBACK)
        for event in (
            'playback_retry_requested', 'playback_line_selected',
            'playback_stall_recovery_started', 'playback_stall_recovery_skipped',
            'episode_resolve_unavailable', 'episode_resolve_response_discarded',
        ):
            self.assertIn(f'@"{event}"', PLAYBACK)
        self.assertIn('MediaPlaybackAddAccessLogFields(fields,item)', PLAYBACK)
        self.assertIn('MediaPlaybackAddAccessLogFields(fields,self.observedItem)', PLAYBACK)
        self.assertNotIn('fields[@"media_url"]', PLAYBACK)
        self.assertNotIn('fields[@"source_url"]', PLAYBACK)

    def test_poster_failures_are_classified_without_logging_image_addresses(self):
        self.assertIn('recordEvent:@"poster_image_failed"', IMAGE_LOADER)
        for stage in ('http_status', 'response_too_large', 'network_error',
                      'image_decode_failed', 'empty_body'):
            self.assertIn(f'@"{stage}"', IMAGE_LOADER)
        for field in ('image_host', 'image_extension', 'http_status',
                      'content_type', 'response_bytes', 'elapsed_ms',
                      'expected_content_length_known', 'expected_response_bytes',
                      'response_length_matches_expected', 'error_domain', 'error_code'):
            self.assertIn(f'@"{field}"', IMAGE_LOADER)
        self.assertNotIn('@"image_url"', IMAGE_LOADER)
        self.assertNotIn('@"source_url"', IMAGE_LOADER)


if __name__ == "__main__":
    unittest.main()
