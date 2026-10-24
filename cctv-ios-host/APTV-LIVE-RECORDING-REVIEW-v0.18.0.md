# APTV CCTV / Live Recording Review

Reviewed the 10.9-second screen recording supplied on 2026-10-24. It shows a channel player page and its EPG diagnostics and source sheets. The captured player stays at 0% with no visible decoded frame, so the recording is useful for interface review but does not establish successful playback.

## Reference items and CCTVHost support

| Recording item | CCTVHost state |
| --- | --- |
| Favorite, player information, and AirPlay controls | Favorite and playback information already existed. The AirPlay-looking control previously opened the stream-route chooser; it now opens Apple's AVRoutePickerView. |
| Category, channel, program, and route sections under the player | Added four player sections. Category selection reuses the current catalog filters; channel selection keeps the existing list/grid; program uses the existing EPG page; route lists the current source and safe alternatives. |
| EPG date strip and live/played/upcoming states | Already implemented and retained. |
| EPG diagnostic sheet with tvg-id, tvg-name, match method, date, and source | Expanded the source sheet. M3U tvg-name is now retained and used after tvg-id when resolving EPG. Source credentials are hidden, while URL query parameters remain visible as requested. |
| Source rows with provider, resolution, and URL | Added to the route section. URL credentials are omitted; query parameters are displayed. Rows describe configured sources only; no synchronous reachability probe or unverified availability claim is made. |
| Channel logo in the player | Added when the channel provides a logo URL. It reuses the bounded image cache and loads only after first frame to avoid competing with startup traffic. |
| Player engine and first-frame diagnostics | Playback information now identifies AVPlayer, CicadaPlayer, the current native player class, or the waiting state. First-frame timing remains based on the player callback. |

The recording's light appearance and APTV branding were not copied. The player stays within CCTVHost's existing dark visual style. A synthetic percentage indicator was not added because the captured 0% state and CCTVHost's SDK callbacks do not provide a reliable playback percentage.

## Verification

- Python test suite: 132 passed, 24 skipped because those tests require macOS frameworks.
- JSPlugins npm test: both suites passed.
- Node syntax check and git diff check: passed after the query-display adjustment.
- iOS build, native JavaScriptCore tests, AirPlay sheet interaction, and device playback remain unverified here because this environment is Linux and has no Xcode or Apple SDK.
