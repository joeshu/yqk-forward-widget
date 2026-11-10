# JAR runtime and playback work — 2026-11-10

## Implementation

Reference: [jo32/tvbox-silicon](https://github.com/jo32/tvbox-silicon), pinned at
`47e563274414c61123db3e8603b7d97ea29f5cee`.

The iOS app statically links the reference's OpenJDK Zero interpreter, native
bindings and Unicorn TCI. It uses the original Java host, DEX-to-JVM conversion
and Android compatibility classes. There is no JIT, Android process or remote
execution server. `Runtime/JAR/upstream.json` pins source and archive SHA-256;
`Scripts/prepare_jar_runtime.sh` reproduces the build. The corresponding upstream
source, build scripts, patches and license notices remain available at that
revision. License texts accompany the packaged runtime.

`MediaJARSource.h` preserves `csp_*` and full Java class names, resolves global
`spider` and per-site `jar` against the subscription URL, verifies inline MD5,
and retains ext and opaque episode IDs. Older incorrectly resolved `/csp_*`
records are migrated. `RootViewController` passes the JAR descriptor into the
existing catalogue source without losing the subscription scope.

`MediaJARRuntime` downloads a bounded archive, verifies its content digest,
persists it by SHA-256, and shares conversion artifacts by archive hash. Source
sessions include subscription, class, key, ext and header identity. Requests run
on 8 MiB worker stacks, at most two active and two pending. Cancellation reaches
the Java host; the UI abandons a request after 15 minutes. Java-side execution
deadlines are 90 seconds for play, 60 for search, and 150 for browsing, after
initial preparation. Finished conversion steps survive interruption. A plugin
stuck in arbitrary code cannot be forcibly unloaded from an in-process JVM.

Known native ports (App3Q and SP360) remain preferred. Other JAR sources with a
valid archive execute their supplied class. JSON results use the existing TVBox
normalizer and parser flow. Archive/API credentials do not become CDN headers;
only playback headers returned by the spider are forwarded to media requests.
Release builds fail if the JVM or runtime resources are missing. The full app's
minimum OS is iOS 17 because this runtime is built for iOS 17+.

## Player changes

- AVPlayer starts with a small preferred buffer, then expands to 12 seconds at
  1x; higher playback rates and stalls increase that preference within a
  30-second ceiling. Low Power Mode and memory pressure use smaller buffers.
  These are preferences, not guarantees of a transfer rate.
- One guarded startup acceleration can run after a real frame and at least one
  buffered second. A paused player is not restarted by the first-frame hook.
  AVFoundation retains its automatic stall-minimization behavior.
- Next-episode resolution starts near the end of finite VOD, with adequate
  buffered media. Attempts are spaced at least 30 seconds apart; cached results
  are checked against source/title/line/episode identity and a short TTL.
- The next episode can reuse one prepared AVURLAsset. The previous blind HTTP
  Range warm-up is removed: a server ignoring Range could download an entire
  movie with no cancellation or size bound. Memory warnings release preloads.
- Cicada waits for actual prepare callbacks instead of fabricating readiness
  after 250 ms. Pausing during preparation cancels deferred autoplay. Buffer
  thresholds increase after the first frame and on rebuffering. Initial and
  restored playback speeds are applied consistently.
- Video size and audio position do not prove a rendered frame. Only SDK render
  callbacks/events signal the first frame. Per-frame callbacks stop dispatching
  UI work once that frame is known. Progress callbacks and polling are coalesced.
- DASH bridge ready/unavailable categories now reach the exported diagnostics,
  without raw URLs, subscription tokens or ext values.

## Evidence and limits

The supplied diagnostic files are still app 1.30/build 480. They show Unicode URL
errors, invalid DASH input, 404s followed by pointless software-decoder retries,
and Python startup errors. Earlier commits in this PR address URL encoding,
clear DASH remuxing, decoder-only retry and safe startup diagnostics. These old
logs cannot establish performance of the new build.

A controlled DEX-only CatVod fixture was generated from the Java source under
`Tests/JARFixture/`, using pinned Google D8 8.3.37. Desktop JVM execution of the
actual host passed home, category filters, Chinese/emoji search, detail and play,
including a non-URL episode ID. This demonstrates conversion/dispatch, not iPhone
performance or compatibility of an arbitrary third-party JAR.

`Scripts/jar_smoke.sh` is the stronger iOS simulator check: the app downloads the
DEX fixture once, executes all five operations through the production JNI bridge,
then renders its H.264/AAC result with AVPlayer. The test server checks separation
of archive and media headers. A controlled Cicada SDK fixture checks preparation,
pause, first-frame, buffer and seek/error behavior; it does not test proprietary
Cicada decoding. Actual completion/results are reported in CI, separately from
ordinary UI smoke (which does not embed the JVM).

The newly supplied `cj_…` subscription was requested verbatim and returned HTTP
403, `ACCESS_DENIED`, “禁止使用脚本/抓包工具访问！”. No source list was returned, so its
stations cannot be claimed as tested or playable. No UA impersonation or access
restriction bypass was used. Testing that exact list needs a configuration export
or an endpoint the provider permits this client to read. The token is not saved
in the repository.

Real JAR support remains source-specific. Plugins needing unsupported Android UI,
Go subprocesses, account sign-in or additional native dependencies can still fail.
Encrypted HJS packages are a different protocol and are not unlocked by a JVM.
No claim is made that all Tencent/Youku/iQIYI content, paid video or protected media
is playable. Device first-frame, sustained buffering and thermal measurements
remain necessary before making speed or stability improvement percentages.
