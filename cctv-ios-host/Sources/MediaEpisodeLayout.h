#import <Foundation/Foundation.h>

static const NSUInteger CCTVEpisodesPerGroup = 30;

static inline NSUInteger CCTVEpisodeDisplayIndex(NSUInteger sourceIndex, NSUInteger count, BOOL reversed) {
    if (count == 0 || sourceIndex >= count) return NSNotFound;
    return reversed ? count - sourceIndex - 1 : sourceIndex;
}

static inline NSUInteger CCTVEpisodeSourceIndex(NSUInteger displayIndex, NSUInteger count, BOOL reversed) {
    if (count == 0 || displayIndex >= count) return NSNotFound;
    return reversed ? count - displayIndex - 1 : displayIndex;
}

static inline NSInteger CCTVEpisodeGroupForSourceIndex(NSUInteger sourceIndex, NSUInteger count, BOOL reversed) {
    NSUInteger displayIndex = CCTVEpisodeDisplayIndex(sourceIndex, count, reversed);
    return displayIndex == NSNotFound ? 0 : (NSInteger)(displayIndex / CCTVEpisodesPerGroup);
}
