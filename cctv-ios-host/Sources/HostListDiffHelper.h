#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A minimal, deterministic diff between two ordered arrays of items keyed by
/// stable identities. Indexes are reported in the coordinate spaces expected by
/// UIKit batch updates:
///   - insertedNewIndexes / reloadedNewIndexes : indexes into the NEW array
///   - deletedOldIndexes                       : indexes into the OLD array
///   - moves @{ @"from": oldIndex, @"to": newIndex }
///
/// The helper is pure Foundation: it performs no UIKit calls and touches no UI
/// state, so callers can unit-test and reuse it from any thread. All work is
/// done synchronously inside `+diffFromOld:toNew:identityBlock:isEqualBlock:`.
@interface HostListDiff : NSObject
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *insertedNewIndexes;
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *deletedOldIndexes;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *moves; // @{from@(NSUInteger),to@(NSUInteger)}
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *reloadedNewIndexes;
@property(nonatomic, readonly) BOOL isEmpty;
@end

/// Stateless diff helper. Safe to call from any thread; produces a new
/// `HostListDiff` describing how to transform `oldItems` into `newItems`.
///
/// identityBlock  : returns a stable identity string for an item. Must be
///                  non-nil for meaningful results; nil/empty items fall back
///                  to an object-pointer identity so they never collide.
/// isEqualBlock   : optional. Returns YES when two items sharing an identity
///                  are visually identical (no reload needed). nil => always
///                  equal (only structural insert/delete/move reported).
@interface HostListDiffHelper : NSObject
+ (HostListDiff *)diffFromOld:(nullable NSArray *)oldItems
                        toNew:(nullable NSArray *)newItems
                identityBlock:(NSString *(^)(id item))identityBlock
                  isEqualBlock:(nullable BOOL (^)(id oldItem, id newItem))isEqualBlock;
@end

NS_ASSUME_NONNULL_END
