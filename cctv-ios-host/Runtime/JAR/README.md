# Embedded JAR dependency

Source: https://github.com/jo32/tvbox-silicon/tree/47e563274414c61123db3e8603b7d97ea29f5cee

The exact revision and archive SHA-256 are in `upstream.json`. Build with
`Scripts/prepare_jar_runtime.sh ios` or `ios-simulator` on an Apple silicon Mac.
The script uses the upstream Java host, static OpenJDK Zero build, patches and
interpreter-only native bindings. Generated runtimes stay outside Git.

`COPYING` contains the upstream GPL-3.0-only license; `RuntimeLicenses` preserves
the other linked components' notices. `UPSTREAM-NOTICES.md` is the unmodified
upstream dependency record (its relative links refer to that upstream revision).
These notices and the source pin are included in the app's resources. Source
plugins and subscription credentials are downloaded only at the user's request;
none are bundled with this runtime.

See `Docs/JAR-RUNTIME-20261110.md` for the app boundary, verification and limitations.
