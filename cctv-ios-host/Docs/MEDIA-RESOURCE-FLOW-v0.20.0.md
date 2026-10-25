# Media and resource flow (0.20.0)

## User flow

- The Resources page accepts ordinary live lists, media scripts/packages, and TVBox JSON catalogs. The bottom tab previously labeled “影视” opens a configurable home; “影视库” opens a selected source.
- A TVBox catalog is a directory. Type 1/4 JSON API sites can be added as direct media sources; they use their original API URL, ext, headers, categories, search, detail and playback responses without starting a plugin runtime. Direct JS, MJS, CJS, Python, ZIP, or matching `.md5` script URLs continue through the existing media importer. Type 3/JAR sources remain visible with the reason they cannot run on iOS.
- A TVBox live-list URL is added through the existing subscription path. Importing a catalog never starts all of its sites or replaces an existing catalog without a choice.
- Film resources and sites have separate bottom-sheet selectors with search, a visible current-selection checkmark, and independent dismissal. Resource choices are filterable by the installed runtime and keep the complete source URL visible; the selected provider stays associated with its film resource and browse state.
- Selecting a film opens a themed detail page with the real poster and optional provider banner, available metadata, synopsis, persistent favorite action, route chips, and a three-column episode grid. Episodes are paged 12 at a time; selecting one resolves through the existing `play` API and carries its resource, provider, detail, line, and episode context into the player. Saved films are reachable from the film page's More menu and reopen against their current resource when it is enabled.
- The player reports AVPlayer's actual item/time-control state, allows line switching, and opens a matching route-chip and three-column episode selector for in-place changes. It waits for the selector transition to finish before presenting parser pages, and the latest episode parse wins. Browsing remains portrait; the playback page supports portrait and landscape, with controls beside the video in landscape.

## Compatibility and limits

- Existing media service protocols, local API routes, manifests, subscriptions, and service identifiers remain unchanged.
- TVBox catalog downloads are HTTP/HTTPS only, use an ephemeral session without cookies, reject redirects, and are bounded to 2 MiB. A catalog may contain up to 500 sites and 100 live entries; up to 50 catalogs are stored. Direct API responses are bounded to 2 MiB and use a 20-second request timeout.
- The direct adapter supports the TVBox type 1/4 JSON API contract only. It maps category/search/detail/play query parameters and normalizes standard `class`, `list`, `vod_play_from`, and `vod_play_url` fields. It does not execute JARs, call arbitrary class names, or claim compatibility with every TVBox fork.
- Reading an M3U address means the subscription parser accepted its channel list. It does not prove that each stream can be decoded. Likewise, a playable API response is not a device playback verification.

## Verification

The simulator smoke fixture exercises resource and platform sheets, the inline film detail/episode layout, playback episode selection, and the dedicated player. It verifies that an older slow episode response cannot replace the latest selection, and checks TVBox URL preservation, type 1/4 direct API classification, type 3/JAR rejection, and the separate live-list section.
