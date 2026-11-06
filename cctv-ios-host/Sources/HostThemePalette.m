#import "HostThemePalette.h"

// 色板以 #RRGGBB 数据表定义（方便对照与回归验算对比度），运行时转成 UIColor。
// 对比度（WCAG，脚本验算，见 Tests/test_host_themes.py）：
//   主文字/背景 16.8–21.0，次文字/背景 6.8–8.2，强调色/背景 4.5–10.3，
//   强调色上文字/强调色：午夜影院 3.98（沿用现有品牌红 + 白字，仅满足大字 AA，
//   其余五套 4.6–9.1。浅色两套的背景纯白/近白但次文字加深，长时间看不刺眼。
static UIColor *HostThemeColorFromHex(NSString *hex, CGFloat alpha) {
    unsigned int value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex];
    [scanner scanHexInt:&value];
    return [UIColor colorWithRed:((value >> 16) & 0xFF) / 255.0 green:((value >> 8) & 0xFF) / 255.0 blue:(value & 0xFF) / 255.0 alpha:alpha];
}

static NSArray<NSDictionary *> *HostThemePaletteDefinitions(void) {
    return @[
        @{@"id":@"midnight", @"name":@"午夜影院", @"tagline":@"深邃影院", @"dark":@YES,
          @"background":@"#0D0E13", @"card":@"#15161F", @"raised":@"#1C1F2A",
          @"text":@"#FFFFFF", @"secondary":@"#9EA6B8", @"accent":@"#FF0024", @"onAccent":@"#FFFFFF", @"muted":@"#9EA6B8",
          @"glass":@"#15171F", @"glassAlpha":@0.62, @"borderAlpha":@0.12, @"separatorAlpha":@0.11,
          @"neutral":@"#21242F", @"selectedAlpha":@0.18, @"highlightedAlpha":@0.20, @"success":@"#122E21"},
        @{@"id":@"obsidian", @"name":@"曜石黑", @"tagline":@"纯黑沉浸", @"dark":@YES,
          @"background":@"#000000", @"card":@"#0F0F11", @"raised":@"#1A1A1D",
          @"text":@"#FFFFFF", @"secondary":@"#A1A1AA", @"accent":@"#5B67E6", @"onAccent":@"#FFFFFF", @"muted":@"#A1A1AA",
          @"glass":@"#0A0A0C", @"glassAlpha":@0.64, @"borderAlpha":@0.14, @"separatorAlpha":@0.12,
          @"neutral":@"#1C1C1F", @"selectedAlpha":@0.22, @"highlightedAlpha":@0.16, @"success":@"#0F2A1A"},
        @{@"id":@"ocean", @"name":@"深海蓝", @"tagline":@"深海静谧", @"dark":@YES,
          @"background":@"#071018", @"card":@"#0C1B26", @"raised":@"#122635",
          @"text":@"#EDF4F7", @"secondary":@"#8FA9B8", @"accent":@"#2DD4BF", @"onAccent":@"#04211D", @"muted":@"#8FA9B8",
          @"glass":@"#0A1822", @"glassAlpha":@0.62, @"borderAlpha":@0.14, @"separatorAlpha":@0.12,
          @"neutral":@"#16303F", @"selectedAlpha":@0.20, @"highlightedAlpha":@0.18, @"success":@"#0B2E26"},
        @{@"id":@"amber", @"name":@"鎏金棕", @"tagline":@"暖金华贵", @"dark":@YES,
          @"background":@"#17120C", @"card":@"#211A10", @"raised":@"#2C2417",
          @"text":@"#FFF8EC", @"secondary":@"#B8A88F", @"accent":@"#E8A33D", @"onAccent":@"#241A05", @"muted":@"#B8A88F",
          @"glass":@"#1C150B", @"glassAlpha":@0.62, @"borderAlpha":@0.14, @"separatorAlpha":@0.11,
          @"neutral":@"#2E2618", @"selectedAlpha":@0.20, @"highlightedAlpha":@0.16, @"success":@"#1E2E1A"},
        @{@"id":@"daylight", @"name":@"晨光白", @"tagline":@"明亮柔和", @"dark":@NO,
          @"background":@"#F2F3F8", @"card":@"#FDFDFE", @"raised":@"#EAECF2",
          @"text":@"#131313", @"secondary":@"#4F5466", @"accent":@"#CC0929", @"onAccent":@"#FFFFFF", @"muted":@"#595D6E",
          @"glass":@"#FFFFFF", @"glassAlpha":@0.64, @"borderAlpha":@0.14, @"separatorAlpha":@0.10,
          @"neutral":@"#E8EAF0", @"selectedAlpha":@0.12, @"highlightedAlpha":@0.06, @"success":@"#E0F5E8"},
        @{@"id":@"snow", @"name":@"雪原白", @"tagline":@"纯白通透", @"dark":@NO,
          @"background":@"#FFFFFF", @"card":@"#F6F6F8", @"raised":@"#EDEDF0",
          @"text":@"#111318", @"secondary":@"#565B66", @"accent":@"#2E5BFF", @"onAccent":@"#FFFFFF", @"muted":@"#5A5E68",
          @"glass":@"#FFFFFF", @"glassAlpha":@0.68, @"borderAlpha":@0.15, @"separatorAlpha":@0.11,
          @"neutral":@"#ECECF0", @"selectedAlpha":@0.12, @"highlightedAlpha":@0.05, @"success":@"#E2F3E9"},
    ];
}

@interface HostThemePalette ()
- (instancetype)initWithDefinition:(NSDictionary *)definition;
@end

@implementation HostThemePalette

- (instancetype)initWithDefinition:(NSDictionary *)definition {
    if ((self = [super init])) {
        _identifier = [definition[@"id"] copy];
        _displayName = [definition[@"name"] copy];
        _tagline = [definition[@"tagline"] copy];
        _dark = [definition[@"dark"] boolValue];
        _background = HostThemeColorFromHex(definition[@"background"], 1);
        _card = HostThemeColorFromHex(definition[@"card"], 1);
        _raisedSurface = HostThemeColorFromHex(definition[@"raised"], 1);
        _text = HostThemeColorFromHex(definition[@"text"], 1);
        _secondaryText = HostThemeColorFromHex(definition[@"secondary"], 1);
        _accent = HostThemeColorFromHex(definition[@"accent"], 1);
        _onAccent = HostThemeColorFromHex(definition[@"onAccent"], 1);
        _mutedText = HostThemeColorFromHex(definition[@"muted"], 1);
        _glassTint = HostThemeColorFromHex(definition[@"glass"], [definition[@"glassAlpha"] doubleValue]);
        CGFloat edgeWhite = _dark ? 1 : 0;
        _border = [UIColor colorWithWhite:edgeWhite alpha:[definition[@"borderAlpha"] doubleValue]];
        _separator = [UIColor colorWithWhite:edgeWhite alpha:[definition[@"separatorAlpha"] doubleValue]];
        _neutralSurface = HostThemeColorFromHex(definition[@"neutral"], 1);
        _selectedSurface = [_accent colorWithAlphaComponent:[definition[@"selectedAlpha"] doubleValue]];
        _highlightedSurface = [UIColor colorWithWhite:edgeWhite alpha:[definition[@"highlightedAlpha"] doubleValue]];
        _successSurface = HostThemeColorFromHex(definition[@"success"], 1);
    }
    return self;
}

+ (NSArray<HostThemePalette *> *)allThemes {
    static NSArray<HostThemePalette *> *themes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<HostThemePalette *> *built = [NSMutableArray array];
        for (NSDictionary *definition in HostThemePaletteDefinitions()) {
            [built addObject:[[HostThemePalette alloc] initWithDefinition:definition]];
        }
        themes = [built copy];
    });
    return themes;
}

+ (nullable HostThemePalette *)paletteForIdentifier:(nullable NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    for (HostThemePalette *palette in self.allThemes) {
        if ([palette.identifier isEqualToString:identifier]) return palette;
    }
    return nil;
}

+ (HostThemePalette *)defaultDarkPalette { return [self paletteForIdentifier:HostThemePaletteDefaultIdentifier]; }
+ (HostThemePalette *)defaultLightPalette { return [self paletteForIdentifier:@"daylight"]; }

+ (NSString *)currentPaletteIdentifier {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:HostThemePaletteIdentifierPreferenceKey];
    if ([self paletteForIdentifier:saved]) return saved;
    return HostThemePaletteDefaultIdentifier;
}

+ (void)setCurrentPaletteIdentifier:(NSString *)identifier {
    if (![self paletteForIdentifier:identifier]) identifier = HostThemePaletteDefaultIdentifier;
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:HostThemePaletteIdentifierPreferenceKey];
}

+ (HostThemePalette *)currentPalette {
    return [self paletteForIdentifier:self.currentPaletteIdentifier] ?: self.defaultDarkPalette;
}

+ (HostThemePalette *)effectivePaletteForDark:(BOOL)dark {
    HostThemePalette *selected = self.currentPalette;
    if (selected.dark == dark) return selected;
    return dark ? self.defaultDarkPalette : self.defaultLightPalette;
}

@end
