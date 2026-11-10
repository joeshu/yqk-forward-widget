# Cicada HLS crash investigation (2026-11-10)

The device report `CCTVHost-2026-11-10-194353.ips` is for CCTVHost 1.33 (502), iOS 27.0.1. Its capture time is 19:43:48.933 +0800. The faulting thread is thread 20, with EXC_BAD_ACCESS / SIGSEGV at address 0. Its stack begins in `Cicada::demuxer_service::open_callback`, called by `proxyDataSource::Open`, `HLSStream::openSegment`, `HLSStream::open_internal`, and the HLS read thread. The shipped CicadaPlayerSDK image UUID in the report is E6A8C2C7-EEF0-3295-9CE0-A62DD0766FE5; the fault is at image offset 0xd0e9c.

At that offset the shipped arm64 binary contains `ldr x8, [x0]`, and the crash register state has x0 = 0. This confirms a null-pointer dereference inside the binary's open callback. It does not establish why the pointer became null, which URL or playlist triggered it, or whether player teardown raced with the HLS worker.

The later application diagnostic session starts at 19:43:57 +0800, after this crash. Its 19:44:30 AVPlayer-to-Cicada handoff cannot be attributed to this crash. MetricKit delivery at 19:44:38 is asynchronous and cannot on its own identify the crash time.

The public Alibaba CicadaPlayer `framework/demuxer/demuxer_service.cpp` open callback checks the data-source member before setting its range and opening the URL. That source has not been established as the exact source used to build the bundled vendor binary; its checks do not prove that the binary is safe under every concurrent lifecycle. Do not ship a guessed binary patch or disable all HLS based on this one report.

The adapter and view controller previously both imposed a fixed 20 second first-frame deadline even when the configured network timeout was up to 40 seconds. The local change makes both use the same max(20 seconds, network timeout + 10 seconds) deadline. This addresses a separate premature-timeout issue and is not a fix for the native crash.

Next validation requires the triggering HLS playlist and headers or a reproducible local HLS fixture, the exact vendor SDK build/source or a supported replacement, and iOS device tests including opening failing/disconnected segments and concurrent stop/destroy. The currently bundled framework must be tested directly; the simulator SDK fixture alone cannot prove the native HLS worker is fixed.
