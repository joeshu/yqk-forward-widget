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
- (void)applyCaptionFont;
@end

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
        // SRT & WebVTT cue blocks
        NSArray<NSString *> *blocks = [normalized componentsSeparatedByString:@"\n\n"];
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
    self.cues = [HostSubtitleOverlayView parseSubtitleText:rawText];
    [self updateForPlaybackTime:self.lastPlaybackTime];
}

- (void)loadSubtitleURL:(NSURL *)url
                headers:(NSDictionary<NSString *, NSString *> *)headers
             completion:(void (^)(BOOL loaded, NSUInteger cueCount))completion {
    [self.fetchTask cancel];
    self.fetchTask = nil;
    if (!url) {
        if (completion) completion(NO, 0);
        return;
    }
    if (url.isFileURL) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *raw = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
            NSArray<HostSubtitleCue *> *parsed = [HostSubtitleOverlayView parseSubtitleText:raw ?: @""];
            dispatch_async(dispatch_get_main_queue(), ^{
                HostSubtitleOverlayView *owner = weakSelf;
                if (!owner) return;
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
    self.fetchTask = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, __unused NSURLResponse *resp, __unused NSError *err) {
        NSString *raw = data.length ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding]) : nil;
        NSArray<HostSubtitleCue *> *parsed = raw.length ? [HostSubtitleOverlayView parseSubtitleText:raw] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            HostSubtitleOverlayView *owner = weakSelf;
            if (!owner) return;
            owner.cues = parsed;
            [owner updateForPlaybackTime:owner.lastPlaybackTime];
            if (completion) completion(parsed.count > 0, parsed.count);
        });
    }];
    [self.fetchTask resume];
}

- (void)clearSubtitles {
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
    NSMutableArray<NSString *> *active = [NSMutableArray array];
    for (NSInteger i = candidate; i >= 0 && i >= candidate - 4; i--) {
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
