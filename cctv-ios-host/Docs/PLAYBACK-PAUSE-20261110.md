# Playback pause behavior

VOD playback pauses when the application enters the background unless picture in picture is active. Embedded detail playback also pauses after its detail page disappears. Returning to the foreground or detail page does not automatically resume playback.

The Cicada first-frame watchdog and controller fallback share a bounded deadline derived from the configured network timeout. These changes do not repair the separately observed native HLS open_callback crash in the bundled vendor SDK.
