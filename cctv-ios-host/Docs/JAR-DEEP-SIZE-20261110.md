# Further Java runtime size research

The first packaging change is PR #14. Its complete candidate IPA is 93,204,952
bytes, compared with 106,835,077 bytes in release 1.31. This follow-up examines
the contents left inside the Java image and dependency archives.

## Findings adopted for the second profile

The exploded target modules used by the pinned build contain OpenJDK compiler
bookkeeping alongside class files. The original image contains **110** such
entries, **6,165,741 bytes** in total. Examples are `_the.java.base_batch.filelist`,
`_the.java.base_batch.modfiles`, `_the.java.base_internalapi`, compiler arguments,
and empty build stamps. These contain build paths, Java source lists and API
dependency fingerprints. The upstream OpenJDK `JavaCompilation.gmk` defines
these exact build products. They are not service-provider or application data.

The second profile excludes only root-level `_the.*` resources when linking.
Verification independently permits only the eleven known bookkeeping names for
each module. An unexpected removed class or resource aborts packaging. All ten
modules and 10,817 class names remain; all other runtime-resource contents are
extracted and compared by SHA-256. XML catalogs, ICU/charset data, security
configuration and service files remain intact. Per-module sizes and the exact
removed paths are recorded in `packaging-report.json`.

Three specifically named archives contain no JVM classes or service providers:

- `kotlin-stdlib-common-1.9.10.jar`: common compiler metadata; retain JVM stdlib.
- `okio-3.6.0.jar`: common compiler metadata; retain `okio-jvm-3.6.0.jar`.
- `listenablefuture-9999.0-empty-to-avoid-conflict-with-guava.jar`: Maven conflict
  placeholder; the actual ListenableFuture class remains in Guava.

The archive-removal guard accepts only manifests, Maven metadata and Kotlin
compiler metadata. A class, native binary, service registration or unknown
resource causes a hard failure. No other dependency archive is rewritten.

## Options rejected after inspection

- Bouncy Castle has 1,087 base classes with versioned counterparts. Its
  multi-release structure is governed by the JAR specification, including base
  public API entries. They are not ordinary redundant files. Older versioned
  entries shadowed by newer ones save only about 10 KB compressed. Keep the
  signed provider whole rather than weakening its packaging contract.
- unidbg's 34 guest ELF libraries are all ARM or AArch64 (21 and 13 respectively),
  not accidentally bundled x86/Mac executables. Keep both guest resource sets.
- Whole-module removal is not adopted from jdeps alone. The host uses management,
  logging, the local HTTP server, XML and character sets; plugins and providers
  can access other classes through reflection and service loading. Keeping the
  module/API surface while removing actual build products gives a measurable,
  narrower change.

## Compatibility evidence

`check_jar_compatibility.py` compiles the pinned upstream's 21 local regression
drivers and runs every driver against the original and candidate JavaHost class
paths in isolated work directories: **42 executions**. Coverage includes Android
context/UI data models, plugin loading, FongMi SDK, bytecode conversion, shared
conversion cache/repair, cloud proxy fixtures, native-library discovery/checksum,
request cancellation and session lifetime. Network cases use controlled fixtures.

The pinned upstream fixture has one stale SLF4J 1.x factory reference while its
POM ships `slf4j-simple 2.0.13`. Both original and candidate initially fail that
same fixture. The harness verifies the real dependency's 2.x factory class,
adapts that one fallback-class assertion, and reports the adjustment explicitly.
The plugin's own-binder precedence assertion remains in place. With this fixture
correction, both class paths pass 21/21 on the desktop JVM.

Embedded Zero/DEX checks remain separate and include direct Kotlin, Okio and
Guava class resolution, cryptography, Chinese encodings, XML/JSON, ZIP filesystem,
plugin assets, all five spider operations, and AVPlayer video rendering. The
device-target IPA is independently built and checked. Apple results and actual
complete-IPA byte savings are recorded in the PR after CI completes.

## Reproducible resource-only rebuilds

Each previous native cache compressed to about 4.17 GB. Keep the validated native
outputs and version-matched relinking kit instead of compiler intermediates.
Native reuse checks the source/SDK stamp, matching archive bytes, JNI headers,
all module directories, matching jlink/jimage tools and boot security data. A
resource-only rebuild skips native backend compilation; a mismatch performs a
complete source build. The pinned outer source archive is verified and restored
when needed. Cache keys distinguish iOS and simulator boundaries explicitly.

References:

- [OpenJDK compiler bookkeeping](https://github.com/openjdk/jdk/blob/master/make/common/JavaCompilation.gmk)
- [Multi-release JAR specification](https://docs.oracle.com/en/java/javase/26/docs/specs/jar/jar.html#multi-release-jar-files)
- [Pinned upstream JavaHost tests](https://github.com/jo32/tvbox-silicon/tree/47e563274414c61123db3e8603b7d97ea29f5cee/Tests/Java)
