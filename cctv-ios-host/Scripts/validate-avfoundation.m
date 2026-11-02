// Compile with Foundation, AVFoundation, CoreMedia and ImageIO on macOS.
// This executable uses Apple's real parser and decoder; it has no app test stubs.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <string.h>

static NSDictionary *ErrorFields(NSError *error) {
    if (!error) return @{};
    NSMutableDictionary *fields = [@{@"domain":error.domain ?: @"", @"code":@(error.code),
                                    @"message":error.localizedDescription ?: @""} mutableCopy];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying && underlying != error) {
        fields[@"underlying_domain"] = underlying.domain ?: @"";
        fields[@"underlying_code"] = @(underlying.code);
        fields[@"underlying_message"] = underlying.localizedDescription ?: @"";
    }
    return fields;
}

static NSString *LoadStatusName(AVKeyValueStatus status) {
    switch (status) {
        case AVKeyValueStatusLoaded: return @"loaded";
        case AVKeyValueStatusFailed: return @"failed";
        case AVKeyValueStatusCancelled: return @"cancelled";
        case AVKeyValueStatusLoading: return @"loading";
        default: return @"unknown";
    }
}

static NSString *FourCC(FourCharCode value) {
    unsigned char bytes[] = {(value >> 24) & 255, (value >> 16) & 255,
                             (value >> 8) & 255, value & 255};
    for (NSUInteger i = 0; i < 4; i++) {
        if (bytes[i] < 32 || bytes[i] > 126) return [NSString stringWithFormat:@"0x%08x", (unsigned int)value];
    }
    return [[NSString alloc] initWithBytes:bytes length:4 encoding:NSASCIIStringEncoding] ?: @"";
}

static BOOL WriteJSON(id value, NSURL *url, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static NSDictionary *DecodeFrame(AVAsset *asset, double seconds, NSURL *pngURL) {
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(960, 960);
    CMTime requested = CMTimeMakeWithSeconds(seconds, 600);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    NSObject *lock = [NSObject new];
    __block BOOL finished = NO;
    __block NSDictionary *result = nil;
    [generator generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:requested]]
        completionHandler:^(CMTime requestedTime, CGImageRef image, CMTime actualTime,
                            AVAssetImageGeneratorResult status, NSError *error) {
        @synchronized (lock) {
            if (finished) return;
            finished = YES;
            NSMutableDictionary *frame = [@{@"requested_seconds":@(seconds),
                @"passed":@(status == AVAssetImageGeneratorSucceeded && image != NULL)} mutableCopy];
            double actual = CMTimeGetSeconds(actualTime);
            if (isfinite(actual)) frame[@"actual_seconds"] = @(actual);
            if (error) frame[@"error"] = ErrorFields(error);
            if (status == AVAssetImageGeneratorSucceeded && image) {
                frame[@"width"] = @(CGImageGetWidth(image));
                frame[@"height"] = @(CGImageGetHeight(image));
                CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)pngURL, CFSTR("public.png"), 1, NULL);
                BOOL saved = NO;
                if (destination) {
                    CGImageDestinationAddImage(destination, image, NULL);
                    saved = CGImageDestinationFinalize(destination);
                    CFRelease(destination);
                }
                frame[@"png_saved"] = @(saved);
                frame[@"png"] = pngURL.lastPathComponent;
                if (!saved) frame[@"passed"] = @NO;
            }
            result = frame;
        }
        dispatch_semaphore_signal(completed);
    }];
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
        @synchronized (lock) {
            if (!finished) {
                finished = YES;
                result = @{@"requested_seconds":@(seconds), @"passed":@NO, @"timeout_seconds":@30};
            }
        }
        [generator cancelAllCGImageGeneration];
    }
    @synchronized (lock) {
        return result ?: @{@"requested_seconds":@(seconds), @"passed":@NO};
    }
}

static NSDictionary *InspectAsset(NSURL *url, NSString *transport, NSURL *outputDirectory,
                                  NSString *imagePrefix) {
    NSDate *started = [NSDate date];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSArray<NSString *> *keys = @[@"tracks", @"playable", @"duration", @"hasProtectedContent"];
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{ dispatch_semaphore_signal(loaded); }];
    NSMutableDictionary *report = [@{@"transport":transport, @"passed":@NO} mutableCopy];
    if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC)) != 0) {
        [asset cancelLoading];
        report[@"load_timeout_seconds"] = @45;
        report[@"elapsed_seconds"] = @(-started.timeIntervalSinceNow);
        return report;
    }
    NSMutableDictionary *loads = [NSMutableDictionary dictionary];
    for (NSString *key in keys) {
        NSError *error = nil;
        AVKeyValueStatus status = [asset statusOfValueForKey:key error:&error];
        NSMutableDictionary *entry = [@{@"status":LoadStatusName(status)} mutableCopy];
        if (error) entry[@"error"] = ErrorFields(error);
        loads[key] = entry;
    }
    report[@"loads"] = loads;
    if ([asset statusOfValueForKey:@"tracks" error:NULL] != AVKeyValueStatusLoaded) {
        report[@"elapsed_seconds"] = @(-started.timeIntervalSinceNow);
        return report;
    }
    NSArray<AVAssetTrack *> *videos = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audios = [asset tracksWithMediaType:AVMediaTypeAudio];
    report[@"asset_video_track_count"] = @(videos.count);
    report[@"asset_audio_track_count"] = @(audios.count);
    report[@"asset_track_count"] = @(asset.tracks.count);
    BOOL playableLoaded = [asset statusOfValueForKey:@"playable" error:NULL] == AVKeyValueStatusLoaded;
    report[@"playable"] = @(playableLoaded && asset.playable);
    if ([asset statusOfValueForKey:@"hasProtectedContent" error:NULL] == AVKeyValueStatusLoaded)
        report[@"has_protected_content"] = @(asset.hasProtectedContent);
    double duration = [asset statusOfValueForKey:@"duration" error:NULL] == AVKeyValueStatusLoaded
        ? CMTimeGetSeconds(asset.duration) : NAN;
    if (isfinite(duration)) report[@"duration_seconds"] = @(duration);
    NSMutableArray *trackReports = [NSMutableArray array];
    for (AVAssetTrack *track in videos) {
        dispatch_semaphore_t trackLoaded = dispatch_semaphore_create(0);
        NSArray *trackKeys = @[@"formatDescriptions", @"naturalSize", @"nominalFrameRate"];
        [track loadValuesAsynchronouslyForKeys:trackKeys completionHandler:^{ dispatch_semaphore_signal(trackLoaded); }];
        if (dispatch_semaphore_wait(trackLoaded, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) {
            [trackReports addObject:@{@"track_id":@(track.trackID), @"metadata_timeout_seconds":@20}];
            continue;
        }
        NSMutableArray *formats = [NSMutableArray array];
        NSArray *descriptions = [track statusOfValueForKey:@"formatDescriptions" error:NULL] == AVKeyValueStatusLoaded
            ? track.formatDescriptions : @[];
        for (id item in descriptions) {
            CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)item;
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
            [formats addObject:@{@"codec_fourcc":FourCC(CMFormatDescriptionGetMediaSubType(format)),
                @"encoded_width":@(dimensions.width), @"encoded_height":@(dimensions.height)}];
        }
        NSMutableDictionary *details = [@{@"track_id":@(track.trackID), @"formats":formats} mutableCopy];
        if ([track statusOfValueForKey:@"naturalSize" error:NULL] == AVKeyValueStatusLoaded) {
            details[@"natural_width"] = @(fabs(track.naturalSize.width));
            details[@"natural_height"] = @(fabs(track.naturalSize.height));
        }
        if ([track statusOfValueForKey:@"nominalFrameRate" error:NULL] == AVKeyValueStatusLoaded)
            details[@"nominal_frame_rate"] = @(isfinite(track.nominalFrameRate) ? track.nominalFrameRate : 0);
        [trackReports addObject:details];
    }
    report[@"video_tracks"] = trackReports;
    NSMutableArray *frames = [NSMutableArray array];
    if (videos.count > 0) {
        NSMutableArray<NSNumber *> *times = [NSMutableArray arrayWithObject:@0];
        if (isfinite(duration) && duration > .2) [times addObject:@(MIN(1.0, duration / 2.0))];
        for (NSUInteger index = 0; index < times.count; index++) {
            NSString *name = [NSString stringWithFormat:@"%@-%@-%lu.png", imagePrefix, transport,
                              (unsigned long)index];
            [frames addObject:DecodeFrame(asset, times[index].doubleValue,
                [outputDirectory URLByAppendingPathComponent:name])];
        }
    }
    report[@"frames"] = frames;
    BOOL framesPassed = frames.count > 0;
    for (NSDictionary *frame in frames) framesPassed = framesPassed && [frame[@"passed"] boolValue];
    report[@"passed"] = @(videos.count > 0 && playableLoaded && asset.playable && framesPassed);
    report[@"elapsed_seconds"] = @(-started.timeIntervalSinceNow);
    return report;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4 || argc > 5) {
            fprintf(stderr, "Usage: validate-avfoundation INPUT_DIRECTORY OUTPUT_DIRECTORY HTTP_BASE_URL [--allow-failures]\n");
            return 2;
        }
        BOOL allowFailures = argc == 5 && strcmp(argv[4], "--allow-failures") == 0;
        if (argc == 5 && !allowFailures) return 2;
        NSURL *input = [NSURL fileURLWithPath:[[NSString stringWithUTF8String:argv[1]] stringByStandardizingPath]
                                 isDirectory:YES];
        NSURL *output = [NSURL fileURLWithPath:[[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath]
                                  isDirectory:YES];
        NSURL *httpBase = [NSURL URLWithString:[NSString stringWithUTF8String:argv[3]]];
        if (![httpBase.scheme isEqualToString:@"http"] || ![httpBase.host isEqualToString:@"127.0.0.1"]) {
            fprintf(stderr, "HTTP_BASE_URL must use http://127.0.0.1 with the local fixture server.\n");
            return 2;
        }
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        BOOL directory = NO;
        if (![files fileExistsAtPath:input.path isDirectory:&directory] || !directory) {
            fprintf(stderr, "Input directory does not exist.\n");
            return 2;
        }
        if (![files createDirectoryAtURL:output withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Cannot create output directory: %@", error);
            return 2;
        }
        NSMutableArray<NSURL *> *media = [NSMutableArray array];
        NSDirectoryEnumerator *enumerator = [files enumeratorAtURL:input includingPropertiesForKeys:@[NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *failure) {
                NSLog(@"Cannot enumerate %@: %@", url.path, failure);
                return YES;
            }];
        for (NSURL *url in enumerator) {
            NSNumber *regular = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
            if (regular.boolValue && [url.pathExtension.lowercaseString isEqualToString:@"mp4"]) [media addObject:url];
        }
        [media sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.path compare:b.path]; }];
        NSMutableArray *reports = [NSMutableArray array];
        NSUInteger requiredCount = 0, requiredFailures = 0, diagnosticFailures = 0;
        for (NSUInteger index = 0; index < media.count; index++) {
            @autoreleasepool {
                NSURL *url = media[index];
                NSUInteger prefixLength = input.path.length + ([input.path hasSuffix:@"/"] ? 0 : 1);
                NSString *relative = [url.path substringFromIndex:prefixLength];
                BOOL expectedInvalid = [url.lastPathComponent.lowercaseString hasSuffix:@".legacy.mp4"];
                NSString *prefix = [NSString stringWithFormat:@"%03lu", (unsigned long)index];
                NSURL *http = httpBase;
                for (NSString *component in relative.pathComponents) http = [http URLByAppendingPathComponent:component];
                NSLog(@"[%lu/%lu] %@%@", (unsigned long)index + 1, (unsigned long)media.count,
                    relative, expectedInvalid ? @" (legacy comparison)" : @"");
                NSDictionary *local = InspectAsset(url, @"file", output, prefix);
                NSDictionary *served = InspectAsset(http, @"http", output, prefix);
                BOOL passed = [local[@"passed"] boolValue] && [served[@"passed"] boolValue];
                NSDictionary *attributes = [files attributesOfItemAtPath:url.path error:NULL];
                NSDictionary *entry = @{@"file":relative, @"file_bytes":attributes[NSFileSize] ?: @0,
                    @"expected_invalid":@(expectedInvalid), @"passed":@(passed),
                    @"transports":@[local, served]};
                [reports addObject:entry];
                if (!expectedInvalid) { requiredCount++; if (!passed) requiredFailures++; }
                else if (!passed) diagnosticFailures++;
                if (!WriteJSON(entry, [output URLByAppendingPathComponent:[prefix stringByAppendingString:@".json"]], &error)) {
                    NSLog(@"Cannot save result: %@", error);
                    return 2;
                }
                NSLog(@"%@ %@ (file: %@, HTTP: %@)", passed ? @"PASS" : @"FAIL", relative,
                    [local[@"passed"] boolValue] ? @"pass" : @"fail",
                    [served[@"passed"] boolValue] ? @"pass" : @"fail");
            }
        }
        BOOL passed = requiredCount > 0 && requiredFailures == 0;
        NSDictionary *summary = @{@"schema_version":@1,
            @"validator":@"macOS AVURLAsset + AVAssetImageGenerator (real AVFoundation)",
            @"operating_system":NSProcessInfo.processInfo.operatingSystemVersionString,
            @"scope":@"Asset track parsing and frame decoding from local files and localhost HTTP Range; iOS device playback is not established by this check.",
            @"passed":@(passed), @"sample_count":@(media.count), @"required_sample_count":@(requiredCount),
            @"required_failure_count":@(requiredFailures), @"legacy_failure_count":@(diagnosticFailures),
            @"samples":reports};
        if (!WriteJSON(summary, [output URLByAppendingPathComponent:@"results.json"], &error)) {
            NSLog(@"Cannot save summary: %@", error);
            return 2;
        }
        NSLog(@"%lu required samples, %lu failures; %lu legacy failures recorded separately.",
            (unsigned long)requiredCount, (unsigned long)requiredFailures, (unsigned long)diagnosticFailures);
        if (requiredCount == 0) return 1;
        return passed || allowFailures ? 0 : 1;
    }
}
