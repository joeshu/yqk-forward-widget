#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Extracts a normalized episode number (Arabic digits, no leading zeros) from a
/// free-form episode name such as "第3集", "EP12", "S02E05" or "12".
/// Returns an empty string when no episode number can be inferred.
FOUNDATION_EXPORT NSString *MediaPlaybackEpisodeNumber(NSString *value);

/// Returns YES when two episode names refer to the same episode, comparing both
/// the raw (case-insensitive) text and the parsed episode numbers.
FOUNDATION_EXPORT BOOL MediaPlaybackEpisodeNamesMatch(NSString *left, NSString *right);

NS_ASSUME_NONNULL_END
