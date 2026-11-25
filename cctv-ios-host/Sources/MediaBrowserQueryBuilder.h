#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// MediaBrowserQueryBuilder owns the pure, UIKit-free search/filter logic shared
/// by the media source picker (MediaSourcePicker inside MediaBrowserViewController.m):
///
///   • per-scope choice counting,
///   • case- and diacritic-insensitive query filtering across name / subtitle / url
///     constrained by the active scope ("*" disables the scope filter),
///   • localized empty-state messaging.
///
/// Moving this logic out of the view controller keeps MediaBrowserViewController.m
/// focused on presentation while making the query semantics unit-testable in
/// isolation. All inputs are plain NSDictionary arrays; no UIKit types are used.
@interface MediaBrowserQueryBuilder : NSObject

/// Number of choices whose ``scope`` equals ``key``. Non-dictionary entries and
/// entries whose ``scope`` is not a string equal to ``key`` are skipped.
/// Mirrors the predicate previously inlined in ``-[MediaSourcePicker configureScopes]``.
+ (NSUInteger)choiceCountForScope:(NSString *)key choices:(NSArray<NSDictionary *> *)choices;

/// Filters ``choices`` by ``scope`` (``"*"`` disables the scope filter) and a
/// case- and diacritic-insensitive ``query`` matched against name / subtitle / url.
/// An empty query matches every in-scope choice; non-dictionary entries are dropped.
/// Mirrors the predicate previously inlined in
/// ``-[MediaSourcePicker updateSearchResultsForSearchController:]``.
+ (NSArray<NSDictionary *> *)filteredChoices:(NSArray<NSDictionary *> *)choices
                                        query:(NSString *)query
                                        scope:(NSString *)scope;

/// Localized empty-state message shown by the picker when no choices remain:
/// a query-specific hint when searching, otherwise a prompt to switch to "全部".
+ (NSString *)emptyMessageForQuery:(NSString *)query;

@end

NS_ASSUME_NONNULL_END
