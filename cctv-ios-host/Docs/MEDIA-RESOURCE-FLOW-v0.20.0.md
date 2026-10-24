# Media and resource flow (0.20.0)

## User flow

- The Resources page accepts ordinary live lists, media scripts/packages, and TVBox JSON catalogs.
- A TVBox catalog is a directory. Its site scripts and live-list URLs remain separate entries. A direct JS, MJS, CJS, Python, ZIP, or matching `.md5` script URL can be handed to the existing media importer; unsupported API/JAR sites stay visible with their source URL and reason. The TVBox `ext` value is passed as the imported manifest's `options` value.
- A TVBox live-list URL is added through the existing subscription path. Importing a catalog never starts all of its sites or replaces an existing catalog without a choice.
- Film resources and sites have separate bottom-sheet selectors with search, a visible current-selection checkmark, and independent dismissal. Resource choices are filterable by the installed runtime and keep the complete source URL visible; the selected provider stays associated with its film resource and browse state.
- Selecting a film opens a synopsis/details page. Its line and episode count leads to a dedicated episode page grouped by playback line. Resolving a selected episode carries its resource, provider, detail, line, and episode context into the player.
- The player reports AVPlayer's actual item/time-control state, allows line switching, and opens the same episode selector for in-place episode changes. It waits for the selector transition to finish before presenting parser pages, and the latest episode parse wins. Browsing remains portrait; the playback page supports portrait and landscape, with controls beside the video in landscape.

## Compatibility and limits

- Existing media service protocols, local API routes, manifests, subscriptions, and service identifiers remain unchanged.
- TVBox catalog downloads are HTTP/HTTPS only, use an ephemeral session without cookies, reject redirects, and are bounded to 2 MiB. A catalog may contain up to 500 sites and 100 live entries; up to 50 catalogs are stored.
- The app does not translate arbitrary TVBox API endpoints, JAR plugins, or remote server protocols into a supported Spider. Those entries are retained for inspection and marked unavailable.
- Reading an M3U address means the subscription parser accepted its channel list. It does not prove that each stream can be decoded. Likewise, a playable API response is not a device playback verification.

## Verification

The simulator smoke fixture exercises resource and platform sheets, separate details, episode, and playback pages, verifies that an older slow episode response cannot replace the latest selection, and checks TVBox URL preservation, unsupported-site labeling, and the separate live-list section.
