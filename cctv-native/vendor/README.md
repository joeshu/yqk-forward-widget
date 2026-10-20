# Browser storage dependency

`fake-indexeddb-6.2.6.js` contains the unchanged JavaScript files from `fake-indexeddb@6.2.6/build/cjs`, keyed by their relative paths, plus a small local CommonJS module loader. Its purpose is IndexedDB semantics within JavaScriptCore, not media or source resolution. No Node process is required on the device.

Upstream: https://github.com/dumbmatter/fakeIndexedDB/tree/v6.2.6

Copyright 2017 Jeremy Scheff. Apache License 2.0 is retained in the bundle header and `fake-indexeddb-LICENSE`. The generated single Python file embeds the complete license separately in `THIRD_PARTY_LICENSE` as well.

To reproduce the dependency collection, install the exact package in a development-only directory with `npm install --ignore-scripts --save-exact fake-indexeddb@6.2.6`. Enumerate its `build/cjs/**/*.js` in sorted relative-path order, storing each original file as a JSON string in `__sources`; preserve the wrapper loader. `build_aptv.py` embeds this committed bundle, so normal builds and all device runs require no npm/network package installation. No upstream media SDK is redistributed in this bundle.
