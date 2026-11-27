#import "HostSubtitleOverlayView.h"

@implementation HostSubtitleCue
@end

static NSTimeInterval HostSubtitleParseTimestamp(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 + parts[2].doubleValue;
    }
    if (parts.count == 2) {
        return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    }
    return -1.0;
}

static NSString *HostSubtitleStripTags(NSString *text) {
    if (!text.length) return @"";
    static NSRegularExpression *assTagRegex = nil;
    static NSRegularExpression *htmlTagRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        assTagRegex = [NSRegularExpression regularExpressionWithPattern:@"\\{[^\\}]*\\}" options:0 error:NULL];
        htmlTagRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:NULL];
    });
    NSString *s = [text stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    s = [assTagRegex stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    s = [htmlTagRegex stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

@interface HostSubtitleOverlayView ()
@property (nonatomic, strong) UIView *pillContainer;
@property (nonatomic, strong) UILabel *captionLabel;
@property (nonatomic, copy) NSArray<HostSubtitleCue *> *cues;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *fetchTask;
@property (nonatomic, assign) NSTimeInterval lastPlaybackTime;
/// T09：加载代际——每次 load/clear 递增；异步完成到达时 generation 已变
/// 则直接丢弃，晚返回的旧字幕不得覆盖新集（A06）。
@property (nonatomic, assign) NSUInteger loadGeneration;
- (void)applyCaptionFont;
@end

/// T09：外挂字幕文件尺寸上限（2 MiB）——超过一律按加载失败处理，不解析。
static const NSUInteger HostSubtitleMaxBytes = 2 * 1024 * 1024;

@implementation HostSubtitleOverlayView

+ (NSArray<HostSubtitleCue *> *)parseSubtitleText:(NSString *)rawText {
    if (![rawText isKindOfClass:NSString.class] || !rawText.length) return @[];
    NSString *normalized = [rawText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray<HostSubtitleCue *> *result = [NSMutableArray array];

    // ASS / SSA Dialogue lines
    if ([normalized containsString:@"[Events]"] || [normalized containsString:@"Dialogue:"]) {
        for (NSString *line in [normalized componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"Dialogue:"]) continue;
            NSString *payload = [line substringFromIndex:9];
            NSArray<NSString *> *fields = [payload componentsSeparatedByString:@","];
            if (fields.count < 10) continue;
            NSTimeInterval start = HostSubtitleParseTimestamp(fields[1]);
            NSTimeInterval end = HostSubtitleParseTimestamp(fields[2]);
            if (start < 0 || end <= start) continue;
            NSString *text = [[fields subarrayWithRange:NSMakeRange(9, fields.count - 9)] componentsJoinedByString:@","];
            NSString *clean = HostSubtitleStripTags(text);
            if (!clean.length) continue;
            HostSubtitleCue *cue = [HostSubtitleCue new];
            cue.startTime = start;
            cue.endTime = end;
            cue.text = clean;
            [result addObject:cue];
        }
    } else {
        // SRT & WebVTT cue blocks (tolerate blank lines containing spaces/tabs)
        static NSRegularExpression *blankLineRegex = nil;
        static dispatch_once_t blankOnce;
        dispatch_once(&blankOnce, ^{
            blankLineRegex = [NSRegularExpression regularExpressionWithPattern:@"\n[ \t]+\n" options:0 error:NULL];
        });
        NSString *blockNormalized = blankLineRegex
            ? [blankLineRegex stringByReplacingMatchesInString:normalized options:0 range:NSMakeRange(0, normalized.length) withTemplate:@"\n\n"]
            : normalized;
        NSArray<NSString *> *blocks = [blockNormalized componentsSeparatedByString:@"\n\n"];
        for (NSString *block in blocks) {
            NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
            NSInteger timingIdx = -1;
            for (NSUInteger i = 0; i < lines.count; i++) {
                if ([lines[i] containsString:@"-->"]) {
                    timingIdx = (NSInteger)i;
                    break;
                }
            }
            if (timingIdx < 0 || (NSUInteger)(timingIdx + 1) >= lines.count) continue;
            NSArray<NSString *> *bounds = [lines[(NSUInteger)timingIdx] componentsSeparatedByString:@"-->"];
            if (bounds.count < 2) continue;
            NSString *endToken = [[bounds[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsSeparatedByString:@" "].firstObject ?: @"";
            NSTimeInterval start = HostSubtitleParseTimestamp(bounds[0]);
            NSTimeInterval end = HostSubtitleParseTimestamp(endToken);
            if (start < 0 || end <= start) continue;
            NSString *body = [[lines subarrayWithRange:NSMakeRange((NSUInteger)timingIdx + 1, lines.count - (NSUInteger)timingIdx - 1)] componentsJoinedByString:@"\n"];
            NSString *clean = HostSubtitleStripTags(body);
            if (!clean.length) continue;
            HostSubtitleCue *cue = [HostSubtitleCue new];
            cue.startTime = start;
            cue.endTime = end;
            cue.text = clean;
            [result addObject:cue];
        }
    }

    [result sortUsingComparator:^NSComparisonResult(HostSubtitleCue *a, HostSubtitleCue *b) {
        if (a.startTime < b.startTime) return NSOrderedAscending;
        if (a.startTime > b.startTime) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return result.copy;
}

- (void)dealloc {
    [_fetchTask cancel];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        _fontScale = 1.0;
        _timeOffset = 0.0;
        _subtitlesEnabled = YES;
        _cues = @[];

        _pillContainer = [UIView new];
        _pillContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _pillContainer.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        _pillContainer.layer.cornerRadius = 8.0;
        _pillContainer.layer.cornerCurve = kCACornerCurveContinuous;
        _pillContainer.hidden = YES;
        [self addSubview:_pillContainer];

        _captionLabel = [UILabel new];
        _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _captionLabel.numberOfLines = 0;
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.textColor = UIColor.whiteColor;
        _captionLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        _captionLabel.shadowOffset = CGSizeMake(0, 1);
        _captionLabel.accessibilityIdentifier = @"media.subtitle.overlay";
        [_pillContainer addSubview:_captionLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_pillContainer.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_pillContainer.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18],
            [_pillContainer.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor constant:16],
            [_pillContainer.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
            [_captionLabel.topAnchor constraintEqualToAnchor:_pillContainer.topAnchor constant:5],
            [_captionLabel.bottomAnchor constraintEqualToAnchor:_pillContainer.bottomAnchor constant:-5],
            [_captionLabel.leadingAnchor constraintEqualToAnchor:_pillContainer.leadingAnchor constant:10],
            [_captionLabel.trailingAnchor constraintEqualToAnchor:_pillContainer.trailingAnchor constant:-10],
        ]];
        [self applyCaptionFont];
    }
    return self;
}

- (void)applyCaptionFont {
    CGFloat clamped = MIN(1.6, MAX(0.8, self.fontScale));
    self.captionLabel.font = [UIFont systemFontOfSize:round(16.0 * clamped) weight:UIFontWeightSemibold];
}

- (void)setFontScale:(CGFloat)fontScale {
    _fontScale = MIN(1.6, MAX(0.8, fontScale));
    [self applyCaptionFont];
}

- (void)setTimeOffset:(NSTimeInterval)timeOffset {
    _timeOffset = timeOffset;
    [self updateForPlaybackTime:self.lastPlaybackTime];
}

- (void)setSubtitlesEnabled:(BOOL)subtitlesEnabled {
    _subtitlesEnabled = subtitlesEnabled;
    if (!subtitlesEnabled) self.pillContainer.hidden = YES;
    else [self updateForPlaybackTime:self.lastPlaybackTime];
}

- (NSUInteger)cueCount {
    return self.cues.count;
}

- (void)loadSubtitleText:(NSString *)rawText {
    self.loadGeneration += 1;
    self.cues = [HostSubtitleOverlayView parseSubtitleText:rawText];
    [self updateForPlaybackTime:self.lastPlaybackTime];
}

- (void)loadSubtitleURL:(NSURL *)url
                headers:(NSDictionary<NSString *, NSString *> *)headers
             completion:(void (^)(BOOL loaded, NSUInteger cueCount))completion {
    // T09：每次加载递增 generation；旧请求的异步完成到达时若 generation
    // 已变，直接丢弃——晚返回的旧字幕不得覆盖新集（A06）。
    self.loadGeneration += 1;
    NSUInteger generation = self.loadGeneration;
    [self.fetchTask cancel];
    self.fetchTask = nil;
    if (!url) {
        if (completion) completion(NO, 0);
        return;
    }
    if (url.isFileURL) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<HostSubtitleCue *> *parsed = @[];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:NULL];
            NSNumber *size = attrs[NSFileSize];
            if (!size || size.unsignedIntegerValue <= HostSubtitleMaxBytes) {
                NSData *data = [NSData dataWithContentsOfURL:url];
                if (data.length && data.length <= HostSubtitleMaxBytes) {
                    NSStringEncoding gbEncoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
                    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                        ?: [[NSString alloc] initWithData:data encoding:gbEncoding]
                        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                    parsed = raw.length ? [HostSubtitleOverlayView parseSubtitleText:raw] : @[];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                HostSubtitleOverlayView *owner = weakSelf;
                if (!owner || owner.loadGeneration != generation) return;
                owner.cues = parsed;
                [owner updateForPlaybackTime:owner.lastPlaybackTime];
                if (completion) completion(parsed.count > 0, parsed.count);
            });
        });
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    for (NSString *k in headers) {
        if ([k isKindOfClass:NSString.class] && [headers[k] isKindOfClass:NSString.class]) {
            [req setValue:headers[k] forHTTPHeaderField:k];
        }
    }
    __weak typeof(self) weakSelf = self;
    self.fetchTask = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        // T09：状态与错误必须判定——非 2xx、网络错误、超 2 MiB 一律按加载
        // 失败处理，不解析错误页/超大体。
        NSArray<HostSubtitleCue *> *parsed = @[];
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (!err && http.statusCode >= 200 && http.statusCode < 300 && data.length && data.length <= HostSubtitleMaxBytes) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            parsed = raw.length ? [HostSubtitleOverlayView parseSubtitleText:raw] : @[];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            HostSubtitleOverlayView *owner = weakSelf;
            if (!owner || owner.loadGeneration != generation) return;
            owner.cues = parsed;
            [owner updateForPlaybackTime:owner.lastPlaybackTime];
            if (completion) completion(parsed.count > 0, parsed.count);
        });
    }];
    [self.fetchTask resume];
}

- (void)clearSubtitles {
    self.loadGeneration += 1;
    [self.fetchTask cancel];
    self.fetchTask = nil;
    self.cues = @[];
    self.captionLabel.text = nil;
    self.pillContainer.hidden = YES;
}

- (void)updateForPlaybackTime:(NSTimeInterval)playbackTime {
    self.lastPlaybackTime = playbackTime;
    if (!self.subtitlesEnabled || !self.cues.count || !isfinite(playbackTime)) {
        self.pillContainer.hidden = YES;
        return;
    }
    NSTimeInterval target = playbackTime - self.timeOffset;
    NSInteger lo = 0, hi = (NSInteger)self.cues.count - 1, candidate = -1;
    while (lo <= hi) {
        NSInteger mid = lo + (hi - lo) / 2;
        if (self.cues[(NSUInteger)mid].startTime <= target) {
            candidate = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    // T09：重叠长 cue 修复——从 candidate 一路扫回第 0 条，收集全部覆盖
    // target 的 cue（旧代码只查最近 5 条，早开始的长 cue 会被遗漏）。
    // cue 数通常 < 数千，逐帧全扫的开销可忽略；显示顺序保持 startTime 升序。
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSInteger i = candidate; i >= 0; i--) {
        HostSubtitleCue *cue = self.cues[(NSUInteger)i];
        if (cue.startTime <= target && target <= cue.endTime) {
            [active insertObject:cue.text atIndex:0];
        }
    }
    if (active.count) {
        self.captionLabel.text = [active componentsJoinedByString:@"\n"];
        self.pillContainer.hidden = NO;
    } else {
        self.pillContainer.hidden = YES;
    }
}

@end
