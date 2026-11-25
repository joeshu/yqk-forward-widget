#import "HostListDiffHelper.h"

@implementation HostListDiff

- (instancetype)initWithInserted:(NSArray<NSNumber *> *)inserted
                         deleted:(NSArray<NSNumber *> *)deleted
                            moves:(NSArray<NSDictionary *> *)moves
                        reloaded:(NSArray<NSNumber *> *)reloaded {
    if((self=[super init])){
        _insertedNewIndexes=[inserted copy]?:@[];
        _deletedOldIndexes=[deleted copy]?:@[];
        _moves=[moves copy]?:@[];
        _reloadedNewIndexes=[reloaded copy]?:@[];
    }
    return self;
}

- (BOOL)isEmpty {
    return _insertedNewIndexes.count==0 && _deletedOldIndexes.count==0 && _moves.count==0 && _reloadedNewIndexes.count==0;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<HostListDiff insert=%lu delete=%lu move=%lu reload=%lu>",
            (unsigned long)_insertedNewIndexes.count,(unsigned long)_deletedOldIndexes.count,
            (unsigned long)_moves.count,(unsigned long)_reloadedNewIndexes.count];
}

@end

@implementation HostListDiffHelper

+ (NSString *)identityFor:(id)item block:(NSString *(^)(id))block {
    NSString *identifier=block?block(item):nil;
    if([identifier isKindOfClass:NSString.class] && identifier.length)return identifier;
    // Pointer-equivalent fallback so nil/empty identities never collide and get
    // treated as pure inserts/deletes rather than spurious moves.
    return [NSString stringWithFormat:@"__host_ptr:%p",item];
}

+ (HostListDiff *)diffFromOld:(nullable NSArray *)oldItems
                        toNew:(nullable NSArray *)newItems
                identityBlock:(NSString *(^)(id))identityBlock
                  isEqualBlock:(nullable BOOL (^)(id oldItem, id newItem))isEqualBlock {
    NSArray *old=oldItems?:@[];
    NSArray *new=newItems?:@[];

    // Map each identity to the queue of its OLD indexes (front => next match).
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *oldPositions=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<old.count;i++){
        NSString *identity=[self identityFor:old[i] block:identityBlock];
        NSMutableArray<NSNumber *> *bucket=oldPositions[identity];
        if(!bucket){bucket=[NSMutableArray array];oldPositions[identity]=bucket;}
        [bucket addObject:@(i)];
    }

    NSUInteger newCount=new.count;
    NSNumber *const kNotFound=[NSNumber numberWithInteger:-1];
    NSMutableArray<NSNumber *> *commonOldIndexForNew=[NSMutableArray arrayWithCapacity:newCount];
    NSMutableArray<NSNumber *> *inserted=[NSMutableArray array];
    NSMutableIndexSet *matchedOld=[NSMutableIndexSet indexSet];
    for(NSUInteger j=0;j<newCount;j++){
        NSString *identity=[self identityFor:new[j] block:identityBlock];
        NSMutableArray<NSNumber *> *bucket=oldPositions[identity];
        if(bucket.count){
            NSUInteger oldIndex=[bucket.firstObject unsignedIntegerValue];
            [bucket removeObjectAtIndex:0];
            [commonOldIndexForNew addObject:@(oldIndex)];
            [matchedOld addIndex:oldIndex];
        }else{
            [commonOldIndexForNew addObject:kNotFound];
            [inserted addObject:@(j)];
        }
    }

    // Deletes: OLD indexes never matched.
    NSMutableArray<NSNumber *> *deleted=[NSMutableArray array];
    for(NSUInteger i=0;i<old.count;i++){
        if(![matchedOld containsIndex:i])[deleted addObject:@(i)];
    }

    // Moves: among COMMON new items (in new order), the longest strictly
    // increasing subsequence of their OLD indexes stays put; everything else
    // is a move. O(n^2) is fine for typical list sizes.
    NSMutableArray<NSNumber *> *commonOldSequence=[NSMutableArray array];
    NSMutableArray<NSNumber *> *commonNewIndexes=[NSMutableArray array]; // new j of each common item
    for(NSUInteger j=0;j<newCount;j++){
        if(commonOldIndexForNew[j].integerValue>=0){
            [commonOldSequence addObject:commonOldIndexForNew[j]];
            [commonNewIndexes addObject:@(j)];
        }
    }
    NSUInteger n=commonOldSequence.count;
    // LIS (strictly increasing) reconstruction.
    NSMutableArray<NSNumber *> *dpLen=[NSMutableArray arrayWithCapacity:n];
    NSMutableArray<NSNumber *> *prev=[NSMutableArray arrayWithCapacity:n];
    NSUInteger bestEnd=0;
    for(NSUInteger i=0;i<n;i++){
        NSUInteger len=1, prevIdx=NSNotFound;
        NSUInteger currentOld=[commonOldSequence[i] unsignedIntegerValue];
        for(NSUInteger k=0;k<i;k++){
            NSUInteger kOld=[commonOldSequence[k] unsignedIntegerValue];
            if(kOld<currentOld){
                NSUInteger kLen=[dpLen[k] unsignedIntegerValue];
                if(kLen+1>len){len=kLen+1;prevIdx=k;}
            }
        }
        [dpLen addObject:@(len)];
        [prev addObject:(prevIdx==NSNotFound)?[NSNumber numberWithInteger:-1]:@(prevIdx)];
        if(len>[dpLen[bestEnd] unsignedIntegerValue])bestEnd=i;
    }
    NSMutableIndexSet *keptOldForLIS=[NSMutableIndexSet indexSet];
    {
        NSUInteger cur=bestEnd;
        while(cur!=NSNotFound && cur<n){
            [keptOldForLIS addIndex:[commonOldSequence[cur] unsignedIntegerValue]];
            NSInteger p=[prev[cur] integerValue];
            cur=(p<0)?NSNotFound:(NSUInteger)p;
        }
    }

    NSMutableArray<NSDictionary *> *moves=[NSMutableArray array];
    NSMutableArray<NSNumber *> *reloaded=[NSMutableArray array];
    for(NSUInteger i=0;i<n;i++){
        NSUInteger oldIndex=[commonOldSequence[i] unsignedIntegerValue];
        NSUInteger newIndex=[commonNewIndexes[i] unsignedIntegerValue];
        if(![keptOldForLIS containsIndex:oldIndex]){
            [moves addObject:@{@"from":@(oldIndex),@"to":@(newIndex)}];
        }
        if(isEqualBlock){
            id oldItem=old[oldIndex];
            id newItem=new[newIndex];
            if(!isEqualBlock(oldItem,newItem))[reloaded addObject:@(newIndex)];
        }
    }

    return [[HostListDiff alloc] initWithInserted:inserted deleted:deleted moves:moves reloaded:reloaded];
}

@end
