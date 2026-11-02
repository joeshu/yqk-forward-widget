# Bundled media resources

These files are registered locally as grouped resource catalogs on first launch. TVBox sites and live playlists stay under one parent resource and are loaded only after the user picks an entry. The JavaScript widget is statically inspected and copied into the imported-resource store; registration never executes it.

`lytvs-ios.json` contains the iOS subscription's 324 internal entries, including 223 Python Spider endpoints and 40 live lists. Its subscription credential is replaced with `__LYTVS_SUBSCRIPTION_TOKEN__` in this public repository. The app asks for the token only when a protected site is first selected and keeps it in this device's Keychain; individual Python scripts are downloaded and checked on demand.

The `haoliang-live.json`, `haoliang-py.json`, and `haoliang-tvbox.json` files are the separate owner-supplied aggregates. `zen-keke-stream.js` is the imported JavaScript source.
