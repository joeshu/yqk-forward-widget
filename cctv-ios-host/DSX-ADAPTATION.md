# DSX enhanced attachment integration

The supplied Python Spider and drpy JavaScript rule are bundled as separate media resources. Existing installations seed the new entries on upgrade. JavaScript uses automatic protocol detection and JavaScriptCore, without forcing this drpy rule through the CommonJS Node host.

Changes:
- Provide drpy `$js.toString` and structured `request(..., {withHeaders:true})` responses, including HTTP status and headers.
- Enable `play_parse` so opaque `dsxplay:` tokens run through the rule resolver.
- Preserve verified HLS format hints on extensionless media URLs in both adapters.
- Accept the upstream drpy flat-header response shape in the JS media probe.

Validation on 2026-11-13:
- Online native navigation and home endpoints returned data (30 home videos).
- Python and JavaScript independently resolved video ID 1127416, including parser response and media-header verification.
- FFmpeg decoded two seconds of the selected audio/video successfully (exit 0).
- ffprobe identified H.264 1920x1080 video and AAC audio in the selected MP4.
- Fixture tests exercise the production Python Spider loader and generated JavaScript runtime, including opaque HLS, signed query parameters, Referer preservation and error-body rejection.
- iPhone device playback requires device acceptance; Linux network/media checks do not establish AVFoundation device behavior.
