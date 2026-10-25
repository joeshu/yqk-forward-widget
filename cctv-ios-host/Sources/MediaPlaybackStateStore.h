#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Local playback history and per-title skip markers. Resolved media URLs and
/// request headers are deliberately never persisted.
@interface MediaPlaybackStateStore : NSObject
+ (NSArray<NSDictionary *> *)watchHistory;
+ (nullable NSDictionary *)historyEntryForContext:(NSDictionary *)context
                                        lineIndex:(NSInteger)lineIndex
                                     episodeIndex:(NSInteger)episodeIndex;
+ (nullable NSDictionary *)latestHistoryForSourceID:(NSString *)sourceID
                                             provider:(NSString *)provider
                                               itemID:(NSString *)itemID;
+ (void)recordContext:(NSDictionary *)context
             lineIndex:(NSInteger)lineIndex
          episodeIndex:(NSInteger)episodeIndex
              position:(NSTimeInterval)position
              duration:(NSTimeInterval)duration
             completed:(BOOL)completed;
+ (void)removeHistoryEntryWithKey:(NSString *)key;
+ (void)clearWatchHistory;

+ (NSTimeInterval)introEndForContext:(NSDictionary *)context;
+ (NSTimeInterval)outroSkipForContext:(NSDictionary *)context;
+ (void)setIntroEnd:(NSTimeInterval)seconds forContext:(NSDictionary *)context;
+ (void)setOutroSkip:(NSTimeInterval)seconds forContext:(NSDictionary *)context;
+ (void)clearSkipPointsForContext:(NSDictionary *)context;
@end

NS_ASSUME_NONNULL_END
