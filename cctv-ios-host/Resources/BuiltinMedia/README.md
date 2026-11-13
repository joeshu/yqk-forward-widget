# Bundled media resources

These files are registered locally as grouped resource catalogs on first launch. TVBox sites and live playlists stay under one parent resource and are loaded only after the user picks an entry. The JavaScript widget is statically inspected and copied into the imported-resource store; registration never executes it.

`lytvs-ios.json` contains the iOS subscription's 324 internal entries, including 223 Python Spider endpoints and 40 live lists. Its subscription credential is replaced with `__LYTVS_SUBSCRIPTION_TOKEN__` in this public repository. The app asks for the token only when a protected site is first selected and keeps it in this device's Keychain; individual Python scripts are downloaded and checked on demand.

`hongguo-python.py` and `hongguo-node.js` are the standalone Red Fruit short-drama sources. The app imports them as two separate local resources on first launch; both keep the 120-second playback-resolution budget, and neither executes during registration. They are maintained byte-for-byte with `Examples/hgtv-python/hgtv_public_1_0_5.py` and `Examples/hgtv-node/hgtv.js`.

`for-adm.json` registers joeshu's For-ADM CCTVHost collection as one catalog row. Its eight JS sites remain remote and are fetched only when selected; the app recognizes their CatVod-compatible `home/category/search/detail/play` exports and passes returned media URLs and headers to the native player.

`dsx-python.py` and `dsx-drpy.js` adapt the supplied DSX enhanced scripts as two local resources. The drpy bridge supports `$js.toString` and structured `withHeaders` responses; the JS rule explicitly enables playback parsing. Both sources preserve verified HLS format hints for extensionless URLs. Upgrades seed the new resources and refresh bundled code.
